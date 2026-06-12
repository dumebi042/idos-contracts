# Submission: Force-Staking via Unrestricted `user` Parameter

**Target:** IDOSNodeStaking.sol
**Severity:** Medium
**Type:** Access Control / Business Logic

## Description

The [`stake(address user, address node, uint256 amount)`](src/IDOSNodeStaking.sol:108) function allows any caller to specify a `user` address different from `msg.sender` with **no access control**. The only guard — [`if (user == address(0)) user = msg.sender`](src/IDOSNodeStaking.sol:115) — only covers the zero-address case. For any non-zero `user`, [`safeTransferFrom(user, address(this), amount)`](src/IDOSNodeStaking.sol:119) pulls tokens from the specified address, and all stake accounting records the position under that `user`.

## Impact

**Direct attacker-controlled consequence:** An attacker who knows a victim has approved the staking contract can force the victim's tokens into any allowlisted node of the attacker's choice. The victim's tokens are locked for the mandatory 14-day unbonding period (`UNSTAKE_DELAY`).

**Conditional escalation:** If the attacker-chosen node is subsequently slashed by the owner, the victim's staked tokens are permanently confiscated via `withdrawSlashedStakes()`. This escalation requires an independent privileged action but is a realistic scenario given the attacker controls node selection.

## Attack Sequence

1. Victim approves the staking contract (e.g., `type(uint256).max` for convenience, or a specific allowance)
2. Attacker calls `stake(victim, attackerNode, victimAmount)` where `attackerNode` is allowlisted
3. `safeTransferFrom(victim, stakingContract, amount)` moves victim's tokens
4. Stake is recorded under `victim` → `attackerNode`
5. Victim cannot unstake for 14 days (`UNSTAKE_DELAY`)
6. If `attackerNode` is slashed, victim's tokens are permanently lost

## PoC

File: [`test/AuditPoC_Wave3.t.sol`](test/AuditPoC_Wave3.t.sol) — 12 test scenarios.

Core PoC (`test_F1_Scenario1_ApprovalConsumed`):

```solidity
function test_F1_Scenario1_ApprovalConsumed() public {
    uint256 stakeAmount = 500;
    uint256 victimBalanceBefore = idosToken.balanceOf(victim);
    uint256 contractBalanceBefore = idosToken.balanceOf(address(idosStaking));

    // Victim approves staking contract
    vm.prank(victim);
    idosToken.approve(address(idosStaking), stakeAmount);

    // Attacker force-stakes victim's tokens to rogue node
    vm.prank(attacker);
    idosStaking.stake(victim, nodeRogue, stakeAmount);

    // External balance assertions
    assertEq(idosToken.balanceOf(victim), victimBalanceBefore - stakeAmount, "Victim lost tokens");
    assertEq(idosToken.balanceOf(address(idosStaking)), contractBalanceBefore + stakeAmount, "Contract gained tokens");
    assertEq(idosStaking.stakeByNodeByUser(victim, nodeRogue), stakeAmount, "Stake recorded under victim");
}
```

## Root Cause

[`IDOSNodeStaking.sol:108-109`](src/IDOSNodeStaking.sol:108-109): No access control on the `user` parameter. A `require(user == msg.sender, "Cannot stake for others")` check is absent.

## Comparison with Prior Audit

Nethermind Finding 6.1 ([`NM0731-FINAL_IDOS.pdf`](NM0731-FINAL_IDOS.pdf)) only flagged the missing allowlist check on the `node` parameter. The unrestricted `user` parameter was not identified.

## Recommended Fix

Add at line 116:

```solidity
require(user == msg.sender, "Cannot stake for others");
```

Or implement an authorized-delegate mapping for legitimate delegation use cases.

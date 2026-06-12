# Submission: Full Unstake Removes Node Record Required by `slash()`

**Target:** IDOSNodeStaking.sol
**Severity:** Medium (candidate)
**Type:** Business Logic / Slashing Design Flaw

## Description

The protocol retains unstaked funds for a 14-day unbonding/slashing penalty window (`UNSTAKE_DELAY`), but [`unstake()`](src/IDOSNodeStaking.sol:142) immediately removes the node record that [`slash()`](src/IDOSNodeStaking.sol:192) requires. Specifically, when a full unstake reduces a node's balance to zero, [`stakeByNode.remove(node)`](src/IDOSNodeStaking.sol:156) fires, removing the node from the `stakeByNode` EnumerableMap. When the owner subsequently calls `slash(node)`, the precondition [`require(stakeByNode.contains(node), NodeIsUnknown(node))`](src/IDOSNodeStaking.sol:192) causes the transaction to revert — the funds held by the protocol become unreachable by the slashing mechanism.

## Impact

Funds that the protocol intentionally retains for a 14-day slashing window can escape slashing. The node identity is not permanently immune — if new stake arrives, it becomes slashable again — but the pending unstaked funds are permanently protected.

## Attack Sequence

1. Staker stakes tokens to node
2. Staker calls `unstake(node, amount)` for the full balance
3. `stakeByNode.remove(node)` fires when `newNodeStake == 0`
4. Owner calls `slash(node)` → reverts with `NodeIsUnknown`
5. After 14 days, staker calls `withdrawUnstaked()` → recovers full amount

## PoC

File: [`test/AuditPoC_Wave3.t.sol`](test/AuditPoC_Wave3.t.sol) — 12 test sequences.

Core PoC (`test_F2_Sequence1_FullUnstakeDuringDelay`):

```solidity
function test_F2_Sequence1_FullUnstakeDuringDelay() public {
    uint256 stakeAmount = 500;

    // Stake to node
    vm.prank(victim);
    idosStaking.stake(address(0), nodeRogue, stakeAmount);

    // Full unstake — removes node from stakeByNode
    vm.prank(victim);
    idosStaking.unstake(nodeRogue, stakeAmount);

    // slash() reverts — node identity removed from stakeByNode
    vm.prank(owner);
    vm.expectRevert(abi.encodeWithSignature("NodeIsUnknown(address)", nodeRogue));
    idosStaking.slash(nodeRogue);

    // After delay, user withdraws successfully
    vm.warp(block.timestamp + UNSTAKE_DELAY + 1);
    vm.prank(victim);
    idosStaking.withdrawUnstaked();

    assertEq(idosToken.balanceOf(victim), INITIAL_VICTIM_BALANCE);
}
```

## Root Cause

[`IDOSNodeStaking.sol:156`](src/IDOSNodeStaking.sol:156): `stakeByNode.remove(node)` is called unconditionally when `newNodeStake == 0`. The `slash()` function at line 192 depends on `stakeByNode.contains(node)` as its gate, creating a design contradiction: the protocol retains funds for 14 days but immediately removes the only record that allows slashing those funds.

## Comparison with Prior Audit

Nethermind Finding 6.5 describes partial unstake (funds escape slashing via reduced stake). This finding describes the distinct scenario where full unstake causes `slash()` to revert entirely — a governance bypass, not just fund escape.

## Scope Consideration

The programme's "Transaction ordering" exclusion may apply since the attack depends on unstake executing before slash. The defence is that this is a **design contradiction** (retain funds but remove slashing handle) rather than generic mempool front-running, and the issue is reachable whenever the final staker, or coordinated stakers representing the node's entire active stake, reduce the node balance to zero before slashing.

## Recommended Fix (Design-Level)

A correct fix requires **node attribution during unbonding**. The current
`Unstake` struct does not record which node the stake came from:

```solidity
struct Unstake {
    uint256 amount;
    uint48 timestamp;
}
```

The pending amounts are stored only by user, without their originating node.
After a full unstake, `stakeByNode` no longer contains the node, and the
contract cannot identify which pending unstakes belong to it.

**Minimal mitigation — track node in `Unstake`:**

```solidity
struct Unstake {
    address node;      // ← add originating node
    uint256 amount;
    uint48 timestamp;
}
```

Then pending unstaked amounts remain attributable to their node and can be
slashed until `UNSTAKE_DELAY` expires. The `slash()` function would iterate
the slashed node's users and confiscate pending amounts still within the
delay window.

**Alternative — do not remove node from `stakeByNode` on unstake:**

Keep the node in `stakeByNode` even when balance reaches zero, so
`slash()` always has a valid target. Track "active stake" via a separate
counter.

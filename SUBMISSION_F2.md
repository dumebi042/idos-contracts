# Submission: Full Unstake Removes Node Record Required by `slash()`

**Target:** IDOSNodeStaking.sol
**Severity:** Low / duplicate-risk candidate
**Type:** Business Logic / Slashing Design Flaw

## Description

The protocol retains unstaked funds for a 14-day unbonding/slashing penalty window (`UNSTAKE_DELAY`), but [`unstake()`](src/IDOSNodeStaking.sol:142) immediately removes the node record that [`slash()`](src/IDOSNodeStaking.sol:192) requires. Specifically, when a full unstake reduces a node's balance to zero, [`stakeByNode.remove(node)`](src/IDOSNodeStaking.sol:156) fires, removing the node from the `stakeByNode` EnumerableMap. When the owner subsequently calls `slash(node)`, the precondition [`require(stakeByNode.contains(node), NodeIsUnknown(node))`](src/IDOSNodeStaking.sol:192) causes the transaction to revert — the funds held by the protocol become unreachable by the slashing mechanism.

## Impact

Funds that the protocol intentionally retains for a 14-day slashing window can escape a later slash if the node's active stake is reduced to zero before `slash(node)` is called. The node identity is not permanently immune — if new stake arrives, it becomes slashable again — but the already-pending unstake can be withdrawn after the delay.

## Attack Sequence

1. Staker stakes tokens to node
2. Staker calls `unstake(node, amount)` for the full balance
3. `stakeByNode.remove(node)` fires when `newNodeStake == 0`
4. Owner calls `slash(node)` → reverts with `NodeIsUnknown`
5. After 14 days, staker calls `withdrawUnstaked()` → recovers full amount

## PoC

File: [`test/AuditPoC_Wave3.t.sol`](test/AuditPoC_Wave3.t.sol) — 12 test sequences.

Core PoC (`test_F2_Sequence1_FullUnstakeSlashDuringDelayUserWithdraws`):

```solidity
function test_F2_Sequence1_FullUnstakeSlashDuringDelayUserWithdraws() public {
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

Nethermind Finding 6.5 already describes the broader issue: `unstake()` reduces `stakeByNode`, pending unstakes are dissociated from the node, `Unstake` does not store node identity, and `withdrawSlashedStakes()` cannot recover those pending amounts. This report is therefore best framed as a concrete edge-case reproduction of that acknowledged issue: when the full active node balance is unstaked, `slash(node)` itself reverts with `NodeIsUnknown` until new stake is added.

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

**Required building block — track node in `Unstake`:**

```solidity
struct Unstake {
    address node;      // ← add originating node
    uint256 amount;
    uint48 timestamp;
}
```

This is necessary for attribution, but it is not sufficient by itself. The
contract also needs bounded accounting that lets `slash(node)` include
pending unstakes without iterating every user.

**Practical bounded design:**

- Store `node`, `amount`, `timestamp`, and a slashed/withdrawn status per pending unstake.
- Maintain node-level pending totals, e.g. `pendingUnstakeByNode[node]`, updated on unstake and withdrawal.
- Let `slash(node)` slash `activeStakeByNode[node] + pendingUnstakeByNode[node]` and mark the node slashed at the slash timestamp.
- In `withdrawUnstaked()`, skip or reduce pending entries whose node was slashed before the request matured, routing those amounts to a protocol slashed-pending pool.
- Keep owner withdrawal based on explicit slashed active and slashed pending totals rather than iterating users.

Keeping zero-value nodes in `stakeByNode` may keep `slash(node)` callable, but it does not by itself make pending withdrawal balances slashable or withdrawable by the protocol.

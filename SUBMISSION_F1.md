# HackenProof Submission: F1

## 1. Target

https://github.com/idos-network/contracts/blob/master/src/IDOSNodeStaking.sol

Type: Smart Contract

## 2. Category

Unsecure Design -> Business Logic Errors

Alternative smart-contract classification: Unauthorized transaction / attacks on logic.

## 3. Severity

Medium

## 4. Title

Unauthorized force-staking in IDOSNodeStaking lets any caller lock a victim's approved IDOS into an allowlisted node

## 5. Vulnerability Details

### Summary

`IDOSNodeStaking.stake(address user, address node, uint256 amount)` allows any caller to pass an arbitrary nonzero `user` address. The function then pulls IDOS from that address with `safeTransferFrom(user, address(this), amount)` and records the resulting stake under the victim, without checking that `user == msg.sender` and without requiring a signature, delegate approval, operator role, or any other staking-specific authorization from the user.

This means an attacker can consume a victim's existing ERC20 approval to the staking contract and force the victim's tokens into any currently allowlisted node selected by the attacker. The victim receives ownership of the resulting stake, but the tokens are no longer liquid and cannot be recovered without first unstaking and waiting the mandatory 14-day unbonding delay.

If the attacker-selected allowlisted node is later slashed by the trusted owner, the victim's force-staked tokens can be permanently confiscated. That permanent-loss path requires an independent privileged slashing action; the direct attacker-controlled impact is unauthorized staking, allowance consumption, unwanted node allocation, and forced lockup.

### Affected Code

In `src/IDOSNodeStaking.sol`:

```solidity
function stake(address user, address node, uint256 amount) external whenNotPaused {
    if (node == address(0)) revert NodeIsZero();
    if (!allowedNodes.contains(node)) revert NodeIsNotAllowed(node);
    if (slashedNodes.contains(node)) revert NodeIsSlashed(node);
    if (amount == 0) revert AmountIsZero();
    if (!hasStarted()) revert NotStarted();

    if (user == address(0)) user = msg.sender;

    user = user.normalize();
    node = node.normalize();
    idosToken.safeTransferFrom(user, address(this), amount);
```

The zero-address fallback only handles self-staking through `stake(address(0), node, amount)`. For any nonzero `user`, the function accepts a user address supplied by the caller and immediately attempts to transfer that user's tokens.

There is no authorization check between:

- `msg.sender`
- the supplied `user`
- the supplied `node`
- the supplied `amount`

### Why This Is a Bug, Not Intended Design

The function appears to support a self-stake sentinel through `if (user == address(0)) user = msg.sender;`. If staking on behalf of another address is intended, the implementation is missing the normal authorization layer for that design.

Expected controls for intentional staking-on-behalf would include at least one of:

- an EIP-712 signature from `user` authorizing the node, amount, deadline, and nonce;
- a user-controlled approved delegate/operator mapping;
- a trusted relayer role;
- documentation and tests proving arbitrary third-party staking is expected.

The current implementation has none of those. ERC20 allowance to the staking contract should not be treated as consent for any external caller to choose the staking node and lock the user's tokens.

### Preconditions

1. The victim has approved the `IDOSNodeStaking` contract to spend IDOS.
2. The attacker knows or can discover the allowance.
3. The attacker chooses a node that is currently allowlisted and not slashed.
4. The staking contract is unpaused and staking has started.

No privileged role is required for the attacker.

### Attack Sequence

1. A victim approves the staking contract, for example with a convenience unlimited approval.
2. The attacker calls:

```solidity
idosStaking.stake(victim, selectedAllowlistedNode, amount);
```

3. `IDOSNodeStaking` calls:

```solidity
idosToken.safeTransferFrom(victim, address(idosStaking), amount);
```

4. The victim's allowance is consumed and their external IDOS balance decreases.
5. The staking contract balance increases.
6. The stake is recorded under `victim` for `selectedAllowlistedNode`.
7. The victim cannot immediately recover liquid tokens. They must call `unstake()` and wait the 14-day `UNSTAKE_DELAY`.
8. If the selected node is later slashed by the owner, the victim's force-staked funds are exposed to confiscation through the normal slashing flow.

### Impact

Direct attacker-controlled impact:

- unauthorized transaction using the victim's existing ERC20 approval;
- victim's approved IDOS can be moved into the staking contract without their staking consent;
- victim is forced into an unwanted node allocation;
- victim loses liquidity for the mandatory 14-day unbonding period;
- repeated force-staking is possible while allowance and balance remain available.

Conditional escalation:

- if the chosen allowlisted node is later slashed by the owner, the victim's force-staked tokens can be permanently lost;
- this permanent loss is not solely attacker-controlled and depends on a later trusted-owner slash.

This is therefore a real unauthorized transaction and forced lockup, but direct theft does not occur without a victim approval and permanent confiscation requires a later privileged slash.

### Deployed-State Confirmation

The issue is not only theoretical. The Arbitrum One deployment listed in `deployments.toml` is:

- `IDOSToken`: `0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c`
- `IDOSNodeStaking`: `0x6132F2EE66deC6bdf416BDA9588D663EaCeec337`

Read-only checks against Arbitrum One confirmed:

- `IDOSNodeStaking.idosToken()` returns `0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c`;
- `IDOSNodeStaking.paused()` returns `false`;
- `getNodeStakes()` returns active allowlisted nodes, including `0x0C5393db793DbA88f16DC4D030D678FBD88F8B0D`.

A read-only `eth_call` to the live staking contract was made with:

- caller: arbitrary address;
- `user`: `0x0000000000000000000000000000000000000001`;
- `node`: active node `0x0C5393db793DbA88f16DC4D030D678FBD88F8B0D`;
- `amount`: `1`.

The call reverted with selector `0xfb8f41b2`, which is OpenZeppelin's `ERC20InsufficientAllowance(address spender, uint256 allowance, uint256 needed)`.

This confirms the live contract accepted `user != msg.sender`, accepted the active node, and reached the ERC20 allowance check for the victim address. It did not revert with a staking authorization error, `NodeIsNotAllowed`, `NotStarted`, or pause-related error.

No funds were moved during this deployed-state check.

### Prior Audit / Public Mention Check

Nethermind Finding 6.1 in `NM0731-FINAL_IDOS.pdf` discussed missing node allowlist validation. It did not identify that any caller can pass an arbitrary nonzero `user` and consume that user's allowance through `safeTransferFrom(user, ...)`.

I also checked public GitHub issues/PR search and indexed web/gist search terms for this specific issue, including:

- `IDOSNodeStaking safeTransferFrom(user`
- `IDOSNodeStaking stake user msg.sender`
- `Force-Staking IDOSNodeStaking`
- `stake(address user,address node,uint256 amount)`
- `0x6132F2EE66deC6bdf416BDA9588D663EaCeec337`

No public issue, PR, or indexed gist/web result for this force-staking issue was found. The currently visible public GitHub issue #25 reports a different reward-calculation/sandwich claim and does not mention arbitrary-user force-staking.

## 6. Validation Steps

### Local Foundry Reproduction

1. From the repository root, run the F1 PoC tests:

```bash
forge test --match-contract AuditPoC_Wave3 --match-test F1 -vvv
```

2. The core test is `test_F1_Scenario1_AttackerConsumesApprovalFirst` in `test/AuditPoC_Wave3.t.sol`.

3. The test sets up:

- victim with IDOS balance;
- attacker with no privileged staking role;
- victim approval to the staking contract;
- an allowlisted node selected by the attacker.

4. The attacker calls:

```solidity
idosStaking.stake(victim, nodeRogue, stakeAmount);
```

5. The test verifies the externally observable effects:

- victim IDOS balance decreases by `stakeAmount`;
- staking contract IDOS balance increases by `stakeAmount`;
- victim's allowance is consumed;
- stake is recorded under `victim`;
- stake is allocated to the attacker-selected allowlisted node;
- victim must use the normal unstake flow and wait the unbonding delay to recover.

### Minimal PoC

```solidity
function test_F1_Scenario1_AttackerConsumesApprovalFirst() public {
    uint256 stakeAmount = 500;
    uint256 victimBalanceBefore = idosToken.balanceOf(victim);
    uint256 contractBalanceBefore = idosToken.balanceOf(address(idosStaking));

    vm.prank(victim);
    idosToken.approve(address(idosStaking), stakeAmount);

    vm.prank(attacker);
    idosStaking.stake(victim, nodeRogue, stakeAmount);

    assertEq(
        idosToken.balanceOf(victim),
        victimBalanceBefore - stakeAmount,
        "victim external balance decreased"
    );
    assertEq(
        idosToken.balanceOf(address(idosStaking)),
        contractBalanceBefore + stakeAmount,
        "staking contract received tokens"
    );
    assertEq(
        idosStaking.stakeByNodeByUser(victim, nodeRogue),
        stakeAmount,
        "stake was recorded under victim for attacker-selected node"
    );
}
```

### Deployed-State Validation Without Moving Funds

The deployed-state behavior can be validated with read-only calls:

1. Confirm the staking contract token:

```bash
cast call 0x6132F2EE66deC6bdf416BDA9588D663EaCeec337 "idosToken()(address)" --rpc-url https://arb1.arbitrum.io/rpc
```

Expected result:

```text
0x68731d6F14B827bBCfFbEBb62b19Daa18de1d79c
```

2. Confirm the staking contract is not paused:

```bash
cast call 0x6132F2EE66deC6bdf416BDA9588D663EaCeec337 "paused()(bool)" --rpc-url https://arb1.arbitrum.io/rpc
```

Expected result:

```text
false
```

3. Confirm active nodes exist:

```bash
cast call 0x6132F2EE66deC6bdf416BDA9588D663EaCeec337 "getNodeStakes()((address,uint256)[])" --rpc-url https://arb1.arbitrum.io/rpc
```

One observed active node:

```text
0x0C5393db793DbA88f16DC4D030D678FBD88F8B0D
```

4. Simulate a force-stake from an arbitrary caller against an arbitrary victim-like address with no allowance:

```bash
cast call \
  --from 0x0000000000000000000000000000000000000222 \
  0x6132F2EE66deC6bdf416BDA9588D663EaCeec337 \
  "stake(address,address,uint256)" \
  0x0000000000000000000000000000000000000001 \
  0x0C5393db793DbA88f16DC4D030D678FBD88F8B0D \
  1 \
  --rpc-url https://arb1.arbitrum.io/rpc
```

Expected behavior:

The call reverts with `ERC20InsufficientAllowance`, proving execution reached `safeTransferFrom(user, ...)` for the arbitrary nonzero `user`.

Expected selector:

```text
0xfb8f41b2
```

## 7. Supporting Files / PoC

Recommended upload:

- `test/AuditPoC_Wave3.t.sol`
- `SUBMISSION_F1.md`

Relevant repository files:

- `src/IDOSNodeStaking.sol`
- `deployments.toml`

Primary PoC test:

- `test_F1_Scenario1_AttackerConsumesApprovalFirst`

Additional F1 tests in `test/AuditPoC_Wave3.t.sol` cover repeated force-staking, unlimited approvals, withdrawal timing, node allocation, and slashing escalation.

## Recommended Remediation

If staking on behalf of another user is not intended, resolve the zero-address sentinel and then require the effective user to be the caller:

```solidity
if (user == address(0)) user = msg.sender;
require(user == msg.sender, "Cannot stake for others");
```

If staking on behalf of another user is intended, preserve it only with explicit user authorization. For example:

- require an EIP-712 signature from `user` over `node`, `amount`, `deadline`, and `nonce`;
- or add a user-controlled approved delegate mapping;
- or restrict non-self staking to a trusted role if the protocol has a specific relayer or distributor design.

ERC20 allowance alone should not authorize arbitrary third parties to choose the staking node and lock the user's tokens.

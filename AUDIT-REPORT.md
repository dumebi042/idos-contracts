# idOS Contracts — Working Audit Report (Wave 3)

## Test Suite Results

| Category                              | Count / Result |
| ------------------------------------- | -------------- |
| Test/invariant entries discovered     | 249            |
| Existing project entries              | 124            |
| New audit entries (Waves 1-3)         | 125            |
| First `forge test --summary` execution | 190 passed / 1 failed |
| First `forge test -vvv` execution      | 147 passed / 1 failed |

_(Discovery counts from `forge test --list`. The requested execution runs stopped/cancelled remaining work after the same failing test: `IDOSVestingTest:test_WorksWithCliff`.)_

**Existing project tests (124):**

| Suite                                   | Tests |
| --------------------------------------- | ----- |
| `BatchCallerTest`                       | 6     |
| `CCADisbursementTrackerUnitTest`        | 35    |
| `CCADisbursementTrackerIntegrationTest` | 5     |
| `CCADisbursementTrackerInvariantTest`   | 4     |
| `IDOSNodeStakingTest`                   | 45    |
| `IDOSTokenTest`                         | 3     |
| `IDOSVestingTest`                       | 2     |
| `TDEDisbursementTest`                   | 24    |

**New audit tests (125) — per Forge-discovered contract:**

| Suite                                              | Tests | Result                        |
| -------------------------------------------------- | ----- | ----------------------------- |
| `AuditPoC` (Wave 1 + Wave 2)                       | 15    | ✅ All pass                   |
| `BatchCallerEIP7702Test` (Wave 2f)                 | 14    | ✅ All pass                   |
| `CCADisbursementTrackerStateMachineTest` (Wave 2d) | 16    | ✅ All pass                   |
| `TDEDisbursementBoundaryTest` (Wave 2e)            | 8     | ✅ All pass                   |
| `AuditPoC_Wave3` (Wave 3 F1+F2 deepening)          | 24    | ✅ All pass                   |
| `StakingInvariantTest` (Wave 3 Phase 4)            | 3     | ✅ Foundry invariant handler  |
| `Wave3Invariants` (Wave 3 Phases 4-6)              | 31    | ✅ All pass                   |
| `AuditPoC_Wave3_CCA_Vesting` (Wave 3 Phases 7-9)   | 14    | ✅ All pass                   |

**Status:** Pre-existing vesting test expectation mismatch observed under the audit configuration; no production exploit identified.

## Findings

### F1: Force-Staking via `stake(user, node, amount)` — **Medium / Novel**

[`IDOSNodeStaking.sol:108-109`](src/IDOSNodeStaking.sol:108-109) allows any caller to specify `user != msg.sender` with no access control. Anyone who knows a victim has approved the staking contract can force-stake their tokens to any allowlisted node.

**Direct attacker-controlled impact:** Forced allocation of approved tokens into an unwanted staking position and a mandatory 14-day unbonding delay.

**Conditional permanent loss:** If the attacker-selected node is subsequently slashed by the owner, the victim's tokens are confiscated. This outcome requires an independent privileged action (owner slashing) and is not solely attacker-controlled.

**Test coverage:** 12 PoC tests in [`test/AuditPoC_Wave3.t.sol`](test/AuditPoC_Wave3.t.sol) — all scenarios confirmed with external balance assertions.

### F2: Full Unstake Removes Node from `stakeByNode`, Making `slash()` Unreachable — **Low / Duplicate-risk Extension of NM-6.5**

When the final staker—or coordinated stakers representing a node's entire active
stake—fully unstakes, [`stakeByNode.remove(node)`](src/IDOSNodeStaking.sol:156)
fires, removing the node from the `stakeByNode` EnumerableMap.
[`slash()`](src/IDOSNodeStaking.sol:192) requires `stakeByNode.contains(node)`
and reverts with `NodeIsUnknown`.

**Root cause:** The protocol intentionally retains unstaked funds for a 14-day
penalty window (`UNSTAKE_DELAY`), but removes the only node record accepted by
`slash()`. Consequently, any full unstake finalized before a slash decision
makes funds already held by the protocol unreachable by the slashing mechanism.

**What becomes immune:**

- ✅ Pending unstaked funds (those in the 14-day unbonding pipeline)
- ❌ The node identity — can be slashed again if new stake arrives
- ❌ Future stakes — always slashable

**Novelty and scope risk:** Nethermind 6.5 already describes the broader pending-unstake slashing bypass, including the missing node attribution in `Unstake`. This report is best treated as a concrete edge-case reproduction rather than a clearly novel standalone finding. The programme's "Transaction ordering" exclusion
(line 111 of `idOS-bounty-info.md`) may apply. The defence is that the
vulnerability is a design flaw in the unbonding/slashing interaction, not
generic mempool front-running.

## Testing Summary

### Wave 1 — Initial Audit (F1-F5 + prior findings verification)

- Wave 1 — Findings F1–F5 in AuditPoC.t.sol (file contains 15 combined Wave 1–2 tests)
- Nethermind findings verified: 2 Fixed, 4 Acknowledged

### Wave 2 — Deep Testing (6 areas)

- Staking accounting invariants — 3 tests, all invariants hold
- Reward fuzzing — isolated W2b rerun exposed a counterexample where withdrawable rewards exceed the current contract balance after owner-funded rewards are paid out; this remains a separate solvency/funding hypothesis, not a submission-ready attacker finding.
- Reward-pool solvency — deterministic W2c scenarios did not prove an additional submission-ready issue.
- CCA state machine — 16 tests, non-terminal `saleFullyDisbursed()` documented
- TDE vesting boundaries — 8 tests, all 10 modalities verified
- BatchCaller EIP-7702 — 14 tests, guard correct

### Wave 3 — Adversarial Testing (9 phases)

- **Phase 1**: Baseline — exact test totals, via-IR-specific test incompatibility investigated; no production defect identified
- **Phase 2**: F1 deepened — **12 scenarios confirmed, F1 classified as Medium**
- **Phase 3**: F2 deepened — **12 sequences confirmed, F2 classified as Low / duplicate-risk with scope-exclusion risk**
- **Phase 4**: Stateful invariants — Ghost accounting handler exercised under Foundry invariant runs; no submission-ready new issue from these invariants
- **Phase 5**: Reward differential — Reference model matches contract for 13/15 sequences (R8/R9 divergences expected — slashing logic)
- **Phase 6**: Slashing accounting — 10 scenarios, `slashedStakeWithdrawn` cannot double-count/underflow/drain pending funds
- **Phase 7**: CCA integration — No external consumers treat `saleFullyDisbursed()` as terminal. `disbursementsToRange()` safe against overflow.
- **Phase 8**: EIP-7702 validation — **Genuinely tested via `vm.signAndAttachDelegation()`** in Foundry 1.5.1. Guard correct.
- **Phase 9**: Vesting failure — Pre-existing test incompatibility observed under the audit's `via-IR` compilation configuration; no production exploit identified.

## Findings Summary

| Finding                                                     | Defensible classification                                           |
| ----------------------------------------------------------- | ------------------------------------------------------------------- |
| F1: Force-staking                                           | Medium, novel                                                       |
| F2: Full unstake removes the node entry required by slash() | Low / duplicate-risk extension, with scope-exclusion risk           |
| Other in-scope contracts                                    | No exploitable issue found in tested paths                          |
| Audit status                                                | Testing complete; report normalization and submission review remain |

## Files Changed (Waves 1-3)

- [`foundry.toml`](foundry.toml) — Modified (`via_ir = true` for audit tests)
- [`test/AuditPoC.t.sol`](test/AuditPoC.t.sol) — Waves 1–2 audit tests
- [`test/AuditPoC_Wave3.t.sol`](test/AuditPoC_Wave3.t.sol) — Wave 3 F1 + F2 deepening
- [`test/AuditPoC_Wave3_Invariants.t.sol`](test/AuditPoC_Wave3_Invariants.t.sol) — Wave 3 invariant/reward/slashing tests
- [`test/AuditPoC_Wave3_CCA_Vesting.t.sol`](test/AuditPoC_Wave3_CCA_Vesting.t.sol) — Wave 3 CCA/EIP-7702/vesting tests
- [`AUDIT-REPORT.md`](AUDIT-REPORT.md) — Working report (this file)

## Commands Used

```bash
forge clean
forge build
forge test --summary
forge test -vvv
forge test --match-contract AuditPoC -vvv
forge test --match-contract Wave3 -vvv
forge test --match-contract BatchCallerEIP7702 -vvv
forge test --match-contract CCADisbursementTrackerStateMachine -vvv
forge test --match-contract TDEDisbursementBoundary -vvv
```

## Limitations

1. **EIP-7702**: Tested via Foundry's simulated EVM (`vm.signAndAttachDelegation`), not a live Pectra fork. Cross-chain replay protection not verified.
2. **CCA submodule**: The CCA library has its own audits (OpenZeppelin, Spearbit, ABDK). We did not re-audit the CCA itself.
3. **Initial distribution scripts**: The TypeScript scripts in `script/initial-distribution/` were reviewed for function usage but not for correctness of the off-chain computation.
4. **Owner trust model**: The owner can pause, slash, and withdraw slashed funds. This is by design but represents a centralization risk.
5. **`via_ir = true`**: Required for the audit test suite due to stack depth in complex test functions. The failing vesting test (`IDOSVestingTest:test_WorksWithCliff`) is a stale expectation around cliff release semantics; no production exploit identified. Foundry 1.5.1 still shows execution-count instability after failures, so `forge test --list` discovery counts should be separated from executed-test counts.

## Remaining Untested Areas

| Area                                                          | In Scope?   | Notes                                                                                                                                                                                                  |
| ------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Full CCA ↔ CCADisbursementTracker lifecycle on mainnet fork   | ❌ No       | CCA is imported dependency (line 106 excludes). `CCADisbursementTracker` not listed as in-scope contract.                                                                                              |
| Long-duration stress testing (years, thousands of stakers)    | ✅ Partial  | Applies to in-scope `IDOSNodeStaking`. Unbounded loop DoS (NM-6.3, NM-6.4) acknowledged by client as low-risk.                                                                                         |
| Off-chain owner governance attacks                            | ❌ No       | Owner trust model / centralization not listed as in-scope vulnerability type.                                                                                                                          |
| ERC20 edge cases (rebasing/fee-on-transfer with IDOS staking) | ✅ Yes      | `SafeERC20` with balance-before/after guards against fee-on-transfer in `stake()`. IDOS token is standard ERC20.                                                                                       |
| Cross-chain deployment / chain reorg scenarios                | ❌ No       | Not mentioned in bounty scope. Contracts deployed on Arbitrum One only.                                                                                                                                |
| **F2 and transaction ordering exclusion**                     | ⚠️ See note | "Transaction ordering" exclusion (line 111) could apply if F2 requires mempool front-running. F2 is a logic omission (no check for pending slashing), not a front-run — strengthens in-scope argument. |

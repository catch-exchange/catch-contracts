# Review and testing

Updated 7 September 2026. This is a maintainer-assembled evidence summary,
not a third-party audit certificate or a new security verdict.

## Review programme

Catch's development has included repeated adversarial reviews in separate
Codex and Claude sessions using the open-source [Pashov Solidity auditor](https://github.com/pashov/skills)
and [EthSkills](https://github.com/austintgriffith/ethskills) /
[EVM audit skills](https://github.com/austintgriffith/evm-audit-skills), executable
reproductions, focused remediation reviews and deployed-token diligence.
These are AI-assisted project reviews. They are not services commissioned
from Pashov Audit Group, a human audit firm's sign-off, or endorsements by
the framework authors. Independent sessions are not independent audit firms.

The earlier workspace-local review note did not contain the whole history:
separate-session records also document the actual framework runs. We distinguish
recorded execution from complete report publication and candidate-specific
results from current-source evidence.

| Review stage | Evidence and scope | Boundary |
| --- | --- | --- |
| August 2026 hardening | Pashov-style specialist lenses, EthSkills checks, precision/fuzz testing and Robinhood fork tests | Superseded cNVDA design; not carried forward as V1 certification or added to current test totals |
| 3 September: cGOLD candidate `c73ca1254a8d41a646c305219ed959cb1458e3c8` | Separate Codex/Claude framework sessions. Recovered Claude metadata records 12 Pashov specialists and 11 EthSkills lenses, with executable reproduction tests. Codex records workflow execution, pinned versions, specialist findings and tests | Pre-remediation candidate, not the deployed reusable factory. The recovered Claude verdict was NO-GO pending remediation/design disposition. A complete sealed Codex final verdict was not recovered for this publication |
| 3 September remediation | Regression-backed changes for specified-side partial fills, launch-address dust, exact-ratio release rounding and paused previews | Intentional primary/secondary price separation and liquid-only NAV were retained, not reported as fixed defects |
| 4 September naming/ABI delta, `ceb860d` → `5f46642` | Claude reviewed generic component names, ABI/events/receipt domains, custody bindings and economic parity; no Critical/High/Medium reported in that delta | Narrow delta review, not a second whole-protocol audit |
| 4 September infrastructure delta, `1c45c67` → `39798b6` | Claude applied relevant Pashov judging lenses and EthSkills checks; reported ACCEPT and 44 Foundry + 10 simulator tests, including five fork tests | Family-neutral launch tooling only. This pass explicitly used focused lenses, not another 12-specialist fan-out |
| 6 September deployed cGOLD diligence | Separate Claude EVM-token diligence at Robinhood block 56,084,916, covering custody, controls, fees, holder concentration, issuer dependencies and exit depth | CONDITIONAL conclusions; not an unqualified security approval or a substitute for source review |

The September framework records pin Pashov skill version 3 at
`c577eb7799c349de0acb187ba00ca98e14e436fd`, EthSkills at
`06ea4efa08076ff04f6ca4945ef4a2ca881115b0`, and EVM audit skills at
`ffe4b670e78e1945bcf275f79d4b7b0481bcff35`. Claude's recorded hook and
token-integration lenses were derived from the official AMM/ERC-20 checklists,
not claimed as separate official standalone skills.

This summary was reconciled from local review records and supplied delta reports.
The complete sealed report archive is **not published here**; therefore it should
not be cited as a publicly reproducible end-to-end audit. Private sessions,
credentials, operator material and raw untriaged exploit notes are not uploaded.

## What changed after review

The public implementation includes regression-covered corrections:

- Underlying-specified partial swap fills revert atomically instead of retaining
  a fee calculated on an unfilled request.
- Pre-existing underlying dust at deterministic launch addresses does not by
  itself brick launch; launch checks do not claim that dust as newly supplied funds.
- Primary-price protection uses full-precision reserve/supply arithmetic, and
  rounding on primary receipts favours NAV. Execution checks the resulting ratio.
- A paused primary release returns a closed, zero-value preview.
- Generic factory tests cover two isolated families, discovery records,
  duplicate/unauthorized launches and rejection of non-18-decimal underlyings.
- An explicit regression checks that unreleased custody cannot redeem or burn
  its way into the reserve.

Several review recommendations were deliberately **not** adopted. The fixed
primary curve does not follow pool price; arbitrage between venues remains
possible. Irreversible reserve donations count as NAV and can satisfy coverage.
Pending fees are excluded until settled, so settlement timing changes liquid
backing. Genesis liquidity remains one-sided. These are design dispositions,
not claims that the associated economic risks disappear. See the
[technical paper](https://catch.exchange/paper) and [risk guide](https://catch.exchange/docs/risks).

## Fresh bounded regression: 7 September 2026

All **36 source files** in the public build manifest matched the private test
workspace byte-for-byte. The result is recorded in
[the machine-readable testing summary](../verification/testing-summary.json).
Test-file hashes identify the exact test snapshot; the private workspace had
additional uncommitted testing/tooling work, so its HEAD alone is not claimed
to identify every test byte.

| Suite | Passed | What it exercises |
| --- | ---: | --- |
| Reusable Family V1 factory | 9 | Atomic launch, bindings, isolation, discovery, geometry, inventory boundaries |
| Family V1 hook | 7 | Four swap shapes, empty hook data, permission mask, partial-fill rejection |
| Legacy-named factory integration harness | 8 | Current family components against a local v4 PoolManager, dust, fees and redemption |
| Core and rounding | 9 | 64 steps, multi-step/partial purchases, exhaustion, protection, pause and rounding |
| Stateful invariant harness | 7 | Six invariants plus a test that deliberately violates backing to check detection |
| Economic simulators | 10 | Release ledger, launch geometry, buy/sell/redemption and backing-per-claim models |

**40 Solidity tests and 10 simulator tests passed; zero failed or skipped.**
Each of the six invariants reports 256 runs, 128,000 calls and zero handler
reverts. Those are counts reported per invariant, **not a claim of 768,000
independent economic paths**. The handler explores purchases, sells, paid
releases, donations, burns, collection and redemption. It cannot model every
adversarial token or external dependency.

Foundry 1.7.1 / Solidity 0.8.26; invariant depth 500 and
`fail_on_revert=false`. Runs were offline. **No live fork, router admission,
wallet signing or mainnet execution was performed in this publication run.**
Historical successful fork rehearsals are recorded above, not relabelled fresh.

The stateful harness and legacy-named integration harness instantiate a retired
one-shot factory around the current components; the separate nine-test suite
exercises the reusable V1 factory. The source-only repository does not ship
those private harnesses. The summary is evidence of a maintainer-run regression,
not a publicly executable replacement for those tests.

## What anyone can reproduce here

Public CI checks the explicit file allowlist, pinned source hashes, schemas,
eight exact standard-JSON compilations, ABI/runtime-template equality and
full public-history secret scanning. Publication-tooling unit tests are separate
from contract security tests. Follow [Verification](VERIFICATION.md).

An exact compilation proves neither a safe economic design nor that every live
dependency remains unchanged. Further families need their own dependency,
parameter, launch-state and runtime checks. Router allowlisting is also a
separate venue decision. Report suspected defects through [Security](../SECURITY.md).

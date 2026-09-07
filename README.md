# Catch contracts

**One family. One reserve. A fixed supply.**

Exact deployed Solidity sources and reproducible inputs for **Catch Family V1**.
Catch is the protocol; each cAsset market has its own underlying reserve,
release inventory and accounting. cGOLD and cSPY are the first published
families on Robinhood Chain.

![Catch marble mark above a circular plinth](assets/catch-market-standard.png)

[![Verify public source](https://github.com/catch-exchange/catch-contracts/actions/workflows/verify.yml/badge.svg)](https://github.com/catch-exchange/catch-contracts/actions/workflows/verify.yml)

[Architecture](docs/ARCHITECTURE.md) · [Deployments](docs/DEPLOYMENTS.md) ·
[Reproduce the build](docs/VERIFICATION.md) · [Technical paper](https://catch.exchange/paper) ·
[Security](SECURITY.md)

## Review and testing

Catch has undergone repeated **AI-assisted security reviews across separate
Codex and Claude sessions**, using the Pashov Solidity auditor and EthSkills
EVM audit workflows, followed by focused remediation and delta reviews.
This describes use of the open-source frameworks, **not an audit commissioned
from Pashov Audit Group or an endorsement by either framework's authors**.

The latest bounded regression run passed **40 Solidity tests**, including six
stateful invariants at **256 runs / 128,000 calls each**, and **10 economic
simulator tests**. Edge cases include multi-step releases, rounding, partial
swap fills, unsolicited dust, custody isolation and unreleased-inventory access.

Read the [review history, findings disposition and testing scope](docs/REVIEW_AND_TESTING.md).
Historical reviews cover specific earlier candidates; they are not blanket
certification of every later deployment. The public CI checks source integrity
and compilation, not the private contract-test suite.

## Start here

| You want to… | Read |
| --- | --- |
| Understand the graph and asset flows | [Architecture and custody boundaries](docs/ARCHITECTURE.md) |
| Check a live family or hook address | [Deployment directory](docs/DEPLOYMENTS.md) and [public identities](deployments/robinhood.json) |
| Reproduce compiler outputs | [Verification guide](docs/VERIFICATION.md) |
| Inspect review methodology and regression evidence | [Review and testing](docs/REVIEW_AND_TESTING.md) |
| Understand release pricing and reserve claims | [Technical paper](https://catch.exchange/paper) |
| Contribute or report a problem | [Contributing](CONTRIBUTING.md) or [private security reporting](SECURITY.md) |

## Deployed on Robinhood Chain · 4663

| Contract | Address |
| --- | --- |
| Shared Family V1 factory | `0x21acBCC6227Cf5D2Fb5eB876735edd04F7B49c12` |
| cGOLD | `0xb44e29a0540c48054d9caec192cdbb18c68398ec` |
| cSPY | `0xad2a032b99ede1ce2f03d2f1ba5a1b790f98592e` |

Match chain **and** address, not a ticker. The JSON lists all seven components
per family and recorded runtime hashes. Current explorer verification and
third-party routing approval are separate checks, not claims made by this table.

## Repository map

```text
src/                 Exact Catch sources, including historical vnext/ paths
lib/v4-core/         Exact imported Uniswap interfaces, types and libraries
abi/                 Eight compiler-generated contract interfaces
deployments/         Public identities of already-launched families
verification/        Exact inputs, source hashes and toolchain pins
scripts/             Integrity/reproduction and pinned-tool download
tests/               Publication-tooling tests, not a contract audit suite
docs/                Architecture, deployments, verification and release policy
.github/             Read-only CI, review ownership and templates
```

Source paths/bytes are deliberately preserved: they are compiler identifiers,
not a draft architecture to rename. No private build history, frontend/BFF,
operator scripts or future launch material is included. This is not an npm
package or a turnkey launch kit.

## Verify locally

Node.js 22.13+; no npm dependency installation, wallet or RPC is required.

```sh
npm run check
npm test
node scripts/download-tool.mjs solc .tools
SOLC="$PWD/.tools/solc" npm run reproduce
```

The downloader verifies a pinned official compiler checksum. If you already
have `0.8.26+commit.8a97fa7a`, set `SOLC` to its path instead.
See [platform support and secret scans](docs/VERIFICATION.md).

CI checks integrity, compiles eight targets and scans complete public history.
It never deploys, signs, spends funds or requires production credentials.
Runtime-template reproduction is **not** a fresh comparison to deployed bytecode
with constructor immutables filled in.

## Core model

- 1,000,000 cAssets preminted: 100,000 genesis allocation and 900,000 paid-release
  inventory. No later mint or replacement after burns.
- Active cAssets claim only their family's liquid underlying reserve. Unreleased
  inventory, locked principal and unsettled fees stay separate.
- Purchases follow a fixed 64-step schedule and repeated coverage test.
  Protected pricing prevents dilution; secondary trades never release inventory.
- The canonical hook charges 3% on the underlying side, split 70% reserve /
  30% treasury on settlement. Execution quotes also account for pool charges
  and impact. Collected cAsset position fees have a separate burn route.
- Holders redeem approved tokens for their pro-rata reserve. Catch cannot pause
  redemption; issuer restrictions and network availability remain.

## Evidence, not guarantees

No commissioned independent audit, perpetual exit liquidity, current explorer badge or router
allowlisting is implied. Genesis liquidity is one-sided; market price and backing
differ. Issuers may retain controls. No future CATCH-token entitlement is defined.

Source visibility allows inspection **and copying**, not anti-cloning protection.
Unpublished launch material remains outside this repository.

[Catch](https://catch.exchange) · [Markets](https://catch.exchange/markets) ·
[Guides](https://catch.exchange/docs) · [Status](https://catch.exchange/status)

Original Catch sources are MIT; imported licences/attribution are preserved.
See [LICENSE](LICENSE) and [NOTICE](NOTICE.md).

# Verification and reproducibility

## What is pinned

[`build-manifest.json`](../verification/build-manifest.json) records the 36-source
closure, exact standard-JSON hashes, eight compilation targets and creation-code
and runtime-template hashes. Original paths/SPDX notices/inputs are retained.
Solidity is `0.8.26+commit.8a97fa7a`, optimizer 200 runs, via-IR, Cancun EVM, with
the original per-input metadata/output settings.

## Local check — no credentials required

Use Node.js 22.13 or later. No npm dependencies need installation.

```sh
npm run check
npm test
node scripts/download-tool.mjs solc .tools
SOLC="$PWD/.tools/solc" npm run reproduce
```

The downloader verifies the version and SHA-256 in
[`toolchain.json`](../verification/toolchain.json). Linux x64 and macOS x64 are
supported; Apple Silicon uses the official x64 compiler and may need Rosetta.
Elsewhere, install the exact compiler from the [official Solidity distribution](https://docs.soliditylang.org/en/v0.8.26/installing-solidity.html)
and supply its path in `SOLC`. Do not substitute the current system compiler.

Compilation itself is offline. It checks exported source/input hashes,
recompiles all targets and compares creation code, runtime templates, ABIs and
immutable-reference layouts. No wallet, RPC, private key or deployment is used.

Before pushing:

```sh
node scripts/download-tool.mjs gitleaks .tools
.tools/gitleaks git --redact=100 --no-banner --log-opts="--all" .
.tools/gitleaks dir --redact=100 --no-banner .
```

The scanner is pinned/checksummed and output is redacted. A clean scan is one
layer, not a guarantee: review the exact file list and history too. Never bypass
a suspected secret to get CI green. The sole documented scanner exception is
the exact `PoolKey.sol` source checksum on its exact manifest line; the integrity
check independently recomputes it. No directory, history or generic key pattern
is excluded. GitHub push protection is an additional
pre-publication control; CI runs **after** data has reached GitHub.

## What each check means

| Check | Establishes | Does not establish |
| --- | --- | --- |
| Publication integrity | Allowed files, hashes, identity schema and local links | That all future submissions are safe to publish |
| Reproducible compilation | Exact outputs from exact inputs | Audit, contract tests or live chain state |
| Recorded runtime hash | Previously reconciled deployment identity | A fresh read or current issuer behavior |
| Explorer verification | Source correspondence reported by that explorer | Router allowlisting or economic safety |
| Secret scanning | No recognized pattern in the scanned scope | Impossibility of undiscovered sensitive material |

Runtime templates contain unresolved constructor immutables. Their SHA-256 is
over the lowercase hex string without `0x`, not bytecode bytes. Recorded onchain
runtime hashes are Ethereum code hashes (Keccak-256 over runtime bytes), with
constructor values filled in. These domains must not be treated as equivalent.

For a fresh chain match, resolve constructor-bound values/immutable offsets,
read the exact address at a pinned block, then compare instantiated runtime.
A token badge does not verify every component or depot. No new Sourcify full
match or independent audit is claimed by this source package.

## CI boundary

**Package integrity**, **Reproducible compilation** and **Secret scan** use
SHA-pinned actions, read-only permissions, non-persistent checkout credentials
and checksummed tools. They do not use repository secrets, publish packages,
deploy, sign or contact RPCs. Dependabot proposes CI-action changes only;
the frozen Solidity closure is not automatically updated.

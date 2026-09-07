# Contributing

This is the public record of deployed contracts, not the private development,
operator or launch repository. Contributions may improve documentation,
reproducibility tooling and precise public identity references.

1. Read [architecture](docs/ARCHITECTURE.md) and [verification](docs/VERIFICATION.md).
2. Branch from `main`, explain the change in a focused PR and run `npm run check`,
   `npm test` and the relevant reproduction checks.
3. Run redacted working-tree and full-history secret scans **before** pushing.
4. Keep licences and exact Solidity bytes intact. Do not format `src/`, `lib/`,
   `abi/` or standard compiler inputs.
5. Include only already-public identities. No future salts, signatures,
   transaction bundles, private paths or operational credentials.

`src/vnext/` and `CatchAssetEmissionVault` are historical compiler identifiers.
Renaming them for appearance invalidates byte-for-byte correspondence. The docs
call the latter **release custody**: paid inventory, not passive emissions.

CI has read-only permissions, pinned actions and checksummed tools. It never
deploys, signs or needs RPC credentials. These are publication/tooling tests,
not the private contract unit, invariant or fork-security test suite.

Changes to the deployed model need a separate reviewed version. Do not silently
replace a published version's sources or mutate release tags. Security-sensitive
reports follow [SECURITY.md](SECURITY.md), not a public PR.

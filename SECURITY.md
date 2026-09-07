# Security

## Report privately

Use [GitHub private vulnerability reporting](https://github.com/catch-exchange/catch-contracts/security/advisories/new).
Do not post a live exploit, private key, mnemonic, RPC credential, signature or
unpublished launch configuration in issues, discussions or pull requests.

Include source revision, chain ID/address, impact, prerequisites and a minimal
**local** reproduction where possible. Do not test by moving other people's
funds, disrupting a network or exploiting a live pool. Maintainers may request
more evidence through the private report.

This policy does not promise a bounty, response SLA, legal safe harbour or
permission to conduct otherwise unauthorized activity.

## Scope and limitations

This is the exact Family V1 source package, not a security certification. Build
reproduction does not prove runtime immutable values, current issuer behavior,
solvency, liquidity depth or routing approval. No independent audit is claimed.

Deployed contracts are immutable. Editing a file cannot upgrade them. A defect
may require incident communication and a separately reviewed deployment; it
must not be disguised as a documentation update. Underlying issuers, wallets,
routers and networks have separate risk boundaries. See [architecture](docs/ARCHITECTURE.md).

Keep evidence private while assessing impact and verify exact deployed
identities. Do not publish sensitive exploit material in CI artifacts. If a
secret is exposed, revoke/rotate it first; deleting a file is not sufficient.

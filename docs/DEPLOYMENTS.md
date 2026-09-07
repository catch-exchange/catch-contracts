# Deployed families

Canonical published record: [`deployments/robinhood.json`](../deployments/robinhood.json).
These are already-live families on **Robinhood Chain, chain ID 4663**. Identities
come from previously reconciled launch evidence, not a fresh chain query.

Shared factory: [`0x21acBCC6227Cf5D2Fb5eB876735edd04F7B49c12`](https://robinhoodchain.blockscout.com/address/0x21acBCC6227Cf5D2Fb5eB876735edd04F7B49c12?tab=contract).

| Family | cAsset address | Launch block | Market |
| --- | --- | --- | --- |
| cGOLD / GLD | `0xb44e29a0540c48054d9caec192cdbb18c68398ec` | 54,377,703 | [cGOLD](https://catch.exchange/robinhood/cgold) |
| cSPY / SPY | `0xad2a032b99ede1ce2f03d2f1ba5a1b790f98592e` | 56,240,325 | [cSPY](https://catch.exchange/robinhood/cspy) |

The JSON records all seven components and full pool IDs. Use it rather than a
truncated social-media address. Resolve pinned depots, authorities and each
underlying dependency during fresh diligence; do not infer them from a symbol,
this table or a token verification badge.

## Version correspondence

`sourceCommit` identifies the original private build revision for the launch
evidence. These are provenance identifiers, not links to private git history.
This public repo starts with a new root commit and `source-v*` publication tags.

The two launch revisions use the exported source closure/common targets.
Constructor values make component runtimes family-specific; uninstantiated
template hashes are not substitutes. See [verification](VERIFICATION.md).

Future records append only already-reconciled public identities. Unlaunched
salts, signatures, scripts and configuration do not belong here. Publishing a
JSON record does not launch or admit a family to the production indexer.

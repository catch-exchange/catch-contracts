# Deployed families

Canonical published record: [`deployments/robinhood.json`](../deployments/robinhood.json).
These are already-live families on **Robinhood Chain, chain ID 4663**. Identities
come from previously reconciled launch evidence, not a fresh chain query.

Shared factory: [`0x21acbcc6227cf5d2fb5eb876735edd04f7b49c12`](https://robinhoodchain.blockscout.com/address/0x21acbcc6227cf5d2fb5eb876735edd04f7b49c12?tab=contract).

| Family | cAsset address | Launch block | Market |
| --- | --- | --- | --- |
| cGOLD / GLD | `0xb44e29a0540c48054d9caec192cdbb18c68398ec` | 54,377,703 | [cGOLD](https://catch.exchange/robinhood/cgold) |
| cSPY / SPY | `0xad2a032b99ede1ce2f03d2f1ba5a1b790f98592e` | 56,240,325 | [cSPY](https://catch.exchange/robinhood/cspy) |
| cNVDA / NVDA | `0x842c2264f683e490432c15155de8ac6398da3c71` | 56,731,164 | [cNVDA](https://catch.exchange/robinhood/cnvda) |
| cEWY / EWY | `0x166bf4c32d522aea235b49cd6c06433ad6d4c739` | 56,740,009 | [cEWY](https://catch.exchange/robinhood/cewy) |
| cSGOV / SGOV | `0x99cbade570867b40c2964bead28d2df366d9f1a9` | 56,746,856 | [cSGOV](https://catch.exchange/robinhood/csgov) |
| cSLV / SLV | `0x2ff495777174a0db364e8c5590d8f99fbe685383` | 56,753,175 | [cSLV](https://catch.exchange/robinhood/cslv) |
| cETH / WETH | `0x7bdd230ac2e10f03ca3b1500ae72e3029dd706dc` | 56,758,296 | [cETH](https://catch.exchange/robinhood/ceth) |
| cPONS / PONS | `0x1b00622c9a3359261c19d3a6c3a2441073e250fb` | 56,770,825 | [cPONS](https://catch.exchange/robinhood/cpons) |
| cSPCX / SPCX | `0x76be0151a6a09d3da4adef47ab548b52546ce10d` | 56,779,410 | [cSPCX](https://catch.exchange/robinhood/cspcx) |
| cTSLA / TSLA | `0x96bee785764c73d300863032eaf99d6c31fd6d9b` | 56,785,837 | [cTSLA](https://catch.exchange/robinhood/ctsla) |
| cCATCH / CATCH | `0x604f247c496049ffe05e603a87fcd7926a3c9fb9` | 57,602,365 | [cCATCH](https://catch.exchange/robinhood/ccatch) |

The JSON records all seven components and full pool IDs. Use it rather than a
truncated social-media address. Resolve pinned depots, authorities and each
underlying dependency during fresh diligence; do not infer them from a symbol,
this table or a token verification badge.

## Version correspondence

`sourceCommit` identifies the original private build revision for the launch
evidence. These are provenance identifiers, not links to private git history.
This public repo starts with a new root commit and `source-v*` publication tags.

All eleven families use the exported source closure/common targets.
Source publication was checked for the first ten families on 7 September 2026
and cCATCH's seven components on 8 September 2026: see the
[provider-specific evidence](../verification/source-status.json) and
[depot exception](VERIFICATION.md#published-source-status).
Constructor values make component runtimes family-specific; uninstantiated
template hashes are not substitutes. See [verification](VERIFICATION.md).

The cCATCH launch transaction is
[`0xc8d039b0cd5cf1ba9ba3cbdcdcc6b2cb6a81e9692254a0d81ba52013e28261c2`](https://robinhoodchain.blockscout.com/tx/0xc8d039b0cd5cf1ba9ba3cbdcdcc6b2cb6a81e9692254a0d81ba52013e28261c2).
Its underlying CATCH token is `0xe9e5cfdca8fbee1f68a7c92d7316331d1aab5fb9`;
that external token is not one of the Family V1 contracts reproduced here.
cCATCH source visibility is not a claim of Uniswap routing approval.

Future records append only already-reconciled public identities. Unlaunched
salts, signatures, scripts and configuration do not belong here. Publishing a
JSON record does not launch or admit a family to the production indexer.

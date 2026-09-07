# Architecture

Catch is the protocol. A **family** is one cAsset, its fixed underlying token,
canonical pool and its own reserve, release and accounting contracts. A shared
factory does not make reserves fungible or bridge claims between chains.

## Shared infrastructure

[`CatchFamilyFactoryV1`](../src/vnext/CatchFamilyFactoryV1.sol) is the immutable,
governance-authorized launch and discovery contract. Seven code depots hold
creation code for the seven family components. The factory pins depot and
PoolManager runtime hashes, appends constructor arguments and deploys each
component with CREATE2. Depots are code storage, not proxies or holder vaults;
families do not delegate execution to them.

One atomic `launch` binds the graph, allocates inventory, initializes the exact
pool and locks the one-sided genesis position. It validates metadata,
18-decimal underlying, code identity, hook bits and permitted launch geometry.
These checks are not a complete review of the underlying issuer.

Economic policy and treasury/governance/safety destinations are fixed by the
factory. Family name, symbol, underlying, denomination and permitted geometry
vary. A policy change needs a new version, not an edit to this export.

## The seven family components

| Component | Responsibility | Custody / authority boundary |
| --- | --- | --- |
| [`CatchAsset`](../src/CatchAsset.sol) | Fixed-supply transferable cAsset | 1,000,000 preminted; no later mint; standard allowance checks |
| [`CatchAssetEmissionVault`](../src/CatchAssetEmissionVault.sol) | Inactive paid-release inventory | 900,000 allocation; only its once-bound controller releases it |
| [`CatchAssetReserveVault`](../src/CatchAssetReserveVault.sol) | Pro-rata underlying redemption | Actual underlying balance backs active claims; no Catch pause or sweep |
| [`CatchFamilyHookV1`](../src/vnext/CatchFamilyHookV1.sol) | Canonical pool's underlying-side charge | Swap-delta-aware integration; permissionless flush to fixed ledger |
| [`CatchFamilyLiquidityLockerV1`](../src/vnext/CatchFamilyLiquidityLockerV1.sol) | Permanent one-sided genesis position | Principal stays locked; fee collection is separate |
| [`CatchFamilyFeeLedgerV1`](../src/vnext/CatchFamilyFeeLedgerV1.sol) | Measured receipts and fixed destinations | Reserve, burns and treasury are separate accounting domains |
| [`CatchFamilyReleaseControllerV1`](../src/vnext/CatchFamilyReleaseControllerV1.sol) | Quotes and paid releases | Repeated coverage test, protected price and purchase-pause authority |

The curve library is compiled into the controller, not an eighth family custody
contract. The eight compiler targets here are the shared factory plus these
seven components. Depot runtime contains component **creation code**, not its
deployed runtime template. Operator depot-launch scripts are not included.

## Three independent actions

### Trade

A compatible router settles a swap with Uniswap v4 PoolManager. The registered
hook charges on the underlying leg. `flushDirect(poolId)` delivers accrued
underlying through the fixed ledger: 70% reserve, 30% treasury, with integer
rounding. Pool charges/impact are separate and belong in execution quotes.
Trading does **not** release inventory from release custody.

The locker's permissionless `collectAndAccount()` collects fees without
withdrawing principal. Underlying fees split 70% reserve / 30% treasury.
cAsset fees split 70% permanent burn / 30% treasury cAsset. External LP fees
are not Catch revenue.

### Purchase

The holder approves the controller and calls `buyRelease` with maximum
underlying input, minimum cAsset output, recipient and deadline. It checks
coverage, walks the 64-step inventory schedule, applies non-dilutive pricing
and routes payment through the ledger. Release custody transfers preminted
tokens to the recipient. Payment splits 70% reserve / 30% treasury, with the
reserve receiving the integer remainder.

Only this action advances paid release. A preview is not an execution
guarantee. There is no caller-selected maximum-steps argument; unspent maximum
input stays in the holder's wallet.

### Redeem

The holder approves the reserve and calls `redeem`. It calculates a pro-rata
underlying payout, pulls exactly the cAsset amount from the caller, burns it
in its own custody and checks delivery to the recipient. It needs no pool
buyer, USD oracle or open purchase gate. Catch cannot pause it; issuer
restrictions and chain failures still matter.

`transferFrom` and `burnFrom` are allowance-based operations, not an operator
seizure permission. `burnFromReserve` is restricted to the once-bound reserve;
the deployed reserve's redemption path actually calls `burn` after pulling the
caller's tokens. Release custody has no arbitrary-call or approval interface.
These observations explain the source; they are not proof against every defect
or compromised dependency.

## Supply and economics

Let `S` be current total supply, `U = 900,000 − cumulative released`, `A = S − U`
active claims, and `R` the reserve's underlying balance. Backing is `R / A`;
redeeming `q` pays `floor(q × R / A)` in raw units. Pool/treasury-held cAssets are
active claims; unreleased inventory is not. Locked principal and unsettled
claims are not added to `R`.

Coverage compares backing to 70% of the **raw first-step price** every time.
It is not a permanent activation flag, nor a pool-price/live-USD test. The raw
schedule uses an immutable launch denomination; protected pricing prevents new
purchases diluting backing. The [technical paper](https://catch.exchange/paper)
contains the full 16-band/64-step arithmetic and examples.

## Integration and trust boundaries

- Discovery: `FamilyLaunched`, `familyCount`, `familyIdAt`, `getFamily` and
  underlying/cAsset lookups. Family IDs bind chain, factory and underlying.
- Bind chain, factory, full pool key and component identities, not a ticker or
  arbitrary pool with the same assets.
- Use shared indexed projections for browsing; deduplicate chain reads and
  filter admitted families in the database. A family does not need a separate
  browser RPC loop. Frontend/BFF/indexer code is outside this repository.
- An unchanged underlying proxy runtime does **not** establish an unchanged
  beacon/implementation or issuer policy. Review each dependency separately.
- Governance launches and controls purchase pauses. Safety may pause purchases
  but cannot resume them. Different role addresses do not imply independent
  control when signer sets overlap.
- Hooks return swap deltas and reject unsupported partial fills. Verified
  source, local quoting and router admission are distinct; assess each deployed
  hook/address and route explicitly.

No cross-family guarantee, future CATCH-token entitlement, two-sided seed
liquidity or perpetual exit depth is implied. See [SECURITY.md](../SECURITY.md).

import assert from "node:assert/strict";
import { createHash } from "node:crypto";

export const roles = ["cAsset", "releaseVault", "reserveVault", "hook", "liquidityLocker", "feeLedger", "releaseController"];
export const hash = value => createHash("sha256").update(value).digest("hex");

export function checkBrandAsset(bytes) {
  assert(bytes.length < 2_000_000, "Brand asset exceeds publication limit");
  assert.equal(bytes.subarray(0, 8).toString("hex"), "89504e470d0a1a0a", "Expected PNG");
  assert.equal(hash(bytes), "50a2e059b5c2ea16f65ad2b7e4ab36f63b0b48f19ae4a89b1de294135a05064e", "Unapproved brand asset");
}

export function safePath(value) {
  assert(typeof value === "string" && value.length > 0, "Empty path");
  assert(!value.startsWith("/") && !value.includes("\\") && !value.includes(":"), "Non-relative path");
  assert(value.split("/").every(part => part && part !== "." && part !== ".."), "Unsafe path component");
  return value;
}

export function exactKeys(value, required, optional = []) {
  assert(value && typeof value === "object" && !Array.isArray(value), "Expected object");
  const permitted = new Set([...required, ...optional]);
  assert(Object.keys(value).every(key => permitted.has(key)), "Unexpected field in public record");
  assert(required.every(key => Object.hasOwn(value, key)), "Missing public record field");
}

export function validateDeployments(value) {
  exactKeys(value, ["schema", "chainId", "evidenceScope", "factory", "families"]);
  assert.equal(value.schema, "catch.public-source-deployments.v1");
  assert.equal(value.chainId, 4663);
  assert(typeof value.evidenceScope === "string" && value.evidenceScope.length > 0);
  const address = text => assert(/^0x[0-9a-fA-F]{40}$/.test(text) && !/^0x0{40}$/.test(text), "Invalid address");
  const digest = text => assert(/^0x[0-9a-f]{64}$/.test(text), "Invalid digest");
  const commit = text => assert(/^[0-9a-f]{40}$/.test(text), "Invalid provenance commit");
  exactKeys(value.factory, ["address", "runtimeCodeHash", "sourceCommit"]);
  address(value.factory.address); digest(value.factory.runtimeCodeHash); commit(value.factory.sourceCommit);
  assert(Array.isArray(value.families) && value.families.length > 0, "No launched families");
  const symbols = new Set(), addresses = new Set([value.factory.address.toLowerCase()]);
  for (const family of value.families) {
    exactKeys(family, ["symbol", "sourceCommit", "launchBlock", "poolId", "contracts"], ["launchTransactionHash"]);
    assert(/^c[A-Z0-9]{1,16}$/.test(family.symbol) && !symbols.has(family.symbol), "Invalid/duplicate symbol");
    symbols.add(family.symbol);
    commit(family.sourceCommit); digest(family.poolId);
    assert(Number.isSafeInteger(family.launchBlock) && family.launchBlock > 0, "Invalid launch block");
    if (family.launchTransactionHash) digest(family.launchTransactionHash);
    exactKeys(family.contracts, roles);
    for (const component of Object.values(family.contracts)) {
      exactKeys(component, ["address", "runtimeCodeHash"]);
      address(component.address); digest(component.runtimeCodeHash);
      assert(!addresses.has(component.address.toLowerCase()), "Duplicate component address");
      addresses.add(component.address.toLowerCase());
    }
  }
}

export function checkArtifact(target, artifact, abi) {
  assert(artifact?.evm?.bytecode && artifact?.evm?.deployedBytecode, "Missing compiler artifact");
  assert.equal(hash(artifact.evm.bytecode.object), target.creationBytecodeSha256, `Creation bytecode differs: ${target.role}`);
  assert.equal(hash(artifact.evm.deployedBytecode.object), target.runtimeTemplateSha256, `Runtime template differs: ${target.role}`);
  assert.deepEqual(artifact.abi, abi, `ABI differs: ${target.role}`);
  assert.deepEqual(artifact.evm.deployedBytecode.immutableReferences ?? {}, target.immutableReferences ?? {}, `Immutable layout differs: ${target.role}`);
}

// Source-publication evidence is separate from launch identities and router admission.
// Every permitted field is explicit: operator bundles cannot be copied into this record.
export function validateSourceStatus(value, deployments, build) {
  validateDeployments(deployments);
  exactKeys(value, ["schema", "chainId", "checkedAt", "evidenceSha256", "scope", "contracts", "depots"]);
  assert.equal(value.schema, "catch.public-source-verification.v1");
  assert.equal(value.chainId, deployments.chainId);
  const date = text => assert(typeof text === "string" && /^\d{4}-\d{2}-\d{2}T/.test(text) && Number.isFinite(Date.parse(text)), "Invalid evidence timestamp");
  const address = text => assert(/^0x[0-9a-f]{40}$/.test(text) && !/^0x0{40}$/.test(text), "Expected lowercase address");
  const digest = text => assert(/^0x[0-9a-f]{64}$/.test(text), "Invalid evidence digest");
  date(value.checkedAt);
  assert(/^[0-9a-f]{64}$/.test(value.evidenceSha256), "Invalid evidence checksum");
  assert.equal(value.scope, "Recorded source correspondence at the stated check times, not an audit, current-state guarantee or router admission.");
  const expected = new Map([[deployments.factory.address.toLowerCase(), { family: "sharedV1", role: "factory" }]]);
  for (const f of deployments.families) for (const role of roles) {
    expected.set(f.contracts[role].address.toLowerCase(), { family: f.symbol, role, transaction: f.launchTransactionHash });
  }
  assert(Array.isArray(value.contracts) && value.contracts.length === expected.size, "Incomplete exact-match directory");
  const seen = new Set();
  const explorer = a => `https://robinhoodchain.blockscout.com/address/${a}?tab=contract`;
  for (const c of value.contracts) {
    exactKeys(c, ["family", "component", "address", "creationTransactionHash", "standardInputSha256", "sourcify", "blockscout"]);
    address(c.address); digest(c.creationTransactionHash);
    const identity = expected.get(c.address);
    assert(identity && !seen.has(c.address), "Unknown/duplicate verified contract");
    seen.add(c.address);
    assert.equal(c.family, identity.family); assert.equal(c.component, identity.role);
    if (identity.transaction) assert.equal(c.creationTransactionHash, identity.transaction);
    assert.equal(c.standardInputSha256, build.targets.find(t => t.role === identity.role)?.inputSha256);
    exactKeys(c.sourcify, ["creationMatch", "runtimeMatch", "matchId", "verifiedAt", "checkedAt", "url"]);
    assert.equal(c.sourcify.creationMatch, "exact_match"); assert.equal(c.sourcify.runtimeMatch, "exact_match");
    assert(/^[1-9][0-9]*$/.test(c.sourcify.matchId), "Invalid Sourcify match ID");
    date(c.sourcify.verifiedAt); date(c.sourcify.checkedAt);
    assert.equal(c.sourcify.url, `https://repo.sourcify.dev/4663/${c.address}`);
    exactKeys(c.blockscout, ["status", "url"]);
    assert.equal(c.blockscout.status, "not-individually-rechecked-in-this-pass");
    assert.equal(c.blockscout.url, explorer(c.address));
  }
  assert(Array.isArray(value.depots) && value.depots.length === roles.length, "Incomplete depot directory");
  const depotRoles = new Set();
  for (const d of value.depots) {
    exactKeys(d, ["component", "address", "creationTransactionHash", "blockscout", "sourcify", "payload"]);
    assert(roles.includes(d.component) && !depotRoles.has(d.component), "Unknown/duplicate depot role");
    depotRoles.add(d.component); address(d.address); digest(d.creationTransactionHash);
    assert(!seen.has(d.address), "Duplicate depot address"); seen.add(d.address);
    exactKeys(d.blockscout, ["status", "checkedAt", "url"]);
    assert.equal(d.blockscout.status, "partial_match"); date(d.blockscout.checkedAt);
    assert.equal(d.blockscout.url, explorer(d.address));
    exactKeys(d.sourcify, ["status", "checkedAt"]);
    assert.equal(d.sourcify.status, "bytecode_length_mismatch"); date(d.sourcify.checkedAt);
    const p = d.payload, t = build.targets.find(target => target.role === d.component);
    exactKeys(p, ["artifact", "byteForByteMatch", "runtimeCodeHash", "componentCreationKeccak256", "pinnedRuntimeCodeHash", "onchainRuntimeBytes", "componentCreationBytes"]);
    assert.equal(p.artifact, `${t.source}:${t.contract}`); assert.equal(p.byteForByteMatch, true);
    digest(p.runtimeCodeHash); assert.equal(p.runtimeCodeHash, p.componentCreationKeccak256);
    assert.equal(p.runtimeCodeHash, p.pinnedRuntimeCodeHash);
    assert(Number.isSafeInteger(p.onchainRuntimeBytes) && p.onchainRuntimeBytes > 0, "Invalid payload length");
    assert.equal(p.onchainRuntimeBytes, p.componentCreationBytes);
  }
}

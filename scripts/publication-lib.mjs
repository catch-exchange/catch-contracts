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

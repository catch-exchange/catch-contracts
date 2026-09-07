import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { safePath, exactKeys, validateDeployments, checkArtifact, hash } from "../scripts/publication-lib.mjs";

const deployment = JSON.parse(await readFile(new URL("../deployments/robinhood.json", import.meta.url)));
test("only bounded relative paths", () => {
  assert.equal(safePath("src/CatchAsset.sol"), "src/CatchAsset.sol");
  for (const path of ["", "/tmp/file", "../private", "src/../key", "src//file", "C:\\key", "./file"]) assert.throws(() => safePath(path));
});
test("public schemas reject extra or missing fields", () => {
  exactKeys({ a: 1 }, ["a"]);
  assert.throws(() => exactKeys({ a: 1, extra: "not public" }, ["a"]));
  assert.throws(() => exactKeys({}, ["a"]));
});
test("known published deployment directory is structurally valid", () => validateDeployments(deployment));
test("private launch fields cannot enter public identities", () => {
  for (const extra of ["salt", "signature", "rpcUrl", "privateKey", "keystore"]) {
    const copy = structuredClone(deployment);
    copy.families[0][extra] = "not a real value";
    assert.throws(() => validateDeployments(copy));
  }
});
test("reject missing components, bad hashes and duplicate addresses", () => {
  const edits = [
    d => { delete d.families[0].contracts.hook; },
    d => { d.factory.runtimeCodeHash = "not a hash"; },
    d => { d.families[0].launchBlock = 0; },
    d => { d.families[1].contracts.cAsset.address = d.families[0].contracts.cAsset.address; },
    d => { d.families[0].contracts.cAsset.hidden = "not public"; },
  ];
  for (const edit of edits) { const copy = structuredClone(deployment); edit(copy); assert.throws(() => validateDeployments(copy)); }
});
test("bytecode, ABI and immutable layout must all match", () => {
  const abi = [{ type: "constructor", inputs: [] }];
  const artifact = { abi, evm: { bytecode: { object: "6000" }, deployedBytecode: { object: "6001", immutableReferences: {} } } };
  const target = { role: "fixture", creationBytecodeSha256: hash("6000"), runtimeTemplateSha256: hash("6001"), immutableReferences: {} };
  checkArtifact(target, artifact, abi);
  assert.throws(() => checkArtifact(target, artifact, []));
  assert.throws(() => checkArtifact({ ...target, runtimeTemplateSha256: hash("6002") }, artifact, abi));
  assert.throws(() => checkArtifact({ ...target, immutableReferences: { "1": [{ start: 1, length: 32 }] } }, artifact, abi));
});

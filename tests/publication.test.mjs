import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { safePath, exactKeys, validateDeployments, validateSourceStatus, checkArtifact, hash, checkBrandAsset } from "../scripts/publication-lib.mjs";

const deployment = JSON.parse(await readFile(new URL("../deployments/robinhood.json", import.meta.url)));
const sourceStatus = JSON.parse(await readFile(new URL("../verification/source-status.json", import.meta.url)));
const build = JSON.parse(await readFile(new URL("../verification/build-manifest.json", import.meta.url)));
test("eleven live families have exact per-address source evidence, with depots separate", () => {
  assert.deepEqual(deployment.families.map(f => f.symbol), ["cGOLD", "cSPY", "cNVDA", "cEWY", "cSGOV", "cSLV", "cETH", "cPONS", "cSPCX", "cTSLA", "cCATCH"]);
  assert.equal(sourceStatus.contracts.length, 78); assert.equal(sourceStatus.depots.length, 7);
  validateSourceStatus(sourceStatus, deployment, build);
});
test("published evidence checksum covers every contract and depot record", () => {
  assert.equal(sourceStatus.evidenceSha256, hash(JSON.stringify({ contracts: sourceStatus.contracts, depots: sourceStatus.depots })));
});
test("cCATCH records the reconciled launch and preserves actual check times", () => {
  const family = deployment.families.find(f => f.symbol === "cCATCH");
  assert.equal(family.contracts.cAsset.address, "0x604f247c496049ffe05e603a87fcd7926a3c9fb9");
  assert.equal(family.launchBlock, 57602365);
  assert.equal(family.launchTransactionHash, "0xc8d039b0cd5cf1ba9ba3cbdcdcc6b2cb6a81e9692254a0d81ba52013e28261c2");
  assert.equal(sourceStatus.contracts.filter(c => c.family === "cCATCH").length, 7);
  for (const c of sourceStatus.contracts) {
    assert(c.sourcify.checkedAt.startsWith(c.family === "cCATCH" ? "2026-09-08" : "2026-09-07"));
  }
});
test("verification cannot imply completeness, exactness or provider admission without evidence", () => {
  const edits = [
    v => v.contracts.pop(),
    v => { v.contracts[1] = v.contracts[0]; },
    v => { v.contracts[0].family = "cUNLAUNCHED"; },
    v => { v.contracts[0].standardInputSha256 = "0".repeat(64); },
    v => { v.contracts[0].sourcify.runtimeMatch = "partial_match"; },
    v => { v.contracts[0].sourcify.url = "https://example.com"; },
    v => { v.contracts[0].blockscout.status = "exact_match"; },
    v => { v.depots[0].sourcify.status = "exact_match"; },
    v => { v.depots[0].payload.byteForByteMatch = false; },
    v => { v.depots[0].payload.componentCreationBytes += 1; },
    v => { v.depots[0].payload.pinnedRuntimeCodeHash = "0x" + "0".repeat(64); },
    v => { v.depots[1].component = v.depots[0].component; },
    v => { v.depots[0].address = v.contracts[0].address; },
    v => { v.contracts[0].routerApproved = true; },
  ];
  for (const edit of edits) { const copy = structuredClone(sourceStatus); edit(copy); assert.throws(() => validateSourceStatus(copy, deployment, build)); }
});
test("source evidence rejects private and unreviewed nested fields", () => {
  for (const name of ["salt", "signature", "rpcUrl", "privateKey", "bundlePath"]) {
    for (const select of [v => v, v => v.contracts[0], v => v.contracts[0].sourcify, v => v.depots[0].payload]) {
      const copy = structuredClone(sourceStatus); select(copy)[name] = "not a real value";
      assert.throws(() => validateSourceStatus(copy, deployment, build));
    }
  }
});
test("only the exact approved public PNG is permitted", async () => {
  const bytes = await readFile(new URL("../assets/catch-market-standard.png", import.meta.url));
  checkBrandAsset(bytes);
  const changed = Buffer.from(bytes); changed[changed.length - 1] ^= 1;
  assert.throws(() => checkBrandAsset(changed));
  assert.throws(() => checkBrandAsset(Buffer.from("not a PNG")));
});
test("testing evidence separates invariant and simulator results", async () => {
  const result = JSON.parse(await readFile(new URL("../verification/testing-summary.json", import.meta.url)));
  assert.equal(result.sourceFilesMatched, 36);
  assert.equal(result.solidity.passed, 40);
  assert.equal(result.solidity.invariants.length, 6);
  assert.equal(result.simulators.passed, 10);
  assert.equal(result.freshForkRun, false);
  assert.equal(result.privateHarnessesIncluded, false);
  for (const item of result.solidity.invariants) {
    assert.equal(item.runs, 256); assert.equal(item.calls, 128000); assert.equal(item.reverts, 0);
  }
});
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

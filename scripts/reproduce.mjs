// Offline compiler reproduction. No wallet, RPC or package installation.
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { hash, safePath, checkArtifact } from "./publication-lib.mjs";

const root = new URL("../", import.meta.url);
const read = path => readFile(new URL(safePath(path), root));
const compiler = process.env.SOLC ?? "solc";
const version = execFileSync(compiler, ["--version"], { encoding: "utf8", timeout: 10_000 });
assert.match(version, /0\.8\.26\+commit\.8a97fa7a(?:\.|\s|$)/, "Wrong compiler version");
const manifest = JSON.parse(await read("verification/build-manifest.json"));
for (const [path, expected] of Object.entries(manifest.sources)) {
  assert.equal(hash(await read(path)), expected, `Source changed: ${path}`);
}
for (const target of manifest.targets) {
  const input = await read(target.input);
  assert.equal(hash(input), target.inputSha256, `Input changed: ${target.role}`);
  for (const [path, value] of Object.entries(JSON.parse(input).sources)) {
    assert.equal(hash(value.content), manifest.sources[path], `Input/source mismatch: ${path}`);
  }
  const output = execFileSync(compiler, ["--standard-json"], {
    input, encoding: "utf8", timeout: 180_000, maxBuffer: 32 * 1024 * 1024,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const result = JSON.parse(output);
  assert(!(result.errors ?? []).some(error => error.severity === "error"), `Compiler error: ${target.role}`);
  const abi = JSON.parse(await read(`abi/${target.role}.json`));
  checkArtifact(target, result.contracts?.[target.source]?.[target.contract], abi);
  console.log(`PASS ${target.role}: creation code, runtime template, ABI and immutable layout`);
}
console.log("All eight targets reproduced. This is not a contract audit or fresh onchain/explorer check.");

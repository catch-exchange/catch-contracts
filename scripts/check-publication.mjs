// Offline, fail-closed allowlist for the tracked public package, not a secret scanner.
import assert from "node:assert/strict";
import { readFile, lstat } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { dirname, resolve, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { hash, roles, safePath, validateDeployments } from "./publication-lib.mjs";

const root = fileURLToPath(new URL("../", import.meta.url));
const read = path => readFile(resolve(root, safePath(path)));
const manifest = JSON.parse(await read("verification/build-manifest.json"));
assert.equal(manifest.schema, "catch.reproducible-compiler-inputs.v1");
assert.equal(manifest.compiler, "0.8.26+commit.8a97fa7a");
assert.equal(Object.keys(manifest.sources).length, 36);
assert.deepEqual(manifest.targets.map(t => t.role).sort(), [...roles, "factory"].sort());
const allowed = new Set([
  ".editorconfig", ".gitattributes", ".gitignore", ".gitleaks.toml", ".nvmrc", "package.json",
  "README.md", "LICENSE", "NOTICE.md", "SECURITY.md", "CONTRIBUTING.md", "PUBLISH_CHECKLIST.md",
  "licenses/Uniswap-MIT.txt", "deployments/robinhood.json", "verification/build-manifest.json", "verification/toolchain.json",
  "docs/ARCHITECTURE.md", "docs/DEPLOYMENTS.md", "docs/VERIFICATION.md", "docs/RELEASING.md",
  "scripts/reproduce.mjs", "scripts/download-tool.mjs", "scripts/check-publication.mjs", "scripts/publication-lib.mjs",
  "tests/publication.test.mjs", ".github/CODEOWNERS", ".github/dependabot.yml", ".github/pull_request_template.md",
  ".github/ISSUE_TEMPLATE/config.yml", ".github/ISSUE_TEMPLATE/documentation.yml", ".github/workflows/verify.yml",
  ...Object.keys(manifest.sources),
  ...manifest.targets.flatMap(t => [t.input, `abi/${t.role}.json`]),
]);
const tracked = execFileSync("git", ["ls-files", "--stage", "-z"], { cwd: root, encoding: "utf8" }).split("\0").filter(Boolean);
const files = tracked.map(entry => {
  const [meta, path] = entry.split("\t");
  assert(/^100644 [0-9a-f]+ 0$/.test(meta), "Only regular non-executable tracked files are permitted");
  safePath(path);
  assert(allowed.has(path), `File not approved for publication: ${path}`);
  return path;
});
assert.equal(files.length, allowed.size, "Stage all approved files; package is incomplete or duplicated");
for (const path of files) {
  const stat = await lstat(resolve(root, path));
  assert(stat.isFile() && !stat.isSymbolicLink() && stat.size < 2_000_000, `Unexpected file type/size: ${path}`);
  const content = await read(path);
  assert(!content.includes(0), `Binary content: ${path}`);
  const text = content.toString("utf8");
  assert(!/(?:\/Users\/|\/home\/)[a-zA-Z0-9_-]+\//.test(text), `Private machine path: ${path}`);
  assert(!/https?:\/\/[^\s/]+:[^\s/]+@/.test(text), `Credential-bearing URL: ${path}`);
  if (path.endsWith(".md")) {
    for (const match of text.matchAll(/\]\(([^\s)]+)\)/g)) {
      const href = match[1];
      if (/^https?:\/\//.test(href) || href.startsWith("#")) continue;
      const target = relative(root, resolve(root, dirname(path), decodeURIComponent(href.split("#")[0])));
      safePath(target);
      assert(allowed.has(target), `Broken/unapproved local link in ${path}`);
    }
  }
}
for (const [path, expected] of Object.entries(manifest.sources)) {
  assert.equal(hash(await read(path)), expected, `Source changed: ${path}`);
}
for (const target of manifest.targets) {
  const input = await read(target.input);
  assert.equal(hash(input), target.inputSha256, `Compiler input changed: ${target.role}`);
  const parsed = JSON.parse(input);
  for (const [path, source] of Object.entries(parsed.sources)) {
    assert.equal(hash(source.content), manifest.sources[path], `Embedded source differs: ${path}`);
    assert.deepEqual(Object.keys(source), ["content"], "Embedded source must not use external URLs");
  }
  assert(Array.isArray(JSON.parse(await read(`abi/${target.role}.json`))), "Invalid ABI export");
}
validateDeployments(JSON.parse(await read("deployments/robinhood.json")));
const workflow = (await read(".github/workflows/verify.yml")).toString();
assert(!/secrets\s*\.|pull_request_target|:\s*write\b/.test(workflow), "CI exceeds read-only publication scope");
assert.match(workflow, /permissions:\s*\n\s+contents: read/);
for (const action of workflow.matchAll(/uses:\s*([^\s#]+)/g)) assert.match(action[1], /^actions\/[a-z-]+@[0-9a-f]{40}$/);
console.log(`PASS ${files.length} allowlisted files, 36 exact sources, 8 exact compiler inputs, public identities and local links`);
console.log("Run the separate compiler reproduction and full-history secret scan before publishing.");

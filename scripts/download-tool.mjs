// Fetch a pinned public tool and verify all bytes before use. No account or RPC.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { chmod, mkdir, readFile, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { execFileSync } from "node:child_process";

const [name, directory] = process.argv.slice(2);
assert(["solc", "gitleaks"].includes(name) && directory, "Usage: node scripts/download-tool.mjs solc|gitleaks OUTPUT_DIRECTORY");
const config = JSON.parse(await readFile(new URL("../verification/toolchain.json", import.meta.url)));
const tool = config[name][`${process.platform}-${process.arch}`];
assert(tool, "Unsupported platform: install the exact tool manually using its official distribution");
const response = await fetch(tool.url, { signal: AbortSignal.timeout(60_000) });
assert(response.ok, `Tool download failed: HTTP ${response.status}`);
const bytes = Buffer.from(await response.arrayBuffer());
assert.equal(createHash("sha256").update(bytes).digest("hex"), tool.sha256, "Tool checksum mismatch; refusing execution");
const destination = resolve(directory);
await mkdir(destination, { recursive: true });
const binary = join(destination, name);
if (name === "gitleaks") {
  const archive = join(destination, "gitleaks.tar.gz");
  await writeFile(archive, bytes, { mode: 0o600 });
  // Extract only the single known member, never arbitrary archive paths.
  execFileSync("tar", ["-xzf", archive, "-C", destination, "gitleaks"]);
} else {
  await writeFile(binary, bytes, { mode: 0o700 });
}
await chmod(binary, 0o700);
console.log(binary);

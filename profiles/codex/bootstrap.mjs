import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const configDir = process.argv[2];
if (!configDir) throw new Error("configuration directory is required");
await mkdir(configDir, { recursive: true });

// Defaults for config.toml. A key the user already set at the top level wins.
// TOML needs top-level keys before the first table, so missing ones are
// prepended rather than appended.
const defaults = {
  // Codex's own sandbox (bubblewrap) needs user namespaces, which the
  // container does not grant. rapunzel's container is the boundary; Codex's
  // approval prompts stay on.
  sandbox_mode: '"danger-full-access"',
  // There is no keyring in the container; keep logins in the volume.
  cli_auth_credentials_store: '"file"',
  check_for_update_on_startup: "false",
  analytics: "{ enabled = false }",
};

const file = join(configDir, "config.toml");
let text = "";
try {
  text = await readFile(file, "utf8");
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
const firstTable = text.search(/^\s*\[/m);
const topLevel = firstTable === -1 ? text : text.slice(0, firstTable);
const missing = Object.entries(defaults).filter(
  ([key]) => !new RegExp(`^\\s*${key}\\s*=`, "m").test(topLevel) &&
    !(key === "analytics" && /^\s*\[analytics\]/m.test(text)),
);
if (missing.length > 0) {
  const lines = missing.map(([key, value]) => `${key} = ${value}`).join("\n");
  await writeFile(file, `${lines}\n${text ? `\n${text}` : ""}`, { mode: 0o600 });
}

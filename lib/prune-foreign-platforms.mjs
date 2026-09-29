// Remove installed packages whose package.json `os`/`cpu` exclude this platform.
//
// pi ships an npm-shrinkwrap.json, and npm installs every optional platform
// package listed there on a global install (all 26 @esbuild/* binaries, about
// 270 MB) instead of only the one matching the build platform. Build-time only;
// run as the last step of the npm install layer.
import { existsSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { join } from "node:path";

const root = process.argv[2];
if (!root) throw new Error("node_modules directory is required");

// npm semantics: a list of plain names is an allowlist, "!name" entries are a denylist.
function excludes(list, value) {
  if (!Array.isArray(list) || list.length === 0) return false;
  if (list.some((entry) => entry.startsWith("!"))) return list.includes(`!${value}`);
  return !list.includes(value);
}

function prune(modulesDir) {
  if (!existsSync(modulesDir)) return;
  for (const entry of readdirSync(modulesDir)) {
    const packages = entry.startsWith("@")
      ? readdirSync(join(modulesDir, entry)).map((name) => join(modulesDir, entry, name))
      : [join(modulesDir, entry)];
    for (const directory of packages) {
      let meta;
      try {
        meta = JSON.parse(readFileSync(join(directory, "package.json"), "utf8"));
      } catch {
        continue;
      }
      if (excludes(meta.os, process.platform) || excludes(meta.cpu, process.arch)) {
        rmSync(directory, { recursive: true, force: true });
        console.log(`pruned ${meta.name}`);
      } else {
        prune(join(directory, "node_modules"));
      }
    }
  }
}

prune(root);

import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

const configDir = process.argv[2];
if (!configDir) throw new Error("configuration directory is required");
await mkdir(configDir, { recursive: true });

// dsh attaches the session log to requests against the official DeepSeek API
// by default. Seed a home-level patch that turns this off, once; the file is
// the user's afterwards, and deleting the row turns uploads back on.
const file = join(configDir, "cordis.patch.yml");
const seed = `# Seeded by rapunzel. Home-level dsh overrides for every profile.
# Session-log upload to the official DeepSeek API is off; remove this row to
# turn it back on.
- id: session-log-deepseek
  config:
    enabled: false
`;
try {
  await writeFile(file, seed, { flag: "wx", mode: 0o644 });
} catch (error) {
  if (error.code !== "EEXIST") throw error;
}

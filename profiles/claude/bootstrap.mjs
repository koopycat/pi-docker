import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";

const configDir = process.argv[2];
if (!configDir) throw new Error("configuration directory is required");
await mkdir(configDir, { recursive: true });

// With a credential from the host (CLAUDE_CODE_OAUTH_TOKEN from
// `claude setup-token`, or ANTHROPIC_API_KEY), first-run onboarding would still
// ask for a login method. Mark onboarding done so the credential is used as is.
// Without one, leave onboarding alone so /login stays reachable.
const env = process.env;
if (env.CLAUDE_CODE_OAUTH_TOKEN?.trim() || env.ANTHROPIC_API_KEY?.trim()) {
  const file = join(configDir, ".claude.json");
  let state = {};
  try {
    state = JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  if (state.hasCompletedOnboarding !== true) {
    state.hasCompletedOnboarding = true;
    await writeFile(file, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  }
}

import { mkdir, readFile, writeFile, chmod } from "node:fs/promises";
import { join } from "node:path";

const configDir = process.argv[2];
if (!configDir) throw new Error("configuration directory is required");

await mkdir(configDir, { recursive: true });
for (const name of ["sessions", "extensions", "skills", "prompts", "themes"]) {
  await mkdir(join(configDir, name), { recursive: true });
}

const env = process.env;
const provider = env.PI_DOCKER_PROVIDER?.trim();
const modelId = (env.PI_DOCKER_MODEL || env.PI_DOCKER_MODEL_ID)?.trim();
const baseUrl = (
  env.PI_DOCKER_API_BASE_URL ||
  env.PI_DOCKER_BASE_URL ||
  env.KILOCODE_API_BASE_URL
)?.trim();
const api = (env.PI_DOCKER_API || "openai-completions").trim();
const apiKeyVariable = (env.PI_DOCKER_API_KEY_VARIABLE || "PI_DOCKER_API_KEY").trim();

function numericEnv(name, fallback) {
  const raw = env[name]?.trim();
  if (!raw) return fallback;

  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be a positive number, got ${JSON.stringify(env[name])}`);
  }
  return value;
}

function jsonEnv(name) {
  try {
    return JSON.parse(env[name]);
  } catch (error) {
    throw new Error(`${name} must contain valid JSON: ${error.message}`);
  }
}

const modelsPath = join(configDir, "models.json");
let models = { providers: {} };
try {
  models = JSON.parse(await readFile(modelsPath, "utf8"));
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}
models.providers ??= {};

let providerConfigured = false;
if (provider && baseUrl && modelId) {
  const model = {
    id: modelId,
    name: env.PI_DOCKER_MODEL_NAME?.trim() || modelId,
    reasoning: env.PI_DOCKER_REASONING === "1" || env.PI_DOCKER_REASONING === "true",
    input: ["text"],
    contextWindow: numericEnv("PI_DOCKER_CONTEXT_WINDOW", 128000),
    maxTokens: numericEnv("PI_DOCKER_MAX_TOKENS", 16384),
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  };

  const providerConfig = {
    baseUrl,
    api,
    apiKey: `$${apiKeyVariable}`,
    models: [model],
  };

  if (env.PI_DOCKER_COMPAT_JSON) {
    providerConfig.compat = jsonEnv("PI_DOCKER_COMPAT_JSON");
  }
  if (env.PI_DOCKER_HEADERS_JSON) {
    providerConfig.headers = jsonEnv("PI_DOCKER_HEADERS_JSON");
  }
  if (env.PI_DOCKER_AUTH_HEADER === "1" || env.PI_DOCKER_AUTH_HEADER === "true") {
    providerConfig.authHeader = true;
  }

  models.providers[provider] = {
    ...(models.providers[provider] ?? {}),
    ...providerConfig,
  };
  providerConfigured = true;
}

await writeFile(modelsPath, `${JSON.stringify(models, null, 2)}\n`, { mode: 0o600 });
await chmod(modelsPath, 0o600);

const settingsPath = join(configDir, "settings.json");
let settings = {};
try {
  settings = JSON.parse(await readFile(settingsPath, "utf8"));
} catch (error) {
  if (error.code !== "ENOENT") throw error;
}

if (providerConfigured) {
  settings.defaultProvider ??= provider;
  settings.defaultModel ??= `${provider}/${modelId}`;
}
settings.defaultProjectTrust ??= "ask";
settings.enableAnalytics ??= false;
settings.quietStartup ??= false;
settings.sessionDir ??= "sessions";
await writeFile(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, { mode: 0o600 });
await chmod(settingsPath, 0o600);

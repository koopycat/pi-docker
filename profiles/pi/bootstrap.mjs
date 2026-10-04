import { mkdir, readFile, writeFile, chmod } from "node:fs/promises";
import { isAbsolute, join } from "node:path";

const configDir = process.argv[2];
if (!configDir) throw new Error("configuration directory is required");

await mkdir(configDir, { recursive: true });
for (const name of ["sessions", "extensions", "skills", "prompts", "themes"]) {
  await mkdir(join(configDir, name), { recursive: true });
}

const env = process.env;
const provider = env.RAPUNZEL_PROVIDER?.trim();
const modelId = (env.RAPUNZEL_MODEL || env.RAPUNZEL_MODEL_ID)?.trim();
const baseUrl = (
  env.RAPUNZEL_API_BASE_URL ||
  env.RAPUNZEL_BASE_URL
)?.trim();
const api = (env.RAPUNZEL_API || "openai-completions").trim();
const apiKeyVariable = (env.RAPUNZEL_API_KEY_VARIABLE || "RAPUNZEL_API_KEY").trim();

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
    name: env.RAPUNZEL_MODEL_NAME?.trim() || modelId,
    reasoning: env.RAPUNZEL_REASONING === "1" || env.RAPUNZEL_REASONING === "true",
    input: ["text"],
    contextWindow: numericEnv("RAPUNZEL_CONTEXT_WINDOW", 128000),
    maxTokens: numericEnv("RAPUNZEL_MAX_TOKENS", 16384),
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
  };

  const providerConfig = {
    baseUrl,
    api,
    apiKey: `$${apiKeyVariable}`,
    models: [model],
  };

  if (env.RAPUNZEL_COMPAT_JSON) {
    providerConfig.compat = jsonEnv("RAPUNZEL_COMPAT_JSON");
  }
  if (env.RAPUNZEL_HEADERS_JSON) {
    providerConfig.headers = jsonEnv("RAPUNZEL_HEADERS_JSON");
    const sensitive = /(authorization|token|secret|api[-_]?key|password|bearer)/i;
    const risky = Object.entries(providerConfig.headers).some(
      ([key, value]) => sensitive.test(key) || (typeof value === "string" && /^bearer\s/i.test(value)),
    );
    if (risky) {
      console.warn(
        "rapunzel: RAPUNZEL_HEADERS_JSON appears to contain a credential; it is stored in plaintext at models.json (mode 0600) inside the agent volume.",
      );
    }
  }
  if (env.RAPUNZEL_AUTH_HEADER === "1" || env.RAPUNZEL_AUTH_HEADER === "true") {
    providerConfig.authHeader = true;
  }

  models.providers[provider] = {
    ...(models.providers[provider] ?? {}),
    ...providerConfig,
  };
  providerConfigured = true;
}

// Built-in providers the credential gateway serves. The entries are rewritten
// on every start, so an edit made from inside the sandbox does not persist.
const gatewayUrl = env.RAPUNZEL_GATEWAY_URL?.trim();
const gatewayProviders = new Set(
  (env.RAPUNZEL_GATEWAY_PROVIDERS ?? "").split(",").map((name) => name.trim()).filter(Boolean),
);
const gatewayKey = "rapunzel-gateway";
const gatewayRoutes = { anthropic: "/anthropic", openai: "/openai/v1" };
for (const [name, route] of Object.entries(gatewayRoutes)) {
  const entry = models.providers[name];
  if (gatewayUrl && gatewayProviders.has(name)) {
    models.providers[name] = { ...(entry ?? {}), baseUrl: `${gatewayUrl}${route}`, apiKey: gatewayKey };
  } else if (entry?.apiKey === gatewayKey) {
    // Drop the override an earlier gateway run left behind.
    delete entry.baseUrl;
    delete entry.apiKey;
    if (Object.keys(entry).length === 0) delete models.providers[name];
  }
}

if (gatewayUrl) {
  try {
    const auth = JSON.parse(await readFile(join(configDir, "auth.json"), "utf8"));
    if (Object.keys(auth).length > 0) {
      console.warn(
        "rapunzel: auth.json in the agent volume holds /login credentials inside the sandbox; the gateway cannot keep those out. Run /logout for each provider to remove them.",
      );
    }
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
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
// pi resolves a relative sessionDir from the working directory, which is the
// mounted project, so sessions would land on the host. Keep them in the agent
// volume, and repair the relative "sessions" older versions wrote.
if (!settings.sessionDir || !isAbsolute(settings.sessionDir)) {
  settings.sessionDir = join(configDir, "sessions");
}
await writeFile(settingsPath, `${JSON.stringify(settings, null, 2)}\n`, { mode: 0o600 });
await chmod(settingsPath, 0o600);

import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";

const stateDir = process.argv[2];
if (!stateDir) throw new Error("state directory is required");

// The image points OPENCODE_CONFIG at this file, which opencode merges over
// the user's opencode.json. rapunzel owns it and rewrites it on every start
// from the environment alone, so the user's own config is never edited and a
// provider removed from the env file leaves nothing behind.
const dir = join(stateDir, "rapunzel");
const file = join(dir, "opencode.json");
const cacheFile = join(dir, "models-cache.json");
await mkdir(dir, { recursive: true });

const env = process.env;
const warn = (message) => console.warn(`rapunzel: ${message}`);

async function writeJson(path, value) {
  const tmp = `${path}.${process.pid}.tmp`;
  await writeFile(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(tmp, path);
}

function numericEnv(name) {
  const raw = env[name]?.trim();
  if (!raw) return undefined;
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be a positive number, got ${JSON.stringify(env[name])}`);
  }
  return value;
}

const positive = (value) => (Number.isFinite(value) && value > 0 ? value : undefined);

// One /models entry as an opencode model. OpenAI's list has only ids; routers
// such as OmniRoute add a name, limits, and capabilities, which are used when
// present.
function modelFromListing(entry) {
  const model = {};
  if (typeof entry.name === "string" && entry.name.trim()) model.name = entry.name.trim();
  const context = positive(entry.context_length);
  const output = positive(entry.max_output_tokens);
  if (context && output) model.limit = { context, output };
  const capabilities = entry.capabilities ?? {};
  if (typeof capabilities.tool_calling === "boolean") model.tool_call = capabilities.tool_calling;
  if (typeof capabilities.reasoning === "boolean") model.reasoning = capabilities.reasoning;
  return model;
}

const validId = (id) => typeof id === "string" && id.length > 0 && id.length <= 200 && !/[\u0000-\u001f\u007f]/.test(id);

async function listModels(baseUrl, keyVariable) {
  const headers = {};
  const key = env[keyVariable]?.trim();
  if (key) headers.Authorization = `Bearer ${key}`;
  const response = await fetch(`${baseUrl.replace(/\/+$/, "")}/models`, {
    headers,
    signal: AbortSignal.timeout(5000),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const body = await response.json();
  if (!Array.isArray(body?.data)) throw new Error("no data array in the response");
  const models = {};
  for (const entry of body.data.slice(0, 1000)) {
    if (validId(entry?.id)) models[entry.id] = modelFromListing(entry);
  }
  return models;
}

const baseUrl = (env.RAPUNZEL_API_BASE_URL || env.RAPUNZEL_BASE_URL)?.trim();
if (!baseUrl) {
  await writeJson(file, {});
  process.exit(0);
}

const api = (env.RAPUNZEL_API || "openai-completions").trim();
if (api !== "openai-completions") {
  warn(`RAPUNZEL_API=${api} is not supported for opencode; only openai-completions is. No provider configured.`);
  await writeJson(file, {});
  process.exit(0);
}

const providerId = (env.RAPUNZEL_PROVIDER || "custom").trim();
if (!/^[a-z0-9][a-z0-9._-]*$/.test(providerId)) {
  throw new Error(`RAPUNZEL_PROVIDER must be a lowercase provider id, got ${JSON.stringify(providerId)}`);
}
const keyVariable = (env.RAPUNZEL_API_KEY_VARIABLE || "RAPUNZEL_API_KEY").trim();
if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(keyVariable)) {
  throw new Error(`RAPUNZEL_API_KEY_VARIABLE is not a variable name: ${JSON.stringify(keyVariable)}`);
}

const modelId = (env.RAPUNZEL_MODEL || env.RAPUNZEL_MODEL_ID)?.trim();
let models = {};
let source;
let fetched = false;
try {
  models = await listModels(baseUrl, keyVariable);
  source = `${Object.keys(models).length} models from ${baseUrl}`;
  fetched = true;
  await writeJson(cacheFile, { baseUrl, models });
} catch (error) {
  // fetch wraps the useful reason, such as the proxy's 403, a few causes deep.
  let innermost = error;
  while (innermost.cause instanceof Error) innermost = innermost.cause;
  const reason = innermost.message || innermost.code || String(error);
  let hint = "";
  if (env.HTTPS_PROXY) {
    hint = "; in allowlist mode, a host that resolves to a private address needs RAPUNZEL_EGRESS_ALLOW_PRIVATE";
  }
  let cached;
  try {
    cached = JSON.parse(await readFile(cacheFile, "utf8"));
  } catch {
    // Missing or unreadable; the next successful listing rewrites it.
  }
  if (cached?.baseUrl === baseUrl && cached.models && typeof cached.models === "object") {
    // The cache is in the agent-writable volume; keep only the fields a
    // listing can produce.
    for (const [id, entry] of Object.entries(cached.models)) {
      if (!validId(id) || !entry || typeof entry !== "object") continue;
      models[id] = modelFromListing({
        name: entry.name,
        context_length: entry.limit?.context,
        max_output_tokens: entry.limit?.output,
        capabilities: { tool_calling: entry.tool_call, reasoning: entry.reasoning },
      });
    }
    source = `${Object.keys(models).length} cached models`;
    warn(`warning: could not list models from ${baseUrl}/models (${reason})${hint}; using ${source}`);
  } else {
    source = modelId ? `only ${modelId}` : "no models";
    warn(`warning: could not list models from ${baseUrl}/models (${reason})${hint}; nothing cached, offering ${source}`);
  }
}

if (modelId) {
  const model = { ...(models[modelId] ?? {}) };
  const name = env.RAPUNZEL_MODEL_NAME?.trim();
  if (name) model.name = name;
  const context = numericEnv("RAPUNZEL_CONTEXT_WINDOW");
  const output = numericEnv("RAPUNZEL_MAX_TOKENS");
  if (context || output) {
    model.limit = { ...(model.limit ?? { context: 128000, output: 16384 }) };
    if (context) model.limit.context = context;
    if (output) model.limit.output = output;
  }
  models[modelId] = model;
}

const config = {
  $schema: "https://opencode.ai/config.json",
  provider: {
    [providerId]: {
      npm: "@ai-sdk/openai-compatible",
      name: providerId,
      // The key stays in the environment; opencode substitutes it at load time.
      options: { baseURL: baseUrl, apiKey: `{env:${keyVariable}}` },
      models,
    },
  },
};
if (modelId) config.model = `${providerId}/${modelId}`;
await writeJson(file, config);
// A failed listing has already said which models are used.
if (fetched) console.warn(`rapunzel: opencode provider ${providerId}: ${source}`);

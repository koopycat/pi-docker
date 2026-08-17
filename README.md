# Isolated pi Docker runner

This repository provides a small Docker image and a `pi-project` wrapper for running the pi coding agent with one project bind-mounted into the container.

The design follows pi's official [Plain Docker](https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/containerization.md) pattern, while adding a non-root runtime user, an isolated named volume, runtime provider configuration, and an isolation check.

## Quick start

Build the image:

```bash
docker build -t pi-project-sandbox .
```

Run pi against a project:

```bash
./pi-project ~/src/my-project
```

Pass normal pi arguments after the project directory:

```bash
./pi-project ~/src/my-project --model openai/gpt-5.6-luna
./pi-project ~/src/my-project --continue
```

The default image name is `pi-project-sandbox` and the default agent volume is `pi-project-agent`.
Override them when needed:

```bash
PI_DOCKER_IMAGE=my-pi PI_DOCKER_VOLUME=my-pi-agent ./pi-project ~/src/my-project
```

The wrapper refuses to run pi as root because the project bind mount must be writable by the caller's non-root UID.

## Provider configuration

API keys are never baked into the image or committed to this repository.
They are supplied at runtime through a Docker env-file or explicit environment variables.

For a custom OpenAI-compatible provider, copy `.env.example` to an untracked file and set the endpoint, model, and key:

```bash
cp .env.example .env.local
# Edit .env.local with the real endpoint and secret.
PI_DOCKER_ENV_FILE="$PWD/.env.local" ./pi-project ~/src/my-project
```

The bootstrap writes a custom provider to the container-local `models.json` only on first creation of that file.
Its configuration is assembled from:

- `PI_DOCKER_PROVIDER` - provider ID such as `omniroute` or `kilocode`.
- `PI_DOCKER_API_BASE_URL` - provider endpoint.
- `PI_DOCKER_API` - supported pi API type, normally `openai-completions`, `openai-responses`, or `anthropic-messages`.
- `PI_DOCKER_MODEL` or `PI_DOCKER_MODEL_ID` - model ID such as `cx/gpt-5.6-luna`.
- `PI_DOCKER_API_KEY_VARIABLE` - name of the environment variable referenced by `models.json`, defaulting to `PI_DOCKER_API_KEY`.
- `PI_DOCKER_API_KEY` or the selected variable - secret passed into the container.
- Optional `PI_DOCKER_COMPAT_JSON`, `PI_DOCKER_HEADERS_JSON`, `PI_DOCKER_AUTH_HEADER`, `PI_DOCKER_REASONING`, `PI_DOCKER_CONTEXT_WINDOW`, and `PI_DOCKER_MAX_TOKENS`.

For built-in providers, pass the provider key and select the provider/model with pi's normal arguments.
The wrapper explicitly forwards supported provider variables such as `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, and the other variables documented by pi.
For example:

```bash
OPENAI_API_KEY="$OPENAI_API_KEY" ./pi-project ~/src/my-project --provider openai --model gpt-5.6-luna
```

The wrapper does not forward the host environment wholesale.
It forwards only an allowlist of provider credentials, pi configuration variables, and proxy variables, plus variables explicitly named by `PI_DOCKER_API_KEY_VARIABLE`.

Pi also supports subscription credentials in `auth.json` and custom provider credentials in `models.json`.
This runner intentionally does not copy either file from the host.
If subscription or persistent auth is needed, configure it inside the container-local volume with an interactive run, or use an env-file.

## What pi needs at runtime

The image includes Node.js 24, bash, CA certificates, git, ripgrep, and the globally installed pi package.
These match pi's official Plain Docker example.
The image deliberately does not include Python, jq, curl, compilers, or language-specific build toolchains.
Install project-specific tools in a project image or extend this Dockerfile when a project genuinely needs them.

Pi's runtime state is under `PI_CODING_AGENT_DIR`, set here to `/home/pi/.pi/agent`:

- `settings.json` - global pi settings such as the provider/model defaults, project trust policy, session directory, tools, and resource paths.
- `models.json` - custom provider and model definitions, including API base URLs and environment references for keys.
- `auth.json` - optional credentials created by `/login`; not imported from the host.
- `trust.json` - project trust decisions; not imported from the host.
- `sessions/` - persistent JSONL conversation sessions.
- `extensions/`, `skills/`, `prompts/`, and `themes/` - container-local user resources.
- `keybindings.json` - optional interactive keybinding overrides.
- `models-store.json` - optional cached provider catalog data.

The entrypoint creates the directories and bootstraps `settings.json` and `models.json` in the named volume.
It sets `sessionDir` to the volume-local `sessions` directory, so session data does not land in the project or host home.

Pi's documented process variables include `PI_CODING_AGENT_DIR`, `PI_CODING_AGENT_SESSION_DIR`, `PI_OFFLINE`, `PI_SKIP_VERSION_CHECK`, `PI_TELEMETRY`, `PI_CACHE_RETENTION`, `HTTP_PROXY`, and `HTTPS_PROXY`.
Provider-specific credential variables are documented in pi's `providers.md`.
The wrapper forwards these when they are set.

Project-local `.pi/settings.json`, `.pi/extensions`, and project `.agents/skills` are still visible because the project itself is mounted.
Pi asks before trusting project resources by default.
Use pi's `--approve` for a single run or `/trust` interactively only when the mounted project is trusted.

## Isolation properties

Each normal `pi-project` run has exactly these intentional host mounts:

```text
PROJECT_DIR (read-write)  -> /workspace
named Docker volume       -> /home/pi/.pi/agent
```

The project is the only host bind mount.
The named volume is Docker-managed and contains pi's container-local settings, auth, trust state, resources, and sessions.
The runner uses Docker's `volume-nocopy` mount option so image files under `/home/pi/.pi/agent` cannot seed or overwrite the volume.
The runtime uses a caller-mapped non-root UID, drops all Linux capabilities, and enables `no-new-privileges`.

The following are deliberately not mounted or copied:

- The host home directory.
- The host `~/.pi` or `~/.pi/agent`.
- The host `~/.ssh`.
- Host shell configuration, npm configuration, credentials, sessions, or arbitrary environment variables.

Docker supplies standard runtime mounts such as `/proc`, `/sys`, `/dev`, `/etc/hosts`, and resolver files.
Those are Docker plumbing, not host home or project mounts.

The project remains writable because it is bind-mounted and the container process uses the invoking user's UID and GID.
The agent volume is prepared with the same UID and GID before pi starts.

### Why not mount the host `.pi`

Mounting the host `.pi` would defeat the isolation boundary.
It can expose provider credentials in `auth.json`, trust decisions, extensions with arbitrary code execution, keybindings, cached catalogs, and full session history.
Host configuration can also contain symlinks or paths that point outside the intended project.
Keeping the directory in a named volume makes the container's settings and session history independent from the host harness.

## Verify isolation

After building the image:

```bash
./verify-isolation.sh ~/src/my-project
```

The check runs with the same two mounts as the runner, with networking disabled.
It verifies that:

- The process is non-root.
- `/workspace` and the agent volume exist and are writable.
- A file can be created and removed in the project.
- Host-looking paths such as `/Users`, `/Volumes`, `/private`, host `.pi`, and host `.ssh` are not visible.
- `/proc/self/mountinfo` contains the project and agent mounts but no host home-related bind mount.

The optional `PI_DOCKER_VOLUME` variable selects the volume used by the check.
Use a throwaway volume for a clean check:

```bash
PI_DOCKER_VOLUME=pi-project-isolation-check ./verify-isolation.sh .
```

## Test pi and session persistence

A provider-backed prompt requires a valid API endpoint and key.
The following smoke test uses a custom provider configured solely through an untracked env-file:

```bash
cat >.env.local <<'EOF'
PI_DOCKER_PROVIDER=example
PI_DOCKER_API_BASE_URL=https://api.example.invalid/v1
PI_DOCKER_API=openai-completions
PI_DOCKER_MODEL=test-model
PI_DOCKER_API_KEY_VARIABLE=PI_DOCKER_API_KEY
PI_DOCKER_API_KEY=replace-me
EOF

PI_DOCKER_ENV_FILE="$PWD/.env.local" ./pi-project /tmp/pi-test -p "Reply with the single word hello"
```

Replace the endpoint, model, and key with a real provider before running this test.
The repository's automated validation uses `pi --version` and a no-network bootstrap smoke test when no real provider credentials are available.

To verify that a session was persisted in the named volume without exposing it on the host:

```bash
VOLUME=pi-project-agent
docker run --rm \
  --mount "type=volume,src=$VOLUME,dst=/data,readonly" \
  alpine:3.20 sh -c 'find /data/sessions -type f -name "*.jsonl" -print'
```

The exact session path is organized by mounted project working directory, as documented by pi.
The host project and host home should have no corresponding session file.

## Updating pi

Rebuild the image to install the version selected by the package manager's current resolution:

```bash
docker build --pull -t pi-project-sandbox .
```

The named volume persists across image updates.
Back it up or delete it deliberately if you want to reset container-local settings and sessions:

```bash
docker volume rm pi-project-agent
```

## Skills and extensions

For project-specific resources, put `.pi/skills`, `.pi/extensions`, or `.agents/skills` in the mounted project.
Review those files and approve the project before using them.
They remain project-owned and are not copied into the image.

For container-local user resources, install or create them inside the container at `/home/pi/.pi/agent/skills` or `/home/pi/.pi/agent/extensions`.
Those resources persist in the named volume and are isolated from the host.
Global pi settings can list additional resource paths, packages, skills, extensions, prompts, or themes.
Remember that extensions and skills are executable instructions/code and should be treated as trusted input.

## Network notes

Pi needs network access to reach the configured model endpoint and may contact pi.dev for update checks, package checks, or install telemetry unless disabled.
The default runner uses Docker's `bridge` network.
Set `PI_DOCKER_NETWORK=none` for offline operation, provided the model is not required:

```bash
PI_DOCKER_NETWORK=none ./pi-project ~/src/my-project --offline
```

For a restricted setup, use a Docker network with egress filtering, an HTTP proxy, or an OpenShell policy boundary.
Pass `HTTP_PROXY` and `HTTPS_PROXY` explicitly when a proxy is required.
Do not assume that restricting the network protects credentials if the model endpoint itself is untrusted.

## Sources

The runtime requirements and behavior documented here are based on the installed pi documentation:

- `docs/containerization.md` - official Node 24 Plain Docker image and named `/root/.pi/agent` volume pattern.
- `docs/settings.md` - settings precedence, project trust, session directory, and resource settings.
- `docs/models.md` - custom `models.json` providers, supported APIs, environment interpolation, and compatibility settings.
- `docs/providers.md` - built-in provider environment variables and auth resolution order.
- `docs/environment-variables.md` - `PI_CODING_AGENT_DIR`, session configuration, offline mode, telemetry, and proxy variables.
- `docs/extensions.md` and `docs/skills.md` - resource locations, project trust, and security implications.
- `docs/sessions.md` and `docs/session-format.md` - container-local session storage and JSONL layout.

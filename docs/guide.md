# Detailed Guide

This guide covers configuration, storage, isolation, extensions, and troubleshooting. For the quick start, see the [project README](../README.md).

The design follows pi's official [Plain Docker](https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/containerization.md) pattern, while adding a non-root runtime user, an isolated named volume, runtime provider configuration, and an isolation check.

## Quick start

Build the image with the pinned pi version (currently `0.87.1`):

```bash
docker build --pull -t pi-project-sandbox .
```

To choose a different published version explicitly:

```bash
docker build --pull --build-arg PI_VERSION=0.87.1 -t pi-project-sandbox .
```

Put this checkout on your `PATH`, for example in `~/.zshrc` or `~/.bashrc`:

```bash
export PATH="$HOME/src/pi-docker:$PATH"
```

Symlinking `pi-project` and `pi-ext` into a directory already on `PATH` works too; the scripts follow the link back to this checkout.

Run pi against the project you are in:

```bash
cd ~/src/my-project
pi-project
```

Without a directory argument, `pi-project` uses the current directory.
Any other directory works the same way, such as `pi-project ~/src/other-project`.
Pass normal pi arguments after an explicit project directory; the first argument is always read as the directory, so write `pi-project . --continue`, not `pi-project --continue`:

```bash
pi-project . --model openai/gpt-5.6-luna
pi-project . --continue
```

The default image name is `pi-project-sandbox`.
Each project gets its own default agent volume derived from its canonical path, such as `pi-project-agent-<hash>`.
This keeps trust decisions, sessions, auth, and extensions separate between projects.
Set `PI_DOCKER_VOLUME` only when deliberately opting into a shared volume:

```bash
PI_DOCKER_IMAGE=my-pi PI_DOCKER_VOLUME=my-pi-agent pi-project
```

The wrapper refuses to run pi as root because the project bind mount must be writable by the caller's non-root UID.
The named volume is created root-owned, so `lib/volumes.sh` prepares its ownership for the invoking UID/GID on every platform, including Docker Desktop.
The preparation is idempotent: a marker file records the owner, so subsequent runs only read it.

## Provider configuration

API keys are never baked into the image or committed to this repository.
They are supplied at runtime through a Docker env-file or explicit environment variables.

For a custom OpenAI-compatible provider, copy `.env.example` to a protected file outside the repository and build context, then set the endpoint, model, and key:

```bash
ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pi-docker"
mkdir -p "$ENV_DIR"
cp .env.example "$ENV_DIR/provider.env"
# Edit provider.env with the real endpoint and secret.
chmod 600 "$ENV_DIR/provider.env"
PI_DOCKER_ENV_FILE="$ENV_DIR/provider.env" pi-project
```

`pi-project` warns if the env file is not mode `600`, but does not change its permissions automatically.
The bootstrap writes or updates the custom provider in the container-local `models.json` on each startup.
Its configuration is assembled from:

- `PI_DOCKER_PROVIDER` - provider ID such as `my-provider`.
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
OPENAI_API_KEY="$OPENAI_API_KEY" pi-project . --provider openai --model gpt-5.6-luna
```

The wrapper does not forward the host environment wholesale.
It forwards only an allowlist of provider credentials, pi configuration variables, and proxy variables, plus variables explicitly named by `PI_DOCKER_API_KEY_VARIABLE`.
The same allowlist filters `PI_DOCKER_ENV_FILE`: entries whose names are not allowlisted are dropped with a warning, so the file cannot set `LD_PRELOAD`, `BASH_ENV`, `NODE_OPTIONS`, `PATH`, or other container-affecting variables.
`PI_DOCKER_HEADERS_JSON` values are written to `models.json` inside the volume, so avoid credentials there; the bootstrap warns when it detects a credential-like header name.

Pi also supports subscription credentials in `auth.json` and custom provider credentials in `models.json`.
This runner intentionally does not copy either file from the host.
Use the shell mode to run `/login`, edit `models.json`, or install resources into the volume:

```bash
pi-project --shell
```

The shell has the same project and agent-volume mounts, forwarded environment, non-root UID, network mode, and isolation flags as a normal run.
It starts an interactive bash instead of pi.
The shell mode requires a TTY and does not accept pi arguments.
The container maps the caller's arbitrary UID/GID to the name `pi` (via libnss-wrapper and `setup-identity.sh`), so prompts, `whoami`, and `os.userInfo()` work without adding the host UID to `/etc/passwd`.

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
`bootstrap-config.mjs` is the single source of defaults for `settings.json`, including `defaultProjectTrust: "ask"`, `enableAnalytics: false`, `quietStartup: false`, and the volume-local session directory.
It sets `sessionDir` to the volume-local `sessions` directory, so session data does not land in the project or host home.
A provider is selected as a default only when its complete provider entry was written.

Pi's documented process variables include `PI_CODING_AGENT_DIR`, `PI_CODING_AGENT_SESSION_DIR`, `PI_OFFLINE`, `PI_SKIP_VERSION_CHECK`, `PI_TELEMETRY`, `PI_CACHE_RETENTION`, `HTTP_PROXY`, and `HTTPS_PROXY`.
Provider-specific credential variables are documented in pi's `providers.md`.
The wrapper forwards these when they are set.

Project-local `.pi/settings.json`, `.pi/extensions`, and project `.agents/skills` are still visible because the project itself is mounted.
Pi asks before trusting project resources by default.
Use pi's `--approve` for a single run or `/trust` interactively only when the mounted project is trusted.
Trust is persisted in the selected volume and is keyed by the in-container path `/workspace`, so an explicitly shared volume also shares that trust decision across projects.
The per-project default avoids this collapse.

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
This relies on the container seeing the same numeric IDs as the host, which holds for a rootful Docker daemon; see Known limitations for rootless Docker and `userns-remap`.

### Why not mount the host `.pi`

Mounting the host `.pi` would defeat the isolation boundary.
It can expose provider credentials in `auth.json`, trust decisions, extensions with arbitrary code execution, keybindings, cached catalogs, and full session history.
Host configuration can also contain symlinks or paths that point outside the intended project.
Keeping the directory in a named volume makes the container's settings and session history independent from the host harness.

## Known limitations

- **Rootless Docker and `userns-remap`.** The runner maps the caller's numeric UID/GID into the container, assuming the container sees the same IDs as the host. A rootless daemon or a rootful daemon with `userns-remap` shifts those IDs, so the project bind mount may not be writable. Use the default rootful daemon, or pass `--userns=host` (rootful only) as an explicit opt-in that weakens namespace isolation. Rootless Docker is not supported out of the box.
- **SELinux hosts.** On enforcing hosts such as Fedora, the project bind mount may need a relabel. Add `:z` to the project mount or set the SELinux context; the wrapper does not relabel automatically because that modifies the host project.
- **Shared volumes.** The marker-based ownership helper targets a single UID/GID. If you deliberately share one volume across host users with `PI_DOCKER_VOLUME`, first use by a new owner re-chowns it; do not run two owners against the same volume concurrently.
- **Identity shim.** The container preloads the fixed library path `/usr/local/lib/libnss_wrapper.so` so the arbitrary UID resolves to `pi`. `LD_PRELOAD` is inherited by agent-spawned processes; it is always set to that path and never taken from the environment.
- **Base image.** `node:24-bookworm-slim` is referenced by tag rather than digest for cross-architecture portability; pin a digest if you need reproducible builds.

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

`pi-project`, `pi-ext`, and `verify-isolation.sh` share the same marker-based, hardened, networkless helper in `lib/volumes.sh`, so a second run skips the recursive `chown` when the owner is unchanged.

## Test pi and session persistence

A provider-backed prompt requires a valid API endpoint and key.
The following smoke test uses a custom provider configured through a protected env-file outside the repository:

```bash
ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/pi-docker"
mkdir -p "$ENV_DIR"
ENV_FILE="$ENV_DIR/smoke-test.env"
cat >"$ENV_FILE" <<'EOF'
PI_DOCKER_PROVIDER=example
PI_DOCKER_API_BASE_URL=https://api.example.invalid/v1
PI_DOCKER_API=openai-completions
PI_DOCKER_MODEL=test-model
PI_DOCKER_API_KEY_VARIABLE=PI_DOCKER_API_KEY
PI_DOCKER_API_KEY=replace-me
EOF
chmod 600 "$ENV_FILE"

PI_DOCKER_ENV_FILE="$ENV_FILE" pi-project /tmp/pi-test -p "Reply with the single word hello"
```

Replace the endpoint, model, and key with a real provider before running this test.
`./test.sh` runs an offline smoke test (`pi --version` plus bootstrap checks) that needs no provider credentials and no network. `./verify-isolation.sh` performs the mount-level isolation check.

To verify that a session was persisted in the named volume without exposing it on the host:

```bash
VOLUME=pi-project-agent-<hash>
docker run --rm \
  --mount "type=volume,src=$VOLUME,dst=/data,readonly" \
  alpine:3.20 sh -c 'find /data/sessions -type f -name "*.jsonl" -print'
```

The exact session path is organized by mounted project working directory, as documented by pi.
The host project and host home should have no corresponding session file.

## Updating pi

The image pins pi at the `PI_VERSION` build argument's value.
Rebuild with a deliberate version change:

```bash
docker build --pull --build-arg PI_VERSION=0.87.1 -t pi-project-sandbox .
```

The named volumes persist across image updates.
Back one up or delete it deliberately if you want to reset container-local settings and sessions:

```bash
docker volume rm pi-project-agent-<hash>
```

## Skills and extensions

For project-specific resources, put `.pi/skills`, `.pi/extensions`, or `.agents/skills` in the mounted project.
Review those files and approve the project before using them.
They remain project-owned and are not copied into the image.

For container-local user resources, install or create them inside the container at `/home/pi/.pi/agent/skills` or `/home/pi/.pi/agent/extensions`.
Those resources persist in the named volume and are isolated from the host.
Global pi settings can list additional resource paths, packages, skills, extensions, prompts, or themes.
Remember that extensions and skills are executable instructions/code and should be treated as trusted input.

### Curated host extensions

`pi-ext` treats the host `~/.pi-extensions/` directory as a local, trusted source of extension content.
It does not use a catalog or hashes.
Symlinks are resolved and copied as real files into the selected volume, and repeated syncs are safe.
The volume remains the only location pi reads at runtime.
Because resolution happens on the host, a curated entry can pull in any host file the user can read; treat `~/.pi-extensions` as trusted input and review it before syncing.

Sync to the per-project volume and inspect curated versus installed entries:

```bash
mkdir -p ~/.pi-extensions
pi-ext sync
pi-ext list
```

Set `PI_EXTENSIONS_DIR` to use another curated directory.
Without a project directory, `pi-ext` uses the current directory's volume.
Set `PI_DOCKER_VOLUME` to target an explicitly shared volume instead.
After syncing, run `/reload` in pi to hot-reload extensions.
Only sync extensions you trust, since they execute inside pi.

## Network notes and egress reality

Pi needs network access to reach the configured model endpoint and may contact pi.dev for update checks, package checks, or install telemetry unless disabled.
The default runner uses Docker's `bridge` network.
Filesystem isolation is not exfiltration protection: code the agent runs can read the API key that was intentionally forwarded into the container and can send it over an allowed network.
The project bind mount is also readable by that code.

For offline work, disable networking explicitly:

```bash
PI_DOCKER_NETWORK=none pi-project . --offline
```

For a restricted setup, use a Docker bridge network with egress filtering, or an HTTP proxy that permits only the model endpoint and required package/update hosts.
Pass `HTTP_PROXY` and `HTTPS_PROXY` explicitly when a proxy is required:

```bash
PI_DOCKER_NETWORK=pi-egress-filtered \
  HTTP_PROXY=http://proxy.internal:3128 \
  HTTPS_PROXY=http://proxy.internal:3128 \
  pi-project
```

Configure the filtering network or proxy outside this repository.
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

## License

MIT. See [LICENSE](LICENSE).

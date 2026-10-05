# rapunzel: Detailed Guide

rapunzel runs coding-agent harnesses in a hardened Docker sandbox.
Each harness is a profile in `profiles/<name>/` with its own image and its own per-project volume:

| Harness | `--harness` | Image | State directory (volume) | Credentials | Egress modes |
|---|---|---|---|---|---|
| pi (default) | `pi` | `rapunzel` | `/home/agent/.pi/agent` | provider keys, custom providers, `/login` | `open`, `allowlist`, `strict` |
| Claude Code | `claude` | `rapunzel:claude` | `/home/agent/.claude` | `ANTHROPIC_API_KEY`, or `CLAUDE_CODE_OAUTH_TOKEN` from the host's `claude setup-token` | `open`, `allowlist` |
| Codex CLI | `codex` | `rapunzel:codex` | `/home/agent/.codex` | `OPENAI_API_KEY`/`CODEX_API_KEY`, or a ChatGPT login inside the sandbox | `open`, `allowlist` |
| DeepSeek Harness | `dsh` | `rapunzel:dsh` | `/home/agent/.dsh` | `DEEPSEEK_API_KEY` | web UI: `open`; headless: `open`, `allowlist` |
| opencode | `opencode` | `rapunzel:opencode` | `/home/agent/.opencode-state` | provider keys, `OPENCODE_API_KEY` (Zen), or `opencode auth login` inside the sandbox | `open`, `allowlist` |

Copilot CLI is planned.
Most of this guide describes the pi profile: where a section names pi's files, variables, or commands, it is about pi itself.
[Claude Code](#claude-code), [Codex CLI](#codex-cli), [DeepSeek Harness](#deepseek-harness), and [opencode](#opencode) have their own sections; the isolation, host-file, and egress controls are the same for every harness.

This guide covers configuration, storage, isolation, extensions, and troubleshooting. For the quick start, see the [project README](../README.md); for how and why it works, see the [architecture](architecture.md).

The pi profile follows pi's official [Plain Docker](https://github.com/earendil-works/pi-mono/blob/main/packages/coding-agent/docs/containerization.md) pattern, while adding a non-root runtime user, an isolated named volume, runtime provider configuration, and an isolation check.

## Quick start

Build the image with the pinned pi version (currently `1.0.2`):

```bash
docker build --pull -t rapunzel .
```

To choose a different published version explicitly:

```bash
docker build --pull --build-arg PI_VERSION=1.0.2 -t rapunzel .
```

Put this checkout on your `PATH`, for example in `~/.zshrc` or `~/.bashrc`:

```bash
export PATH="$HOME/src/rapunzel:$PATH"
```

Symlinking `rapunzel` and `rapunzel-ext` into a directory already on `PATH` works too; the scripts follow the link back to this checkout.

Run pi against the project you are in:

```bash
cd ~/src/my-project
rapunzel
```

To run another harness, build its image stage and select its profile with `--harness` (or `RAPUNZEL_HARNESS`):

```bash
docker build --pull --target claude -t rapunzel:claude .
docker build --pull --target codex -t rapunzel:codex .
rapunzel --harness claude
rapunzel --harness codex . resume --last
```

`--harness` comes before every other argument.
The links `rapunzel-claude`, `rapunzel-codex`, `rapunzel-dsh`, and `rapunzel-opencode` in this checkout select their harness by name (`rapunzel-claude .` is `rapunzel --harness claude .`); a link you make yourself, such as `ln -s ~/src/rapunzel/rapunzel ~/bin/rapunzel-codex`, works the same way.
When the harness image has not been built, `rapunzel` prints the `docker build` command instead of letting Docker look for it on Docker Hub.

Without `RAPUNZEL_ENV_FILE`, the launcher loads `${XDG_CONFIG_HOME:-~/.config}/rapunzel/<harness>.env` when that file exists, for example `claude.env` with a `CLAUDE_CODE_OAUTH_TOKEN` or `pi.env` with provider keys, and says so on startup.
It goes through the same allowlist filter as any env file. Set `RAPUNZEL_ENV_FILE=` (empty) to run without it.
`--shell` and `--exec` work for every harness and use that harness's image, volume, and environment.

Without a directory argument, `rapunzel` uses the current directory.
Any other directory works the same way, such as `rapunzel ~/src/other-project`.
Pass normal pi arguments after an explicit project directory; the first argument is always read as the directory, so write `rapunzel . --continue`, not `rapunzel --continue`:

```bash
rapunzel . --model openai/gpt-5.6-luna
rapunzel . --continue
```

The default image name is `rapunzel`.
Each project gets its own default agent volume derived from its canonical path, such as `rapunzel-pi-<hash>` (`rapunzel-<harness>-<hash>`).
This keeps trust decisions, sessions, auth, and extensions separate between projects.
Set `RAPUNZEL_VOLUME` only when deliberately opting into a shared volume:

```bash
RAPUNZEL_IMAGE=my-rapunzel RAPUNZEL_VOLUME=my-rapunzel-agent rapunzel
```

The wrapper refuses to run any harness as root because the project bind mount must be writable by the caller's non-root UID.
The named volume is created root-owned, so `lib/volumes.sh` prepares its ownership for the invoking UID/GID on every platform, including Docker Desktop.
The preparation is idempotent: a marker file records the owner, so subsequent runs only read it.

## Provider configuration

API keys are never baked into the image or committed to this repository.
They are supplied at runtime through a Docker env-file or explicit environment variables.

For a custom OpenAI-compatible provider, copy `.env.example` to a protected file outside the repository and build context, then set the endpoint, model, and key:

```bash
ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rapunzel"
mkdir -p "$ENV_DIR"
cp .env.example "$ENV_DIR/provider.env"
# Edit provider.env with the real endpoint and secret.
chmod 600 "$ENV_DIR/provider.env"
RAPUNZEL_ENV_FILE="$ENV_DIR/provider.env" rapunzel
```

`rapunzel` warns if the env file is not mode `600`, but does not change its permissions automatically.
A default `<harness>.env` may be a symlink to a shared provider file; the mode check follows the link.
The bootstrap writes or updates the custom provider in the container-local `models.json` on each startup.
Its configuration is assembled from:

- `RAPUNZEL_PROVIDER` - provider ID such as `my-provider`.
- `RAPUNZEL_API_BASE_URL` - provider endpoint.
- `RAPUNZEL_API` - supported pi API type, normally `openai-completions`, `openai-responses`, or `anthropic-messages`.
- `RAPUNZEL_MODEL` or `RAPUNZEL_MODEL_ID` - model ID such as `cx/gpt-5.6-luna`.
- `RAPUNZEL_API_KEY_VARIABLE` - name of the environment variable referenced by `models.json`, defaulting to `RAPUNZEL_API_KEY`.
- `RAPUNZEL_API_KEY` or the selected variable - secret passed into the container.
- Optional `RAPUNZEL_COMPAT_JSON`, `RAPUNZEL_HEADERS_JSON`, `RAPUNZEL_AUTH_HEADER`, `RAPUNZEL_REASONING`, `RAPUNZEL_CONTEXT_WINDOW`, and `RAPUNZEL_MAX_TOKENS`.

For built-in providers, pass the provider key and select the provider/model with pi's normal arguments.
The wrapper explicitly forwards supported provider variables such as `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENROUTER_API_KEY`, `GEMINI_API_KEY`, and the other variables documented by pi.
For example:

```bash
OPENAI_API_KEY="$OPENAI_API_KEY" rapunzel . --provider openai --model gpt-5.6-luna
```

The wrapper does not forward the host environment wholesale.
It forwards only an allowlist of provider credentials, the harness profile's configuration variables, and proxy variables, plus variables explicitly named by `RAPUNZEL_API_KEY_VARIABLE`.
A profile's variables reach only that harness: `CLAUDE_CODE_OAUTH_TOKEN`, for example, is dropped for pi.
`TZ` is set from the host's `TZ` or `/etc/localtime`, so times inside the container match the host; only a plain zone name such as `Europe/Berlin` is passed.
The same allowlist filters `RAPUNZEL_ENV_FILE`: entries whose names are not allowlisted are dropped with a warning, so the file cannot set `LD_PRELOAD`, `BASH_ENV`, `NODE_OPTIONS`, `PATH`, or other container-affecting variables.
`RAPUNZEL_HEADERS_JSON` values are written to `models.json` inside the volume, so avoid credentials there; the bootstrap warns when it detects a credential-like header name.

Pi also supports subscription credentials in `auth.json` and custom provider credentials in `models.json`.
This runner intentionally does not copy either file from the host.
Use the shell mode to run `/login`, edit `models.json`, or install resources into the volume:

```bash
rapunzel --shell
```

The shell has the same project and agent-volume mounts, forwarded environment, non-root UID, network mode, and isolation flags as a normal run.
It starts an interactive bash instead of pi.
The shell mode requires a TTY and does not accept pi arguments.
The container maps the caller's arbitrary UID/GID to the name `agent` (via libnss-wrapper and `setup-identity.sh`), so prompts, `whoami`, and `os.userInfo()` work without adding the host UID to `/etc/passwd`.

## What pi needs at runtime

The image includes Node.js 24, bash, CA certificates, git, ripgrep, and the globally installed pi package.
These match pi's official Plain Docker example.
The image deliberately does not include Python, jq, curl, compilers, or language-specific build toolchains.
Install project-specific tools in a project image or extend this Dockerfile when a project genuinely needs them.

Pi's runtime state is under `PI_CODING_AGENT_DIR`, set here to `/home/agent/.pi/agent`:

- `settings.json` - global pi settings such as the provider/model defaults, project trust policy, session directory, tools, and resource paths.
- `models.json` - custom provider and model definitions, including API base URLs and environment references for keys.
- `auth.json` - optional credentials created by `/login`; not imported from the host.
- `trust.json` - project trust decisions; not imported from the host.
- `sessions/` - persistent JSONL conversation sessions.
- `extensions/`, `skills/`, `prompts/`, and `themes/` - container-local user resources.
- `keybindings.json` - optional interactive keybinding overrides.
- `models-store.json` - optional cached provider catalog data.

The entrypoint creates the directories and bootstraps `settings.json` and `models.json` in the named volume.
`profiles/pi/bootstrap.mjs` is the single source of defaults for `settings.json`, including `defaultProjectTrust: "ask"`, `enableAnalytics: false`, `quietStartup: false`, and the volume-local session directory.
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

## Claude Code

`rapunzel --harness claude` runs Claude Code in the `rapunzel:claude` image.
`CLAUDE_CONFIG_DIR` points at the volume (`/home/agent/.claude`), so its settings, `.claude.json` state, sessions, and logins all stay in the project's volume; the host `~/.claude` and `~/.claude.json` are never mounted or copied.

Credentials:

- **Subscription.** Create a long-lived token once on the host with `claude setup-token`, store it as `CLAUDE_CODE_OAUTH_TOKEN` in a mode-600 env file, and pass that file with `RAPUNZEL_ENV_FILE`. The token enters as an environment variable on each run and is never written to the volume. Your host login, which macOS keeps in the Keychain, is not copied, so its refresh token never enters the sandbox and host and sandbox sessions do not invalidate each other. The token is valid for a year; revoke it in your Claude account settings.
- **API key.** `ANTHROPIC_API_KEY`, forwarded like for pi.
- **Interactive login.** Without either, Claude Code shows its usual login picker and keeps the result in the volume.

With a token or API key set, `profiles/claude/bootstrap.mjs` marks first-run onboarding as done in `.claude.json`, so Claude Code uses the credential without asking for a login method.
The login picker cannot be left with Ctrl+C; finish or stop it with `docker stop` if needed.

Egress:

- `allowlist` always allows `api.anthropic.com`, which is enough for both an API key and a setup token. An interactive subscription login also needs `RAPUNZEL_EGRESS_LOGINS=anthropic` and `RAPUNZEL_EGRESS_ALLOW=claude.ai`.
- Both restricted modes set `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and `DISABLE_AUTOUPDATER=1`.
- `strict` is refused: pointing Claude Code at the gateway with a placeholder key is untested, and a subscription token cannot go through the gateway at all, because the gateway replaces auth headers with its own key.

Claude Code honors `HTTPS_PROXY`, so it reaches the allowlist proxy like pi.
It retries an API error up to ten times with backoff, so a failing `claude -p` can take minutes to return.
Its own permission prompts and modes work as usual inside the container.

## Codex CLI

`rapunzel --harness codex` runs the Codex CLI in the `rapunzel:codex` image.
`CODEX_HOME` points at the volume (`/home/agent/.codex`), which holds `config.toml`, `auth.json`, and sessions.

Credentials:

- **ChatGPT subscription.** Sign in once per project volume with the device-code flow, which needs no callback into the container:

  ```bash
  rapunzel --harness codex --exec . codex login --device-auth
  ```

  Codex prints a link and a one-time code; open the link in your host browser and enter the code. The login is stored as `auth.json` (mode 600) in the volume. The host `~/.codex` is never mounted or copied, so host and sandbox sessions stay independent.
- **API key.** `OPENAI_API_KEY` or `CODEX_API_KEY`.

On every start, `profiles/codex/bootstrap.mjs` adds these defaults to `config.toml` when they are not set at the top level; values you set yourself win:

- `sandbox_mode = "danger-full-access"`. Codex's own Linux sandbox (bubblewrap) needs user namespaces, which the container does not grant, so every sandboxed command would fail. The container is the boundary; Codex still asks for approval before running commands.
- `cli_auth_credentials_store = "file"`, because there is no keyring in the container.
- `check_for_update_on_startup = false` and `analytics = { enabled = false }`.

Egress:

- `allowlist` with a subscription login needs `RAPUNZEL_EGRESS_LOGINS=openai-codex` (`chatgpt.com`, `auth.openai.com`), both for signing in and for the model API. An API key adds `api.openai.com` through `OPENAI_API_KEY`.
- `strict` is refused until a gateway route for Codex is tested.

The image also contains `procps`, because the interactive CLI manages its background app-server with `ps`.

## DeepSeek Harness

`rapunzel --harness dsh` runs [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) (`dsh`, a developer preview) in the `rapunzel:dsh` image.
`DSH_HOME` points at the volume (`/home/agent/.dsh`), which holds dsh's profiles, `.credentials.yaml`, sessions, and storages.
Pass `DEEPSEEK_API_KEY` like any provider key; `EXA_API_KEY` and `PERPLEXITY_API_KEY` are forwarded for web search.

dsh has no terminal UI, so it runs in one of two ways:

- **Web UI**, the default. Without harness arguments, rapunzel runs `dsh web --patch /usr/local/lib/rapunzel/dsh-web.patch.yml --no-open --port 3080` and publishes the port on the host's `127.0.0.1` only. Open the URL with `?token=` that dsh prints; the token sets a session cookie, and requests without it get `401`. Set `RAPUNZEL_PORT` (1024-65535) to use another port, for example to run two projects at once. The patch makes dsh listen on all interfaces inside the container so Docker can forward the port, which dsh's own `--host` flag refuses; dsh then also prints a `LAN` URL with the container's bridge address, which other containers on the default bridge could reach, still only with the token. The web UI requires `RAPUNZEL_EGRESS=open`: the restricted modes put the container on an `--internal` network, from which Docker publishes no ports.
- **Headless**, one task per run, in every supported egress mode:

  ```bash
  rapunzel --harness dsh --exec . dsh headless "run the tests"
  rapunzel --harness dsh --exec . dsh headless --session-id <id> "continue"
  ```

dsh keeps its own sandbox: bash and file changes run under Landlock with approval prompts (`workspace-write`, approval on request).
Landlock needs no capabilities and works inside the container; bubblewrap, its first choice, does not, and dsh falls back on its own.
`DSH_PERMISSION_MODE` and the other `DSH_*` paths cannot be set from the host, so the sandbox cannot be switched off through rapunzel's environment.

On first start, `profiles/dsh/bootstrap.mjs` writes a home-level `cordis.patch.yml` into the volume that turns off `session-log-deepseek`, which otherwise attaches the session log to requests against the official DeepSeek API.
The file is yours afterwards; delete the row to turn uploads back on.
In the restricted modes, `DSH_TELEMETRY_MODE=DISABLED` also turns off OpenTelemetry feedback uploads, which would bypass the proxy.

Egress:

- `allowlist` always allows `api.deepseek.com`. dsh honors `HTTPS_PROXY` for its own requests and for the child processes it starts. Add sites for its `web_fetch` tool with `RAPUNZEL_EGRESS_ALLOW`.
- `strict` is refused until a gateway route for DeepSeek's API is tested.

## opencode

`rapunzel --harness opencode` (or `rapunzel-opencode`) runs [opencode](https://opencode.ai) in the `rapunzel:opencode` image.
opencode has no single home variable, so the image points `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, and `XDG_CACHE_HOME` at `config/`, `data/`, `state/`, and `cache/` in the volume (`/home/agent/.opencode-state`).
The volume therefore holds `opencode.json`, `auth.json`, the session database, logs, and the plugin and language-server caches.
The volume is not `~/.opencode`, because opencode loads that directory as a second global config directory.
Other XDG-aware tools in the container keep their config and caches in the volume too.
The host `~/.config/opencode` and `~/.local/share/opencode` are never mounted or copied.

```bash
rapunzel-opencode                                   # terminal UI
rapunzel-opencode . --continue                      # resume the last session
rapunzel-opencode --exec . opencode run "run the tests"
```

Credentials:

- **API keys.** Any key in the shared list that opencode reads, such as `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, or `OPENCODE_API_KEY` for opencode Zen.
- **Logins.** `rapunzel-opencode --exec . opencode auth login` stores the login in `auth.json` in the volume.

- **Custom OpenAI-compatible endpoint**, such as a model router: the same `RAPUNZEL_*` settings as pi, described below.

`OPENCODE_CONFIG_CONTENT` passes inline config from the host, such as `{"model":"anthropic/claude-sonnet-5-5"}`, without editing the volume.
`XDG_*`, `OPENCODE_CONFIG`, `OPENCODE_CONFIG_DIR`, and `OPENCODE_DB` cannot be set from the host.
The image sets `OPENCODE_DISABLE_AUTOUPDATE=1`, because the root-owned install cannot be updated in place.

opencode has no sandbox of its own, and by default its `build` agent runs tools without asking. It asks only for paths outside the project, `.env` reads, and repeated identical calls.
The container is the boundary.
To get approval prompts, set `OPENCODE_PERMISSION`, for example `OPENCODE_PERMISSION='{"bash":"ask","edit":"ask"}'`.
The project's `opencode.json` and `.opencode/` are in the [host-file report](#files-the-host-runs), because a plugin or MCP command there would run with the host's opencode.

Egress:

- `allowlist` adds `api.anthropic.com` and `api.openai.com` through their keys; allow any other provider's API host with `RAPUNZEL_EGRESS_ALLOW` (opencode Zen: `opencode.ai`). opencode honors `HTTPS_PROXY`. A login needs its sign-in hosts too, through `RAPUNZEL_EGRESS_LOGINS` or `RAPUNZEL_EGRESS_ALLOW`. In the restricted modes, `OPENCODE_DISABLE_MODELS_FETCH=1` keeps opencode on its bundled model catalog instead of fetching models.dev, and `OPENCODE_DISABLE_LSP_DOWNLOAD=1` stops language-server downloads that would fail.
- `strict` is refused until opencode's providers are tested against the gateway routes.

### Custom provider for opencode

On every start, `profiles/opencode/bootstrap.mjs` turns pi's custom-provider settings into an opencode provider, so one env file serves both harnesses:

| Variable | Effect in opencode |
|---|---|
| `RAPUNZEL_API_BASE_URL` | Endpoint of an `@ai-sdk/openai-compatible` provider. Without it, no provider is configured. |
| `RAPUNZEL_PROVIDER` | Provider id (default `custom`); models appear as `<id>/<model>`. |
| `RAPUNZEL_API_KEY_VARIABLE` | The variable holding the key (default `RAPUNZEL_API_KEY`). The config refers to it as `{env:NAME}`, so the key is never written to the volume. |
| `RAPUNZEL_MODEL` | Optional default model, added to the list even when the endpoint does not report it. `RAPUNZEL_MODEL_NAME`, `RAPUNZEL_CONTEXT_WINDOW`, and `RAPUNZEL_MAX_TOKENS` refine it. |
| `RAPUNZEL_API` | Only `openai-completions` (the default) is supported; any other value configures no provider. |

The model list comes from the endpoint's `/models` at startup, with a 5-second timeout.
Names, context and output limits, and tool-calling and reasoning flags are used where the endpoint reports them, as OmniRoute does.
A successful listing is cached in the volume; when the endpoint cannot be reached, the cached list for the same URL is used, with a warning.

The bootstrap writes `rapunzel/opencode.json` in the volume, which the image loads through `OPENCODE_CONFIG`, and rewrites it from the environment on every start.
It never edits your own `opencode.json`: opencode merges the rapunzel file over it, and the project's config and `OPENCODE_CONFIG_CONTENT` override both.
Remove the settings from the env file, and the provider is gone on the next start.

For a model router that pi reaches through an [extension provider](#extension-providers), add `RAPUNZEL_PROVIDER` to its env file and link the file to opencode's default:

```bash
echo RAPUNZEL_PROVIDER=omniroute >> ~/.config/rapunzel/omniroute.env
ln -s omniroute.env ~/.config/rapunzel/opencode.env
rapunzel-opencode
RAPUNZEL_EGRESS=allowlist RAPUNZEL_EGRESS_ALLOW_PRIVATE=omniroute.example.lan rapunzel-opencode
```

pi ignores `RAPUNZEL_PROVIDER` without `RAPUNZEL_MODEL`, so the file still works for pi.
Do not add `RAPUNZEL_MODEL` to a file pi shares, or pi registers its own provider next to the extension's; pick the model in opencode's `/models` instead, which it remembers, or set it in `OPENCODE_CONFIG_CONTENT`.

## Isolation properties

Each normal `rapunzel` run has exactly these intentional host mounts:

```text
PROJECT_DIR (read-write)            -> /workspace
PROJECT_DIR/.git/config (read-only) -> /workspace/.git/config
PROJECT_DIR/.git/hooks (read-only)  -> /workspace/.git/hooks
in-project core.hooksPath (read-only, if set, e.g. .husky)
named Docker volume                 -> the harness state directory (pi: /home/agent/.pi/agent)
```

The project is the only host directory mounted; the read-only entries are parts of it, described in [Files the host runs](#files-the-host-runs).
The named volume is Docker-managed and contains pi's container-local settings, auth, trust state, resources, and sessions.
The runner uses Docker's `volume-nocopy` mount option so image files under `/home/agent/.pi/agent` cannot seed or overwrite the volume.
The runtime uses a caller-mapped non-root UID, drops all Linux capabilities, and enables `no-new-privileges`.

The following are deliberately not mounted or copied:

- The host home directory.
- The host `~/.pi` or `~/.pi/agent`, `~/.claude` or `~/.claude.json`, `~/.codex`, `~/.dsh`, and opencode's `~/.config/opencode` and `~/.local/share/opencode`.
- The host `~/.ssh`.
- Host shell configuration, npm configuration, credentials, sessions, or arbitrary environment variables.

Docker supplies standard runtime mounts such as `/proc`, `/sys`, `/dev`, `/etc/hosts`, and resolver files.
Those are Docker plumbing, not host home or project mounts.

The project remains writable because it is bind-mounted and the container process uses the invoking user's UID and GID.
The agent volume is prepared with the same UID and GID before pi starts.
This relies on the container seeing the same numeric IDs as the host, which holds for a rootful Docker daemon; see Known limitations for rootless Docker and `userns-remap`.

### Files the host runs

pi can write anything in the project, including files that tools on the host later run on their own: git hooks, git config entries such as `core.fsmonitor` or `core.hooksPath`, `.envrc`, editor tasks, and package scripts.
A planted file like that runs outside the container the next time you use git, enter the directory, or open the project in an editor, regardless of any egress control.

`rapunzel` limits this in two ways:

- **Read-only git control files.** `.git/config`, `.git/hooks`, and a `core.hooksPath` directory inside the project (such as `.husky`) are mounted read-only. pi can still commit, branch, and stash, but cannot add hooks or change what git runs. Commands that write the repository config, such as `git config` or `git push -u`, fail inside the container. If `.git/hooks` does not exist, `rapunzel` creates it on the host first, so it can be mounted.
- **A change report.** Before pi starts, `rapunzel` records hashes of files the host commonly runs; when pi exits, it lists every one that was added, modified, or removed:

  ```text
  rapunzel: pi changed files that the host may run on its own.
  Review them before running git, direnv, your editor, or build tools in this project:
    added: .envrc
    modified: package.json
  ```

  The list covers `.envrc`; `.vscode` tasks, settings, and launch files; `.devcontainer`; CI workflows; pre-commit and husky hooks; agent settings (`.claude`, `.mcp.json`, `.cursor`, and opencode's `opencode.json` and `.opencode`, whose plugins run on the host); `package.json` and package-manager config; `Makefile` and `justfile`; Nix and devenv files; `mise.toml`; `.gitattributes` and `.gitmodules`; and git internals that are not read-only (`.git/info`, `.git/commondir`, `.git/worktrees`, alternates, and submodule config and hooks).

This is detection, not prevention, for everything except git config and hooks.
Review reported files before running anything on the host.
Linked worktrees and submodules whose `.git` is a file keep their git directory outside the project, so it is not mounted at all.

### Why not mount the host `.pi`

Mounting the host `.pi` would defeat the isolation boundary.
It can expose provider credentials in `auth.json`, trust decisions, extensions with arbitrary code execution, keybindings, cached catalogs, and full session history.
Host configuration can also contain symlinks or paths that point outside the intended project.
Keeping the directory in a named volume makes the container's settings and session history independent from the host harness.

## Known limitations

- **Rootless Docker and `userns-remap`.** The runner maps the caller's numeric UID/GID into the container, assuming the container sees the same IDs as the host. A rootless daemon or a rootful daemon with `userns-remap` shifts those IDs, so the project bind mount may not be writable. Use the default rootful daemon, or pass `--userns=host` (rootful only) as an explicit opt-in that weakens namespace isolation. Rootless Docker is not supported out of the box.
- **SELinux hosts.** On enforcing hosts such as Fedora, the project bind mount may need a relabel. Add `:z` to the project mount or set the SELinux context; the wrapper does not relabel automatically because that modifies the host project.
- **Shared volumes.** The marker-based ownership helper targets a single UID/GID. If you deliberately share one volume across host users with `RAPUNZEL_VOLUME`, first use by a new owner re-chowns it; do not run two owners against the same volume concurrently.
- **Identity shim.** The container preloads the fixed library path `/usr/local/lib/libnss_wrapper.so` so the arbitrary UID resolves to `agent`. `LD_PRELOAD` is inherited by agent-spawned processes; it is always set to that path and never taken from the environment.
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

The optional `RAPUNZEL_VOLUME` variable selects the volume used by the check, and `RAPUNZEL_HARNESS` selects the profile (and so the image and state directory) for both `verify-isolation.sh` and `./test.sh`:

```bash
RAPUNZEL_HARNESS=claude ./test.sh
RAPUNZEL_HARNESS=codex RAPUNZEL_VOLUME=rapunzel-isolation-codex ./verify-isolation.sh .
```

Use a throwaway volume for a clean check:

```bash
RAPUNZEL_VOLUME=rapunzel-isolation-check ./verify-isolation.sh .
```

`rapunzel`, `rapunzel-ext`, and `verify-isolation.sh` share the same marker-based, hardened, networkless helper in `lib/volumes.sh`, so a second run skips the recursive `chown` when the owner is unchanged.

## Test pi and session persistence

A provider-backed prompt requires a valid API endpoint and key.
The following smoke test uses a custom provider configured through a protected env-file outside the repository:

```bash
ENV_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/rapunzel"
mkdir -p "$ENV_DIR"
ENV_FILE="$ENV_DIR/smoke-test.env"
cat >"$ENV_FILE" <<'EOF'
RAPUNZEL_PROVIDER=example
RAPUNZEL_API_BASE_URL=https://api.example.invalid/v1
RAPUNZEL_API=openai-completions
RAPUNZEL_MODEL=test-model
RAPUNZEL_API_KEY_VARIABLE=RAPUNZEL_API_KEY
RAPUNZEL_API_KEY=replace-me
EOF
chmod 600 "$ENV_FILE"

RAPUNZEL_ENV_FILE="$ENV_FILE" rapunzel /tmp/pi-test -p "Reply with the single word hello"
```

Replace the endpoint, model, and key with a real provider before running this test.
`./test.sh` runs an offline smoke test (`pi --version` plus bootstrap checks) that needs no provider credentials and no network. `./verify-isolation.sh` performs the mount-level isolation check.

To verify that a session was persisted in the named volume without exposing it on the host:

```bash
VOLUME=rapunzel-pi-<hash>
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
docker build --pull --build-arg PI_VERSION=1.0.2 -t rapunzel .
```

The other harnesses pin their versions the same way, with `CLAUDE_VERSION`, `CODEX_VERSION`, `DSH_VERSION`, and `OPENCODE_VERSION` (see the `ARG` lines in the `Dockerfile` for the current pins; Renovate proposes updates weekly):

```bash
docker build --pull --target claude --build-arg CLAUDE_VERSION=<version> -t rapunzel:claude .
docker build --pull --target codex --build-arg CODEX_VERSION=<version> -t rapunzel:codex .
```

Their auto-updaters cannot write the root-owned install (Codex's update check and opencode's auto-update are off, and Claude Code's updater is off in the restricted egress modes), so update by rebuilding.

The named volumes persist across image updates.
Back one up or delete it deliberately if you want to reset container-local settings and sessions:

```bash
docker volume rm rapunzel-pi-<hash>
```

## Skills and extensions

For project-specific resources, put `.pi/skills`, `.pi/extensions`, or `.agents/skills` in the mounted project.
Review those files and approve the project before using them.
They remain project-owned and are not copied into the image.

For container-local user resources, install or create them inside the container at `/home/agent/.pi/agent/skills` or `/home/agent/.pi/agent/extensions`.
Those resources persist in the named volume and are isolated from the host.
Global pi settings can list additional resource paths, packages, skills, extensions, prompts, or themes.
Remember that extensions and skills are executable instructions/code and should be treated as trusted input.

### Curated host extensions

`rapunzel-ext` treats the host `~/.pi-extensions/` directory as a local, trusted source of extension content.
It does not use a catalog or hashes.
Symlinks are resolved and copied as real files into the selected volume, and repeated syncs are safe.
The volume remains the only location pi reads at runtime.
Because resolution happens on the host, a curated entry can pull in any host file the user can read; treat `~/.pi-extensions` as trusted input and review it before syncing.

Sync to the per-project volume and inspect curated versus installed entries:

```bash
mkdir -p ~/.pi-extensions
rapunzel-ext sync
rapunzel-ext list
```

Each top-level entry of the curated directory becomes one extension, and pi loads a directory through its `index.ts` or `index.js`.
An extension that imports a sibling directory, such as `../shared`, needs a small wrapper entry that carries both:

```bash
mkdir -p ~/.pi-extensions/omniroute
ln -s ~/src/pi_extensions/model-catalogs ~/.pi-extensions/omniroute/model-catalogs
echo 'export { default } from "./model-catalogs/omniroute/index.ts";' > ~/.pi-extensions/omniroute/index.ts
```

`rapunzel-ext sync` copies the symlinked tree as real files, so the relative imports keep working inside the volume.

Set `RAPUNZEL_EXTENSIONS_DIR` to use another curated directory.
Without a project directory, `rapunzel-ext` uses the current directory's volume.
Set `RAPUNZEL_VOLUME` to target an explicitly shared volume instead.
After syncing, run `/reload` in pi to hot-reload extensions.
Only sync extensions you trust, since they execute inside pi.

## Network notes and egress control

Pi needs network access to reach the configured model endpoint and may contact pi.dev for update checks, package checks, or install telemetry unless disabled.
By default the runner uses Docker's `bridge` network, so pi can reach the whole internet.
Filesystem isolation is not exfiltration protection: code the agent runs can read the API key that was intentionally forwarded into the container and can send it over the network.
The project bind mount is also readable by that code.

For offline work, disable networking explicitly:

```bash
RAPUNZEL_NETWORK=none rapunzel . --offline
```

### Egress control

`RAPUNZEL_EGRESS` restricts what pi can reach.
[Egress control: architecture and decisions](egress.md) explains the design, the alternatives that were rejected, and the remaining risks.

| Mode | pi holds the provider credential | pi can reach | `/login` subscriptions |
|---|---|---|---|
| `open` (default) | yes | the internet | yes |
| `allowlist` | yes | only allowlisted hosts over HTTPS | yes, with `RAPUNZEL_EGRESS_LOGINS` |
| `strict` | no, only a placeholder | only fixed provider routes on a credential gateway | no, API keys only |

Both restricted modes put pi on a per-run Docker network created with `--internal` and isolated gateway mode, so it has no route off that network, no upstream DNS, and no address on the host side of the bridge.
The only other member is a sidecar container, which is pi's only way out.
The sidecar and both networks are removed when pi exits.
Both modes need Docker Engine 28 or newer, set the harness's offline switches (for pi `PI_OFFLINE`, `PI_SKIP_VERSION_CHECK`, and `PI_TELEMETRY=0`), and cannot be combined with `RAPUNZEL_NETWORK`.
`strict` is available for pi only; the other harnesses refuse it.

### allowlist mode

```bash
ANTHROPIC_API_KEY=sk-ant-... RAPUNZEL_EGRESS=allowlist rapunzel
RAPUNZEL_EGRESS=allowlist RAPUNZEL_EGRESS_LOGINS=openai rapunzel   # ChatGPT subscription via /login
```

The sidecar is [Pipelock](https://github.com/luckyPipewrench/pipelock), an HTTPS CONNECT proxy.
pi gets `HTTPS_PROXY=http://egress:8888` and `NODE_USE_ENV_PROXY=1`.
The proxy allows a tunnel only to an allowlisted host, and only when the TLS handshake inside names that same host.
It refuses IP literals, private and metadata addresses, and plain `http://` requests.

The allowlist is built from the configuration:

- `ANTHROPIC_API_KEY` allows `api.anthropic.com`;
- `OPENAI_API_KEY` allows `api.openai.com`;
- `RAPUNZEL_API_BASE_URL` allows that URL's host;
- `RAPUNZEL_EGRESS_LOGINS` adds the hosts of providers you signed in to with `/login`, see below;
- `RAPUNZEL_EGRESS_ALLOW` adds comma-separated hosts; `*.example.com` also matches `example.com`;
- `RAPUNZEL_EGRESS_ALLOW_PRIVATE` adds exact hosts that resolve to a private address, see below.

`rapunzel` prints the final list on startup.

A `/login` subscription keeps its OAuth tokens in `auth.json` inside the agent volume, so pi holds them in every mode.
Name the providers you use in `RAPUNZEL_EGRESS_LOGINS` (comma-separated) to allow their model API and token refresh hosts.
The names are pi's provider IDs, the same keys `/login` writes to `auth.json`:

| `/login` provider (`RAPUNZEL_EGRESS_LOGINS`) | Allowed hosts |
|---|---|
| `openai` (ChatGPT subscription, "Sign in with ChatGPT") | `api.openai.com`, `auth.openai.com` |
| `openai-codex` (pi's legacy ChatGPT Plus/Pro login) | `chatgpt.com`, `auth.openai.com` |
| `anthropic` (Claude subscription) | `api.anthropic.com`, `platform.claude.com` |
| `github-copilot` | `api.github.com`, `*.githubcopilot.com` |

These lists come from pi 0.99.1's provider code.
`rapunzel` never reads them from `auth.json`, because pi can edit that file and would otherwise choose its own allowlist.
`github-copilot` also allows `api.github.com`, which exposes GitHub's whole API to the token pi holds.
`/login` works inside the container: the browser cannot reach pi's callback there, so paste the redirect URL when pi asks for it, or choose the device-code option. It needs the same hosts, and the tokens then persist in the project's volume.
Package registries and GitHub are not allowed by default, because they accept uploads with any token; install dependencies before the session, in `open` mode.

The proxy refuses private, loopback, and link-local destinations after resolving a name, even for an allowlisted host.
A model router or gateway on your local network, for example `router.lan` at `10.1.0.11`, therefore needs `RAPUNZEL_EGRESS_ALLOW_PRIVATE=router.lan`.
It takes exact names only, no wildcards: whoever controls a name's DNS decides where it points, so list only names whose DNS you control.
Cloud metadata and link-local addresses stay blocked regardless.

### strict mode

```bash
ANTHROPIC_API_KEY=sk-ant-... RAPUNZEL_EGRESS=strict rapunzel
```

The sidecar is a [Caddy](https://caddyserver.com/) reverse proxy that holds the real keys.
The bootstrap points pi's providers at `http://llm-proxy:8080` with the placeholder key `rapunzel-gateway`.
The gateway serves only fixed routes and answers everything else with `403`:

| Route | Upstream | Credential | Header the gateway sets |
|---|---|---|---|
| `/anthropic/*` | `https://api.anthropic.com` | `ANTHROPIC_API_KEY` | `x-api-key` |
| `/openai/*` | `https://api.openai.com` | `OPENAI_API_KEY` | `Authorization: Bearer` |
| `/custom/*` | `RAPUNZEL_API_BASE_URL` | `RAPUNZEL_API_KEY` or `RAPUNZEL_API_KEY_VARIABLE` | `x-api-key` for `anthropic-messages`, otherwise `Authorization: Bearer` |

The gateway always overwrites these headers and removes the other one, so pi cannot use an allowed provider with a credential of its own, for example to upload data to a provider's file API under an attacker's account.
Requests and responses are otherwise passed through unchanged and streamed without buffering.
Credentials can come from the host environment or from `RAPUNZEL_ENV_FILE`; the gateway reads them from a temporary env-file that is deleted after the run.

Limitations of strict mode:

- Only the three routes above are supported. Other provider keys, `RAPUNZEL_HEADERS_JSON`, and proxy variables are not passed, and `rapunzel` names them in a warning.
- Credentials stored with `/login` live in `auth.json` inside the agent volume, where the gateway cannot protect them. The bootstrap warns when `auth.json` is not empty; run `/logout` to remove them.

### Extension providers

Some providers come from a pi extension rather than from pi itself, for example a catalog extension for a model router such as OmniRoute.
Such an extension reads its endpoint and key from variables of its own, such as `OMNIROUTE_BASE_URL` and `OMNIROUTE_API_KEY`.
Name them, and let `rapunzel` fill them in for each mode:

```bash
# ~/.config/rapunzel/omniroute.env (chmod 600)
RAPUNZEL_API_BASE_URL=https://omniroute.example.lan/v1
RAPUNZEL_BASE_URL_VARIABLE=OMNIROUTE_BASE_URL
RAPUNZEL_API_KEY_VARIABLE=OMNIROUTE_API_KEY
OMNIROUTE_API_KEY=replace-me
```

| Mode | `OMNIROUTE_BASE_URL` inside pi | `OMNIROUTE_API_KEY` inside pi |
|---|---|---|
| `open` | the real URL | the real key |
| `allowlist` | the real URL; its host is allowlisted automatically | the real key |
| `strict` | `http://llm-proxy:8080/custom`, the gateway's custom route | the placeholder `rapunzel-gateway`; the gateway sends the real key upstream |

Without `RAPUNZEL_PROVIDER` and `RAPUNZEL_MODEL`, the bootstrap registers no provider of its own, so only the extension's provider appears.
pi needs both, so adding only `RAPUNZEL_PROVIDER` lets [opencode use the same file](#custom-provider-for-opencode).
Install the extension into the project's volume with `rapunzel-ext` (see [Curated host extensions](#curated-host-extensions)).
If the router resolves to a private address, add `RAPUNZEL_EGRESS_ALLOW_PRIVATE` with its host for `allowlist` mode.

### What egress control does not cover

- pi can still send anything it reads, including project files, to the hosts it may reach.
- pi can write files in the project that the host later runs, such as git hooks, `.git/config`, editor tasks, and package scripts. Review changes before running git commands or opening the project in an IDE. See [residual risks](egress.md#residual-risks).
- WSL2 has not been tested yet.

### Verify egress control

```bash
./verify-egress.sh            # both modes
./verify-egress.sh strict     # offline
./verify-egress.sh allowlist  # needs internet
```

The check runs a probe inside pi's container through the real launcher, with a listener on the host network as a canary.
It fails if pi can resolve external names, connect directly to the internet, the metadata address, or the host, or reach anything the sidecar should refuse.
In strict mode it also checks that no real key reaches pi and that the gateway replaces pi's credentials.
[Verification](egress.md#verification) lists every check.

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

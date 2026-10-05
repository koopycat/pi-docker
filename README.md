# rapunzel

rapunzel runs coding-agent harnesses against a project inside a hardened Docker sandbox. The agent sees one host directory, the project mounted at `/workspace`, and keeps its settings, logins, sessions, and extensions in a separate Docker volume per project. It runs without root, receives only an allowlist of environment variables, and can be limited to named hosts or kept away from your provider keys entirely.

The [pi coding agent](https://github.com/earendil-works/pi-mono) is the default harness. [Claude Code](#claude-code) (`--harness claude`), [Codex CLI](#codex-cli) (`--harness codex`), [DeepSeek Harness](#deepseek-harness) (`--harness dsh`), and [opencode](#opencode) (`--harness opencode`) are further profiles on the same launcher, each in its own image (`docker build --target <harness> -t rapunzel:<harness> .`), and each has a shortcut, `rapunzel-claude`, `rapunzel-codex`, `rapunzel-dsh`, and `rapunzel-opencode`, that also loads `~/.config/rapunzel/<harness>.env` when it exists; they support `open` and `allowlist` egress, not `strict` yet. Copilot CLI is planned.

The name: Rapunzel is kept in a tower whose only way out is a single strand you control. Here the tower is the container, and the strand is the one project directory and, optionally, the one egress proxy.

## Quick start

You need Docker Engine or Docker Desktop running. Put this checkout on your `PATH` (or symlink `rapunzel` into a directory on it) and select the published image, for example in `~/.zshrc` or `~/.bashrc`:

```bash
export PATH="$HOME/src/rapunzel:$PATH"
export RAPUNZEL_IMAGE=ghcr.io/koopycat/rapunzel
```

Then start Pi from the project you want it to work on:

```bash
cd ~/src/my-project
rapunzel
```

Without a path, `rapunzel` uses the current directory. Pass a path to use a different project, such as `rapunzel ~/src/other-project`.

The published image supports `linux/amd64` and `linux/arm64`. GitHub Actions updates `latest` from `main` and publishes a matching image tag for each `v*` Git tag. Docker pulls the image on first use; run `docker pull ghcr.io/koopycat/rapunzel:latest` to update it.

To build the image locally instead, run this in the checkout and leave `RAPUNZEL_IMAGE` unset:

```bash
docker build --pull -t rapunzel .
```

Pass Pi's usual arguments after an explicit project path:

```bash
rapunzel . --continue
```

Open a shell with the same project and agent-state mounts:

```bash
rapunzel --shell
```

Set a provider key in your environment before launching Pi. The runner passes supported provider keys and configuration variables at runtime. For a custom API endpoint, start with [.env.example](.env.example) and follow the [provider setup guide](docs/guide.md#provider-configuration). Keep real secrets outside the repository and Docker build context.

## Claude Code

```bash
docker build --target claude -t rapunzel:claude .
./rapunzel --harness claude [PROJECT_DIR [claude arguments...]]
```

To reuse your host's Claude subscription instead of logging in again inside every project volume, create a long-lived token once on the host and pass it per run:

```bash
claude setup-token                     # on the host; prints a token
printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' '<token>' >> ~/.config/rapunzel/claude.env
chmod 600 ~/.config/rapunzel/claude.env
./rapunzel-claude .                    # loads ~/.config/rapunzel/claude.env
```

The token enters the container as an environment variable and is never written to the volume, and no refresh token from your host login is copied, so host and sandbox sessions do not invalidate each other. Revoke it from your Claude account settings when you no longer need it. With a token or `ANTHROPIC_API_KEY` set, the entrypoint marks first-run onboarding as done so Claude Code skips the login picker.

`RAPUNZEL_EGRESS=allowlist` works with either credential (`api.anthropic.com` is always allowed for this harness); `strict` is not supported for Claude Code yet.

## Codex CLI

```bash
docker build --target codex -t rapunzel:codex .
./rapunzel --harness codex [PROJECT_DIR [codex arguments...]]
```

Use `OPENAI_API_KEY` (or `CODEX_API_KEY`), or sign in with your ChatGPT subscription once per project volume through the device-code flow:

```bash
./rapunzel --harness codex --exec . codex login --device-auth
```

Codex prints a link and a one-time code; finish the sign-in in your host browser. The login is stored in the project's volume (`auth.json` in `CODEX_HOME`), not copied from the host's `~/.codex`, so host and sandbox sessions stay independent. With `RAPUNZEL_EGRESS=allowlist`, a subscription login needs `RAPUNZEL_EGRESS_LOGINS=openai-codex` (`chatgpt.com`, `auth.openai.com`); `strict` is not supported for Codex yet.

Codex's own sandbox (bubblewrap) cannot create namespaces inside rapunzel's container, so the entrypoint defaults `sandbox_mode` to `danger-full-access` in `config.toml`; the container is the boundary, and Codex still asks for approval. It also stores logins in a file and turns off update checks and analytics. Values you set yourself in `config.toml` win.

## DeepSeek Harness

```bash
docker build --target dsh -t rapunzel:dsh .
DEEPSEEK_API_KEY=... ./rapunzel --harness dsh                     # web UI
DEEPSEEK_API_KEY=... ./rapunzel --harness dsh --exec . dsh headless "run the tests"
```

DeepSeek Harness (`dsh`) has no terminal UI. Without harness arguments, rapunzel starts `dsh web` and publishes it on `127.0.0.1:3080` only (`RAPUNZEL_PORT` changes the port); open the tokenized URL dsh prints. The web UI needs `RAPUNZEL_EGRESS=open`, because the restricted modes have no published ports. `dsh headless` works in `allowlist` mode too (`api.deepseek.com` is allowed). dsh keeps its own Landlock sandbox and approval prompts, which work inside the container, and rapunzel seeds a home-level patch that turns off dsh's default session-log upload to the DeepSeek API.

## opencode

```bash
docker build --target opencode -t rapunzel:opencode .
./rapunzel-opencode [PROJECT_DIR [opencode arguments...]]
./rapunzel-opencode --exec . opencode run "run the tests"
```

Pass any provider key opencode knows (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `OPENCODE_API_KEY` for opencode Zen, and the rest of the shared list), or sign in once per project volume with `./rapunzel-opencode --exec . opencode auth login`. opencode keeps its config, logins, and sessions in the project's volume, never in the host's `~/.config/opencode` or `~/.local/share/opencode`. `OPENCODE_CONFIG_CONTENT` passes host-side config, such as a default model, without editing the volume. In `allowlist` mode, allow the provider's host yourself unless a key adds it (opencode Zen: `RAPUNZEL_EGRESS_ALLOW=opencode.ai`); opencode then uses its bundled model catalog instead of fetching models.dev. `strict` is not supported for opencode yet.

opencode has no sandbox of its own and runs tools without asking by default; the container is the boundary. Set `OPENCODE_PERMISSION` (JSON) to require approval, for example `{"bash":"ask","edit":"ask"}`.

## What stays separate

- Each project gets its own persistent Docker volume for the agent's settings, login credentials, sessions, trust decisions, and installed extensions.
- The selected project is the only host directory mounted into a normal run. Its git config and hooks are read-only, and `rapunzel` reports changes to files the host runs on its own, such as `.envrc` or editor tasks. The host home directory, `~/.pi`, and `~/.ssh` are not mounted.
- The agent runs as your numeric user and group, without root privileges or Linux capabilities.
- Only supported runtime variables are passed into the container, rather than the full host environment.
- With `RAPUNZEL_EGRESS=allowlist`, the agent reaches only allowlisted hosts through an SNI-checking proxy. `RAPUNZEL_EGRESS=strict` also keeps provider keys out of the container. See [egress control](docs/guide.md#egress-control) and its [design decisions](docs/egress.md).

The agent can read and modify files in the mounted project, including project-local agent resources. It can also read any credentials you pass to it. Docker networking defaults to `bridge`; use `RAPUNZEL_NETWORK=none` for offline runs. See the [isolation guide](docs/guide.md#isolation-properties) for the full boundary and limitations.

## Renamed from pi-docker

This project was called pi-docker. The rename is breaking, and the old names no longer work:

- The launcher is `rapunzel` instead of `pi-project`, and `rapunzel-ext` replaces `pi-ext`.
- Environment variables use the prefix `RAPUNZEL_` instead of `PI_DOCKER_`, and `RAPUNZEL_EXTENSIONS_DIR` replaces `PI_EXTENSIONS_DIR`.
- The local image is `rapunzel` instead of `pi-project-sandbox`, and the published image is `ghcr.io/koopycat/rapunzel` instead of `ghcr.io/koopycat/pi-docker`.
- Per-project volumes are named `rapunzel-<harness>-<hash>`, for example `rapunzel-pi-<hash>`. Existing `pi-project-agent-*` volumes are not reused, so each project starts with fresh settings, logins, and sessions. Remove the old volumes with `docker volume rm` once you no longer need them.
- Inside the container, the user is `agent` and `HOME` is `/home/agent`.

## More

- [Architecture](docs/architecture.md): goals, threat model, design, verification, and residual risks
- [Configuration, storage, and provider options](docs/guide.md#provider-configuration)
- [Shell mode and extension management](docs/guide.md#skills-and-extensions)
- [Isolation checks](docs/guide.md#verify-isolation)
- [Known limitations](docs/guide.md#known-limitations)
- [Full guide](docs/guide.md)
- [MIT license](LICENSE)

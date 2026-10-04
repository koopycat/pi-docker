# rapunzel

rapunzel runs coding-agent harnesses against a project inside a hardened Docker sandbox. The agent sees one host directory, the project mounted at `/workspace`, and keeps its settings, logins, sessions, and extensions in a separate Docker volume per project. It runs without root, receives only an allowlist of environment variables, and can be limited to named hosts or kept away from your provider keys entirely.

The [pi coding agent](https://github.com/earendil-works/pi-mono) is the first supported harness, and currently the only one. Claude Code, Codex CLI, and Copilot CLI are planned as further profiles on the same launcher.

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
- Per-project volumes are named `rapunzel-agent-<hash>`. Existing `pi-project-agent-*` volumes are not reused, so each project starts with fresh settings, logins, and sessions. Remove the old volumes with `docker volume rm` once you no longer need them.
- Inside the container, the user is `agent` and `HOME` is `/home/agent`.

## More

- [Architecture](docs/architecture.md): goals, threat model, design, verification, and residual risks
- [Configuration, storage, and provider options](docs/guide.md#provider-configuration)
- [Shell mode and extension management](docs/guide.md#skills-and-extensions)
- [Isolation checks](docs/guide.md#verify-isolation)
- [Known limitations](docs/guide.md#known-limitations)
- [Full guide](docs/guide.md)
- [MIT license](LICENSE)

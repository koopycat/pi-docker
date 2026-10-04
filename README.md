# Pi Docker Sandbox

Run the [Pi coding agent](https://github.com/earendil-works/pi-mono) against a project inside Docker. The project stays mounted at `/workspace`; Pi's settings, sessions, and extensions live in a separate Docker volume.

## Quick start

You need Docker Engine or Docker Desktop running. Put this checkout on your `PATH` (or symlink `pi-project` into a directory on it) and select the published image, for example in `~/.zshrc` or `~/.bashrc`:

```bash
export PATH="$HOME/src/pi-docker:$PATH"
export PI_DOCKER_IMAGE=ghcr.io/koopycat/pi-docker
```

Then start Pi from the project you want it to work on:

```bash
cd ~/src/my-project
pi-project
```

Without a path, `pi-project` uses the current directory. Pass a path to use a different project, such as `pi-project ~/src/other-project`.

The published image supports `linux/amd64` and `linux/arm64`. GitHub Actions updates `latest` from `main` and publishes a matching image tag for each `v*` Git tag. Docker pulls the image on first use; run `docker pull ghcr.io/koopycat/pi-docker:latest` to update it.

To build the image locally instead, run this in the checkout and leave `PI_DOCKER_IMAGE` unset:

```bash
docker build --pull -t pi-project-sandbox .
```

Pass Pi's usual arguments after an explicit project path:

```bash
pi-project . --continue
```

Open a shell with the same project and Pi state mounts:

```bash
pi-project --shell
```

Set a provider key in your environment before launching Pi. The runner passes supported provider keys and configuration variables at runtime. For a custom API endpoint, start with [.env.example](.env.example) and follow the [provider setup guide](docs/guide.md#provider-configuration). Keep real secrets outside the repository and Docker build context.

## What stays separate

- Each project gets its own persistent Docker volume for Pi settings, login credentials, sessions, trust decisions, and installed extensions.
- The selected project is the only host directory mounted into a normal Pi run. Its git config and hooks are read-only, and `pi-project` reports changes to files the host runs on its own, such as `.envrc` or editor tasks. The host home directory, `~/.pi`, and `~/.ssh` are not mounted.
- Pi runs as your numeric user and group, without root privileges or Linux capabilities.
- Only supported runtime variables are passed into the container, rather than the full host environment.
- With `PI_DOCKER_EGRESS=allowlist`, Pi reaches only allowlisted hosts through an SNI-checking proxy. `PI_DOCKER_EGRESS=strict` also keeps provider keys out of the container. See [egress control](docs/guide.md#egress-control) and its [design decisions](docs/egress.md).

Pi can read and modify files in the mounted project, including project-local agent resources. It can also read any credentials you pass to it. Docker networking defaults to `bridge`; use `PI_DOCKER_NETWORK=none` for offline runs. See the [isolation guide](docs/guide.md#isolation-properties) for the full boundary and limitations.

## More

- [Architecture](docs/architecture.md): goals, threat model, design, verification, and residual risks
- [Configuration, storage, and provider options](docs/guide.md#provider-configuration)
- [Shell mode and extension management](docs/guide.md#skills-and-extensions)
- [Isolation checks](docs/guide.md#verify-isolation)
- [Known limitations](docs/guide.md#known-limitations)
- [Full guide](docs/guide.md)
- [MIT license](LICENSE)

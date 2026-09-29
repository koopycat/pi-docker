# Pi Docker Sandbox

Run the [Pi coding agent](https://github.com/earendil-works/pi-mono) against a project inside Docker. The project stays mounted at `/workspace`; Pi's settings, sessions, and extensions live in a separate Docker volume.

## Quick start

You need Docker Engine or Docker Desktop running.

```bash
docker pull ghcr.io/koopycat/pi-docker:latest
PI_DOCKER_IMAGE=ghcr.io/koopycat/pi-docker ./pi-project /path/to/project
```

The published image supports `linux/amd64` and `linux/arm64`. GitHub Actions updates `latest` from `main` and publishes a matching image tag for each `v*` Git tag.

To build the image locally instead:

```bash
docker build --pull -t pi-project-sandbox .
./pi-project /path/to/project
```

Pass Pi's usual arguments after the project path:

```bash
./pi-project /path/to/project --continue
```

Open a shell with the same project and Pi state mounts:

```bash
./pi-project --shell /path/to/project
```

Set a provider key in your environment before launching Pi. The runner passes supported provider keys and configuration variables at runtime. For a custom API endpoint, start with [.env.example](.env.example) and follow the [provider setup guide](docs/guide.md#provider-configuration). Keep real secrets outside the repository and Docker build context.

## What stays separate

- Each project gets its own persistent Docker volume for Pi settings, login credentials, sessions, trust decisions, and installed extensions.
- The selected project is the only host directory mounted into a normal Pi run. The host home directory, `~/.pi`, and `~/.ssh` are not mounted.
- Pi runs as your numeric user and group, without root privileges or Linux capabilities.
- Only supported runtime variables are passed into the container, rather than the full host environment.

Pi can read and modify files in the mounted project, including project-local agent resources. It can also read any credentials you pass to it. Docker networking defaults to `bridge`; use `PI_DOCKER_NETWORK=none` for offline runs. See the [isolation guide](docs/guide.md#isolation-properties) for the full boundary and limitations.

## More

- [Configuration, storage, and provider options](docs/guide.md#provider-configuration)
- [Shell mode and extension management](docs/guide.md#skills-and-extensions)
- [Isolation checks](docs/guide.md#verify-isolation)
- [Known limitations](docs/guide.md#known-limitations)
- [Full guide](docs/guide.md)
- [MIT license](LICENSE)

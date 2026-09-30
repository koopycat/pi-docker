# pi Docker sandbox

## Commands

- `docker build -t pi-project-sandbox .`
- `./pi-project [PROJECT_DIR [pi arguments...]]` (PROJECT_DIR defaults to the current directory)
- `./pi-project --shell [PROJECT_DIR]`
- `./pi-ext sync|list [PROJECT_DIR]`
- `./test.sh`
- `./verify-isolation.sh [project-directory]`

## Invariants

- The only host bind mount is the requested project at `/workspace`.
- Pi configuration and sessions live in the named Docker volume at `/home/pi/.pi/agent`.
- Named volumes are created root-owned; `lib/volumes.sh` prepares ownership for the caller's UID/GID before every run (idempotent via a marker file). Do not add a Docker Desktop skip.
- The container maps the caller's arbitrary UID/GID to the name `pi` via `setup-identity.sh` and libnss-wrapper, so it stays non-root without "I have no name!" prompts.
- Only allowlisted environment names enter the container; `PI_DOCKER_ENV_FILE` is filtered through the same allowlist and `PI_DOCKER_API_KEY_VARIABLE` must name an allowed variable.
- Secrets enter at runtime through a Docker env-file or explicitly forwarded variables.
- Do not mount the host home directory, `~/.pi`, or `~/.ssh`.
- `/home/pi` is mode 1777 because the runtime UID is the caller's, not the image's 1001.
- pi's shrinkwrap makes npm install every `@esbuild/*` platform binary; `lib/prune-foreign-platforms.mjs` removes them and must run in the same `RUN` layer as `npm install`.
- `publish-image.yml` calls `ci.yml` and publishes only after it passes; do not add a separate push trigger to `ci.yml`.

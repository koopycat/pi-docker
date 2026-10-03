# pi Docker sandbox

## Commands

- `docker build -t pi-project-sandbox .`
- `./pi-project [PROJECT_DIR [pi arguments...]]` (PROJECT_DIR defaults to the current directory)
- `./pi-project --shell [PROJECT_DIR]`
- `./pi-ext sync|list [PROJECT_DIR]`
- `./test.sh`
- `./verify-isolation.sh [project-directory]`
- `./verify-egress.sh [allowlist|strict]` (allowlist needs internet, strict runs offline; no credentials needed)
- `./verify-host-files.sh` (needs git on the host)

## Invariants

- The only host bind mount is the requested project at `/workspace`, plus read-only sub-mounts of its `.git/config`, `.git/hooks`, and an in-project `core.hooksPath` (`lib/host-files.sh`). pi must stay able to commit; keep `./verify-host-files.sh` passing.
- The image sets `safe.directory=/workspace` system-wide because Docker Desktop shows the mount root as owned by root.
- Pi configuration and sessions live in the named Docker volume at `/home/pi/.pi/agent`.
- Named volumes are created root-owned; `lib/volumes.sh` prepares ownership for the caller's UID/GID before every run (idempotent via a marker file). Do not add a Docker Desktop skip.
- The container maps the caller's arbitrary UID/GID to the name `pi` via `setup-identity.sh` and libnss-wrapper, so it stays non-root without "I have no name!" prompts.
- Only allowlisted environment names enter the container; `PI_DOCKER_ENV_FILE` is filtered through the same allowlist and `PI_DOCKER_API_KEY_VARIABLE` must name an allowed variable.
- Secrets enter at runtime through a Docker env-file or explicitly forwarded variables.
- `PI_DOCKER_EGRESS=allowlist|strict` puts pi only on a per-run `--internal` network in isolated gateway mode; its one peer is a sidecar on a per-run outbound bridge (never the default bridge). Design and decisions live in `docs/egress.md`; update its decision records when changing `lib/egress.sh`.
- allowlist mode: Pipelock must keep `sni_verification` and `sni_require_tls` on; `HTTP_PROXY` stays unset so cleartext fails closed. Allowed hosts come only from the host side (keys, base URL, `PI_DOCKER_EGRESS_LOGINS`, `PI_DOCKER_EGRESS_ALLOW`, `PI_DOCKER_EGRESS_ALLOW_PRIVATE`), never from agent-writable state such as `auth.json`. Private destinations are trusted only for exact names in `PI_DOCKER_EGRESS_ALLOW_PRIVATE`.
- strict mode: pi receives no provider credentials; the Caddy gateway always overwrites auth headers and answers unknown routes with 403.
- Sidecar images are pinned by digest in `lib/egress.sh` and never automerged. Any change there must keep `./verify-egress.sh` passing.
- Do not mount the host home directory, `~/.pi`, or `~/.ssh`.
- `/home/pi` and `/home/pi/.pi` are mode 1777 because the runtime UID is the caller's, not the image's 1001; extensions write caches such as `~/.pi/cache` there.
- pi's shrinkwrap makes npm install every `@esbuild/*` platform binary; `lib/prune-foreign-platforms.mjs` removes them and must run in the same `RUN` layer as `npm install`.
- `publish-image.yml` calls `ci.yml` and publishes only after it passes; do not add a separate push trigger to `ci.yml`.

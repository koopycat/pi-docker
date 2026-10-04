# rapunzel: Docker sandbox for coding-agent harnesses

pi is the default harness; Claude Code and Codex CLI are further profiles, and Copilot CLI is planned.

## Commands

- `docker build -t rapunzel .`
- `./rapunzel [PROJECT_DIR [pi arguments...]]` (PROJECT_DIR defaults to the current directory)
- `./rapunzel --shell [PROJECT_DIR]`
- `./rapunzel --harness NAME ...` (profiles live in `profiles/NAME/`: `pi`, `claude`, `codex`; build a non-default image with `docker build --target NAME -t rapunzel:NAME .`)
- `./rapunzel-ext sync|list [PROJECT_DIR]`
- `./test.sh`
- `./verify-isolation.sh [project-directory]`
- `./verify-egress.sh [allowlist|strict]` (allowlist needs internet, strict runs offline; no credentials needed)
- `./verify-host-files.sh` (needs git on the host)

## Invariants

`docs/architecture.md` describes the design these invariants protect; keep it current when they change.


- The only host bind mount is the requested project at `/workspace`, plus read-only sub-mounts of its `.git/config`, `.git/hooks`, and an in-project `core.hooksPath` (`lib/host-files.sh`). pi must stay able to commit; keep `./verify-host-files.sh` passing.
- The image sets `safe.directory=/workspace` system-wide because Docker Desktop shows the mount root as owned by root.
- Harness configuration and sessions live in a per-project, per-harness named Docker volume at the profile's `H_STATE_DIR` (pi: `/home/agent/.pi/agent`).
- A profile (`profiles/<name>/profile.sh`) is data only: command, state directory, environment names. It never weakens a launcher control, and profiles come only from this repository, never from a user-supplied path.
- Named volumes are created root-owned; `lib/volumes.sh` prepares ownership for the caller's UID/GID before every run (idempotent via a marker file). Do not add a Docker Desktop skip.
- The container maps the caller's arbitrary UID/GID to the name `agent` via `setup-identity.sh` and libnss-wrapper, so it stays non-root without "I have no name!" prompts.
- Only allowlisted environment names enter the container; `RAPUNZEL_ENV_FILE` is filtered through the same allowlist and `RAPUNZEL_API_KEY_VARIABLE` must name an allowed variable.
- Secrets enter at runtime through a Docker env-file or explicitly forwarded variables.
- `RAPUNZEL_EGRESS=allowlist|strict` puts pi only on a per-run `--internal` network in isolated gateway mode; its one peer is a sidecar on a per-run outbound bridge (never the default bridge). Design and decisions live in `docs/egress.md`; update its decision records when changing `lib/egress.sh`.
- allowlist mode: Pipelock must keep `sni_verification` and `sni_require_tls` on; `HTTP_PROXY` stays unset so cleartext fails closed. Allowed hosts come only from the host side (keys, base URL, `RAPUNZEL_EGRESS_LOGINS`, `RAPUNZEL_EGRESS_ALLOW`, `RAPUNZEL_EGRESS_ALLOW_PRIVATE`), never from agent-writable state such as `auth.json`. Private destinations are trusted only for exact names in `RAPUNZEL_EGRESS_ALLOW_PRIVATE`.
- strict mode: pi receives no provider credentials; the Caddy gateway always overwrites auth headers and answers unknown routes with 403.
- Sidecar images are pinned by digest in `lib/egress.sh` and never automerged. Any change there must keep `./verify-egress.sh` passing.
- Do not mount the host home directory, `~/.pi`, or `~/.ssh`.
- `/home/agent` and `/home/agent/.pi` are mode 1777 because the runtime UID is the caller's, not the image's 1001; extensions write caches such as `~/.pi/cache` there.
- Since pi 1.0.1 the package ships no `npm-shrinkwrap.json`, so transitive dependencies resolve at build time. `lib/prune-foreign-platforms.mjs` stays as a guard against foreign `@esbuild/*` platform binaries and must run in the same `RUN` layer as `npm install`.
- `publish-image.yml` calls `ci.yml` and publishes only after it passes; do not add a separate push trigger to `ci.yml`.

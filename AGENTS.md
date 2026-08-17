# pi Docker sandbox

## Commands

- `docker build -t pi-project-sandbox .`
- `./pi-project PROJECT_DIR [pi arguments...]`
- `./verify-isolation.sh [project-directory]`

## Invariants

- The only host bind mount is the requested project at `/workspace`.
- Pi configuration and sessions live in the named Docker volume at `/home/pi/.pi/agent`.
- Secrets enter at runtime through a Docker env-file or explicitly forwarded variables.
- Do not mount the host home directory, `~/.pi`, or `~/.ssh`.

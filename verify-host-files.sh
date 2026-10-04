#!/usr/bin/env bash
set -Eeuo pipefail

# Checks the host-executed file protection through the real launcher: inside
# the container, rapunzel --exec tries to plant git hooks and git config and
# to change files the host runs. Writes to git config and hooks must fail, a
# commit must still work, and rapunzel must report the other changes.
# Needs git on the host; no network or credentials.

SCRIPT_PATH=${BASH_SOURCE[0]}
# Follow symlinks so a link on PATH still finds lib/ in the checkout.
while [[ -L "$SCRIPT_PATH" ]]; do
    link=$(readlink -- "$SCRIPT_PATH")
    [[ "$link" == /* ]] || link="$(dirname -- "$SCRIPT_PATH")/$link"
    SCRIPT_PATH=$link
done
ROOT_DIR=$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd -P)
# shellcheck source=lib/docker.sh
source "${ROOT_DIR}/lib/docker.sh"
IMAGE=${RAPUNZEL_IMAGE:-rapunzel}
VOLUME=${RAPUNZEL_VOLUME:-rapunzel-host-files-check}

require_docker verify-host-files.sh
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    printf 'Image %s is missing. Run docker build -t %s . first.\n' "$IMAGE" "$IMAGE" >&2
    exit 1
}
command -v git >/dev/null 2>&1 || {
    printf 'git is required on the host for this check\n' >&2
    exit 1
}

project=$(mktemp -d "${TMPDIR:-/tmp}/rapunzel-host-files.XXXXXX")
report=$(mktemp "${TMPDIR:-/tmp}/rapunzel-host-files-report.XXXXXX")
trap 'rm -rf "$project" "$report"' EXIT

# A repository whose hooks live in the working tree, as with husky.
git -C "$project" init --quiet
git -C "$project" config user.name host
git -C "$project" config user.email host@example.invalid
mkdir "${project}/.husky"
printf '#!/bin/sh\nexit 0\n' >"${project}/.husky/pre-commit"
chmod +x "${project}/.husky/pre-commit"
git -C "$project" config core.hooksPath .husky
git -C "$project" add .husky
git -C "$project" commit --quiet -m initial
config_before=$(cat "${project}/.git/config")

# Each attempt prints "RESULT <name> <exit status>". The script runs in the
# container, so its expansions are meant to stay unexpanded here.
# shellcheck disable=SC2016
attempts='
attempt() { name=$1; shift; if "$@" >/dev/null 2>&1; then echo "RESULT $name 0"; else echo "RESULT $name 1"; fi; }
attempt write-git-hook sh -c "printf \"#!/bin/sh\n\" > .git/hooks/post-checkout"
attempt append-git-config sh -c "printf \"[core]\n\tfsmonitor = evil\n\" >> .git/config"
attempt git-config-fsmonitor git config core.fsmonitor evil
attempt write-hooks-path-hook sh -c "printf \"#!/bin/sh\n\" > .husky/post-checkout"
attempt replace-hooks-path-hook sh -c "printf \"#!/bin/sh\n\" > .husky/pre-commit"
attempt git-commit git -c user.name=pi -c user.email=pi@example.invalid commit --quiet --allow-empty -m from-container
mkdir -p .vscode
printf "{}\n" > .vscode/tasks.json
printf "echo hi\n" > .envrc
printf "* filter=evil\n" > .git/info/attributes
'
output=$(
    env -u RAPUNZEL_ENV_FILE -u RAPUNZEL_EGRESS \
        RAPUNZEL_IMAGE="$IMAGE" \
        RAPUNZEL_VOLUME="$VOLUME" \
        "${ROOT_DIR}/rapunzel" --exec "$project" bash -c "$attempts" 2>"$report"
)

failures=0
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}
expect() {
    local name=$1 status=$2 line
    line=$(grep "^RESULT ${name} " <<<"$output" || true)
    if [[ "$line" == "RESULT ${name} ${status}" ]]; then
        printf 'PASS %s\n' "$name"
    else
        fail "${name}: expected status ${status}, got '${line:-no result}'"
    fi
}

expect write-git-hook 1
expect append-git-config 1
expect git-config-fsmonitor 1
expect write-hooks-path-hook 1
expect replace-hooks-path-hook 1
expect git-commit 0

[[ "$(cat "${project}/.git/config")" == "$config_before" ]] || fail "the host's .git/config changed"
[[ ! -e "${project}/.git/hooks/post-checkout" && ! -e "${project}/.husky/post-checkout" ]] ||
    fail "a hook reached the host"
[[ "$(git -C "$project" log -1 --format=%s)" == from-container ]] || fail "the commit made in the container is missing"

for expected in "added: .envrc" "added: .vscode/tasks.json" "added: .git/info/attributes"; do
    if grep -qF "$expected" "$report"; then
        printf 'PASS reported %s\n' "$expected"
    else
        fail "rapunzel did not report '${expected}'"
    fi
done
if grep -qF ".husky" "$report"; then
    fail "rapunzel reported an unchanged hooks directory"
fi

if [[ "$failures" -gt 0 ]]; then
    printf -- '--- rapunzel stderr ---\n' >&2
    cat "$report" >&2
    printf '%s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf 'PASS: git config and hooks are read-only, commits work, host-executed changes are reported\n'

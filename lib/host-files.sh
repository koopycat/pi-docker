#!/usr/bin/env bash
# shellcheck disable=SC2034 # HOST_FILE_MOUNTS is read by the sourcing script
# Host-executed files in the mounted project.
#
# pi can write anything in /workspace, including files the host later runs on
# its own: git hooks, git config, direnv, editor tasks, package scripts. This
# file makes the git ones read-only where that keeps pi able to commit, and
# reports changes to the rest after each run.
#
# Source this file from the wrapper scripts. It defines:
#   host_files_mounts   - read-only mounts for .git/config, .git/hooks and an
#                         in-project core.hooksPath; sets HOST_FILE_MOUNTS
#   host_files_snapshot - record hashes of host-executed files
#   host_files_report   - print what changed between two snapshots

# Working-tree paths that common host tools run or load without asking.
HOST_EXECUTED_PATHS=(
    .envrc
    .vscode/tasks.json .vscode/settings.json .vscode/launch.json
    .devcontainer
    .github/workflows .gitlab-ci.yml
    .pre-commit-config.yaml .husky .githooks
    .claude/settings.json .claude/settings.local.json .mcp.json .cursor
    package.json .npmrc .pnpmfile.cjs .yarnrc.yml
    Makefile justfile Justfile
    devenv.nix devenv.yaml flake.nix shell.nix
    mise.toml .mise.toml
    .gitattributes .gitmodules
)
# Git internals that decide what git runs or which config it reads. Only
# config and hooks are mounted read-only; the rest is detected.
GIT_CONTROL_PATHS=(
    .git/config .git/config.worktree .git/commondir .git/hooks .git/info
    .git/worktrees .git/objects/info/alternates
)

HOST_FILE_MOUNTS=()
HOST_FILES_EXTRA=()

# Print the in-project core.hooksPath directory relative to PROJECT, if any.
_hooks_path_in_project() {
    local project=$1 hooks_path resolved
    command -v git >/dev/null 2>&1 || return 0
    # --file reads the repository config only and runs nothing from it.
    hooks_path=$(git config --file "${project}/.git/config" --get core.hooksPath 2>/dev/null) || return 0
    [[ "$hooks_path" == /* ]] || hooks_path="${project}/${hooks_path}"
    resolved=$(cd -- "$hooks_path" 2>/dev/null && pwd -P) || return 0
    [[ "$resolved" == "$project"/* ]] || return 0
    printf '%s' "${resolved#"${project}"/}"
}

host_files_mounts() {
    local project=${1:?host_files_mounts requires a project directory}
    local hooks_dir
    HOST_FILE_MOUNTS=()
    HOST_FILES_EXTRA=()
    # A .git file means a linked worktree or submodule; its git directory is
    # outside the project and therefore not mounted at all.
    [[ -d "${project}/.git" && ! -L "${project}/.git" ]] || return 0

    if [[ -f "${project}/.git/config" && ! -L "${project}/.git/config" ]]; then
        HOST_FILE_MOUNTS+=(--mount "type=bind,src=${project}/.git/config,dst=/workspace/.git/config,readonly")
    fi
    # git init creates hooks/, but some clones lack it. Without the directory
    # pi could create hooks that the host would run.
    [[ -e "${project}/.git/hooks" ]] || mkdir "${project}/.git/hooks"
    if [[ -d "${project}/.git/hooks" && ! -L "${project}/.git/hooks" ]]; then
        HOST_FILE_MOUNTS+=(--mount "type=bind,src=${project}/.git/hooks,dst=/workspace/.git/hooks,readonly")
    fi
    hooks_dir=$(_hooks_path_in_project "$project")
    if [[ -n "$hooks_dir" && "$hooks_dir" != .git/hooks ]]; then
        HOST_FILE_MOUNTS+=(--mount "type=bind,src=${project}/${hooks_dir},dst=/workspace/${hooks_dir},readonly")
        HOST_FILES_EXTRA+=("$hooks_dir")
    fi
}

# Hash the files given as NUL-separated paths on stdin, one "hash  path" each.
# With no input, GNU xargs still runs once and hashes stdin as "-"; the
# snapshot drops that line.
_hash_files() {
    if command -v shasum >/dev/null 2>&1; then
        xargs -0 shasum -a 256 --
    else
        xargs -0 sha256sum --
    fi
}

# Write "hash  path" lines for every host-executed file under PROJECT to OUT.
# Symlinks are recorded by target, so retargeting one is a change too.
host_files_snapshot() {
    local project=${1:?host_files_snapshot requires a project directory}
    local out=${2:?host_files_snapshot requires an output file}
    local path
    (
        cd -- "$project" || exit 0
        for path in "${HOST_EXECUTED_PATHS[@]}" "${GIT_CONTROL_PATHS[@]}" \
            ${HOST_FILES_EXTRA[@]+"${HOST_FILES_EXTRA[@]}"}; do
            [[ -e "$path" || -L "$path" ]] || continue
            find "$path" -type l -exec sh -c 'printf "link:%s  %s\n" "$(readlink "$1")" "$1"' sh {} \;
            find "$path" -type f -print0 | _hash_files
        done
        # Submodule git directories carry their own config and hooks.
        if [[ -d .git/modules ]]; then
            find .git/modules \( -name config -o -path '*/hooks/*' \) -type f -print0 | _hash_files
        fi
    ) 2>/dev/null | grep -v '  -$' | sort -u >"$out" || true
}

# Print "  added|removed|modified: path" for differences between snapshots.
host_files_report() {
    local before=${1:?} after=${2:?} changes
    # Lines are "hash  path"; paths may contain spaces.
    changes=$(awk '
        { hash = $1; path = substr($0, index($0, "  ") + 2) }
        NR == FNR { seen[path] = hash; next }
        !(path in seen) { print "  added: " path; next }
        seen[path] != hash { print "  modified: " path }
        { delete seen[path] }
        END { for (path in seen) print "  removed: " path }
    ' "$before" "$after" | sort -u)
    [[ -n "$changes" ]] || return 0
    printf '%s\n' \
        'pi-project: pi changed files that the host may run on its own.' \
        'Review them before running git, direnv, your editor, or build tools in this project:' \
        "$changes" >&2
}

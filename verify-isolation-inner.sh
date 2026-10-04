#!/usr/bin/env bash
set -Eeuo pipefail

fail() {
    printf 'isolation check failed: %s\n' "$*" >&2
    exit 1
}

[[ "$(id -u)" != 0 ]] || fail "container process is root"
[[ -d /workspace ]] || fail "/workspace is missing"
[[ -d /home/agent/.pi/agent ]] || fail "container-local pi agent directory is missing"
[[ -w /workspace ]] || fail "/workspace is not writable"
[[ -w /home/agent/.pi/agent ]] || fail "agent volume is not writable"

probe="/workspace/.rapunzel-isolation-$$"
printf 'ok\n' >"$probe"
rm -f "$probe"

# These paths would be present or contain host state if a home-directory mount
# had slipped into the container. /home/agent/.pi is deliberately the named volume.
[[ ! -e /root/.ssh ]] || fail "root SSH directory is visible"
[[ ! -e /root/.pi ]] || fail "root host .pi directory is visible"
[[ ! -e /home/agent/.ssh ]] || fail "agent SSH directory is visible"
[[ ! -e /Users ]] || fail "macOS host filesystem is visible"
[[ ! -e /Volumes ]] || fail "macOS host volumes are visible"
[[ ! -e /private ]] || fail "macOS host private filesystem is visible"

if [[ -n "${HOST_HOME_PATH:-}" ]]; then
    [[ ! -e "$HOST_HOME_PATH" ]] || fail "host home path is visible: $HOST_HOME_PATH"
fi

# Check the mount destinations visible to this process. Docker's runtime mounts
# (proc, sysfs, tmpfs, /etc/hosts, and resolver files) are expected; no host
# project or home path may appear as an additional bind mount.
mount_targets=$(awk '{print $5}' /proc/self/mountinfo)
grep -qx '/workspace' <<<"$mount_targets" || fail "/workspace mount is missing"
grep -qx '/home/agent/.pi/agent' <<<"$mount_targets" || fail "agent volume mount is missing"

# Remove the two intentional mounts before looking for host-like paths.
unexpected_mounts=$(awk '$5 != "/workspace" && $5 != "/home/agent/.pi/agent" {print $5}' <<<"$mount_targets")
host_mounts=$(grep -E '^/(Users|Volumes|private|home/[^/]+/\.pi|home/[^/]+/\.ssh)(/|$)' <<<"$unexpected_mounts" || true)
[[ -z "$host_mounts" ]] || fail "host home-related mount is visible"

printf 'PASS: non-root, project writable, container-local agent volume, no host home or SSH mounts\n'

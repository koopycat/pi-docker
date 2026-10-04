#!/usr/bin/env bash
# Give the caller's arbitrary UID/GID a resolvable identity inside the container.
#
# The runner maps the host UID/GID into the container, which usually has no
# matching /etc/passwd entry. Without one, interactive prompts show
# "I have no name!", `whoami` fails, and `os.userInfo()` throws.
#
# libnss-wrapper maps the current UID/GID to the name "agent" without requiring
# root, so the process stays non-root. This file is sourced by the entrypoints
# (bootstrap.sh and rapunzel-shell) before exec'ing the real command, so the
# exported environment is inherited by every child process.
#
# LD_PRELOAD is set to exactly this library; any inherited value is discarded so
# a caller cannot smuggle in an additional preloaded object.
#
# Requires CONFIG_DIR (a writable agent directory) to be set.

if [[ -e /usr/local/lib/libnss_wrapper.so ]] && [[ "$(id -u)" != "0" ]]; then
    nss_dir="${CONFIG_DIR}/.nss"
    mkdir -p "$nss_dir"
    printf 'agent:x:%s:%s:agent:%s:/bin/bash\n' "$(id -u)" "$(id -g)" "${HOME:-/home/agent}" >"${nss_dir}/passwd"
    printf 'agent:x:%s:\n' "$(id -g)" >"${nss_dir}/group"
    export NSS_WRAPPER_PASSWD="${nss_dir}/passwd"
    export NSS_WRAPPER_GROUP="${nss_dir}/group"
    export LD_PRELOAD="/usr/local/lib/libnss_wrapper.so"
fi
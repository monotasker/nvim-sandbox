#!/usr/bin/env bash
# Editor entrypoint (root only): SSH agent proxy → runuser seed-home as uid 1000.
#
# Docker Desktop often mounts the host agent as root:root 660. socat listens on
# /tmp/ssh-agent-proxy owned by dev, then we drop privileges and run
# editor-seed-home.sh (home tooling/config, then exec CMD).
#
# Same proxy model as docker/workspace_entrypoint.sh.
set -euo pipefail

log() { printf 'editor: %s\n' "$*" >&2; }

if [[ "$(id -u)" -ne 0 ]]; then
  log "error: editor-entrypoint must run as root (compose must not set user:)"
  exit 1
fi

MOUNT="${SSH_AUTH_SOCK_MOUNT:-/ssh-agent}"
PROXY="${SSH_AUTH_SOCK_PROXY:-/tmp/ssh-agent-proxy}"

if [[ -S "$MOUNT" ]]; then
  rm -f "$PROXY"
  # Long-lived proxy: root can open $MOUNT; dev can open $PROXY.
  socat \
    "UNIX-LISTEN:${PROXY},fork,mode=660,user=dev,group=dev,unlink-early" \
    "UNIX-CONNECT:${MOUNT}" &
  for _ in $(seq 1 50); do
    if [[ -S "$PROXY" ]]; then
      break
    fi
    sleep 0.1
  done
  if [[ ! -S "$PROXY" ]]; then
    log "warning: SSH agent proxy did not start at ${PROXY}"
  else
    export SSH_AUTH_SOCK="$PROXY"
  fi
fi

if [[ $# -eq 0 ]]; then
  set -- sleep infinity
fi
exec runuser -u dev -- /usr/local/bin/editor-seed-home.sh "$@"

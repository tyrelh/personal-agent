#!/bin/bash
# Copy the install scripts to the box over Tailscale SSH and run them.
#
# Run this from a laptop on the tailnet, after `terraform apply` has brought the
# instance up. user-data only does the base OS and Tailscale; everything else is here.
#
#   ./deploy.sh                     # hermes, then obsidian
#   ./deploy.sh hermes              # just one of them
#   FORCE=1 ./deploy.sh hermes      # knobs are forwarded (see each script's header)
#   SYNC_MODE=pull-only ./deploy.sh obsidian
#
# Safe to re-run: both scripts are idempotent, which is the point of deploying this way
# rather than through user-data. `HOST=` points at a different box.
set -euo pipefail

HOST="${HOST:-root@hermes}"
cd "$(dirname "$0")"

# Knobs the remote scripts read. ssh does not forward the environment, so anything set
# here has to go on the remote command line. SECRET_ID and REGION are left out on
# purpose: each script already defaults them, and the values are not secret enough to be
# worth a flag but not obvious enough to be worth guessing at from here.
FORWARD=(FORCE HERMES_COMMIT MODEL_DEFAULT HERMES_USER
         SECRET_ID REGION
         OB_VERSION NODE_MAJOR VAULT_DIR CONTAINER_PATH SYNC_MODE)

remote_env() {
  local name value out=""
  for name in "${FORWARD[@]}"; do
    value="${!name:-}"
    [ -n "$value" ] && out+="$name=$(printf '%q' "$value") "
  done
  printf '%s' "$out"
}

# `cat >` over ssh rather than scp: Tailscale SSH implements sftp, but it has broken
# before (tailscale#12849) and this needs no sftp subsystem, no scp binary and no second
# connection. Written to a temp file and moved into place so a dropped connection cannot
# leave a half-written script at a path we are about to execute.
deploy() { # deploy <local file> <remote name>
  local src="$1" name="$2" dest="/usr/local/sbin/$2"
  echo "==> $src -> $HOST:$dest"
  ssh "$HOST" "cat > $dest.new && chmod 755 $dest.new && mv $dest.new $dest" < "$src"
  echo "==> running $dest"
  # A TTY only when there is one to pass through: it keeps apt and npm printing progress
  # on a ten-minute install, but asking for one from a script or a CI job just earns a
  # "Pseudo-terminal will not be allocated" warning on every run.
  # A plain string, not an array: macOS ships bash 3.2, where "${arr[@]}" on an empty
  # array trips `set -u`. Unquoted on purpose so empty expands to no argument at all.
  local tty=""
  [ -t 0 ] && tty="-t"
  # shellcheck disable=SC2086
  ssh $tty "$HOST" "$(remote_env)$dest"
}

case "${1:-all}" in
  all)      deploy install_hermes.sh   hermes-install
            deploy install_obsidian.sh hermes-obsidian-install ;;
  hermes)   deploy install_hermes.sh   hermes-install ;;
  obsidian) deploy install_obsidian.sh hermes-obsidian-install ;;
  *) echo "usage: $0 [all|hermes|obsidian]" >&2; exit 1 ;;
esac

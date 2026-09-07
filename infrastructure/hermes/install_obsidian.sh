#!/bin/bash
# Obsidian vault on the box: the headless Sync client, a continuous sync unit, and
# the bind mount that makes the vault visible to the agent's sandbox container.
#
# Runs as root on the box, copied there and started by ./deploy.sh. Self-contained and
# safe to re-run: the install is skipped once the pinned version is present (FORCE=1 to
# reinstall), and the login, sync-setup, config and unit steps all converge rather than
# append.
#
#   ./deploy.sh obsidian
#   ssh root@hermes /usr/local/sbin/hermes-obsidian-install
#
# It is a no-op when the Obsidian keys are absent from the secret, the same way the
# gateway step is a no-op without the Slack tokens — so a box with no Obsidian account
# attached still deploys cleanly.
set -euo pipefail

OB_VERSION="${OB_VERSION:-0.0.14}"    # open beta; pin it. Unpin at your own risk.
NODE_MAJOR="${NODE_MAJOR:-22}"        # obsidian-headless engines: node >=22
VAULT_DIR="${VAULT_DIR:-/srv/obsidian}"
CONTAINER_PATH="${CONTAINER_PATH:-/workspace/vault}"
SYNC_MODE="${SYNC_MODE:-bidirectional}"   # or pull-only / mirror-remote (read-only)
HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="/home/$HERMES_USER"
FORCE="${FORCE:-0}"
# The literals are the normal case now that nothing templates this script; deploy.sh
# forwards SECRET_ID/REGION only when they are set in its own environment.
SECRET_ID="${SECRET_ID:-hermes}"
REGION="${REGION:-ca-west-1}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq missing — run user_data.sh first" >&2; exit 1; }
AWS=/snap/bin/aws
[ -x "$AWS" ] || { echo "$AWS missing — run user_data.sh first" >&2; exit 1; }

case "$SYNC_MODE" in
  bidirectional|pull-only|mirror-remote) ;;
  *) echo "SYNC_MODE must be bidirectional, pull-only or mirror-remote" >&2; exit 1 ;;
esac

as_hermes() { cd "$HERMES_HOME" && sudo -u "$HERMES_USER" -H "$@"; }

# --- 1. credentials ----------------------------------------------------------
# Read straight from Secrets Manager, never from ~/.hermes/.env. The account
# password is access to *every* vault on the account, and .env is read by an agent
# that has a shell — so hermes-render-env deletes the OBSIDIAN_* keys on the way
# through (same reason it deletes TAILSCALE_AUTH_KEY). This script has the instance
# role, so it does not need them there.
secret=$("$AWS" secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" --region "$REGION" \
  --query SecretString --output text)

get() { printf '%s' "$secret" | jq -r --arg k "$1" '.[$k] // ""'; }
OBSIDIAN_EMAIL=$(get OBSIDIAN_EMAIL)
OBSIDIAN_PASSWORD=$(get OBSIDIAN_PASSWORD)
OBSIDIAN_VAULT=$(get OBSIDIAN_VAULT)
OBSIDIAN_VAULT_PASSWORD=$(get OBSIDIAN_VAULT_PASSWORD)
unset secret

if [ -z "$OBSIDIAN_EMAIL" ] || [ -z "$OBSIDIAN_PASSWORD" ] || [ -z "$OBSIDIAN_VAULT" ]; then
  echo "==> no OBSIDIAN_EMAIL/OBSIDIAN_PASSWORD/OBSIDIAN_VAULT in the secret — skipping Obsidian"
  exit 0
fi

# --- 2. node + the client ----------------------------------------------------
# Node 22 from NodeSource, system-wide, rather than reusing the Node 26 the hermes
# installer puts under ~/.hermes: that tree is the installer's to delete, and `ob`
# vanishing from under a running systemd unit on someone else's reinstall is a bad
# way to lose a sync daemon. noble's own nodejs is 18, too old for the engines field.
if [ "$FORCE" != "1" ] && ob --version 2>/dev/null | grep -qF "$OB_VERSION"; then
  echo "==> obsidian-headless $OB_VERSION already present — skipping; FORCE=1 to reinstall"
else
  echo "==> node $NODE_MAJOR + obsidian-headless $OB_VERSION"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  if [ "$(node --version 2>/dev/null | cut -d. -f1)" != "v$NODE_MAJOR" ]; then
    curl -fsSL "https://deb.nodesource.com/setup_$NODE_MAJOR.x" -o /tmp/nodesource.sh
    bash /tmp/nodesource.sh
    apt-get install -y -qq nodejs
  fi
  npm install -g --silent "obsidian-headless@$OB_VERSION"
fi
OB=$(command -v ob) || { echo "obsidian-headless installed but 'ob' is not on PATH" >&2; exit 1; }

# --- 3. login ----------------------------------------------------------------
# The daemon runs as root and so does the login, which is deliberate: the stored
# session then lives in root's home, out of reach of the hermes user and of anything
# that escapes the sandbox. The agent reaches the vault through the bind mount in
# section 6 and nothing else.
#
# Unconditional, not guarded by a "already logged in?" probe: passing --email and
# --password is how the client re-authenticates an existing session, so one call
# converges either way. A probe would have to guess what `ob login --json` reports for
# a logged-out account, and guessing wrong means a boot that looks fine and then dies
# at sync-setup.
#
# 2FA cannot be answered by a boot script — if the account has it on, this fails here
# with the client's own message and nothing after it runs.
# ponytail: the password goes on argv, so it is in /proc/<pid>/cmdline for the life of
# one command. There is no token or stdin path in the client today; switch to one if
# it ever lands.
echo "==> logging in to Obsidian as $OBSIDIAN_EMAIL"
"$OB" login --email "$OBSIDIAN_EMAIL" --password "$OBSIDIAN_PASSWORD" --json >/dev/null
unset OBSIDIAN_EMAIL OBSIDIAN_PASSWORD

# --- 4. vault ----------------------------------------------------------------
# Root-owned, and that is what makes the ownership work out: the sandbox container
# runs as root, so files the agent creates in the mount land root-owned on the host,
# and a sync daemon running as anyone else could upload them but never edit or
# delete them again. One uid on both sides of the mount, no remapping.
mkdir -p "$VAULT_DIR"
chmod 700 "$VAULT_DIR"

if "$OB" sync-status --path "$VAULT_DIR" --json >/dev/null 2>&1; then
  echo "==> vault already linked at $VAULT_DIR"
else
  echo "==> linking $VAULT_DIR to remote vault '$OBSIDIAN_VAULT'"
  # --json disables the password prompt, so an end-to-end encrypted vault with no
  # OBSIDIAN_VAULT_PASSWORD in the secret fails here rather than hanging at boot.
  "$OB" sync-setup --path "$VAULT_DIR" --vault "$OBSIDIAN_VAULT" \
    --device-name hermes --json \
    ${OBSIDIAN_VAULT_PASSWORD:+--password "$OBSIDIAN_VAULT_PASSWORD"} >/dev/null
fi
unset OBSIDIAN_VAULT_PASSWORD

# Set on every run, not just at setup: this is the one knob that decides whether the
# agent's writes reach your other devices, so it converges rather than drifting.
echo "==> sync mode: $SYNC_MODE"
"$OB" sync-config --path "$VAULT_DIR" --mode "$SYNC_MODE" --json >/dev/null

# --- 5. the sync unit --------------------------------------------------------
# One-shot `ob sync` first: it is the check that the login and the E2EE password are
# both right, and it fails loudly here instead of into journalctl. It also means the
# vault has content before the agent can look at it.
echo "==> initial sync (first run pulls the whole vault)"
"$OB" sync --path "$VAULT_DIR"

echo "==> installing obsidian-sync.service"
cat > /etc/systemd/system/obsidian-sync.service <<UNIT_EOF
[Unit]
Description=Obsidian Sync (headless, continuous)
Documentation=https://github.com/obsidianmd/obsidian-headless
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$VAULT_DIR
ExecStart=$OB sync --continuous --path $VAULT_DIR
# Beta client on a box nobody watches: assume it will die and let systemd deal with
# it. StartLimit off, because a crash loop that gives up silently is worse than one
# that keeps retrying and shows up in the journal.
Restart=always
RestartSec=15
StartLimitIntervalSec=0

[Install]
WantedBy=multi-user.target
UNIT_EOF
systemctl daemon-reload
# enable, then restart rather than `enable --now`: restart starts a stopped unit and
# picks up a rewritten one, so a re-run converges instead of starting it twice.
systemctl enable obsidian-sync
systemctl restart obsidian-sync
systemctl is-active --quiet obsidian-sync || { systemctl status --no-pager -l obsidian-sync; exit 1; }

# --- 6. hand the vault to the agent -----------------------------------------
# Phase 3 put the agent's shell in a container that mounts only its own sandbox dir,
# so a vault sitting on the host filesystem is invisible to it. terminal.docker_volumes
# is the bind mount. Read-only unless the mode is bidirectional — under pull-only or
# mirror-remote a local write is either ignored or reverted, and silently discarding
# the agent's work is worse than telling it the mount is read-only.
mount_opts=""
[ "$SYNC_MODE" = "bidirectional" ] || mount_opts=":ro"
mount="$VAULT_DIR:$CONTAINER_PATH$mount_opts"

# Merge into the existing list rather than replacing it: hermes may have other mounts
# configured, and dropping them here would be a silent regression. Any stale entry for
# this same host path is dropped first, so flipping SYNC_MODE rewrites the mount
# instead of leaving two conflicting ones.
existing=$(as_hermes bash -lc 'hermes config get terminal.docker_volumes' 2>/dev/null | tr -d '\r' || true)
case "$(printf '%s' "$existing" | tr -d '[:space:]')" in
  ''|null) existing='[]' ;;
  *) # Refuse rather than guess. Resetting the list on an unrecognised format would
     # silently delete mounts somebody added by hand — which is the exact failure this
     # merge exists to avoid.
     jq -e 'type == "array" and all(type == "string")' >/dev/null 2>&1 <<<"$existing" || {
       echo "terminal.docker_volumes is not a JSON array of strings — merge by hand:" >&2
       printf '%s\n' "$existing" >&2
       exit 1
     } ;;
esac
volumes=$(jq -cn --argjson cur "$existing" --arg p "$VAULT_DIR" --arg m "$mount" \
  '($cur | map(select(startswith($p + ":") | not))) + [$m]')

echo "==> mounting the vault into the sandbox: $mount"
as_hermes bash -lc "hermes config set terminal.docker_volumes '$volumes'"

# The sandbox container is long-lived, so it keeps the old mount table until it is
# recreated. Restarting the gateway is what forces that. Skipped when there is no
# gateway yet (Phase 4 not done), because then no container is running anyway.
if systemctl list-unit-files hermes-gateway.service >/dev/null 2>&1 &&
   systemctl is-active --quiet hermes-gateway; then
  echo "==> restarting the gateway so the sandbox picks up the mount"
  "$HERMES_HOME/.local/bin/hermes" gateway restart --system
fi

# --- 7. verify ---------------------------------------------------------------
# Not just "the unit is up": that the client thinks the vault is linked, and that the
# mount is actually visible from inside a sandbox container with the expected
# writability. The container check is the only one that proves the agent can use it.
echo "==> verifying"
"$OB" sync-status --path "$VAULT_DIR"

# The container reports what the mount actually is; the shell decides whether that is
# what the mode asked for. The rm runs on both paths — if a supposedly read-only mount
# turns out writable, the check has to fail *and* not leave a file to sync everywhere.
expect=ro
[ "$SYNC_MODE" != "bidirectional" ] || expect=rw
image=$(as_hermes bash -lc "hermes config get terminal.docker_image")
got=$(as_hermes docker run --rm -v "$mount" "$image" sh -c "
  [ -d $CONTAINER_PATH ] || { echo absent; exit 0; }
  if touch $CONTAINER_PATH/.hermes-mount-check 2>/dev/null; then
    rm -f $CONTAINER_PATH/.hermes-mount-check
    echo rw
  else
    echo ro
  fi")
[ "$got" = "$expect" ] || { echo "vault mount is '$got' inside the sandbox, expected '$expect'" >&2; exit 1; }
echo "==> vault ready at $VAULT_DIR ($CONTAINER_PATH in the sandbox, $SYNC_MODE)"

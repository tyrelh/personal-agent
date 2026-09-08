#!/bin/bash
# Obsidian vault on the box: the headless Sync client, a continuous sync unit, and the
# ownership that lets both the sync daemon and the agent write to the same directory.
#
# The agent's shell runs on the host (terminal.backend local), so the vault needs no
# mount and no wiring to be visible to it — it is a directory on the filesystem the
# agent already has. All this file has to get right is who owns it.
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
SYNC_MODE="${SYNC_MODE:-bidirectional}"   # or pull-only / mirror-remote (read-only)
HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="/home/$HERMES_USER"
FORCE="${FORCE:-0}"
# The literals are the normal case now that nothing templates this script; deploy.sh
# forwards SECRET_ID/REGION only when they are set in its own environment.
SECRET_ID="${SECRET_ID:-hermes}"
REGION="${REGION:-ca-west-1}"
# A 2FA code, when one is needed. Environment only, never the secret: it is valid for
# about thirty seconds, so storing it would be meaningless.
OBSIDIAN_MFA="${OBSIDIAN_MFA:-}"

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
# session then lives in root's home, out of reach of the hermes user the agent runs as.
# That session is the whole Obsidian account — every vault on it — while the vault
# directory is one vault's notes. The agent gets the notes, not the account, and that
# split is the only reason anything here still runs as root.
#
# The probe is sync-list-remote, not `ob login`. `ob login` with no arguments is
# documented as printing account info when a session exists, but it exits 0 with no
# output when logged *out* too, so it cannot tell you anything. sync-list-remote is a
# real authenticated call: exit 2 and "No account logged in" when there is no session.
#
# Skipping the login when a session already exists is what makes 2FA workable. The
# session is stored, so an account with 2FA needs exactly one interactive login ever;
# every run after that is unattended.
#
# `ob login` takes no --json (its only options are --email, --password and --mfa), so
# stdin comes from /dev/null — a prompt then gets EOF and fails instead of hanging.
# ponytail: the password goes on argv, so it is in /proc/<pid>/cmdline for the life of
# one command. There is no token or stdin path in the client today; switch to one if
# it ever lands.
if "$OB" sync-list-remote --json </dev/null >/dev/null 2>&1; then
  echo "==> already logged in to Obsidian"
else
  echo "==> logging in to Obsidian as $OBSIDIAN_EMAIL"
  "$OB" login --email "$OBSIDIAN_EMAIL" --password "$OBSIDIAN_PASSWORD" \
    ${OBSIDIAN_MFA:+--mfa "$OBSIDIAN_MFA"} </dev/null >/dev/null || {
    cat >&2 <<'LOGIN_HELP_EOF'

login failed. If the account has 2FA enabled, an unattended run cannot answer it — the
code is valid for about thirty seconds. The session is stored once you log in, so this is
a one-time step and every later run skips it:

  ssh -t root@hermes ob login          # prompts for email, password and the code

Or hand a fresh code to this run:

  OBSIDIAN_MFA=123456 ./deploy.sh obsidian
LOGIN_HELP_EOF
    exit 1
  }
fi
unset OBSIDIAN_EMAIL OBSIDIAN_PASSWORD

# Running as root is what keeps the agent user from ever holding an Obsidian credential,
# and nothing enforces that — an `ob login` run as the wrong user is an easy mistake and
# leaves a token sitting in the agent's own home. Warn rather than act: clearing somebody
# else's session without asking is worse than telling them it is there.
if [ -e "$HERMES_HOME/.config/obsidian-headless/auth_token" ]; then
  echo "WARNING: $HERMES_USER holds an Obsidian session at ~/.config/obsidian-headless." >&2
  echo "         That is an account credential inside the agent's home. Clear it with:" >&2
  echo "           sudo -u $HERMES_USER -H ob logout" >&2
fi

# --- 4. vault ----------------------------------------------------------------
# Two writers at two uids: the sync daemon runs as root (section 3 — it holds the
# Obsidian session) and the agent's shell runs as hermes on this host. Group ownership
# is what lets both work on the same files. root ignores modes, so only the hermes side
# needs spelling out: the group is hermes, the setgid bit keeps new subdirectories in
# that group, and the umask in section 5 — on the unit and on the one-shot sync — is
# what stops root's own writes landing 644 and read-only to the agent.
#
# Group write is also the read-only switch. Under pull-only or mirror-remote a local
# edit is either ignored or reverted on the next sync, and silently discarding the
# agent's work is worse than refusing the write outright — so the group loses w and the
# agent gets EACCES instead of a note that quietly disappears.
if [ "$SYNC_MODE" = "bidirectional" ]; then
  dir_mode=2770
  file_mode=660
  sync_umask=0007
else
  dir_mode=2750
  file_mode=640
  sync_umask=0027
fi

echo "==> vault ownership: root:$HERMES_USER, $dir_mode ($SYNC_MODE)"
mkdir -p "$VAULT_DIR"
# Applied on every run rather than only at creation: the mode encodes SYNC_MODE, so
# flipping that has to rewrite what is already on disk, and a re-run inherits whatever
# the previous mode's daemon had already pulled down.
chown -R "root:$HERMES_USER" "$VAULT_DIR"
chmod "$dir_mode" "$VAULT_DIR"
find "$VAULT_DIR" -mindepth 1 -type d -exec chmod "$dir_mode" {} +
find "$VAULT_DIR" -mindepth 1 -type f -exec chmod "$file_mode" {} +

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
# Stop the daemon before the one-shot sync below. The client refuses two sync instances
# for the same vault, so on a re-run the one-shot would fail with "Another sync instance
# is already running" instead of checking anything. It gets started again at the end of
# this section either way.
if systemctl cat obsidian-sync >/dev/null 2>&1; then
  echo "==> stopping obsidian-sync for the one-shot check"
  systemctl stop obsidian-sync
fi

# One-shot `ob sync` first: it is the check that the login and the E2EE password are
# both right, and it fails loudly here instead of into journalctl. It also means the
# vault has content before the agent can look at it.
#
# The umask is the same one the unit gets below, and it has to be here too: this is
# root's shell, so without it the first run — the one that pulls the whole vault — lands
# every file 644 and read-only to the agent. Section 4's chmod pass already ran, and on a
# first run it ran over an empty directory. A subshell so it does not leak to the units
# and files written after this point.
echo "==> initial sync (first run pulls the whole vault)"
( umask "$sync_umask"; "$OB" sync --path "$VAULT_DIR" )

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
# The daemon is root and the agent is hermes, sharing the vault by group (section 4).
# Without this every file root pulls down lands 644 — readable to the agent, not
# writable — and editing a synced note fails. Follows SYNC_MODE for the same reason the
# modes do: under pull-only the agent must not be able to write what the daemon pulls.
UMask=$sync_umask
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

# --- 6. verify ---------------------------------------------------------------
echo "==> verifying"
"$OB" sync-status --path "$VAULT_DIR"

# Checked at the agent's uid, not root's: root passes every one of these whatever the
# mode says, which is precisely why checking as root proves nothing. `if` rather than
# `&&`, so a failing test is a branch and not a set -e exit.
if ! as_hermes test -r "$VAULT_DIR"; then
  echo "$HERMES_USER cannot read $VAULT_DIR" >&2
  exit 1
fi
if [ "$SYNC_MODE" = "bidirectional" ]; then
  if ! as_hermes test -w "$VAULT_DIR"; then
    echo "$HERMES_USER cannot write $VAULT_DIR — expected write under $SYNC_MODE" >&2
    exit 1
  fi
elif as_hermes test -w "$VAULT_DIR"; then
  echo "$VAULT_DIR is writable by $HERMES_USER — expected read-only under $SYNC_MODE" >&2
  exit 1
fi

# One real agent tool call, because the shell the agent actually gets is the thing under
# test. The container version of this script once checked the mount by hand, passed, and
# left a box where the vault was invisible to the agent; the same trap applies to testing
# this with sudo and calling it done.
echo "==> checking the agent can see the vault"
as_hermes bash -lc "hermes -z 'Use the terminal tool to run exactly: ls -d $VAULT_DIR. Reply with the raw output only.'" \
  | grep -qx "$VAULT_DIR" \
  || { echo "the agent's shell cannot see $VAULT_DIR" >&2; exit 1; }

# --- 7. tell the agent the vault exists -------------------------------------
# Reachable is not the same as known: nothing in the agent's context mentions a vault,
# so asked "where are my notes" it has no reason to look in /srv. AGENTS.md is
# auto-injected into every
# session (alongside SOUL.md and memory), which makes it the place to say so.
#
# It has to sit in the directory the hermes process actually runs from, and injection
# does NOT walk up the tree — verified: a file at ~/AGENTS.md is invisible to the gateway,
# whose WorkingDirectory is ~/.hermes. So this goes in ~/.hermes, not the home directory.
#
# Written as a delimited block that is stripped and re-added on each run, so anything else
# in the file — the user's own instructions, a later phase's — survives.
agents_md="$HERMES_HOME/.hermes/AGENTS.md"
block_begin="<!-- BEGIN hermes-obsidian (managed by install_obsidian.sh) -->"
block_end="<!-- END hermes-obsidian -->"

if [ "$SYNC_MODE" = "bidirectional" ]; then
  writes="Files you create or edit there sync to every device on the account within
seconds, so treat it as the user's live notes, not a scratch directory."
else
  writes="It is read-only to you ($SYNC_MODE): you can read the notes but not change
them, and a write will fail with a permission error rather than propagate."
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if [ -f "$agents_md" ]; then
  awk -v b="$block_begin" -v e="$block_end" '
    $0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }
  ' "$agents_md" > "$tmp"
fi
cat >> "$tmp" <<AGENTS_EOF
$block_begin
## Obsidian vault

The user's Obsidian vault "$OBSIDIAN_VAULT" is on this machine at \`$VAULT_DIR\`. It is a
real Obsidian vault kept in sync by the headless Sync client, so it is the same notes
the user reads on their phone and laptop.

$writes

Read \`$VAULT_DIR/AGENTS.md\` if it exists — it holds the user's own conventions for
how the vault is organised.
$block_end
AGENTS_EOF

echo "==> telling the agent about the vault in ~/.hermes/AGENTS.md"
mv "$tmp" "$agents_md"
trap - EXIT
chown "$HERMES_USER:$HERMES_USER" "$agents_md"
chmod 644 "$agents_md"

echo "==> vault ready at $VAULT_DIR ($SYNC_MODE)"

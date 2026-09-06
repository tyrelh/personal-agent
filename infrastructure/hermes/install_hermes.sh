#!/bin/bash
# Phase 2 — install and configure Hermes on a fresh box.
#
# Run as root over Tailscale SSH; it drops to the `hermes` user for everything that
# is not apt. Self-contained on purpose, so it works piped at a box that has nothing
# on it yet. Safe to re-run: an existing install is left alone unless FORCE=1, and
# the env/config steps converge rather than append.
#
#   ssh root@hermes 'bash -s' < install_hermes.sh
#
# Pin a version with HERMES_COMMIT=<sha> (the installer's --commit; it refuses to
# roll an existing install backwards without --force-commit).
set -euo pipefail

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="/home/$HERMES_USER"
MODEL_DEFAULT="${MODEL_DEFAULT:-kimi/kimi-k3}"
FORCE="${FORCE:-0}"
# At boot, user_data.sh passes the terraform-templated values for these two; the
# literals are only the fallback for piping this at a bare box by hand.
SECRET_ID="${SECRET_ID:-hermes}"
REGION="${REGION:-ca-west-1}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
id "$HERMES_USER" >/dev/null 2>&1 || { echo "no $HERMES_USER user — run user_data.sh first" >&2; exit 1; }

# Always cd into the user's home before dropping privileges: uv resolves config by
# walking up from the *current* directory, so running from /root makes it die on
# /root/.venv even though -H sets HOME correctly.
as_hermes() { cd "$HERMES_HOME" && sudo -u "$HERMES_USER" -H "$@"; }

# --- 1. system packages ------------------------------------------------------
# The only part of the install needing root, so it happens here and the hermes user
# never gets sudo. build-essential is required (node-pty compiles); ripgrep and
# ffmpeg are optional, but the installer only warns and silently degrades without them.
echo "==> system packages"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -qq
apt-get install -y -qq build-essential ripgrep ffmpeg libatomic1

# --- 2. docker ---------------------------------------------------------------
# Phase 3: agent shell commands run in a container instead of on the host. Ubuntu's
# docker.io rather than docker-ce — one apt line, no third-party apt repo, and
# nothing here wants a newer engine.
echo "==> docker"
apt-get install -y -qq docker.io

# Containers inherit the host's resolv.conf *except* when it points at a loopback
# resolver, which noble's systemd-resolved does (127.0.0.53). Docker then silently
# substitutes its own public defaults (8.8.8.8), which the security group has no
# egress rule for — so every lookup inside every container hangs until it times out.
# Point the daemon at the VPC resolver the host is actually using.
# Log rotation is here for the same reason everything else on a 30GB root volume is:
# the default json-file driver never rotates.
resolver=$(awk '/^nameserver/ {print $2; exit}' /run/systemd/resolve/resolv.conf)
[ -n "$resolver" ] || { echo "no upstream resolver in /run/systemd/resolve/resolv.conf" >&2; exit 1; }
daemon_json=$(jq -n --arg dns "$resolver" '{
  dns: [$dns],
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}')
if [ "$(cat /etc/docker/daemon.json 2>/dev/null)" != "$daemon_json" ]; then
  printf '%s\n' "$daemon_json" > /etc/docker/daemon.json
  systemctl restart docker
fi

# The agent itself never reaches this group: its shell is inside the container and
# no docker socket is mounted there. It is the backend, running as hermes on the
# host, that has to talk to the daemon.
# ponytail: docker group is root-equivalent on the host for anything that does
# escape the container. Rootless docker closes that; it costs a userns AppArmor
# profile on noble. Worth doing if this ever has to hold against a hostile agent
# rather than a wrong one.
usermod -aG docker "$HERMES_USER"

# --- 3. hermes itself --------------------------------------------------------
# Browser and computer-use are skipped: they pull Playwright's Chromium, the largest
# and least reliable part of the install, and nothing before Phase 4 needs them.
if [ "$FORCE" != "1" ] && ver=$(as_hermes bash -lc 'hermes --version' 2>/dev/null | head -1) && [ -n "$ver" ]; then
  echo "==> hermes already present ($ver) — skipping; FORCE=1 to reinstall"
else
  echo "==> installing hermes (several minutes)"
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o /tmp/hermes-install.sh
  chmod 644 /tmp/hermes-install.sh
  as_hermes bash /tmp/hermes-install.sh \
    --skip-setup --skip-browser --skip-computer-use --non-interactive \
    ${HERMES_COMMIT:+--commit "$HERMES_COMMIT"}
fi

# --- 4. secrets --------------------------------------------------------------
# Lives at /usr/local/bin so the Phase 4 gateway unit can call it from ExecStartPre;
# rotation is then "update the secret, restart the unit". Written here rather than
# shipped as a second file so this script stays pipeable at a bare box.
echo "==> installing hermes-render-env"
# The defaults are baked in from this script's own SECRET_ID/REGION, so the
# terraform-templated values passed at boot become the on-disk defaults — one
# source of truth. A per-run SECRET_ID=/REGION= override still wins.
cat > /usr/local/bin/hermes-render-env <<RENDER_HEAD_EOF
#!/bin/bash
# Renders the hermes secret into ~/.hermes/.env.
# Runs as the hermes user — it needs that user's HOME and the instance role.
SECRET_ID="\${SECRET_ID:-$SECRET_ID}"
REGION="\${REGION:-$REGION}"
RENDER_HEAD_EOF
cat >> /usr/local/bin/hermes-render-env <<'RENDER_EOF'
set -euo pipefail
umask 077

ENV_FILE="$HOME/.hermes/.env"

# Write via a temp file: a failed API call must not leave a truncated .env behind.
tmp=$(mktemp "$ENV_FILE.XXXXXX")
trap 'rm -f "$tmp"' EXIT

# TAILSCALE_AUTH_KEY is consumed by user-data at boot and is not a Hermes variable;
# keep it out of a file read by an agent that has shell access. MOONSHOT_API_KEY is
# the name the key is stored under; Hermes' native Kimi/Moonshot provider reads
# KIMI_API_KEY. Rename the key in the secret and this clause can go.
/snap/bin/aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" \
  --region "$REGION" \
  --query SecretString --output text \
  | jq -r '
      del(.TAILSCALE_AUTH_KEY)
      | with_entries(if .key == "MOONSHOT_API_KEY" then .key = "KIMI_API_KEY" else . end)
      | to_entries[]
      | select(.value != "")
      | "\(.key)=\(.value)"
    ' > "$tmp"

[ -s "$tmp" ] || { echo "render_env: secret produced no keys, refusing to write" >&2; exit 1; }

chmod 600 "$tmp"
mv "$tmp" "$ENV_FILE"
trap - EXIT
RENDER_EOF
chmod 755 /usr/local/bin/hermes-render-env

# Overwrites the commented template the installer drops at ~/.hermes/.env; that
# template survives as ~/.hermes/hermes-agent/.env.example.
echo "==> rendering .env from Secrets Manager"
as_hermes /usr/local/bin/hermes-render-env

# --- 5. config ---------------------------------------------------------------
# model.default: the shipped default is anthropic/claude-opus-4.6, which has no key.
#
# The rest is Phase 3 hardening. Under the docker backend the container *is* the
# security boundary, so Hermes skips the dangerous-command approval stack entirely —
# which is the point: no prompt to answer, and nothing it runs touches the host.
# container_memory: the shipped 5120MB is more memory than this box has, so a runaway
# container would take the gateway down with it rather than hit its own cap first.
# The two approvals keys are already the shipped defaults, pinned so an upstream
# change to either is a diff here rather than a silent policy change on a headless
# box. They decide what a cron job does when it hits a dangerous command with nobody
# around to approve it.
echo "==> config"
# set -e inside the shell too: without it only the last command's status escapes, and
# a failed set in the middle of the list would pass silently.
as_hermes bash -lc "
  set -e
  hermes config set model.default '$MODEL_DEFAULT'
  hermes config set terminal.backend docker
  hermes config set terminal.container_memory 2048
  hermes config set approvals.mode smart
  hermes config set approvals.cron_mode deny
"

# --- 6. verify ---------------------------------------------------------------
# A real completion through the configured provider — the only check proving the
# key, the base URL and the model slug all line up.
echo "==> verifying"
as_hermes bash -lc "hermes -z 'Reply with exactly: hermes online. Do not use any tools.'"

# Pull the sandbox image here rather than let the first agent command block on ~1GB
# of registry traffic; skipped once it is local, so a re-run costs no registry round
# trip. The throwaway container after it is the check on the daemon-DNS fix above —
# name resolution inside a container is the part that fails silently.
image=$(as_hermes bash -lc "hermes config get terminal.docker_image")
echo "==> sandbox image: $image"
as_hermes docker image inspect "$image" >/dev/null 2>&1 || as_hermes docker pull -q "$image"
as_hermes docker run --rm "$image" \
  sh -c 'getent hosts api.moonshot.ai >/dev/null && echo container-dns-ok' \
  | grep -qx container-dns-ok

as_hermes bash -lc 'hermes --version' | head -1

# --- 7. gateway (Phase 4) ----------------------------------------------------
# Only once the Slack tokens are actually in the secret; until then this is a no-op,
# so the script stays runnable on a box that has no chat platform yet.
#
# System unit rather than a --user one: root can restart it over Tailscale SSH, and
# it starts at boot without depending on the hermes user's linger. It still runs as
# hermes — never root.
env_file="$HERMES_HOME/.hermes/.env"
if ! grep -q '^SLACK_BOT_TOKEN=' "$env_file"; then
  echo "==> no SLACK_BOT_TOKEN in the secret — skipping the gateway (Phase 4)"
else
  # Fail closed. An unset allowlist means deny-all, so the bot would install, start,
  # connect, and then ignore every message — a failure that looks like a Slack
  # problem. GATEWAY_ALLOW_ALL_USERS is never the fix.
  grep -q '^SLACK_ALLOWED_USERS=.' "$env_file" || {
    echo "SLACK_BOT_TOKEN is set but SLACK_ALLOWED_USERS is empty — refusing to install a deny-all gateway" >&2
    exit 1
  }

  echo "==> installing the gateway service"
  # Run as root, not as hermes: a --system install writes to /etc/systemd/system and
  # the CLI refuses it from a non-root uid. --run-as-user is what keeps the unit's
  # User= (and its remapped HERMES_HOME) pointed at hermes rather than root.
  # --force so a re-run converges the unit rather than leaving a stale one; the start
  # is deferred until the drop-in below exists.
  "$HERMES_HOME/.local/bin/hermes" gateway install --system \
    --run-as-user "$HERMES_USER" --force --no-start-now --start-on-login

  # The unit hermes generates has no ExecStartPre, so rotation is a drop-in: re-render
  # .env from Secrets Manager on every start. Rotating a key is then "update the
  # secret, restart the unit". A drop-in rather than an edit — hermes compares the
  # installed unit against what it would generate and reports an edited one as drift.
  mkdir -p /etc/systemd/system/hermes-gateway.service.d
  cat > /etc/systemd/system/hermes-gateway.service.d/10-render-env.conf <<'DROPIN_EOF'
[Service]
# Runs as the unit's User= (hermes) with its HOME, which is what render-env needs.
ExecStartPre=/usr/local/bin/hermes-render-env
DROPIN_EOF
  systemctl daemon-reload
  systemctl restart hermes-gateway
  systemctl is-active --quiet hermes-gateway || { systemctl status --no-pager -l hermes-gateway; exit 1; }
  echo "==> gateway running"
fi

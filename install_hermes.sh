#!/bin/bash
# Phase 2 — install and configure Hermes on a fresh box.
#
# Run as root on the box, copied there and started by ./deploy.sh; it drops to the
# `hermes` user for everything that is not apt. Self-contained on purpose, so it also
# works piped at a box that has nothing on it yet. Safe to re-run: an existing install is
# left alone unless FORCE=1, and the env/config steps converge rather than append.
#
#   ./deploy.sh hermes
#   ssh root@hermes 'bash -s' < install_hermes.sh
#
# Pin a version with HERMES_COMMIT=<sha> (the installer's --commit; it refuses to
# roll an existing install backwards without --force-commit).
set -euo pipefail

HERMES_USER="${HERMES_USER:-hermes}"
HERMES_HOME="/home/$HERMES_USER"
MODEL_DEFAULT="${MODEL_DEFAULT:-kimi/kimi-k3}"
FORCE="${FORCE:-0}"
# The literals are the normal case now that nothing templates this script; deploy.sh
# forwards SECRET_ID/REGION only when they are set in its own environment.
SECRET_ID="${SECRET_ID:-hermes}"
REGION="${REGION:-ca-west-1}"

[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
id "$HERMES_USER" >/dev/null 2>&1 || { echo "no $HERMES_USER user — run user_data.sh first" >&2; exit 1; }

# Always cd into the user's home before dropping privileges: uv resolves config by
# walking up from the *current* directory, so running from /root makes it die on
# /root/.venv even though -H sets HOME correctly.
as_hermes() { cd "$HERMES_HOME" && sudo -u "$HERMES_USER" -H "$@"; }

# --- 1. system packages ------------------------------------------------------
# The only part of the install needing root, apart from the units in sections 6-7 and
# the single sudoers line section 7 needs. build-essential is required (node-pty
# compiles); ripgrep and ffmpeg are optional, but the installer only warns and silently
# degrades without them.
echo "==> system packages"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -qq
apt-get install -y -qq build-essential ripgrep ffmpeg libatomic1

# --- 2. no sandbox -----------------------------------------------------------
# The agent's shell runs on the host, as the hermes user, with the whole filesystem in
# reach. The isolation boundary is the VM, not a container: this box exists to run this
# agent, its security group has no ingress, and everything on it is either the agent's
# own or was deliberately handed to it. A container inside that adds a second boundary
# whose main practical effect is that ordinary things — the Obsidian vault, a checkout,
# a file the user asks about — need a bind mount before the agent can see them at all.
#
# Converge a box that ran the earlier container setup: drop the docker group, which is
# root-equivalent on the host and nothing needs any more, and stop the daemon. The
# package is left installed; purging it is a one-liner when the disk is wanted back:
#   apt-get purge -y docker.io && rm -rf /var/lib/docker
echo "==> no sandbox: the agent's shell runs on the host"
if id -nG "$HERMES_USER" | tr ' ' '\n' | grep -qx docker; then
  echo "==> removing $HERMES_USER from the docker group"
  gpasswd -d "$HERMES_USER" docker >/dev/null
fi
if systemctl cat docker.service >/dev/null 2>&1; then
  echo "==> stopping the docker daemon"
  systemctl disable --now docker.socket docker.service >/dev/null 2>&1 || true
fi

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
# The defaults are baked in from this script's own SECRET_ID/REGION, so whatever this
# run used becomes the on-disk default — one source of truth. A per-run
# SECRET_ID=/REGION= override still wins.
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

# The first with_entries is the denylist: boot-only secrets that are not Hermes
# variables and must not reach a file read by an agent with shell access.
# TAILSCALE_AUTH_KEY is consumed by user-data at boot; the OBSIDIAN_* keys are read
# from the secret directly by install_obsidian.sh, as root, and are the stronger case —
# that email and password are access to every vault on the account. Add the next
# boot-only key or prefix to this one clause.
#
# MOONSHOT_API_KEY is the name the key is stored under; Hermes' native Kimi/Moonshot
# provider reads KIMI_API_KEY. Rename the key in the secret and that clause can go.
/snap/bin/aws secretsmanager get-secret-value \
  --secret-id "$SECRET_ID" \
  --region "$REGION" \
  --query SecretString --output text \
  | jq -r '
      with_entries(select(.key | . != "TAILSCALE_AUTH_KEY" and (startswith("OBSIDIAN_") | not)))
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

# --- 4. config ---------------------------------------------------------------
# model.default: the shipped default is anthropic/claude-opus-4.6, which has no key.
#
# The approvals block is the rest of it, and it only matters now that the backend is
# local. Under a container backend Hermes skips the dangerous-command approval stack
# entirely — the container was the boundary — so these keys were decoration. With the
# shell on the host they are live again, and all four of them fail closed by default:
# on a box with nobody sitting at a terminal, an approval prompt is a command that
# blocks until it times out. That is the wrong answer here, so all four are opened:
#
#   mode off            — no approval prompt at all (what --yolo sets)
#   cron_mode           \
#   single_query_mode    > approve rather than deny: a cron job, a -q session and an
#   unattended_mode     /  unattended platform (the Slack gateway is one) have no
#                          channel to answer a prompt on, so deny is not "ask someone",
#                          it is "block the command".
#
# approvals.deny is left at its shipped empty list. It is a glob denylist that bites
# even under mode=off, which makes it the place for a specific command that must never
# run on this box — not a general safety net.
echo "==> config"
# set -e inside the shell too: without it only the last command's status escapes, and
# a failed set in the middle of the list would pass silently.
as_hermes bash -lc "
  set -e
  hermes config set model.default '$MODEL_DEFAULT'
  hermes config set terminal.backend local
  hermes config set approvals.mode off
  hermes config set approvals.cron_mode approve
  hermes config set approvals.single_query_mode approve
  hermes config set approvals.unattended_mode approve
"

# Converge a box that ran the container setup. These keys are inert under the local
# backend, and terminal.docker_volumes in particular is a stale record of a bind mount
# that no longer means anything — left in the file it reads as configuration that is
# still doing something. `config unset` exits nonzero on a key that is already gone.
for key in terminal.container_memory terminal.container_cpu terminal.container_disk \
           terminal.container_persistent terminal.docker_volumes \
           terminal.docker_mount_cwd_to_workspace; do
  as_hermes bash -lc "hermes config unset $key" >/dev/null 2>&1 || true
done

# --- 5. verify ---------------------------------------------------------------
# A real completion through the configured provider — the only check proving the
# key, the base URL and the model slug all line up.
echo "==> verifying"
as_hermes bash -lc "hermes -z 'Reply with exactly: hermes online. Do not use any tools.'"

# The check on section 4. Under the container backend this same call answered with a
# container id and `root`; on the host it has to answer with this user. A wrong answer
# means terminal.backend did not take and the agent is still boxed in — which would
# otherwise surface much later as an empty vault rather than as an error here.
echo "==> checking the agent's shell runs on the host"
as_hermes bash -lc "hermes -z 'Use the terminal tool to run exactly: id -un. Reply with the raw output only.'" \
  | grep -qx "$HERMES_USER" \
  || { echo "the agent's shell does not report id -un = $HERMES_USER — the backend is not local" >&2; exit 1; }

as_hermes bash -lc 'hermes --version' | head -1

# --- 6. gateway (Phase 4) ----------------------------------------------------
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
  # The CLI's own restart, not systemctl: it first rewrites the unit to match what
  # this install would generate. `install --force` alone leaves a unit that `hermes
  # gateway status` then reports as outdated — the generated PATH order depends on
  # the invoking environment. It also drains in-flight turns before stopping, so a
  # re-run mid-conversation waits rather than cutting the agent off.
  "$HERMES_HOME/.local/bin/hermes" gateway restart --system
  systemctl is-active --quiet hermes-gateway || { systemctl status --no-pager -l hermes-gateway; exit 1; }
  echo "==> gateway running"
fi

# --- 7. dashboard ------------------------------------------------------------
# The web UI on the tailnet and nowhere else: hermes binds loopback, `tailscale
# serve` is the only thing in front of it, so the security group keeps its empty
# ingress and TLS is tailscaled's problem rather than this box's.
#
# Exposure implies a password here structurally, not by policy. The Host-header
# middleware rejects anything whose Host is not the bound interface, so the
# proxied tailnet name only works once it is declared in `dashboard.public_url` —
# and a non-loopback public_url engages the auth gate, which refuses to start
# with no auth provider registered. No password in the secret, no dashboard.
env_val() { sed -n "s/^$1=//p" "$env_file" | head -1; }
dash_user=$(env_val HERMES_DASHBOARD_BASIC_AUTH_USERNAME)
if [ -z "$dash_user" ]; then
  echo "==> no HERMES_DASHBOARD_BASIC_AUTH_USERNAME in the secret — skipping the dashboard"
  # Converge rather than merely skip. A dashboard from an earlier run would keep
  # restarting into the auth-gate refusal now that its password has left the
  # secret — Restart=always plus a config the server refuses to bind is a crash
  # loop, so pulling the credentials out of the secret has to be a real teardown.
  # Guarded on our own unit file: a box that never had a dashboard has no serve
  # config of ours to switch off.
  if [ -f /etc/systemd/system/hermes-dashboard.service ]; then
    echo "==> removing the dashboard an earlier run installed"
    systemctl disable --now -q hermes-dashboard
    rm -f /etc/systemd/system/hermes-dashboard.service /etc/sudoers.d/hermes-dashboard
    systemctl daemon-reload
    tailscale serve --http=80 off >/dev/null 2>&1 || true
    tailscale serve --https=443 off >/dev/null 2>&1 || true
    as_hermes bash -lc 'hermes config unset dashboard.public_url' >/dev/null
  fi
else
  # Same fail-closed shape as the gateway's allowlist: half-configured credentials
  # make the plugin skip registration, and the server then exits at bind time with
  # "no auth providers are registered" — a startup crash that looks like a bug.
  # The plaintext password is the one the secret carries; the plugin hashes it at
  # startup, and `_PASSWORD_HASH` is deliberately unused here — a precomputed hash
  # buys nothing on a box whose .env already holds every other key in the secret.
  if [ -z "$(env_val HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)" ]; then
    echo "HERMES_DASHBOARD_BASIC_AUTH_USERNAME is set but HERMES_DASHBOARD_BASIC_AUTH_PASSWORD is not — refusing to install a dashboard that cannot authenticate" >&2
    exit 1
  fi

  ts_name=$(tailscale status --json | jq -r '.Self.DNSName // ""' | sed 's/\.$//')
  [ -n "$ts_name" ] || { echo "no tailnet name from tailscale status — is this box on the tailnet?" >&2; exit 1; }

  # https is `tailscale serve`'s default mode but needs a cert, which the tailnet
  # only issues once HTTPS Certificates is switched on in the admin console. When
  # it is off, http is the honest answer: the hop is still inside WireGuard, and
  # the auth cookies drop their __Host-/Secure prefixes to match the scheme.
  if tailscale status --json | jq -e --arg n "$ts_name" '(.CertDomains // []) | index($n)' >/dev/null; then
    scheme=https
    serve_flag=--https=443
  else
    scheme=http
    serve_flag=--http=80
    echo "==> tailnet HTTPS certs are off — serving over http; enable them in the admin console and re-run for TLS"
  fi

  # Declares the external URL *and* trusts its Host/Origin. One key, because they
  # are the same fact: this is the name the dashboard is reached by.
  echo "==> dashboard public URL: $scheme://$ts_name"
  as_hermes bash -lc "hermes config set dashboard.public_url '$scheme://$ts_name'"

  # No `hermes dashboard install` exists, so the unit is written here. Everything
  # below the ExecStart mirrors the gateway unit hermes generates for itself —
  # same interpreter, same environment, same ExecStartPre re-render of .env so
  # rotating the password is "update the secret, restart the unit".
  #
  # `dashboard --no-open`, NOT `serve`: they are the same server, but `serve` sets
  # HERMES_SERVE_HEADLESS, which leaves the SPA unmounted — a backend for the
  # desktop app, with no web UI at any path. `dashboard` also builds the frontend
  # when the source hash moved, which is what keeps this self-healing across a
  # `hermes update` instead of quietly serving a stale bundle.
  cat > /etc/systemd/system/hermes-dashboard.service <<UNIT_EOF
[Unit]
Description=Hermes Agent Dashboard - web UI behind tailscale serve
After=network-online.target tailscaled.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$HERMES_USER
Group=$HERMES_USER
ExecStartPre=/usr/local/bin/hermes-render-env
ExecStart=$HERMES_HOME/.hermes/hermes-agent/venv/bin/python -m hermes_cli.main dashboard --no-open --host 127.0.0.1 --port 9119
WorkingDirectory=$HERMES_HOME/.hermes
Environment="HOME=$HERMES_HOME"
Environment="USER=$HERMES_USER"
Environment="LOGNAME=$HERMES_USER"
Environment="PATH=$HERMES_HOME/.hermes/node:$HERMES_HOME/.hermes/hermes-agent/venv/bin:$HERMES_HOME/.hermes/hermes-agent/node_modules/.bin:$HERMES_HOME/.hermes/node/bin:$HERMES_HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="VIRTUAL_ENV=$HERMES_HOME/.hermes/hermes-agent/venv"
# NOT $HERMES_HOME: that is the unix home, and hermes' HERMES_HOME is the data
# directory under it. Point this at /home/hermes and the server reads an empty
# auto-seeded config — no public_url, no credentials, an ungated dashboard and a
# 400 on every proxied request.
Environment="HERMES_HOME=$HERMES_HOME/.hermes"
Environment="HERMES_SUPERVISED_CHILD=1"
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF
  # `hermes update` restarts the runtimes it manages, and it runs as the hermes user —
  # so its `sudo -n systemctl restart hermes-dashboard.service` dies with "a password
  # is required" and the box keeps serving the pre-update frontend until someone
  # restarts the unit as root by hand. One sudoers line is what makes `hermes update`
  # finish on its own.
  #
  # Not an escalation: the unit lives in /etc/systemd/system and is root-owned, so this
  # permits restarting hermes' own dashboard and nothing else. Validated before it
  # lands — a syntactically broken file in sudoers.d breaks *every* sudo on the box.
  # Both spellings because sudo matches the argv it is given, not the unit.
  sudoers=/etc/sudoers.d/hermes-dashboard
  cat > "$sudoers.tmp" <<SUDOERS_EOF
$HERMES_USER ALL=(root) NOPASSWD: /usr/bin/systemctl restart hermes-dashboard.service, /usr/bin/systemctl restart hermes-dashboard
SUDOERS_EOF
  chmod 440 "$sudoers.tmp"
  visudo -cqf "$sudoers.tmp" || { echo "generated sudoers file is invalid — not installing it" >&2; rm -f "$sudoers.tmp"; exit 1; }
  mv "$sudoers.tmp" "$sudoers"

  systemctl daemon-reload
  systemctl enable -q hermes-dashboard
  # restart, not start: a re-run that changed public_url or the password has to
  # take, and the server reads both once at startup.
  systemctl restart hermes-dashboard

  # The server builds the web UI on start when the source hash moved (`hermes
  # update` is the usual reason), which is minutes on this box — and it is a
  # Type=simple unit, so systemd calls it started the moment it forks. Waiting on
  # the port is the only honest readiness check.
  echo "==> waiting for the dashboard to answer (a first start builds the web UI — minutes)"
  ready=0
  for _ in $(seq 1 120); do
    if curl -s -o /dev/null --max-time 5 http://127.0.0.1:9119/login; then ready=1; break; fi
    systemctl is-active --quiet hermes-dashboard || { journalctl -u hermes-dashboard -n 40 --no-pager; exit 1; }
    sleep 5
  done
  [ "$ready" = 1 ] || { echo "dashboard never answered on 127.0.0.1:9119" >&2; journalctl -u hermes-dashboard -n 40 --no-pager; exit 1; }

  # Declarative and stored in tailscaled's own state: re-running with the same
  # target changes nothing, and it survives a reboot without a unit of its own.
  tailscale serve --bg "$serve_flag" http://127.0.0.1:9119

  # End to end through tailscaled, which is what proves the Host/Origin trust and
  # the proxy hop, not just the loopback listener.
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$scheme://$ts_name/login")
  [ "$code" = 200 ] || { echo "dashboard reachable on loopback but returned $code via $scheme://$ts_name" >&2; exit 1; }
  echo "==> dashboard running — $scheme://$ts_name (login as $dash_user)"
fi

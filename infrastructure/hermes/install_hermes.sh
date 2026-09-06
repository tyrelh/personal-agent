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

# --- 2. hermes itself --------------------------------------------------------
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

# --- 3. secrets --------------------------------------------------------------
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

# --- 4. config ---------------------------------------------------------------
# The shipped default is anthropic/claude-opus-4.6, which has no key. Phase 3's
# hardening settings belong here too once they land.
echo "==> config"
as_hermes bash -lc "hermes config set model.default '$MODEL_DEFAULT'"

# --- 5. verify ---------------------------------------------------------------
# A real completion through the configured provider — the only check proving the
# key, the base URL and the model slug all line up.
echo "==> verifying"
as_hermes bash -lc "hermes -z 'Reply with exactly: hermes online. Do not use any tools.'"
as_hermes bash -lc 'hermes --version' | head -1

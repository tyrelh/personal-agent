#!/bin/bash
# no -x: the auth key must not land in the cloud-init log.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y jq ufw curl

# noble dropped the awscli deb; snap is the supported path. /snap/bin is not on
# cloud-init's PATH, and the snap seed isn't loaded yet this early in boot.
snap wait system seed.loaded
snap install aws-cli --classic
export PATH="$PATH:/snap/bin"

# Firewall first: survives an SG mistake. Only the tailnet gets in.
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw --force enable

curl -fsSL https://tailscale.com/install.sh | sh

# TS_AUTHKEY lives in the secret, not user-data (user-data is readable from IMDS
# and visible in the console). Ephemeral single-use key, so it expires on its own.
TS_AUTHKEY=$(aws secretsmanager get-secret-value \
  --secret-id "${secret_id}" \
  --region "${region}" \
  --query SecretString --output text | jq -r '.TAILSCALE_AUTH_KEY')

tailscale up --authkey "$TS_AUTHKEY" --ssh --advertise-tags=tag:hermes --hostname hermes
unset TS_AUTHKEY

# Non-root service user. Linger so its systemd units (the gateway, later) start at
# boot without a login session.
id hermes >/dev/null 2>&1 || useradd -m -s /bin/bash hermes
loginctl enable-linger hermes

# Tailscale SSH is up and is now the only interactive path; SSM stays as break-glass.
# Masked, not just disabled: socket activation would otherwise revive sshd.
systemctl disable --now ssh.socket ssh.service || true
systemctl mask ssh.socket ssh.service

# --- Phase 2 ----------------------------------------------------------------
# install_hermes.sh, injected verbatim by terraform's templatefile(). It lands on
# disk as well as running, so it stays re-runnable by hand later (FORCE=1 to
# reinstall) without going near cloud-init.
#
# Deliberately the LAST thing in this file. It is the slow, network-dependent,
# most-likely-to-fail step — roughly ten minutes, most of it a `curl | bash` of an
# upstream installer. Everything that makes the box reachable and locked down has
# already happened above, so if this fails the box still comes up on the tailnet
# with sshd masked and you can debug it over SSH. Pin the upstream with
# HERMES_COMMIT=<sha> below if a rebuild ever needs to match this one exactly.
cat > /usr/local/sbin/hermes-install <<'HERMES_INSTALL_EOF'
${install_hermes}
HERMES_INSTALL_EOF
chmod 755 /usr/local/sbin/hermes-install
SECRET_ID='${secret_id}' REGION='${region}' /usr/local/sbin/hermes-install

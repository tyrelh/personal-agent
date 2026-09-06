#!/bin/bash
# no -x: the auth key must not land in the cloud-init log.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y awscli jq ufw curl

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
  --query SecretString --output text | jq -r '.TS_AUTHKEY')

tailscale up --authkey "$TS_AUTHKEY" --ssh --advertise-tags=tag:hermes --hostname hermes
unset TS_AUTHKEY

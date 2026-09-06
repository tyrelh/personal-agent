# hermes infrastructure

Phase 0 of the Hermes agent plan: state backend, EC2 host, IAM.

## Apply

The `hermes` secret must already exist (see below) — terraform reads it as a data
source and fails the plan if it is missing.

```sh
terraform init
terraform plan
terraform apply
```

State lives in `s3://superflux-terraform-state/hermes.tfstate` (`ca-west-1`),
locked with S3 native locking. The bucket is bootstrapped by hand and is not managed here.

## Create the secret (once, by hand — before the first apply)

Terraform does not manage the secret at all: it looks it up by name so no key
material ever reaches state.

```sh
aws secretsmanager create-secret \
  --region ca-west-1 \
  --name hermes \
  --description "Hermes agent env blob: LLM keys, Slack tokens, Tailscale auth key" \
  --secret-string file://hermes.json
rm hermes.json
```

To rotate later, same thing with `put-secret-value --secret-id hermes`.

`hermes.json` (never commit it):

```json
{
  "ANTHROPIC_API_KEY": "",
  "MOONSHOT_API_KEY": "",
  "SLACK_BOT_TOKEN": "",
  "SLACK_APP_TOKEN": "",
  "SLACK_ALLOWED_USERS": "",
  "FIRECRAWL_API_KEY": "",
  "TAILSCALE_AUTH_KEY": ""
}
```

Use an ephemeral, pre-authorized, single-use Tailscale auth key.

## Access

No inbound rules and no SSH key on the instance. Get on the box with SSM:

```sh
aws ssm start-session --region ca-west-1 --target "$(terraform output -raw instance_id)"
```

After Phase 1, Tailscale SSH is the normal path and SSM is break-glass: `user_data.sh`
masks `ssh.socket`/`ssh.service`, so nothing listens on port 22 outside the tailnet.

```sh
ssh root@hermes   # over the tailnet
```

## Changing `user_data.sh`

Cloud-init runs user-data **once per instance-id**. Editing this file does nothing to a
running box. The rendered copy that actually ran lives on the instance at:

```
/var/lib/cloud/instance/scripts/part-001     # the script, template vars already filled
/var/log/cloud-init-output.log               # its output
```

Three ways to deploy a change, pick by how much state is on the box:

1. **Replace the instance** — the honest one, and the only one that proves the script.
   ```sh
   terraform apply -replace=aws_instance.hermes
   ```
   Put a fresh single-use `TAILSCALE_AUTH_KEY` in the secret first (the old one is burned)
   and remove the stale `hermes` node from the tailnet. Leaves an orphan root volume.
2. **Re-run cloud-init in place** — `cloud-init clean --logs && reboot`. Only safe if the
   script is idempotent. Right now it is not: `ufw --force reset` wipes the rules and
   `tailscale up --authkey` fails on a burned single-use key under `set -e`.
3. **Apply the change by hand over Tailscale SSH, then mirror it into this file.** What was
   done for the Phase 1 steps. `user_data.sh` then describes how a *rebuild* would reach the
   current state, not how this box did.

Note that `user_data_replace_on_change` is unset (defaults false), so a `user_data` diff is
pushed in place — Terraform stops and starts the instance and cloud-init still ignores the
new script. Downtime, no effect. Use one of the three above instead.

## Notes

- The live instance booted from an earlier version of this script that ran
  `apt-get install awscli`, which noble no longer ships. It failed there, before Tailscale,
  so `cloud-init status` reports `error` and the Phase 1 steps were applied by hand. The
  committed script installs the CLI from snap and is correct; a rebuild would run clean.
- Boot creates a non-root `hermes` service user with linger enabled; Hermes itself
  installs under that user (Phase 2). `unattended-upgrades` needs no setup — the
  Ubuntu cloud image ships it enabled.
- The root volume has `delete_on_termination = false`. `terraform destroy` leaves the
  volume behind on purpose — it holds `~/.hermes`. Delete it manually when you mean to.
- Egress includes TCP 80 and UDP 53 beyond the plan's 443/41641: Ubuntu's arm64 apt
  mirrors are plain HTTP and DNS must reach the VPC resolver. Drop them and the box
  cannot patch itself or resolve anything.
- The AMI comes from Canonical's SSM public parameter, but the instance ignores AMI
  changes so a new Canonical image never silently replaces the running agent. To move
  to a newer image: `terraform taint aws_instance.hermes` then apply, on purpose.

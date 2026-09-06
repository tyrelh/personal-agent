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

After Phase 1, Tailscale SSH is the normal path and SSM is break-glass.

## Notes

- The root volume has `delete_on_termination = false`. `terraform destroy` leaves the
  volume behind on purpose — it holds `~/.hermes`. Delete it manually when you mean to.
- Egress includes TCP 80 and UDP 53 beyond the plan's 443/41641: Ubuntu's arm64 apt
  mirrors are plain HTTP and DNS must reach the VPC resolver. Drop them and the box
  cannot patch itself or resolve anything.
- The AMI comes from Canonical's SSM public parameter, but the instance ignores AMI
  changes so a new Canonical image never silently replaces the running agent. To move
  to a newer image: `terraform taint aws_instance.hermes` then apply, on purpose.

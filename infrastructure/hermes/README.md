# hermes infrastructure

Phase 0 of the Hermes agent plan: state backend, EC2 host, secret container, IAM.

## Apply

```sh
terraform init
terraform plan
terraform apply
```

State lives in `s3://superflux-terraform-state/hermes/terraform.tfstate` (`ca-west-1`),
locked with S3 native locking. The bucket is bootstrapped by hand and is not managed here.

## Load the secret (once, by hand)

Terraform manages the secret *container* only. The value is loaded by CLI so no key
material ever reaches state.

```sh
aws secretsmanager put-secret-value \
  --region ca-west-1 \
  --secret-id hermes \
  --secret-string file://hermes.json
rm hermes.json
```

`hermes.json` (never commit it):

```json
{
  "ANTHROPIC_API_KEY": "",
  "MOONSHOT_API_KEY": "",
  "SLACK_BOT_TOKEN": "",
  "SLACK_APP_TOKEN": "",
  "SLACK_ALLOWED_USERS": "",
  "FIRECRAWL_API_KEY": "",
  "TS_AUTHKEY": ""
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

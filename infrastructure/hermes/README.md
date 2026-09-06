# hermes infrastructure

Phase 0 of the Hermes agent plan: state backend, EC2 host, IAM. Phases 1 and 2 —
base OS, Tailscale, and the Hermes install itself — run unattended at first boot:
`user_data.sh` does the base OS and ends by running `install_hermes.sh`, which
terraform injects into it. A fresh `terraform apply` reaches a verified agent with
no manual steps.

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

Keys are copied into `~/.hermes/.env` verbatim by `hermes-render-env`, so their names here
are the names Hermes reads — with two deliberate exceptions it handles for you,
`MOONSHOT_API_KEY` and `TAILSCALE_AUTH_KEY`. See Phase 2 below. Empty values are
skipped rather than rendered as blanks, so the placeholders above are harmless until
filled; only `MOONSHOT_API_KEY` and `TAILSCALE_AUTH_KEY` are set today.

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

The Phase 2 half is exempt from most of this. `install_hermes.sh` is injected into
`user_data.sh` but also written to `/usr/local/sbin/hermes-install`, and it is idempotent,
so a change to it deploys to a running box by re-running that file — no instance
replacement, no `cloud-init clean`. Only changes to the base-OS half above need one of the
three routes.

Note that `user_data_replace_on_change` is unset (defaults false), so a `user_data` diff is
pushed in place — Terraform stops and starts the instance and cloud-init still ignores the
new script. Downtime, no effect. Use one of the three above instead.

## Phase 2 — installing Hermes

`install_hermes.sh` is the whole of it, and **it runs itself at first boot** — terraform
injects it into `user_data.sh` with `file()`, which appends it as the last thing cloud-init
does. A new instance comes up with Hermes installed, keyed and verified; there is nothing
to run by hand.

It is injected with `file()` rather than `templatefile()` on purpose: the script is full of
shell expansions like `${HERMES_USER:-hermes}`, and only the *outer* template gets scanned
for interpolation, so an injected value passes through verbatim. Render it through
`templatefile()` too and terraform would try to resolve those as terraform variables and
fail the plan.

It also lands on disk at `/usr/local/sbin/hermes-install`, so it stays re-runnable later
without touching cloud-init — which is how you add something to an already-running box:

```sh
ssh root@hermes /usr/local/sbin/hermes-install          # converges; skips the install
ssh root@hermes 'FORCE=1 /usr/local/sbin/hermes-install' # reinstall over the top
```

Re-running is safe: an existing install is skipped, and the env and config steps converge
rather than append. It ends by asking the model a real question, which is the only check
that proves the key, the base URL and the model slug all line up. Piping it at a bare box
(`ssh root@hermes 'bash -s' < install_hermes.sh`) also still works — it writes
`hermes-render-env` itself rather than needing a second file copied over.

Knobs, all optional: `FORCE=1` reinstalls over an existing install, `HERMES_COMMIT=<sha>`
pins the upstream checkout, `MODEL_DEFAULT=` picks a different model. `SECRET_ID=` and
`REGION=` point at a different secret — at boot, user_data passes the terraform-templated
values, and they become the baked-in defaults of the rendered `hermes-render-env`.

Two consequences of putting this on the boot path, both deliberate:

- **It is the last thing `user_data.sh` does.** This is the slow, network-dependent,
  most-likely-to-fail step — roughly ten minutes, most of it a `curl | bash` of an upstream
  installer. Everything that makes the box reachable and locked down happens before it, so
  a failure here still leaves a box on the tailnet with sshd masked that you can SSH in and
  debug. Expect `cloud-init status --wait` to take ~12 minutes on a fresh instance.
- **The upstream installer is unpinned.** A rebuild six months from now gets whatever
  Hermes ships that day, and this is exactly how the first build broke (`apt install awscli`
  vanished in noble). If a rebuild ever needs to match a known-good box, set
  `HERMES_COMMIT` in `install_hermes.sh` to the `upstream` SHA that `hermes --version`
  reports — currently `5106e939` for v0.21.0.

What it does, and why each piece is the way it is:

1. **`build-essential ripgrep ffmpeg libatomic1` as root.** The only root-needing part of
   the install, done up front so the `hermes` user never needs sudo at all. Only
   `build-essential` is load-bearing — `node-pty` compiles from source. Without the other
   two the installer just warns and degrades (grep instead of ripgrep, limited TTS).
2. **The upstream installer, as `hermes`.** Everything else is user-local: `uv`, Python
   3.11, Node 26, the checkout and all data land under `~/.hermes`. Note the script `cd`s
   into the user's home before dropping privileges — `uv` resolves config by walking up
   from the *current* directory, so running this from `/root` fails on `/root/.venv` even
   with `HOME` set correctly. Browser and computer-use are skipped; they pull Playwright's
   Chromium, the largest and flakiest part of the install, and nothing before Phase 4 wants
   them. `hermes doctor --fix` adds them later.
3. **`.env` rendered from Secrets Manager** by `/usr/local/bin/hermes-render-env`, which
   runs *as* `hermes` (it needs that user's `$HOME` and the instance role). This overwrites
   the 27KB commented template the installer drops at `~/.hermes/.env`; that template
   survives as `~/.hermes/hermes-agent/.env.example` if you want the full variable list.
   It lives at `/usr/local/bin` because the Phase 4 gateway unit calls it from
   `ExecStartPre` — that is what makes rotation "update the secret, restart the unit".

   Two things it does beyond dumping the JSON:

   - **Drops `TAILSCALE_AUTH_KEY`.** Only user-data reads it, at boot. `.env` is read by
     the agent process, and the agent has shell access — no reason to hand it a tailnet
     auth key.
   - **Renames `MOONSHOT_API_KEY` to `KIMI_API_KEY`.** Hermes has a *native*
     Kimi/Moonshot provider (`kimi-coding`) whose default base URL is already
     `https://api.moonshot.ai/v1`, which is right for a legacy `sk-…` platform key — so
     the plan's "configure it as an OpenAI-compatible `base_url`" is unnecessary. It reads
     `KIMI_API_KEY`. Renaming the key in the secret itself would let this clause go; it
     lives here only because the instance role is read-only on the secret.
     (`KIMI_BASE_URL` is *only* for `sk-kimi-…` Kimi Code keys, which resolve to
     `api.kimi.com/coding` instead.)
4. **`model.default`.** The shipped default is `anthropic/claude-opus-4.6`, which has no
   key. The Moonshot key serves `kimi-k2.6`, `kimi-k2.7-code`, `kimi-k2.7-code-highspeed`
   and `kimi-k3`. Adding `ANTHROPIC_API_KEY` to the secret later needs no script change —
   it renders on the next run, and `model.provider` is `auto`.

To check `hermes-render-env` itself — it must be re-runnable, and a failed fetch must
leave a working `.env` alone rather than truncating it:

```sh
md5sum ~/.hermes/.env                                                    # twice, same hash
SECRET_ID=nope-does-not-exist /usr/local/bin/hermes-render-env; echo $?  # nonzero
md5sum ~/.hermes/.env                                                    # unchanged, no .env.* left
```

`hermes doctor` should report `✓ Kimi / Moonshot` under API Connectivity. Its other
warnings at this stage are expected: the disabled browser/computer-use tools, the
unconfigured chat platforms, and two npm advisories in build-time tooling. `hermes config
check` listing hundreds of `○` variables is not an error either — those are the optional
integrations we do not use.

### Rebuilding this box

`terraform apply` on an empty account reaches a working agent with no manual steps —
both phases run at first boot. What it does *not* reach is any of the state that makes
it *yours*:

| Under `~/.hermes` | | |
|---|---|---|
| `hermes-agent/`, `node/`, `bin/` | ~1.25GB | rebuilt by the installer |
| `skills/` | 3.9MB | 60 bundled skills, re-synced by the installer |
| `config.yaml` | 141 real lines | all shipped defaults bar `model.default` |
| `state.db`, `memories/`, `sessions/`, `cron/`, `SOUL.md` | ~300KB | **irreplaceable** |

So the whole irreplaceable surface is a few hundred KB, and nothing yet backs it up —
that is Phase 5. Until it lands, replacing this instance loses the agent's memory even
though the install reproduces perfectly. The root volume's
`delete_on_termination = false` is the only thing standing in for a backup right now,
and it protects against `terraform destroy`, not against a rebuild.

## Notes

- **The running box has never executed the committed `user_data.sh`.** It booted from an
  earlier version that ran `apt-get install awscli`, which noble no longer ships; that
  failed before Tailscale, so `cloud-init status` still reports `error` and the Phase 1
  steps were applied by hand. Phase 2 was likewise applied by hand, then folded into
  `install_hermes.sh`. Both halves are correct and a rebuild runs them clean — but the
  boot path itself is unproven until an instance is actually replaced. The pieces have
  been exercised individually (`install_hermes.sh` re-run against the live box, the
  rendered template syntax-checked), which is not the same as a green first boot.
- Boot creates a non-root `hermes` service user with linger enabled; Hermes installs
  under that user (see Phase 2 above). `unattended-upgrades` needs no setup — the
  Ubuntu cloud image ships it enabled.
- **`terminal.backend` is still `local`.** Phase 2 stops at a verified single query;
  nothing is listening and no gateway is installed, so the agent only runs when someone
  starts it by hand. Phase 3 switches the backend to `docker` — do that before Phase 4
  connects it to Slack, not after.
- The root volume has `delete_on_termination = false`. `terraform destroy` leaves the
  volume behind on purpose — it holds `~/.hermes`. Delete it manually when you mean to.
- Egress includes TCP 80 and UDP 53 beyond the plan's 443/41641: Ubuntu's arm64 apt
  mirrors are plain HTTP and DNS must reach the VPC resolver. Drop them and the box
  cannot patch itself or resolve anything.
- The AMI comes from Canonical's SSM public parameter, but the instance ignores AMI
  changes so a new Canonical image never silently replaces the running agent. To move
  to a newer image: `terraform taint aws_instance.hermes` then apply, on purpose.

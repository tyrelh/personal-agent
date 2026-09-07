# hermes infrastructure

Phase 0 of the Hermes agent plan: state backend, EC2 host, IAM.

Two steps, and the split is the whole design. `terraform apply` builds the box and
`user_data.sh` gets it onto the tailnet with sshd masked — Phase 1, and nothing more.
Then `./deploy.sh` copies the install scripts over Tailscale SSH and runs them: Phase 2
(Hermes), Phase 3 (the Docker sandbox), Phase 4 (the Slack gateway) and the Obsidian
vault. Both scripts are idempotent, so re-running `deploy.sh` is the normal way to change
anything above the base OS.

The install scripts used to be injected into user-data. They are not any more: user-data
is capped at 16KB, runs exactly once per instance-id, and cannot be edited on a running
box — so an inlined install script is a size ceiling *and* a lie, since editing it does
nothing until a rebuild while still showing up as a `user_data` diff terraform wants to
push with a pointless stop/start. Over ssh, the file on disk and the file in git are the
same thing.

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
  "SLACK_HOME_CHANNEL": "",
  "FIRECRAWL_API_KEY": "",
  "TAILSCALE_AUTH_KEY": "",
  "OBSIDIAN_EMAIL": "",
  "OBSIDIAN_PASSWORD": "",
  "OBSIDIAN_VAULT": "",
  "OBSIDIAN_VAULT_PASSWORD": ""
}
```

Use an ephemeral, pre-authorized, single-use Tailscale auth key.

Keys are copied into `~/.hermes/.env` verbatim by `hermes-render-env`, so their names here
are the names Hermes reads — with one deliberate rename it handles for you,
`MOONSHOT_API_KEY`, and two sets of keys it deletes on the way through,
`TAILSCALE_AUTH_KEY` and `OBSIDIAN_*`. See Phase 2 below. Empty values are
skipped rather than rendered as blanks, so the placeholders above are harmless until
filled; `ANTHROPIC_API_KEY` and `FIRECRAWL_API_KEY` are the ones still empty today.

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

## Deploy

Once the box is up and on the tailnet, from this directory:

```sh
./deploy.sh              # install_hermes.sh, then install_obsidian.sh
./deploy.sh hermes       # just one of them
./deploy.sh obsidian
```

It pipes each script to `/usr/local/sbin/` over ssh and runs it there. Expect ~12 minutes
the first time, most of it Phase 2's upstream installer. Re-running is the normal case,
not a repair: an existing Hermes install is skipped, and every env/config/unit step
converges rather than appending.

Knobs are forwarded to the remote script when set — `FORCE=1`, `HERMES_COMMIT=`,
`MODEL_DEFAULT=`, `SYNC_MODE=`, `VAULT_DIR=`, `SECRET_ID=`, `REGION=` and the rest listed
in `deploy.sh`. `HOST=` (default `root@hermes`) points at a different box.

```sh
FORCE=1 ./deploy.sh hermes                # reinstall Hermes over the top
SYNC_MODE=pull-only ./deploy.sh obsidian  # make the vault read-only to the agent
```

Three details worth knowing:

- **It uses `cat >` over ssh, not `scp`.** Tailscale SSH does implement sftp, but it has
  broken before ([tailscale#12849](https://github.com/tailscale/tailscale/issues/12849)),
  and a pipe needs no sftp subsystem, no `scp` binary and no second connection. Each
  script is written to `<dest>.new` and moved into place, so a dropped connection cannot
  leave a half-written file at a path about to be executed.
- **`ssh` does not forward the environment**, so the knobs above go on the remote command
  line, `printf %q`-quoted.
- **The scripts still work piped by hand** if you would rather not use `deploy.sh`:
  `ssh root@hermes 'bash -s' < install_hermes.sh`. They are self-contained for exactly
  this reason — `install_hermes.sh` writes `hermes-render-env` itself rather than needing
  a second file copied over.

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

None of this applies to the install scripts any more — that is the point of deploying
them over ssh. `./deploy.sh` is the whole story for anything above the base OS. What is
left in `user_data.sh` is only the part that genuinely has to happen before you can reach
the box: apt, ufw, Tailscale, the `hermes` user, and masking sshd. Changing *that* still
needs one of the three routes above, and route 2 is still unsafe for the reasons given.

Note that `user_data_replace_on_change` is unset (defaults false), so a `user_data` diff is
pushed in place — Terraform stops and starts the instance and cloud-init still ignores the
new script. Downtime, no effect. Use one of the three above instead.

## Phase 2 — installing Hermes

`install_hermes.sh` is the whole of it. `./deploy.sh hermes` copies it to
`/usr/local/sbin/hermes-install` and runs it; it lives on disk so it stays re-runnable
there directly:

```sh
ssh root@hermes /usr/local/sbin/hermes-install           # converges; skips the install
ssh root@hermes 'FORCE=1 /usr/local/sbin/hermes-install' # reinstall over the top
```

It never goes through terraform's `templatefile()`: the script is full of shell expansions
like `${HERMES_USER:-hermes}` that terraform would try to resolve as terraform variables
and fail the plan on. It reads what it needs from the environment instead, which is what
`deploy.sh` forwards.

Re-running is safe: an existing install is skipped, and the env and config steps converge
rather than append. It ends by asking the model a real question, which is the only check
that proves the key, the base URL and the model slug all line up.

Knobs, all optional: `FORCE=1` reinstalls over an existing install, `HERMES_COMMIT=<sha>`
pins the upstream checkout, `MODEL_DEFAULT=` picks a different model. `SECRET_ID=` and
`REGION=` point at a different secret; whichever values a run uses become the baked-in
defaults of the `hermes-render-env` it writes.

Two things about it, both deliberate:

- **It is off the boot path entirely.** This is the slow, network-dependent,
  most-likely-to-fail step — roughly ten minutes, most of it a `curl | bash` of an upstream
  installer. Running it over ssh after the box is reachable means a failure is something
  you watch happen on a box you are already logged into, rather than something you go
  digging for in `/var/log/cloud-init-output.log` after a silent twelve-minute wait.
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

## Phase 3 — sandbox the agent's shell

Section 2 of `install_hermes.sh` installs Docker; section 5 points Hermes at it. Same
file as Phase 2, so it deploys the same way: `./deploy.sh hermes`.

Five settings, and one of them is the whole phase:

| Key | Value | Why |
|---|---|---|
| `terminal.backend` | `docker` | The agent's shell runs in a container, not on the host. |
| `terminal.container_memory` | `2048` | Shipped default is 5120MB — more than this 4GB box has. |
| `approvals.mode` | `smart` | Already the default; pinned so an upstream change shows as a diff. |
| `approvals.cron_mode` | `deny` | Ditto. Decides what a headless cron job does with a dangerous command. |
| `model.default` | `kimi/kimi-k3` | Phase 2. |

The rest of the plan's Phase 3 list needs no code: `.env` is already `chmod 600`
(`hermes-render-env` writes it under `umask 077`), the dashboard's default bind is
`127.0.0.1` and nothing has been told otherwise, `GATEWAY_ALLOW_ALL_USERS` is simply
not in the secret, and the gateway does not exist until Phase 4 — when it must be
installed as the `hermes` user, never root.

### What the container backend actually buys

Hermes runs every container `--cap-drop ALL --security-opt no-new-privileges
--pids-limit 256`, mounting only `~/.hermes/sandboxes/docker/<task>/` as `/root` and
`/workspace` plus a handful of `~/.hermes` cache and skill directories. No Docker
socket, no `.env`, no `state.db`, no host filesystem.

That is also why the approval settings above are close to decoration here: under a
container backend Hermes **skips the dangerous-command approval stack entirely**,
deliberately — the container is the boundary, so there is no prompt to answer and
nothing it runs reaches the host. They matter again if the backend is ever moved
back to `local`.

The `hermes` user is in the `docker` group, which is root-equivalent *on the host*.
The agent never reaches it: its shell is inside the container, and no socket is
mounted there. Rootless Docker would close the gap for a container escape too, at the
cost of a userns AppArmor profile on noble — worth it if this ever has to hold against
a hostile agent rather than a wrong one.

### Two things that break silently without the daemon config

1. **DNS.** Containers inherit the host `resolv.conf` unless it points at a loopback
   resolver — which noble's `systemd-resolved` does. Docker then substitutes its own
   public defaults (8.8.8.8), which the security group has no egress rule for, so every
   lookup in every container hangs until it times out. `/etc/docker/daemon.json` pins
   the daemon to the VPC resolver the host is actually using.
2. **Log growth.** The default `json-file` driver never rotates, on a 30GB root volume.
   Capped at 10MB × 3 per container.

Verification, all of it run by the install script itself except the last:

```sh
docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' \
  $(docker ps -q | head -1)     # 2147483648 [ALL] [no-new-privileges]

hermes -z 'Use the terminal tool to run: cat /etc/hostname && id -un. Raw output only.'
# a container ID and `root` — NOT ip-172-31-x-x and `hermes`
```

The sandbox image (`nikolaik/python-nodejs:python3.11-nodejs20`, ~1GB) is pulled at
install time so the first agent command does not stall on it, and a `getent hosts`
inside a throwaway container is the install's own check on the DNS fix. Disk after the
pull: 7.4GB of 29GB.

## Phase 4 — Slack gateway

Socket Mode: the app dials **out** to Slack over a WebSocket, so the security group
keeps its zero ingress rules and there is no public URL, no ALB, and no request
signature to verify.

Three of the five steps are in this repo; the two that are not are a browser and a
secret, and neither can be.

**1. Create the Slack app (by hand, once).** [api.slack.com/apps](https://api.slack.com/apps)
→ *Create New App* → *From an app manifest* → paste `slack_app_manifest.yaml`. Use a
**personal workspace, not Giftbit** — this bot has shell access, which is a different
risk conversation in a work workspace.

Then, still in the browser:

- *Basic Information* → *App-Level Tokens* → generate one with `connections:write`
  → that is `SLACK_APP_TOKEN` (`xapp-…`). The manifest cannot create this.
- *Install App* → install to the workspace → `SLACK_BOT_TOKEN` (`xoxb-…`).
- Your own member ID: Slack profile → *Copy member ID* (`U…`) → `SLACK_ALLOWED_USERS`.

**2. Put the three values in the secret.** Read-modify-write, because
`put-secret-value` replaces the whole blob:

```sh
aws secretsmanager get-secret-value --region ca-west-1 --secret-id hermes \
  --query SecretString --output text \
  | jq '.SLACK_BOT_TOKEN="xoxb-…" | .SLACK_APP_TOKEN="xapp-…" | .SLACK_ALLOWED_USERS="U…"' \
  > hermes.json
aws secretsmanager put-secret-value --region ca-west-1 --secret-id hermes \
  --secret-string file://hermes.json
rm hermes.json
```

**3. Re-run the installer.** Section 7 of `install_hermes.sh` is the whole gateway
install, and it is a no-op until `SLACK_BOT_TOKEN` is in the rendered `.env`:

```sh
./deploy.sh hermes
```

It renders `.env` afresh, installs a **system** unit running as `hermes`, and starts
it. Nothing about the earlier phases re-runs beyond converging, so this is the only
step needed once the tokens are in the secret.

Why a system unit and not the `--user` one the CLI defaults to: root can restart it
over Tailscale SSH, and it starts at boot without depending on the `hermes` user's
linger. It still runs as `hermes` — the plan's "never run the gateway as root" is
`User=hermes` in the unit, not the uid that installed it. `--system` *does* have to
be installed by root; the CLI refuses it otherwise and remaps `HERMES_HOME` to the
target user itself.

**4. Home channel.** Where cron results and cross-platform messages land. Hermes
prompts for `/hermes sethome` in chat, which needs a `/hermes` slash command
registered on the app — this manifest deliberately has none. Use `SLACK_HOME_CHANNEL`
in the secret instead: it is read at every start and overrides the stored value, so a
rebuilt box keeps its home channel instead of waiting for someone to remember the
click. Create the channel, invite the bot (`/invite @Hermes`), take its ID from
*View channel details* → bottom (`C…`), add it to the secret, then
`ssh root@hermes systemctl restart hermes-gateway`.

**The allowlist is a hard gate.** `SLACK_ALLOWED_USERS` unset means deny-all, so the
bot would install, connect, and then ignore every message — a failure that looks like
a Slack problem for an hour. Section 7 refuses to install without it.
`GATEWAY_ALLOW_ALL_USERS` is never the fix, and is deliberately absent from the secret.

### Rotation

The unit gets a drop-in at
`/etc/systemd/system/hermes-gateway.service.d/10-render-env.conf` adding a single
`ExecStartPre=/usr/local/bin/hermes-render-env`, so every start re-reads the secret.
Rotating any key — Slack, Kimi, anything — is:

```sh
aws secretsmanager put-secret-value --region ca-west-1 --secret-id hermes --secret-string file://hermes.json
ssh root@hermes systemctl restart hermes-gateway
```

A drop-in rather than an edit of the unit: Hermes compares the installed unit against
what it would generate and reports an edited one as drift.

### Verifying

```sh
ssh root@hermes 'systemctl status hermes-gateway --no-pager'
ssh root@hermes 'journalctl -u hermes-gateway -n 50 --no-pager'   # look for the Slack socket connecting
```

Then, from Slack:

| Do this | Expect |
|---|---|
| DM the bot from your allowlisted account | a reply |
| DM from any other account | nothing at all |
| Plain message in a channel it is in | ignored |
| `@Hermes` in that channel | threaded reply; the thread continues without re-mentioning |
| Ask it to run `cat /etc/hostname && id -un` | a container ID and `root` — **not** `ip-172-31-…` and `hermes` |
| `sudo reboot`, then a full EC2 stop/start | the gateway comes back on its own |

### Rebuilding this box

`terraform apply` then `./deploy.sh` on an empty account reaches a working agent — two
commands, both unattended. What they do *not* reach is any of the state that makes it
*yours*:

| Under `~/.hermes` | | |
|---|---|---|
| `hermes-agent/`, `node/`, `bin/` | ~1.25GB | rebuilt by the installer |
| `skills/` | 3.9MB | 60 bundled skills, re-synced by the installer |
| `config.yaml` | 141 real lines | shipped defaults bar the five keys Phase 2/3 set |
| `state.db`, `memories/`, `sessions/`, `cron/`, `SOUL.md` | ~300KB | **irreplaceable** |

So the whole irreplaceable surface is a few hundred KB, and nothing yet backs it up —
that is Phase 5. Until it lands, replacing this instance loses the agent's memory even
though the install reproduces perfectly. The root volume's
`delete_on_termination = false` is the only thing standing in for a backup right now,
and it protects against `terraform destroy`, not against a rebuild.

## Obsidian vault

`install_obsidian.sh`. Puts a real Obsidian vault on the box, kept in sync by
[obsidian-headless](https://github.com/obsidianmd/obsidian-headless) — the official CLI
client for Obsidian Sync, no desktop app — and bind-mounts it into the agent's sandbox.
Notes edited on a phone show up in the agent's filesystem, and (in the default mode) the
agent's edits show up on the phone.

`./deploy.sh` runs it after `install_hermes.sh`, and it is a no-op when the `OBSIDIAN_*`
keys are absent from the secret, exactly like the Phase 4 gateway. On its own:

```sh
./deploy.sh obsidian
ssh root@hermes /usr/local/sbin/hermes-obsidian-install   # or re-run it in place
```

Knobs, all optional: `SYNC_MODE=` (below), `VAULT_DIR=` (default `/srv/obsidian`),
`CONTAINER_PATH=` (default `/workspace/vault`), `OB_VERSION=` and `NODE_MAJOR=`,
`FORCE=1` to reinstall the client over the top.

### Setting it up

Four values in the secret, read-modify-write as in Phase 4:

```sh
aws secretsmanager get-secret-value --region ca-west-1 --secret-id hermes \
  --query SecretString --output text \
  | jq '.OBSIDIAN_EMAIL="…" | .OBSIDIAN_PASSWORD="…" | .OBSIDIAN_VAULT="My Vault"
        | .OBSIDIAN_VAULT_PASSWORD="…"' \
  > hermes.json
aws secretsmanager put-secret-value --region ca-west-1 --secret-id hermes \
  --secret-string file://hermes.json
rm hermes.json
```

`OBSIDIAN_VAULT` is the remote vault's name or ID as `ob sync-list-remote` reports it.
`OBSIDIAN_VAULT_PASSWORD` is the end-to-end encryption password and is only needed for an
E2EE vault — leave it empty otherwise. An active Sync subscription is required.

**2FA needs one interactive login, once.** `ob login` takes `--email`, `--password` and
`--mfa`, but a code is only valid for about thirty seconds so no unattended run can
supply one. The session is stored afterwards, and `install_obsidian.sh` probes for it
before trying to log in — so this is a one-time step, not a per-run problem, and there is
no reason to turn 2FA off:

```sh
ssh -t root@hermes ob login              # prompts for email, password and the code
./deploy.sh obsidian                     # every later run skips the login
```

Or hand a fresh code to a single run: `OBSIDIAN_MFA=123456 ./deploy.sh obsidian`.

The probe is `ob sync-list-remote`, not `ob login` — the latter exits 0 whether or not an
account is logged in, so it cannot answer the question.

**The `OBSIDIAN_*` keys never reach `~/.hermes/.env`** — `hermes-render-env`'s denylist
drops them alongside `TAILSCALE_AUTH_KEY`, and `install_obsidian.sh` reads them from
Secrets Manager directly instead. The reasoning is in the comment on that filter.

**The sync daemon runs as root, and so does the login.** Deliberate, and the one place
this repo departs from "services run as `hermes`":

- The stored Obsidian session lands in root's home, where the `hermes` user — and
  anything that escapes the sandbox — cannot read it. The agent reaches the vault
  through the bind mount and nothing else.
- The sandbox container runs as root, so files the agent creates in the vault are
  root-owned on the host. A daemon running as anyone else could upload them but never
  edit or delete them again — one uid on both sides of the mount avoids the whole
  problem, and avoids having to turn on `terminal.docker_run_as_host_user` and change
  what Phase 3 verified.

### Sync mode

| `SYNC_MODE` | Mount | Effect |
|---|---|---|
| `bidirectional` (default) | read-write | The agent's edits propagate to every device on the account. |
| `pull-only` | `:ro` | Vault is read-only to the agent; local changes ignored. |
| `mirror-remote` | `:ro` | Same, and any local change is reverted. |

Set on every run, not just at setup, so it converges rather than drifting. Under
`pull-only`/`mirror-remote` the bind mount is made `:ro` too — a mount the agent can
write to but whose writes are silently discarded is worse than one it is told is
read-only. Flipping the mode later rewrites the existing mount rather than adding a
second one:

```sh
SYNC_MODE=pull-only ./deploy.sh obsidian
```

### How the agent actually sees it

Phase 3 put the agent's shell in a container that mounts only its own sandbox directory,
so a vault sitting on the host filesystem is invisible to it. `terminal.docker_volumes`
is the bind mount, and the script merges its entry into whatever is already there rather
than replacing the list — if that key is ever something other than a JSON array of
strings it refuses and asks you to merge by hand, because resetting it would silently
delete somebody's hand-added mount.

The sandbox container is long-lived and keeps its old mount table until it is recreated,
so the script restarts the gateway (when there is one) to force that.

### Verifying

The script checks all of this itself except the last row — a one-shot `ob sync` before
installing the unit (which is what proves the login and the E2EE password), then
`sync-status`, then a throwaway container that touches a file in the mount to prove the
agent-side path and its writability.

```sh
ssh root@hermes 'systemctl status obsidian-sync --no-pager'
ssh root@hermes 'journalctl -u obsidian-sync -n 50 --no-pager'
ssh root@hermes 'ls /srv/obsidian'
ssh root@hermes 'ob sync-status --path /srv/obsidian'
```

| Do this | Expect |
|---|---|
| Ask the agent in Slack to `ls /workspace/vault` | your notes |
| Edit a note on a phone, wait | it changes on the box within seconds |
| Ask the agent to write a note there (`bidirectional`) | it appears on your other devices |

### Notes

- **The running box has never executed the committed `user_data.sh`.** It booted from an
  earlier version that ran `apt-get install awscli`, which noble no longer ships; that
  failed before Tailscale, so `cloud-init status` still reports `error` and the Phase 1
  steps were applied by hand. `user_data.sh` is correct and a rebuild runs it clean, but
  it is unproven until an instance is actually replaced — the rendered template has only
  been syntax-checked. The install scripts are the opposite: they have been run against
  the live box repeatedly, which is now the only way they ever run.
- Boot creates a non-root `hermes` service user with linger enabled, which is why that
  part stayed in `user_data.sh` — `install_hermes.sh` refuses to run without it. Hermes
  installs under that user (see Phase 2 above). `unattended-upgrades` needs no setup — the
  Ubuntu cloud image ships it enabled.
- **`terminal.backend` is `docker` (Phase 3).** Nothing is listening and no gateway is
  installed yet, so the agent still only runs when someone starts it by hand — but its
  shell is already in a container, which is the thing Phase 4 must not be done without.
- The root volume has `delete_on_termination = false`. `terraform destroy` leaves the
  volume behind on purpose — it holds `~/.hermes`. Delete it manually when you mean to.
- Egress includes TCP 80 and UDP 53 beyond the plan's 443/41641: Ubuntu's arm64 apt
  mirrors are plain HTTP and DNS must reach the VPC resolver. Drop them and the box
  cannot patch itself or resolve anything.
- The AMI comes from Canonical's SSM public parameter, but the instance ignores AMI
  changes so a new Canonical image never silently replaces the running agent. To move
  to a newer image: `terraform taint aws_instance.hermes` then apply, on purpose.

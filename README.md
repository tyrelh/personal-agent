# Hermes Agent

Phase 0 of the Hermes agent plan: state backend, EC2 host, IAM.

Two steps, and the split is the whole design. `terraform apply` builds the box and
`user_data.sh` gets it onto the tailnet with sshd masked — Phase 1, and nothing more.
Then `./deploy.sh` copies the install scripts over Tailscale SSH and runs them: Phase 2
(Hermes), Phase 3 (the agent's shell), Phase 4 (the Slack gateway) and the Obsidian
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
  "OBSIDIAN_VAULT_PASSWORD": "",
  "OBSIDIAN_VAULT_PATH": "",
  "HERMES_DASHBOARD_BASIC_AUTH_USERNAME": "",
  "HERMES_DASHBOARD_BASIC_AUTH_PASSWORD": "",
  "HERMES_DASHBOARD_BASIC_AUTH_SECRET": "",
  "GOOGLE_CLIENT_SECRET_JSON": ""
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
   The same section creates a 2G `/swapfile` (guarded, and `fstab`-persisted), because the
   browser below shares 3.8GB with the gateway and the dashboard's build step — see
   **Browser** for why swap is the difference between a spike and an OOM-killed gateway.
2. **The upstream installer, as `hermes`.** Everything else is user-local: `uv`, Python
   3.11, Node 26, the checkout and all data land under `~/.hermes`. Note the script `cd`s
   into the user's home before dropping privileges — `uv` resolves config by walking up
   from the *current* directory, so running this from `/root` fails on `/root/.venv` even
   with `HOME` set correctly. The upstream installer's own browser and computer-use steps are
   skipped — they are the slowest and flakiest part of a fresh install — and the browser is
   provisioned explicitly by the next section instead. See **Browser**: `hermes doctor
   --fix` does *not* install an engine this host can run.
3. **`.env` rendered from Secrets Manager** by `/usr/local/bin/hermes-render-env`, which
   runs *as* `hermes` (it needs that user's `$HOME` and the instance role). This overwrites
   the 27KB commented template the installer drops at `~/.hermes/.env`; that template
   survives as `~/.hermes/hermes-agent/.env.example` if you want the full variable list.
   It lives at `/usr/local/bin` because the Phase 4 gateway unit calls it from
   `ExecStartPre` — that is what makes rotation "update the secret, restart the unit".

   Two things it does beyond dumping the JSON:

   - **Drops four keys by name:** `TAILSCALE_AUTH_KEY`, `OBSIDIAN_EMAIL`,
     `OBSIDIAN_PASSWORD`, `OBSIDIAN_VAULT_PASSWORD`. `.env` is owned by `hermes` and the
     agent's shell runs as that user, so anything rendered here is agent-readable. The
     auth key is boot-only (user-data reads it) and joins the tailnet; the three Obsidian
     keys are the *account* rather than the notes — see the Obsidian section. By name and
     not by `OBSIDIAN_*` prefix, because `OBSIDIAN_VAULT` and `OBSIDIAN_VAULT_PATH` are a
     name and a path the agent has use for. The trade: a future `OBSIDIAN_*` credential
     is not caught for free, so add it to that list.
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
   and `kimi-k3`. `kimi-k2.6` is the default because it is the cheap one and most of what
   this box does is routine; `kimi-k3` is a deliberate per-task or per-cron swap, not the
   floor. Adding `ANTHROPIC_API_KEY` to the secret later needs no script change —
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

## Phase 3 — the agent's shell runs on the host

Section 2 of `install_hermes.sh` is the *absence* of a sandbox; section 4 points Hermes
at the host. Same file as Phase 2, so it deploys the same way: `./deploy.sh hermes`.

Six settings, and the first one is the whole phase:

| Key | Value | Why |
|---|---|---|
| `terminal.backend` | `local` | The agent's shell runs on this host, as `hermes`, with the whole filesystem in reach. |
| `approvals.mode` | `off` | No approval prompt at all. There is nobody at a terminal to answer one. |
| `approvals.cron_mode` | `approve` | A cron job has no approval channel, so `deny` does not mean "ask someone" — it means "block the command". |
| `approvals.single_query_mode` | `approve` | Same for a `hermes -q`/`-z` session. |
| `approvals.unattended_mode` | `approve` | Same for unattended platforms; the Slack gateway is one. |
| `model.default` | `kimi/kimi-k2.6` | Phase 2. |

The four `approvals` keys were decoration under the old container backend — Hermes skips
the dangerous-command approval stack entirely when the shell is in a container, because
the container is the boundary. On the host they are live, and every one of them fails
closed by default, which on a box with nobody watching means a command that blocks until
it times out.

The rest of the plan's Phase 3 list needs no code: `.env` is already `chmod 600`
(`hermes-render-env` writes it under `umask 077`), the dashboard's default bind is
`127.0.0.1` and nothing has been told otherwise, `GATEWAY_ALLOW_ALL_USERS` is simply
not in the secret, and the gateway does not exist until Phase 4 — when it must be
installed as the `hermes` user, never root.

### Why there is no container

The VM is the boundary. This box runs one thing, its security group has zero ingress,
sshd is masked in favour of Tailscale SSH, and everything on the filesystem is either
the agent's own or was deliberately put there for it. A container inside that adds a
second boundary whose main practical effect is that *ordinary* things — the Obsidian
vault, a checkout, a file the user asks about — are invisible until somebody adds a bind
mount for them. That is the cost that decided it: handing the agent one directory of
notes previously took a `terminal.docker_volumes` entry, a gateway restart, and a
container teardown, and it still silently did nothing until all three were right.

What is given up is real and worth naming. With `terminal.backend local` a wrong command
reaches the host: `~/.hermes/.env` (every API key), `state.db`, the systemd units, the
whole filesystem. `.env` is `chmod 600` and owned by `hermes`, so the agent can read its
own keys — that is not a leak so much as an acknowledgement that this design has no
answer to it. The Obsidian session is root's and stays out of reach (Phase 5). None of
this holds against a hostile agent, only a careless one, and only weakly; rebuild is the
recovery plan, which is why the root volume outlives `terraform destroy`.

`approvals.deny` is the one guard rail left standing, and it is empty on purpose. It is a
glob denylist checked *even under* `mode: off`, which makes it the right place for a
specific command that must never run here — not a general safety net:

```sh
hermes config set approvals.deny '["shutdown*", "git push --force*"]'
```

### Converging a box that had the container backend

`install_hermes.sh` tears the old setup down, because leaving it in place is not inert:

- **`hermes` is removed from the `docker` group.** That group is root-equivalent on the
  host. It was harmless when the agent's shell was inside a container with no socket
  mounted; with the shell on the host, the agent would reach it.
- **`docker.socket` and `docker.service` are disabled and stopped.**
- **`terminal.container_*` and `terminal.docker_volumes` are unset.** Inert under the
  local backend, but a leftover `docker_volumes` entry reads as configuration that is
  still doing something.

The package is left installed. Purge it when you want the ~2GB back:

```sh
ssh root@hermes 'apt-get purge -y docker.io && rm -rf /var/lib/docker'
```

### Verifying

The install script runs this itself. It is the check that the backend actually took, and
it is worth having because a wrong answer surfaces later as an empty vault rather than
as an error:

```sh
hermes -z 'Use the terminal tool to run exactly: id -un. Reply with the raw output only.'
# hermes    — under the old container backend this answered `root`
```

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
| Ask it to run `cat /etc/hostname && id -un` | `ip-172-31-…` and `hermes` — the shell is the host itself (Phase 3) |
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

## Browser

The `browser_*` tools — a real headless Chromium, not `curl`: JS-rendered pages,
screenshots, clicks, and a session that can stay logged in. Section 3b of
`install_hermes.sh`, so `./deploy.sh hermes` is the whole of it.

Nothing here adds a browser *stack*. Hermes ships the `browser` toolset enabled and a
provider menu with six backends (Local Chromium, Lightpanda, Camofox, Browserbase, Browser
Use cloud, Firecrawl). Playwright MCP or Browser Use beside that would be pure duplication.
The only thing missing was an engine, so all this does is put one on disk and tell Hermes
where it is.

**Why it is not `hermes tools post-setup agent_browser`.** That hook delegates to
`agent-browser install`, which downloads Chrome for Testing and explicitly rejects Linux
ARM64 ([v0.26.0 `cli/src/install.rs`](https://github.com/vercel-labs/agent-browser/blob/v0.26.0/cli/src/install.rs#L370)).
This box is arm64, and Google Chrome proper has no Linux arm64 build at all. Playwright
*does* publish an arm64 Chromium for noble, so its downloader is used directly. For the
same reason `browser.engine` stays `auto` — Hermes resolves that to Chromium — and must
never be pointed at a Chrome channel.

Four steps, all idempotent, in this order because each needs the one before it:

1. **`playwright@1.63.0` into `/opt/playwright`**, as root, using Hermes' own Node
   (`~/.hermes/node/bin` — there is no system node and root's `PATH` has neither). Pinned,
   not `@latest`: the same version provisions the apt dependencies, downloads the browser
   and resolves its path, so the three cannot disagree. In `/opt` so `hermes update` cannot
   replace it.
2. **`playwright install-deps chromium`**, as root, because it is `apt`. This is the one
   thing that needs privilege, and doing it here is what keeps the `hermes` user out of
   sudo entirely — `playwright install --with-deps` as that user would try to escalate and
   fail. The dependency set is not inferred from `build-essential`/`ffmpeg`.
3. **`playwright install chromium --no-shell`**, as `hermes`, into that user's own
   `~/.cache/ms-playwright/` (*not* `~/.hermes/node/`, which is the Node runtime). A re-run
   reuses the cached revision. `--no-shell` on purpose: `chromium-headless-shell` cannot
   screenshot a real page, which is most of the point.
4. **A stable symlink at `~/.local/bin/chromium`**, pointed at whatever
   `chromium.executablePath()` reports for that pinned version — asked, not guessed at from
   a revision directory, so bumping the pin moves the symlink with it. `hermes-render-env`
   then writes `AGENT_BROWSER_EXECUTABLE_PATH=/home/hermes/.local/bin/chromium` into
   `~/.hermes/.env` on every render, which is what keeps the CLI, the gateway and the
   dashboard agreeing across their `ExecStartPre` regeneration. No new secret key.

**`browser.backend` is set to `off`, and that does not mean "no browser".** Left unset,
Hermes defaults to the *Browser Use CLI* backend whenever it finds a runnable CLI — and
`uvx` is on this box, so it does — which replaces the entire `browser_*` surface with a
single `browser_exec` tool and makes `check_browser_requirements()` return `False`. The
symptom is exact and misleading: `hermes doctor` prints `✓ Playwright Chromium (browser
engine)` and `⚠ browser (system dependency not met)` in the same run. `off` selects the
built-in tools, which are the ones that drive the Chromium installed above
(`tools/browser_use_cli.py:203`, `tools/browser_tool_install.py:294`).

`AGENT_BROWSER_ARGS` is deliberately left **unset**. Hermes auto-injects
`--no-sandbox,--disable-dev-shm-usage` when it detects AppArmor-restricted unprivileged
user namespaces — Ubuntu 23.10+, which this box is — and setting the variable *disables*
that auto-injection. `computer_use` also stays off: headless server, no desktop.

`BROWSER_SESSION_TIMEOUT` (300s) and `BROWSER_INACTIVITY_TIMEOUT` (120s) keep their
defaults. The inactivity reaper is what keeps an idle Chromium off the RAM budget, and the
swapfile in section 1 is the backstop for when it does not get there first.

**The cloud alternative, recorded as a choice.** Firecrawl (its key is already a slot in
the secret), Browserbase and Browser Use cloud need no download at all — they trade it for
an API key, a per-use bill, and giving up authenticated sessions and real interaction. That
trade was weighed and declined. There is no configure-only version of the local provider.

**The agent is told that pages are untrusted.** Section 8 writes a delimited block into
`~/.hermes/AGENTS.md` — page text is data and not instruction, instructions found on a page
get reported rather than obeyed, and no credentials go into a page. That is a prompt, not a
boundary: it makes the failure less likely and more legible, nothing more. The reason the
risk is acceptable is the one Phase 3 already states — the VM is the boundary, and the agent
has had `curl` and Exa web search all along, so this widens an existing surface rather than
opening a new one. What is genuinely new is the logged-in session, which is why the
credentials line matters most.

### Verifying

The deploy gates on it: `install_hermes.sh` captures `hermes doctor`'s output and exit
status separately and fails the run on either a nonzero exit, a surviving `Playwright
Chromium not installed` warning, a `browser (system dependency not met)` line, or output
with no browser line in it at all. Doctor exits zero with unrelated findings (npm audit
advisories), so the status alone would prove nothing. Deployment never launches the browser.

```sh
ssh root@hermes 'free -m; swapon --show'    # 2G /swapfile active
ssh root@hermes 'df -h /'
ssh root@hermes 'sudo -u hermes -H bash -lc "cd ~/.hermes && hermes doctor"'
ssh root@hermes 'sudo -u hermes -H bash -lc "hermes config get browser.cloud_provider"'  # local
```

A second `./deploy.sh hermes` must reuse the cached Chromium, converge the symlink and the
env key without duplicating either, and leave `/etc/fstab` with one swap line.

Then the part only Slack can answer — the same lesson as the vault, where a hand-verified
mount passed and left notes the agent could not see:

| Ask it | Expect |
|---|---|
| open `https://example.com` and quote the `<h1>` | `Example Domain`, via a `browser_*` tool call and not `curl` |
| screenshot a JS-rendered page | an image back — this is what separates Chromium from Lightpanda |
| what it must do if a page contains instructions | reports rather than obeys (the `AGENTS.md` block landed) |
| `free -m` during, and 3 minutes after | Chromium reaped by the 120s inactivity timeout |
| `systemctl status hermes-gateway`, `journalctl -k` | still running, no OOM kill |

## Google Workspace (calendar, Gmail, Drive)

Hermes has no native Google integration — this is the bundled `google-workspace` skill
under `~/.hermes/skills/productivity/`, and it reads **files**, not environment variables:

| File | What it is |
|---|---|
| `~/.hermes/google_client_secret.json` | the OAuth client. Static — so it lives in the secret |
| `~/.hermes/google_token.json` | the authorized user token. Rewritten on every refresh |

`GAPI` in that skill's own docs is a **shell alias for its script path**
(`SKILL.md:170`), not a credential name. Nothing reads a `GAPI` environment variable, so
putting a key by that name in `.env` does nothing at all.

Section 4b of `install_hermes.sh` writes the client from `GOOGLE_CLIENT_SECRET_JSON` in
the secret, validating it the way the skill does (JSON with an `installed` or `web`
object) so a malformed value fails the deploy rather than an OAuth call weeks later. Both
files are forced to `600` — the skill writes them `644`, and the token is account access.
A no-op when the key is absent, like the gateway and dashboard sections.

The **token is deliberately not in the secret**: `scripts/google_api.py` rewrites it on
every refresh, so a stored copy goes stale and a render would clobber a fresher one with
an older refresh token. Authorizing is a one-time interactive step after a rebuild, the
same shape as `ob login`:

```sh
gws=~/.hermes/skills/productivity/google-workspace/scripts/setup.py
ssh root@hermes "sudo -u hermes -H python3 $gws --auth-url"       # visit it, authorize
ssh root@hermes "sudo -u hermes -H python3 $gws --auth-code CODE"
ssh root@hermes "sudo -u hermes -H python3 $gws --check"          # exit 0 = authorized
```

`GOOGLE_CLIENT_SECRET_JSON` holds the client secret file's own JSON, nested as an object:

```json
"GOOGLE_CLIENT_SECRET_JSON": {
  "installed": {
    "client_id": "….apps.googleusercontent.com",
    "project_id": "…",
    "auth_uri": "https://accounts.google.com/o/oauth2/auth",
    "token_uri": "https://oauth2.googleapis.com/token",
    "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
    "client_secret": "GOCSPX-…",
    "redirect_uris": ["http://localhost"]
  }
}
```

This is the only key in the secret that is not a flat string, and that is fine: `jq -r`
on a non-string prints it back as JSON, so section 4b writes the file unchanged. A
string-encoded copy of the same JSON (`tojson`) parses identically — the object form is
just readable in the console. Keep the `client_id` matching whatever issued the existing
`google_token.json`; a token is tied to its client, so swapping the client invalidates it
and needs a re-auth.

To write it from a file downloaded out of the Google console, read-modify-write as
elsewhere:

```sh
aws secretsmanager get-secret-value --region ca-west-1 --secret-id hermes \
  --query SecretString --output text \
  | jq --slurpfile c client_secret.json '.GOOGLE_CLIENT_SECRET_JSON=$c[0]' > hermes.json
aws secretsmanager put-secret-value --region ca-west-1 --secret-id hermes \
  --secret-string file://hermes.json
rm hermes.json client_secret.json
```

## Dashboard

Hermes' web UI — config, keys, sessions, chat — on the tailnet and nowhere else. Section
7 of `install_hermes.sh`, so it deploys like everything above it: `./deploy.sh hermes`.
A no-op until the dashboard credentials are in the secret, like the Phase 4 gateway, and
a teardown if they ever leave it.

Three parts:

```
hermes binds 127.0.0.1:9119  ←  tailscale serve proxies the tailnet name at it
                                dashboard.public_url declares that name
```

The security group is untouched — it still has no ingress rule of any kind, because
nothing arrives that way. `tailscale serve` config lives in tailscaled's own state, so it
survives a reboot without a unit of its own.

The third part is not bookkeeping. It is what makes the first two work, and it is why
there is a password:

- The Host-header middleware answers `400 Invalid Host header` to any request whose Host
  is not the interface hermes bound to. A proxied `hermes.tail16ed35.ts.net` is exactly
  that, so without `dashboard.public_url` the tunnel connects and every request bounces
  (verified on the box: 400 through the tailnet, 200 on loopback).
- A non-loopback `public_url` engages the auth gate **even on a loopback bind**, and the
  gate refuses to bind at all when no auth provider is registered — it exits with
  "Refusing to bind dashboard to 127.0.0.1 … no auth providers are registered".

So the one key that permits the exposure also demands the login, and `--insecure` cannot
buy its way out: it has been a no-op since the June 2026 hardening. There is no
unauthenticated public dashboard to configure.

**The unit runs `hermes dashboard --no-open`, not `hermes serve`.** Same server, but
`serve` sets `HERMES_SERVE_HEADLESS` and leaves the SPA unmounted — a backend for the
desktop app, with no web UI at any path (`/login` still renders, which makes this an easy
half hour to lose). `dashboard` also rebuilds the frontend when the source content hash
moves, which is what keeps a `hermes update` from silently serving a stale bundle.

That build is `npm install` + `tsc -b && vite build`, about two minutes on this box, and
it happens on the *first start of the unit* — so `install_hermes.sh` waits on the port
rather than on `systemctl`, which calls a `Type=simple` unit started the moment it forks.
Later starts skip the build against a stamp in `~/.hermes/web-ui-build-stamp.json`.

### `hermes update` and the unit

`hermes update` checks out new code and then restarts the runtimes it manages, so that
nothing keeps serving the pre-update build. It runs as the `hermes` user, and the
dashboard is a *system* unit — so its restart step used to end here:

```
✗ failed to restart hermes-dashboard.service
  systemctl restart …: Interactive authentication required.
  sudo -n systemctl restart …: sudo: a password is required
```

which leaves the new backend paired with the old frontend bundle until someone SSHes in
as root. `install_hermes.sh` therefore ships one sudoers line beside the unit:

```
hermes ALL=(root) NOPASSWD: /usr/bin/systemctl restart hermes-dashboard.service, …
```

Restarting a root-owned unit in `/etc/systemd/system` is not a way onto the rest of the
box, and it is the whole grant — no other command, no other unit. It is written through
a temp file that `visudo -c` has to accept first, because a malformed file in
`sudoers.d` breaks *every* sudo on the box, and the teardown branch removes it along
with the unit.

If you hit that error on a box deployed before this, restart it by hand once and
re-deploy to install the rule:

```sh
ssh root@hermes systemctl restart hermes-dashboard
./deploy.sh hermes
```

### Credentials

Three keys, read-modify-write as in Phase 4. `hermes-render-env` copies them into
`~/.hermes/.env` like every other key, and the bundled `basic` dashboard-auth plugin
reads them from there:

| Key | |
|---|---|
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | Required. Its absence is what makes the whole section a no-op. |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | Required, plaintext. The plugin hashes it (stdlib scrypt) at startup. |
| `HERMES_DASHBOARD_BASIC_AUTH_SECRET` | Session-token signing key, `openssl rand -base64 32`. Optional: without it hermes generates one per process, and every restart logs everyone out. |

The plugin also accepts a precomputed `…_PASSWORD_HASH`, and this repo does not use it.
It would keep the plaintext out of the secret and out of `~/.hermes/.env` — but every
other key in that file is an API token worth more than a dashboard login, so a hash here
protects nothing the file does not already hold, and it costs a hashing step on the box
every time the password changes.

```sh
aws secretsmanager get-secret-value --region ca-west-1 --secret-id hermes \
  --query SecretString --output text \
  | jq '.HERMES_DASHBOARD_BASIC_AUTH_USERNAME="tyrel"
        | .HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="…"
        | .HERMES_DASHBOARD_BASIC_AUTH_SECRET="…"' \
  > hermes.json
aws secretsmanager put-secret-value --region ca-west-1 --secret-id hermes \
  --secret-string file://hermes.json
rm hermes.json
```

Then `./deploy.sh hermes`. Rotation is the same as the gateway's — update the secret and
restart, because `ExecStartPre` re-renders `.env` on every start:

```sh
ssh root@hermes systemctl restart hermes-dashboard
```

Set the username without the password and the install refuses rather than handing you a
server that crash-loops on the auth gate. Remove the username and a later run disables
the unit, deletes it, switches the serve config off and unsets `public_url` — otherwise
`Restart=always` would grind against a gate that can no longer be satisfied.

### http today, https when the tailnet says so

`tailscale serve`'s default mode is https:443, which needs a cert, which the tailnet only
issues once **HTTPS Certificates** is enabled in the admin console. It is off today, so
the installer reads `CertDomains` from `tailscale status --json`, finds nothing, and
serves http:80 instead — announcing that it did. The hop is still inside WireGuard, and
the auth cookies drop their `__Host-`/`Secure` prefixes to match the scheme.

Switch the feature on in the admin console, re-run `./deploy.sh hermes`, and the same
code picks https:443 and the prefixed cookies.

### Verifying

```sh
ssh root@hermes 'systemctl status hermes-dashboard --no-pager'
ssh root@hermes 'journalctl -u hermes-dashboard -n 50 --no-pager'
ssh root@hermes tailscale serve status
```

| Check | Expect |
|---|---|
| `curl -o /dev/null -w '%{http_code}' http://hermes.tail16ed35.ts.net/login` | `200` |
| Same URL for `/` while logged out | `302` to `/login` |
| Same, from a device *off* the tailnet | nothing — no route, no ingress rule |
| A wrong password | `401` |
| `sudo -u hermes curl 127.0.0.1:9119/` with `public_url` unset | `200`, unauthenticated — the local-only mode, and the reason `public_url` is what gates |

## Obsidian vault

`install_obsidian.sh`. Puts a real Obsidian vault on the box, kept in sync by
[obsidian-headless](https://github.com/obsidianmd/obsidian-headless) — the official CLI
client for Obsidian Sync, no desktop app. The agent's shell is the host (Phase 3), so
the vault needs no mount and no wiring to be visible to it — all this has to get right
is who owns the directory. Notes edited on a phone show up in the agent's filesystem,
and (in the default mode) the agent's edits show up on the phone.

`./deploy.sh` runs it after `install_hermes.sh`, and it is a no-op when the `OBSIDIAN_*`
keys are absent from the secret, exactly like the Phase 4 gateway. On its own:

```sh
./deploy.sh obsidian
ssh root@hermes /usr/local/sbin/hermes-obsidian-install   # or re-run it in place
```

Knobs, all optional: `SYNC_MODE=` (below), `VAULT_DIR=` (overrides
`OBSIDIAN_VAULT_PATH` in the secret for one run; `/srv/obsidian` if neither is set),
`OB_VERSION=` and `NODE_MAJOR=`, `FORCE=1` to reinstall the client over the top.

### Setting it up

Five values in the secret, read-modify-write as in Phase 4:

```sh
aws secretsmanager get-secret-value --region ca-west-1 --secret-id hermes \
  --query SecretString --output text \
  | jq '.OBSIDIAN_EMAIL="…" | .OBSIDIAN_PASSWORD="…" | .OBSIDIAN_VAULT="My Vault"
        | .OBSIDIAN_VAULT_PASSWORD="…" | .OBSIDIAN_VAULT_PATH="/srv/obsidian"' \
  > hermes.json
aws secretsmanager put-secret-value --region ca-west-1 --secret-id hermes \
  --secret-string file://hermes.json
rm hermes.json
```

`OBSIDIAN_VAULT` is the remote vault's name or ID as `ob sync-list-remote` reports it.
`OBSIDIAN_VAULT_PASSWORD` is the end-to-end encryption password and is only needed for an
E2EE vault — leave it empty otherwise. An active Sync subscription is required.

`OBSIDIAN_VAULT_PATH` is where the vault lands, and it is one value read at both ends:
`install_obsidian.sh` syncs into it and takes ownership of it, and `hermes-render-env`
puts it in `~/.hermes/.env` so the agent knows where its notes are. The notes land
*directly* in that directory — there is no per-vault subdirectory under it. It is the one
`OBSIDIAN_*` key that is not a credential, which is why the denylist names the other
three instead of matching the prefix.

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

**Log in as `root`, not as `hermes`.** The daemon runs as root (see above), and it is
root's session it uses. A login as the `hermes` user does nothing for it and leaves an
Obsidian account credential sitting in the agent's own home directory —
`install_obsidian.sh` warns if it finds one. Clear it with
`sudo -u hermes -H ob logout`.

**The Obsidian *credentials* never reach `~/.hermes/.env`** — `hermes-render-env` drops
`OBSIDIAN_EMAIL`, `OBSIDIAN_PASSWORD` and `OBSIDIAN_VAULT_PASSWORD` by name, alongside
`TAILSCALE_AUTH_KEY`, and `install_obsidian.sh` reads them from Secrets Manager directly
instead. That email and password are every vault on the account plus the ability to change
the password; the vault password is the encryption key. `OBSIDIAN_VAULT` and
`OBSIDIAN_VAULT_PATH` are *not* dropped — a vault name and a path are things the agent has
a use for, and the split this section describes is about the account, not the notes. The
reasoning is in the comment on that filter.

**The sync daemon runs as root, and so does the login.** Deliberate, and the one place
this repo departs from "services run as `hermes`". The stored Obsidian session lands in
root's home, where the `hermes` user the agent runs as cannot read it. That session is
the whole *account* — every vault on it, and the ability to change the password; the
vault directory is one vault's notes. The agent gets the notes and not the account, and
that split is the only reason anything here still runs as root.

### Who owns the vault

Two writers at two uids: the sync daemon (root) and the agent's shell (`hermes`). They
share the directory by group, which `install_obsidian.sh` sets on every run:

- Owner `root`, group `hermes`, `2770` on every directory and `660` on every file.
- The setgid bit keeps directories created inside in the `hermes` group.
- `UMask=0007` on `obsidian-sync.service`, and the same umask around the install's own
  one-shot `ob sync`. Without it every file the daemon pulls down lands `644` — readable
  to the agent, not writable — and editing a synced note fails. Both are needed: the
  chmod pass runs before the first sync, when the directory is still empty.

root ignores modes, so only the `hermes` side of this needs spelling out.

### Sync mode

| `SYNC_MODE` | Vault modes | umask | Effect |
|---|---|---|---|
| `bidirectional` (default) | `2770` / `660` | `0007` | The agent's edits propagate to every device on the account. |
| `pull-only` | `2750` / `640` | `0027` | Vault is read-only to the agent; local changes ignored. |
| `mirror-remote` | `2750` / `640` | `0027` | Same, and any local change is reverted. |

Set on every run, not just at setup, so it converges rather than drifting — flipping the
mode rewrites the modes already on disk. Group write is the read-only switch: under
`pull-only`/`mirror-remote` a local edit is either ignored or reverted on the next sync,
and a vault the agent can write to but whose writes vanish is worse than one that
refuses the write with `EACCES`.

```sh
SYNC_MODE=pull-only ./deploy.sh obsidian
```

### Telling the agent it has a vault

Reachable is not the same as known. Nothing in the agent's context mentions the vault, so
asked "where are my notes" it has no reason to go looking in `/srv` — which is exactly
what happened the first time. `install_obsidian.sh` writes a block into
`~/.hermes/AGENTS.md`, which Hermes auto-injects into every session alongside `SOUL.md`
and memory.

It has to be `~/.hermes/AGENTS.md`, not `~/AGENTS.md`: injection reads the directory the
process runs from and **does not walk up the tree**, and the gateway's
`WorkingDirectory` is `~/.hermes`. Verified both ways — a sentinel fact at `~/AGENTS.md`
is invisible to the gateway, the same fact at `~/.hermes/AGENTS.md` comes back without a
tool call.

The block is delimited and rewritten on every run, so anything else in that file
survives. Its wording follows `SYNC_MODE`, so under `pull-only` the agent is told the
vault is read-only rather than being left to discover it by failing a write.

### Verifying

The script checks all of this itself except the last row: a one-shot `ob sync` before
installing the unit (which is what proves the login and the E2EE password), then
`sync-status`, then `test -r`/`test -w` **as the `hermes` user** — root passes those
whatever the mode says, which is why checking as root proves nothing — and finally one
real agent tool call. That last one matters: the container version of this script once
checked the mount by hand, passed, and left a box where the vault was invisible to the
agent. The shell the agent actually gets is the thing under test.

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
- **`terminal.backend` is `local` (Phase 3).** The agent's shell is this host, as the
  `hermes` user, with no container between it and the filesystem. The VM is the boundary;
  read the trade-off in Phase 3 before adding anything to this box that is not the
  agent's.
- The root volume has `delete_on_termination = false`. `terraform destroy` leaves the
  volume behind on purpose — it holds `~/.hermes`. Delete it manually when you mean to.
- Egress includes TCP 80 and UDP 53 beyond the plan's 443/41641: Ubuntu's arm64 apt
  mirrors are plain HTTP and DNS must reach the VPC resolver. Drop them and the box
  cannot patch itself or resolve anything.
- **A hand-added `GAPI` key was on the live box's `.env`, and nothing ever read it.** It
  was not in the secret and no script here writes it; `hermes-render-env` rewrites that
  file from the secret on every run *and* from both units' `ExecStartPre`, so it is gone
  now. It was not doing anything even while it was there — `GAPI` is a shell alias in the
  google-workspace skill's docs, not a variable that skill reads. See **Google Workspace**
  for where those credentials actually belong. (`OBSIDIAN_VAULT_PATH` was hand-added the
  same way and is now a real secret key — see the Obsidian section.)
- The AMI comes from Canonical's SSM public parameter, but the instance ignores AMI
  changes so a new Canonical image never silently replaces the running agent. To move
  to a newer image: `terraform taint aws_instance.hermes` then apply, on purpose.
wher

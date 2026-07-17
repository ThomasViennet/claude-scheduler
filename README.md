# claude-scheduler

**English** · [Version française](README.fr.md)

Automatically sends a minimal message to Claude at fixed times to **anchor the 5-hour usage windows** of a Claude Pro/Max subscription to predictable hours.

## Why

Claude subscriptions work with 5-hour quota windows that **start when you send your first message**. If your first interaction of the day happens at a random time, your quota resets happen at random times. By sending an automatic "hi" at fixed times (07:00, 12:00 and 17:00 by default), the windows chain predictably: 07:00–12:00, 12:00–17:00, 17:00–22:00.

## How it works

The official **Claude Code** CLI, authenticated with your subscription (not an API key), consumes the **same quota** as claude.ai. A simple:

```bash
claude -p "hi" --model haiku
```

therefore opens a 5-hour window exactly like a message on the website would — at a negligible quota cost (Haiku + a one-word message). This repo provides two bash scripts around that command:

- **`ping.sh`** — sends the message, logs the result, handles a concurrency lock, a timeout, a single retry on transient errors, and log rotation.
- **`apply-schedule.sh`** — reads the times from `scheduler.conf` and installs the matching cron lines (idempotent block: re-running the script updates the block without touching the rest of your crontab).

No dependencies beyond bash, cron and the claude CLI.

## Requirements

- A machine that is powered on at ping times: server, VPS, Raspberry Pi… (Linux; also testable on macOS).
- A Claude Pro or Max subscription.
- `bash` and `cron` (present by default on Linux).

## Installation (Raspberry Pi / Linux server)

1. **Timezone** — the times in `scheduler.conf` are the machine's local time (VPS are often set to UTC):

   ```bash
   sudo timedatectl set-timezone Europe/Paris
   date   # check
   ```

2. **Install the Claude Code CLI**:

   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   ```

   The binary lands in `~/.local/bin/claude`. Fallback if the installer does not support your architecture: `sudo apt install nodejs npm && npm install -g @anthropic-ai/claude-code` (then adjust `CLAUDE_BIN` in `scheduler.conf`).

3. **Log in with your subscription** (works over SSH, no display needed):

   ```bash
   claude setup-token
   ```

   The CLI prints an OAuth URL: open it in a browser on another device (laptop, phone), log in with your claude.ai account, then paste the returned code into the SSH terminal. The long-lived token is stored in `~/.claude/.credentials.json`.

   > Note: copying `~/.claude/.credentials.json` from another **Linux** machine also works — but only via direct `scp` between the two machines (never through a cloud drive, email or chat), followed by `chmod 600` on the copy. It does not work from macOS (credentials live in the Keychain, not in a file). The clean method remains `claude setup-token` on each machine.

4. **Clone, configure, test**:

   ```bash
   git clone https://github.com/ThomasViennet/claude-scheduler.git && cd claude-scheduler
   nano scheduler.conf        # adjust PING_TIMES if needed
   ./ping.sh --dry-run        # checks the command without calling Claude
   ./ping.sh                  # real test: expect [OK] in logs/ping.log
   tail logs/ping.log
   ```

5. **Install the schedule**:

   ```bash
   ./apply-schedule.sh
   crontab -l                 # check the claude-scheduler block
   systemctl status cron      # check the cron daemon is running
   ```

## Configuration (`scheduler.conf`)

| Key | Default | Purpose |
|---|---|---|
| `PING_TIMES` | `07:00 12:00 17:00` | Ping times (machine local time, HH:MM format, space-separated). Ideally spaced ≥ 5h apart. |
| `MODEL` | `haiku` | Model used (the cheapest in quota terms). |
| `PROMPT` | `hi` | Message sent. |
| `PING_TIMEOUT` | `120` | Max duration of one call in seconds (if `timeout` is available). |
| `RETRY_DELAY` | `30` | Wait before the single retry. |
| `CLAUDE_BIN` | `~/.local/bin/claude` | Path to the claude binary. |
| `LOG_FILE` | *(empty)* | Log file; empty = `logs/ping.log` in the repo. If you place it elsewhere in the repo, keep the `.log` extension (covered by `.gitignore`) so your logs are never committed. |
| `MAX_LOG_LINES` | `2000` | Above this, the log is truncated to the last half. |

After changing `PING_TIMES`, re-run `./apply-schedule.sh` to regenerate the crontab.

## Usage

```bash
./ping.sh                    # send a ping now
./ping.sh --dry-run          # log the command without executing it
./apply-schedule.sh          # install / update the cron block
./apply-schedule.sh --remove # cleanly remove the cron block
tail -f logs/ping.log        # follow the runs
```

Log format — one line per event:

```
2026-07-15T07:00:04+0200 [OK] model=haiku duration=5s response="Hi! How can I help you today?"
2026-07-15T12:00:02+0200 [RETRY] exit=1 retrying in 30s
2026-07-15T12:00:35+0200 [ERROR] exit=1 output="fetch failed ..."
```

Possible statuses: `OK`, `DRY-RUN`, `QUOTA` (limit already reached — harmless, a window is already open), `AUTH` (expired token → re-run `claude setup-token`), `RETRY`/`ERROR` (transient or persistent error), `SKIP` (concurrent run ignored).

## Security

- **The token = a password.** `~/.claude/.credentials.json` grants access to your Claude subscription (sending requests against your quota — not your billing or your conversations). Treat it like a password: `600` permissions (the CLI sets them itself), never committed, never shared, never transferred through a third-party service.
- **Revocation.** If in doubt (compromised or decommissioned machine…), invalidate the token: log out on that machine (`claude` then `/logout`, or delete `~/.claude/.credentials.json`) and re-authenticate where needed. Pings from a machine with an invalid token show up as `[AUTH]` in the log.
- **`scheduler.conf` is executed.** This file is sourced by the scripts: any line it contains runs with your privileges. Review it as code if a change comes from a third party.
- **Logs stay local.** `logs/` and `*.log` are excluded by `.gitignore`. Before pasting a log excerpt into a public issue, remove personal paths (`/home/<user>/…`).

## Known limitations

- **Machine off at ping time**: cron does not catch up on missed runs. This is deliberate: a catch-up ping at boot would open a window at an arbitrary time — exactly the unpredictability this tool exists to eliminate. Better a missed anchor than a misaligned one.
- **Ping inside an already-open window** (times spaced < 5h apart, or if you already wrote to Claude before): harmless and nearly free, but it anchors nothing — the current window continues.
- **Token expiry** (~1 year): pings switch to `[AUTH]` in the log; re-run `claude setup-token`.
- **Daylight saving time**: cron handles switch nights crudely (a time scheduled between 02:00 and 03:00 can skip or run twice). The default times are unaffected.
- **Weekly limits**: on subscriptions that have them, this mechanism only anchors the 5-hour windows; it does not change weekly caps (the pings' cost against them is negligible).

## Local testing on macOS

The scripts also work on macOS (atomic-`mkdir` lock in place of `flock`, optional `timeout`). To try without polluting your crontab: `./ping.sh --dry-run`, then `./apply-schedule.sh` followed by `./apply-schedule.sh --remove`.

macOS limitation: a ping launched **by cron** fails there with `[AUTH]`, because claude credentials are stored in the Keychain, which cron sessions cannot access (manual `./ping.sh` runs work fine). macOS is therefore only for testing — deploy on Linux, where credentials live in `~/.claude/.credentials.json`.

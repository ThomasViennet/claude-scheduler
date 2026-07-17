---
name: Bug report
about: Report a problem to help us improve
title: "[Bug] "
labels: bug
assignees: ''
---

## Describe the bug

A clear and concise description of what the bug is.

## Steps to reproduce

1. Configuration used (`scheduler.conf` values, redacted if needed)
2. Command run (`./ping.sh`, `./apply-schedule.sh`, cron trigger…)
3. See error

## Expected behavior

What you expected to happen.

## Actual behavior

What actually happened.

## Environment

- OS / distribution (e.g. Raspberry Pi OS Bookworm 64-bit, Debian 12, Ubuntu 24.04):
- Hardware (e.g. Raspberry Pi 3, VPS):
- Claude Code CLI version (`claude --version`):
- Version of claude-scheduler (commit or tag):

## Additional context

Relevant lines from `logs/ping.log` help a lot.
**Before pasting logs, remove personal paths (`/home/<user>/…`) and any other detail you consider private.** Never paste the content of `~/.claude/.credentials.json`.

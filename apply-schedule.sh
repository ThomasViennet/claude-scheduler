#!/usr/bin/env bash
# Installs (or removes with --remove) the claude-scheduler cron lines.
# Idempotent: only the block between the BEGIN/END markers is replaced,
# the rest of the crontab is preserved.
# Usage: ./apply-schedule.sh [--remove]
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/scheduler.conf"
PING="$SCRIPT_DIR/ping.sh"

BEGIN_MARK="# claude-scheduler BEGIN (managed block - run apply-schedule.sh to edit)"
END_MARK="# claude-scheduler END"

current="$(crontab -l 2>/dev/null || true)"

# Safety check: a BEGIN without END would make the sed below delete everything
# that follows, including cron lines that do not belong to this tool.
if printf '%s\n' "$current" | grep -q '^# claude-scheduler BEGIN' \
  && ! printf '%s\n' "$current" | grep -q '^# claude-scheduler END'; then
  echo "Corrupted crontab: BEGIN marker without END. Fix it by hand (crontab -e) before re-running." >&2
  exit 1
fi

cleaned="$(printf '%s\n' "$current" | sed '/^# claude-scheduler BEGIN/,/^# claude-scheduler END/d')"

if [ "${1:-}" = "--remove" ]; then
  if [ -z "$(printf '%s' "$cleaned" | tr -d '[:space:]')" ]; then
    # printf '' | crontab - rather than crontab -r: same effect (empty crontab),
    # without the prompt/hang of -r observed on some environments.
    printf '' | crontab - || { echo "Failed to write crontab." >&2; exit 1; }
    echo "claude-scheduler block removed; crontab is now empty."
  else
    printf '%s\n' "$cleaned" | crontab - || { echo "Failed to write crontab." >&2; exit 1; }
    echo "claude-scheduler block removed."
  fi
  exit 0
fi

if [ ! -f "$CONF" ]; then
  echo "Config file not found: $CONF" >&2
  exit 1
fi
# shellcheck source=scheduler.conf
. "$CONF"

if [ -z "${PING_TIMES:-}" ]; then
  echo "PING_TIMES is empty in scheduler.conf" >&2
  exit 1
fi
if [ ! -x "$PING" ]; then
  echo "$PING is not executable (chmod +x ping.sh)" >&2
  exit 1
fi
for t in $PING_TIMES; do
  if ! [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "Invalid time: '$t' (expected format HH:MM, from 00:00 to 23:59)" >&2
    exit 1
  fi
done
if [ ! -x "$CLAUDE_BIN" ]; then
  echo "Warning: CLAUDE_BIN ($CLAUDE_BIN) not found — install the CLI before the first ping runs." >&2
fi
# % is special to Vixie cron (end of command) even when quoted; the others
# would break out of the double quotes in the sh-interpreted cron line.
case "$SCRIPT_DIR" in
  *%*|*'"'*|*'$'*|*'`'*|*';'*|*'\'*|*$'\n'*)
    echo "The repository path contains a character incompatible with cron or its command line (% \" \$ \` ; \\ or newline): $SCRIPT_DIR" >&2
    echo "Move the repository to a path without special characters." >&2
    exit 1
    ;;
esac

# The >> redirection in the cron line does not create the directory: it must
# exist before the first trigger (a fresh clone has no logs/, it is gitignored).
mkdir -p "$SCRIPT_DIR/logs"

{
  [ -n "$cleaned" ] && printf '%s\n' "$cleaned"
  echo "$BEGIN_MARK"
  for t in $PING_TIMES; do
    h="${t%%:*}"
    m="${t##*:}"
    echo "${m#0} ${h#0} * * * \"$PING\" >> \"$SCRIPT_DIR/logs/ping.log\" 2>&1"
  done
  echo "$END_MARK"
} | crontab - || { echo "Failed to write crontab." >&2; exit 1; }

echo "Installed crontab block:"
echo
crontab -l | sed -n '/^# claude-scheduler BEGIN/,/^# claude-scheduler END/p'
echo
echo "Machine timezone: $(date +'%Z (UTC%z)') — the times above are local time."
if command -v timedatectl >/dev/null 2>&1; then
  echo "To change it: sudo timedatectl set-timezone Europe/Paris"
fi
echo "Check with: crontab -l"

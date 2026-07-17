#!/usr/bin/env bash
# Sends a minimal message to Claude to anchor the 5-hour quota window.
# Usage: ./ping.sh [--dry-run]
# Exit codes: 0 = OK / quota already reached / concurrent run skipped,
#             1 = error (auth, persistent network failure, config).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/scheduler.conf"
if [ ! -f "$CONF" ]; then
  echo "Config file not found: $CONF" >&2
  exit 1
fi
# shellcheck source=scheduler.conf
. "$CONF"

# Cron starts with a minimal PATH (/usr/bin:/bin).
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

[ -n "$LOG_FILE" ] || LOG_FILE="$SCRIPT_DIR/logs/ping.log"
# logs/ is required even with a custom LOG_FILE: the lock lives there.
mkdir -p "$SCRIPT_DIR/logs" "$(dirname "$LOG_FILE")"

DRY_RUN="${DRY_RUN:-0}"
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() {
  printf '%s [%s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" "$2" >> "$LOG_FILE"
}

# Flattens multi-line output, strips control characters (including ANSI
# escapes — the log is read back in a terminal via tail/cat) and truncates.
flat() {
  printf '%s' "$1" | tr '\n' ' ' | tr -d '\000-\010\013-\037\177' | cut -c1-"$2"
}

# --- Concurrency lock --------------------------------------------------------
# flock (Linux); otherwise atomic mkdir (macOS) with stale-lock steal > 10 min.
LOCK_DIR="$SCRIPT_DIR/logs/.ping.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$SCRIPT_DIR/logs/.ping.lockfile"
  if ! flock -n 9; then
    log "SKIP" "another run is in progress"
    exit 0
  fi
else
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rmdir "$LOCK_DIR" 2>/dev/null
      if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "SKIP" "another run is in progress"
        exit 0
      fi
    else
      log "SKIP" "another run is in progress"
      exit 0
    fi
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
fi

# --- Log rotation ------------------------------------------------------------
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
  tmp="$(mktemp)" && tail -n "$((MAX_LOG_LINES / 2))" "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
fi

CMD=("$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --no-session-persistence)

if [ "$DRY_RUN" = "1" ]; then
  log "DRY-RUN" "command: ${CMD[*]}"
  exit 0
fi

# Sets OUTPUT, STATUS, DURATION.
attempt_once() {
  local start end
  start=$(date +%s)
  # 9>&- : do not pass the flock fd down to claude and its descendants,
  # otherwise a detached process would keep holding the lock after we exit.
  if command -v timeout >/dev/null 2>&1; then
    OUTPUT="$(timeout "$PING_TIMEOUT" "${CMD[@]}" 2>&1 9>&-)"
  else
    OUTPUT="$("${CMD[@]}" 2>&1 9>&-)"
  fi
  STATUS=$?
  end=$(date +%s)
  DURATION=$((end - start))
}

# Deliberately narrow: a transient "rate limit" (429) must go through RETRY,
# not be classified as subscription quota.
is_quota() {
  printf '%s' "$OUTPUT" | grep -qiE 'usage limit|limit reached'
}

# Actual CLI message verified: "Not logged in · Please run /login"
is_auth() {
  printf '%s' "$OUTPUT" | grep -qiE 'not (logged|authenticated)|invalid.*(token|api key)|please run /login'
}

attempt_once
if [ "$STATUS" -ne 0 ]; then
  if is_quota; then
    # Quota exhausted = a window is already open, retrying is pointless.
    log "QUOTA" "exit=$STATUS output=\"$(flat "$OUTPUT" 200)\""
    exit 0
  fi
  if is_auth; then
    log "AUTH" "exit=$STATUS output=\"$(flat "$OUTPUT" 200)\" — re-run: claude setup-token"
    exit 1
  fi
  log "RETRY" "exit=$STATUS retrying in ${RETRY_DELAY}s"
  sleep "$RETRY_DELAY"
  attempt_once
fi

if [ "$STATUS" -eq 0 ]; then
  log "OK" "model=$MODEL duration=${DURATION}s response=\"$(flat "$OUTPUT" 80)\""
  exit 0
fi

if is_quota; then
  log "QUOTA" "exit=$STATUS output=\"$(flat "$OUTPUT" 200)\""
  exit 0
fi
if is_auth; then
  log "AUTH" "exit=$STATUS output=\"$(flat "$OUTPUT" 200)\" — re-run: claude setup-token"
  exit 1
fi
log "ERROR" "exit=$STATUS output=\"$(flat "$OUTPUT" 200)\""
exit 1

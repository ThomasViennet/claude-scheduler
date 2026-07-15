#!/usr/bin/env bash
# Envoie un message minimal à Claude pour ancrer la fenêtre de quota de 5h.
# Usage : ./ping.sh [--dry-run]
# Codes de sortie : 0 = OK / quota déjà atteint / run concurrent ignoré,
#                   1 = erreur (auth, réseau persistant, config).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/scheduler.conf"
if [ ! -f "$CONF" ]; then
  echo "Config introuvable : $CONF" >&2
  exit 1
fi
# shellcheck source=scheduler.conf
. "$CONF"

# Cron démarre avec un PATH minimal (/usr/bin:/bin).
export PATH="$HOME/.local/bin:/usr/local/bin:/opt/homebrew/bin:$PATH"

[ -n "$LOG_FILE" ] || LOG_FILE="$SCRIPT_DIR/logs/ping.log"
# logs/ est requis même avec un LOG_FILE personnalisé : le verrou y vit.
mkdir -p "$SCRIPT_DIR/logs" "$(dirname "$LOG_FILE")"

DRY_RUN="${DRY_RUN:-0}"
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

log() {
  printf '%s [%s] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$1" "$2" >> "$LOG_FILE"
}

# Aplatit une sortie multi-ligne et la tronque pour tenir sur une ligne de log.
flat() {
  printf '%s' "$1" | tr '\n' ' ' | cut -c1-"$2"
}

# --- Verrou anti-concurrence -------------------------------------------------
# flock (Linux) ; sinon mkdir atomique (macOS) avec vol de verrou > 10 min.
LOCK_DIR="$SCRIPT_DIR/logs/.ping.lock"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$SCRIPT_DIR/logs/.ping.lockfile"
  if ! flock -n 9; then
    log "SKIP" "un autre run est en cours"
    exit 0
  fi
else
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      rmdir "$LOCK_DIR" 2>/dev/null
      if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        log "SKIP" "un autre run est en cours"
        exit 0
      fi
    else
      log "SKIP" "un autre run est en cours"
      exit 0
    fi
  fi
  trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT
fi

# --- Rotation du log ---------------------------------------------------------
if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt "$MAX_LOG_LINES" ]; then
  tmp="$(mktemp)" && tail -n "$((MAX_LOG_LINES / 2))" "$LOG_FILE" > "$tmp" && mv "$tmp" "$LOG_FILE"
fi

CMD=("$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --no-session-persistence)

if [ "$DRY_RUN" = "1" ]; then
  log "DRY-RUN" "command: ${CMD[*]}"
  exit 0
fi

# Renseigne OUTPUT, STATUS, DURATION.
attempt_once() {
  local start end
  start=$(date +%s)
  # 9>&- : ne pas transmettre le fd du verrou flock à claude et ses
  # descendants, sinon un processus détaché garderait le verrou après nous.
  if command -v timeout >/dev/null 2>&1; then
    OUTPUT="$(timeout "$PING_TIMEOUT" "${CMD[@]}" 2>&1 9>&-)"
  else
    OUTPUT="$("${CMD[@]}" 2>&1 9>&-)"
  fi
  STATUS=$?
  end=$(date +%s)
  DURATION=$((end - start))
}

# Volontairement étroit : un « rate limit » transitoire (429) doit passer
# par RETRY, pas être classé quota d'abonnement.
is_quota() {
  printf '%s' "$OUTPUT" | grep -qiE 'usage limit|limit reached'
}

# Message réel du CLI vérifié : « Not logged in · Please run /login »
is_auth() {
  printf '%s' "$OUTPUT" | grep -qiE 'not (logged|authenticated)|invalid.*(token|api key)|please run /login'
}

attempt_once
if [ "$STATUS" -ne 0 ]; then
  if is_quota; then
    # Quota épuisé = une fenêtre est déjà ouverte, inutile de réessayer.
    log "QUOTA" "exit=$STATUS output=\"$(flat "$OUTPUT" 200)\""
    exit 0
  fi
  if is_auth; then
    log "AUTH" "exit=$STATUS output=\"$(flat "$OUTPUT" 200)\" — relancer : claude setup-token"
    exit 1
  fi
  log "RETRY" "exit=$STATUS nouvelle tentative dans ${RETRY_DELAY}s"
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
  log "AUTH" "exit=$STATUS output=\"$(flat "$OUTPUT" 200)\" — relancer : claude setup-token"
  exit 1
fi
log "ERROR" "exit=$STATUS output=\"$(flat "$OUTPUT" 200)\""
exit 1

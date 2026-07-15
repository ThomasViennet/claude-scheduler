#!/usr/bin/env bash
# Installe (ou retire avec --remove) les lignes cron de claude-scheduler.
# Idempotent : seul le bloc entre les marqueurs BEGIN/END est remplacé,
# le reste du crontab est préservé.
# Usage : ./apply-schedule.sh [--remove]
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONF="$SCRIPT_DIR/scheduler.conf"
PING="$SCRIPT_DIR/ping.sh"

BEGIN_MARK="# claude-scheduler BEGIN (bloc gere automatiquement - lancer apply-schedule.sh pour modifier)"
END_MARK="# claude-scheduler END"

current="$(crontab -l 2>/dev/null || true)"

# Garde-fou : un BEGIN sans END ferait supprimer par le sed ci-dessous tout
# ce qui suit, y compris des lignes cron n'appartenant pas à cet outil.
if printf '%s\n' "$current" | grep -q '^# claude-scheduler BEGIN' \
  && ! printf '%s\n' "$current" | grep -q '^# claude-scheduler END'; then
  echo "Crontab corrompu : marqueur BEGIN sans END. Corrigez-le à la main (crontab -e) avant de relancer." >&2
  exit 1
fi

cleaned="$(printf '%s\n' "$current" | sed '/^# claude-scheduler BEGIN/,/^# claude-scheduler END/d')"

if [ "${1:-}" = "--remove" ]; then
  if [ -z "$(printf '%s' "$cleaned" | tr -d '[:space:]')" ]; then
    # printf '' | crontab - plutôt que crontab -r : même effet (crontab vide),
    # sans le prompt/blocage de -r observé sur certains environnements.
    printf '' | crontab - || { echo "Échec de l'écriture du crontab." >&2; exit 1; }
    echo "Bloc claude-scheduler retiré ; crontab désormais vide."
  else
    printf '%s\n' "$cleaned" | crontab - || { echo "Échec de l'écriture du crontab." >&2; exit 1; }
    echo "Bloc claude-scheduler retiré."
  fi
  exit 0
fi

if [ ! -f "$CONF" ]; then
  echo "Config introuvable : $CONF" >&2
  exit 1
fi
# shellcheck source=scheduler.conf
. "$CONF"

if [ -z "${PING_TIMES:-}" ]; then
  echo "PING_TIMES est vide dans scheduler.conf" >&2
  exit 1
fi
if [ ! -x "$PING" ]; then
  echo "$PING n'est pas exécutable (chmod +x ping.sh)" >&2
  exit 1
fi
for t in $PING_TIMES; do
  if ! [[ "$t" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    echo "Heure invalide : '$t' (format attendu HH:MM, de 00:00 à 23:59)" >&2
    exit 1
  fi
done
if [ ! -x "$CLAUDE_BIN" ]; then
  echo "Attention : CLAUDE_BIN ($CLAUDE_BIN) introuvable — installez le CLI avant le premier ping." >&2
fi
case "$SCRIPT_DIR" in
  *%*|*$'\n'*)
    # % est un caractère spécial de Vixie cron (fin de commande), même quoté.
    echo "Le chemin du dépôt contient un caractère incompatible avec cron (% ou saut de ligne) : $SCRIPT_DIR" >&2
    exit 1
    ;;
esac

# La redirection >> de la ligne cron ne crée pas le dossier : il doit exister
# avant le premier déclenchement (un clone frais n'a pas logs/, gitignoré).
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
} | crontab - || { echo "Échec de l'écriture du crontab." >&2; exit 1; }

echo "Bloc installé dans le crontab :"
echo
crontab -l | sed -n '/^# claude-scheduler BEGIN/,/^# claude-scheduler END/p'
echo
echo "Fuseau horaire de la machine : $(date +'%Z (UTC%z)') — les heures ci-dessus sont en heure locale."
if command -v timedatectl >/dev/null 2>&1; then
  echo "Pour le changer : sudo timedatectl set-timezone Europe/Paris"
fi
echo "Vérifiez avec : crontab -l"

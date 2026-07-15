# claude-scheduler

Automatically sends scheduled messages to Claude at configurable times to anchor the 5-hour usage windows.

Envoie automatiquement un message minimal à Claude à heures fixes pour **ancrer les fenêtres de quota de 5 h** de l'abonnement Claude Pro/Max à des horaires prévisibles.

## But

Les abonnements Claude fonctionnent par fenêtres de quota de 5 h qui **démarrent au premier message envoyé**. Si votre première interaction de la journée a lieu à une heure aléatoire, les resets de quota tombent à des heures aléatoires. En envoyant un « hi » automatique à heures fixes (par défaut 07:00, 12:00 et 17:00), les fenêtres s'enchaînent de façon prévisible : 07:00–12:00, 12:00–17:00, 17:00–22:00.

## Comment ça marche

Le CLI officiel **Claude Code**, connecté avec votre abonnement (et non une clé API), consomme le **même quota** que claude.ai. Un simple :

```bash
claude -p "hi" --model haiku
```

ouvre donc une fenêtre de 5 h exactement comme un message sur le site web — pour un coût de quota négligeable (Haiku + message d'un mot). Ce dépôt fournit deux scripts bash autour de cette commande :

- **`ping.sh`** — envoie le message, journalise le résultat, gère verrou anti-concurrence, timeout, une nouvelle tentative en cas d'erreur transitoire, et rotation du log.
- **`apply-schedule.sh`** — lit les horaires dans `scheduler.conf` et installe les lignes cron correspondantes (bloc idempotent : ré-exécuter le script met à jour le bloc sans toucher au reste du crontab).

Aucune dépendance en dehors de bash, cron et du CLI claude.

## Prérequis

- Une machine allumée aux heures de ping : serveur, VPS, Raspberry Pi… (Linux ; testable aussi sur macOS).
- Un abonnement Claude Pro ou Max.
- `bash` et `cron` (présents par défaut sur Linux).

## Installation (Raspberry Pi / serveur Linux)

1. **Fuseau horaire** — les heures de `scheduler.conf` sont en heure locale de la machine (les VPS sont souvent en UTC) :

   ```bash
   sudo timedatectl set-timezone Europe/Paris
   date   # vérifier
   ```

2. **Installer le CLI Claude Code** :

   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   ```

   Le binaire est installé dans `~/.local/bin/claude`. Solution de repli si l'installeur ne supporte pas votre architecture : `sudo apt install nodejs npm && npm install -g @anthropic-ai/claude-code` (puis adapter `CLAUDE_BIN` dans `scheduler.conf`).

3. **Se connecter avec l'abonnement** (fonctionne en SSH, sans écran) :

   ```bash
   claude setup-token
   ```

   Le CLI affiche une URL OAuth : ouvrez-la dans le navigateur d'un autre appareil (Mac, téléphone), connectez-vous avec votre compte claude.ai, puis collez le code retourné dans le terminal SSH. Le token longue durée est stocké dans `~/.claude/.credentials.json`.

   > Note : copier `~/.claude/.credentials.json` depuis une autre machine **Linux** fonctionne aussi, mais pas depuis macOS (où les identifiants sont dans le Trousseau, pas dans un fichier).

4. **Cloner, configurer, tester** :

   ```bash
   git clone <url-du-depot> && cd claude-scheduler
   nano scheduler.conf        # ajuster PING_TIMES si besoin
   ./ping.sh --dry-run        # vérifie la commande sans appeler Claude
   ./ping.sh                  # test réel : attendre [OK] dans logs/ping.log
   tail logs/ping.log
   ```

5. **Installer le planning** :

   ```bash
   ./apply-schedule.sh
   crontab -l                 # vérifier le bloc claude-scheduler
   systemctl status cron      # vérifier que le démon cron tourne
   ```

## Configuration (`scheduler.conf`)

| Clé | Défaut | Rôle |
|---|---|---|
| `PING_TIMES` | `07:00 12:00 17:00` | Heures d'envoi (heure locale machine, format HH:MM, séparées par des espaces). À espacer idéalement de ≥ 5 h. |
| `MODEL` | `haiku` | Modèle utilisé (le moins coûteux en quota). |
| `PROMPT` | `hi` | Message envoyé. |
| `PING_TIMEOUT` | `120` | Délai max d'un appel en secondes (si `timeout` est disponible). |
| `RETRY_DELAY` | `30` | Attente avant l'unique nouvelle tentative. |
| `CLAUDE_BIN` | `~/.local/bin/claude` | Chemin du binaire claude. |
| `LOG_FILE` | *(vide)* | Fichier de log ; vide = `logs/ping.log` dans le dépôt. |
| `MAX_LOG_LINES` | `2000` | Au-delà, le log est tronqué aux 1000 dernières lignes. |

Après modification de `PING_TIMES`, relancer `./apply-schedule.sh` pour régénérer le crontab.

## Utilisation

```bash
./ping.sh                    # envoie un ping maintenant
./ping.sh --dry-run          # journalise la commande sans l'exécuter
./apply-schedule.sh          # installe / met à jour le bloc cron
./apply-schedule.sh --remove # retire proprement le bloc cron
tail -f logs/ping.log        # suivre les exécutions
```

Format du log — une ligne par événement :

```
2026-07-15T07:00:04+0200 [OK] model=haiku duration=5s response="Hi! How can I help you today?"
2026-07-15T12:00:02+0200 [RETRY] exit=1 nouvelle tentative dans 30s
2026-07-15T12:00:35+0200 [ERROR] exit=1 output="fetch failed ..."
```

Statuts possibles : `OK`, `DRY-RUN`, `QUOTA` (limite déjà atteinte — sans gravité, une fenêtre est déjà ouverte), `AUTH` (token expiré → relancer `claude setup-token`), `RETRY`/`ERROR` (erreur transitoire ou persistante), `SKIP` (exécution concurrente ignorée).

## Limites connues

- **Machine éteinte à l'heure du ping** : cron ne rattrape pas les exécutions manquées. C'est un choix délibéré : un ping de rattrapage au démarrage ouvrirait une fenêtre à une heure arbitraire — exactement l'imprévisibilité que cet outil cherche à éliminer. Mieux vaut un ancrage manqué qu'un ancrage désaligné.
- **Ping dans une fenêtre déjà ouverte** (heures espacées de < 5 h, ou si vous avez déjà écrit à Claude avant) : sans danger et quasi gratuit, mais il n'ancre rien — la fenêtre en cours continue.
- **Expiration du token** (~1 an) : les pings passent en `[AUTH]` dans le log ; relancer `claude setup-token`.
- **Changement d'heure (DST)** : cron gère brutalement les nuits de changement (une heure planifiée entre 02:00 et 03:00 peut sauter ou doubler). Les horaires par défaut ne sont pas concernés.
- **Limites hebdomadaires** : sur les abonnements qui en ont, ce mécanisme n'ancre que les fenêtres de 5 h ; il ne change rien aux plafonds hebdomadaires (le coût des pings y est négligeable).

## Test local sur macOS

Les scripts fonctionnent aussi sur macOS (verrou par `mkdir` atomique à défaut de `flock`, `timeout` optionnel). Pour essayer sans polluer votre crontab : `./ping.sh --dry-run`, puis `./apply-schedule.sh` suivi de `./apply-schedule.sh --remove`.

Limite macOS : un ping lancé **par cron** y échoue en `[AUTH]`, car les identifiants claude sont stockés dans le Trousseau, inaccessible aux sessions cron (en lancement manuel, `./ping.sh` fonctionne). macOS ne sert donc qu'aux tests — le déploiement se fait sur Linux, où les identifiants sont dans `~/.claude/.credentials.json`.

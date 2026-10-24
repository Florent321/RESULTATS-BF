#!/usr/bin/env bash
# =============================================================================
# scripts/app.sh — rôle « app » : app1 à appN, serveurs applicatifs (étape 3)
# =============================================================================
# Installe le service Gunicorn qui sert app/app.py sur le port 3000.
# Rejoué à chaque vagrant up : le service n'est redémarré que si son code, son
# environnement ou son unité a changé (R2). Utilisé aussi par
# scripts/deploiement.sh pour mettre à jour un serveur à la fois (E4).
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "${DEPOT:-/vagrant}/scripts/lib.sh"

UTILISATEUR=resultats
DOSSIER_APP=/opt/resultats-bf/app
FICHIER_ENV=/etc/resultats-bf/app.env
UNITE=resultats
PORT_APP=3000

charger_secrets

# 1. Utilisateur système dédié : le service ne tourne jamais en root.
if ! id -u "$UTILISATEUR" >/dev/null 2>&1; then
  action useradd --system --no-create-home --home-dir /nonexistent \
    --shell /usr/sbin/nologin "$UTILISATEUR"
fi

# 2. Code copié hors de /vagrant (non monté au démarrage de la VM).
modifie=0
ecrire_fichier "$DOSSIER_APP/app.py" 0644 root:root <"$DEPOT/app/app.py"
if (( FICHIER_MODIFIE )); then modifie=1; fi

# 3. Environnement : bases à essayer dans l'ordre (depuis noeuds.yml), version,
#    mot de passe. Variables standard de libpq, lues par psycopg.
engendrer_env() {
  local hotes
  hotes=$(lister_noeuds | awk '$3 == "bdd" || $3 == "replique" { printf "%s%s", sep, $1; sep = "," }')
  cat <<EOF
# Engendré par scripts/app.sh : contient un secret, lisible par root seulement.
APP_ECOUTE=0.0.0.0:$PORT_APP
APP_PROCESSUS=3
APP_VERSION=$(tr -d '\r\n' <"$DEPOT/app/VERSION")
PGHOST=$hotes
PGPORT=5432
PGDATABASE=resultats
PGUSER=app_resultats
PGPASSWORD=$PG_APP_MDP
PGOPTIONS="-c statement_timeout=2000"
EOF
}
ecrire_fichier "$FICHIER_ENV" 0600 root:root < <(engendrer_env)
if (( FICHIER_MODIFIE )); then modifie=1; fi

# 4. Unité systemd.
ecrire_fichier "/etc/systemd/system/$UNITE.service" 0644 root:root <"$DEPOT/app/resultats.service"
if (( FICHIER_MODIFIE )); then
  action systemctl daemon-reload
  modifie=1
fi

# 5. Activé au démarrage ; (re)démarré seulement si quelque chose a changé.
assurer_service "$UNITE" "$modifie"

# 6. Contrôles : le service répond, puis la base est-elle joignable ?
if ! attendre_code_http "http://127.0.0.1:$PORT_APP/info" 200 30; then
  erreur "le service ne répond pas sur le port $PORT_APP (voir : journalctl -u $UNITE -n 30)."
fi
log "service $UNITE : version $(tr -d '\r\n' <"$DEPOT/app/VERSION"), port $PORT_APP"
code=$(code_http "http://127.0.0.1:$PORT_APP/sante")
if [[ $code == 200 ]]; then
  log "base joignable : /sante répond 200"
else
  log "ATTENTION : /sante répond $code (base injoignable ?) ; le répartiteur écartera ce serveur tant que la base ne répond pas."
fi

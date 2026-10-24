# shellcheck shell=bash
# =============================================================================
# scripts/lib_pg.sh — fonctions PostgreSQL de bdd.sh et replique.sh
# =============================================================================
# À sourcer APRÈS lib.sh. Toutes les fonctions sont idempotentes (R2).
# Cluster Debian/Ubuntu « 16/main » : configuration dans /etc/postgresql/16/main,
# données dans /var/lib/postgresql/16/main, jamais dans /vagrant (énoncé §12 :
# les verrous et la durabilité ne fonctionnent pas dans un dossier synchronisé).
# =============================================================================

PG_VERSION=16
PG_CLUSTER=main
PG_PORT=5432
PG_CONF=/etc/postgresql/$PG_VERSION/$PG_CLUSTER
PG_DATA=/var/lib/postgresql/$PG_VERSION/$PG_CLUSTER
PG_SERVICE=postgresql@$PG_VERSION-$PG_CLUSTER
PG_SOCKET=/var/run/postgresql
PG_BASE=resultats
PG_ROLE_APP=app_resultats
PG_ROLE_REPLI=replicateur
ETAT_LOCAL=/etc/resultats-bf
MARQUEUR_PG=$ETAT_LOCAL/postgresql-initialise   # écrit après la première mise en service

PG_A_REDEMARRER=0   # positionnées par pg_ecrire_configuration
PG_A_RECHARGER=0

# --- Exécuter du SQL ---------------------------------------------------------------
# pg_sql ARGS... : psql en tant que postgres, par le socket local (« peer »).
# -X ignore ~/.psqlrc ; ON_ERROR_STOP arrête à la première erreur.
pg_sql() { runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -p "$PG_PORT" "$@"; }

# pg_valeur REQUETE [ARGS...] : une seule valeur, sans en-tête ni alignement.
pg_valeur() { local requete=$1; shift; pg_sql -At "$@" -c "$requete"; }

# pg_en_reprise : vrai si ce nœud est une réplique (il rejoue les journaux d'un primaire).
pg_en_reprise() { [[ $(pg_valeur "SELECT pg_is_in_recovery()") == t ]]; }

# --- Configuration (fichiers engendrés depuis config/noeuds.yml) ----------------------
pg_engendrer_parametres() {
  cat <<'EOF'
# Engendré par scripts/lib_pg.sh : ne pas modifier à la main.
# Écoute sur toutes les interfaces ; pg_hba.conf décide qui peut se connecter.
listen_addresses = '*'
# Réplication en flux (valeurs de PostgreSQL 16, écrites pour être explicites).
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
# Un slot ne retient jamais plus de 1 Go de journaux pour une réplique absente.
max_slot_wal_keep_size = '1GB'
EOF
}

pg_engendrer_hba() {
  local noeuds
  noeuds=$(lister_noeuds)
  cat <<'EOF'
# Engendré par scripts/lib_pg.sh depuis config/noeuds.yml : ne pas modifier à la main.
# TYPE  BASE         UTILISATEUR    ADRESSE             MÉTHODE
local   all          postgres                           peer
local   all          all                                peer
host    all          all            127.0.0.1/32        scram-sha-256
host    all          all            ::1/128             scram-sha-256
EOF
  echo "# Serveurs applicatifs : base $PG_BASE seulement, par le réseau privé (R8)"
  awk -v base="$PG_BASE" -v role="$PG_ROLE_APP" '$3 == "app" {
    printf "host    %-12s %-14s %-19s scram-sha-256\n", base, role, $2 "/32" }' <<<"$noeuds"
  echo "# Nœuds de base : réplication dans les deux sens (une réplique peut devenir"
  echo "# primaire), et lecture de l'état d'un pair (primaire ou réplique ?) par la base postgres"
  awk -v role="$PG_ROLE_REPLI" '$3 == "bdd" || $3 == "replique" {
    printf "host    %-12s %-14s %-19s scram-sha-256\n", "replication", role, $2 "/32"
    printf "host    %-12s %-14s %-19s scram-sha-256\n", "postgres", role, $2 "/32" }' <<<"$noeuds"
}

# pg_ecrire_configuration : paramètres, règles d'accès, mot de passe de réplication,
# démarrage manuel. Positionne PG_A_REDEMARRER (paramètres) et PG_A_RECHARGER (accès).
pg_ecrire_configuration() {
  ecrire_fichier "$PG_CONF/conf.d/resultats.conf" 0644 postgres:postgres < <(pg_engendrer_parametres)
  if (( FICHIER_MODIFIE )); then PG_A_REDEMARRER=1; fi
  ecrire_fichier "$PG_CONF/pg_hba.conf" 0640 postgres:postgres < <(pg_engendrer_hba)
  if (( FICHIER_MODIFIE )); then PG_A_RECHARGER=1; fi
  # ~postgres/.pgpass : lu par pg_basebackup et par le flux de réplication (0600 exigé).
  ecrire_fichier /var/lib/postgresql/.pgpass 0600 postgres:postgres \
    <<<"*:*:*:$PG_ROLE_REPLI:$PG_REPLICATION_MDP"
  # Démarrage manuel (étape 5) : PostgreSQL ne démarre plus seul quand la VM
  # démarre. C'est le provisionnement, rejoué à chaque vagrant up, qui le lance
  # APRÈS avoir vérifié que ce nœud n'est pas isolé : une ancienne primaire
  # rallumée ne peut donc jamais revenir en primaire (deux primaires = split-brain).
  ecrire_fichier "$PG_CONF/start.conf" 0644 postgres:postgres <<'EOF'
# Engendré par scripts/lib_pg.sh : démarré par le provisionnement, pas au démarrage.
manual
EOF
  if (( FICHIER_MODIFIE )); then action systemctl daemon-reload; fi
}

# --- Rôle des nœuds (étape 5) -------------------------------------------------------------
# pg_noeuds : « nom ip role » des machines de base (primaire nominale et répliques).
pg_noeuds() { lister_noeuds | awk '$3 == "bdd" || $3 == "replique"'; }

# pg_noeud_isole : vrai si scripts/bascule.sh a isolé ce nœud (ancienne primaire).
# Le témoin vit côté hôte, dans le dépôt : il survit à l'extinction de la VM.
pg_noeud_isole() { [[ -f $DEPOT/.etat/isole-$NOM_MACHINE ]]; }

# pg_role_distant IP : « primaire » ou « replique » selon le nœud IP ; rien s'il ne répond pas.
pg_role_distant() {
  local r
  r=$(PGPASSWORD=$PG_REPLICATION_MDP PGCONNECT_TIMEOUT=3 psql -X -At -w -h "$1" -p "$PG_PORT" \
        -U "$PG_ROLE_REPLI" -d postgres -c "SELECT pg_is_in_recovery()" 2>/dev/null) || return 0
  case $r in
    f) echo primaire ;;
    t) echo replique ;;
  esac
}

# pg_pair_de_role ROLE : adresse du premier AUTRE nœud de base dans ce rôle.
pg_pair_de_role() {
  local nom ip
  while read -r nom ip _; do
    [[ $nom == "$NOM_MACHINE" ]] && continue
    if [[ $(pg_role_distant "$ip") == "$1" ]]; then echo "$ip"; return 0; fi
  done < <(pg_noeuds)
}

# pg_verifier_primaire_unique : appelée AVANT de démarrer un nœud qui serait
# primaire. Refuse si un autre nœud accepte déjà les écritures : deux primaires
# recevraient chacune leurs écritures et divergeraient (« split-brain »).
pg_verifier_primaire_unique() {
  local ip autre
  ip=$(pg_pair_de_role primaire)
  [[ -z $ip ]] && return 0
  autre=$(lister_noeuds | awk -v ip="$ip" '$2 == ip { print $1 }')
  if systemctl is-active --quiet "$PG_SERVICE"; then
    erreur "DEUX PRIMAIRES : $NOM_MACHINE et $autre acceptent les écritures. Arrêtez PostgreSQL sur celle dont les données sont à abandonner, puis réintégrez-la depuis l'hôte : bash scripts/reintegrer.sh <nom>."
  fi
  erreur "$autre est déjà primaire : $NOM_MACHINE ne démarre PAS en primaire (les deux divergeraient). Pour en faire sa réplique, depuis l'hôte : bash scripts/reintegrer.sh $NOM_MACHINE"
}

# --- Service ----------------------------------------------------------------------------
# pg_assurer_cluster : le paquet crée normalement le cluster 16/main ; sinon on le crée.
pg_assurer_cluster() {
  if [[ ! -f $PG_CONF/postgresql.conf ]]; then
    action pg_createcluster "$PG_VERSION" "$PG_CLUSTER"
  fi
}

# pg_attendre_pret [DELAI_S] : attend que PostgreSQL accepte les connexions locales.
pg_attendre_pret() {
  local delai=${1:-60} debut=$SECONDS
  until pg_isready -q -h "$PG_SOCKET" -p "$PG_PORT"; do
    (( SECONDS - debut < delai )) \
      || erreur "PostgreSQL ne répond pas après $delai s (voir /var/log/postgresql/postgresql-$PG_VERSION-$PG_CLUSTER.log)."
    sleep 1
  done
}

# pg_assurer_demarre : démarre, redémarre ou recharge seulement si nécessaire.
pg_assurer_demarre() {
  if ! systemctl is-active --quiet "$PG_SERVICE"; then
    action systemctl start "$PG_SERVICE"
  elif (( PG_A_REDEMARRER )); then
    action systemctl restart "$PG_SERVICE"
  elif (( PG_A_RECHARGER )); then
    action systemctl reload "$PG_SERVICE"
  fi
  PG_A_REDEMARRER=0
  PG_A_RECHARGER=0
  pg_attendre_pret
}

# --- Primaire : rôles, base, schéma, données ----------------------------------------------
# pg_assurer_role ROLE ATTRIBUTS VARIABLE_MDP : crée le rôle s'il manque, et ne
# change son mot de passe que s'il ne correspond plus à .env (rejeu sans effet).
pg_assurer_role() {
  local role=$1 attributs=$2 variable=$3
  if [[ $(pg_valeur "SELECT count(*) FROM pg_roles WHERE rolname = '$role'") == 0 ]]; then
    action pg_sql -c "CREATE ROLE $role WITH $attributs"
  fi
  if ! PGPASSWORD=${!variable} PGCONNECT_TIMEOUT=5 psql -X -q -w -h 127.0.0.1 -p "$PG_PORT" \
         -U "$role" -d postgres -c 'SELECT 1' >/dev/null 2>&1; then
    # Le mot de passe passe par l'environnement (\getenv), jamais par la ligne de commande.
    log "ACTION mot de passe du rôle $role aligné sur .env"
    MDP_A_APPLIQUER=${!variable} runuser -u postgres -w MDP_A_APPLIQUER -- \
      psql -X -q -v ON_ERROR_STOP=1 -p "$PG_PORT" -v role="$role" <<'SQL'
\getenv mdp MDP_A_APPLIQUER
ALTER ROLE :"role" WITH PASSWORD :'mdp';
SQL
  fi
}

pg_initialiser_primaire() {
  pg_assurer_role "$PG_ROLE_REPLI" "LOGIN REPLICATION" PG_REPLICATION_MDP
  pg_assurer_role "$PG_ROLE_APP" "LOGIN" PG_APP_MDP
  if [[ $(pg_valeur "SELECT count(*) FROM pg_database WHERE datname = '$PG_BASE'") == 0 ]]; then
    action pg_sql -c "CREATE DATABASE $PG_BASE ENCODING 'UTF8' LOCALE 'C.UTF-8' TEMPLATE template0"
  fi
  # Schéma et données : fichiers SQL idempotents, lus par root et transmis à psql.
  pg_sql -d "$PG_BASE" <"$DEPOT/sql/schema.sql"
  local inserees
  inserees=$(pg_sql -At -d "$PG_BASE" <"$DEPOT/sql/donnees.sql")
  if (( inserees > 0 )); then
    log "MODIF  base $PG_BASE : $inserees lignes insérées dans resultats"
  fi
  log "base $PG_BASE : $(pg_valeur "SELECT count(*) FROM resultats" -d "$PG_BASE") lignes dans resultats"
}

# --- Réplique : clonage et état du flux ----------------------------------------------------
# pg_cloner_depuis IP [SUFFIXE] : remplace le cluster local par une copie du
# primaire IP et le démarre en réplique (fichier standby.signal). Les anciennes
# données sont mises de côté dans $PG_DATA.SUFFIXE, jamais effacées en silence.
pg_cloner_depuis() {
  local primaire=$1 suffixe=${2:-avant-clonage} slot="slot_$NOM_MACHINE"
  attendre_port "$primaire" "$PG_PORT" 600
  log "clonage du primaire $primaire vers $NOM_MACHINE (pg_basebackup)…"
  if systemctl is-active --quiet "$PG_SERVICE"; then
    action systemctl stop "$PG_SERVICE"
  fi
  if [[ -d $PG_DATA ]]; then
    rm -rf "${PG_DATA:?}.$suffixe"
    action mv "$PG_DATA" "$PG_DATA.$suffixe"
  fi
  install -d -o postgres -g postgres -m 0700 "$PG_DATA"
  # Slot de réplication : le primaire garde les journaux tant que ce nœud ne les a pas reçus.
  runuser -u postgres -- pg_receivewal -h "$primaire" -p "$PG_PORT" -U "$PG_ROLE_REPLI" -w \
    --slot="$slot" --create-slot --if-not-exists
  # -R écrit standby.signal et primary_conninfo : le nœud démarrera en réplique.
  action runuser -u postgres -- pg_basebackup -w -D "$PG_DATA" \
    -d "host=$primaire port=$PG_PORT user=$PG_ROLE_REPLI application_name=$NOM_MACHINE" \
    --wal-method=stream --checkpoint=fast --write-recovery-conf --slot="$slot"
  action systemctl start "$PG_SERVICE"
  PG_A_REDEMARRER=0   # le démarrage a pris la configuration actuelle
  PG_A_RECHARGER=0
  pg_attendre_pret 120
}

# pg_attendre_flux : sur une réplique, attend (30 s au plus) que le flux soit établi.
pg_attendre_flux() {
  local debut=$SECONDS
  until [[ $(pg_valeur "SELECT status FROM pg_stat_wal_receiver") == streaming ]]; do
    if (( SECONDS - debut >= 30 )); then
      log "ATTENTION : flux de réplication non établi après 30 s (le primaire est-il démarré ?)"
      return 0
    fi
    sleep 1
  done
}

pg_journaliser_reception() {
  log "réplique : flux $(pg_valeur "SELECT coalesce((SELECT status || ' depuis ' || sender_host FROM pg_stat_wal_receiver), 'non établi')")"
}

pg_journaliser_replication() {
  local lignes ligne
  lignes=$(pg_valeur "SELECT application_name || ' (' || host(client_addr) || ') ' || state || ', ' || sync_state FROM pg_stat_replication")
  if [[ -z $lignes ]]; then
    log "primaire : aucune réplique connectée pour l'instant"
  else
    while IFS= read -r ligne; do log "primaire : réplique $ligne"; done <<<"$lignes"
  fi
}

# --- Point d'entrée --------------------------------------------------------------------------
# pg_provisionner primaire|replique [--reintegrer] : appelé par bdd.sh et replique.sh.
# Le rôle NOMINAL (bdd1 primaire, bdd2 réplique) ne décide que d'une chose :
# ce que fait un nœud neuf quand aucune autre base n'est primaire. Après une
# bascule, c'est l'état réel de chaque nœud qui compte.
pg_provisionner() {
  local role=$1 mode=${2:-} primaire nominale
  charger_secrets
  install -d -m 0755 "$ETAT_LOCAL"
  pg_assurer_cluster
  pg_ecrire_configuration

  if [[ $mode == --reintegrer ]]; then
    # Réintégration demandée par scripts/reintegrer.sh : on rejoint le primaire actuel.
    primaire=$(pg_pair_de_role primaire)
    [[ -n $primaire ]] || erreur "aucun autre nœud n'est primaire : rien à rejoindre."
    pg_cloner_depuis "$primaire" "avant-reintegration-$(date +%Y%m%d-%H%M%S)"
  elif pg_noeud_isole; then
    # Ancienne primaire isolée par la bascule : elle reste arrêtée.
    if systemctl is-active --quiet "$PG_SERVICE"; then action systemctl stop "$PG_SERVICE"; fi
    log "ISOLÉ : $NOM_MACHINE a été remplacée par une bascule ; PostgreSQL reste arrêté."
    log "        Pour la réintégrer comme réplique, depuis l'hôte : bash scripts/reintegrer.sh $NOM_MACHINE"
    return 0
  elif [[ ! -f $MARQUEUR_PG ]]; then
    # Nœud neuf : s'il existe déjà un primaire, ce nœud devient sa réplique.
    primaire=$(pg_pair_de_role primaire)
    if [[ -n $primaire ]]; then
      pg_cloner_depuis "$primaire"
    elif [[ $role == replique ]]; then
      nominale=$(lister_noeuds bdd | awk 'NR == 1 { print $1 }')
      if [[ -f $DEPOT/.etat/isole-$nominale ]]; then
        erreur "aucune base primaire joignable, et $nominale est isolée depuis une bascule. Si vous acceptez de perdre les écritures faites depuis cette bascule : rm .etat/isole-$nominale puis vagrant provision $nominale."
      fi
      pg_cloner_depuis "$(ip_de "$nominale")"   # attend que la primaire nominale réponde
    elif [[ -n $(pg_pair_de_role replique) ]]; then
      # Le cluster vide démarré par l'installation du paquet est arrêté : seule
      # la réplique, qui a les données, doit pouvoir devenir primaire.
      if systemctl is-active --quiet "$PG_SERVICE"; then action systemctl stop "$PG_SERVICE"; fi
      erreur "une autre base est une réplique sans primaire : promouvez-la d'abord, puis rattachez $NOM_MACHINE, depuis l'hôte : bash scripts/bascule.sh puis bash scripts/reintegrer.sh $NOM_MACHINE"
    fi
  fi

  # Sans standby.signal, PostgreSQL démarrerait en PRIMAIRE : on vérifie d'abord
  # qu'aucun autre nœud ne l'est (ancienne primaire rallumée après une bascule…).
  if [[ ! -f $PG_DATA/standby.signal ]]; then pg_verifier_primaire_unique; fi
  pg_assurer_demarre
  if pg_en_reprise; then
    pg_attendre_flux
    pg_journaliser_reception
  else
    pg_initialiser_primaire
    pg_journaliser_replication
  fi
  [[ -f $MARQUEUR_PG ]] || action touch "$MARQUEUR_PG"
}

#!/usr/bin/env bash
# =============================================================================
# scripts/pg_outil.sh — opérations d'exploitation PostgreSQL, DANS une VM de base
# =============================================================================
# Appelé depuis l'hôte par scripts/bascule.sh (vagrant ssh), ou à la main :
#   sudo bash /vagrant/scripts/pg_outil.sh etat [IP...]
#     état de ce nœud, en lignes « cle=valeur » ; avec des IP : rôle de ces
#     nœuds vus d'ici, par le réseau privé (celui qu'utilisent les applications)
#   sudo bash /vagrant/scripts/pg_outil.sh arreter
#     arrête PostgreSQL (isolement d'une ancienne primaire)
#   sudo bash /vagrant/scripts/pg_outil.sh promouvoir
#     promeut cette réplique en primaire (pg_promote) et vérifie le résultat
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "${DEPOT:-/vagrant}/scripts/lib.sh"
# shellcheck source=scripts/lib_pg.sh
source "$DEPOT/scripts/lib_pg.sh"

(( EUID == 0 )) || erreur "à lancer avec sudo."
pg_demarre() { systemctl is-active --quiet "$PG_SERVICE" && pg_isready -q -h "$PG_SOCKET" -p "$PG_PORT"; }

commande=${1:-}
shift || true
case $commande in
  etat)
    echo "machine=$NOM_MACHINE"
    if pg_demarre; then
      if pg_en_reprise; then echo "role=replique"; else echo "role=primaire"; fi
      # Positions dans le journal (LSN) : ce qui a été reçu et rejoué par une
      # réplique, ou la position courante d'une primaire.
      pg_valeur "SELECT ligne FROM (VALUES
          ('flux=' || coalesce((SELECT status FROM pg_stat_wal_receiver), 'aucun')),
          ('recu=' || coalesce(pg_last_wal_receive_lsn()::text, '-')),
          ('rejoue=' || coalesce(pg_last_wal_replay_lsn()::text, '-')),
          ('derniere_transaction=' || coalesce(pg_last_xact_replay_timestamp()::timestamptz(0)::text, '-')),
          ('position=' || CASE WHEN pg_is_in_recovery() THEN '-' ELSE pg_current_wal_lsn()::text END)
        ) AS t (ligne)"
    else
      echo "role=arrete"
    fi
    if pg_noeud_isole; then echo "isole=oui"; else echo "isole=non"; fi
    charger_secrets
    for ip in "$@"; do
      role=$(pg_role_distant "$ip")
      echo "pair_$ip=${role:-injoignable}"
    done
    ;;
  arreter)
    if systemctl is-active --quiet "$PG_SERVICE"; then action systemctl stop "$PG_SERVICE"; fi
    if systemctl is-active --quiet "$PG_SERVICE"; then erreur "PostgreSQL tourne encore sur $NOM_MACHINE."; fi
    log "PostgreSQL arrêté sur $NOM_MACHINE (il ne redémarrera pas seul : start.conf = manual)."
    ;;
  promouvoir)
    pg_demarre || erreur "PostgreSQL est arrêté sur $NOM_MACHINE : rien à promouvoir."
    if ! pg_en_reprise; then
      log "$NOM_MACHINE est déjà primaire : rien à faire."
      exit 0
    fi
    # pg_promote(true, 60) : rejoue la fin des journaux reçus, quitte le mode
    # réplique, puis attend (60 s au plus) que la base accepte les écritures.
    [[ $(pg_valeur "SELECT pg_promote(true, 60)") == t ]] \
      || erreur "promotion non terminée après 60 s (voir /var/log/postgresql/postgresql-$PG_VERSION-$PG_CLUSTER.log)."
    if pg_en_reprise; then erreur "$NOM_MACHINE est encore en réplique après pg_promote."; fi
    log "ACTION $NOM_MACHINE promue primaire (accepte les écritures)."
    ;;
  *)
    erreur "usage : sudo bash /vagrant/scripts/pg_outil.sh etat [IP...] | arreter | promouvoir"
    ;;
esac

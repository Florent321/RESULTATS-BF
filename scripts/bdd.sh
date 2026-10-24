#!/usr/bin/env bash
# =============================================================================
# scripts/bdd.sh — rôle « bdd » : bdd1, PostgreSQL primaire (étape 2)
# =============================================================================
# Lancé après commun.sh, qui a déjà installé le paquet postgresql.
# Configure le cluster, crée les rôles, la base resultats et ses 50 000 lignes.
# Rejoué à chaque vagrant up : idempotent (R2).
# Étape 5 : si une autre base est déjà primaire (après une bascule), bdd1 ne
# démarre pas en primaire ; « --reintegrer » (scripts/reintegrer.sh) en fait
# une réplique. Toute la logique est dans pg_provisionner (lib_pg.sh).
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "${DEPOT:-/vagrant}/scripts/lib.sh"
# shellcheck source=scripts/lib_pg.sh
source "$DEPOT/scripts/lib_pg.sh"

pg_provisionner primaire "$@"

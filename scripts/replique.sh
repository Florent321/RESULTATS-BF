#!/usr/bin/env bash
# =============================================================================
# scripts/replique.sh — rôle « replique » : bdd2, réplique en flux de bdd1 (étape 2)
# =============================================================================
# Au premier passage : copie bdd1 avec pg_basebackup, puis démarre en réplique.
# Aux passages suivants : vérifie seulement que le flux est établi (R2).
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "${DEPOT:-/vagrant}/scripts/lib.sh"
# shellcheck source=scripts/lib_pg.sh
source "$DEPOT/scripts/lib_pg.sh"

pg_provisionner replique

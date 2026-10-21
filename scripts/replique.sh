#!/usr/bin/env bash
# =============================================================================
# scripts/replique.sh — rôle « replique » : bdd2, réplique en flux de bdd1
# =============================================================================
# Étape 1 : vide. Complété à l'étape 2 par M3 (ingénieur données).
# Lancé après commun.sh, qui a déjà installé les paquets et /etc/hosts.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "${DEPOT:-/vagrant}/scripts/lib.sh"

log "rôle replique : rien à faire à l'étape 1 (la réplication arrive à l'étape 2)."

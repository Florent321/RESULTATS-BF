#!/usr/bin/env bash
# =============================================================================
# scripts/bdd.sh — rôle « bdd » : bdd1, PostgreSQL primaire
# =============================================================================
# Étape 1 : vide. Complété à l'étape 2 par M3 (ingénieur données).
# Lancé après commun.sh, qui a déjà installé les paquets et /etc/hosts.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "${DEPOT:-/vagrant}/scripts/lib.sh"

log "rôle bdd : rien à faire à l'étape 1 (PostgreSQL arrive à l'étape 2)."

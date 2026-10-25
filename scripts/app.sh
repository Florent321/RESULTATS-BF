#!/usr/bin/env bash
# =============================================================================
# scripts/app.sh — rôle « app » : app1 à appN, serveurs applicatifs sans état
# =============================================================================
# Étape 1 : vide. Complété à l'étape 3 par M2 (ingénieur applicatif).
# Lancé après commun.sh, qui a déjà installé les paquets et /etc/hosts.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "${DEPOT:-/vagrant}/scripts/lib.sh"

log "rôle app : rien à faire à l'étape 1 (l'application arrive à l'étape 3)."

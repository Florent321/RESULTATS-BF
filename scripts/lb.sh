#!/usr/bin/env bash
# =============================================================================
# scripts/lb.sh — rôle « lb » : lb1, répartiteur HAProxy
# =============================================================================
# Étape 1 : vide. Complété à l'étape 4 par M1 (architecte réseau).
# Rejoué à CHAQUE vagrant up (run: "always" dans le Vagrantfile) : c'est ici
# que la configuration HAProxy sera engendrée depuis noeuds.yml (R3).
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "${DEPOT:-/vagrant}/scripts/lib.sh"

log "rôle lb : rien à faire à l'étape 1 (HAProxy arrive à l'étape 4)."
log "serveurs applicatifs déclarés : $(lister_noeuds app | awk '{ printf "%s ", $1 }')"

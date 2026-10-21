#!/usr/bin/env bash
# =============================================================================
# scripts/commun.sh — provisionnement commun à TOUTES les machines
# =============================================================================
# Appelé par le Vagrantfile avec le rôle en argument, à CHAQUE vagrant up
# (run: "always") : il doit donc rester strictement idempotent (R2).
# =============================================================================
set -Eeuo pipefail

LIB="${DEPOT:-/vagrant}/scripts/lib.sh"
if [[ ! -r $LIB ]]; then
  echo "ERREUR : $LIB illisible : /vagrant n'est pas monté (Additions invité VirtualBox ?)." >&2
  exit 1
fi
# shellcheck source=scripts/lib.sh
source "$LIB"

ROLE=${1:?usage : commun.sh ROLE (bdd, replique, app ou lb)}

# 1. Pas de mises à jour automatiques : ni téléchargement caché, ni verrou apt.
desactiver_maj_auto

# 2. Un seul apt-get pour tous les paquets de la machine (base + rôle).
LISTE=$(paquets_du_role "$ROLE")
read -ra PAQUETS <<<"$LISTE"
installer_paquets "${PAQUETS[@]}"

# 3. La machine doit être active dans la source de vérité, avec ce rôle.
verifier_declaration "$ROLE"

# 4. Résolution des noms : bloc /etc/hosts engendré depuis noeuds.yml.
mettre_a_jour_hosts

log "socle commun prêt (rôle $ROLE)."

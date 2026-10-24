#!/usr/bin/env bash
# =============================================================================
# tests/noeud.sh — contrôles lancés DANS une VM par tests/verifier_socle.sh
# =============================================================================
# Pour chaque autre machine active : son nom se résout-il en son adresse
# privée, et répond-elle au ping ? Affiche aussi l'empreinte de /etc/hosts.
# Sortie : lignes « OK ... », « ECHEC ... », « EMPREINTE <machine> <hash> ».
# =============================================================================
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "${DEPOT:-/vagrant}/scripts/lib.sh"

# shellcheck disable=SC2119  # sans argument : toutes les machines
if ! noeuds=$(lister_noeuds); then
  echo "ECHEC $NOM_MACHINE : config/noeuds.yml illisible"
  exit 1
fi

# joignable NOM : ping si disponible, sinon tentative TCP sur le port 22. Une
# connexion acceptée OU refusée prouve que la machine répond ; seul le silence
# (délai dépassé, code 124) signifie qu'elle est injoignable.
joignable() {
  if command -v ping >/dev/null 2>&1; then
    ping -c 1 -W 2 "$1" >/dev/null 2>&1
  else
    timeout 2 bash -c "exec 3<>/dev/tcp/$1/22" 2>/dev/null
    (( $? != 124 ))
  fi
}

ko=0
while read -r nom ip _; do
  [[ $nom == "$NOM_MACHINE" ]] && continue
  resolu=$(getent hosts "$nom" | awk '{ print $1; exit }')
  if [[ $resolu != "$ip" ]]; then
    echo "ECHEC $NOM_MACHINE -> $nom : résolu en « ${resolu:-rien} », attendu $ip"
    ko=$((ko + 1))
  elif ! joignable "$nom"; then
    echo "ECHEC $NOM_MACHINE -> $nom ($ip) : machine injoignable sur le réseau privé"
    ko=$((ko + 1))
  else
    echo "OK $NOM_MACHINE -> $nom ($ip)"
  fi
done <<<"$noeuds"

blocs=$(grep -c "^# >>> RESULTATS-BF" "$FICHIER_HOSTS")
if [[ $blocs == 1 ]]; then
  echo "OK $NOM_MACHINE : un seul bloc RESULTATS-BF dans /etc/hosts"
else
  echo "ECHEC $NOM_MACHINE : $blocs bloc(s) RESULTATS-BF dans /etc/hosts, 1 attendu"
  ko=$((ko + 1))
fi

echo "EMPREINTE $NOM_MACHINE $(sha256sum "$FICHIER_HOSTS" | cut -c1-16)"
exit $(( ko > 0 ))

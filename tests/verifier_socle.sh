#!/usr/bin/env bash
# =============================================================================
# tests/verifier_socle.sh — contrôle de l'étape 1, lancé depuis l'HÔTE
# =============================================================================
# Usage (Git Bash, à la racine du dépôt, socle démarré par vagrant up) :
#   mkdir -p docs/preuves
#   bash tests/verifier_socle.sh 2>&1 | tee "docs/preuves/etape1-$(hostname).txt"
# Durée : 3 à 6 minutes (deux provisionnements complets). Ne modifie aucune VM.
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# Pas de vérification de version de Vagrant avant chaque commande (jusqu'à 10 s).
export VAGRANT_CHECKPOINT_DISABLE=1

ECHECS=0
ok()    { echo "OK     $*"; }
echec() { echo "ECHEC  $*"; ECHECS=$((ECHECS + 1)); }
titre() { printf '\n== %s ==\n' "$*"; }

echo "Socle RÉSULTATS-BF : $(date '+%Y-%m-%d %H:%M:%S')," \
     "commit $(git rev-parse --short HEAD 2>/dev/null || echo inconnu)," \
     "NB_APP=${NB_APP:-2 (défaut)}"

# --- 1 -----------------------------------------------------------------------
titre "1. Machines démarrées (d'après Vagrant)"
mapfile -t ACTIVES < <(vagrant status --machine-readable 2>/dev/null | tr -d '\r' \
  | awk -F, '$3 == "state" && $4 == "running" { print $2 }')
ATTENDUES=$(grep -c '^- nom: ' config/noeuds.yml)
if (( ${#ACTIVES[@]} >= ATTENDUES )); then
  ok "${#ACTIVES[@]} machines démarrées : ${ACTIVES[*]}"
else
  echec "${#ACTIVES[@]} machine(s) démarrée(s), $ATTENDUES attendues : ${ACTIVES[*]:-aucune}"
fi

# --- 2 -----------------------------------------------------------------------
titre "2. Noms et réseau privé, vus de chaque machine"
declare -A EMPREINTE=()
for m in "${ACTIVES[@]}"; do
  sortie=$(vagrant ssh "$m" --no-tty -c "bash /vagrant/tests/noeud.sh" -- -q </dev/null 2>/dev/null | tr -d '\r')
  while IFS= read -r ligne; do
    case $ligne in
      "OK "*)        ok "${ligne#OK }" ;;
      "ECHEC "*)     echec "${ligne#ECHEC }" ;;
      "EMPREINTE "*) read -r _ nom empreinte <<<"$ligne"; EMPREINTE[$nom]=$empreinte ;;
    esac
  done <<<"$sortie"
  [[ -n ${EMPREINTE[$m]:-} ]] || echec "$m : contrôle impossible (vagrant ssh a échoué)"
done

# --- 3 -----------------------------------------------------------------------
titre "3. Idempotence (R2) : deux provisionnements de suite"
JOURNAUX=$(mktemp -d)
for passe in 1 2; do
  journal="$JOURNAUX/passe$passe.log"
  if vagrant provision >"$journal" 2>&1; then
    modifs=$(tr -d '\r' <"$journal" | grep -cE "(MODIF|ACTION) ")
    if (( modifs == 0 )); then
      ok "passe $passe : réussie, aucune modification ni action"
    else
      echec "passe $passe : $modifs modification(s) ou action(s) :"
      tr -d '\r' <"$journal" | grep -E "(MODIF|ACTION) " | sed 's/^/         /'
    fi
  else
    echec "passe $passe : vagrant provision a échoué (journal : $journal)"
  fi
done

# --- 4 -----------------------------------------------------------------------
titre "4. Empreinte de /etc/hosts inchangée après les deux passes"
for m in "${ACTIVES[@]}"; do
  apres=$(vagrant ssh "$m" --no-tty -c "sha256sum /etc/hosts | cut -c1-16" -- -q </dev/null 2>/dev/null | tr -d '\r')
  avant=${EMPREINTE[$m]:-?}
  if [[ $apres == "$avant" ]]; then
    ok "$m : $apres"
  else
    echec "$m : empreinte $avant devenue ${apres:-?}"
  fi
done

# --- 5 -----------------------------------------------------------------------
titre "5. Paramètres NB_APP et GROUPE (R3) et garde-fous"
compter_apps() { grep -c "role: app" config/noeuds.yml; }
# Plage de l'énoncé (§7.1) : groupes 1 à 8, 192.168.56.0 à 192.168.63.255. Au-delà,
# seul VirtualBox sous Windows accepte le réseau : signalé, sans compter comme échec.
reseau_groupe=$(awk '/^reseau: / { print $2 }' config/noeuds.yml)
case $reseau_groupe in
  192.168.5[6-9].0/24 | 192.168.6[0-3].0/24)
    ok "réseau $reseau_groupe dans la plage de l'énoncé (192.168.56.0/21)" ;;
  *)
    echo "ATTENTION  réseau $reseau_groupe hors de la plage de l'énoncé (192.168.56.0/21) :" \
         "accepté par VirtualBox sous Windows seulement ; à faire valider par l'enseignant" ;;
esac
if NB_APP=12 vagrant status >/dev/null 2>&1; then
  echec "NB_APP=12 accepté"
else
  ok "NB_APP=12 refusé (au-delà de 9 : collision d'adresses avec bdd1)"
fi
if GROUPE=21 vagrant status >/dev/null 2>&1; then
  echec "GROUPE=21 accepté"
else
  ok "GROUPE=21 refusé (groupes 1 à 20)"
fi
NB_APP=4 vagrant status >/dev/null 2>&1
avec4=$(compter_apps)
env -u NB_APP vagrant status >/dev/null 2>&1
defaut=$(compter_apps)
vagrant status >/dev/null 2>&1   # remet noeuds.yml dans l'état de cette session
if [[ $avec4 == 4 && $defaut == 2 ]]; then
  ok "noeuds.yml suit NB_APP : 4 serveurs avec NB_APP=4, 2 par défaut"
else
  echec "noeuds.yml ne suit pas NB_APP : $avec4 avec NB_APP=4, $defaut par défaut"
fi

# --- 6 -----------------------------------------------------------------------
titre "6. Exposition (R8) et secrets (R7)"
n=$(grep -c '"forwarded_port"' Vagrantfile)
if (( n == 1 )); then
  ok "un seul forwarded_port dans le Vagrantfile"
else
  echec "$n forwarded_port dans le Vagrantfile, 1 attendu"
fi
if git check-ignore -q .env; then
  ok ".env est ignoré par Git"
else
  echec ".env n'est PAS ignoré par Git"
fi
if [[ -z $(git log --all --format=%h -- .env 2>/dev/null) ]]; then
  ok ".env n'apparaît dans aucun commit"
else
  echec ".env apparaît dans l'historique : changez les mots de passe, réécrivez l'historique"
fi
valeurs=$(mktemp)
grep -E '^[A-Z_][A-Z0-9_]*=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r' | grep -v '^$' >"$valeurs"
# grep -c lit tout le flux : grep -q s'arrêterait au premier résultat, git log
# recevrait SIGPIPE et, avec pipefail, la fuite passerait inaperçue.
if [[ -s $valeurs ]] && (( $(git log --all -p 2>/dev/null | grep -cF -f "$valeurs") > 0 )); then
  echec "une valeur de .env apparaît dans l'historique Git (ou vaut encore a_remplacer)"
else
  ok "aucune valeur de .env dans l'historique Git"
fi
rm -f "$valeurs"

# --- Bilan -----------------------------------------------------------------------
titre "Bilan"
if (( ECHECS == 0 )); then
  echo "ÉTAPE 1 VALIDÉE : aucun échec."
else
  echo "ÉTAPE 1 NON VALIDÉE : $ECHECS échec(s), voir ci-dessus."
fi
exit $(( ECHECS > 0 ))

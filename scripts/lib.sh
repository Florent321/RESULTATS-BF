# shellcheck shell=bash
# Bibliothèque : FICHIER_MODIFIE est lue par les scripts appelants (SC2034) et
# le rôle de lister_noeuds est un argument facultatif (SC2119, SC2120).
# shellcheck disable=SC2034,SC2119,SC2120
# =============================================================================
# scripts/lib.sh — bibliothèque commune de RÉSULTATS-BF
# =============================================================================
# À SOURCER par les scripts de provisionnement, jamais à exécuter seule.
# Règle d'or : chaque fonction est idempotente. La rejouer ne change rien
# quand l'état voulu est déjà atteint (exigence R2).
#
# Les variables ci-dessous ont une valeur par défaut pour les VM ; elles ne
# sont surchargées que par les tests, hors VM.
# =============================================================================

DEPOT=${DEPOT:-/vagrant}                          # le dépôt, vu depuis la VM
FICHIER_NOEUDS=${FICHIER_NOEUDS:-$DEPOT/config/noeuds.yml}
FICHIER_SECRETS=${FICHIER_SECRETS:-$DEPOT/.env}
FICHIER_HOSTS=${FICHIER_HOSTS:-/etc/hosts}
NOM_MACHINE=${NOM_MACHINE:-$(hostname -s)}

FICHIER_MODIFIE=0   # mis à 1 par ecrire_fichier quand le contenu a changé

BALISE_DEBUT="# >>> RESULTATS-BF : bloc engendré depuis config/noeuds.yml, ne pas modifier"
BALISE_FIN="# <<< RESULTATS-BF"

# Paquets présents sur toutes les machines. python3-yaml sert à lire noeuds.yml.
PAQUETS_BASE=(python3-yaml curl)

# --- Messages ------------------------------------------------------------------
log()    { printf '[%s] %s\n' "$NOM_MACHINE" "$*"; }
erreur() { printf '[%s] ERREUR : %s\n' "$NOM_MACHINE" "$*" >&2; exit 1; }

# --- Fichiers --------------------------------------------------------------------
# ecrire_fichier CIBLE [MODE] [PROPRIETAIRE]   (contenu lu sur l'entrée standard)
# N'écrit que si le contenu diffère, et positionne FICHIER_MODIFIE (1 ou 0).
# Usage typique, pour ne recharger un service QUE si sa configuration change :
#   ecrire_fichier /etc/x.cfg 0644 < <(engendrer_config)
#   if (( FICHIER_MODIFIE )); then systemctl reload x; fi
ecrire_fichier() {
  local cible=$1 mode=${2:-0644} proprio=${3:-root:root} tmp
  tmp=$(mktemp)
  cat >"$tmp"
  if [[ -f $cible ]] && cmp -s "$tmp" "$cible"; then
    rm -f "$tmp"
    FICHIER_MODIFIE=0
    # Contenu identique : on rectifie seulement des droits qui auraient dérivé.
    [[ $(stat -c '%a' "$cible") == "${mode#0}" ]] || chmod "$mode" "$cible"
    [[ $(stat -c '%U:%G' "$cible") == "$proprio" ]] || chown "$proprio" "$cible"
    return 0
  fi
  install -D -m "$mode" -o "${proprio%%:*}" -g "${proprio##*:}" "$tmp" "$cible"
  rm -f "$tmp"
  FICHIER_MODIFIE=1
  log "MODIF  $cible"
}

# --- Paquets ---------------------------------------------------------------------
# paquets_du_role ROLE : paquets de base + paquets propres au rôle.
# Chaque membre ajoute ici les paquets de son rôle, à son étape : ainsi chaque
# machine ne fait qu'UN seul apt-get install (énoncé §7.2).
paquets_du_role() {
  local supplementaires
  case $1 in
    bdd | replique) supplementaires="" ;;   # étape 2 : postgresql
    app)            supplementaires="" ;;   # étape 3 : application Python
    lb)             supplementaires="" ;;   # étape 4 : haproxy
    *) erreur "rôle inconnu : $1 (attendu : bdd, replique, app ou lb)" ;;
  esac
  echo "${PAQUETS_BASE[*]} $supplementaires"
}

# installer_paquets PAQUET... : un seul apt-get pour tous les paquets absents.
# Si tout est déjà installé, aucun accès réseau : le rejeu est rapide (R2).
installer_paquets() {
  local manquants=() p
  for p in "$@"; do
    [[ $(dpkg-query -W -f='${Status}' "$p" 2>/dev/null) == "install ok installed" ]] \
      || manquants+=("$p")
  done
  if (( ${#manquants[@]} == 0 )); then
    log "paquets déjà présents : $*"
    return 0
  fi
  log "installation groupée : ${manquants[*]}"
  export DEBIAN_FRONTEND=noninteractive
  # DPkg::Lock::Timeout : attend (jusqu'à 5 min) qu'un autre apt libère le verrou.
  apt-get -o DPkg::Lock::Timeout=300 update -qq
  apt-get -o DPkg::Lock::Timeout=300 install -y -qq --no-install-recommends "${manquants[@]}"
}

# desactiver_maj_auto : coupe les mises à jour automatiques d'Ubuntu. Elles
# téléchargent en tâche de fond (connexion lente) et prennent le verrou apt
# pendant le provisionnement. Choix assumé pour un laboratoire, pas en production.
desactiver_maj_auto() {
  if [[ ! -d /run/systemd/system ]]; then
    log "systemd absent : mises à jour automatiques non traitées."
    return 0
  fi
  local unite
  for unite in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service; do
    if systemctl is-enabled --quiet "$unite" 2>/dev/null; then
      systemctl disable --now --quiet "$unite"
      log "désactivé : $unite"
    fi
  done
}

# --- Inventaire (source de vérité) --------------------------------------------------
# lister_noeuds [ROLE] : une ligne « nom ip role » par machine active, lue dans
# config/noeuds.yml (engendré par le Vagrantfile). Filtre optionnel par rôle.
lister_noeuds() {
  [[ -r $FICHIER_NOEUDS ]] \
    || erreur "$FICHIER_NOEUDS introuvable : lancez une commande vagrant depuis l'hôte."
  python3 - "$FICHIER_NOEUDS" "${1:-}" <<'PY'
import sys
import yaml

chemin, role = sys.argv[1], sys.argv[2]
with open(chemin, encoding="utf-8") as fichier:
    donnees = yaml.safe_load(fichier)
for noeud in donnees["noeuds"]:
    if role in ("", noeud["role"]):
        print(noeud["nom"], noeud["ip"], noeud["role"])
PY
}

# verifier_declaration ROLE : la machine doit être active dans noeuds.yml, avec
# ce rôle. Empêche de démarrer app5 « à la main » sans passer par NB_APP.
verifier_declaration() {
  local attendu=$1 noeuds role_lu
  noeuds=$(lister_noeuds)
  role_lu=$(awk -v h="$NOM_MACHINE" '$1 == h { print $3 }' <<<"$noeuds")
  [[ -n $role_lu ]] \
    || erreur "$NOM_MACHINE n'est pas active dans noeuds.yml : changez NB_APP (ex. NB_APP=4 vagrant up) au lieu de la démarrer à la main."
  [[ $role_lu == "$attendu" ]] \
    || erreur "$NOM_MACHINE est déclarée « $role_lu » dans noeuds.yml, pas « $attendu »."
  log "machine déclarée : $NOM_MACHINE ($role_lu)"
}

# mettre_a_jour_hosts : réécrit le bloc balisé de /etc/hosts depuis noeuds.yml.
# Le reste du fichier (lignes du système et de Vagrant) n'est pas touché.
mettre_a_jour_hosts() {
  local noeuds reste
  noeuds=$(lister_noeuds)
  reste=$(awk -v d="$BALISE_DEBUT" -v f="$BALISE_FIN" \
    '$0 == d { saute = 1; next } $0 == f { saute = 0; next } !saute' "$FICHIER_HOSTS")
  ecrire_fichier "$FICHIER_HOSTS" 0644 root:root < <(
    printf '%s\n' "$reste" "$BALISE_DEBUT"
    awk '{ printf "%-15s %s\n", $2, $1 }' <<<"$noeuds"
    printf '%s\n' "$BALISE_FIN"
  )
}

# --- Secrets (utilisés à partir de l'étape 2) ----------------------------------------
# charger_secrets : exporte les variables de .env. Fins de ligne Windows
# tolérées ; les valeurs ne sont jamais affichées (pas de set -x !).
charger_secrets() {
  [[ -r $FICHIER_SECRETS ]] \
    || erreur "$FICHIER_SECRETS introuvable : lancez une commande vagrant depuis l'hôte pour le créer."
  local ligne cle
  while IFS= read -r ligne || [[ -n $ligne ]]; do
    ligne=${ligne%$'\r'}
    [[ $ligne =~ ^[[:space:]]*(#|$) ]] && continue
    cle=${ligne%%=*}
    [[ $cle =~ ^[A-Z_][A-Z0-9_]*$ && $ligne == *=* ]] \
      || erreur "ligne invalide dans .env : « ${cle} »"
    export "$cle=${ligne#*=}"
  done <"$FICHIER_SECRETS"
}

# --- Attente d'un service (utilisée à partir de l'étape 2) ------------------------------
# attendre_port HOTE PORT [DELAI_S] : attend qu'un service accepte les
# connexions TCP, ou échoue avec un message clair après DELAI_S secondes.
attendre_port() {
  local hote=$1 port=$2 delai=${3:-120} debut=$SECONDS
  until timeout 2 bash -c "exec 3<>/dev/tcp/$hote/$port" 2>/dev/null; do
    if (( SECONDS - debut >= delai )); then
      erreur "$hote:$port injoignable après $delai s."
    fi
    sleep 2
  done
  log "$hote:$port joignable."
}

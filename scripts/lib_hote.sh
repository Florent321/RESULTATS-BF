# shellcheck shell=bash
# =============================================================================
# scripts/lib_hote.sh — fonctions des scripts lancés sur le POSTE HÔTE
# =============================================================================
# À sourcer par scripts/bascule.sh, tests/*.sh… Conçu pour Git Bash sous Windows
# (et Linux) : bash 4 ou plus, GNU date, curl ; ni python ni yq : config/noeuds.yml
# est lu avec awk, dans le format exact qu'écrit le Vagrantfile. Sous macOS, le
# bash 3.2 et le date BSD livrés ne conviennent pas (Homebrew : bash, coreutils).
# =============================================================================
set -o pipefail

RACINE_DEPOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NOEUDS_YML=$RACINE_DEPOT/config/noeuds.yml
cd "$RACINE_DEPOT" || exit 1

# --- Affichage ---------------------------------------------------------------------
NB_ECHECS=0
info()  { printf '%s\n' "$*"; }
etape() { printf '\n== %s ==\n' "$*"; }
ok()    { printf 'OK     %s\n' "$*"; }
ko()    { printf 'ECHEC  %s\n' "$*"; NB_ECHECS=$((NB_ECHECS + 1)); }
echec() { printf 'ERREUR : %s\n' "$*" >&2; exit 1; }
bilan() {   # bilan LIBELLE : dernière ligne de chaque script de vérification
  etape "Bilan"
  if (( NB_ECHECS == 0 )); then info "$1 : VALIDÉ (aucun échec)."; else info "$1 : NON VALIDÉ ($NB_ECHECS échec(s))."; fi
  return $(( NB_ECHECS > 0 ))
}

# --- Temps ---------------------------------------------------------------------------
maintenant_ms() { date +%s%3N; }
horodatage()    { date '+%Y-%m-%d %H:%M:%S'; }
duree_s()       { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1000 }'; }

# --- Inventaire ----------------------------------------------------------------------
# noeuds_hote [ROLE] : « nom ip role » par machine active, depuis config/noeuds.yml.
noeuds_hote() {
  [[ -r $NOEUDS_YML ]] || echec "$NOEUDS_YML absent : lancez d'abord une commande vagrant (vagrant status)."
  tr -d '\r' <"$NOEUDS_YML" | awk -v filtre="${1:-}" '
    function sortir() { if (nom != "" && (filtre == "" || filtre == role)) print nom, ip, role }
    /^- nom: /  { sortir(); nom = $3; ip = ""; role = ""; next }
    /^  ip: /   { ip = $2; next }
    /^  role: / { role = $2; next }
    END         { sortir() }'
}
ip_hote()  { noeuds_hote | awk -v n="$1" '$1 == n { print $2 }'; }
vip_hote() { tr -d '\r' <"$NOEUDS_YML" | awk '/^vip: / { print $2 }'; }

# url_service : point d'entrée du service vu de l'hôte. Par défaut l'adresse
# privée du répartiteur (ou l'IP virtuelle avec l'extension E1). La redirection
# localhost:8080 passe par le NAT de VirtualBox, plus lent : à éviter pour mesurer.
url_service() {
  if [[ -n ${URL_SERVICE:-} ]]; then echo "${URL_SERVICE%/}"; return; fi
  local adresse
  adresse=$(vip_hote)
  [[ -n $adresse ]] || adresse=$(noeuds_hote lb | awk 'NR == 1 { print $2 }')
  echo "http://$adresse"
}

# --- Mesures ---------------------------------------------------------------------------
# dossier_mesures SCENARIO : crée et affiche mesures/SCENARIO-AAAAMMJJ-HHMMSS.
dossier_mesures() {
  local d
  d="mesures/$1-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$d"
  echo "$d"
}

# ajouter_csv FICHIER ENTETE LIGNE : ajoute LIGNE, et l'en-tête si le fichier est neuf.
ajouter_csv() {
  [[ -s $1 ]] || echo "$2" >"$1"
  echo "$3" >>"$1"
}

# commit_courant : identifiant du commit mesuré (une mesure se rattache à un code).
commit_courant() { git rev-parse --short HEAD 2>/dev/null || echo inconnu; }

# analyser_sonde FICHIER_CSV [T_PANNE_MS] : résumé d'une sonde (tests/sonde.sh).
# Avec T_PANNE_MS, situe les erreurs par rapport à l'instant de la panne.
analyser_sonde() {
  awk -F';' -v panne="${2:-0}" '
    NR == 1 { next }
    { n++; if (NR == 2) debut = $1
      if ($3 + 0 > lent) { lent = $3 + 0; t_lent = $1 }
      if ($2 != 200) { e++; if (!pe) pe = $1; de = $1 } }
    END {
      printf "requêtes de la sonde : %d, en erreur (code différent de 200) : %d\n", n, e
      printf "réponse la plus lente : %.2f s (à t = %+.1f s)\n", lent, (t_lent - (panne ? panne : debut)) / 1000
      if (e) {
        printf "première erreur : t = %+.1f s ; dernière : t = %+.1f s\n", (pe - (panne ? panne : debut)) / 1000, (de - (panne ? panne : debut)) / 1000
        printf "période dégradée (première à dernière erreur) : %.1f s\n", (de - pe) / 1000
      } else {
        print "aucune erreur pendant toute la sonde"
      }
      if (panne) print "(t = 0 : instant de la panne)"
    }' "$1"
}

# code_http_hote URL : code de réponse HTTP vu de l'hôte (000 : aucune réponse en 5 s).
code_http_hote() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" || true; }

# attendre_http_hote URL CODE DELAI_S : vrai dès que URL répond CODE, faux après DELAI_S.
attendre_http_hote() {
  local debut=$SECONDS
  until [[ $(code_http_hote "$1") == "$2" ]]; do
    (( SECONDS - debut < $3 )) || return 1
    sleep 0.5
  done
}

# lire_ab FICHIER CHAMP : extrait une valeur de la sortie brute d'ApacheBench.
lire_ab() {
  case $2 in
    complete) awk '/^Complete requests:/ { print $3 }' "$1" ;;
    echecs)   awk '/^Failed requests:/ { print $3 }' "$1" ;;
    non2xx)   awk '/^Non-2xx responses:/ { print $3; t = 1 } END { if (!t) print 0 }' "$1" ;;
    debit)    awk '/^Requests per second:/ { print $4 }' "$1" ;;
    moyenne)  awk '/^Time per request:/ && /\(mean\)/ { print $4; exit }' "$1" ;;
    p50)      awk '$1 == "50%" { print $2 }' "$1" ;;
    p95)      awk '$1 == "95%" { print $2 }' "$1" ;;
    max)      awk '$1 == "100%" { print $2 }' "$1" ;;
  esac
}

# --- Vagrant -------------------------------------------------------------------------
# Sous Windows, chaque commande vagrant coûte plusieurs secondes. Avant chacune,
# Vagrant attend jusqu'à 10 s une vérification de version sur Internet : coupée
# ici, elle ne sert à rien aux scripts.
export VAGRANT_CHECKPOINT_DISABLE=1
DELAI_VAGRANT=${DELAI_VAGRANT:-120}   # secondes au plus par commande vagrant courte

# vagrant_borne ARGUMENTS… : vagrant ARGUMENTS, entrée standard fermée (sinon ssh
# avalerait celle d'une boucle « while read »), fins de ligne Windows retirées.
# La sortie passe par un fichier et non par un tube, et la commande est arrêtée
# au bout de DELAI_VAGRANT secondes : un vagrant qui ne rend pas la main ne
# bloque plus tout le script, et le message dit lequel. Code 124 ou 137 : délai.
vagrant_borne() {
  local sortie code
  sortie=$(mktemp)
  timeout -k 10 "$DELAI_VAGRANT" vagrant "$@" </dev/null >"$sortie"
  code=$?
  tr -d '\r' <"$sortie"
  rm -f "$sortie"
  if (( code == 124 || code == 137 )); then
    printf 'ERREUR : « vagrant %s %s » sans réponse après %s s (fiche pratique, section 7).\n' \
      "$1" "$2" "$DELAI_VAGRANT" >&2
  fi
  return "$code"
}

# --- Accès aux VM ----------------------------------------------------------------------
# Une VM est jointe en ssh DIRECT sur son adresse privée (noeuds.yml), avec la clé que
# Vagrant a créée pour elle (.vagrant/machines/NOM/virtualbox/private_key) : une à deux
# secondes par commande, sans passer par Vagrant ni par sa redirection de port, et la
# commande arrive telle quelle dans la VM. Sans clé ou sans client ssh, ou avec
# ACCES_VM=vagrant, les scripts passent par vagrant ssh (plusieurs secondes par appel
# sous Windows).
ACCES_VM=${ACCES_VM:-direct}
DELAI_SSH=${DELAI_SSH:-60}   # secondes au plus pour une commande courte (requête, état)

# acces_vm MACHINE : « direct » si le ssh direct est possible, sinon « vagrant ».
acces_vm() {
  if [[ $ACCES_VM == direct && -r $RACINE_DEPOT/.vagrant/machines/$1/virtualbox/private_key \
        && -n $(ip_hote "$1") ]] && command -v ssh >/dev/null 2>&1; then
    echo direct
  else
    echo vagrant
  fi
}

# commande_vm MACHINE COMMANDE DELAI : exécute COMMANDE dans la VM, sans terminal et
# entrée standard fermée (sinon ssh avalerait celle d'une boucle « while read »),
# arrêtée au bout de DELAI secondes. Code de sortie : celui de COMMANDE ; 255 si la
# VM est injoignable ; 124 ou 137 si le délai est dépassé (message sur stderr).
commande_vm() {
  local mode code
  mode=$(acces_vm "$1")
  if [[ $mode == direct ]]; then
    timeout -k 5 "$3" ssh -i "$RACINE_DEPOT/.vagrant/machines/$1/virtualbox/private_key" \
      -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
      "vagrant@$(ip_hote "$1")" "$2" </dev/null
  else
    timeout -k 10 "$3" vagrant ssh "$1" --no-tty -c "$2" -- -q </dev/null
  fi
  code=$?
  if (( code == 124 || code == 137 )); then
    printf 'ERREUR : %s sans réponse après %s s (accès %s ; fiche pratique, section 7).\n' \
      "$1" "$3" "$mode" >&2
  fi
  return "$code"
}

# vssh MACHINE COMMANDE : commande courte (DELAI_SSH), dont on capture la sortie avec
# $(…). La sortie passe par un fichier et non par un tube : un vagrant arrêté par le
# délai peut laisser des processus orphelins qui garderaient le tube ouvert.
vssh() {
  local sortie code
  sortie=$(mktemp)
  commande_vm "$1" "$2" "$DELAI_SSH" >"$sortie"
  code=$?
  tr -d '\r' <"$sortie"
  rm -f "$sortie"
  return "$code"
}

# vssh_suivi MACHINE COMMANDE DELAI : opération longue (installation, promotion,
# réintégration), dont la sortie s'affiche au fur et à mesure.
vssh_suivi() { commande_vm "$@"; }

# etat_vm MACHINE : running, poweroff, not_created, saved…
etat_vm() {
  vagrant_borne status "$1" --machine-readable 2>/dev/null | awk -F, '$3 == "state" { print $4; exit }'
}

# etats_vm : « machine état » pour toutes les machines, en un seul appel à vagrant.
etats_vm() {
  vagrant_borne status --machine-readable 2>/dev/null | awk -F, '$3 == "state" { print $2, $4 }'
}

# psql_vm MACHINE REQUETE [BASE] : une valeur, en tant que postgres dans la VM.
# La requête ne doit contenir ni guillemet double ni dollar.
psql_vm() {
  vssh "$1" "cd /tmp && sudo -u postgres psql -X -At -d ${3:-postgres} -c \"$2\""
}

# noeuds_bdd_hote : noms des machines de base (primaire nominale puis répliques).
noeuds_bdd_hote() { noeuds_hote | awk '$3 == "bdd" || $3 == "replique" { print $1 }'; }

# role_pg_vm MACHINE → primaire, replique ou rien (VM éteinte, PostgreSQL arrêté
# ou injoignable). Un seul appel à vagrant : vagrant ssh échoue seul, et vite,
# sur une VM qui ne tourne pas.
role_pg_vm() {
  case $(psql_vm "$1" "SELECT pg_is_in_recovery()" 2>/dev/null) in
    f) echo primaire ;;
    t) echo replique ;;
  esac
}

# reperer_roles : interroge chaque base UNE fois, en affichant l'avancement et la
# durée de chaque appel, et positionne PRIMAIRE et REPLIQUE (vides si aucune).
# À appeler sans $(…).
reperer_roles() {
  local nom role debut acces
  PRIMAIRE=""; REPLIQUE=""
  for nom in $(noeuds_bdd_hote); do
    if [[ $(acces_vm "$nom") == direct ]]; then acces="ssh direct"; else acces="vagrant ssh"; fi
    info "  $nom : interrogation par $acces…"
    debut=$SECONDS
    role=$(role_pg_vm "$nom")
    if [[ -z $role ]] && (( SECONDS - debut >= DELAI_SSH )); then
      info "  $nom : sans réponse après $DELAI_SSH s (fiche pratique, section 7)"
    else
      info "  $nom : ${role:-arrêtée ou injoignable} ($(( SECONDS - debut )) s)"
    fi
    case $role in
      primaire) [[ -n $PRIMAIRE ]] || PRIMAIRE=$nom ;;
      replique) [[ -n $REPLIQUE ]] || REPLIQUE=$nom ;;
    esac
  done
}

# primaire_actuelle / replique_actuelle : machine de base démarrée qui accepte
# (ou refuse) les écritures. Rien si aucune ne convient.
primaire_actuelle() {
  local nom
  for nom in $(noeuds_bdd_hote); do
    if [[ $(role_pg_vm "$nom") == primaire ]]; then echo "$nom"; return 0; fi
  done
  return 1
}
replique_actuelle() {
  local nom
  for nom in $(noeuds_bdd_hote); do
    if [[ $(role_pg_vm "$nom") == replique ]]; then echo "$nom"; return 0; fi
  done
  return 1
}

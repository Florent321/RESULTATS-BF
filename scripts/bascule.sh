#!/usr/bin/env bash
# =============================================================================
# scripts/bascule.sh — procédure de bascule de la base (R6, scénario V4)
# =============================================================================
# Quand la base primaire est perdue : isole l'ancienne primaire (elle ne
# redémarrera jamais seule en primaire), promeut la réplique, attend que le
# service réponde de nouveau, et chronomètre chaque étape.
# Les serveurs applicatifs ne sont pas touchés : leur PGHOST liste les deux
# bases, et libpq choisit celle qui accepte les écritures (étape 3).
# Usage (Git Bash, à la racine du dépôt) :
#   bash scripts/bascule.sh [NOUVELLE] [--forcer]
#     NOUVELLE  base à promouvoir (par défaut : la réplique démarrée)
#     --forcer  bascule PLANIFIÉE : l'ancienne primaire répond encore ; elle est
#               arrêtée et isolée avant la promotion
# Ensuite : bash scripts/reintegrer.sh ANCIENNE (elle redevient réplique).
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/lib_hote.sh"

nouvelle=""; forcer=0
for a in "$@"; do
  case $a in
    --forcer) forcer=1 ;;
    -*) echec "option inconnue : $a (usage : bash scripts/bascule.sh [NOUVELLE] [--forcer])" ;;
    *) nouvelle=$a ;;
  esac
done

t0=$(maintenant_ms)
mapfile -t bases < <(noeuds_bdd_hote)
(( ${#bases[@]} == 2 )) || echec "procédure écrite pour deux machines de base (trouvé : ${bases[*]})."

etape "1. Diagnostic"
info "date : $(horodatage) ; commit : $(commit_courant)"
etats=$(etats_vm)
etat_de() { awk -v n="$1" '$1 == n { print $2 }' <<<"$etats"; }
autre_que() { if [[ $1 == "${bases[0]}" ]]; then echo "${bases[1]}"; else echo "${bases[0]}"; fi; }

# État vu de l'intérieur de chaque base démarrée (une seule connexion par VM).
declare -A diag=()
for nom in "${bases[@]}"; do
  if [[ $(etat_de "$nom") == running ]]; then
    diag[$nom]=$(vssh "$nom" "sudo bash /vagrant/scripts/pg_outil.sh etat $(ip_hote "$(autre_que "$nom")")")
  fi
done
val() { awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' <<<"${diag[$1]:-}"; }

for nom in "${bases[@]}"; do
  ligne="$nom : VM $(etat_de "$nom")"
  if [[ -n ${diag[$nom]:-} ]]; then
    ligne+=", PostgreSQL $(val "$nom" role)"
    [[ $(val "$nom" role) == replique ]] && ligne+=" (flux : $(val "$nom" flux), reçu : $(val "$nom" recu), rejoué : $(val "$nom" rejoue))"
    [[ $(val "$nom" isole) == oui ]] && ligne+=", ISOLÉE"
  fi
  info "$ligne"
done

if [[ -z $nouvelle ]]; then
  for nom in "${bases[@]}"; do
    if [[ $(val "$nom" role) == replique ]]; then nouvelle=$nom; break; fi
  done
  [[ -n $nouvelle ]] || echec "aucune réplique démarrée : rien à promouvoir."
fi
[[ " ${bases[*]} " == *" $nouvelle "* ]] || echec "$nouvelle n'est pas une machine de base (${bases[*]})."
ancienne=$(autre_que "$nouvelle")
[[ $(etat_de "$nouvelle") == running ]] || echec "$nouvelle n'est pas démarrée : vagrant up $nouvelle"
case $(val "$nouvelle" role) in
  replique) ;;
  primaire) info "$nouvelle est déjà primaire : rien à promouvoir."; exit 0 ;;
  *) echec "PostgreSQL ne tourne pas sur $nouvelle : promotion impossible." ;;
esac

# L'ancienne primaire répond-elle encore ? Vu depuis la réplique, par le réseau
# privé : c'est ce que voient aussi les applications.
vue=$(val "$nouvelle" "pair_$(ip_hote "$ancienne")")
info "vu depuis $nouvelle, $ancienne ($(ip_hote "$ancienne")) est : $vue"
if [[ $vue == primaire || $(val "$ancienne" role) == primaire ]]; then
  (( forcer )) || echec "$ancienne est primaire et répond encore : bascule refusée (deux primaires divergeraient). Bascule planifiée : bash scripts/bascule.sh $nouvelle --forcer"
  mode=planifiee
else
  mode=panne
fi
info "dernière transaction rejouée par $nouvelle : $(val "$nouvelle" derniere_transaction)"
info "réplication asynchrone : une écriture validée sur $ancienne après la position $(val "$nouvelle" recu) serait perdue."

etape "2. Isolement de $ancienne"
t1=$(maintenant_ms)
mkdir -p .etat mesures
printf '%s : %s isolée par scripts/bascule.sh (%s promue primaire)\n' "$(horodatage)" "$ancienne" "$nouvelle" >".etat/isole-$ancienne"
ok "témoin .etat/isole-$ancienne posé : au prochain vagrant up, $ancienne gardera PostgreSQL arrêté"
if [[ $(etat_de "$ancienne") == running ]]; then
  if vssh_suivi "$ancienne" "sudo bash /vagrant/scripts/pg_outil.sh arreter" 300; then
    ok "PostgreSQL arrêté sur $ancienne"
  elif [[ $mode == planifiee ]]; then
    echec "impossible d'arrêter PostgreSQL sur $ancienne : promotion ANNULÉE (sinon deux primaires). Le témoin reste posé."
  else
    ko "arrêt de PostgreSQL sur $ancienne non confirmé (le témoin et start.conf l'empêchent de redémarrer seule)"
  fi
else
  info "$ancienne est éteinte : PostgreSQL n'y démarre jamais au démarrage de la VM (start.conf = manual), et le témoin bloque le provisionnement."
fi

etape "3. Promotion de $nouvelle"
t2=$(maintenant_ms)
vssh_suivi "$nouvelle" "sudo bash /vagrant/scripts/pg_outil.sh promouvoir" 300 || echec "promotion de $nouvelle échouée (voir ci-dessus)."
t3=$(maintenant_ms)
ok "$nouvelle promue primaire en $(duree_s "$t2" "$t3") s"

etape "4. Reprise du service"
url="$(url_service)/sante"
t4=""
if attendre_http_hote "$url" 200 90; then
  t4=$(maintenant_ms)
  ok "$url répond 200, $(duree_s "$t3" "$t4") s après la promotion"
else
  ko "$url ne répond toujours pas 200, 90 s après la promotion"
fi

etape "Chronométrage (R6)"
reprise=""; total=""
if [[ -n $t4 ]]; then reprise=$(duree_s "$t3" "$t4"); total=$(duree_s "$t0" "$t4"); fi
info "diagnostic : $(duree_s "$t0" "$t1") s ; isolement : $(duree_s "$t1" "$t2") s ; promotion : $(duree_s "$t2" "$t3") s ; reprise du service : ${reprise:-non obtenue} s"
info "durée totale de la procédure : ${total:-incomplète} s"
ajouter_csv mesures/bascules.csv "date;commit;operation;machine;autre;mode;diagnostic_s;isolement_s;promotion_s;reprise_s;total_s" \
  "$(horodatage);$(commit_courant);bascule;$nouvelle;$ancienne;$mode;$(duree_s "$t0" "$t1");$(duree_s "$t1" "$t2");$(duree_s "$t2" "$t3");$reprise;$total"
info "ligne ajoutée à mesures/bascules.csv"
info "Ensuite, pour retrouver une réplique : bash scripts/reintegrer.sh $ancienne"
bilan "Bascule vers $nouvelle"

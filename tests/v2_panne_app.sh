#!/usr/bin/env bash
# =============================================================================
# tests/v2_panne_app.sh — scénario V2 : panne d'un serveur applicatif sous charge
# =============================================================================
# Pendant une charge ab et une sonde horodatée, éteint un serveur applicatif,
# puis compte les requêtes perdues et mesure la période dégradée (énoncé §6).
# Usage (Git Bash, à la racine du dépôt) :
#   bash tests/v2_panne_app.sh [app1] [--brutal] [--sans-retour]
#     --brutal      vagrant halt --force (coupure de courant) au lieu d'un arrêt propre
#     --sans-retour ne pas rallumer le serveur à la fin
# Durée : environ 1 min 30.
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/../scripts/lib_hote.sh"

cible=app1; brutal=0; retour=1
for a in "$@"; do
  case $a in
    --brutal) brutal=1 ;;
    --sans-retour) retour=0 ;;
    *) cible=$a ;;
  esac
done
command -v ab >/dev/null || echec "ab (ApacheBench) introuvable : voir l'Étape 0 du cadrage."
[[ $(etat_vm "$cible") == running ]] || echec "$cible n'est pas démarrée."
url="$(url_service)/resultat?matricule=BF-2026-000042"
dossier=$(dossier_mesures v2)
arret="vagrant halt $cible"; (( brutal )) && arret="vagrant halt --force $cible"

etape "V2 — panne de $cible pendant une charge"
info "date : $(horodatage) ; commit : $(commit_courant) ; serveurs : $(noeuds_hote app | awk '{ printf "%s ", $1 }')"
info "charge : ab -k -r -t 30 -n 1000000 -c 10 \"$url\""
info "sonde  : bash tests/sonde.sh \"$url\" 40 0.1"
info "panne  : $arret (8 s après le début)"

bash tests/sonde.sh "$url" 40 0.1 >"$dossier/sonde.csv" &
pid_sonde=$!
# -k : connexions réutilisées, comme un navigateur. Sans lui, 30 s de charge
# ouvrent des milliers de connexions et épuisent les ports de l'hôte (Windows
# garde chaque connexion fermée environ 2 minutes). -r : continuer malgré une
# erreur de réception.
ab -k -r -t 30 -n 1000000 -c 10 "$url" >"$dossier/ab.txt" 2>&1 &
pid_ab=$!
sleep 8
t_panne=$(maintenant_ms)
$arret >"$dossier/arret.txt" 2>&1
info "panne déclenchée à $(date -d "@$(( t_panne / 1000 ))" +%H:%M:%S) ; arrêt terminé en $(duree_s "$t_panne" "$(maintenant_ms)") s"
wait "$pid_ab" "$pid_sonde"

etape "Charge (ab)"
complete=$(lire_ab "$dossier/ab.txt" complete); echecs=$(lire_ab "$dossier/ab.txt" echecs); non2xx=$(lire_ab "$dossier/ab.txt" non2xx)
info "requêtes terminées : ${complete:-?} ; en échec : ${echecs:-?} ; réponses non 2xx : ${non2xx:-?} ; débit : $(lire_ab "$dossier/ab.txt" debit) req/s"
# Mesure à rapporter (énoncé : « nombre de requêtes perdues ») ; le critère de
# réussite est celui de la sonde : plus aucune erreur au-delà de 5 s.
perdues=$(( ${echecs:-0} > ${non2xx:-0} ? ${echecs:-0} : ${non2xx:-0} ))
info "requêtes perdues pendant la charge : $perdues sur ${complete:-?}"
[[ -n $complete ]] || ko "sortie d'ab illisible (voir $dossier/ab.txt)"

etape "Sonde (une requête toutes les 0,1 s)"
analyser_sonde "$dossier/sonde.csv" "$t_panne" | tee "$dossier/resume-sonde.txt"
derniere=$(awk -F';' -v p="$t_panne" 'NR > 1 && $2 != 200 { d = $1 } END { print (d ? (d - p) / 1000 : -1) }' "$dossier/sonde.csv")
if awk -v d="$derniere" 'BEGIN { exit !(d < 5) }'; then ok "plus aucune erreur au-delà de 5 s après la panne"; else ko "erreurs encore $derniere s après la panne"; fi

etape "Vue du répartiteur"
for lb in $(noeuds_hote lb | awk '{ print $1 }'); do
  info "$lb : $(vssh "$lb" "sudo bash -c 'source /vagrant/scripts/lib.sh; etat_serveurs_haproxy'" | awk '{ printf "%s %s, ", $1, $2 }')"
done

ajouter_csv mesures/v2.csv "date;commit;cible;mode;requetes_ab;echecs_ab;non2xx_ab;perdues;derniere_erreur_s" \
  "$(horodatage);$(commit_courant);$cible;$( (( brutal )) && echo brutal || echo propre);${complete:-};${echecs:-};${non2xx:-};$perdues;$derniere"
info "sorties brutes : $dossier/ (ab.txt, sonde.csv) ; ligne ajoutée à mesures/v2.csv"

if (( retour )); then
  etape "Remise en service de $cible"
  if vagrant up "$cible" >"$dossier/remise.txt" 2>&1; then
    ok "$cible rallumée"
  else
    ko "$cible ne redémarre pas (voir $dossier/remise.txt)"
  fi
fi
bilan "V2"

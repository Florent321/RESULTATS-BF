#!/usr/bin/env bash
# =============================================================================
# tests/v4_bascule_bdd.sh — scénario V4 : panne de la base primaire, puis bascule
# =============================================================================
# 1. écrit un témoin sur la primaire et attend qu'il soit répliqué ;
# 2. éteint la primaire (vagrant halt) sous une sonde /sante toutes les 0,5 s ;
# 3. vérifie que le service répond PROPREMENT 503 (JSON), jamais une page
#    blanche ni une erreur de connexion brute (énoncé, V4) ;
# 4. lance la procédure scripts/bascule.sh dès que la panne est visible, et la
#    chronomètre ; vérifie que le témoin est sur la nouvelle primaire.
# Usage (Git Bash, à la racine du dépôt) :
#   bash tests/v4_bascule_bdd.sh [--brutal] [--reintegrer]
#     --brutal      vagrant halt --force (coupure de courant)
#     --reintegrer  à la fin, rallume l'ancienne primaire et la réintègre
#                   comme réplique (scripts/reintegrer.sh, sans confirmation)
# Durée : 1 à 3 minutes (plus avec --reintegrer).
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/../scripts/lib_hote.sh"

brutal=0; reintegrer=0
for a in "$@"; do
  case $a in
    --brutal) brutal=1 ;;
    --reintegrer) reintegrer=1 ;;
    *) echec "option inconnue : $a (usage : bash tests/v4_bascule_bdd.sh [--brutal] [--reintegrer])" ;;
  esac
done
url=$(url_service)
dossier=$(dossier_mesures v4)

etape "V4 — panne de la base primaire"
info "date : $(horodatage) ; commit : $(commit_courant) ; service : $url"
reperer_roles
primaire=$PRIMAIRE; replique=$REPLIQUE
[[ -n $primaire ]] || echec "aucune base primaire joignable : plateforme incomplète (voir les lignes ci-dessus)."
[[ -n $replique ]] || echec "aucune réplique joignable : la bascule serait impossible (voir les lignes ci-dessus)."
info "primaire : $primaire ; réplique : $replique"
[[ $(code_http_hote "$url/sante") == 200 ]] || echec "$url/sante ne répond pas 200 AVANT la panne : corrigez d'abord la plateforme."
n=$(psql_vm "$primaire" "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'")
(( ${n:-0} >= 1 )) || echec "aucune réplique en flux : une bascule perdrait des données."

etape "1. Témoin écrit avant la panne"
jeton="v4-$(date +%Y%m%d-%H%M%S)"
psql_vm "$primaire" "INSERT INTO preuve_replication (jeton) VALUES ('$jeton')" resultats >/dev/null
replique_ok=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ $(psql_vm "$replique" "SELECT count(*) FROM preuve_replication WHERE jeton = '$jeton'" resultats) == 1 ]] && { replique_ok=1; break; }
  sleep 1
done
if (( replique_ok )); then ok "témoin $jeton écrit sur $primaire et déjà présent sur $replique"; else ko "témoin $jeton absent de $replique après 10 s"; fi

etape "2. Panne : $( (( brutal )) && echo "vagrant halt --force" || echo "vagrant halt") $primaire"
bash tests/sonde.sh "$url/sante" 900 0.5 >"$dossier/sonde.csv" &
pid_sonde=$!
sleep 3
t_panne=$(maintenant_ms)
if (( brutal )); then vagrant halt --force "$primaire" >"$dossier/arret.txt" 2>&1 &
else vagrant halt "$primaire" >"$dossier/arret.txt" 2>&1 & fi
pid_arret=$!
t_vue=""
for _ in $(seq 120); do
  if [[ $(code_http_hote "$url/sante") != 200 ]]; then t_vue=$(maintenant_ms); break; fi
  sleep 0.5
done
if [[ -n $t_vue ]]; then info "panne visible sur /sante $(duree_s "$t_panne" "$t_vue") s après le début de l'arrêt"
else ko "la panne n'est pas visible sur /sante 60 s après l'arrêt de $primaire"; fi
# Preuve « proprement 503 » : réponse complète (en-têtes + corps), par le
# répartiteur et directement sur un serveur applicatif.
app=$(noeuds_hote app | awk 'NR == 1 { print $1 }')
curl -s -i --max-time 8 "$url/sante" 2>&1 | tr -d '\r' >"$dossier/reponse-repartiteur.txt"
curl -s -i --max-time 8 "http://$(ip_hote "$app"):3000/sante" 2>&1 | tr -d '\r' >"$dossier/reponse-$app.txt"
for f in "$dossier/reponse-repartiteur.txt" "$dossier/reponse-$app.txt"; do
  statut=$(head -1 "$f" | tr -d '\r')
  corps=$(tr -d '\r' <"$f" | awk 'corps { print } /^$/ { corps = 1 }')
  if [[ $statut == *" 503"* ]] && grep -qi '^content-type: application/json' "$f" && [[ $corps == "{"*"}" ]]; then
    ok "${f##*/} : $statut, corps JSON $corps"
  else
    ko "${f##*/} : réponse inattendue « $statut » (voir le fichier)"
  fi
done
wait "$pid_arret"
info "arrêt de $primaire terminé en $(duree_s "$t_panne" "$(maintenant_ms)") s"

etape "3. Procédure de bascule (scripts/bascule.sh)"
info "lancée dès la panne constatée ; en exploitation, ajoutez le temps de réaction de l'opérateur."
t_b0=$(maintenant_ms)
bash scripts/bascule.sh 2>&1 | tee "$dossier/bascule.txt"
rc=${PIPESTATUS[0]}
t_b1=$(maintenant_ms)
if (( rc == 0 )); then ok "bascule terminée en $(duree_s "$t_b0" "$t_b1") s"; else ko "bascule en échec (code $rc)"; fi
sleep 5
kill "$pid_sonde" 2>/dev/null; wait "$pid_sonde" 2>/dev/null

etape "4. Après la bascule"
if [[ $(role_pg_vm "$replique") == primaire ]]; then ok "$replique est la nouvelle primaire"; else ko "$replique n'est pas primaire"; fi
temoin=non
if [[ $(psql_vm "$replique" "SELECT count(*) FROM preuve_replication WHERE jeton = '$jeton'" resultats) == 1 ]]; then
  temoin=oui
  ok "le témoin écrit avant la panne est sur $replique (aucune perte pour ce qui était répliqué)"
else
  ko "témoin $jeton introuvable sur $replique"
fi
if [[ -n $(psql_vm "$replique" "INSERT INTO preuve_replication (jeton) VALUES ('$jeton-apres') RETURNING id" resultats) ]]; then
  ok "$replique accepte les écritures"
else
  ko "$replique refuse les écritures"
fi

etape "5. Sonde /sante (une requête toutes les 0,5 s)"
analyser_sonde "$dossier/sonde.csv" "$t_panne" | tee "$dossier/resume-sonde.txt"
codes=$(awk -F';' -v p="$t_panne" 'NR > 1 && $1 >= p && $2 != 200 { c[$2]++ } END { for (k in c) printf "%s:%d ", k, c[k] }' "$dossier/sonde.csv")
info "réponses en erreur, par code (code:nombre) : ${codes:-aucune}"
if [[ -n $codes && $codes =~ ^(503:[0-9]+ )+$ ]]; then ok "toutes les erreurs sont des 503 (aucune page blanche, aucune connexion refusée)"
else ko "codes d'erreur autres que 503 : $codes"; fi
read -r premiere derniere retour < <(awk -F';' -v p="$t_panne" '
  NR > 1 && $1 >= p { if ($2 != 200) { if (!pe) pe = $1; de = $1; r = "" } else if (de && !r) r = $1 }
  END { print (pe ? pe : "-"), (de ? de : "-"), (r ? r : "-") }' "$dossier/sonde.csv")
detection="-"; fin_erreurs="-"; indispo="-"
[[ $premiere != - ]] && detection=$(duree_s "$t_panne" "$premiere")
[[ $derniere != - ]] && fin_erreurs=$(duree_s "$t_panne" "$derniere")
[[ $premiere != - && $retour != - ]] && indispo=$(duree_s "$premiere" "$retour")
info "sonde : première erreur $detection s après le début de l'arrêt, dernière à $fin_erreurs s ; service indisponible pendant $indispo s"
info "durée de la procédure de bascule (mesure demandée par l'énoncé) : $(duree_s "$t_b0" "$t_b1") s"

ajouter_csv mesures/v4.csv "date;commit;mode;ancienne;nouvelle;detection_s;procedure_s;indisponibilite_s;codes_erreur;temoin_retrouve" \
  "$(horodatage);$(commit_courant);$( (( brutal )) && echo brutal || echo propre);$primaire;$replique;$detection;$(duree_s "$t_b0" "$t_b1");$indispo;${codes% };$temoin"
info "sorties brutes : $dossier/ ; ligne ajoutée à mesures/v4.csv"

if (( reintegrer )); then
  etape "6. Réintégration de $primaire (comme réplique de $replique)"
  bash scripts/reintegrer.sh "$primaire" --oui 2>&1 | tee "$dossier/reintegration.txt"
  if (( PIPESTATUS[0] == 0 )); then ok "$primaire réintégrée"; else ko "réintégration de $primaire en échec"; fi
else
  info "$primaire reste isolée. Pour la réintégrer : bash scripts/reintegrer.sh $primaire"
fi
bilan "V4"

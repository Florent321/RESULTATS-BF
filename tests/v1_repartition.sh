#!/usr/bin/env bash
# =============================================================================
# tests/v1_repartition.sh — scénario V1 : répartition, depuis l'HÔTE (Git Bash)
# =============================================================================
# 20 appels successifs à /info : chaque serveur doit apparaître, et l'écart
# entre le plus et le moins sollicité doit rester sous 20 % (énoncé §6).
# Écart (%) = (max - min) / (appels / serveurs) x 100 : 0 % = partage parfait.
# Usage : bash tests/v1_repartition.sh [NOMBRE_APPELS]
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/../scripts/lib_hote.sh"

appels=${1:-20}
url="$(url_service)/info"
mapfile -t declares < <(noeuds_hote app | awk '{ print $1 }')
dossier=$(dossier_mesures v1)

etape "V1 — répartition : $appels appels à $url"
info "date : $(horodatage) ; commit : $(commit_courant) ; serveurs déclarés : ${declares[*]}"
info "commande : for i in \$(seq $appels); do curl -s $url; echo; done"
for _ in $(seq "$appels"); do curl -s --max-time 5 "$url"; echo; done >"$dossier/reponses.txt"

etape "Résultat"
declare -A compte=()
for s in "${declares[@]}"; do compte[$s]=0; done
while IFS= read -r s; do
  [[ -n $s ]] && compte[$s]=$(( ${compte[$s]:-0} + 1 ))
done < <(sed -nE 's/.*"serveur":"([^"]*)".*/\1/p' "$dossier/reponses.txt")
max=0; min=$appels; detail=""
for s in "${!compte[@]}"; do
  (( compte[$s] > max )) && max=${compte[$s]}
  (( compte[$s] < min )) && min=${compte[$s]}
done
for s in $(printf '%s\n' "${!compte[@]}" | sort); do
  info "  $s : ${compte[$s]} réponse(s)"
  detail+="$s=${compte[$s]} "
done
ecart=$(awk -v a="$max" -v b="$min" -v n="$appels" -v k="${#declares[@]}" 'BEGIN { printf "%.0f", (a - b) / (n / k) * 100 }')
info "écart entre le plus et le moins sollicité : $max - $min = $(( max - min )), soit $ecart % de la part équitable"

absents=0
for s in "${declares[@]}"; do (( compte[$s] > 0 )) || { ko "$s déclaré mais jamais servi"; absents=1; }; done
(( absents == 0 )) && ok "les ${#declares[@]} serveurs déclarés ont répondu"
if (( ecart < 20 )); then ok "écart $ecart % < 20 %"; else ko "écart $ecart % >= 20 %"; fi

ajouter_csv mesures/v1.csv "date;commit;serveurs;appels;detail;ecart_pct" \
  "$(horodatage);$(commit_courant);${#declares[@]};$appels;${detail% };$ecart"
info "réponses brutes : $dossier/reponses.txt ; ligne ajoutée à mesures/v1.csv"
bilan "V1"

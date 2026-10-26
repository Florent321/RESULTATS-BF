#!/usr/bin/env bash
# =============================================================================
# tests/synthese.sh — tableaux des mesures, pour le dossier (livrable L2)
# =============================================================================
# Relit les fichiers mesures/*.csv écrits par les scénarios et produit
# mesures/synthese.md : un tableau par scénario, avec les dernières mesures.
# Aucun chiffre n'est calculé ailleurs que dans les CSV : chaque ligne renvoie
# à une exécution réelle (date, commit) dont les sorties brutes sont gardées
# dans mesures/<scénario>-<date>/.
# Usage : bash tests/synthese.sh            (affiche aussi le résultat)
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/../scripts/lib_hote.sh"

SORTIE=mesures/synthese.md
mkdir -p mesures
lignes() { tail -n +2 "$1" | tr -d '\r' | tail -n "$2"; }   # lignes FICHIER N
section() { printf '\n## %s\n\n' "$1"; }
absent() { printf '_Aucune mesure : lancez %s._\n' "\`$1\`"; }

{
  echo "# Synthèse des mesures — RÉSULTATS-BF"
  echo
  echo "Engendrée le $(horodatage) par \`tests/synthese.sh\` (commit $(commit_courant)), depuis les"
  echo "fichiers \`mesures/*.csv\`. Les sorties brutes de chaque mesure sont dans"
  echo "\`mesures/<scénario>-<date>/\`. Durées en secondes, débits en requêtes par seconde."

  section "V1 — Répartition : appels successifs à /info (critère : écart < 20 %)"
  if [[ -s mesures/v1.csv ]]; then
    echo "| Date | Commit | Serveurs | Réponses par serveur | Écart |"
    echo "| --- | --- | --- | --- | --- |"
    lignes mesures/v1.csv 5 | awk -F';' '{ printf "| %s | %s | %s | %s | %s %% |\n", $1, $2, $3, $5, $6 }'
  else absent "bash tests/v1_repartition.sh"; fi

  section "V2 — Panne d'un serveur applicatif sous charge (critère : plus d'erreur après 5 s)"
  if [[ -s mesures/v2.csv ]]; then
    echo "| Date | Commit | Serveur arrêté | Arrêt | Requêtes (ab) | Perdues | Dernière erreur après la panne |"
    echo "| --- | --- | --- | --- | --- | --- | --- |"
    lignes mesures/v2.csv 6 | awk -F';' '{ printf "| %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $8, ($9 < 0 ? "aucune erreur" : $9 " s") }'
  else absent "bash tests/v2_panne_app.sh app1"; fi

  section "V3 — Montée en charge : ab -n 2000 -c 50 (débit par nombre de serveurs)"
  if [[ -s mesures/v3.csv ]]; then
    echo "| Commit | N serveurs | Passes | Débit médian | Minimum | Maximum |"
    echo "| --- | --- | --- | --- | --- | --- |"
    tail -n +2 mesures/v3.csv | tr -d '\r' | awk -F';' '{ print $2 ";" $3 }' | awk '!vu[$0]++' | while IFS=';' read -r c nn; do
      valeurs=$(awk -F';' -v c="$c" -v n="$nn" 'NR > 1 && $2 == c && $3 == n { print $7 }' mesures/v3.csv | tr -d '\r' | sort -g)
      k=$(grep -c . <<<"$valeurs")
      printf '| %s | %s | %s | %s | %s | %s |\n' "$c" "$nn" "$k" "$(sed -n "$(( (k + 1) / 2 ))p" <<<"$valeurs")" "$(head -1 <<<"$valeurs")" "$(tail -1 <<<"$valeurs")"
    done
    echo
    echo "Les VM se partagent le processeur de l'hôte : un débit qui n'augmente pas avec N est un résultat à expliquer, pas à corriger."
  else absent "bash tests/v3_charge.sh, puis NB_APP=4 vagrant up et NB_APP=4 bash tests/v3_charge.sh"; fi

  section "V4 — Panne de la base primaire (critère : 503 propre ; mesure : durée de la bascule)"
  if [[ -s mesures/v4.csv ]]; then
    echo "| Date | Commit | Arrêt | Bascule | Panne visible après | Procédure de bascule | Service indisponible | Codes d'erreur | Témoin retrouvé |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    lignes mesures/v4.csv 6 | awk -F';' '{ printf "| %s | %s | %s | %s → %s | %s s | %s s | %s s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10 }'
  else absent "bash tests/v4_bascule_bdd.sh"; fi

  section "V5 — Reconstruction complète (vagrant destroy -f puis vagrant up)"
  if [[ -s mesures/v5.csv ]]; then
    echo "| Date | Commit | NB_APP | E1 | Boîte déjà présente | Destruction | vagrant up | Plateforme | Total |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    lignes mesures/v5.csv 5 | awk -F';' '{ printf "| %s | %s | %s | %s | %s | %s s | %s s | %s | %s s |\n", $1, $2, $3, $4, $5, $6, $7, ($8 == "validee" ? "validée" : "en échec"), $9 }'
  else absent "bash tests/v5_reconstruction.sh"; fi

  section "V6 — Panne du répartiteur (E1) : même adresse, reprise en moins de 5 s"
  if [[ -s mesures/v6.csv ]]; then
    echo "| Date | Commit | Arrêt | IP virtuelle | Requêtes touchées | Erreurs | Plus lente | Coupure | Reprise | Touchées au retour |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    lignes mesures/v6.csv 6 | awk -F';' '{ printf "| %s | %s | %s | %s → %s | %s | %s | %s s | %s s | %s s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11 }'
  else absent "bash tests/v6_bascule_lb.sh"; fi

  section "E4 — Déploiement sans coupure (critère : aucune requête en erreur)"
  if [[ -s mesures/e4.csv ]]; then
    echo "| Date | Commit | Version | Serveurs | Déploiement | Requêtes (ab) | Échecs | Non 2xx | Erreurs de la sonde | Débit |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    lignes mesures/e4.csv 5 | awk -F';' '{ printf "| %s | %s | %s | %s | %s s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10 }'
  else absent "bash tests/e4_deploiement.sh --version X.Y.Z"; fi

  section "Procédures chronométrées (scripts/bascule.sh, scripts/reintegrer.sh)"
  if [[ -s mesures/bascules.csv ]]; then
    echo "| Date | Commit | Opération | Machine | Autre base | Mode | Diagnostic | Isolement | Promotion | Reprise du service | Total |"
    echo "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
    lignes mesures/bascules.csv 8 | awk -F';' '{ printf "| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11 }'
  else absent "bash scripts/bascule.sh (pendant V4)"; fi
} >"$SORTIE"

cat "$SORTIE"
info ""
info "écrit dans $SORTIE"

#!/usr/bin/env bash
# =============================================================================
# tests/sonde.sh — sonde horodatée, lancée depuis l'HÔTE (Git Bash)
# =============================================================================
# Envoie une requête HTTP toutes les INTERVALLE secondes pendant DUREE secondes
# et écrit une ligne CSV par requête : instant (ms), code HTTP, durée, serveur.
# Sert aux scénarios V2, V4, V6 et E4 : c'est elle qui date les pannes.
# Usage : bash tests/sonde.sh URL DUREE_S [INTERVALLE_S] > sonde.csv
# =============================================================================
set -u
url=${1:?usage : sonde.sh URL DUREE_S [INTERVALLE_S]}
duree=${2:-30}
intervalle=${3:-0.2}
fin=$(( $(date +%s%3N) + duree * 1000 ))

echo "t_ms;code;duree_s;serveur"
while (( $(date +%s%3N) < fin )); do
  debut=$(date +%s%3N)
  # 000 = aucune réponse (connexion refusée, délai de 5 s dépassé…).
  reponse=$(curl -s --max-time 5 -w '\n%{http_code};%{time_total}' "$url")
  corps=${reponse%$'\n'*}
  mesures=${reponse##*$'\n'}
  serveur=$(sed -nE 's/.*"serveur":"([^"]*)".*/\1/p' <<<"$corps")
  echo "$debut;$mesures;$serveur"
  sleep "$intervalle"
done

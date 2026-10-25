#!/usr/bin/env bash
# =============================================================================
# tests/verifier_plateforme.sh — contrôle fonctionnel de bout en bout, depuis l'HÔTE
# =============================================================================
# Vérifie que la plateforme entière répond : service par le répartiteur, JSON
# attendu, serveurs vus UP par HAProxy, configuration engendrée (R3, R4),
# réplication en flux (R5). C'est le contrôle du jalon J1, à relancer après
# chaque vagrant up.
# Usage : bash tests/verifier_plateforme.sh 2>&1 | tee "docs/preuves/plateforme-$(date +%Y%m%d-%H%M).txt"
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/../scripts/lib_hote.sh"

base=$(url_service)
mapfile -t apps < <(noeuds_hote app)
info "Plateforme RÉSULTATS-BF : $(horodatage), commit $(commit_courant), service $base, ${#apps[@]} serveur(s) applicatif(s)"

etape "1. Le service répond par le répartiteur"
corps=$(curl -s --max-time 10 "$base/resultat?matricule=BF-2026-000123")
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$base/resultat?matricule=BF-2026-000123")
if [[ $code == 200 && $corps == *'"matricule":"BF-2026-000123"'* ]]; then ok "GET /resultat : 200, $corps"; else ko "GET /resultat : HTTP $code, « $corps »"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$base/sante")
if [[ $code == 200 ]]; then ok "GET /sante : 200"; else ko "GET /sante : HTTP $code"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$base/resultat?matricule=INCONNU")
if [[ $code == 404 ]]; then ok "matricule inconnu : 404"; else ko "matricule inconnu : HTTP $code (404 attendu)"; fi
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$base/resultat")
if [[ $code == 400 ]]; then ok "matricule absent : 400"; else ko "matricule absent : HTTP $code (400 attendu)"; fi

etape "2. Tous les serveurs déclarés répondent (/info)"
vus=$(for _ in $(seq $(( ${#apps[@]} * 4 ))); do curl -s --max-time 5 "$base/info"; echo; done \
  | sed -nE 's/.*"serveur":"([^"]*)".*/\1/p' | sort -u | tr '\n' ' ')
for ligne in "${apps[@]}"; do
  read -r nom _ <<<"$ligne"
  if [[ " $vus" == *" $nom "* ]]; then ok "$nom a répondu"; else ko "$nom n'a jamais répondu"; fi
done

etape "3. Répartiteur : configuration engendrée et sonde (R3, R4)"
if grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}' config/haproxy.cfg.modele; then ko "le modèle contient une adresse IP écrite en dur"; else ok "le modèle ne contient aucune adresse IP"; fi
for lb in $(noeuds_hote lb | awk '{ print $1 }'); do
  conf=$(vssh "$lb" "sudo grep -E '^ +server ' /etc/haproxy/haproxy.cfg")
  etats=$(vssh "$lb" "sudo bash -c 'source /vagrant/scripts/lib.sh; etat_serveurs_haproxy'")
  for ligne in "${apps[@]}"; do
    read -r nom ip _ <<<"$ligne"
    if grep -qE "server +$nom +$ip:3000 +check" <<<"$conf"; then ok "$lb : « server $nom $ip:3000 check » présent"; else ko "$lb : ligne server de $nom absente ou sans check"; fi
    etat=$(awk -v n="$nom" '$1 == n { print $2 }' <<<"$etats")
    if [[ $etat == UP ]]; then ok "$lb : $nom UP"; else ko "$lb : $nom ${etat:-absent}"; fi
  done
  nb=$(grep -cE '^ +server ' <<<"$conf")
  if (( nb == ${#apps[@]} )); then ok "$lb : $nb serveur(s), autant que dans noeuds.yml"; else ko "$lb : $nb serveur(s) pour ${#apps[@]} déclaré(s)"; fi
done

etape "4. Réplication (R5)"
if primaire=$(primaire_actuelle); then
  n=$(psql_vm "$primaire" "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming'")
  if (( ${n:-0} >= 1 )); then ok "$primaire est primaire, $n réplique(s) en flux"; else ko "$primaire est primaire mais aucune réplique en flux"; fi
else
  ko "aucune base primaire joignable"
fi

etape "5. Redirection de port de l'hôte (R8)"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:8080/info")
if [[ $code == 200 ]]; then ok "http://127.0.0.1:8080/info : 200 (seul port redirigé, vers lb1)"; else info "ATTENTION : 127.0.0.1:8080 répond $code (port changé par auto_correct ? voir vagrant port lb1)"; fi

bilan "Plateforme"

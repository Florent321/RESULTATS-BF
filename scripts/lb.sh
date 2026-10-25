#!/usr/bin/env bash
# =============================================================================
# scripts/lb.sh — rôle « lb » : répartiteur HAProxy (étape 4)
# =============================================================================
# Engendre /etc/haproxy/haproxy.cfg depuis config/haproxy.cfg.modele et la
# liste des serveurs de config/noeuds.yml (R3 : aucune adresse écrite à la main).
# Rejoué à chaque vagrant up : NB_APP=4 vagrant up ajoute donc app3 et app4 au
# répartiteur. HAProxy n'est rechargé que si sa configuration change (R2).
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "${DEPOT:-/vagrant}/scripts/lib.sh"

PORT_APP=3000
MODELE=$DEPOT/config/haproxy.cfg.modele
CONFIG=/etc/haproxy/haproxy.cfg

charger_secrets
IP_PRIVEE=$(ip_de "$NOM_MACHINE")
[[ -n $IP_PRIVEE ]] || erreur "adresse de $NOM_MACHINE absente de noeuds.yml"
a_recharger=0

# --- 1. Pages d'erreur en JSON ----------------------------------------------------
# Ce sont des réponses HTTP brutes : fins de ligne CRLF et longueur exacte.
page_erreur() {   # page_erreur CODE RAISON ERREUR MESSAGE
  local corps
  corps=$(printf '{"erreur":"%s","code":%s,"message":"%s"}' "$3" "$1" "$4")
  printf 'HTTP/1.1 %s %s\r\n' "$1" "$2"
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf 'Connection: close\r\n'
  printf 'Content-Length: %s\r\n\r\n' "$(printf '%s' "$corps" | wc -c)"
  printf '%s' "$corps"
}
ecrire_fichier /etc/haproxy/errors/resultats-502.http 0644 root:root < <(page_erreur 502 "Bad Gateway" \
  reponse_invalide "Un serveur applicatif a interrompu sa réponse. Réessayez.")
if (( FICHIER_MODIFIE )); then a_recharger=1; fi
ecrire_fichier /etc/haproxy/errors/resultats-503.http 0644 root:root < <(page_erreur 503 "Service Unavailable" \
  service_indisponible "Aucun serveur disponible pour le moment. Réessayez dans quelques secondes.")
if (( FICHIER_MODIFIE )); then a_recharger=1; fi
ecrire_fichier /etc/haproxy/errors/resultats-504.http 0644 root:root < <(page_erreur 504 "Gateway Timeout" \
  delai_depasse "Le serveur applicatif n'a pas répondu à temps. Réessayez.")
if (( FICHIER_MODIFIE )); then a_recharger=1; fi

# --- 2. Configuration engendrée ----------------------------------------------------
# Une ligne « server » par serveur applicatif actif, AVEC le mot-clé check :
# sans lui, HAProxy n'interroge jamais /sante (énoncé §12, dernier piège).
serveurs=$(lister_noeuds app | awk -v port="$PORT_APP" '{ printf "    server %-5s %s:%s check\n", $1, $2, port }')
[[ -n $serveurs ]] || erreur "aucun serveur applicatif dans noeuds.yml"
config="# FICHIER ENGENDRÉ par scripts/lb.sh depuis config/haproxy.cfg.modele et config/noeuds.yml."$'\n'
config+="# Ne pas modifier à la main : la prochaine commande vagrant l'écraserait."$'\n'
config+=$(<"$MODELE")
config=${config//@@SERVEURS_APP@@/"$serveurs"}
config=${config//@@IP_PRIVEE@@/"$IP_PRIVEE"}
config=${config//@@MDP_STATS@@/"$HAPROXY_STATS_MDP"}
if [[ $config =~ @@[A-Z_]+@@ ]]; then
  erreur "marqueur ${BASH_REMATCH[0]} du modèle non remplacé"
fi

# Validation AVANT écriture : une configuration invalide ne remplace jamais
# celle qui fonctionne.
candidat=$(mktemp)
printf '%s\n' "$config" >"$candidat"
if ! sortie=$(haproxy -c -f "$candidat" 2>&1); then
  rm -f "$candidat"
  erreur "configuration HAProxy invalide : $sortie"
fi
# Contient le mot de passe de la page d'état : lisible par root et haproxy seulement.
ecrire_fichier "$CONFIG" 0640 root:haproxy <"$candidat"
rm -f "$candidat"
if (( FICHIER_MODIFIE )); then a_recharger=1; fi

# --- 3. Service ----------------------------------------------------------------------
[[ -d /run/haproxy ]] || install -d -m 2775 -o haproxy -g haproxy /run/haproxy
systemctl is-enabled --quiet haproxy || action systemctl enable --quiet haproxy
if ! systemctl is-active --quiet haproxy; then
  action systemctl start haproxy
  a_recharger=1
elif (( a_recharger )); then
  # Rechargement à chaud : les connexions en cours ne sont pas coupées.
  action systemctl reload haproxy
fi

# --- 4. État des serveurs, vu par HAProxy -------------------------------------------------
# Après un (re)chargement, on laisse aux sondes le temps de passer (rise 2 x 1 s).
if (( a_recharger )); then sleep 3; fi
etats=$(etat_serveurs_haproxy | awk '{ printf "%s%s %s", sep, $1, $2; sep = ", " }')
log "HAProxy : $(lister_noeuds app | wc -l) serveur(s) déclaré(s) : $etats"

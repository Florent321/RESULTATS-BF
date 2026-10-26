#!/usr/bin/env bash
# =============================================================================
# scripts/lb.sh — rôle « lb » : répartiteurs HAProxy lb1 et lb2 (étapes 4 et 6)
# =============================================================================
# Engendre /etc/haproxy/haproxy.cfg depuis config/haproxy.cfg.modele et la
# liste des serveurs de config/noeuds.yml (R3 : aucune adresse écrite à la main).
# Rejoué à chaque vagrant up : NB_APP=4 vagrant up ajoute donc app3 et app4 au
# répartiteur. HAProxy n'est rechargé que si sa configuration change (R2).
# Étape 6 (E1) : si noeuds.yml déclare une IP virtuelle, engendre aussi la
# configuration keepalived (VRRP) qui la fait porter par lb1 ou lb2.
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
reponse_json() {   # reponse_json CODE RAISON CORPS
  printf 'HTTP/1.1 %s %s\r\n' "$1" "$2"
  printf 'Content-Type: application/json; charset=utf-8\r\n'
  printf 'Cache-Control: no-store\r\n'
  printf 'Connection: close\r\n'
  printf 'Content-Length: %s\r\n\r\n' "$(printf '%s' "$3" | wc -c)"
  printf '%s' "$3"
}
page_erreur() {   # page_erreur CODE RAISON ERREUR MESSAGE
  reponse_json "$1" "$2" "$(printf '{"erreur":"%s","code":%s,"message":"%s"}' "$3" "$1" "$4")"
}
# Réponse de /lb-sante (monitor-uri, étape 6) : nomme le répartiteur qui répond.
ecrire_fichier /etc/haproxy/errors/resultats-200.http 0644 root:root < <(reponse_json 200 OK \
  "$(printf '{"etat":"ok","repartiteur":"%s"}' "$NOM_MACHINE")")
if (( FICHIER_MODIFIE )); then a_recharger=1; fi
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

# --- 5. IP virtuelle partagée par les répartiteurs (étape 6, extension E1) -------------
VIP=$(vip_declaree)
if [[ -z $VIP ]]; then
  # E1=0 : pas d'IP virtuelle ; keepalived, s'il a tourné, est arrêté.
  if systemctl is-active --quiet keepalived 2>/dev/null; then action systemctl disable --now --quiet keepalived; fi
  exit 0
fi
# Pairs : les AUTRES répartiteurs ; priorité : 150 pour le premier (lb1), 100 ensuite.
pairs=$(lister_noeuds lb | awk -v n="$NOM_MACHINE" '$1 != n { printf "        %s\n", $2 }')
[[ -n $pairs ]] || erreur "IP virtuelle $VIP déclarée mais aucun autre répartiteur : E1 en demande deux."
rang=$(lister_noeuds lb | awk -v n="$NOM_MACHINE" '$1 == n { print NR }')
priorite=$(( rang == 1 ? 150 : 102 - rang ))
# Interface qui porte l'adresse privée (eth1 sur la boîte bento, sans le supposer).
interface=$(ip -o -4 addr show | awk -v ip="$IP_PRIVEE" '{ split($4, a, "/") } a[1] == ip && !vu { print $2; vu = 1 }')
[[ -n $interface ]] || erreur "aucune interface ne porte $IP_PRIVEE"
# Identifiant VRRP : 3e octet du réseau (56 à 63), différent pour chaque groupe.
vrid=$(cut -d. -f3 <<<"$VIP")

id -u keepalived_script >/dev/null 2>&1 \
  || action useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin keepalived_script
config=$(<"$DEPOT/config/keepalived.conf.modele")
config="# FICHIER ENGENDRÉ par scripts/lb.sh depuis config/keepalived.conf.modele et config/noeuds.yml."$'\n'"$config"
config=${config//@@NOM@@/"$NOM_MACHINE"}
config=${config//@@INTERFACE@@/"$interface"}
config=${config//@@VRID@@/"$vrid"}
config=${config//@@PRIORITE@@/"$priorite"}
config=${config//@@IP_PRIVEE@@/"$IP_PRIVEE"}
config=${config//@@PAIRS@@/"$pairs"}
config=${config//@@VIP@@/"$VIP"}
if [[ $config =~ @@[A-Z_]+@@ ]]; then erreur "marqueur ${BASH_REMATCH[0]} du modèle keepalived non remplacé"; fi
candidat=$(mktemp)
printf '%s\n' "$config" >"$candidat"
if ! sortie=$(keepalived -t -f "$candidat" 2>&1); then
  rm -f "$candidat"
  erreur "configuration keepalived invalide : $sortie"
fi
ecrire_fichier /etc/keepalived/keepalived.conf 0644 root:root <"$candidat"
rm -f "$candidat"
vrrp_modifie=$FICHIER_MODIFIE
systemctl is-enabled --quiet keepalived || action systemctl enable --quiet keepalived
if ! systemctl is-active --quiet keepalived; then
  action systemctl start keepalived
elif (( vrrp_modifie )); then
  # Rechargement (SIGHUP) : le maître garde l'IP, aucune coupure.
  action systemctl reload keepalived
fi
# Élection : un keepalived qui vient de démarrer (ici, ou au démarrage de la VM)
# attend ~1,8 s les annonces d'un maître avant de prendre l'IP ; on lui laisse 4 s.
age=$(ps -o etimes= -C keepalived 2>/dev/null | sort -n | awk 'NR == 1 { print $1 }') || true
if [[ $age =~ ^[0-9]+$ ]] && (( age < 4 )); then sleep $(( 4 - age )); fi
# (grep sur une variable, pas en fin de tube : avec pipefail, « … | grep -q »
# peut échouer à tort quand grep s'arrête avant la fin de l'écriture.)
if grep -q " $VIP/" <<<"$(ip -o -4 addr show dev "$interface")"; then
  log "keepalived : $NOM_MACHINE est MAÎTRE et porte l'IP virtuelle $VIP (priorité $priorite)"
else
  log "keepalived : $NOM_MACHINE est en attente (BACKUP, priorité $priorite) ; l'IP virtuelle $VIP est portée par l'autre répartiteur"
fi

#!/usr/bin/env bash
# =============================================================================
# scripts/haproxy_serveur.sh — retirer / remettre un serveur dans HAProxy (E4)
# =============================================================================
# Lancé DANS un répartiteur, par scripts/deploiement.sh (vagrant ssh), ou à la main :
#   sudo bash /vagrant/scripts/haproxy_serveur.sh drainer app1
#     plus aucune NOUVELLE requête vers app1 ; attend la fin de celles en cours
#   sudo bash /vagrant/scripts/haproxy_serveur.sh activer app1
#     remet app1 en service et attend que la sonde /sante le voie UP
#   sudo bash /vagrant/scripts/haproxy_serveur.sh etat
#     « serveur état requêtes_en_cours » pour chaque serveur
# Passe par l'interface d'administration d'HAProxy (/run/haproxy/admin.sock) :
# aucun rechargement, aucune coupure. L'état « drain » est perdu si HAProxy est
# rechargé : le serveur revient alors en service, comme les autres.
# =============================================================================
set -Eeuo pipefail
# shellcheck source=scripts/lib.sh
source "${DEPOT:-/vagrant}/scripts/lib.sh"

(( EUID == 0 )) || erreur "à lancer avec sudo."
commande=${1:-}
serveur=${2:-}
champ() { etat_serveurs_haproxy | awk -v s="$serveur" -v c="$1" '$1 == s { print $c }'; }

case $commande in
  etat)
    etat_serveurs_haproxy
    ;;
  drainer | activer)
    [[ -n $serveur ]] || erreur "usage : sudo bash /vagrant/scripts/haproxy_serveur.sh $commande SERVEUR"
    [[ -n $(champ 2) ]] || erreur "$serveur inconnu de HAProxy sur $NOM_MACHINE (serveurs : $(etat_serveurs_haproxy | awk '{ printf "%s ", $1 }'))"
    if [[ $commande == drainer ]]; then
      reponse=$(api_haproxy "set server be_app/$serveur state drain")
      [[ -z ${reponse//[$'\n ']/} ]] || erreur "HAProxy refuse : $reponse"
      debut=$SECONDS
      # Requêtes en cours sur ce serveur : on attend qu'elles se terminent (30 s au plus).
      until [[ $(champ 3) == 0 ]]; do
        if (( SECONDS - debut >= 30 )); then log "ATTENTION : $(champ 3) requête(s) encore en cours sur $serveur après 30 s"; break; fi
        sleep 0.2
      done
      log "ACTION $serveur retiré (drain) : $(champ 3) requête en cours, état $(champ 2)"
    else
      reponse=$(api_haproxy "set server be_app/$serveur state ready")
      [[ -z ${reponse//[$'\n ']/} ]] || erreur "HAProxy refuse : $reponse"
      debut=$SECONDS
      # « ready » lève le retrait ; le trafic ne revient qu'une fois la sonde /sante réussie.
      until [[ $(champ 2) == UP ]]; do
        if (( SECONDS - debut >= 30 )); then erreur "$serveur toujours $(champ 2) après 30 s (sonde /sante en échec ?)"; fi
        sleep 0.2
      done
      log "ACTION $serveur remis en service : UP en $(( SECONDS - debut )) s"
    fi
    ;;
  *)
    erreur "usage : sudo bash /vagrant/scripts/haproxy_serveur.sh drainer|activer SERVEUR, ou etat"
    ;;
esac

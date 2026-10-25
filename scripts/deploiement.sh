#!/usr/bin/env bash
# =============================================================================
# scripts/deploiement.sh — déploiement sans coupure, serveur par serveur (E4)
# =============================================================================
# Installe la version du dépôt (app/app.py, app/VERSION) sur chaque serveur
# applicatif, L'UN APRÈS L'AUTRE :
#   1. retrait du serveur dans chaque répartiteur (drain), fin des requêtes en cours ;
#   2. installation par scripts/app.sh (copie, redémarrage de Gunicorn) ;
#   3. contrôle direct du serveur : /info donne la nouvelle version, /sante 200 ;
#   4. remise en service, attendue jusqu'à ce que les répartiteurs le voient UP.
# Un seul serveur est hors service à la fois : la capacité baisse d'un serveur
# sur N pendant quelques secondes, le service ne s'arrête jamais.
# Usage (Git Bash, à la racine du dépôt) : bash scripts/deploiement.sh
# En cas d'échec, le serveur concerné RESTE retiré (le service continue sur les
# autres) : corrigez, puis relancez ce script.
# Pour mettre à jour l'application, préférez ce script à vagrant provision, qui
# redémarre les serveurs sans les retirer d'abord des répartiteurs.
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/lib_hote.sh"

version=$(tr -d '\r\n' <app/VERSION)
mapfile -t apps < <(noeuds_hote app)
mapfile -t lbs < <(noeuds_hote lb | awk '{ print $1 }')
(( ${#apps[@]} >= 2 )) || echec "il faut au moins deux serveurs applicatifs pour déployer sans coupure."
version_de() { curl -s --max-time 5 "http://$1:3000/info" | sed -nE 's/.*"version":"([^"]*)".*/\1/p'; }

t0=$(maintenant_ms)
etape "Déploiement de la version $version sur ${#apps[@]} serveur(s), un par un"
info "date : $(horodatage) ; commit : $(commit_courant) ; répartiteurs : ${lbs[*]}"
deployes=0
for ligne in "${apps[@]}"; do
  read -r nom ip _ <<<"$ligne"
  etape "$nom ($ip)"
  avant=$(version_de "$ip")
  if [[ $avant == "$version" ]]; then ok "$nom a déjà la version $version : rien à faire"; continue; fi
  t1=$(maintenant_ms)
  for lb in "${lbs[@]}"; do
    vssh_suivi "$lb" "sudo bash /vagrant/scripts/haproxy_serveur.sh drainer $nom" 300 \
      || echec "retrait de $nom sur $lb impossible : déploiement arrêté."
  done
  vssh_suivi "$nom" "sudo bash /vagrant/scripts/app.sh" 600 \
    || echec "installation sur $nom échouée : $nom reste retiré des répartiteurs (corrigez, puis relancez)."
  apres=$(version_de "$ip")
  [[ $apres == "$version" ]] || echec "$nom répond la version « $apres » au lieu de $version : il reste retiré."
  [[ $(code_http_hote "http://$ip:3000/sante") == 200 ]] || echec "$nom : /sante ne répond pas 200 : il reste retiré."
  for lb in "${lbs[@]}"; do
    vssh_suivi "$lb" "sudo bash /vagrant/scripts/haproxy_serveur.sh activer $nom" 300 \
      || echec "remise en service de $nom sur $lb impossible : déploiement arrêté."
  done
  ok "$nom : ${avant:-?} → $apres en $(duree_s "$t1" "$(maintenant_ms)") s"
  deployes=$((deployes + 1))
done

t_fin=$(maintenant_ms)
etape "Bilan du déploiement"
info "$deployes serveur(s) mis à jour en $(duree_s "$t0" "$t_fin") s"
mkdir -p mesures
ajouter_csv mesures/deploiements.csv "date;commit;version;serveurs_mis_a_jour;duree_s" \
  "$(horodatage);$(commit_courant);$version;$deployes;$(duree_s "$t0" "$t_fin")"
bilan "Déploiement de $version"

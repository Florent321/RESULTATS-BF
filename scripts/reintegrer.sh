#!/usr/bin/env bash
# =============================================================================
# scripts/reintegrer.sh — réintègre une ancienne primaire comme RÉPLIQUE
# =============================================================================
# Après une bascule (scripts/bascule.sh), l'ancienne primaire est isolée : ses
# données ont pu diverger (écritures validées chez elle mais jamais reçues par
# la réplique). Ce script la recopie entièrement depuis la primaire actuelle
# (pg_basebackup), la redémarre en réplique, puis lève l'isolement.
# Usage (Git Bash, à la racine du dépôt) :
#   bash scripts/reintegrer.sh MACHINE [--oui]
#     --oui  sans demande de confirmation (scripts de test)
# DESTRUCTIF pour MACHINE : ses anciennes données sont mises de côté dans la VM
# (/var/lib/postgresql/16/main.avant-reintegration-DATE), à supprimer à la main.
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/lib_hote.sh"

machine=""; oui=0
for a in "$@"; do
  case $a in
    --oui) oui=1 ;;
    -*) echec "option inconnue : $a (usage : bash scripts/reintegrer.sh MACHINE [--oui])" ;;
    *) machine=$a ;;
  esac
done
[[ -n $machine ]] || echec "usage : bash scripts/reintegrer.sh MACHINE [--oui]"
role_nominal=$(noeuds_hote | awk -v n="$machine" '$1 == n { print $3 }')
[[ $role_nominal == bdd || $role_nominal == replique ]] || echec "$machine n'est pas une machine de base."

t0=$(maintenant_ms)
etape "1. Primaire actuelle"
primaire=""
for nom in $(noeuds_bdd_hote); do
  [[ $nom == "$machine" ]] && continue
  if [[ $(role_pg_vm "$nom") == primaire ]]; then primaire=$nom; break; fi
done
[[ -n $primaire ]] || echec "aucune autre base n'est primaire : rien à rejoindre. Faites d'abord la bascule : bash scripts/bascule.sh"
info "primaire actuelle : $primaire ; à réintégrer : $machine"

etape "2. Confirmation"
info "ATTENTION — opération DESTRUCTIVE pour $machine : ses données PostgreSQL seront"
info "remplacées par une copie de $primaire (les anciennes restent dans la VM, dossier"
info "/var/lib/postgresql/16/main.avant-reintegration-DATE)."
if (( ! oui )); then
  read -r -p "Tapez OUI pour continuer : " reponse
  [[ $reponse == OUI ]] || echec "abandon : rien n'a été modifié."
fi

etape "3. Recopie depuis $primaire"
etat=$(etat_vm "$machine")
if [[ $etat == not_created ]]; then
  # Base détruite : son témoin d'isolement a été retiré (Vagrantfile), et un
  # nœud neuf rejoint de lui-même la primaire actuelle.
  vagrant up "$machine" || echec "vagrant up $machine a échoué."
else
  if [[ $etat != running ]]; then
    # Isolée, elle redémarre SANS PostgreSQL (le provisionnement le vérifie).
    vagrant up "$machine" || echec "vagrant up $machine a échoué."
  fi
  vssh_suivi "$machine" "sudo bash /vagrant/scripts/$role_nominal.sh --reintegrer" 1800 \
    || echec "réintégration de $machine échouée (voir ci-dessus) : elle reste isolée."
fi
rm -f ".etat/isole-$machine"
ok "isolement de $machine levé"

etape "4. Vérification"
role=$(role_pg_vm "$machine")
if [[ $role == replique ]]; then ok "$machine est réplique"; else ko "$machine : rôle « ${role:-injoignable} » au lieu de réplique"; fi
flux=$(psql_vm "$primaire" "SELECT state FROM pg_stat_replication WHERE application_name = '$machine'")
if [[ $flux == streaming ]]; then ok "$primaire envoie son journal à $machine (streaming)"; else ko "flux de $primaire vers $machine : « $flux »"; fi
t1=$(maintenant_ms)
info "durée de la réintégration : $(duree_s "$t0" "$t1") s (confirmation comprise)"
mkdir -p mesures
ajouter_csv mesures/bascules.csv "date;commit;operation;machine;autre;mode;diagnostic_s;isolement_s;promotion_s;reprise_s;total_s" \
  "$(horodatage);$(commit_courant);reintegration;$machine;$primaire;-;;;;;$(duree_s "$t0" "$t1")"
bilan "Réintégration de $machine"

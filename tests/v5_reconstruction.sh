#!/usr/bin/env bash
# =============================================================================
# tests/v5_reconstruction.sh — scénario V5 (et R1) : destruction puis reconstruction
# =============================================================================
# DESTRUCTIF : supprime TOUTES les machines et leurs données (vagrant destroy -f),
# les recrée (vagrant up) sans aucune intervention, puis vérifie la plateforme
# (tests/verifier_plateforme.sh) et chronomètre chaque phase.
# Usage (Git Bash, à la racine du dépôt) :
#   bash tests/v5_reconstruction.sh [--oui]      (--oui : sans confirmation)
# Les paramètres de ce terminal (NB_APP, E1) s'appliquent à la reconstruction.
# Durée : de 10 à 30 minutes sur un poste de la salle (plus si la boîte doit
# être téléchargée).
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/../scripts/lib_hote.sh"

oui=0
for a in "$@"; do
  case $a in
    --oui) oui=1 ;;
    *) echec "option inconnue : $a (usage : bash tests/v5_reconstruction.sh [--oui])" ;;
  esac
done
dossier=$(dossier_mesures v5)
version_boite=$(sed -nE 's/^VERSION_BOITE *= *"([^"]+)".*/\1/p' Vagrantfile)
boites=$(vagrant box list 2>/dev/null | tr -d '\r')   # pas de « | grep -q » sous pipefail
if grep -q "^bento/ubuntu-24.04 *(virtualbox, $version_boite" <<<"$boites"; then cache=oui; else cache=non; fi

etape "V5 — reconstruction complète"
info "date : $(horodatage) ; commit : $(commit_courant) ; NB_APP=${NB_APP:-2 (défaut)} ; E1=${E1:-1 (défaut)}"
info "boîte bento/ubuntu-24.04 $version_boite déjà présente sur ce poste : $cache"
if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
  info "ATTENTION : le dossier contient des modifications non commitées ; elles seront utilisées."
fi
info "ATTENTION — opération DESTRUCTIVE : toutes les machines et leurs données seront supprimées."
if (( ! oui )); then
  read -r -p "Tapez OUI pour continuer : " reponse
  [[ $reponse == OUI ]] || echec "abandon : rien n'a été modifié."
fi

t0=$(maintenant_ms)
vagrant destroy -f >"$dossier/destruction.txt" 2>&1 || ko "vagrant destroy -f a échoué (voir $dossier/destruction.txt)"
t1=$(maintenant_ms)
info "destruction : $(duree_s "$t0" "$t1") s"
info "vagrant up en cours (sortie complète : $dossier/reconstruction.txt)…"
if vagrant up >"$dossier/reconstruction.txt" 2>&1; then
  t2=$(maintenant_ms)
  ok "vagrant up terminé sans erreur en $(duree_s "$t1" "$t2") s"
else
  t2=$(maintenant_ms)
  ko "vagrant up a échoué après $(duree_s "$t1" "$t2") s ; fin de la sortie :"
  tail -20 "$dossier/reconstruction.txt" | tr -d '\r'
fi

etape "Vérification de la plateforme (sans aucune commande manuelle)"
if bash tests/verifier_plateforme.sh >"$dossier/verification.txt" 2>&1; then
  verification=validee; ok "plateforme fonctionnelle (détail : $dossier/verification.txt)"
else
  verification=echec; ko "plateforme incomplète :"; grep -E "^ECHEC" "$dossier/verification.txt"
fi
t3=$(maintenant_ms)

etape "Chronométrage"
info "destruction : $(duree_s "$t0" "$t1") s ; reconstruction (vagrant up) : $(duree_s "$t1" "$t2") s ; vérification : $(duree_s "$t2" "$t3") s"
info "durée totale de la reconstruction (destroy + up) : $(duree_s "$t0" "$t2") s"
ajouter_csv mesures/v5.csv "date;commit;nb_app;e1;boite_en_cache;destruction_s;reconstruction_s;verification;total_s" \
  "$(horodatage);$(commit_courant);${NB_APP:-2};${E1:-1};$cache;$(duree_s "$t0" "$t1");$(duree_s "$t1" "$t2");$verification;$(duree_s "$t0" "$t2")"
info "sorties brutes : $dossier/ ; ligne ajoutée à mesures/v5.csv"
bilan "V5"

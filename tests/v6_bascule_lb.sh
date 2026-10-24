#!/usr/bin/env bash
# =============================================================================
# tests/v6_bascule_lb.sh — scénario V6 (extension E1) : panne du répartiteur maître
# =============================================================================
# 1. repère le répartiteur qui porte l'IP virtuelle (GET http://VIP/lb-sante) ;
# 2. sonde le service SUR L'IP VIRTUELLE toutes les 0,1 s ;
# 3. éteint ce répartiteur (vagrant halt) et mesure la reprise : le service doit
#    rester joignable à la MÊME adresse, en moins de 5 s (énoncé, E1) ;
# 4. rallume le répartiteur éteint : il ne doit PAS reprendre l'IP (nopreempt),
#    donc aucune coupure au retour.
# Usage (Git Bash, à la racine du dépôt) :
#   bash tests/v6_bascule_lb.sh [--brutal] [--sans-retour]
#     --brutal      vagrant halt --force (coupure de courant)
#     --sans-retour ne pas rallumer le répartiteur à la fin
# Durée : 1 à 3 minutes selon le poste (le retour refait un vagrant up).
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/../scripts/lib_hote.sh"

brutal=0; retour=1
for a in "$@"; do
  case $a in
    --brutal) brutal=1 ;;
    --sans-retour) retour=0 ;;
    *) echec "option inconnue : $a (usage : bash tests/v6_bascule_lb.sh [--brutal] [--sans-retour])" ;;
  esac
done
vip=$(vip_hote)
[[ -n $vip ]] || echec "aucune IP virtuelle dans config/noeuds.yml : l'extension E1 est désactivée (E1=0)."
url="http://$vip/resultat?matricule=BF-2026-000042"
porteur() { curl -s --max-time 3 "http://$vip/lb-sante" | sed -nE 's/.*"repartiteur":"([^"]*)".*/\1/p'; }
dossier=$(dossier_mesures v6)

etape "V6 — panne du répartiteur maître"
info "date : $(horodatage) ; commit : $(commit_courant) ; IP virtuelle : $vip"
maitre=$(porteur)
[[ -n $maitre ]] || echec "l'IP virtuelle $vip ne répond pas : plateforme incomplète."
autre=$(noeuds_hote lb | awk -v m="$maitre" '$1 != m { print $1; exit }')
[[ -n $autre && $(etat_vm "$autre") == running ]] || echec "aucun autre répartiteur démarré : personne ne reprendrait l'IP."
info "l'IP virtuelle est portée par $maitre ; $autre est en attente"
info "sonde : bash tests/sonde.sh \"$url\" (toutes les 0,1 s)"

bash tests/sonde.sh "$url" 900 0.1 >"$dossier/sonde.csv" &
pid_sonde=$!
sleep 5
t_panne=$(maintenant_ms)
if (( brutal )); then vagrant halt --force "$maitre" >"$dossier/arret.txt" 2>&1
else vagrant halt "$maitre" >"$dossier/arret.txt" 2>&1; fi
info "panne : vagrant halt $( (( brutal )) && echo "--force ")$maitre, terminé en $(duree_s "$t_panne" "$(maintenant_ms)") s"
sleep 10
t_fin_panne=$(maintenant_ms)
nouveau=$(porteur)
if [[ $nouveau == "$autre" ]]; then ok "l'IP virtuelle $vip est maintenant portée par $autre"; else ko "porteur de l'IP virtuelle : « $nouveau » au lieu de $autre"; fi

if (( retour )); then
  etape "Retour de $maitre (nopreempt : il ne doit pas reprendre l'IP)"
  vagrant up "$maitre" >"$dossier/retour.txt" 2>&1 || ko "vagrant up $maitre a échoué (voir $dossier/retour.txt)"
  sleep 5
  if [[ $(porteur) == "$autre" ]]; then ok "$autre garde l'IP virtuelle ; $maitre est revenu en attente"; else ko "l'IP virtuelle a changé de porteur au retour de $maitre"; fi
fi
t_fin=$(maintenant_ms)
kill "$pid_sonde" 2>/dev/null; wait "$pid_sonde" 2>/dev/null

# Requête « touchée » : en erreur, ou plus lente que 0,5 s (connexion envoyée à
# l'ancien maître, puis rejouée par TCP vers le nouveau).
fenetre() {   # fenetre DEBUT_MS FIN_MS : « touchees erreurs debut_coupure_ms fin_coupure_ms lente_s »
  awk -F';' -v d="$1" -v f="$2" '
    NR > 1 && $1 >= d && $1 < f {
      fin = $1 + $3 * 1000
      if ($3 + 0 > lente) lente = $3 + 0
      if ($2 != 200 || $3 > 0.5) { n++; if ($2 != 200) e++; if (!pd) pd = $1; if (fin > df) df = fin }
    }
    END { printf "%d %d %s %s %.2f\n", n, e, (pd ? sprintf("%.0f", pd) : "-"), (df ? sprintf("%.0f", df) : "-"), lente }' "$dossier/sonde.csv"
}

etape "Sonde pendant la panne"
read -r touchees erreurs debut fin lente < <(fenetre "$t_panne" "$t_fin_panne")
info "requêtes touchées (erreur ou plus de 0,5 s) : $touchees, dont en erreur : $erreurs ; la plus lente : $lente s"
reprise=0.0; coupure=0.0
if [[ $fin != - ]]; then reprise=$(duree_s "$t_panne" "$fin"); coupure=$(duree_s "$debut" "$fin"); fi
info "coupure vue par la sonde : $coupure s ; service normal $reprise s après le début de l'arrêt"
if awk -v r="$reprise" 'BEGIN { exit !(r < 5) }'; then ok "service joignable à la même adresse en moins de 5 s (reprise : $reprise s)"
else ko "service perturbé pendant $reprise s (plus de 5 s)"; fi
retour_touchees="-"
if (( retour )); then
  etape "Sonde pendant le retour de $maitre"
  read -r retour_touchees retour_erreurs _ _ retour_lente < <(fenetre "$t_fin_panne" "$t_fin")
  info "requêtes touchées : $retour_touchees, dont en erreur : $retour_erreurs ; la plus lente : $retour_lente s"
  if (( retour_erreurs == 0 )); then ok "aucune erreur au retour de $maitre"; else ko "$retour_erreurs erreur(s) au retour de $maitre"; fi
fi

ajouter_csv mesures/v6.csv "date;commit;mode;ancien_maitre;nouveau_maitre;touchees;erreurs;plus_lente_s;coupure_s;reprise_s;touchees_au_retour" \
  "$(horodatage);$(commit_courant);$( (( brutal )) && echo brutal || echo propre);$maitre;$nouveau;$touchees;$erreurs;$lente;$coupure;$reprise;$retour_touchees"
info "sorties brutes : $dossier/ (sonde.csv) ; ligne ajoutée à mesures/v6.csv"
bilan "V6"

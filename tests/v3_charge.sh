#!/usr/bin/env bash
# =============================================================================
# tests/v3_charge.sh — scénario V3 : débit avec la configuration ACTUELLE
# =============================================================================
# Procédure complète de l'énoncé (N = 2 puis N = 4), dans Git Bash :
#   bash tests/v3_charge.sh                  # N = 2
#   NB_APP=4 vagrant up                      # ajoute app3 et app4 (R3)
#   NB_APP=4 bash tests/v3_charge.sh         # N = 4, puis tableau comparatif
# Retour à N = 2 : vagrant destroy -f app3 app4, puis vagrant up.
# Chaque appel : un échauffement (ab -n 200 -c 10, non compté), puis R passes
# de « ab -n 2000 -c 50 » (commande de l'énoncé) sur l'adresse du service.
# Usage : bash tests/v3_charge.sh [--repetitions R]     (R = 3 par défaut)
# Honnêteté (énoncé §6) : les VM se partagent le processeur de l'hôte ;
# doubler N ne double pas le débit, et il peut baisser. On mesure, on explique.
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/../scripts/lib_hote.sh"

reps=3
while (( $# )); do
  case $1 in
    --repetitions) reps=${2:-}; shift ;;
    *) echec "option inconnue : $1 (usage : bash tests/v3_charge.sh [--repetitions R])" ;;
  esac
  shift
done
[[ $reps =~ ^[1-9][0-9]?$ ]] || echec "nombre de répétitions invalide : $reps"
command -v ab >/dev/null || echec "ab (ApacheBench) introuvable : voir l'Étape 0 du cadrage."
url="$(url_service)/resultat?matricule=BF-2026-000042"
dossier=$(dossier_mesures v3)

# Serveurs qui répondent VRAIMENT, comptés par /info. (Aucune commande vagrant
# ici : elle réécrirait noeuds.yml avec le NB_APP de ce terminal.) Un serveur
# tout juste rallumé n'est servi qu'après deux sondes réussies : on l'attend 30 s.
servis_par_info() {
  for _ in $(seq 40); do curl -s --max-time 5 "$(url_service)/info"; echo; done \
    | sed -nE 's/.*"serveur":"([^"]*)".*/\1/p' | sort -u
}
declares=$(noeuds_hote app | wc -l | tr -d ' ')
debut=$SECONDS
servis=$(servis_par_info)
until (( $(grep -c . <<<"$servis") >= declares || SECONDS - debut >= 30 )); do
  sleep 2
  servis=$(servis_par_info)
done
n=$(grep -c . <<<"$servis")

etape "V3 — débit avec N = $n serveur(s) applicatif(s)"
info "date : $(horodatage) ; commit : $(commit_courant) ; service : $url"
info "serveurs qui répondent : $(tr '\n' ' ' <<<"$servis")(déclarés dans noeuds.yml : $declares)"
(( n == declares )) || ko "$n serveur(s) répondent pour $declares déclaré(s) : terminez « NB_APP=$declares vagrant up », ou exportez le bon NB_APP"
info "rappel : les VM se partagent le processeur de l'hôte ; doubler N ne double pas le débit."

ab -n 200 -c 10 "$url" >"$dossier/echauffement.txt" 2>&1 || ko "échauffement en échec (voir $dossier/echauffement.txt)"
for r in $(seq "$reps"); do
  f="$dossier/passe$r.txt"
  ab -n 2000 -c 50 "$url" >"$f" 2>&1
  debit=$(lire_ab "$f" debit); echecs=$(lire_ab "$f" echecs); non2xx=$(lire_ab "$f" non2xx)
  if [[ -z $debit ]]; then ko "passe $r : sortie d'ab illisible (voir $f)"; continue; fi
  info "passe $r : $debit req/s ; temps moyen $(lire_ab "$f" moyenne) ms ; médiane $(lire_ab "$f" p50) ms ; 95 % sous $(lire_ab "$f" p95) ms ; max $(lire_ab "$f" max) ms ; échecs $echecs ; non 2xx $non2xx"
  if [[ $echecs == 0 && $non2xx == 0 ]]; then ok "passe $r : aucune requête en erreur"; else ko "passe $r : requêtes en erreur"; fi
  ajouter_csv mesures/v3.csv "date;commit;n_serveurs;passe;requetes;concurrence;debit_req_s;moyenne_ms;p50_ms;p95_ms;max_ms;echecs;non2xx" \
    "$(horodatage);$(commit_courant);$n;$r;2000;50;$debit;$(lire_ab "$f" moyenne);$(lire_ab "$f" p50);$(lire_ab "$f" p95);$(lire_ab "$f" max);$echecs;$non2xx"
  sleep 2
done

etape "Comparaison (toutes les passes du commit $(commit_courant), dans mesures/v3.csv)"
echo "| N serveurs | Passes | Débit médian | Minimum | Maximum |"
echo "| --- | --- | --- | --- | --- |"
awk -F';' -v c="$(commit_courant)" 'NR > 1 && $2 == c { print $3 }' mesures/v3.csv | sort -un | while read -r nn; do
  valeurs=$(awk -F';' -v c="$(commit_courant)" -v n="$nn" 'NR > 1 && $2 == c && $3 == n { print $7 }' mesures/v3.csv | sort -g)
  k=$(grep -c . <<<"$valeurs")
  mediane=$(sed -n "$(( (k + 1) / 2 ))p" <<<"$valeurs")
  echo "| $nn | $k | $mediane | $(head -1 <<<"$valeurs") | $(tail -1 <<<"$valeurs") |"
done
info "(débits en requêtes par seconde ; médiane : valeur du milieu, moins sensible à une passe perturbée)"
info "sorties brutes : $dossier/ ; lignes ajoutées à mesures/v3.csv"
bilan "V3 (N = $n)"

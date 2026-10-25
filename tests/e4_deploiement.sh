#!/usr/bin/env bash
# =============================================================================
# tests/e4_deploiement.sh — extension E4 : mise à jour complète PENDANT une charge
# =============================================================================
# Lance une charge ab et une sonde sur /info, déploie la version de app/VERSION
# serveur par serveur (scripts/deploiement.sh), puis vérifie l'exigence de
# l'énoncé : « sans une seule requête en erreur ».
# Usage (Git Bash, à la racine du dépôt) :
#   bash tests/e4_deploiement.sh [--version X.Y.Z] [--duree S]
#     --version  écrit d'abord X.Y.Z dans app/VERSION (fichier VERSIONNÉ :
#                commitez-le ensuite) ; sinon, la version actuelle du fichier
#     --duree    durée de la charge (défaut : 30 s par serveur + 30 s) ; elle
#                doit couvrir tout le déploiement
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/../scripts/lib_hote.sh"

nouvelle=""; duree=""
while (( $# )); do
  case $1 in
    --version) nouvelle=${2:-}; shift ;;
    --duree) duree=${2:-}; shift ;;
    *) echec "option inconnue : $1 (usage : bash tests/e4_deploiement.sh [--version X.Y.Z] [--duree S])" ;;
  esac
  shift
done
command -v ab >/dev/null || echec "ab (ApacheBench) introuvable : voir l'Étape 0 du cadrage."
if [[ -n $nouvelle ]]; then
  [[ $nouvelle =~ ^[0-9A-Za-z.+-]+$ ]] || echec "version invalide : $nouvelle"
  printf '%s\n' "$nouvelle" >app/VERSION
  info "app/VERSION vaut maintenant $nouvelle (fichier versionné : pensez à le commiter)."
fi
version=$(tr -d '\r\n' <app/VERSION)
mapfile -t apps < <(noeuds_hote app)
a_jour=0
for ligne in "${apps[@]}"; do
  read -r _ ip _ <<<"$ligne"
  [[ $(curl -s --max-time 5 "http://$ip:3000/info") == *"\"version\":\"$version\""* ]] && a_jour=$((a_jour + 1))
done
(( a_jour < ${#apps[@]} )) || echec "tous les serveurs ont déjà la version $version : rien à déployer. Changez app/VERSION (et le code), ou : --version X.Y.Z"
duree=${duree:-$(( 30 * ${#apps[@]} + 30 ))}
url=$(url_service)
dossier=$(dossier_mesures e4)

etape "E4 — déploiement de la version $version sous charge"
info "date : $(horodatage) ; commit : $(commit_courant) ; serveurs : ${#apps[@]} ; déjà à jour : $a_jour"
info "charge : ab -k -r -t $duree -n 1000000 -c 10 \"$url/resultat?matricule=BF-2026-000042\""
info "sonde  : bash tests/sonde.sh \"$url/info\" $duree 0.2 (serveur et version de chaque réponse)"
t_charge=$(maintenant_ms)
ab -k -r -t "$duree" -n 1000000 -c 10 "$url/resultat?matricule=BF-2026-000042" >"$dossier/ab.txt" 2>&1 &
pid_ab=$!
bash tests/sonde.sh "$url/info" "$duree" 0.2 >"$dossier/sonde.csv" &
pid_sonde=$!
sleep 5

t_d0=$(maintenant_ms)
bash scripts/deploiement.sh 2>&1 | tee "$dossier/deploiement.txt"
rc=${PIPESTATUS[0]}
t_d1=$(maintenant_ms)
info "attente de la fin de la charge…"
wait "$pid_ab" "$pid_sonde"

etape "Résultats"
if (( rc == 0 )); then ok "déploiement terminé en $(duree_s "$t_d0" "$t_d1") s"; else ko "déploiement en échec (code $rc)"; fi
if (( t_d1 < t_charge + duree * 1000 )); then ok "le déploiement s'est fait entièrement sous charge"
else ko "la charge s'est arrêtée avant la fin du déploiement : relancez avec --duree plus grand"; fi
complete=$(lire_ab "$dossier/ab.txt" complete); echecs=$(lire_ab "$dossier/ab.txt" echecs); non2xx=$(lire_ab "$dossier/ab.txt" non2xx)
info "ab : ${complete:-?} requêtes, ${echecs:-?} en échec, ${non2xx:-?} réponses non 2xx, $(lire_ab "$dossier/ab.txt" debit) req/s"
if [[ -n $complete && ${echecs:-1} == 0 && ${non2xx:-1} == 0 ]]; then ok "aucune requête en erreur pendant la charge"; else ko "requêtes en erreur pendant la charge (voir $dossier/ab.txt)"; fi
erreurs=$(awk -F';' 'NR > 1 && $2 != 200' "$dossier/sonde.csv" | wc -l | tr -d ' ')
if (( erreurs == 0 )); then ok "sonde /info : aucune erreur"; else ko "sonde /info : $erreurs erreur(s)"; fi
info "versions servies pendant la charge (t = 0 : début du déploiement) :"
awk -F';' -v t0="$t_d0" 'NR > 1 && $5 != "" { n[$5]++; if (!($5 in premier)) premier[$5] = $1; dernier[$5] = $1 }
  END { for (v in n) printf "  %s : %d réponse(s), de t = %+.1f s à t = %+.1f s\n", v, n[v], (premier[v] - t0) / 1000, (dernier[v] - t0) / 1000 }' \
  "$dossier/sonde.csv" | sort -t= -k2 -g
a_jour=0
for ligne in "${apps[@]}"; do
  read -r nom ip _ <<<"$ligne"
  if [[ $(curl -s --max-time 5 "http://$ip:3000/info") == *"\"version\":\"$version\""* ]]; then a_jour=$((a_jour + 1)); else ko "$nom n'a pas la version $version"; fi
done
if (( a_jour == ${#apps[@]} )); then ok "les ${#apps[@]} serveurs ont la version $version"; fi

ajouter_csv mesures/e4.csv "date;commit;version;serveurs;duree_deploiement_s;requetes_ab;echecs_ab;non2xx_ab;erreurs_sonde;debit" \
  "$(horodatage);$(commit_courant);$version;${#apps[@]};$(duree_s "$t_d0" "$t_d1");${complete:-};${echecs:-};${non2xx:-};$erreurs;$(lire_ab "$dossier/ab.txt" debit)"
info "sorties brutes : $dossier/ ; ligne ajoutée à mesures/e4.csv"
bilan "E4"

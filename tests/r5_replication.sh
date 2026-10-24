#!/usr/bin/env bash
# =============================================================================
# tests/r5_replication.sh — preuve de R5, lancée depuis l'HÔTE (Git Bash)
# =============================================================================
# Une écriture sur la base primaire doit être lue sur la réplique, qui doit
# elle-même refuser toute écriture.
# Usage, à la racine du dépôt :
#   mkdir -p docs/preuves
#   bash tests/r5_replication.sh 2>&1 | tee "docs/preuves/r5-$(date +%Y%m%d-%H%M).txt"
# =============================================================================
set -u
# shellcheck source=scripts/lib_hote.sh
source "$(dirname "$0")/../scripts/lib_hote.sh"

info "R5 — réplication en flux : $(horodatage), commit $(git rev-parse --short HEAD 2>/dev/null || echo inconnu)"

etape "0. Rôles actuels"
reperer_roles
primaire=$PRIMAIRE; replique=$REPLIQUE
[[ -n $primaire ]] || echec "aucune base primaire joignable (voir les lignes ci-dessus ; état des VM : vagrant status)."
[[ -n $replique ]] || echec "aucune réplique joignable (voir les lignes ci-dessus ; état des VM : vagrant status)."
info "primaire : $primaire ; réplique : $replique"

jeton="r5-$(date +%Y%m%d-%H%M%S)-$RANDOM"
etape "1. Écriture sur le primaire ($primaire)"
requete="INSERT INTO preuve_replication (jeton) VALUES ('$jeton') RETURNING id, ecrit_le"
info "requête : $requete"
ecrit=$(psql_vm "$primaire" "$requete" resultats | head -1)
if [[ -n $ecrit ]]; then ok "écrit sur $primaire : $ecrit"; else ko "écriture impossible sur $primaire"; fi

etape "2. Lecture sur la réplique ($replique)"
lu=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  lu=$(psql_vm "$replique" "SELECT id, ecrit_le FROM preuve_replication WHERE jeton = '$jeton'" resultats)
  [[ -n $lu ]] && break
  sleep 1
done
if [[ -n $lu && $lu == "$ecrit" ]]; then ok "lu sur $replique : $lu (identique)"; else ko "jeton absent ou différent sur $replique : « $lu »"; fi

etape "3. La réplique refuse les écritures"
sortie=$(vssh "$replique" "cd /tmp && sudo -u postgres psql -X -d resultats -c \"INSERT INTO preuve_replication (jeton) VALUES ('interdit-$jeton')\" 2>&1")
info "réponse : $sortie"
if grep -q "read-only transaction" <<<"$sortie"; then ok "écriture refusée (lecture seule)"; else ko "la réplique a accepté l'écriture ou a répondu autre chose"; fi

etape "4. Flux vu du primaire (pg_stat_replication)"
psql_vm "$primaire" "SELECT application_name, client_addr, state, sync_state, coalesce(replay_lag::text, '0') FROM pg_stat_replication"

etape "5. Retard de la réplique"
info "dernière transaction rejouée il y a : $(psql_vm "$replique" "SELECT coalesce((now() - pg_last_xact_replay_timestamp())::text, 'inconnu')")"

bilan "R5"

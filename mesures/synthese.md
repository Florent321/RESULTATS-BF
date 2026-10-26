# Synthèse des mesures — RÉSULTATS-BF

Engendrée le 2026-10-26 02:13:51 par `tests/synthese.sh` (commit 05b92b2), depuis les
fichiers `mesures/*.csv`. Les sorties brutes de chaque mesure sont dans
`mesures/<scénario>-<date>/`. Durées en secondes, débits en requêtes par seconde.

## V1 — Répartition : appels successifs à /info (critère : écart < 20 %)

| Date | Commit | Serveurs | Réponses par serveur | Écart |
| --- | --- | --- | --- | --- |
| 2026-10-24 15:16:42 | c6a98f3 | 2 | app1=10 app2=10 | 0 % |
| 2026-10-24 15:41:05 | c6a98f3 | 2 | app1=0 app2=20 | 200 % |

## V2 — Panne d'un serveur applicatif sous charge (critère : plus d'erreur après 5 s)

| Date | Commit | Serveur arrêté | Arrêt | Requêtes (ab) | Perdues | Dernière erreur après la panne |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-10-24 15:17:47 | c6a98f3 | app1 | propre | 24345 | 0 | aucune erreur |
| 2026-10-24 15:30:35 | c6a98f3 | app2 | brutal | 10320 | 5479 | 31.813 s |
| 2026-10-24 15:54:36 | c6a98f3 | app1 | propre | 7091 | 0 | aucune erreur |
| 2026-10-24 16:01:20 | c6a98f3 | app2 | brutal | 12109 | 0 | aucune erreur |

## V3 — Montée en charge : ab -n 2000 -c 50 (débit par nombre de serveurs)

| Commit | N serveurs | Passes | Débit médian | Minimum | Maximum |
| --- | --- | --- | --- | --- | --- |
| 3eacb1d | 2 | 3 | 81.18 | 77.61 | 81.92 |
| 3eacb1d | 4 | 6 | 67.13 | 66.03 | 69.31 |

Les VM se partagent le processeur de l'hôte : un débit qui n'augmente pas avec N est un résultat à expliquer, pas à corriger.

## V4 — Panne de la base primaire (critère : 503 propre ; mesure : durée de la bascule)

| Date | Commit | Arrêt | Bascule | Panne visible après | Procédure de bascule | Service indisponible | Codes d'erreur | Témoin retrouvé |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-25 15:55:05 | 4f3db63 | propre | bdd1 → bdd2 | 16.8 s | 36.7 s | 39.8 s | 503:46 | oui |
| 2026-10-25 16:03:25 | 4f3db63 | brutal | bdd2 → bdd1 | 11.9 s | 33.3 s | 41.4 s | 503:43 | oui |

## V5 — Reconstruction complète (vagrant destroy -f puis vagrant up)

| Date | Commit | NB_APP | E1 | Boîte déjà présente | Destruction | vagrant up | Plateforme | Total |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-26 00:20:01 | d9e7c72 | 2 | 1 | oui | 34.3 s | 870.1 s | en échec | 904.4 s |
| 2026-10-26 01:09:50 | d9e7c72 | 2 | 1 | oui | 34.6 s | 901.3 s | validée | 935.9 s |

## V6 — Panne du répartiteur (E1) : même adresse, reprise en moins de 5 s

| Date | Commit | Arrêt | IP virtuelle | Requêtes touchées | Erreurs | Plus lente | Coupure | Reprise | Touchées au retour |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-24 13:36:32 | 336fe6f | propre | lb2 → lb1 | 0 | 0 | 0.02 s | 0.0 s | 0.0 s | 0 |
| 2026-10-24 13:39:45 | 336fe6f | propre | lb1 → lb2 | 1 | 0 | 1.01 s | 1.0 s | 8.0 s | 0 |
| 2026-10-24 13:44:18 | 336fe6f | propre | lb2 → lb1 | 0 | 0 | 0.03 s | 0.0 s | 0.0 s | 0 |
| 2026-10-26 01:59:50 | 05b92b2 | propre | lb1 → lb2 | 1 | 1 | 5.00 s | 5.0 s | 19.1 s | 0 |
| 2026-10-26 02:05:34 | 05b92b2 | propre | lb2 → lb1 | 1 | 1 | 5.00 s | 5.0 s | 19.5 s | 0 |
| 2026-10-26 02:09:00 | 05b92b2 | brutal | lb1 → lb2 | 1 | 0 | 3.02 s | 3.0 s | 13.0 s | 0 |

## E4 — Déploiement sans coupure (critère : aucune requête en erreur)

| Date | Commit | Version | Serveurs | Déploiement | Requêtes (ab) | Échecs | Non 2xx | Erreurs de la sonde | Débit |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-25 00:06:05 | cb4281b | 1.1.0 | 2 | 52.3 s | 4484 | 0 | 0 | 0 | 49.81 |
| 2026-10-25 19:09:24 | 24b0111 | 1.1.0 | 2 | 62.1 s | 2957 | 0 | 0 | 0 | 32.85 |

## Procédures chronométrées (scripts/bascule.sh, scripts/reintegrer.sh)

| Date | Commit | Opération | Machine | Autre base | Mode | Diagnostic | Isolement | Promotion | Reprise du service | Total |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2026-10-25 15:54:55 | 4f3db63 | bascule | bdd2 | bdd1 | panne | 29.0 | 0.2 | 1.7 | 4.7 | 35.7 |
| 2026-10-25 16:00:07 | 4f3db63 | reintegration | bdd1 | bdd2 | - |  |  |  |  | 71.5 |
| 2026-10-25 16:03:15 | 4f3db63 | bascule | bdd1 | bdd2 | panne | 28.7 | 0.2 | 1.3 | 2.0 | 32.2 |
| 2026-10-25 16:04:46 | 4f3db63 | reintegration | bdd2 | bdd1 | - |  |  |  |  | 80.0 |

# RÉSULTATS-BF

Plateforme de consultation des résultats d'examen par matricule, résiliente
et scalable, entièrement décrite en code avec Vagrant et VirtualBox.
Projet de groupe, M1 Informatique, IBAM, Université Joseph Ki-Zerbo (2026-2027).

## Prérequis

| Outil | Version utilisée par le groupe |
| --- | --- |
| VirtualBox | 7.2.20 |
| Vagrant | 2.4.9 |
| Boîte | `bento/ubuntu-24.04`, version 202510.26.0 (téléchargée au premier `vagrant up`) |
| Mémoire libre | 3 Go pour le socle |
| Terminal conseillé sous Windows | Git Bash |

## Démarrage

```bash
git clone <adresse-du-depot> resultats-bf
cd resultats-bf
vagrant up
```

Aucune autre commande n'est nécessaire : le numéro de groupe est versionné dans
`config/groupe` (un nombre de 1 à 20). Au premier lancement, le Vagrantfile
engendre lui-même :

- `config/noeuds.yml` : l'inventaire des machines actives, lu par les scripts ;
- `.env` : les mots de passe, tirés au hasard, jamais versionnés.

Ne supprimez pas `.env` tant que les machines existent : elles utilisent ces mots de passe.

## Paramètres

| Variable | Rôle | Défaut | Valeurs |
| --- | --- | --- | --- |
| `NB_APP` | Nombre de serveurs applicatifs | 2 | 2 à 9 |
| `GROUPE` | Numéro de groupe : sous-réseau `192.168.(55+G).0/24` | contenu de `config/groupe` | 1 à 20 ; l'énoncé prévoit 1 à 8 (§7.1) |

| Terminal | Syntaxe |
| --- | --- |
| Git Bash | `NB_APP=4 vagrant up`, ou `export NB_APP=4` pour toute la session |
| PowerShell | `$env:NB_APP = "4"; vagrant up` |
| Invite de commandes | `set NB_APP=4` puis `vagrant up` |

Gardez la même valeur pour toutes les commandes d'une session : une commande
lancée sans elle (`vagrant provision`, `vagrant destroy -f`…) revient à 2.
Pour ajouter des serveurs, changez `NB_APP` : ne démarrez jamais `app5` à la main.

## Machines du socle

| Machine | Adresse | Rôle |
| --- | --- | --- |
| bdd1 | 192.168.X.31 | PostgreSQL primaire (rôle nominal) |
| bdd2 | 192.168.X.32 | Réplique en flux ; primaire après une bascule |
| app1 … appN | 192.168.X.21 … .2N | Serveurs applicatifs sans état |
| lb1 | 192.168.X.11 | Répartiteur HAProxy |

X = 55 + numéro de groupe. Seul lb1 expose un port vers l'hôte : `localhost:8080`.

## Commandes utiles

| Commande | Effet |
| --- | --- |
| `vagrant status` | État des machines (app3 à app9 restent « not created » tant que `NB_APP` ne les active pas) |
| `vagrant ssh app1` | Ouvre un terminal dans app1 |
| `vagrant provision` | Rejoue le provisionnement : ne doit rien changer (idempotence) |
| `vagrant destroy -f` | **Supprime toutes les machines et leurs données** |
| `bash tests/verifier_socle.sh` | Vérifie le socle (noms, réseau, idempotence, paramètres, secrets) |
| `bash tests/r5_replication.sh` | Preuve de R5 : écriture sur le primaire, lecture sur la réplique |
| `bash tests/verifier_plateforme.sh` | Contrôle de bout en bout : service, JSON, serveurs UP, configuration engendrée |
| `bash tests/v1_repartition.sh` | Scénario V1 : 20 appels à `/info`, écart de répartition |
| `bash tests/v2_panne_app.sh app1 [--brutal]` | Scénario V2 : panne d'un serveur pendant une charge `ab` |
| `bash tests/v4_bascule_bdd.sh [--brutal] [--reintegrer]` | Scénario V4 : panne de la base primaire, bascule chronométrée |
| `bash scripts/bascule.sh [--forcer]` | **Bascule de la base** : promeut la réplique (voir ci-dessous) |
| `bash scripts/reintegrer.sh bdd1` | **Destructif pour bdd1** : la recopie depuis la primaire actuelle et en fait une réplique |

## Base de données

PostgreSQL 16 (paquet Ubuntu). bdd1 est le primaire : elle porte la base
`resultats` (50 000 candidats engendrés par `sql/donnees.sql`, toujours les
mêmes). bdd2 en est une réplique en flux : copiée une fois par `pg_basebackup`,
puis alimentée en continu, en lecture seule. Les données vivent dans
`/var/lib/postgresql`, jamais dans le dossier synchronisé `/vagrant`.

| Rôle PostgreSQL | Droits | Mot de passe (`.env`) |
| --- | --- | --- |
| `app_resultats` | lecture de la table `resultats` | `PG_APP_MDP` |
| `replicateur` | réplication entre bdd1 et bdd2 | `PG_REPLICATION_MDP` |

Consulter la base : `vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats"`.

### Bascule de la base (R6)

Quand la primaire est perdue (`vagrant halt bdd1`, panne…), le service répond
503 en JSON sur `/sante` et `/resultat`. La procédure, chronométrée :

```bash
bash scripts/bascule.sh          # promeut la réplique démarrée (bdd2)
bash scripts/reintegrer.sh bdd1  # plus tard : bdd1 redevient réplique (destructif pour bdd1)
```

`bascule.sh` refuse d'agir si l'ancienne primaire répond encore : deux
primaires recevraient chacune leurs écritures et divergeraient. Avant la
promotion, il **isole** l'ancienne primaire : témoin `.etat/isole-bdd1` (non
versionné) et arrêt de PostgreSQL si la VM tourne. Rallumée, elle garde
PostgreSQL arrêté jusqu'à `reintegrer.sh`. Les serveurs applicatifs ne sont
pas touchés. Les durées vont dans `mesures/bascules.csv`.

Bascule planifiée (retour à bdd1 primaire, par exemple) :
`bash scripts/bascule.sh bdd1 --forcer` puis `bash scripts/reintegrer.sh bdd2`.

PostgreSQL ne démarre plus seul au démarrage d'une VM (`start.conf` à `manual`) :
c'est le provisionnement qui le lance, après avoir vérifié que le nœud n'est
ni isolé ni en concurrence avec une autre primaire. Après un redémarrage hors
Vagrant (interface de VirtualBox, `sudo reboot`), relancez-le avec
`vagrant provision bdd1` (ou `vagrant up`).

## Application

`app/app.py` (Python 3, Flask, moins de 100 lignes), servie par Gunicorn
(3 processus) sur le port 3000 de chaque serveur applicatif. Sans état :
aucune session, aucun fichier, aucun compteur.

| Point d'entrée | Réponse |
| --- | --- |
| `GET /resultat?matricule=BF-2026-000123` | 200 et le résultat en JSON ; 404 si inconnu ; 400 si absent ; 503 si la base est injoignable |
| `GET /sante` | 200 si la base répond vraiment à `SELECT 1`, 503 sinon (sonde du répartiteur) |
| `GET /info` | nom du serveur et version (`app/VERSION`) |

L'application essaie `bdd1` puis `bdd2` et n'accepte que la base qui accepte
les écritures : après une bascule, elle suit la nouvelle primaire sans
reconfiguration. Journal du service : `vagrant ssh app1 -c "journalctl -u resultats -n 30"`.

## Répartiteur

HAProxy sur lb1, port 80. Sa configuration est **engendrée** par `scripts/lb.sh`
à partir de `config/haproxy.cfg.modele` (qui ne contient aucune adresse) et
de la liste des serveurs de `config/noeuds.yml` : `NB_APP=4 vagrant up` suffit
pour ajouter app3 et app4. Chaque serveur est sondé sur `GET /sante` chaque
seconde ; deux échecs l'écartent, deux succès le réintègrent. Une requête
envoyée à un serveur qui tombe est rejouée sur un autre.

| Adresse, depuis l'hôte | Usage |
| --- | --- |
| `http://192.168.X.11/` | Service, par le réseau privé (à utiliser pour mesurer) |
| `http://127.0.0.1:8080/` | Service, par la redirection de port de VirtualBox |
| `http://192.168.X.11:8404/stats` | Page d'état de HAProxy (utilisateur `admin`, mot de passe `HAPROXY_STATS_MDP` de `.env`) |

## Structure du dépôt

```text
Vagrantfile          source unique de vérité : machines, adresses, mémoire
scripts/lib.sh       fonctions communes idempotentes
scripts/commun.sh    provisionnement commun à toutes les machines
scripts/lib_pg.sh    fonctions PostgreSQL (bdd.sh, replique.sh)
scripts/lib_hote.sh  fonctions des scripts lancés sur l'hôte (tests/)
scripts/<rôle>.sh    bdd, replique, app, lb
scripts/bascule.sh   bascule de la base (hôte) ; reintegrer.sh : retour en réplique
scripts/pg_outil.sh  état, arrêt, promotion de PostgreSQL (dans une VM de base)
app/                 application, version, unité systemd
sql/                 schéma et données (idempotents)
config/              modèle HAProxy, numéro de groupe (noeuds.yml est engendré)
tests/               vérifications et scénarios V1 à V6
mesures/             sorties brutes des mesures
docs/                dossier d'architecture, journal de bord, preuves
```

## Avancement

- [x] Étape 1 : socle Vagrant (machines, inventaire engendré, provisionnement commun)
- [x] Étape 2 : PostgreSQL, données et réplication
- [x] Étape 3 : application
- [x] Étape 4 : HAProxy et sonde de santé
- [x] Étape 5 : bascule de la base, isolement et réintégration
- [ ] Étapes suivantes : extensions E1 et E4, mesures

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
| bdd1 | 192.168.X.31 | PostgreSQL primaire |
| bdd2 | 192.168.X.32 | Réplique en flux |
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

## Structure du dépôt

```text
Vagrantfile          source unique de vérité : machines, adresses, mémoire
scripts/lib.sh       fonctions communes idempotentes
scripts/commun.sh    provisionnement commun à toutes les machines
scripts/lib_pg.sh    fonctions PostgreSQL (bdd.sh, replique.sh)
scripts/lib_hote.sh  fonctions des scripts lancés sur l'hôte (tests/)
scripts/<rôle>.sh    bdd, replique, app, lb
sql/                 schéma et données (idempotents)
config/              fichiers de configuration (noeuds.yml est engendré)
tests/               vérifications et scénarios V1 à V6
mesures/             sorties brutes des mesures
docs/                dossier d'architecture, journal de bord, preuves
```

## Avancement

- [x] Étape 1 : socle Vagrant (machines, inventaire engendré, provisionnement commun)
- [x] Étape 2 : PostgreSQL, données et réplication
- [ ] Étape 3 : application
- [ ] Étape 4 : HAProxy et sonde de santé
- [ ] Étapes suivantes : bascule, extensions E1 et E4, mesures

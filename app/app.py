"""RÉSULTATS-BF : consultation d'un résultat d'examen par matricule.

Service SANS ÉTAT (énoncé §3.2) : ni session, ni fichier, ni compteur ; tout
vit dans la base. Configuration par l'environnement (/etc/resultats-bf/app.env),
avec les variables standard de libpq : PGHOST=bdd1,bdd2 (essayées dans l'ordre),
PGDATABASE, PGUSER, PGPASSWORD, PGOPTIONS.
"""
import os
import socket
import threading
import time

import psycopg
from flask import Flask, jsonify, request
from werkzeug.exceptions import HTTPException

app = Flask(__name__)
HOTE = socket.gethostname()
VERSION = os.environ.get("APP_VERSION", "inconnue")
# Échouer vite plutôt que bloquer : une base éteinte ne répond plus du tout.
PARAMETRES_BASE = {
    "target_session_attrs": "read-write",  # n'accepter que la base primaire
    "connect_timeout": 2,                  # secondes, pour CHAQUE hôte essayé
    "tcp_user_timeout": 2000,              # ms : la base disparaît en pleine requête
    "keepalives": 1, "keepalives_idle": 5, "keepalives_interval": 2, "keepalives_count": 2,
    "application_name": f"resultats@{HOTE}",
}
_fil = threading.local()  # une connexion par fil d'exécution, jamais partagée


def _oublier_connexion():
    if getattr(_fil, "cnx", None) is not None:
        _fil.cnx.close()
    _fil.cnx = None


def interroger(sql, parametres=()):
    """Exécute une requête de lecture. Une connexion ANCIENNE qui échoue VITE (base
    redémarrée : connexion fermée) est remplacée une seule fois. Une panne LENTE
    (base disparue, 2 s d'attente) n'est pas retentée : la 503 part en ~2 s, bien
    avant le délai de 5 s du répartiteur. Toute autre erreur remonte."""
    for essai in (1, 2):
        ancienne = getattr(_fil, "cnx", None) is not None and not _fil.cnx.closed
        debut = time.monotonic()
        try:
            if not ancienne:
                _fil.cnx = psycopg.connect(autocommit=True, **PARAMETRES_BASE)
            with _fil.cnx.cursor() as curseur:
                curseur.execute(sql, parametres)
                return curseur.fetchone()
        except psycopg.OperationalError:
            _oublier_connexion()
            if not ancienne or essai == 2 or time.monotonic() - debut > 1:
                raise
        except psycopg.Error:
            _oublier_connexion()
            raise


@app.get("/resultat")
def resultat():
    matricule = request.args.get("matricule", "").strip()
    if not matricule or len(matricule) > 32:
        return jsonify(erreur="matricule_invalide"), 400
    try:
        ligne = interroger("SELECT matricule, nom, serie, moyenne, admis"
                           " FROM resultats WHERE matricule = %s", (matricule,))
    except psycopg.Error as exc:
        app.logger.warning("base indisponible : %s", exc)
        return jsonify(erreur="base_indisponible", serveur=HOTE), 503
    if ligne is None:
        return jsonify(erreur="matricule_inconnu", matricule=matricule), 404
    matricule, nom, serie, moyenne, admis = ligne
    return jsonify(matricule=matricule, nom=nom, serie=serie,
                   moyenne=float(moyenne), admis=admis)


@app.get("/sante")
def sante():
    """Sonde du répartiteur : 200 seulement si la base répond vraiment."""
    try:
        interroger("SELECT 1")
    except psycopg.Error as exc:
        app.logger.warning("sonde /sante : base indisponible : %s", exc)
        return jsonify(etat="indisponible", serveur=HOTE), 503
    return jsonify(etat="ok", serveur=HOTE)


@app.get("/info")
def info():
    """Nom du serveur qui répond : sert à observer la répartition (V1)."""
    return jsonify(serveur=HOTE, version=VERSION)


@app.errorhandler(HTTPException)
def erreur_http(exc):
    """Toute erreur HTTP (404, 405…) en JSON, jamais en page HTML."""
    return jsonify(erreur=exc.name, code=exc.code), exc.code

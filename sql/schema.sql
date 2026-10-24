-- =============================================================================
-- sql/schema.sql — schéma de la base resultats (énoncé §3.2)
-- =============================================================================
-- Idempotent : rejoué à chaque provisionnement sans rien changer (R2).
-- Exécuté par scripts/lib_pg.sh, sur le primaire seulement.
-- =============================================================================

-- Taire les avis « already exists, skipping » des rejeux : seules les vraies
-- erreurs restent dans le journal du provisionnement.
SET client_min_messages = warning;

CREATE TABLE IF NOT EXISTS resultats (
    matricule text          PRIMARY KEY,
    nom       text          NOT NULL,
    serie     text          NOT NULL,
    moyenne   numeric(4, 2) NOT NULL CHECK (moyenne BETWEEN 0 AND 20),
    admis     boolean       NOT NULL
);

-- Preuve de la réplication (R5) : on écrit ici sur le primaire, on relit sur
-- la réplique. Table séparée : les données des candidats ne sont jamais touchées.
CREATE TABLE IF NOT EXISTS preuve_replication (
    id       bigserial   PRIMARY KEY,
    jeton    text        NOT NULL UNIQUE,
    ecrit_le timestamptz NOT NULL DEFAULT now()
);

-- Moindre privilège : seule l'application se connecte à cette base, et elle
-- ne peut que lire la table resultats.
REVOKE ALL ON DATABASE resultats FROM PUBLIC;
GRANT CONNECT ON DATABASE resultats TO app_resultats;
GRANT SELECT ON resultats TO app_resultats;

-- =============================================================================
-- sql/donnees.sql — 50 000 candidats engendrés par generate_series (énoncé §3.2)
-- =============================================================================
-- Déterministe : chaque valeur est calculée à partir du numéro i, sans hasard.
-- Deux reconstructions donnent exactement les mêmes données : les mesures
-- restent comparables d'un essai à l'autre.
-- Idempotent : ON CONFLICT DO NOTHING ignore les matricules déjà présents.
-- Affiche le nombre de lignes réellement insérées (50000, puis 0 au rejeu).
-- =============================================================================

SET client_encoding = 'UTF8';

WITH inserees AS (
    INSERT INTO resultats (matricule, nom, serie, moyenne, admis)
    SELECT
        format('BF-2026-%s', lpad(i::text, 6, '0')),
        (ARRAY['OUEDRAOGO', 'SAWADOGO', 'KABORE', 'ZONGO', 'TRAORE',
               'OUATTARA', 'KONATE', 'NIKIEMA', 'ILBOUDO', 'COULIBALY'])[1 + i % 10]
            || ' ' ||
        (ARRAY['Awa', 'Issa', 'Mariam', 'Boukary', 'Salif', 'Aminata',
               'Rasmané', 'Fatimata', 'Karim', 'Ramatou', 'Adama', 'Safiatou'])[1 + (i * 7) % 12],
        (ARRAY['A4', 'C', 'D', 'E', 'F3', 'G2'])[1 + (i * 13) % 6],
        -- Moyenne de 0,00 à 20,00, répartie sur toute l'échelle.
        round(((i * 7919) % 2001) / 100.0, 2),
        (i * 7919) % 2001 >= 1000
    FROM generate_series(1, 50000) AS i
    ON CONFLICT (matricule) DO NOTHING
    RETURNING 1
)
SELECT count(*) FROM inserees;

-- Statistiques à jour pour le planificateur de requêtes.
ANALYZE resultats;

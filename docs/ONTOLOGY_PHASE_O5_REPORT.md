# Orus Ontology - Rapport de phase O5

Date : 2026-08-15  
Statut : complete

## Perimetre livre

* generation d'IDs objets deterministes avec UUIDv5 ;
* namespace isole par ontologie et type d'objet ;
* cle composite encodee en JSON type et ordonne ;
* normalisation declarative des chaines ;
* canonicalisation des `Decimal`, dates, datetimes et UUID ;
* candidats de correspondance deterministes et symetriques ;
* confiance exacte et version de matcher ;
* preuves par assertions sources ;
* decisions de fusion ou rejet immuables ;
* identite canonique reproductible pour une fusion ;
* conservation explicite de toutes les identites sources.

## Invariants verifies

1. L'ordre des cles du dictionnaire source ne modifie pas l'ID.
2. Deux valeurs equivalentes apres normalisation produisent le meme ID.
3. L'encodage composite ne presente pas de collision de separateur.
4. Une composante manquante, nulle ou vide apres normalisation est refusee.
5. Les datetimes d'identite sont timezone-aware et canonises en UTC.
6. Les valeurs JSON ne peuvent pas participer a une identite.
7. Une candidature relie deux objets distincts dans un ordre canonique.
8. L'ordre gauche/droite ne modifie pas l'ID de candidature.
9. Les scores n'acceptent pas `float` et restent bornes entre 0 et 1.
10. Une fusion conserve les deux IDs sources et cree un ID canonique stable.
11. Un rejet ne cree aucune identite canonique.

## Verification

Execute depuis `python/` :

```text
.venv/bin/python -m ruff check src tests
All checks passed!

.venv/bin/python -m ruff format --check src tests
33 files already formatted

.venv/bin/python -m pyright
0 errors, 0 warnings, 0 informations

.venv/bin/python -m pytest
57 passed
```

## Limites intentionnelles

O5 produit des identites et des decisions, mais ne les stocke pas encore. La
resolution automatique de groupes de plus de deux objets sera construite sur
les decisions persistantes, apres les contrats de stockage O7.

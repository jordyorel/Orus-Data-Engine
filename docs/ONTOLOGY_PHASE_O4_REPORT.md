# Orus Ontology - Rapport de phase O4

Date : 2026-08-15  
Statut : complete

## Perimetre livre

* assertions immuables `observed`, `transformed`, `corrected` et `inferred` ;
* cibles discriminees entre valeur typee et objet ;
* representation non ambigue d'une valeur `null` ;
* valeurs exactes `Decimal`, dates, datetimes, UUID et JSON profondement fige ;
* provenance source avec run, batch, ligne, offset, colonne et transformations ;
* temps d'observation, de validite et d'enregistrement ;
* normalisation UTC obligatoire pour les timestamps techniques ;
* confiance decimale bornee entre 0 et 1 ;
* corrections par supersession sans mutation du fait original ;
* deductions reliees a une regle et a leurs assertions sources.

## Invariants verifies

1. Une assertion cible exactement une valeur ou un objet grace a un
   discriminateur explicite.
2. Une valeur nulle reste distincte de l'absence de cible.
3. Une assertion observee possede une provenance source directe.
4. Une assertion inferee possede un `rule_id` et au moins une assertion source.
5. Une correction reference l'assertion qu'elle remplace sans la modifier.
6. Une provenance reference une ligne ou un offset global.
7. Les IDs de transformations, provenances et assertions sources sont uniques.
8. Les datetimes techniques sont timezone-aware et normalises en UTC.
9. `recorded_at` n'est pas anterieur a `observed_at`.
10. `valid_from` n'est pas posterieur a `valid_to`.
11. Les floats sont refuses pour les valeurs decimales et la confiance.
12. La serialisation JSON preserve les UUID, dates et `Decimal` au round-trip.

## Structure ajoutee

```text
python/src/orus_ontology/assertions/
|- __init__.py
|- assertion.py
|- provenance.py
`- temporal.py

python/tests/assertions/
|- test_assertion.py
|- test_provenance.py
`- test_temporal.py
```

## Verification

Execute depuis `python/` :

```text
.venv/bin/python -m ruff check src tests
All checks passed!

.venv/bin/python -m ruff format --check src tests
28 files already formatted

.venv/bin/python -m pyright
0 errors, 0 warnings, 0 informations

.venv/bin/python -m pytest
49 passed
```

## Limites intentionnelles

O4 definit les faits et leur histoire, mais ne materialise pas encore
`ObjectInstance` ou `RelationInstance` et ne les persiste pas. La generation
d'identites deterministes appartient a O5 ; le mapping et la materialisation
streaming appartiennent a O6 ; le stockage et les requetes appartiennent a O7.

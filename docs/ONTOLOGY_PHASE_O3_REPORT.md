# Orus Ontology - Rapport de phase O3

Date : 2026-08-15  
Statut : complete

## Perimetre livre

* registre de brouillon transactionnel ;
* publication de snapshots profondement immuables ;
* lecture de l'historique par version ;
* remplacement de types par ID sans alias de nom obsolete ;
* comparaison deterministe de versions consecutives ;
* classification des changements compatibles et incompatibles ;
* plans de migration immuables ;
* couverture exacte obligatoire de chaque chemin incompatible ;
* conservation des migrations acceptees avec l'historique.

## Politique de compatibilite

Sont notamment incompatibles : suppression ou renommage d'un type, changement
d'identite, suppression ou renommage d'une propriete, changement de type ou de
cardinalite, ajout d'une propriete obligatoire sans valeur par defaut, et
modification structurelle d'une relation.

Les assouplissements de nullabilite, obligation ou unicite sont compatibles.
Les changements de contraintes sont traites conservativement comme
incompatibles.

## Invariants verifies

1. Une inscription invalide ne modifie pas le brouillon courant.
2. Une version publiee ne partage aucune collection mutable avec l'appelant.
3. Les recherches par nom et par UUID retournent la meme definition courante.
4. Une evolution compatible refuse un plan de migration inutile.
5. Une evolution incompatible refuse l'absence de migration.
6. Une migration cible la bonne ontologie et deux versions consecutives.
7. Les chemins de migration correspondent exactement aux ruptures detectees.
8. Un diff ne peut pas etre calcule sur des versions non publiees.

## Verification

Execute depuis `python/` :

```text
.venv/bin/python -m ruff check src tests
All checks passed!

.venv/bin/python -m ruff format --check src tests
21 files already formatted

.venv/bin/python -m pyright
0 errors, 0 warnings, 0 informations

.venv/bin/python -m pytest
35 passed
```

## Limites intentionnelles

Un `MigrationPlan` declare comment traiter une rupture de schema, mais ne
reecrit aucune donnee : les instances et le stockage ne sont pas encore dans le
perimetre. L'execution de migrations sera branchee lorsqu'un backend persistant
existera. O3 garantit des maintenant qu'aucune rupture ne soit publiee sans
decision explicite et auditable.

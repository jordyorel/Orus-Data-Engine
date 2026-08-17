# Orus Ontology - Rapport de phase O6

Date : 2026-08-15  
Statut : complete

## Perimetre livre

* contrats sources versionnes et types ;
* definitions declaratives de mapping serialisables ;
* mappings d'objets, proprietes et relations ;
* transformations `trim`, `lowercase` et `uppercase` ;
* compilateur resolvant tous les noms avant execution ;
* verification des versions d'ontologie et de contrat source ;
* verification de compatibilite des types et des extremites de relations ;
* plan d'execution profondement immutable ;
* instances d'objets et de relations typees ;
* assertions deterministes avec provenance colonne et transformation ;
* materialisation atomique par enregistrement ;
* politiques explicites `reject` et `quarantine` ;
* consommation paresseuse par batches de taille fixe.

## Invariants verifies

1. Seule une ontologie publiee peut etre compilee.
2. Les versions de schema, mapping et contrat source correspondent exactement.
3. Toutes les proprietes d'identite sont mappees avant execution.
4. Les champs sources et proprietes cibles sont resolus avant le chemin chaud.
5. Les types source et cible sont compatibles.
6. Les aliases d'une relation correspondent a ses types source et cible.
7. Les champs inconnus ou invalides ne sont jamais ignores silencieusement.
8. Tout le contrat source est valide, y compris les champs non materialises.
9. Une ligne invalide ne produit aucun objet ou relation partiel.
10. `reject` arrete le traitement et `quarantine` conserve l'erreur et la ligne.
11. Un batch ne contient jamais plus que le nombre d'entrees configure.
12. Le generateur ne lit pas le batch suivant avant consommation du courant.
13. Les IDs objets, relations et assertions sont reproductibles pour un meme
    run et une meme observation.
14. Une valeur par defaut produit une assertion transformee et `default@1` dans
    sa provenance.
15. Les relations non dirigees utilisent un ordre canonique des extremites.

## Structure ajoutee

```text
python/src/orus_ontology/
|- mapping/
|  |- definition.py
|  |- compiler.py
|  `- plan.py
`- materialization/
   |- batch.py
   |- object_materializer.py
   `- relation_materializer.py

python/tests/
|- mapping/test_compiler.py
`- materialization/test_materializer.py
```

## Verification

Execute depuis `python/` :

```text
.venv/bin/python -m ruff check src tests
All checks passed!

.venv/bin/python -m ruff format --check src tests
44 files already formatted

.venv/bin/python -m pyright
0 errors, 0 warnings, 0 informations

.venv/bin/python -m pytest
69 passed
```

## Capacite et limites

La memoire de materialisation depend de `batch_size`, du nombre de mappings par
ligne et du nombre maximal de valeurs d'une propriete multiple ; elle ne depend
pas du nombre total de lignes du dataset. Les objets produits restent en memoire
uniquement pendant le batch courant.

O6 ne persiste pas encore les resultats et n'applique pas l'unicite globale ou
les cardinalites entre plusieurs batches. Ces garanties necessitent les
contrats et backends de stockage de O7.

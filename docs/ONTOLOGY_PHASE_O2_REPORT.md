# Orus Ontology - Rapport de phase O2

Date : 2026-08-15  
Statut : complete

## Perimetre livre

* types semantiques `string`, `integer`, `decimal`, `boolean`, `date`,
  `datetime`, `enum`, `reference` et `json` ;
* `PropertyType` et contraintes locales ;
* `IdentitySpec` declaratif sans generation anticipee ;
* `ObjectType` avec identite structurellement validee ;
* `RelationType` avec cardinalite et extremites typees ;
* `OntologyDefinition` et validation des references croisees ;
* serialisation JSON aller-retour avec conservation des UUID ;
* API publique limitee aux contrats implementes.

## Invariants verifies

1. Les noms techniques commencent par une lettre et ne contiennent que des
   lettres, chiffres ou underscores.
2. Une identite contient des proprietes declarees, obligatoires et non nulles.
3. Les noms et IDs de proprietes sont uniques.
4. Les IDs de proprietes sont uniques dans toute une ontologie.
5. Les noms et IDs de types sont uniques par categorie.
6. Les extremites d'une relation existent dans la meme ontologie.
7. Une propriete `reference` cible un `ObjectType` existant.
8. Les contraintes enum, textuelles et numeriques correspondent au type de la
   propriete.
9. Les valeurs decimales exactes ne passent pas par `float`.
10. Les collections de schema sont des tuples.
11. Les metadata sont copiees, profondement figees et limitees au JSON strict.
12. Une mutation de l'entree fournie par l'appelant ne modifie pas le modele.

## Structure ajoutee

```text
python/src/orus_ontology/
|- _schema.py
|- identity/
|  |- __init__.py
|  `- spec.py
`- metamodel/
   |- __init__.py
   |- value_type.py
   |- property_type.py
   |- object_type.py
   |- relation_type.py
   |- ontology.py
   `- validator.py

python/tests/metamodel/
|- test_property_type.py
|- test_object_type.py
`- test_ontology.py
```

## Verification

Execute depuis `python/` :

```text
.venv/bin/python -m ruff check src tests
All checks passed!

.venv/bin/python -m ruff format --check src tests
16 files already formatted

.venv/bin/python -m pyright
0 errors, 0 warnings, 0 informations

.venv/bin/python -m pytest
26 passed
```

## Limites intentionnelles

O2 ne publie ni ne migre encore les schemas. Le statut et la version sont des
donnees validees, mais leurs transitions seront controlees par le registre de
la phase O3. Les IDs deterministes, la resolution d'entites et les instances ne
font pas partie de cette phase.

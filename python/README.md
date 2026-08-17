# Orus Ontology v1

Couche semantique versionnee d'Orus Data Engine. Le coeur fournit schemas,
mapping, materialisation, stockage, requetes et raisonnement borne.

## Installation

```sh
python -m pip install -e .
python -m pip install -e '.[postgres]'
```

Psycopg est optionnel tant que `PostgresStore` et le vertical de production ne
sont pas utilises.

## Compatibilite

`orus_ontology.compatibility.compatibility_manifest()` publie les versions du
contrat JSONL et du schema de stockage ainsi que les empreintes de l'ontologie
et du mapping Customer. Toute modification de ces empreintes exige une version
ou migration explicite.

## Import Customer

Voir `docs/ONTOLOGY_CUSTOMERS_VERTICAL_REPORT.md` pour la commande complete,
les checkpoints, les limites de disque et les resultats du test 100 000 lignes.

## Requetes

`QueryService` impose des limites. Les recherches `equals` sont poussees vers
l'index du backend ; voisinages et traversees exigent egalement une limite et
une profondeur explicites. Il ne faut jamais charger le graphe complet pour le
visualiser.

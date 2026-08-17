# Orus Ontology API

Service HTTP autonome de consultation bornee de l'ontologie. Il depend du
package `orus-ontology`, mais l'ontologie ne depend jamais de FastAPI.

```sh
../../scripts/pilotage.sh setup-api
../../scripts/pilotage.sh api-dev
```

Documentation interactive : `http://127.0.0.1:8080/docs`.

L'API ne propose aucune route de chargement du graphe complet. Les recherches,
voisinages et traversees imposent des limites explicites.

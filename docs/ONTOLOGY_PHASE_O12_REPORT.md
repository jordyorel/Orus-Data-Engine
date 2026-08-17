# Orus Ontology - Rapport de phase O12

Date : 2026-08-15  
Statut : complete

## Perimetre livre

L'API est un troisieme composant autonome du monorepo :

```text
Orus Data Engine (Zig) -> Orus Ontology (Python) -> Ontology API (FastAPI)
```

Elle possede son propre `pyproject.toml`, son environnement virtuel, ses tests,
ses controles Ruff/Pyright et son point d'entree Uvicorn. La dependance va de
`orus-ontology-api` vers `orus-ontology`; le coeur ontologique ne connait pas
FastAPI.

## Contrat HTTP v1

| Methode | Route | Limite |
|---|---|---:|
| GET | `/health/live` | aucun acces stockage |
| GET | `/health/ready` | connexion et statistiques |
| GET | `/v1/statistics` | cinq cardinalites |
| POST | `/v1/objects/search` | 200 objets, 8 filtres |
| GET | `/v1/objects/{id}` | 500 assertions, 500 provenances |
| GET | `/v1/objects/{id}/neighbors` | 200 voisins |
| POST | `/v1/traversals` | profondeur 4, 500 objets |

Aucune route ne permet de lire tout le graphe. Les objets absents retournent
404, les requetes invalides 400 ou 422, et les erreurs de stockage 503.

## Verification reelle

Le service a ete lance sur `127.0.0.1:8080` contre le cluster local contenant
les 10 000 premieres lignes de `customers-2000000.csv`.

```text
readiness   ready
schemas     1
objects     29 183
relations   20 000
assertions  60 000
```

La recherche HTTP de `customer_id = 4962FDBE6BFEE6D` a retourne l'objet
Customer deterministe, ses quatre assertions (`customer_id`, `first_name`,
`last_name`, `subscription_date`) et la provenance de la ligne globale 0. Les
routes de voisinage et traversee sont testees sur `OWNS_EMAIL` et `WORKS_FOR`.

## Qualite

* 10 tests HTTP isoles passes ;
* 1 test d'integration PostgreSQL passe ;
* Ruff passe ;
* Pyright strict passe sans erreur ;
* OpenAPI est genere par FastAPI sous `/docs` et `/openapi.json` ;
* pilotage ajoute dans `scripts/pilotage.sh` et `PILOTAGE.md`.

## Limites et suite

Une connexion PostgreSQL est ouverte par requete. Ce choix est correct pour le
POC et evite le partage implicite d'une connexion entre workers. Avant une mise
en production concurrente, un benchmark de charge devra justifier et
dimensionner un pool de connexions.

L'authentification, les quotas par client et CORS ne sont pas actives tant que
l'API reste locale. Elles sont obligatoires avant toute exposition reseau.

La prochaine phase est l'explorateur visuel. Il devra consommer uniquement ces
routes bornees, rechercher un point de depart puis etendre le graphe
progressivement. Il ne devra jamais charger la base complete.

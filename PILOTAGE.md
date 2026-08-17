# Pilotage et tests

Ce document est le point d'entree operateur du depot. Toutes les commandes se
lancent depuis la racine `orus_data_engine`. Le script ne contient aucune
logique metier : il orchestre les interfaces Zig et Python existantes.

## 1. Preparation initiale

Prerequis : Zig 0.16, Python 3.12 ou plus recent et PostgreSQL pour les tests
de persistance.

```sh
chmod +x scripts/pilotage.sh
./scripts/pilotage.sh setup
./scripts/pilotage.sh setup-api
./scripts/pilotage.sh setup-web
./scripts/pilotage.sh setup-control
./scripts/pilotage.sh setup-studio
./scripts/pilotage.sh build
```

Afficher a tout moment les commandes et variables disponibles :

```sh
./scripts/pilotage.sh help
```

## 2. Validation du socle

Lancer toute la qualite locale sans PostgreSQL :

```sh
./scripts/pilotage.sh test
```

Les controles peuvent aussi etre lances separement :

```sh
./scripts/pilotage.sh test-zig
./scripts/pilotage.sh test-python
./scripts/pilotage.sh check
```

Le resultat actuel hors PostgreSQL est : tests Zig Debug et ReleaseSafe passes,
89 tests Python passes, 15 integrations ignorees, `zig fmt`, Ruff et Pyright
sans erreur, ainsi que les tests et controles propres a l'API. Les 104 tests
ontologiques passent lorsque PostgreSQL et le binaire Zig sont fournis aux
integrations. Le nombre de tests peut augmenter au fil du developpement.

## 3. Benchmark du moteur Zig

Le benchmark parcourt les 2 millions de lignes sans creer de sortie durable :

```sh
./scripts/pilotage.sh benchmark-csv
```

Changer la taille de batch :

```sh
BATCH_SIZE=8192 ./scripts/pilotage.sh benchmark-csv
```

La reference actuelle sur `fixtures/customers-2000000.csv` est 2 000 000 de
lignes, 349 416 788 octets, aucune valeur invalide et environ 25 Mio de pic RSS.
Le debit depend de la machine et du cache disque.

## 4. Benchmark de materialisation ontologique

Ce test utilise les donnees reelles mais ne requiert pas PostgreSQL :

```sh
./scripts/pilotage.sh benchmark-ontology
SAMPLE_ROWS=100000 ./scripts/pilotage.sh benchmark-ontology
```

Il mesure le transport JSONL, la materialisation Python et la memoire. Une
execution avec tracemalloc est volontairement plus lente qu'un import normal.

## 5. PostgreSQL

Demarrer le serveur local dedie au projet :

```sh
./scripts/pilotage.sh postgres-start
./scripts/pilotage.sh postgres-status
```

Au premier lancement, le script initialise un cluster dans
`.zig-cache/orus-postgres`, puis ecoute uniquement sur le socket local `/tmp`,
port `55439`. Ce cluster est independant de toute base PostgreSQL deja installee
sur la machine. La connexion par defaut est :

```sh
host=/tmp port=55439 dbname=postgres
```

Il n'est donc pas necessaire d'exporter `POSTGRES_DSN` pour le serveur local.
Pour utiliser un autre serveur, definir explicitement la connexion et son port :

```sh
export POSTGRES_PORT=5432
export POSTGRES_DSN='host=localhost port=5432 dbname=orus user=orus'
```

Le connecteur Zig a un test distinct qui attend le port fixe `55432` :

```sh
./scripts/pilotage.sh test-postgres-zig
```

Le message `postgres rows=20000 batches=20 bytes=...` est la sortie reussie du
test, pas une commande a saisir ensuite.

Tester le backend ontologique Python sur `POSTGRES_DSN` :

```sh
./scripts/pilotage.sh test-postgres-python
```

## 6. API ontologique

L'API possede son propre package et son propre environnement sous
`apps/ontology-api`. Avec PostgreSQL demarre et les donnees importees :

```sh
./scripts/pilotage.sh setup-api
./scripts/pilotage.sh api-dev
```

L'API ecoute par defaut sur `http://127.0.0.1:8080`. Les interfaces utiles sont :

```text
GET  /health/live
GET  /health/ready
GET  /v1/statistics
POST /v1/objects/search
GET  /v1/objects/{object_id}
GET  /v1/objects/{object_id}/neighbors
POST /v1/traversals
GET  /docs
```

Lancer ses tests isoles puis son integration sur les donnees PostgreSQL :

```sh
./scripts/pilotage.sh test-api
./scripts/pilotage.sh test-api-postgres
```

## 7. Orus Studio

Le parcours produit principal utilise le Control Plane et Orus Studio :

```sh
./scripts/pilotage.sh control-dev
./scripts/pilotage.sh studio-dev
```

Ouvrir `http://127.0.0.1:5174`, creer un projet, importer un CSV puis lancer
`Profile data`. Les fichiers, rapports et metadonnees locales sont conserves
dans `.orus-control`.

Le Control Plane refuse par defaut les fichiers superieurs a 10 Go et interrompt
un profilage apres 6 heures. Ces limites sont configurables avant le lancement :

```sh
export ORUS_CONTROL_MAX_UPLOAD_BYTES=10737418240
export ORUS_CONTROL_PROFILE_TIMEOUT_SECONDS=21600
```

```sh
./scripts/pilotage.sh test-control
./scripts/pilotage.sh build-studio
```

## 8. Explorateur visuel

Le frontend autonome se trouve dans `web/ontology-explorer`. Demarrer les trois
processus dans trois terminaux :

```sh
./scripts/pilotage.sh postgres-start
./scripts/pilotage.sh api-dev
./scripts/pilotage.sh web-dev
```

Ouvrir `http://127.0.0.1:5173`. L'explorateur recherche un Customer par son
identifiant, charge son contexte, puis etend uniquement les voisinages demandes.

```sh
./scripts/pilotage.sh test-web
./scripts/pilotage.sh build-web
```

## 9. Import Customer borne

Commencer par 10 000 lignes :

```sh
./scripts/pilotage.sh postgres-start
./scripts/pilotage.sh import-sample
./scripts/pilotage.sh ontology-stats
```

Changer la limite sans modifier le script :

```sh
SAMPLE_ROWS=100000 ./scripts/pilotage.sh import-sample
```

L'import est idempotent avec le meme `RUN_ID` et le meme instant
d'observation. Il est donc normal qu'une seconde execution annonce zero
nouvelle insertion pour les lignes deja materialisees.

## 10. Import des 2 millions de lignes

Attention : la projection mesuree est d'environ 33 Gio et il faut conserver une
marge d'au moins 45 Gio pour PostgreSQL. Verifier l'espace libre affiche par le
script avant de laisser continuer l'import.

```sh
./scripts/pilotage.sh postgres-start
./scripts/pilotage.sh import-full
```

Le checkpoint est ecrit dans
`.zig-cache/customers-2m.checkpoint.json`. Apres une interruption, relancer
exactement la meme commande reprend au dernier batch commite. Ne pas modifier
`RUN_ID`, `OBSERVED_AT`, le fichier source ou le chemin du checkpoint pendant
une reprise.

Suivre les cardinalites depuis un autre terminal :

```sh
./scripts/pilotage.sh ontology-stats
```

Projection attendue a la fin : environ 5,16 millions d'objets, 4 millions de
relations et 12 millions d'assertions. Ce sont des estimations, notamment parce
que les entreprises et adresses sont dedupliquees.

## 11. Variables utiles

```text
POSTGRES_DSN   Connexion PostgreSQL, par defaut le serveur local du projet
POSTGRES_PORT  Port local verifie par le script, par defaut 55439
POSTGRES_DATA  Cluster local, par defaut .zig-cache/orus-postgres
CUSTOMERS_CSV  Fichier CSV, par defaut fixtures/customers-2000000.csv
SAMPLE_ROWS    Limite des tests bornes, par defaut 10000
BATCH_SIZE     Taille des batches, par defaut 2048
CHECKPOINT     Checkpoint de l'import complet
PYTHON_BOOTSTRAP  Executable Python >= 3.12 utilise par setup
RUN_ID         Identifiant stable de l'execution
OBSERVED_AT    Instant ISO 8601 stable de l'observation
```

Les resultats de reference et leur interpretation sont detailles dans
`docs/BENCHMARK.md`, `docs/ONTOLOGY_PHASE_O11_REPORT.md` et
`docs/ONTOLOGY_CUSTOMERS_VERTICAL_REPORT.md`.

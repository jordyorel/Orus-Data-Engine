# Cas vertical Customer sur donnees reelles

Date : 2026-08-15  
Statut : pret pour l'import des 2 000 000 lignes

## Contrat livre

Le vertical possede des UUID stables pour l'ontologie, les types, proprietes,
relations et le mapping. Les douze colonnes CSV sont renommees explicitement a
la frontiere ; aucune colonne inconnue ou manquante n'est ignoree.

```text
Customer(customer_id, first_name, last_name, subscription_date)
EmailAddress(address)
Company(name)

Customer -[OWNS_EMAIL]-> EmailAddress
Customer -[WORKS_FOR]-> Company
```

Les dates physiques Zig sont emises en ISO 8601. Les IDs Customer, EmailAddress
et Company sont deterministes et les valeurs Email/Company sont normalisees
avant calcul d'identite.

## Import

```sh
cd python
.venv/bin/python -m orus_ontology.vertical \
  ../fixtures/customers-2000000.csv \
  --postgres "host=/tmp port=55439 dbname=postgres" \
  --engine ../zig-out/bin/orusdata \
  --run-id dca43ce5-0fd8-5cbc-b9d7-8a2527f50fde \
  --observed-at 2026-08-15T12:00:00+00:00 \
  --batch-size 2048 \
  --checkpoint ../.zig-cache/customers-2m.checkpoint.json
```

Pour un essai borne, ajouter `--max-rows 10000`. Une relance avec le meme
fichier, run ID et checkpoint reprend a l'offset commite. Changer l'un de ces
elements est refuse.

## Verification effectuee

Le test d'integration rapide verifie reprise en deux executions, deduplication,
date typee, lookup par `customer_id`, provenance et deux voisins sortants. Le
test de volume sur les 100 000 premieres lignes confirme les cardinalites et
la lecture du contexte complet d'un client reel.

Le fichier de 2 millions n'a pas ete importe integralement pendant O11 afin de
ne pas consommer automatiquement environ 33 a 45 Gio du disque utilisateur.
Le chemin, les checkpoints et les limites necessaires a ce lancement sont
cependant verifies sur 100 000 lignes reelles.


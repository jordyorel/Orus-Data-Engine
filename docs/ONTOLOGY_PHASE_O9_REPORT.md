# Orus Ontology - Rapport de phase O9

Date : 2026-08-15  
Statut : complete

## Perimetre livre

* backend synchrone PostgreSQL avec Psycopg 3 optionnel ;
* migration SQL versionnee, verrou advisory et checksum immuable ;
* tables pour schemas, objets, relations, assertions et resolutions ;
* documents JSONB canoniques pour reconstruire exactement les modeles ;
* cles et colonnes relationnelles pour les recherches et l'integrite ;
* index objets par type, relations par extremite/type et assertions par sujet ;
* transactions atomiques pour objets, relations et batches d'assertions ;
* ecritures idempotentes et collisions de contenu refusees ;
* meme suite contractuelle que `MemoryStore` ;
* test de fermeture, reconnexion et relecture du graphe.

## Invariants verifies

1. Un schema publie precede toute instance.
2. Les cles etrangeres protegent schemas et extremites de relations.
3. Une ecriture d'agregat inclut ses assertions dans la meme transaction.
4. Un batch contenant une assertion invalide ne persiste aucun prefixe.
5. Rejouer un document identique est idempotent ; changer son contenu echoue.
6. Une migration appliquee ne peut pas changer de checksum silencieusement.
7. Deux initialiseurs concurrents sont serialises pendant les migrations.
8. La fermeture du processus ne supprime aucun objet, relation ou assertion.

## Verification PostgreSQL

La suite a ete executee contre une instance PostgreSQL locale isolee : tous les
tests contractuels passent sur memoire et PostgreSQL, et le test de reconnexion
reconstruit les modeles Pydantic a l'identique.

## Limites

Le store utilise une connexion synchrone possedee par instance. Le pooling,
les replicas, la haute disponibilite et le partitionnement sont des choix de
deploiement a mesurer en O11, pas des garanties implicites de ce backend.


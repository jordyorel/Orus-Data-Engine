# Orus Ontology - Rapport de phase O7

Date : 2026-08-15  
Statut : complete

## Perimetre livre

* contrats separes pour schemas, objets, relations et resolutions ;
* backend memoire de reference sans dependance externe ;
* ecritures idempotentes et collisions refusees ;
* validation des schemas publies, types et extremites de relations ;
* recherche par type et proprietes avec pagination explicite ;
* historique d'assertions et exclusion des assertions remplacees ;
* voisinage entrant, sortant ou bidirectionnel ;
* traversee multi-sauts bornee a 16 sauts et 10 000 resultats ;
* provenance dedupliquee et resolution de l'identite canonique.

## Invariants verifies

1. Aucune instance n'est stockee sans son schema publie.
2. Une identite existante ne peut pas etre reecrite avec un contenu different.
3. Une relation ne peut pas pointer vers une extremite absente ou de mauvais type.
4. Une correction ne peut pas remplacer une assertion inconnue.
5. Chaque filtre public est applique et teste.
6. Les pages, historiques, voisinages et traversees ont une limite explicite.
7. Les cycles ne provoquent pas d'expansion non bornee.

## Limites

`MemoryStore` est reserve aux tests et POC bornes. Son volume resident augmente
avec le nombre d'objets, relations et assertions. La persistance et les index de
production restent le perimetre de O9.


# Orus Ontology - Rapport de phase O8

Date : 2026-08-15  
Statut : complete

## Perimetre livre

* commande Zig `export-jsonl` sur le pipeline CSV type existant ;
* enveloppe JSONL `contract_version: 1` avec record, source et run ;
* validation stricte des versions, tailles de ligne et metadonnees ;
* conversion en `CanonicalRecord` immutable ;
* bridge subprocess sans shell et consommation progressive de `stdout` ;
* drainage concurrent et borne de `stderr` ;
* backpressure naturelle par pipe ;
* statuts `running`, `complete` et `failed` ;
* invalidation explicite de tout prefixe emis lorsque le processus echoue.

## Cas vertical verifie

Une fixture CSV de deux clients traverse le binaire Zig reel avec un batch de
taille 1. Python valide les deux enveloppes puis materialise quatre objets et
deux relations. Les assertions obtenues conservent `source_id`, ligne, batch,
offset global, run et instant d'observation.

## Limites

JSONL reste le contrat initial, portable et inspectable. Son cout de parsing et
sa bande passante devront etre mesures en O11 avant une decision Arrow IPC ou
ABI native. Un consommateur ne doit persister un run qu'apres `records_valid` ;
un run incomplet est invalide meme si certains records ont deja ete emis.


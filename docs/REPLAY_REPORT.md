# Provenance rejouable

Date: 2026-08-08  
Statut: blocker v1 ferme

## Contrat

Chaque entree d'audit contient une version de format, l'identite du run et de
la source, le batch, la plage globale, les hashes de schemas et une liste
ordonnee de `TransformSpec`. Une spec conserve l'identifiant, la version, le
nom de colonne, l'operation et les parametres exacts.

Le hash canonique encode entiers et longueurs en little-endian. Il est stable
entre architectures et verifie avant toute transformation.

`ReplayReader` lit une entree par batch, impose une taille maximale de record
et un nombre maximal de transforms, puis utilise un double buffer d'arenas et
un scratch reutilise. Il rejette les audits tronques, supplementaires,
incompatibles ou alteres.

## Utilisation

```sh
orusdata replay source.csv output.csv.audit.jsonl replayed.csv [batch_size]
```

Le round-trip de verification est :

```sh
orusdata clean fixtures/csv/replay.csv cleaned.csv name trim 2
orusdata replay fixtures/csv/replay.csv cleaned.csv.audit.jsonl replayed.csv 2
cmp cleaned.csv replayed.csv
```

La comparaison est identique octet par octet sur plusieurs batches.

## Verification

- audit versionne et parametres canoniques ;
- registre avec validation de version ;
- replay streaming et memoire bornee ;
- rejet d'un audit termine trop tot ;
- 17 tests d'integration passent ;
- Debug, ReleaseSafe, ReleaseFast et PostgreSQL passent.

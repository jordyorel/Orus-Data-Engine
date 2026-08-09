# Phase 11 - Connecteurs et sinks supplementaires

Date: 2026-08-08  
Toolchain: Zig 0.16.0  
Statut: complete dans le perimetre de la roadmap

## JSON Lines

`JsonlSource` lit un objet JSON plat par ligne avec des buffers reutilises. Le
schema est infere sur le premier objet et les lignes suivantes doivent rester
compatibles. Les objets imbriques sont rejetes explicitement. Les limites
`batch_size` et `max_record_bytes` bornent le travail en memoire.

`JsonlSink` preserve les nombres, booleens, nulls et chaines JSON. Les decimals
sont ecrits comme chaines pour ne perdre aucune precision. Les dates et
datetimes utilisent leur representation physique entiere actuelle.

Benchmark sur `customers-2000000.csv` :

| Mesure | Resultat |
|---|---:|
| Lignes | 2 000 000 |
| Taille JSONL | 644 085 001 octets |
| Ecriture | 432 255 lignes/s |
| Lecture | 504 954 lignes/s |
| Temps ecriture | 4,627 s |
| Temps lecture | 3,961 s |

Commande : `zig build bench-jsonl`.

## PostgreSQL

`PostgresSource` repose sur `libpq` et active le mode single-row avant de lire
les resultats. Une ligne seulement est detenue par libpq, puis les lignes sont
copiees dans le batch colonnaire courant. Les OID booleens, entiers et flottants
sont types ; les autres types restent des chaines afin d'eviter une conversion
implicite avec perte.

La chaine de connexion n'est ni conservee comme URI ni exposee par l'identite.
Le nom public de source est configure separement. `lastError()` fournit le
diagnostic libpq emprunte lorsque l'appelant en a besoin.

Le connecteur est optionnel pour conserver un binaire de base sans dependance
PostgreSQL :

```sh
zig build -Dpostgres=true test-postgres
```

Le test reel execute sur PostgreSQL 18 lit 20 000 lignes en 20 batches et
mesure 444 278 octets de valeurs.

## Sinks

- `JsonlSink` : sortie fichier progressive avec buffer de 64 KiB ;
- `MemorySink` : resultat stable pour tests/petits jeux, avec limites dures de
  lignes et de charge utile ;
- `NullSink` et `CsvSink` restent disponibles.

## Formats binaires

Arrow et Parquet sont deliberement reportes. Leur ajout impose de choisir un
contrat d'interoperabilite, une dependance maintenue et une strategie de
deploiement statique. Aucun critere v1.0 actuel ne les exige.

## Limites connues

- JSONL accepte uniquement les objets plats ;
- un premier champ JSON `null` est infere comme chaine ;
- PostgreSQL execute une requete textuelle fournie par l'appelant et n'ajoute
  pas de construction SQL ;
- `libpq` doit etre installe uniquement pour les builds `-Dpostgres=true` ;
- aucun benchmark PostgreSQL distant n'est fourni, car le reseau et le serveur
  domineraient la mesure du connecteur.

## Verification

- `zig fmt --check build.zig src tests benchmarks` : passe ;
- `zig build test` : passe, 15 tests d'integration ;
- `zig build -Doptimize=ReleaseSafe test` : passe ;
- `zig build -Doptimize=ReleaseFast` : passe ;
- `zig build bench-jsonl` : passe ;
- `zig build -Dpostgres=true test-postgres` : passe sur PostgreSQL 18.

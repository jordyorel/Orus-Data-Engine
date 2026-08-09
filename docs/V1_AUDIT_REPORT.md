# Audit de readiness v1.0

Date: 2026-08-08  
Toolchain: Zig 0.16.0  
Verdict: **NON PRET POUR UNE RELEASE v1.0**

## Resume executif

Le socle de calcul est solide et les gates de compilation passent. Le moteur
lit, type, profile, valide, nettoie et rapproche des donnees en streaming avec
une memoire bornee. Apres fermeture du replay, 15 criteres v1.0 sont satisfaits
et 2 restent partiels.

La release reste bloquee par deux garanties de donnees : les sinks fichier ne
sont pas atomiques et l'identite d'une source ne versionne pas son contenu. La
CLI n'expose par ailleurs qu'une partie des capacites de la bibliotheque.

## Findings

### [RESOLU] La provenance est rejouable

Le format d'audit conserve des `TransformSpec` canoniques et versionnes, leur
ordre, la colonne cible et les parametres. `ReplayReader` consomme source et
audit en streaming, verifie run, source, batch, plages, parametres et schemas,
puis rejoue les transforms avec des arenas bornees. Le test multi-batch et la
commande CLI `replay` reproduisent le CSV nettoye octet par octet.

### [P1] Les sorties CSV, JSONL et audit peuvent rester partielles

`CsvSink.open`, `JsonlSink.open` et `AuditLog.open` tronquent directement la
destination. `abort` marque seulement le sink ferme et ne retire pas le fichier
partiel. Une erreur de parsing, de transformation, de disque ou de flush peut
donc detruire une destination valide ou laisser une sortie presentee comme
utilisable. L'exigence P-001 de la roadmap declare deja ce point bloquant avant
production.

Correction requise : fichier temporaire sur le meme volume, flush/sync, rename
atomique, preservation de la destination existante et tests d'injection
d'erreur pour `write`, `finish` et `abort`.

### [P1] L'identite de source ne distingue pas deux contenus au meme chemin

CSV et JSONL calculent `source_id` a partir du chemin uniquement. `version` et
`content_hash` restent a zero. Un fichier remplace au meme emplacement produit
donc la meme identite et les memes RowId, ce qui affaiblit la provenance, le
replay et l'audit de correspondances.

Correction requise : politique versionnee d'identite, au minimum metadata
stable plus hash de contenu calcule en streaming, et propagation de
`source_version` dans chaque `BatchMetadata`.

### [P2] La CLI n'expose pas le moteur complet

La CLI propose `infer`, `profile`, `validate`, `clean` et `benchmark`, tous
limites a une source CSV. Elle n'expose pas le pipeline builder, le matching,
JSONL, PostgreSQL, la conversion de formats, le replay ni les resultats
persistants de validation. Les capacites existent dans l'API Zig mais ne sont
pas encore exploitables comme produit unifie.

Correction requise : commandes versionnees et configuration de pipeline
declarative, sorties JSON stables, codes de sortie documentes et selection
explicite source/sink.

### [P2] Les violations n'ont pas de sink fichier de production

`ViolationSink` recoit bien les violations progressivement, mais la seule
implementation fournie est `SamplingSink`. La CLI conserve au maximum 100
violations dans son resume. Une integration peut fournir son propre sink, mais
le binaire ne peut pas produire un journal complet et borne sur disque.

Correction requise : sink JSONL/CSV progressif, lifecycle `finish/abort`,
atomicite et test multi-batch.

### [P2] Les capacites `seekable` ne correspondent pas au contrat public

CSV et JSONL annoncent `seekable=true`, alors que `Source` ne fournit aucune
operation de seek ou de rewind. Cette information peut conduire un planificateur
a choisir une strategie impossible a executer.

Correction requise : annoncer `false` jusqu'a l'ajout d'un contrat de seek, ou
ajouter une operation de reouverture/rewind testee.

### [P2] La distribution autonome reste non resolue

Le binaire standard lie dynamiquement SQLite. Le choix V-001 reste ouvert entre
SQLite statique et un spill exact natif. PostgreSQL est correctement optionnel,
mais le test d'integration utilise actuellement une installation et un endpoint
macOS locaux. Aucun gate Linux musl ou artefact de release autonome n'est
present.

Correction requise : fermer V-001, produire les binaires cibles, verifier leurs
dependances runtime et ajouter une CI Linux/macOS.

## Matrice des criteres v1.0

| # | Critere | Etat | Preuve ou ecart |
|---:|---|---|---|
| 1 | CSV streaming | Passe | Parseur borne, benchmark 2 M lignes |
| 2 | Batches colonnaires | Passe | Sept types physiques et null bitmaps |
| 3 | Inference de schema | Passe | Inference conservative et schema possede |
| 4 | Zeros initiaux | Passe | Tests d'identifiants ambigus |
| 5 | Profiling complet | Passe | Statistiques typees par colonne |
| 6 | Cardinalite adaptative | Passe | Exact puis HyperLogLog |
| 7 | Regles de validation | Passe | Compilation et evaluation typees |
| 8 | Violations progressives | Partiel | Contrat streaming, aucun sink fichier fourni |
| 9 | Transformations immuables | Passe | Arenas entree/sortie distinctes |
| 10 | Dataset nettoye | Passe | CSV relisible sur 2 M lignes |
| 11 | Provenance rejouable | Passe | Format versionne, registre, reader et CLI testes |
| 12 | Double buffer d'arenas | Passe | PipelineAllocators et test pipeline |
| 13 | Memoire bornee | Passe | Limites, approximations et spill |
| 14 | Metriques d'execution | Passe | Lignes, batches, octets, temps benchmark |
| 15 | Matching exact | Passe | Backend partitionne teste sur 2 x 2 M lignes |
| 16 | Tests unitaires/integration | Passe | Debug, ReleaseSafe et PostgreSQL passent |
| 17 | Fichier superieur a la RAM | Partiel | 349 MiB sous ~25 MiB RSS; aucun test 10-50 Go |

## Verification executee

Les commandes suivantes passent :

```text
zig fmt --check build.zig src tests benchmarks
zig build test
zig build -Doptimize=ReleaseSafe test
zig build -Doptimize=ReleaseFast
zig build -Dpostgres=true test-postgres
```

Smoke tests CLI passes : `infer`, `profile`, `validate`, `clean` et `replay`.

Le binaire macOS ReleaseFast mesure 632 KiB et depend actuellement de
`/usr/lib/libsqlite3.dylib` et `libSystem`.

## Gates de sortie v1.0 proposes

1. Fermer P-001 pour CSV, JSONL, audit et violations.
2. Versionner l'identite et le contenu des sources.
3. Fournir une CLI couvrant pipeline, matching et connecteurs.
4. Fermer V-001 et verifier un artefact autonome Linux/macOS.
5. Executer un test d'endurance de 10 Go minimum avec RSS, disque et cleanup.
6. Ajouter CI, fuzzing parseurs et injection de fautes I/O/OOM.

Une fois les deux blockers P1 termines, le moteur pourra etre qualifie de
release candidate. Les six points sont requis avant la declaration v1.0 stable
recommandee par cet audit.

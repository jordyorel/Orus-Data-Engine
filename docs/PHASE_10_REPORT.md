# Phase 10 - Matching fuzzy et spill partitionne

Date: 2026-08-08  
Toolchain: Zig 0.16.0  
Statut: complete dans le perimetre de la roadmap

## Capacites livrees

- normalisation ASCII versionnee et blocking exact, prefixe ou prefixe de token ;
- distance de Levenshtein bornee avec arret anticipe et scratch reutilise ;
- similarite Jaro-Winkler sans allocation, bornee a 1 024 octets ;
- score composite pondere, seuil configurable et configuration validee ;
- limites du nombre de candidats et de resultats par ligne ;
- partitionnement deterministe des references et candidats ;
- spill binaire temporaire et indexation d'une seule partition a la fois ;
- ecriture progressive des correspondances par blocs de 256 ;
- suppression des partitions apres succes et apres erreur d'initialisation ;
- metriques de partitions, octets de spill et pic memoire de l'index.

## Contrats de ressources

La memoire de l'index est bornee par `index_memory_limit`, independamment de la
taille totale des fichiers. `partition_count` controle la taille moyenne des
partitions. Une partition trop grosse retourne `MatchIndexMemoryLimit` au lieu
d'augmenter la memoire sans limite. `max_value_bytes`,
`max_candidates_per_row` et `max_matches_per_row` sont des limites dures.

Le disque temporaire doit pouvoir contenir les valeurs normalisees des deux
datasets et leurs metadonnees de ligne. Les fichiers sont crees exclusivement :
deux executions utilisant le meme `temp_prefix` ne peuvent pas s'ecraser.

## Benchmark de reference

Commande :

```sh
zig build bench-matching
```

Dataset : `fixtures/customers-2000000.csv`, utilise comme reference et candidat.

| Mesure | Resultat |
|---|---:|
| Lignes reference | 2 000 000 |
| Lignes candidates | 2 000 000 |
| Correspondances | 2 000 000 |
| Partitions | 32 |
| Limite index | 32 MiB |
| Pic index | 13 MiB |
| Spill | 209 MiB |
| Temps | 6,631 s |
| Debit total | 603 247 lignes/s |

Ce benchmark mesure le chemin partitionne exact. Les tests d'integration
exercent egalement le scoring fuzzy au-dessus du meme backend disque.

## Verification

- `zig fmt --check build.zig src tests benchmarks` : passe ;
- `zig build test` : passe ;
- `zig build -Doptimize=ReleaseSafe test` : passe ;
- `zig build -Doptimize=ReleaseFast` : passe ;
- `zig build bench-matching` : passe.

## Limites connues

- la normalisation et les distances operent actuellement sur des octets ASCII,
  pas sur des graphemes Unicode ;
- Jaro-Winkler retourne zero au-dela de 1 024 octets ;
- un blocking trop peu selectif peut atteindre les limites explicites par
  ligne ;
- le nombre de partitions est configure avant l'execution, sans
  repartitionnement automatique d'une partition desequilibree ;
- le repertoire temporaire doit disposer d'un espace libre suffisant.

Ces limites sont explicites et ne remettent pas en cause la consommation
memoire bornee. Unicode et le repartitionnement adaptatif sont des evolutions
ulterieures, pas des criteres incomplets de cette phase.

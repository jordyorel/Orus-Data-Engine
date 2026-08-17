# Orus Ontology - Rapport de phase O11

Date : 2026-08-15  
Statut : complete

## Perimetre livre

* benchmark reproductible Zig, materialisation, PostgreSQL et requetes ;
* ecriture PostgreSQL atomique par batch avec prelecture des collisions ;
* lookup exact indexe par predicat et valeur ;
* test de volume sur 100 000 lignes du fichier reel ;
* manifeste de compatibilite API, transport, stockage, ontologie et mapping ;
* limites de capacite et commande d'import documentees ;
* decision mesuree concernant JSONL, Arrow IPC et ABI native.

## Mesures reproductibles

Machine : Mac Apple Silicon, Zig 0.16, Python 3.14, PostgreSQL local. Les
resultats sont des references de cette machine et non une garantie universelle.

### 10 000 lignes reelles

| Chemin | Resultat |
|---|---:|
| Zig `export-jsonl`, 100 000 lignes | 55 556 lignes/s |
| Materialisation avec `tracemalloc` | 516 lignes/s |
| Pic Python trace, batch 1 024 | 76 704 201 octets |
| Pic RSS processus Python | 195 936 256 octets |
| Import PostgreSQL, batch 1 024 | 942 lignes/s |
| Lookup identite median / p95 | 0,31 ms / 0,44 ms |
| Voisinage 1 saut median / p95 | 4,24 ms / 5,06 ms |
| Traversee bornee 1 saut median / p95 | 0,40 ms / 0,51 ms |
| Stockage PostgreSQL | 168 Mio |

### Test de volume 100 000 lignes

| Mesure | Resultat |
|---|---:|
| Customers | 100 000 |
| EmailAddress dedupliquees | 99 999 |
| Company dedupliquees | 72 251 |
| Objets totaux | 272 250 |
| Relations | 200 000 |
| Assertions | 600 000 |
| Taille PostgreSQL, index inclus | 1 633 Mio |

Le checkpoint a progresse par batch et le contexte du premier client a ete
relu avec ses quatre assertions, son offset source et ses relations
`OWNS_EMAIL` et `WORKS_FOR`.

## Projection 2 millions

Le profil complet permet d'attendre environ 5,16 millions d'objets, 4 millions
de relations et 12 millions d'assertions. La projection lineaire du test de
volume est de 32,7 Gio. Il faut reserver au moins 45 Gio pour les index, WAL,
maintenance et variations de cardinalite. Au debit de reference, l'import prend
environ 35 minutes, hors maintenance PostgreSQL.

## Decision transport v1

JSONL reste le contrat v1. Zig produit les enveloppes environ 59 fois plus vite
que le chemin PostgreSQL mesure. Le cout dominant se situe dans la validation,
la materialisation Pydantic et la persistance, pas dans le parseur CSV Zig.

Arrow IPC ajouterait une dependance et un second contrat sans supprimer ce cout.
Une ABI native couplerait Python a la memoire Zig et compliquerait fortement la
gestion des erreurs et du deploiement. La decision sera reouverte uniquement si
un profil demontre que JSONL consomme plus de 25 % du temps apres optimisation
du chemin Python, ou si le debit de materialisation depasse 20 000 lignes/s.

## Limites publiees

* `batch_size` borne la materialisation, mais PostgreSQL croit avec le graphe ;
* `MemoryStore` ne convient pas au volume dataset ;
* les recherches exactes utilisent l'index predicat/valeur ;
* les filtres non exacts restent des scans pagines ;
* un import complet exige PostgreSQL, Psycopg et assez d'espace disque ;
* les checkpoints sont mis a jour uniquement apres commit du batch ;
* rejouer le dernier batch apres interruption est idempotent.

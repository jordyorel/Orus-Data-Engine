# Orus Ontology - Rapport de phase O10

Date : 2026-08-15  
Statut : complete

## Perimetre livre

* regles declaratives immuables et versionnees ;
* conditions `exists`, `equals` et `not_equals` ;
* conclusions litterales ou copiees depuis une premisse ;
* chainage avant deterministe et monotone ;
* assertions `inferred` avec regle, confiance et IDs des premisses ;
* identifiants d'inference deterministes par sujet/regle/version/conclusion ;
* intersection des intervalles de validite ;
* limites explicites d'iterations, objets, assertions et taille de page ;
* prevention des cycles par identite stable et chemin d'explication ;
* explication recursive bornee de chaque deduction.

## Invariants verifies

1. Une regle cible un type d'objet explicite.
2. Premisses et conclusion doivent exister dans ce type publie.
3. Le type de la conclusion doit correspondre au schema.
4. Une execution identique ne cree pas une seconde assertion.
5. L'ordre des regles et assertions est stable.
6. Une inference ne perd jamais les IDs de ses premisses.
7. Une validite temporelle vide ne produit aucune assertion.
8. Atteindre une limite retourne `truncated`, jamais un faux etat sature.
9. Une explication cyclique ou trop profonde est tronquee explicitement.

## Limites

O10 est un moteur de regles locales sur les assertions d'un meme objet. Il ne
promet ni negation par absence, ni logique non monotone, ni jointure globale
entre entites. Ces extensions exigeraient une semantique et des benchmarks
distincts avant d'entrer dans le coeur.

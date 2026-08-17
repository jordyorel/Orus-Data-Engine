# Fiche technique - Orus Ontology

## 0. Presentation

**Nom du composant :** Orus Ontology  
**Version cible initiale :** v0.1 POC  
**Langage initial :** Python 3.12+  
**Type de composant :** couche semantique, versionnee et tracable  
**Position dans Orus :** au-dessus d'Orus Data Engine, en dessous des workflows,
de l'analytics et de l'IA

Ce document est la source de verite conceptuelle pour la construction d'Orus
Ontology. Il definit les responsabilites, les invariants et l'architecture cible.
Une implementation qui contredit un invariant de ce document doit modifier le
document et justifier explicitement ce changement.

---

## 1. Mission

Orus Data Engine transforme des donnees brutes en donnees typees, profilees,
validees, nettoyees et rapprochees. Orus Ontology transforme ces donnees en une
representation metier exploitable : objets, relations et assertions dont
l'identite, l'origine, la validite et le niveau de confiance sont connus.

La definition centrale est la suivante :

> Une ontologie Orus est un ensemble versionne de types, d'identites,
> d'assertions et de relations tracables, materialise a partir de donnees
> validees.

Orus Ontology doit permettre de :

1. definir des concepts metier independamment des formats physiques ;
2. materialiser des objets et des relations depuis les sorties du Data Engine ;
3. conserver une identite stable entre plusieurs sources et executions ;
4. distinguer les faits observes, transformes, corriges et inferes ;
5. expliquer l'origine de chaque fait important ;
6. interroger le contexte complet d'une entite ;
7. supporter le raisonnement, les workflows et l'IA sans les integrer au coeur ;
8. evoluer par versions sans modifier retroactivement l'historique publie.

---

## 2. Perimetre

Orus Ontology couvre :

```text
Schema semantique versionne
    -> Mapping declaratif
    -> Materialisation d'objets et de relations
    -> Resolution d'identite
    -> Assertions et provenance
    -> Stockage abstrait
    -> Requetes et traversees
    -> Regles d'inference explicites
```

Orus Ontology ne couvre pas :

* le parsing CSV ou JSONL ;
* l'inference des types physiques ;
* le profiling et le nettoyage bas niveau ;
* le fuzzy matching de masse ;
* l'orchestration des pipelines Zig ;
* les dashboards et l'API HTTP ;
* l'authentification et le controle d'acces ;
* les workflows metier propres a un domaine ;
* les modeles d'IA.

Ces fonctions consomment ou alimentent l'ontologie, mais restent des composants
distincts.

---

## 3. Position dans l'architecture Orus

```text
Sources CSV / JSONL / PostgreSQL
                |
                v
        Orus Data Engine (Zig)
        - ingestion streaming
        - schema physique
        - profiling
        - validation
        - cleaning
        - matching
                |
                | contrat de sortie versionne
                v
        Orus Ontology (Python)
        - schema semantique
        - identite
        - assertions
        - relations
        - provenance
        - requetes
                |
                v
     Workflows / Analytics / IA / API
```

La frontiere Zig/Python est un contrat de donnees. Python ne doit pas importer
les structures memoire internes de Zig. Le premier transport sera un flux JSONL
versionne. Apache Arrow IPC ou une ABI native ne seront introduits qu'apres une
mesure demontrant que JSONL est le goulot d'etranglement.

---

## 4. Les quatre niveaux de representation

### 4.1 Niveau physique

Le niveau physique decrit la source telle qu'elle existe : fichier, table,
colonnes, types physiques, lignes, batches et identite de source. Il appartient
au Data Engine.

### 4.2 Niveau canonique

Le niveau canonique contient les valeurs typees et nettoyees, encore organisees
comme des enregistrements. Il constitue l'entree normale de l'ontologie.

Exemples : `customer_id`, `normalized_phone`, `subscription_date`.

### 4.3 Niveau ontologique

Le niveau ontologique exprime le sens metier : `Customer`, `Company`,
`EmailAddress`, `WORKS_FOR`, `OWNS_EMAIL`.

### 4.4 Niveau decisionnel

Le niveau decisionnel utilise le graphe pour produire des alertes, analyses,
recommandations ou decisions. Il ne fait pas partie du noyau ontologique.

---

## 5. Principes non negociables

### 5.1 Separation entre schema et donnees

Un type definit ce qui peut exister. Une instance represente ce qui a ete
observe ou affirme. Une modification d'instance ne modifie jamais son type.

### 5.2 Versions publiees immuables

Une version publiee du schema est une photographie profonde immuable. Aucun
tableau, dictionnaire ou objet mutable partage ne doit permettre de la modifier
retroactivement.

### 5.3 Identite explicite

Une entite ne doit jamais etre fusionnee uniquement parce que deux valeurs se
ressemblent. Toute strategie d'identite est declaree, versionnee et testable.

### 5.4 Provenance native

La provenance n'est pas une metadata facultative ajoutee a la fin. Chaque
assertion materialisee doit etre rattachee a une source ou explicitement
marquee comme derivee.

### 5.5 Pas de perte silencieuse

Une propriete inconnue, une valeur incompatible, une relation invalide ou une
identite manquante produit une erreur structuree ou suit une politique explicite
(`reject`, `quarantine`, `default`). Elle ne doit jamais etre ignoree.

### 5.6 Observation et inference distinctes

Un fait lu depuis une source, un fait nettoye et un fait deduit par une regle
sont des assertions differentes, meme lorsque leur valeur finale est identique.

### 5.7 Coeur independant du stockage

Le metamodel, la validation et la materialisation ne dependent ni de NetworkX,
ni de PostgreSQL, ni d'un fournisseur de base graphe. Le stockage implemente un
contrat defini par le coeur.

### 5.8 Capacite bornee

Le chemin de materialisation traite les entrees en flux ou par batches bornes.
Le backend memoire est reserve aux tests et petits POC. Les volumes durables
doivent etre diriges vers un backend persistant.

### 5.9 Compilation avant materialisation

Les mappings sont valides et compiles avant de traiter les enregistrements :
resolution des types, des proprietes, des identites, des transformations et des
relations. Le chemin chaud ne redecouvre pas le schema a chaque ligne.

---

## 6. Metamodele

### 6.1 OntologyDefinition

Racine d'une version de schema :

```text
OntologyDefinition
|- ontology_id
|- name
|- version
|- status: draft | published | retired
|- object_types[]
|- relation_types[]
|- constraints[]
`- metadata
```

Seul un brouillon peut etre modifie. La publication cree une photographie
profonde et incremente la version suivante.

### 6.2 ObjectType

Un `ObjectType` definit une classe d'entites metier :

```text
ObjectType
|- type_id              identifiant stable entre versions
|- name                 nom technique stable
|- display_name
|- version
|- identity_spec
|- properties[]
|- constraints[]
`- metadata
```

Le nom n'est pas l'identite interne du type. Un renommage est une evolution
explicite et ne doit pas laisser d'alias implicite dans le registre.

### 6.3 PropertyType

```text
PropertyType
|- property_id
|- name
|- value_type
|- required
|- nullable
|- unique
|- cardinality: one | many
|- default_value
|- constraints[]
`- metadata
```

Types initiaux : `string`, `integer`, `decimal`, `boolean`, `date`, `datetime`,
`enum`, `reference` et `json`. Les valeurs financieres exactes utilisent
`Decimal`, jamais `float`.

`required` signifie que la propriete doit etre presente. `nullable` signifie
qu'une valeur presente peut valoir `null`. Ces deux notions restent distinctes.

### 6.4 ObjectInstance

```text
ObjectInstance
|- object_id            identite technique stable
|- object_type_id
|- ontology_version
|- canonical_id         optionnel avant resolution
|- assertions[]
|- created_at
`- updated_at
```

Les proprietes ne sont pas conceptuellement un simple dictionnaire mutable.
Elles sont exposees comme une vue de l'ensemble des assertions actives.

### 6.5 RelationType

```text
RelationType
|- type_id
|- name
|- source_type_id
|- target_type_id
|- directed
|- cardinality
|- temporal
|- properties[]
`- constraints[]
```

Cardinalites initiales : `one_to_one`, `one_to_many`, `many_to_one` et
`many_to_many`.

### 6.6 RelationInstance

```text
RelationInstance
|- relation_id
|- relation_type_id
|- source_object_id
|- target_object_id
|- assertions[]
|- valid_from / valid_to
`- created_at
```

La creation d'une relation exige que les deux objets existent et correspondent
aux types source et cible declares. Une relation non dirigee conserve une
representation canonique deterministe de ses extremites.

### 6.7 Assertion

L'assertion est l'unite fondamentale de connaissance :

```text
Assertion
|- assertion_id
|- subject_id
|- predicate
|- value ou object_id
|- kind: observed | transformed | corrected | inferred
|- provenance[]
|- confidence
|- observed_at
|- valid_from / valid_to
|- recorded_at
|- mapping_version
`- rule_id optionnel
```

Une propriete d'objet est une assertion vers une valeur. Une relation est une
assertion vers un autre objet, enrichie par un `RelationType`. L'implementation
peut employer des representations optimisees distinctes, mais doit conserver ce
modele conceptuel commun.

### 6.8 Provenance

```text
SourceReference
|- source_id
|- source_version
|- batch_id
|- row_id ou global_offset
|- source_column
|- run_id
|- transformation_ids[]
|- observed_at
`- checksum optionnel
```

Une provenance doit permettre de retrouver l'observation d'origine et la
recette qui a produit l'assertion.

---

## 7. Identite et resolution d'entites

Le modele distingue obligatoirement :

1. **identite source** : position d'un enregistrement dans une source ;
2. **identite deterministe** : ID derive d'une cle metier et du type ;
3. **identite canonique** : entite unifiee representant plusieurs observations ;
4. **candidat de correspondance** : hypothese de similarite avec score ;
5. **decision de fusion** : decision auditable reliant des identites.

Strategie deterministe initiale :

```text
object_id = UUIDv5(namespace_ontology, type_id + canonical_identity_key)
```

La canonicalisation de la cle est definie dans `IdentitySpec` et versionnee.
Elle ne doit pas dependre de la locale ou de l'heure de la machine.

Une fusion ne supprime pas les identites sources. Elle cree une decision de
resolution contenant la methode, le score, la date, la version et, lorsqu'il y
en a un, l'acteur responsable.

---

## 8. Proprietes ou objets

Une valeur devient un objet lorsqu'au moins une condition est vraie :

* elle possede sa propre identite ;
* elle peut etre partagee par plusieurs entites ;
* elle porte ses propres relations ;
* elle possede un historique autonome ;
* elle doit etre interrogee independamment.

Exemples :

* `first_name` reste une propriete ;
* `Company` est normalement un objet ;
* `EmailAddress` peut devenir un objet pour detecter des comptes lies ;
* `Country` peut etre une propriete ou un objet de reference selon le domaine.

Chaque valeur ne doit pas devenir un noeud. La modelisation doit servir un cas
d'usage explicite.

---

## 9. Contraintes, validation et inference

### 9.1 Contraintes structurelles

Types, presence, nullabilite, unicite, cardinalite, domaines enum, extremites
des relations et formats semantiques.

### 9.2 Contraintes metier

Regles propres au domaine, par exemple l'impossibilite d'avoir deux contrats
principaux actifs au meme instant.

### 9.3 Regles d'inference

Regles qui produisent de nouvelles assertions. Une inference ne modifie pas le
fait source et declare obligatoirement `kind=inferred`, `rule_id`, sa provenance
et son niveau de confiance.

Validation et inference sont separees : une validation accepte, rejette ou met
en quarantaine ; une inference produit une assertion.

---

## 10. Temporalite

Quatre temps sont distingues :

```text
observed_at   moment ou la source a observe le fait
valid_from    debut de validite metier
valid_to      fin de validite metier
recorded_at   moment d'enregistrement dans Orus
```

L'absence de `valid_to` signifie "validite ouverte", pas "valide pour toujours".
Les corrections ferment ou remplacent une assertion ; elles ne reecrivent pas
silencieusement l'historique.

---

## 11. Mapping declaratif

Un mapping est une recette versionnee qui relie le niveau canonique au niveau
ontologique.

```yaml
mapping: customers_v1
ontology: commerce
ontology_version: 1
source_contract: customers_clean_v1

objects:
  - type: Customer
    identity:
      columns: [customer_id]
      normalizers: [trim]
    properties:
      customer_id: customer_id
      first_name: first_name
      subscription_date: subscription_date

  - type: EmailAddress
    identity:
      columns: [normalized_email]
    properties:
      address: normalized_email

relations:
  - type: OWNS_EMAIL
    source: Customer
    target: EmailAddress
    confidence: 1.0
```

Le compilateur de mapping verifie avant execution :

* l'existence des types et proprietes ;
* la compatibilite des types ;
* la presence des colonnes d'identite ;
* les transformations autorisees ;
* les extremites et cardinalites des relations ;
* la compatibilite de version.

---

## 12. Contrat avec Orus Data Engine

Le flux initial est un JSONL enveloppe et versionne :

```json
{"contract_version":1,"record":{"customer_id":"C-123"},"source":{"source_id":"customers.csv","batch_id":4,"row_id":42},"run_id":"..."}
```

Regles :

1. une ligne JSON represente un enregistrement canonique ;
2. les metadata de provenance sont separees du contenu metier ;
3. la version du contrat est obligatoire ;
4. une version inconnue est rejetee explicitement ;
5. le flux est consomme progressivement, sans chargement complet ;
6. `stderr` du processus Zig est draine concurremment pour eviter un blocage ;
7. une sortie partielle apres echec est marquee incomplete et non valide.

Le pont de processus ne nettoie ni ne revalide les donnees physiques. Il
transporte les sorties du Data Engine vers le materialiseur.

---

## 13. Stockage

Le coeur depend de contrats, pas d'un backend concret :

```text
SchemaStore
|- publish(definition)
|- get(ontology_id, version)
`- latest(ontology_id)

ObjectStore
|- put_object(object)
|- get_object(id)
|- put_assertions(batch)
`- find_objects(query)

RelationStore
|- put_relation(relation)
|- get_relation(id)
`- neighbors(id, relation_type, direction)
```

Backends prevus :

* `memory` : tests unitaires et POC bornes ;
* `postgres` : persistance initiale de production, proprietes indexables et
  transactions ;
* un backend graphe specialise uniquement si les mesures de traversees le
  justifient.

Un backend non implemente ne doit pas etre exporte comme disponible.

---

## 14. Requetes

La premiere API de requete couvre :

* recuperation par identite ;
* recherche par type et proprietes ;
* lecture des assertions actives ou historiques ;
* voisins entrants, sortants ou dans les deux directions ;
* traversees multi-sauts avec profondeur et limites explicites ;
* provenance d'un objet, d'une relation ou d'une valeur ;
* resolution du contexte canonique d'une entite.

Toute traversee possede une profondeur maximale, une limite de resultats et une
politique de cycle. Une API ne doit pas promettre un filtre qu'elle n'applique
pas effectivement.

---

## 15. Structure cible

```text
python/
├── pyproject.toml
├── src/
│   └── orus_ontology/
│       ├── __init__.py
│       ├── errors.py
│       ├── metamodel/
│       │   ├── value_type.py
│       │   ├── property_type.py
│       │   ├── object_type.py
│       │   ├── relation_type.py
│       │   ├── ontology.py
│       │   └── validator.py
│       ├── registry/
│       │   ├── registry.py
│       │   ├── version.py
│       │   └── migration.py
│       ├── identity/
│       │   ├── spec.py
│       │   ├── generator.py
│       │   ├── candidate.py
│       │   └── resolution.py
│       ├── assertions/
│       │   ├── assertion.py
│       │   ├── provenance.py
│       │   └── temporal.py
│       ├── mapping/
│       │   ├── definition.py
│       │   ├── compiler.py
│       │   └── plan.py
│       ├── materialization/
│       │   ├── object_materializer.py
│       │   ├── relation_materializer.py
│       │   └── batch.py
│       ├── storage/
│       │   ├── contracts.py
│       │   ├── memory.py
│       │   ├── postgres.py
│       │   └── migrations/
│       │       └── 001_initial.sql
│       ├── query/
│       │   ├── filters.py
│       │   ├── traversal.py
│       │   └── service.py
│       ├── interchange/
│       │   ├── contract.py
│       │   ├── jsonl.py
│       │   └── subprocess_bridge.py
│       └── reasoning/
│           ├── rule.py
│           └── engine.py
└── tests/
    └── miroir de src/orus_ontology/
```

Les modules `interchange/arrow.py` et les workflows ne sont ajoutes que dans la
phase qui les implemente reellement.

---

## 16. Dependances initiales

Le noyau commence avec la bibliotheque standard et Pydantic 2 pour les contrats,
la validation et la serialisation. Psycopg 3 est un extra strictement optionnel
pour le backend PostgreSQL ; le coeur et le backend memoire restent importables
sans lui. Une dependance n'est ajoutee que lorsqu'elle remplace une complexite
reelle et qu'elle est utilisee par un comportement teste.

NetworkX n'appartient pas au coeur. Il peut etre utilise dans un adaptateur
d'analyse ou un prototype, mais le modele et les services ne doivent pas
dependre de ses types.

---

## 17. Gestion des erreurs

Categories minimales :

```text
OntologyError
|- SchemaError
|- VersionError
|- IdentityError
|- MappingError
|- MaterializationError
|- StorageError
|- QueryError
`- BridgeError
```

Les erreurs externes incluent un code stable, un message, le contexte utile et
la cause lorsqu'elle existe. `NotImplementedError` ne doit pas etre expose par
une classe presentee comme utilisable.

---

## 18. Regles d'implementation Python

1. Python 3.12+ est la cible initiale ; aucune compatibilite speculative.
2. Le code public est type ; les types vagues comme `Any` restent aux frontieres
   de serialisation et sont valides avant d'entrer dans le coeur.
3. Les modeles de schema publies sont profondement immuables.
4. Les dictionnaires mutables fournis par l'appelant ne sont pas conserves par
   reference dans une version ou une assertion.
5. Aucun singleton global ou registre cache.
6. Aucun module generique `utils`, `helpers`, `common` ou `manager`.
7. Une abstraction doit proteger un invariant ou permettre un backend reel.
8. Les chemins synchrones et asynchrones ne sont pas melanges implicitement.
9. Une coroutine ne doit pas effectuer d'I/O fichier bloquante directement.
10. Les traitements de masse acceptent un iterateur et emettent des batches
    bornes ; ils ne retournent pas une liste de taille dataset.
11. Les timestamps sont en UTC et les identifiants deterministes sont
    independants de l'environnement.
12. Les imports suivent les frontieres de modules ; le metamodel n'importe ni
    stockage, ni mapping, ni requetes.
13. Un composant incomplet reste interne et absent des exports publics.
14. Ruff est l'autorite de format et de lint ; Pyright verifie les types.
15. Chaque comportement public et chaque bug corrige possedent un test.

---

## 19. Strategie de tests

Chaque phase doit inclure :

* tests unitaires des invariants ;
* tests de serialisation aller-retour ;
* tests de valeurs invalides et de limites ;
* tests de versionnage et d'immutabilite profonde ;
* tests deterministes d'identite ;
* tests de non-perte des proprietes inconnues ;
* tests d'integration du flux Zig vers Python ;
* test multi-batch demontrant que la materialisation reste bornee ;
* benchmarks avant toute optimisation du transport ou du stockage.

Commandes cibles :

```sh
cd python
.venv/bin/python -m ruff check src tests
.venv/bin/python -m ruff format --check src tests
.venv/bin/python -m pyright
.venv/bin/python -m pytest
```

---

## 20. Roadmap de construction

### Phase O1 - Socle du projet [complete]

* packaging `src/` ;
* configuration Ruff, Pyright et Pytest ;
* hierarchy d'erreurs ;
* exports publics minimaux.

**Termine lorsque :** le package s'installe, les controles passent et aucun
comportement fictif n'est exporte.

### Phase O2 - Metamodele et validation [complete]

* types de valeurs ;
* proprietes, objets, relations et ontologie ;
* contraintes structurelles ;
* serialisation stable.

**Termine lorsque :** les schemas valides passent, les schemas incoherents sont
rejetes et les modeles publies peuvent etre rendus immuables.

### Phase O3 - Registry et versions [complete]

* brouillon, publication et lecture historique ;
* immutabilite profonde ;
* detection des changements incompatibles ;
* migration explicite.

**Termine lorsque :** une version publiee ne peut plus etre modifiee, meme via
une collection imbriquee.

### Phase O4 - Assertions, provenance et temporalite [complete]

* assertions typees ;
* references de source ;
* temps d'observation, de validite et d'enregistrement ;
* corrections sans reecriture de l'historique.

**Termine lorsque :** toute valeur materialisee peut expliquer son origine et
son etat temporel.

### Phase O5 - Identite [complete]

* `IdentitySpec` ;
* IDs deterministes ;
* candidats de correspondance ;
* decisions de fusion auditables.

**Termine lorsque :** deux executions identiques produisent les memes IDs et
qu'une fusion conserve toutes les identites sources.

### Phase O6 - Mapping et materialisation [complete]

* format declaratif ;
* compilateur ;
* plan immutable ;
* materialisation streaming d'objets et de relations ;
* politiques d'erreur explicites.

**Termine lorsque :** un flux canonique multi-batch est materialise avec une
memoire bornee et sans perte silencieuse.

### Phase O7 - Stockage memoire et requetes [complete]

* contrats de stockage ;
* backend memoire de reference ;
* recherche, voisinage, traversee bornee et provenance.

**Termine lorsque :** la suite contractuelle passe contre le backend memoire et
tous les filtres annonces sont verifies.

### Phase O8 - Integration Orus Data Engine [complete]

* contrat JSONL versionne ;
* bridge subprocess robuste ;
* backpressure et drainage de `stderr` ;
* propagation des erreurs et statut de sortie partielle.

**Termine lorsque :** une fixture CSV traverse le pipeline Zig et produit des
objets et relations tracables dans Python.

### Phase O9 - Persistance PostgreSQL [complete]

* schema SQL et migrations ;
* transactions ;
* index des identites, types et relations ;
* meme suite contractuelle que le backend memoire.

**Termine lorsque :** les resultats fonctionnels sont identiques entre memoire
et PostgreSQL, et qu'une reprise de processus conserve le graphe.

### Phase O10 - Raisonnement controle [complete]

* regles declaratives ;
* assertions inferees ;
* prevention des cycles et limites d'expansion ;
* explication des deductions.

**Termine lorsque :** chaque inference est reproductible, bornee et expliquee.

### Phase O11 - Performance et stabilisation v1 [complete]

* benchmarks de materialisation, requetes et traversees ;
* test de volume ;
* decision mesuree sur Arrow IPC ou ABI native ;
* compatibilite de schema et documentation publique.

**Termine lorsque :** les limites de capacite sont publiees, les chemins de
production sont persistants et aucune garantie ne repose sur le backend memoire.

### Phase O12 - API de consultation [complete]

* service FastAPI autonome dans `apps/ontology-api` ;
* dependance orientee uniquement de l'API vers `orus-ontology` ;
* liveness, readiness et statistiques PostgreSQL ;
* recherche, contexte, voisinage et traversee bornes ;
* erreurs ontologiques traduites en erreurs HTTP stables ;
* tests memoire et integration sur les donnees Customer reelles.

**Termine lorsque :** le client reel peut etre recherche par HTTP avec ses
assertions et sa provenance, son voisinage peut etre explore sans route de
chargement global, et tests, lint et types du package autonome passent.

### Phase O13 - Explorateur visuel [complete]

* application React/TypeScript autonome dans `web/ontology-explorer` ;
* graphe Cytoscape construit uniquement depuis Ontology API v1 ;
* recherche Customer, selection, contexte, assertions et provenance ;
* expansion progressive des voisins sans lecture globale ;
* controles de zoom, legende et statistiques de portee ;
* interface responsive desktop et mobile ;
* CORS local strict sur l'API.

**Termine lorsque :** un Customer reel peut etre recherche, inspecte et etendu
vers son email et son entreprise dans le navigateur, avec build TypeScript,
tests et verification visuelle desktop/mobile passes.

---

## 21. Definition de done globale

Une phase n'est complete que si :

1. ses invariants sont documentes ;
2. son comportement est entierement implemente ;
3. aucun placeholder n'est exporte ;
4. les erreurs ne provoquent ni perte silencieuse ni etat ambigu ;
5. les tests unitaires et d'integration passent ;
6. les types et le lint passent ;
7. les limites memoire et de volume sont explicites ;
8. les exports publics correspondent exactement aux fonctions disponibles ;
9. la roadmap et le rapport de phase refletent l'etat reel.

---

## 22. Premier cas vertical

Le premier cas d'usage utilisera `fixtures/customers-2000000.csv` lorsqu'il est
present, avec un petit extrait deterministe pour les tests rapides.

Le schema initial materialisera :

```text
Customer
|- customer_id
|- first_name
|- last_name
`- subscription_date

EmailAddress
`- address

Company
`- name

Customer -[OWNS_EMAIL]-> EmailAddress
Customer -[WORKS_FOR]-> Company
```

Ce cas vertical doit prouver :

* la stabilite de l'identite ;
* la provenance ligne/colonne ;
* la materialisation streaming ;
* la creation controlee des relations ;
* la requete du contexte complet d'un client ;
* l'absence de dependance du coeur a NetworkX ou PostgreSQL.

Il ne doit pas imposer au metamodele des noms ou comportements propres au
domaine client.

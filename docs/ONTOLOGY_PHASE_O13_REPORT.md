# Orus Ontology - Rapport de phase O13

Date : 2026-08-15  
Statut : complete

## Composant livre

`web/ontology-explorer` est le quatrieme composant autonome du monorepo :

```text
Ontology Explorer -> Ontology API -> Orus Ontology -> PostgreSQL
```

Le frontend ne depend ni de PostgreSQL, ni du package Python, ni du moteur Zig.
Il utilise exclusivement les routes HTTP v1 bornees de la phase O12.

## Fonctionnalites

* recherche exacte par `customer_id` ;
* statistiques objets, relations et assertions ;
* graphe interactif Cytoscape ;
* formes et couleurs distinctes Customer, Email et Company ;
* relations dirigees `OWNS_EMAIL` et `WORKS_FOR` ;
* selection d'un noeud et chargement de son contexte ;
* valeurs typees, nature de l'assertion et confiance ;
* provenance ligne, colonne et fichier ;
* expansion progressive du voisinage ;
* zoom avant, zoom arriere et ajustement ;
* etats connexion, chargement, absence et erreur ;
* mise en page responsive avec inspecteur inferieur sur mobile.

## Verification reelle

Le test navigateur a utilise les 10 000 lignes deja materialisees dans
PostgreSQL. La recherche du client `4962FDBE6BFEE6D` a affiche :

```text
Customer  4962FDBE6BFEE6D
Prenom    Pam
Nom       Sparks
Date      2020-11-29
Source    customers-2000000.csv, ligne globale 0
```

L'expansion a produit exactement trois noeuds et deux liens : le Customer,
l'Email, la Company, `OWNS_EMAIL` et `WORKS_FOR`. Les statistiques affichees
etaient 29 183 objets, 20 000 relations et 60 000 assertions.

Le rendu a ete controle sur le viewport desktop puis sur `390 x 844`. Le canvas
mobile est visible et dimensionne a `390 x 703`; les textes, boutons et panneaux
ne se chevauchent pas de maniere incoherente.

## Qualite et limites

* TypeScript strict passe ;
* tests Vitest du mapping domaine vers graphe passes ;
* build Vite de production passe ;
* API CORS limitee aux origines locales `127.0.0.1:5173` et `localhost:5173` ;
* aucun endpoint de graphe complet n'est utilise ;
* chaque expansion est limitee a 100 voisins par le client et 200 par l'API.

Le frontend n'a pas encore d'authentification, de sauvegarde de vues, de filtres
multi-types, de clustering visuel ni de rendu virtualise au-dela de quelques
centaines de noeuds. Ces fonctions devront conserver le principe d'expansion
bornee et etre justifiees par des tests de performance navigateur.

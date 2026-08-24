# wisq

*This is the French README; the primary one is [README.md](README.md).*

Machines virtuelles sur iPhone, en Swift — distantes à pleine vitesse,
locales dans les règles.

wisq se place face à UTM sur deux fronts à la fois :

- **Distant** : l'iPhone est un client rapide vers des VM qui tournent là où il
  y a du silicium — un Mac, un PC, un NAS, un serveur. C'est le mode principal,
  celui qui donne un vrai bureau à pleine vitesse.
- **Local** : un émulateur RISC-V rv32ima interprété, écrit en Swift, boote un
  vrai noyau Linux **sur le téléphone** en moins d'une seconde — sans réseau,
  sans serveur, shell compris. Interprété, donc sans JIT : conforme aux règles
  d'iOS, là où UTM SE vit dans une zone grise.

| | UTM SE (App Store) | wisq |
|---|---|---|
| Exécution | émulation locale QEMU, interprétée | la VM tourne sur l'hôte |
| Vitesse | très lente (pas de JIT sur iOS) | limitée par le réseau, pas par le CPU |
| Conformité App Store | zone grise, dépendante de la règle 4.7 | client réseau classique |
| Licence | GPL (QEMU) | pas de QEMU dedans, donc pas de copyleft à porter |
| Autonomie | l'émulation vide la batterie | décodage d'image seulement |

## Vitesse

La machine locale est un interpréteur, et elle est faite pour être rapide.
Démarrez un vrai noyau et mesurez vous-même :

```sh
swift run -c release wisq-bench --image /chemin/vers/Image
```

Sur le conteneur Linux x86_64 de développement, cela donne environ **160
millions d'instructions invitées par seconde** : l'invite `buildroot login:`
arrive après 44,6 M d'instructions en 0,27 s environ, la RAM invitée étant
obtenue en moins de 0,1 ms. La CI relance le même banc à chaque changement et
publie son propre chiffre, donc une régression se voit dans le journal.

Ces chiffres sont à lire pour ce qu'ils sont : ils viennent d'un conteneur
Linux, pas d'un téléphone — aucun iPhone n'est passé par cette boucle, et un
cœur A-series est une autre machine. Ce qui se transporte, c'est la forme : le
même chemin de code tourne sur le téléphone, il n'y a aucun JIT dedans, et rien
n'y exige de jailbreak ni d'autorisation particulière.

## État

Ce dépôt contient le squelette complet de l'application et un client **VNC/RFB 3.8
fonctionnel** écrit à la main. SPICE et RDP ont leur place réservée dans
l'architecture mais ne sont pas implémentés (voir `docs/ROADMAP.md`).

| Composant | État |
|---|---|
| Modèle de données, persistance, trousseau | fait |
| Transport TCP/TLS (Network.framework) | fait |
| VNC : handshake, auth VNC (DES), Raw / CopyRect / RRE / Hextile | fait |
| VNC : redimensionnement de bureau, presse-papiers | fait |
| VNC : ZRLE, Tight (JPEG compris), zlib — flux persistants | fait |
| VNC : mises à jour continues, curseur distant | fait |
| Reconnexion automatique (repli exponentiel, jamais sur erreur d'auth) | fait |
| Interface SwiftUI : liste, éditeur, session, barre de touches | fait |
| Gestes tactiles configurables, inertie, arbitrage | fait |
| Clavier matériel (HID → keysym X11) et clavier logiciel | fait |
| SPICE, RDP | à faire |
| Agent hôte : démon `wisq-agent` (virsh + mode démo), testé bout-à-bout | fait |
| App ↔ agent : démarrage de la VM à la connexion, import des VM d'un agent | fait |
| Appairage `wisq://` (QR via qrencode), découverte Bonjour | fait |
| Linux local : émulateur rv32ima Swift, boot d'un vrai noyau, terminal | fait |

`WisqCore`, `WisqNet` et `WisqRemote` compilent sans erreur ni
avertissement sous Swift 6.3, y compris en concurrence stricte complète, et
leurs tests passent (234 avec ceux du Rust) — dont un bout-à-bout où le vrai
démon est interrogé par le vrai client. La couche `WisqUI` et la cible application demandent UIKit : elles ne
sont vérifiées que par le job macOS de la CI.

## Construire

```sh
brew install xcodegen
xcodegen generate
open Wisq.xcodeproj
```

Les tests du cœur tournent sans Xcode, y compris sur Linux — la couche UI est
retirée du paquet là-bas, précisément pour que ce soit possible :

```sh
./scripts/verify.sh          # cœur : compilation stricte + tests
./scripts/verify.sh --app    # ajoute la compilation de l'app (macOS + Xcode)
```

Sur Linux, le paquet a besoin des en-têtes zlib (`zlib1g-dev` ; l'image Docker
officielle Swift les a déjà).

## Structure

```
Sources/WisqCore     modèle de domaine, persistance, trousseau (Foundation seul)
Sources/WisqNet      transport octets : TCP/TLS, plus un flux mémoire pour les tests
Sources/WisqRemote   protocoles distants : RFB/VNC, agent hôte, emplacements SPICE/RDP
Sources/WisqUI       SwiftUI, pensé téléphone d'abord
Sources/WisqVM       Linux local : cœur rv32ima interprété, machine 64 Mo, UART
crates/wisq-agent    démon hôte (Rust) : serveur HTTP/1.1, backends virsh et démo
crates/wisq-vm       interpréteur rv32ima (Rust) avec une ABI C pour l'application
site/                le site du projet : React 19 sur Bun, pré-rendu, PWA installable
App                  cible application
docs                 architecture, protocole de l'agent, feuille de route
```

Deux langages, répartis selon ce que chaque partie est réellement. Swift
tient l'application, l'interface et le client de bureau distant — du travail
de forme Apple, sur Network.framework. Rust tient ce qui n'est ni l'un ni
l'autre : un démon sans interface, et un interpréteur qui n'est que du calcul
sur un tableau d'octets. Ni l'un ni l'autre n'a de raison d'embarquer un
runtime de langage, et le téléchargement du démon est passé de 58 Mo à moins
de 600 Ko en cessant d'en porter un.

Voir `docs/ARCHITECTURE.md` pour le détail des couches et `docs/ROADMAP.md` pour
la suite.

## Auteur

Créé et développé par [Maxime Nathan Lestage](https://github.com/maxlestage).
Copyright 2026 Maxime Nathan Lestage. Tous droits réservés.

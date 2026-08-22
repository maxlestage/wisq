# wisq

Client de machines virtuelles distantes pour iPhone, en Swift.

wisq se place face à UTM sur un axe différent : plutôt que d'émuler une VM sur le
téléphone — ce qu'iOS punit lourdement en interdisant le JIT — wisq fait de
l'iPhone un client rapide vers des VM qui tournent là où il y a du silicium :
un Mac, un PC, un NAS, un serveur.

| | UTM SE (App Store) | wisq |
|---|---|---|
| Exécution | émulation locale QEMU, interprétée | la VM tourne sur l'hôte |
| Vitesse | très lente (pas de JIT sur iOS) | limitée par le réseau, pas par le CPU |
| Conformité App Store | zone grise, dépendante de la règle 4.7 | client réseau classique |
| Licence | GPL (QEMU) | code applicatif sous notre contrôle |
| Autonomie | l'émulation vide la batterie | décodage d'image seulement |

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
| VNC : ZRLE, Tight (hors JPEG), zlib — flux persistants | fait |
| Interface SwiftUI : liste, éditeur, session, barre de touches | fait |
| Gestes tactiles configurables, inertie, arbitrage | fait |
| Clavier matériel (HID → keysym X11) et clavier logiciel | fait |
| VNC : JPEG dans Tight | à faire |
| SPICE, RDP | à faire |
| Agent hôte (démarrage des VM à distance) | protocole défini, client fait, démon à faire |

`WisqCore`, `WisqNet` et `WisqRemote` compilent sans erreur ni avertissement
sous Swift 6.1, y compris en concurrence stricte complète, et leurs 67 tests
passent. La couche `WisqUI` et la cible application demandent UIKit : elles ne
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
./scripts/verify.sh          # cœur : compilation stricte + 67 tests
./scripts/verify.sh --app    # ajoute la compilation de l'app (macOS + Xcode)
```

Sur Linux, le paquet a besoin des en-têtes zlib (`zlib1g-dev` ; l'image Docker
officielle Swift les a déjà).

## Essayer sans matériel

N'importe quel serveur VNC fait l'affaire :

```sh
# une VM QEMU avec console VNC
qemu-system-x86_64 -m 2048 -vnc :1 -hda disk.qcow2

# ou un bureau Linux existant
x11vnc -display :0 -rfbport 5900 -passwd secret
```

Puis dans wisq : **+**, adresse `hôte:5901`, mot de passe, connexion.

## Structure

```
Sources/WisqCore     modèle de domaine, persistance, trousseau (Foundation seul)
Sources/WisqNet      transport octets : TCP/TLS, plus un flux mémoire pour les tests
Sources/WisqRemote   protocoles distants : RFB/VNC, agent hôte, emplacements SPICE/RDP
Sources/WisqUI       SwiftUI, pensé téléphone d'abord
App                  cible application
docs                 architecture, protocole de l'agent, feuille de route
```

Voir `docs/ARCHITECTURE.md` pour le détail des couches et `docs/ROADMAP.md` pour
la suite.

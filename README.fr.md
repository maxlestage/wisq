# wisq

*This is the French README; the primary one is [README.md](README.md).*

Machines virtuelles sur iPhone, en Swift — distantes à pleine vitesse,
locales dans les règles.

wisq se place face à UTM sur deux fronts à la fois :

- **Distant** : l'iPhone est un client rapide vers des VM qui tournent là où il
  y a du silicium — un Mac, un PC, un NAS, un serveur. C'est le mode principal,
  celui qui donne un vrai bureau à pleine vitesse.
- **Local** : un émulateur RISC-V rv32ima interprété, écrit en Swift, boote un
  vrai noyau Linux **sur le téléphone** en une à deux secondes — sans réseau,
  sans serveur, shell compris. Interprété, donc sans JIT : conforme aux règles
  d'iOS, là où UTM SE vit dans une zone grise.

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

`WisqCore`, `WisqNet`, `WisqRemote` et `WisqAgentKit` compilent sans erreur ni
avertissement sous Swift 6.1, y compris en concurrence stricte complète, et
leurs 117 tests passent — dont un bout-à-bout où le vrai démon est interrogé par
le vrai client. La couche `WisqUI` et la cible application demandent UIKit : elles ne
sont vérifiées que par le job macOS de la CI.

## Installer

**iPhone** : téléchargez l'IPA non signé de la
[dernière release](https://github.com/maxlestage/wisq/releases) et
installez-le avec AltStore ou Sideloadly — ou, avec un Mac et Xcode,
`./scripts/install-ios.sh` compile et installe directement sur l'iPhone
branché (signature personnelle gratuite : à renouveler tous les 7 jours).

**Mac / Linux (l'agent hôte)**, en une ligne :

```sh
curl -fsSL https://raw.githubusercontent.com/maxlestage/wisq/master/scripts/install.sh | sh -s -- --service
```

Ou par Homebrew, servi depuis ce dépôt :

```sh
brew tap maxlestage/wisq https://github.com/maxlestage/wisq.git
brew install maxlestage/wisq/wisq-agent
brew services start wisq-agent
```

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

## Essayer sans matériel

N'importe quel serveur VNC fait l'affaire :

```sh
# une VM QEMU avec console VNC
qemu-system-x86_64 -m 2048 -vnc :1 -hda disk.qcow2

# ou un bureau Linux existant
x11vnc -display :0 -rfbport 5900 -passwd secret
```

Puis dans wisq : **+**, adresse `hôte:5901`, mot de passe, connexion.

Et pour essayer l'agent sans hyperviseur :

```sh
swift run wisq-agent --demo
```

## Structure

```
Sources/WisqCore     modèle de domaine, persistance, trousseau (Foundation seul)
Sources/WisqNet      transport octets : TCP/TLS, plus un flux mémoire pour les tests
Sources/WisqRemote   protocoles distants : RFB/VNC, agent hôte, emplacements SPICE/RDP
Sources/WisqUI       SwiftUI, pensé téléphone d'abord
Sources/WisqVM       Linux local : cœur rv32ima interprété, machine 64 Mo, UART
Sources/WisqAgentKit démon hôte : serveur HTTP POSIX, backends virsh et démo
Sources/wisq-agent   exécutable du démon
App                  cible application
docs                 architecture, protocole de l'agent, feuille de route
```

Voir `docs/ARCHITECTURE.md` pour le détail des couches et `docs/ROADMAP.md` pour
la suite.

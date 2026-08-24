# Feuille de route

## Lot 1 — socle (fait)

Modules, modèle, persistance, trousseau, transport, client VNC RFB 3.8, interface
SwiftUI, gestes tactiles, tests unitaires.

## Lot 2 — VNC utilisable en mobilité (fait)

ZRLE, Tight (JPEG compris, verrouillé sur la présence d'un décodeur), zlib,
flux persistants, mises à jour continues, curseur distant, reconnexion
automatique avec repli exponentiel — le tout testé, reconnexion comprise,
contre des serveurs scriptés. Voir `docs/ARCHITECTURE.md`.

## Lot 3 — RDP

FreeRDP 3 compilé pour iOS/arm64, piloté par une passerelle C mince derrière
`RDPSession`. Points à trancher avant d'écrire du code :

- Construction reproductible en CI plutôt qu'un `xcframework` versionné, qui
  devient un piège dès la première CVE.
- FreeRDP est sous Apache 2.0 : la distribution sur l'App Store ne pose pas le
  problème de licence qui contraint les concurrents fondés sur QEMU.
- NLA/CredSSP d'abord — sans lui, aucun Windows moderne n'accepte la connexion.

## Lot 4 — agent hôte (fait en v1)

Démon écrit et testé bout-à-bout contre le client de l'application : serveur
HTTP POSIX sans dépendance, backend libvirt via `virsh`, backend démo pour
essayer sans hyperviseur. Voir `docs/AGENT-PROTOCOL.md`.

L'application est branchée dessus : à la connexion d'une machine liée à un
agent, wisq démarre la VM si nécessaire, attend sa console et résout l'adresse
et le port avant d'ouvrir la session (`ConsoleResolver`, testé bout-à-bout
contre le démon réel) ; et « Importer depuis un agent » liste les VM d'un hôte
pour les ajouter en machines, liaison comprise.

L'appairage et la découverte sont faits : lien `wisq://agent` imprimé par le
démon (QR via `qrencode` quand il est là), schéma enregistré côté app avec
ouverture directe de l'import pré-rempli, annonce Bonjour best effort côté
démon et navigation `NWBrowser` côté app.

Le TLS de l'agent est fait : certificat auto-signé persistant, empreinte
SHA-256 dans le lien d'appairage, épinglage côté app, `--no-tls` pour les
tunnels. Voir « Transport » dans AGENT-PROTOCOL.md.
La question push contre interrogation est tranchée pour l'instant du côté de
l'interrogation — elle survit aux changements de réseau du téléphone, et le
démon reste sans état par connexion.

## Le cœur Rust (empaquetage, câblage et bascule faits ; défaut à trancher)

`scripts/build-xcframework.sh` produit `CWisqVM.xcframework` — tranche
appareil, tranches simulateur et macOS universelles — et
`scripts/test-ios.sh` fait démarrer un vrai noyau Linux à travers l'ABI C
*dans un iPhone simulé*, via `simctl spawn`. Les deux tournent dans le job
« App iOS » de la CI : la question n'était pas « est-ce que ça compile pour
iOS » mais « est-ce que l'interpréteur tourne sur l'appareil visé », et la
réponse est vérifiée à chaque commit.

L'en-tête `crates/wisq-vm/include/wisq_vm.h` est écrit à la main, donc un
test le compile contre la vraie bibliothèque et démarre un noyau au travers,
sur Linux, à chaque commit : une signature qui dérive de `src/ffi.rs` casse
un test au lieu de corrompre la mémoire sur un téléphone.

Le cœur Rust est maintenant câblé dans le paquet Swift, mais **absent par
défaut** : la cible `WisqVMRust` n'existe que si `WISQ_RUST_CORE` est définie,
parce que la lier suppose un `cargo build` préalable et qu'un clone avec Swift
et rien d'autre doit continuer à se construire et à passer ses tests. Ce que le
drapeau achète : la CI Linux construit les deux interpréteurs et fait démarrer
le *même* noyau à travers chacun, en comparant tous les millions
d'instructions le nombre d'instructions retirées et les octets de console.
`scripts/test-rust-core.sh` fait tourner ça d'une commande.

Ce test a trouvé un vrai défaut le jour où il a été écrit : le bus Rust
répondait aux lectures CLINT `mtime` avec un instantané pris *avant* que le pas
n'avance l'horloge. L'invité voyait donc une horloge en retard d'une tranche —
et de toute la période d'inactivité quand le hart venait d'être réveillé d'un
WFI par un saut d'horloge. Corrigé (`Bus::set_time`) ; les deux cœurs retirent
désormais exactement les mêmes instructions et écrivent exactement les mêmes
octets.

L'application peut désormais tourner dessus. `LocalVMModel` ne nomme plus un
interprète mais `LocalMachine`, un alias que `WISQ_RUST_CORE` fait pointer sur
l'un ou sur l'autre ; seul le CPU change, la console reste `TerminalGrid`. Et
le manifeste choisit tout seul comment la bibliothèque arrive : un `.a` ne
porte aucune plateforme, donc s'il trouve `dist/CWisqVM.xcframework` il le lie
comme cible binaire — c'est Xcode qui prend la bonne tranche — sinon il retombe
sur l'archive et un `-L`. Les deux vendent un module nommé `CWisqVM`, donc
l'enrobage Swift est le même code des deux côtés.

La CI construit l'application des deux façons : les compilations qui expédient
restent sur le cœur Swift, et une compilation simulateur supplémentaire, avec
le drapeau, prouve que l'XCFramework se lie vraiment dans une vraie app iOS.
Sans elle, « l'app peut utiliser le cœur Rust » serait une affirmation que rien
ne vérifie.

Le cœur Swift reste le défaut, et le restera tant que la bascule suppose un
`cargo build` : `swift build` doit continuer à marcher pour qui n'a que Swift.

## Lot 4 bis — Linux local (fait en v1)

`WisqVM` : émulateur rv32ima interprété en Swift, boot d'un vrai noyau 6.1
jusqu'au shell, import d'images par Fichiers, et une vraie grille VT100
(`TerminalGrid`) : adressage curseur, effacements, région de défilement,
écran alterné, retour à la ligne différé — de quoi faire vivre un éditeur,
un pager, `top`. Suite possible : images téléchargeables depuis l'app,
stockage persistant (un bloc device 9P ou virtio-blk), et un cœur rv64 avec
MMU pour des distributions complètes — chacun un chantier distinct.

## Lot 5 — SPICE

Le protocole multi-canaux, dans l'ordre où les canaux doivent monter : main,
inputs, display, cursor. Intéressant surtout parce que c'est la console par
défaut de QEMU/libvirt, donc de l'écrasante majorité des VM que l'agent gérera.

## Lot 6 — finition

- iPad : curseur système, multi-fenêtres, pointeur indirect (souris et trackpad).
- Raccourcis Siri et widgets « se connecter à … ».
- Import depuis les fichiers `.vv` (SPICE) et `.rdp`.
- Partage de fichiers via un dossier monté côté agent.

## Ce qu'on doit à UTM

Leur client iOS a dix ans d'avance sur le toucher, et il est sous Apache 2.0.
Rien n'a été copié — tout est réécrit en Swift — mais quatre idées viennent de
là : l'inertie confiée à `UIDynamicItem` plutôt qu'à une boucle maison, le délai
de 50 ms entre appui et relâchement, la matrice d'arbitrage des reconnaisseurs de
gestes, et le principe même de rendre l'affectation des gestes configurable
plutôt que de figer un jeu.

## Contraintes à garder en tête

**La règle 4.7 de l'App Store ne nous concerne pas.** C'est l'angle mort des
concurrents fondés sur l'émulation locale : leur sort dépend de l'interprétation
qu'Apple fait d'une règle écrite pour les émulateurs de consoles rétro. wisq est
un client réseau, catégorie aussi ancienne que l'App Store.

**Pas de JIT, donc pas de course à la vitesse d'émulation.** iOS n'accorde de
mémoire exécutable qu'aux applications signées pour le développement. Toute
émulation locale sur iPhone est interprétée, donc lente d'un ordre de grandeur.
C'est précisément pourquoi déporter l'exécution est le bon compromis.

**Le réseau est le budget.** Chaque décision — encodages, format de pixel,
mises à jour incrémentales — se juge en octets par image et en millisecondes de
latence, pas en cycles CPU.

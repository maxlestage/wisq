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

## Le cœur Rust (fait : empaquetage, câblage, bascule, et c'est le défaut)

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

Le cœur Rust est câblé dans le paquet Swift par la cible `WisqVMRust`, et la
CI Linux construit les deux interpréteurs pour faire démarrer le *même* noyau à
travers chacun, en comparant tous les millions d'instructions le nombre
d'instructions retirées et les octets de console. `scripts/test-rust-core.sh`
fait tourner ça d'une commande. C'est ce test qui rend la bascule défendable
plutôt qu'imprudente : sans lui, changer le moteur sous l'application serait un
changement que personne ne peut vérifier.

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

La CI construit l'application des deux façons — Rust par défaut, Swift avec
`WISQ_SWIFT_CORE=1` — sur Linux comme sur macOS. L'échappatoire est une phrase
que le manifeste imprime aux gens ; une échappatoire que rien ne compile est
une échappatoire déjà pourrie.

Et c'est désormais le défaut : le cœur Rust est celui que l'app embarque. Le
prix est une seconde chaîne d'outils — `cargo build --release -p wisq-vm`, plus
`scripts/build-xcframework.sh` pour l'app — et `WISQ_SWIFT_CORE=1` rend
l'ancien comportement à qui n'a que Swift. Quand la bibliothèque manque, le
manifeste s'arrête et affiche la commande à lancer : retomber silencieusement
sur le cœur Swift ferait dépendre l'interprète expédié de ce qui se trouvait
installé sur la machine de build, et une release coupée là-dessus embarquerait
le cœur lent sans que rien ne le signale.

## Lot 4 bis — Linux local (fait en v1)

`WisqVM` : émulateur rv32ima interprété en Swift, boot d'un vrai noyau 6.1
jusqu'au shell, import d'images par Fichiers, et une vraie grille VT100
(`TerminalGrid`) : adressage curseur, effacements, région de défilement,
écran alterné, retour à la ligne différé — de quoi faire vivre un éditeur,
un pager, `top`. Suite possible : images téléchargeables depuis l'app,
stockage persistant (un bloc device 9P ou virtio-blk), et un cœur rv64 avec
MMU pour des distributions complètes — chacun un chantier distinct.

## La machine suspendue (fait)

Une VM locale qui s'efface quand on quitte l'application n'est pas une machine,
c'est une démonstration. iOS reprend le processus dès que l'écran s'éteint, donc
la question n'est pas *si* la machine est interrompue mais ce qu'il en reste.

Le format d'instantané (`crates/wisq-vm/src/snapshot.rs`, et son jumeau
`Sources/WisqVM/Snapshot.swift`) écrit l'état entier : les 48 mots du CPU, la
RAM, la file d'entrée en attente et la sortie pas encore remise à la console.
Les longues plages de zéros sont repliées en paires (zéros, littéraux), ce qui
ramène 64 Mio de RAM fraîchement démarrée à une quinzaine de mégaoctets — la
mémoire d'un Linux qui vient de démarrer est surtout vide.

Le disque aurait été l'autre réponse, et c'est la mauvaise ici : un bloc device
persiste les *fichiers*, pas la session. L'utilisateur qui revient veut son
shell là où il l'a laissé, pas un second démarrage de quarante secondes vers un
disque qui contient ses fichiers.

Trois propriétés sont tenues par des tests plutôt que par un raisonnement :

- **Les deux cœurs écrivent les mêmes octets.** `SnapshotAgreementTests` compare
  les instantanés Swift et Rust octet pour octet, puis fait reprendre chaque
  cœur depuis l'instantané de l'autre et vérifie qu'ils arrivent au même futur.
  Sans ça, le jour où l'application change de cœur, les machines enregistrées
  cessent de s'ouvrir.
- **Un fichier tronqué est refusé, pas exécuté.** Chaque troncature possible est
  testée, en Rust comme en Swift : un instantané abîmé produit une erreur, jamais
  une machine à moitié restaurée.
- **Le premier enregistrement fonctionne.** C'est le cas qu'une implémentation
  bâtie sur « remplacer le fichier existant » rate — et ratait ici, avant
  `testTheFirstSaveWorksWithNothingToReplace`.

Côté application, `SuspendedMachine` range un instantané par noyau, le nom du
noyau étant dans le nom de fichier : restaurer une machine démarrée depuis une
image dans une session ouverte avec une autre ressusciterait la mauvaise chose,
et un noyau qui ne correspond pas doit simplement vouloir dire « rien
d'enregistré ». L'écriture est atomique parce que le moment où elle se produit
est exactement celui où iOS retire l'application.

La couche application n'est plus l'angle mort. `WisqUI` est `#if os(iOS)`,
donc aucun runner Linux ne la compile — et c'est exactement là que trois
défauts se sont logés : « Arrêter » sauvegardait la machine qu'il venait de
terminer, une machine mise de côté quand iOS retirait l'application n'était
jamais reprise au retour, et la sortie qui suit un arrêt était avalée, laissant
le modèle bloqué sur une machine qu'il ne relâchait plus. Aucun n'était visible
à la compilation. `scripts/test-app.sh` fait tourner le vrai modèle contre le
vrai interprète dans un iPhone simulé, à chaque commit.

Une machine enregistrée est classée sous **les octets** de son noyau, pas sous
son nom. Le nom seul était la première réponse et ne suffisait pas : les images
arrivent par Fichiers, et `Image` est le nom de presque toutes — deux noyaux
différents importés à une semaine d'écart partagent ce nom, et le second
héritait de la machine du premier. Le nom reste devant le condensé, mais
seulement pour qu'un humain qui ouvre le dossier puisse s'y retrouver.

Le condensé est un FNV-1a 64 bits écrit ici plutôt que le `SHA256` de `WisqNet`,
qui rend `Data()` vide sur toute plateforme sans CryptoKit — c'est-à-dire celle
où tournent tous ces tests. Un condensé qui ne fonctionne que là où il n'est pas
vérifié est pire que pas de condensé.

Et « Oublier » jette la machine enregistrée sans arrêter celle qui tourne :
« Arrêter » l'efface aussi, mais en mettant fin à la session, alors qu'un
utilisateur dont l'invité est coincé veut partir maintenant et revenir propre.

La question de « l'instantané plus vieux que son image » ne se pose plus : une
image modifiée est une autre clé, donc rien d'enregistré et un démarrage propre.
C'était la réponse complète, pas une réponse partielle.

## Lot 5 — SPICE (le lien est fait)

Le protocole multi-canaux, dans l'ordre où les canaux doivent monter : main,
inputs, display, cursor. Intéressant surtout parce que c'est la console par
défaut de QEMU/libvirt, donc de l'écrasante majorité des VM que l'agent gérera.

`SpiceWire` porte le format : magie `REDQ`, versions, message de lien et sa
réponse, en-tête de données de 18 octets, `MAIN_INIT`, liste des canaux, ping,
acquittements, notifications. C'est du pur encodage sur des octets, sans socket
ni acteur — donc chaque règle de cadrage est vérifiée par un test qui n'a besoin
ni de serveur ni de réseau. C'est là que vivent les défauts de protocole, et
c'est la couche qu'un runner qui ne coûte rien peut éprouver à fond.

Petit-boutiste de bout en bout, ce qui est la première chose qui sépare SPICE du
code RFB d'à côté : les lecteurs de `ByteStream` sont gros-boutistes parce que
RFB l'est, et les réutiliser ici serait faux d'une manière qui marcherait quand
même la plupart du temps — une longueur de 1 se lit pareil dans les deux sens.
D'où un lecteur à part plutôt qu'un emprunt.

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

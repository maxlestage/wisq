# Feuille de route

## Lot 1 — socle (fait)

Modules, modèle, persistance, trousseau, transport, client VNC RFB 3.8, interface
SwiftUI, gestes tactiles, tests unitaires.

## Lot 2 — VNC utilisable en mobilité (fait, sauf JPEG)

ZRLE, Tight et zlib sont implémentés, adossés à des flux zlib persistants pour
toute la session. Voir `docs/ARCHITECTURE.md`, section « La compression ».

Ce qui reste dans ce lot :

- **JPEG dans Tight.** Absent volontairement : un serveur n'envoie du JPEG que
  si le client annonce un niveau de qualité, et nous n'en annonçons aucun. Cela
  garde la couche protocolaire testable sur Linux. Sur un lien cellulaire c'est
  pourtant exactement ce qu'on veut — l'ajouter demande d'annoncer une qualité
  et de décoder via ImageIO côté Apple, derrière une interface que Linux laisse
  vide.
- **Mises à jour continues** (`EnableContinuousUpdates`) pour cesser de demander
  chaque image.
- **Curseur distant** (pseudo-encodage `Cursor`, -239) pour dessiner le vrai
  curseur de l'invité au lieu du rond blanc.
- **Reconnexion automatique** quand le téléphone change de réseau : c'est le
  défaut le plus visible de tous les clients VNC iOS existants. Attention, la
  reconnexion doit repartir de flux zlib neufs — un dictionnaire hérité de la
  session précédente décode en bouillie.

## Lot 3 — RDP

FreeRDP 3 compilé pour iOS/arm64, piloté par une passerelle C mince derrière
`RDPSession`. Points à trancher avant d'écrire du code :

- Construction reproductible en CI plutôt qu'un `xcframework` versionné, qui
  devient un piège dès la première CVE.
- FreeRDP est sous Apache 2.0 : la distribution sur l'App Store ne pose pas le
  problème de licence qui contraint les concurrents fondés sur QEMU.
- NLA/CredSSP d'abord — sans lui, aucun Windows moderne n'accepte la connexion.

## Lot 4 — agent hôte

Le démon décrit dans `docs/AGENT-PROTOCOL.md` : un binaire Swift, libvirt quand
il est disponible, QEMU direct sinon. Appairage par QR code. C'est ce qui
transforme wisq d'« un client VNC de plus » en « mes VM, depuis mon téléphone » :
on ouvre l'application, on tape une VM éteinte, elle démarre, la console
s'affiche.

À trancher au moment de l'écrire : notre protocole interroge l'agent en boucle
pendant un démarrage, là où UTM Remote garde une connexion permanente et pousse
les changements d'état (`virtualMachineDidTransition`). Le push donne un état
instantané ; l'interrogation survit mieux à un téléphone qui change de réseau
toutes les dix minutes. Le bon compromis est sans doute le push avec repli sur
l'interrogation à la reconnexion — mais cela se décide avec le démon sous les
yeux, pas avant.

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

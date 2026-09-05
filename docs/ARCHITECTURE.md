# Architecture

## Principe

Des modules empilés, chacun ne connaissant que celui du dessous.

```
WisqUI        SwiftUI, gestes, rendu           ──┐
WisqRemote    RFB/VNC, SPICE, RDP, agent hôte  ──┤ dépendances descendantes
WisqVM        l'émulateur local (voir plus bas) ─┤ uniquement
WisqNet       octets : TCP, TLS, flux mémoire  ──┤
WisqCore      modèle, persistance, secrets     ──┘
```

`WisqCore` n'importe que Foundation — plus Security derrière un
`#if canImport`, pour le trousseau, avec un magasin en mémoire là où Security
n'existe pas. C'est ce qui rend le modèle testable sans simulateur, et ce qui
permettra plus tard une cible macOS ou visionOS sans démêler des dépendances
UIKit.

## Le flux d'une session

```
SessionModel ──connect()──▶ SessionFactory ──▶ VNCSession (actor)
     ▲                                              │
     │                                              ├─▶ NetworkByteStream (actor)
     │  AsyncStream<SessionEvent>                   │
     └──────────────────────────────────────────────┤
                                                    └─▶ Framebuffer (partagé)
RemoteDisplayView ──lit le Framebuffer──▶ CGImage ──▶ CALayer
```

Points de conception qui comptent :

**Un acteur par session.** `VNCSession` est un `actor` : la pompe de messages,
les écritures d'entrées et l'arrêt ne peuvent pas se marcher dessus. L'UI ne
touche jamais à la socket.

**Le framebuffer est partagé, pas copié par événement.** Le décodeur écrit
dedans, la vue en prend un instantané au moment de redessiner. L'événement
`framebufferChanged` ne transporte que les rectangles modifiés — un `Data` de
8 Mo par image traverserait l'`AsyncStream` sinon.

**Le format de pixel est négocié pour le rendu, pas pour le réseau.** wisq
demande du 32 bits petit-boutiste avec les décalages R=16, G=8, B=0. En mémoire
cela donne B,G,R,X — exactement ce que consomment `CGImage`
(`byteOrder32Little` + `noneSkipFirst`) et Metal. Le décodage Raw devient une
copie, sans passe de conversion par image.

**Le transport est une abstraction.** `ByteStream` a deux implémentations :
`NetworkByteStream` (Network.framework) et `MemoryByteStream`. La seconde permet
de tester une poignée de main complète sans ouvrir de socket — c'est ce que
fait `VNCHandshakeTests`.

## Le modèle tactile

Un bureau suppose un curseur, deux boutons et une molette. Un iPhone n'a rien de
tout cela. Un doigt pilote toujours le pointeur ; le reste est configurable, par
machine :

| Geste | Par défaut | Configurable |
|---|---|---|
| un doigt qui glisse | déplace le pointeur (relatif en trackpad, absolu en tactile direct) | non |
| tape | clic gauche | non |
| tape à deux doigts | clic droit | oui |
| appui long | clic droit | oui (dont « glisser ») |
| deux doigts qui glissent | molette | oui |
| trois doigts qui glissent | déplace la vue | oui |
| balayage à trois doigts | affiche / masque le clavier | oui |
| pincement | zoom | non |
| double-tape | affiche ou masque la barre d'outils | non |

Rendre ces gestes configurables plutôt que d'en figer un jeu est la leçon d'UTM :
personne ne s'accorde sur ce que deux doigts devraient faire, et la bonne réponse
dépend surtout de si le bureau distant tient sur l'écran du téléphone. Déplacer
une vue qui n'a nulle part où aller est du geste gaspillé.

Le mode trackpad est le défaut : viser un bouton de 12 pixels avec un doigt de
9 mm ne marche pas, et le curseur virtuel donne le retour visuel qui manque.

Trois détails font toute la différence de toucher :

**L'inertie.** Le pointeur et la molette continuent sur leur lancée quand le
doigt se lève. UIKit intègre déjà vitesse et résistance à chaque image :
`InertialTracker` se conforme à `UIDynamicItem` et laisse
`UIDynamicItemBehavior` faire le travail, sans boucle d'animation maison. Le
pointeur glisse loin (résistance 50), la molette s'arrête vite (résistance 10).

**Le délai entre l'appui et le relâchement.** Un clic ou une frappe synthétisés
envoient leurs deux fronts à 50 ms d'intervalle. Les envoyer dans le même instant
est le bug classique du bureau distant : un invité qui échantillonne ses entrées
sur une horloge ne voit rien du tout.

**L'arbitrage des reconnaisseurs.** Sans `shouldRequireFailureOf`, une tape à
deux doigts se lit aussi comme une tape simple, et l'appui long se déclenche sous
chaque tape qui s'attarde.

Le curseur virtuel est dessiné dans un `CAShapeLayer` séparé de la couche des
pixels : il peut bouger à 120 Hz sans re-rastériser le bureau.

## Les deux claviers

Une seule vue invisible (`KeyCaptureUIView`) porte les deux. Elle reste premier
répondeur toute la session — c'est la condition pour recevoir les frappes d'un
clavier matériel — et bascule son `inputView` entre `nil` et une vue vide pour
faire apparaître ou non le clavier logiciel.

Le clavier matériel rapporte des codes HID ; RFB et SPICE parlent des keysyms
X11. `HIDKeyMap` fait la traduction. C'est le pendant de la table HID → PS/2
d'UTM, en plus court : SPICE veut des scancodes, RFB veut des keysyms.

Les modificateurs de la barre de touches sont collants — ctrl, puis une lettre,
et la paire part ensemble — puis relâchés après la frappe suivante.

## La compression

C'est ce qui sépare un client de LAN d'un client utilisable en mobilité. Un
bureau 1080p en Raw, c'est 8 Mo par image complète.

Trois encodages compressés, tous adossés à zlib :

| Encodage | Ce que c'est |
|---|---|
| **zlib** (6) | des pixels Raw passés dans le flux. Le repli minimal. |
| **ZRLE** (16) | tuiles de 64×64, chacune choisissant entre pixels bruts, couleur unie, palette compactée ou séries. |
| **Tight** (7) | quatre flux zlib au choix du serveur, trois filtres, et « sous douze octets, ne compresse pas ». Le meilleur ratio sans perte. |

**Les flux zlib vivent aussi longtemps que la session.** C'est le point qui rend
ces encodages délicats : le dictionnaire se construit d'un rectangle à l'autre,
et c'est de là que vient le taux de compression. Corollaire désagréable — un
seul octet mal analysé corrompt toutes les images suivantes, pas seulement
celle en cours. D'où le soin mis à rejeter explicitement tout sous-encodage
réservé plutôt que de tenter une interprétation.

Deux pièges de format valent d'être notés, parce qu'ils se ressemblent
exactement assez pour qu'on les confonde :

- Le **CPIXEL** de ZRLE porte les trois octets de couleur *dans l'ordre du
  format négocié*. Chez nous, petit-boutiste, cela donne B, G, R.
- Le **TPIXEL** de Tight est **toujours** R, G, B, quels que soient les
  décalages négociés.

Les inverser produit une image en fausses couleurs, pas une erreur.

Le **JPEG de Tight est verrouillé sur la présence d'un décodeur.** Un serveur
n'a le droit d'envoyer du JPEG que si le client a annoncé un niveau de
qualité ; wisq ne l'annonce que là où `JPEGDecoder` existe — ImageIO, donc les
plateformes Apple. Sur Linux rien n'est annoncé et un serveur conforme n'envoie
jamais de JPEG : la couche protocolaire y reste testable sans décodeur d'image,
et un JPEG qui arriverait quand même est une erreur nommée, pas un rectangle
deviné.

Le choix d'ordre des encodages annoncés dépend du débit : sur lien rapide ZRLE
passe devant Tight, parce que le coût de décodage compte alors plus que les
derniers pour-cent de ratio.

## Sécurité

- Les mots de passe vont dans le trousseau
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), jamais dans le JSON de la
  bibliothèque, jamais dans une sauvegarde iCloud.
- L'authentification VNC historique est du DES sur un défi de 16 octets. C'est
  faible par construction — d'où l'avertissement affiché dans l'éditeur quand le
  chiffrement de transport est désactivé, et l'implémentation DES cantonnée à ce
  seul usage.
- `TransportSecurity.tlsPinned` épingle sur le chemin machine quand la machine
  porte une empreinte (`Machine.certificateFingerprint`, saisie dans l'éditeur
  et portée par `SessionConfiguration` jusqu'à `NetworkByteStream`) ; sans
  empreinte, `ResolvedTransportSecurity` en fait une validation système
  complète — jamais une connexion qui accepte n'importe quel certificat, ce
  que ce cas est devenu un temps avant d'être corrigé. La machine le dit
  elle-même (`transportDescription`). Le chemin agent épingle par une autre
  route : `AgentBinding` garde l'empreinte relevée à l'appairage et
  `AgentClient` la prend en paramètre non optionnel.
  Le plan pour donner la même chose au chemin machine est dans
  `docs/ROADMAP.md`.

## Le Linux local

`WisqVM` est l'exception assumée au « la VM tourne sur l'hôte » : un émulateur
rv32ima interprété, portage Swift de la sémantique de mini-rv32ima (Charles
Lohr, MIT) — la plus petite machine connue qui boote un vrai noyau Linux. Un
hart RV32 IMA + Zicsr, modes machine et utilisateur, pas de MMU ; 64 Mo de RAM,
un UART 8250, un CLINT, un syscon. Le device tree est celui de la machine de
référence, embarqué tel quel.

Il existe en deux exemplaires : le portage Swift et un cœur Rust
(`crates/wisq-vm`), et **c'est le cœur Rust que l'application embarque par
défaut** — la CI fait démarrer le même noyau à travers les deux et compare,
tous les millions d'instructions, le nombre d'instructions retirées et les
octets de console. Seul le CPU change ; la console, l'instantané machine et
l'interface sont les mêmes des deux côtés.

L'interprétation est le choix, pas un pis-aller : iOS n'accorde de mémoire
exécutable qu'aux applications signées pour le développement, donc un JIT
n'a jamais été une option — et un interprète est irréprochable côté App Store
(précédent : iSH). En pratique l'interprète Swift dépasse le milliard
d'instructions par seconde en build release sur x86 ; un noyau 6.1 atteint son
invite de connexion en une à deux secondes.

L'horloge virtuelle avance avec les instructions exécutées, pas avec le temps
réel : un démarrage est déterministe sur toute machine qui l'exécute, ce qui
rend le boot testable en CI. Le test de référence charge le même noyau que
l'émulateur d'origine et lit sa bannière sur l'UART ; en local, le même
harnais va jusqu'au shell et fait exécuter une commande par l'invité.

Deux détails qui ont mordu :

- Les invites se terminent sans saut de ligne. Le tampon de sortie de l'UART
  était vidé sur `\n` ou 256 octets : une invite restait invisible exactement
  au moment où la machine attendait l'utilisateur. D'où le vidage périodique.
- La console série émet des séquences ANSI, et la console est une vraie
  grille de cellules (`TerminalGrid`) : adressage curseur, effacements,
  région de défilement, écran alterné — de quoi faire vivre un éditeur, un
  pager, `top`. La v1 filtrait les séquences vers du texte brut ; la grille
  l'a remplacée, et elle sert les deux cœurs, Swift comme Rust — seul le CPU
  change.

### Deux architectures, et trois sortes de fichiers

Depuis le lot 7 la machine locale n'est plus seulement rv32 : un fichier peut
demander un cœur x86-64. Ce n'est pas un réglage — `KernelImageKind` lit les
premiers quarante kibioctets et `GuestArchitecture.core` en déduit le cœur.

Ce qui suit de là est que la bibliothèque contient **trois sortes de fichiers**
au lieu d'une, et qu'aucune règle sur les octets ne les sépare complètement :

| ce que la personne apporte | ce que wisq en fait | qui décide |
| --- | --- | --- |
| un noyau | il démarre | les octets (`KernelImageKind`) |
| un initramfs | déballé par le noyau | le nom, puis la personne (`BootMedia`) |
| un disque | branché sur `/dev/vda` | la personne (`LocalDisk`) |

Un noyau compressé et un initramfs compressé sont l'un et l'autre un flux
gzip : c'est un fait sur les octets, pas une paresse, et il commande la forme
de tout le reste. `BootMedia` apparie sur les noms et ne refuse que ce qui
n'est sûrement pas un initramfs ; `LocalDisk` ne devine pas du tout — le
disque est un choix, retenu sous le nom du noyau dans `kernel-disk.json`, à
côté du réglage de mémoire.

**Le disque est tenu en mémoire, entier**, et c'est le fait qui commande son
plafond : `VirtioBlock` garde son image dans un tableau d'octets parce que
l'invité écrit dedans et que l'instantané emporte ces écritures. Un disque de
deux cents mébioctets coûte donc deux cents mébioctets, à côté de la RAM de
l'invité — d'où un plafond qui est « ce que le téléphone laisse, moins la plus
petite machine PC », et un changement de disque qui oublie les machines
sauvegardées de ce noyau.

La machine rv32, elle, **refuse** un disque et un initramfs, nommément
(`GuestMachineRefusal`) : son noyau nommu n'a aucun pilote bloc, et accepter
en silence donnerait un démarrage qui échoue quatre milliards d'instructions
plus loin, sans rapport visible avec la cause.

## SPICE : une connexion par canal

C'est la forme qui sépare SPICE du RFB d'à côté, et elle traverse tout le
reste. RFB, c'est une socket ; SPICE, c'est **une socket par canal**.

Le canal principal s'ouvre en premier parce qu'il est le seul à apprendre
l'identifiant de session, et chaque canal suivant doit le présenter comme
identifiant de connexion. Sans ça, le serveur ne voit pas un second canal : il
voit un second *client*, et lui donne un affichage à lui — un écran noir qui
ressemble exactement à un décodeur cassé. C'est la panne la plus coûteuse à
diagnostiquer de tout le protocole, et c'est une ligne de code.

    principal ──▶ identifiant de session, agent (presse-papiers, fichiers)
                     ├──▶ display   (surfaces, dessins, images, flux vidéo)
                     ├──▶ entrées   (clavier, souris)      meilleur effort
                     ├──▶ curseur   (image du pointeur)    meilleur effort
                     ├──▶ lecture   (le son de l'invité)   meilleur effort
                     └──▶ record    (le micro du téléphone) meilleur effort

Tout sauf le display est en meilleur effort, et c'est un choix : un serveur qui
n'offre pas un canal donne quand même une session utilisable. Un écran sans
clavier vaut d'être montré ; refuser de démarrer échangerait quelque chose
contre rien.

Chaque canal compte ses propres numéros de série. Un compteur partagé entre deux
connexions donnerait à chacune une suite trouée, et un serveur qui acquitte par
numéro aurait raison de s'en plaindre.

Le curseur a sa propre connexion pour continuer de bouger pendant que le canal
display envoie un écran entier de pixels. Sur un téléphone, c'est la différence
entre un pointeur qui suit le doigt et un pointeur qui traîne derrière un
rafraîchissement.

### Ce que le client demande

Un serveur SPICE choisit son encodage d'image selon sa propre configuration, et
le défaut habituel est « automatique » : QUIC pour le photographique, GLZ pour
le graphique. wisq décode aujourd'hui les quatre codecs du canal — LZ, QUIC,
GLZ, LZ4 — et demande donc `AUTO_GLZ`, le mode que les serveurs servent le
mieux. La demande a suivi les décodeurs : `LZ` quand LZ était seul, `AUTO_LZ`
quand QUIC est arrivé, `AUTO_GLZ` quand la fenêtre GLZ a été branchée — parce
que décoder un codec et se faire envoyer ce codec sont deux réussites
distinctes, et seule la seconde met une image à l'écran.

### « Pas implémenté » n'est pas « malformé »

La distinction autour de laquelle la pompe est bâtie. Un encodage que wisq ne
décode pas laisse cette partie de l'écran tranquille et se compte ; un message
qui n'a pas de sens arrête la pompe. Confondre les deux déconnecte un téléphone
parce qu'un serveur a envoyé un JPEG.

## Ce qui n'est pas là

Côté RDP, ce qui manque est nommé dans `docs/ROADMAP.md` : NLA/CredSSP — donc
les Windows modernes, qui l'exigent par défaut —, les canaux virtuels et avec
eux le presse-papiers, le curseur distant, la renégociation de taille en cours
de session, et les codecs RemoteFX et H.264. La sécurité employée aujourd'hui
n'authentifie pas le serveur, et l'application le dit plutôt que de le taire.

Côté SPICE, le canal display est complet — LZ, QUIC, GLZ, LZ4, JPEG, les
formes à palette, tous les messages de dessin — et l'agent du canal principal
porte le presse-papiers et l'envoi de fichiers vers l'invité. Ce qui manque
vraiment : les codecs vidéo des flux (VP8/9, H.264/5 — seul MJPEG est décodé,
et uniquement là où ImageIO existe), les codecs audio compressés (Opus, CELT —
seul le PCM brut passe), et la sortie comme la capture audio elles-mêmes, qui
demandent AVAudioEngine et n'existent donc que côté Apple. Chacun est nommé à
l'utilisateur plutôt que rangé sous « inconnu » : « le serveur a choisi
H.264 » est une explication sur laquelle on peut agir, un rectangle figé n'en
est pas une.

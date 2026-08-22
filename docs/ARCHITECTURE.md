# Architecture

## Principe

Quatre modules, empilés, chacun ne connaissant que celui du dessous.

```
WisqUI        SwiftUI, gestes, rendu           ──┐
WisqRemote    RFB/VNC, SPICE, RDP, agent hôte  ──┤ dépendances descendantes
WisqNet       octets : TCP, TLS, flux mémoire  ──┤ uniquement
WisqCore      modèle, persistance, secrets     ──┘
```

`WisqCore` n'importe que Foundation. C'est ce qui rend le modèle testable sans
simulateur, et ce qui permettra plus tard une cible macOS ou visionOS sans
démêler des dépendances UIKit.

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

Le **JPEG est délibérément absent** de Tight. Un serveur n'a le droit d'envoyer
du JPEG que si le client a annoncé un niveau de qualité ; wisq n'en annonce
aucun. Ce n'est pas un contournement : c'est ce qui garde la couche protocolaire
libre de tout décodeur d'image spécifique à une plateforme, et donc testable sur
Linux. L'ajouter voudra dire annoncer un niveau de qualité et décoder via
ImageIO côté Apple.

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
- `TransportSecurity.tlsPinned` fait du TOFU : on accepte le certificat au
  premier contact et on le compare ensuite. Les labos personnels tournent en
  auto-signé ; refuser sèchement ferait retomber les gens sur du texte clair,
  ce qui est pire.

## Le Linux local

`WisqVM` est l'exception assumée au « la VM tourne sur l'hôte » : un émulateur
rv32ima interprété, portage Swift de la sémantique de mini-rv32ima (Charles
Lohr, MIT) — la plus petite machine connue qui boote un vrai noyau Linux. Un
hart RV32 IMA + Zicsr, modes machine et utilisateur, pas de MMU ; 64 Mo de RAM,
un UART 8250, un CLINT, un syscon. Le device tree est celui de la machine de
référence, embarqué tel quel.

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
- La console série émet des séquences ANSI ; la vue terminal v1 est du texte
  brut, donc `ANSIFilter` retire les séquences et rejoue `\r` et retour
  arrière comme un terminal le ferait. Une vraie grille de cellules VT100
  pourra remplacer cela plus tard.

## Ce qui n'est pas là

`SPICESession` et `RDPSession` existent, se conforment à `RemoteSession` et
échouent proprement avec `unsupportedProtocol`. Ce n'est pas de l'ornement : cela
fige la surface que les implémentations devront respecter, et cela permet à
l'éditeur de machine de déjà modéliser les trois protocoles.

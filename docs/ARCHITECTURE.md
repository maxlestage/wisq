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
tout cela. La répartition retenue :

| Geste | Effet |
|---|---|
| un doigt qui glisse | déplace le curseur (relatif en mode trackpad, absolu en tactile direct) |
| tape | clic gauche |
| tape à deux doigts | clic droit |
| appui long | clic droit |
| deux doigts qui glissent | molette si l'écran est entièrement visible, sinon déplacement de la vue |
| pincement | zoom |
| double-tape | affiche ou masque la barre d'outils |

Le mode trackpad est le défaut : viser un bouton de 12 pixels avec un doigt de
9 mm ne marche pas, et le curseur virtuel donne le retour visuel qui manque.

Le curseur virtuel est dessiné dans un `CAShapeLayer` séparé de la couche des
pixels : il peut bouger à 120 Hz sans re-rastériser le bureau.

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

## Ce qui n'est pas là

`SPICESession` et `RDPSession` existent, se conforment à `RemoteSession` et
échouent proprement avec `unsupportedProtocol`. Ce n'est pas de l'ornement : cela
fige la surface que les implémentations devront respecter, et cela permet à
l'éditeur de machine de déjà modéliser les trois protocoles.

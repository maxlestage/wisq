# Feuille de route

> Les sessions où le travail avance sans personne devant l'écran sont
> consignées dans [`JOURNAL.md`](JOURNAL.md) — l'autorisation qui les a
> ouvertes, et ce qui a été décidé.


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

## Lot 5 — SPICE (format, lien, entrées, affichage, curseur et presse-papiers faits)

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

`SpiceLink` mène la poignée de main sur n'importe quel flux d'octets, et
`SpiceMainChannel` la boucle du canal principal jusqu'à la liste des canaux —
`MAIN_INIT`, `ATTACH_CHANNELS`, ping, acquittements, notifications.

Le chiffrement du ticket est **une fermeture, pas un appel**, et c'est toute la
raison pour laquelle le lien est testable. SPICE chiffre son ticket en RSA :
sur Apple cela veut dire `Security`, sur Linux cela ne veut rien dire du tout.
L'appeler directement aurait mis toute la séquence derrière une plateforme que
la CI n'a pas, et l'ordre, la négociation de capacités, le cadrage et chaque
refus seraient passés sans vérification. `WisqNet.SHA256` a déjà fait cette
erreur dans l'autre sens — il rend `Data()` vide sans CryptoKit, donc un
condensé bâti dessus passe ses tests en étant d'accord avec lui-même sur rien.

Ce qu'un bouchon ne vérifie pas, c'est le chiffrement lui-même, et les tests ne
prétendent pas le contraire. Ils vérifient tout ce qui l'entoure, là où sont les
défauts.

`SpiceInputs` encode le canal des entrées, et `SpiceScancode` fait la traduction
qui va avec. C'est là qu'est le vrai travail : **RFB prend des keysyms, SPICE
prend des scancodes PC AT**. `InputEvent.key` affirmait en commentaire que son
keysym valait « pour RFB et SPICE » ; c'était faux, et un backend qui l'aurait
transmis tel quel n'aurait rien tapé de reconnaissable. Le commentaire est
corrigé en même temps que la table existe.

Les pièges que les tests tiennent : le préfixe `0xE0` des touches étendues, sans
lequel les flèches deviennent le pavé numérique ; une touche inconnue qui
n'envoie rien plutôt qu'un code deviné, parce qu'un clavier qui ment est pire
qu'un clavier incomplet ; la molette qui n'entre pas dans le masque des boutons
tenus, mais qui garde le bouton d'un glisser en cours ; et une coordonnée
négative bornée plutôt qu'enroulée à quatre milliards.

`SpiceDisplayWire` décode le canal display : géométrie, découpe, surfaces,
descripteurs d'image, `DRAW_FILL` et `DRAW_COPY`. Écrit **avec la spécification
sous les yeux** — `spice.proto` et le démarshaleur que `spice_codegen.py` en
engendre — et pas de mémoire, parce que c'est là qu'était le piège annoncé :

**Un pointeur SPICE est un `uint32` qui vaut un décalage depuis le début du
message**, pas depuis le champ qui le porte, et pas une longueur. Zéro vaut
nul. Un décalage au-delà de la fin est une erreur, pas un plafonnement. Ces
quatre lignes sont toute la raison pour laquelle ce fichier n'existait pas
avant : un décodeur qui devine ce qu'est un pointeur produit un analyseur
plausible qui lit les mauvais octets.

Ce que les tests tiennent : l'ordre `top, left, bottom, right` d'un rectangle,
qui n'est pas celui qu'on suppose et qui transpose tout si on le suppose ; la
découpe est **en ligne** et non derrière un pointeur, parce que le `@to_ptr` de
la spécification parle de la structure C et pas du fil ; un type de découpe
inconnu est refusé plutôt que pris pour « aucune découpe », ce qui peindrait
par-dessus ce que le serveur demandait d'épargner ; un format de surface
inconnu est nommé plutôt que supposé ; et un pointeur au-delà du message est
refusé.

Ce que le décodeur ne fait pas, et le dit : il ne dessine pas, et il s'arrête
aux charges compressées. QUIC, LZ, GLZ et JPEG sont chacun leur propre travail,
et prétendre les avoir ici donnerait un décodeur qui annonce avoir compris une
image dont il ne sait produire aucun pixel.

Deux gardes ont été écrites puis retirées après qu'un sabotage a montré
qu'elles ne changeaient rien : une borne sur le nombre de rectangles — la
sûreté vient de ne rien réserver, pas de vérifier — et, plus tôt, la même leçon
sur la liste des canaux. Une troisième est restée, avec une note disant
honnêtement qu'aucun chemin actuel ne peut boucler et qu'elle attend
`DRAW_ROP3` et `DRAW_OPAQUE`.

`SpiceLZ` défait le premier des codecs. LZ avant QUIC et avant JPEG pour une
raison qui tient à ce dépôt plutôt qu'au codec : c'est du calcul entier sur des
octets, sans plateforme derrière, donc un runner Linux qui ne coûte rien peut
en éprouver chaque branche. JPEG voudrait dire `ImageIO` sur Apple et rien sur
Linux — la forme de `WisqNet.SHA256`, qui rend `Data()` vide sans CryptoKit et
n'est donc d'accord qu'avec lui-même.

Deux choses s'y seraient écrites faux de mémoire, et les deux l'ont été avant
d'être corrigées : **l'en-tête du flux est gros-boutiste**, dans un protocole
petit-boutiste partout ailleurs ; et **les longueurs sont biaisées, différemment
selon le type de pixel** — plus un pour du RGB32, plus deux pour du RGB16, plus
trois pour les palettes. Une correspondance manque alors un pixel, ce qui donne
une image presque juste : la pire sorte de faux.

Ce qui l'a attrapé : les fixtures ne sont pas écrites à la main. `lz.c`, la
mise en œuvre de référence, est liée dans un petit harnais qui comprime des
images faites pour contenir des bandes plates, un motif répété et du bruit —
littéraux, correspondances courtes, longues et la distance longue à deux octets
s'y produisent toutes. Une fixture écrite à la main n'aurait fait que confirmer
que la même personne a fait deux fois la même hypothèse ; celles-ci échouent
quand l'hypothèse est fausse, et elles ont échoué. Voir
`scripts/spice-lz-fixtures/`.

Une branche restait non couverte même ainsi — la frontière de l'échappement de
distance longue ne sort pas de l'encodeur à ces tailles. Ce flux-là est
fabriqué à la main puis **validé par le décodeur de référence**, pas par une
attente.

Le tout est branché : un `DRAW_COPY` portant une image LZ_RGB ressort en pixels,
et un test traverse la couture. GLZ est refusé bien que son format soit le même,
parce que ses correspondances remontent dans un dictionnaire bâti à partir des
*images précédentes du canal* : le décoder seul assemblerait une image à partir
de ce qui traînait.

Le 16 bits est fait aussi, avec sa particularité : ses deux octets atterrissent
en mémoire dans l'ordre inverse du flux, parce que le codec lit un pixel comme
`(premier << 8) | second` et le range en mot machine. Écrit explicitement
plutôt que laissé à l'hôte, pour que la sortie soit la même partout et qu'un
test puisse dire ce qu'elle doit être.

`SpiceDisplayClient` porte ce que le client *dit* au canal display, et sa
raison d'être n'est pas petite : **wisq décode le LZ, et c'est comme ça qu'on
lui envoie du LZ.** Un serveur SPICE choisit son encodage selon sa propre
configuration, et le défaut habituel est « automatique » — QUIC pour le
photographique, GLZ pour le graphique. Aucun des deux n'est décodé ici. Sans ce
message, un client qui n'a qu'un décodeur LZ regarde arriver l'essentiel de
l'écran dans un encodage qu'il doit sauter : décoder un codec et se faire
envoyer ce codec sont deux réussites distinctes, et seule la seconde met une
image sur un téléphone.

`SPICE_MSGC_DISPLAY_PREFERRED_COMPRESSION` demande donc `LZ` — pas `AUTO_LZ`,
qui laisserait le serveur libre d'envoyer du QUIC pour le photographique, c'est
le sens même d'« automatique ». Et seulement si le serveur a annoncé
`SPICE_DISPLAY_CAP_PREF_COMPRESSION` : un message que l'autre bout a dit ne pas
comprendre n'est pas une demande, c'est du bruit. Une capacité est un **numéro
de bit**, pas une valeur — lue comme une valeur, la vérification serait fausse
d'une manière qui tombe juste pour les capacités 1 et 2.

Ça change l'ordre du travail restant : porter QUIC — deux mille lignes de
codage prédictif — devient une optimisation *après*, et non un prérequis
*avant*.

`SpiceSurfaces` est l'endroit où les trois pièces finies se rejoignent : le
canal dit *où* dessiner, le décodeur LZ dit *quoi*, et ceci le met quelque
part. Jusque-là chacune était juste et aucune ne montrait rien. Un test
traverse toute la couture : un flux produit par l'encodeur de SPICE ressort en
pixels sur une surface, à l'origine de la boîte.

Presque chaque test y porte sur une frontière, et ce n'est pas du remplissage.
En C, un blit qui déborde d'une ligne écrit la suivante et l'image se décale —
invisible. Ici le tableau est borné, donc la même erreur *piège* : l'app meurt
au lieu de mal dessiner. Retirer la découpe et lancer les tests le montre — ils
ne échouent pas, ils emportent le processus. Aucune des deux issues n'est
acceptable quand les nombres viennent d'une socket.

Les deux découpes sont distinctes et s'appliquent toutes les deux : la boîte
dit où le serveur veut dessiner, la découpe dit ce qu'il veut encore voir.
N'honorer que la boîte, et une fenêtre qui devait rester couverte est
repeinte. Et une découpe change *quels* pixels sont écrits, jamais *de quel
pixel source* chacun vient — calculer la source depuis le rectangle découpé
ferait glisser l'image partout où quelque chose la recouvre.

`SpiceDisplayChannel` fait tourner tout ça : messages en entrée, pixels en
sortie. Une `struct` sur un `ByteStream` comme le canal principal, donc
éprouvable contre un serveur scripté sans la moindre socket — et c'est comme ça
que les règles d'ordre se vérifient au lieu de s'espérer.

L'ordre justement : `INIT` **avant** la préférence de compression. Ce n'est pas
un goût, c'est le protocole — le serveur ne dessine pas tant qu'`INIT` n'est pas
arrivé, et une préférence envoyée d'abord peut atteindre un serveur qui n'a pas
encore décidé que ce client existe.

La distinction qui compte : **« pas encore implémenté » n'est pas « malformé »**.
Un encodage que wisq ne décode pas laisse cette partie de l'écran tranquille et
se compte ; un message qui n'a pas de sens arrête la pompe. Confondre les deux
déconnecte un téléphone parce qu'un serveur a envoyé un JPEG. Les messages non
traités sont comptés par type — un client qui ignore la moitié d'un protocole
devrait au moins savoir dire laquelle, et c'est ce chiffre qui dit quoi
construire ensuite.

**`SPICESession` est branché.** `SessionFactory` rend une session SPICE là où il
levait `unsupportedProtocol`. La forme qui distingue SPICE de RFB d'à côté :
**une connexion TCP par canal**. Le canal principal d'abord, parce que c'est le
seul qui apprend l'identifiant de session, et chaque canal suivant doit le
présenter comme identifiant de connexion — sans quoi le serveur voit un client
non apparenté et lui donne un affichage à lui, c'est-à-dire un écran noir qui
ressemble exactement à un décodeur cassé.

Éprouvé contre un serveur scripté à deux sockets : l'identifiant est relu tel
quel dans le message de lien du canal display.

Deux défauts trouvés en branchant, et pas par un test qui existait :

- La pompe traitait **256 messages avant de rendre quoi que ce soit**. Une
  première image de trois messages serait restée non peinte en attendant la
  253ᵉ — sur un bureau tranquille, jamais. Le défaut est maintenant **un**
  message par appel, et l'appelant publie les dégâts au fur et à mesure.
- Le numéro de série ne survivait pas entre les appels, et rien ne le
  vérifiait. Un `defer` censé le poser était du code mort : un `defer` s'exécute
  après la copie de la valeur de retour, donc il ne peut pas la changer.
  Vérifié par un petit programme plutôt que raisonné. Retiré, et un test le
  tient désormais.

**Le canal des entrées est branché** : une troisième connexion, présentant le
même identifiant de session. C'est en *meilleur effort* — un serveur qui n'offre
pas ce canal donne quand même une session utilisable, parce que l'écran vaut
d'être montré sans le clavier et que refuser de démarrer échangerait quelque
chose contre rien. Chaque canal compte ses propres numéros de série : un
compteur partagé entre deux connexions donnerait à chacune une suite trouée.

**Le canal curseur est fait** : décodage et branchement, sur sa propre
connexion — pour que le pointeur continue de bouger pendant que le canal
display envoie un écran entier de pixels. Deux largeurs s'y seraient écrites
faux de mémoire : `cursor_flags` fait seize bits là où `cursor_type` en fait
huit, donc l'en-tête ne commence pas où on le croit ; et la position est un
`Point16` — deux entiers signés de seize bits — pas les deux de trente-deux du
canal display.

Trois absences y sont distinctes, et les confondre donne un pointeur faux
plutôt qu'une erreur : le drapeau `NONE` (aucune image), un curseur nommé
depuis un cache que ce client ne tient pas, et une forme non décodée (mono,
palette). Un curseur vide veut dire « cache le pointeur » ; renvoyer ça pour
« je ne l'ai pas » fait exactement l'inverse de ce que le serveur demande.

**Les formes à palette sont faites** : PLT8, PLT4 et PLT1, dans les deux ordres
chacune. Trois règles y donnent une image quand on les écrit à l'envers plutôt
qu'une erreur — le quartet bas ou haut d'abord, le bit 0 ou le bit 7 d'abord, et
la palette petite-boutiste alors que l'en-tête LZ juste au-dessus est
gros-boutiste. À l'envers, on obtient une image miroir par paires, par groupes
de huit, ou dans les mauvaises couleurs. Rien ne lève d'erreur. Les trois ont
donc été vérifiées contre la sortie du décodeur de référence **avant** que le
décodeur ne soit écrit, ce qui est le seul ordre où cette vérification veut dire
quelque chose.

Un défaut trouvé en chemin : la boucle de décompression comptait une unité de
sortie par pixel. Pour une image 4 bits, une ligne de huit pixels tient en
quatre octets, pas huit — tous les flux à palette semblaient tronqués. Et
chaque ligne commence sur une frontière d'octet : une ligne de cinq pixels en
1 bit dépense un octet et en gâche trois bits, sans quoi tout décale à partir de
la deuxième ligne.

**`rgba` et `xxxa` sont faits, et LZ est complet.** Ce sont **deux flux LZ bout
à bout dans une seule charge** : la passe couleur, puis une passe alpha qui
reparcourt les mêmes pixels et ne touche que leur quatrième octet, en
continuant la lecture là où la première s'est arrêtée. C'est pour ça qu'ils
étaient refusés : la boucle à une passe aurait lu la couleur, déclaré l'image
finie, et laissé tous les pixels opaques pendant que la moitié de la charge
restait non lue — une image, et une fausse.

`xxxa` est la passe alpha seule : ses octets de couleur ne sont jamais
transmis, donc ils ressortent à zéro plutôt qu'avec ce que le tampon
contenait. En C, c'est de la mémoire non initialisée qui arrive à l'écran.

**Le presse-papiers est encodé et décodé.** Il ne passe pas par le canal des
entrées — c'est la supposition qu'on fait en lisant — mais par l'agent qui
tourne *dans* l'invité : le presse-papiers est celui de l'invité, donc il va au
programme et non au matériel virtuel. Les messages voyagent sur le canal
principal enveloppés dans `AGENT_DATA`.

Le piège, et il est plus vicieux que les précédents : **ces structures n'ont
pas une disposition, elles en ont quatre.** Deux préfixes optionnels
apparaissent ou disparaissent selon ce que les deux bouts ont négocié —
`selection`, qui fait **quatre octets** (un de sélection, trois réservés,
alignés sur un mot) et non un ; et `serial`, sur le message `grab` seulement,
sous une capacité encore différente. Un client qui en suppose une marche contre
le serveur pour lequel il a été écrit et lit tout de travers avec le suivant.
La disposition est donc calculée depuis les capacités négociées, jamais fixée.

**Le presse-papiers est branché, et une couche qui n'existe pas a été
retirée.** `vd_agent.h` définit un `VDIChunkHeader` — port et taille — devant
chaque `VDAgentMessage`, et un client écrit depuis les en-têtes seuls le pose
sur le fil. Il ne devrait pas : **cet en-tête appartient au tuyau virtio entre
le serveur SPICE et l'agent dans l'invité, et ne traverse jamais le réseau.**
Vérifié dans `channel-main.c` de spice-gtk, qui écrit le `VDAgentMessage` nu
dans `AGENT_DATA` et découpe à 2048 octets. Un premier jet de ce dépôt encodait
la couche fantôme ; elle a été enlevée avant d'être commise, avec le décodeur
et les tests qui l'accompagnaient. C'est la même famille d'erreur que
`attachChannels = 101` : du code correct pour quelque chose qui n'est pas là.

Ce qui survit du découpage, c'est sa conséquence : **un message d'agent arrive
en plusieurs `AGENT_DATA`**, coupé n'importe où, y compris au milieu de
l'en-tête. Un lecteur qui prend chaque `AGENT_DATA` pour un message entier
marche sur du texte court et tronque le texte long en silence — la panne qui
n'apparaît que le jour où quelqu'un copie un vrai document. Le réassembleur est
testé sur toutes les coupures possibles d'un même message.

Deux autres choses manquaient, et la seconde cachait la première. **Personne ne
lisait le canal principal après la poignée de main** : les pings du serveur
tombaient dans un tampon de réception qui se remplissait sans bruit, et un
serveur qui ping sans réponse conclut que le client est parti. `SpiceAgentChannel`
le lit, répond aux pings et aux fenêtres d'acquittement, et porte le
presse-papiers.

Le presse-papiers est **à la demande, dans les deux sens**, ce qui surprend qui
attend qu'une copie envoie le texte : l'invité copie → il envoie `GRAB` en
nommant les types → le client envoie `REQUEST` → l'invité envoie `CLIPBOARD`.
Et l'inverse. Le texte copié sur le téléphone est donc *gardé* jusqu'à ce que
l'invité le demande, ce qui peut ne jamais arriver.

Les jetons sont l'autre moitié : chaque `AGENT_DATA` en dépense un, et ce qui
n'en a pas attend au lieu de partir impayé ou d'être jeté. Un seul drain à la
fois — pas pour l'ordre des octets, que la file FIFO garantit déjà, mais pour
le **numéro de séquence** : il est lu pour bâtir un message et incrémenté après
le retour de l'écriture, donc deux drains simultanés tamponnent le même numéro.
Le sabotage le montre : huit messages, sept numéros.

Reste : QUIC, GLZ, JPEG.

## Lot 6 — finition

- iPad : curseur système, multi-fenêtres, pointeur indirect (souris et trackpad).
- Raccourcis Siri et widgets « se connecter à … ».
- Import depuis les fichiers `.vv` et `.rdp` : fait. `VirtViewerFile` lit le fichier que virt-manager, oVirt et Proxmox remettent quand on clique
  « console » — hôte, port, transport, et le ticket à usage unique que personne
  ne peut retaper. Du pur décodage, donc entièrement testé.

  Ce que les tests tiennent : les options que ce client n'a pas sont ignorées
  plutôt que refusées, sans quoi la plupart des vrais fichiers seraient rejetés
  pour avoir dit quelque chose en plus ; `tls-port` l'emporte sur `port`, car un
  fichier qui offre les deux offre un choix et le chiffré est la réponse ;
  `port=-1` n'est pas lu comme un port ; un port illisible est refusé plutôt que
  remplacé par un défaut, qui connecterait ailleurs que là où le fichier le dit ;
  une seconde section arrête la lecture, sinon une section ajoutée redirigerait
  la connexion ; et le mot de passe n'apparaît jamais dans la description, parce
  que c'est elle qui finit dans un journal ou un rapport de plantage.

  `RemoteDesktopFile` fait la même chose pour les `.rdp` que Windows, Azure et
  les passerelles remettent. Le format est une ligne par option, `clé:type:valeur`,
  et la valeur garde tous ses deux-points — c'est ce qui fait que
  `full address:s:[2001:db8::1]:3390` est une ligne légale, et pourquoi c'est un
  parseur et pas un `split(separator: ":")`.

  Les pièges tenus par les tests : un IPv6 entre crochets a cinq deux-points et
  un seul sépare un port, donc couper au premier donne un hôte `[2001` et une
  connexion nulle part ; un IPv6 **nu** ne porte pas de port du tout, et prendre
  son dernier groupe pour un port tronquerait silencieusement l'adresse ; le
  port 3389 s'applique quand aucun n'est donné, jamais à la place d'un port
  illisible ; un champ `i` contenant du texte est refusé plutôt que deviné ; et
  le mot de passe enregistré — chiffré vers la machine qui a écrit le fichier,
  donc inutilisable ici — n'est ni décodé, ni stocké, ni porté.

  `ConnectionImport` fait le pont : un fichier lu devient une `Machine`. Ce sont
  des décisions sur des valeurs que wisq n'a pas choisies, d'où un type à part
  plutôt qu'un initialiseur. Le mot de passe **revient à côté de la machine et
  jamais dedans** — `Machine` est `Codable` et va sur le disque, un secret qui
  l'atteindrait serait persisté en clair à côté de l'hôte qu'il ouvre. La
  référence de credential reste vide tant que personne n'a stocké le secret : une
  machine pointant vers un credential jamais écrit échoue à la connexion au lieu
  de demander. Un `.rdp` ne se voit attribuer aucun transport, parce qu'il n'en
  déclare pas. Et la géométrie n'est pas portée : elle décrit l'écran de celui
  qui a enregistré le fichier, pas ce que veut un téléphone.

  Et c'est branché : « Ouvrir un fichier .vv ou .rdp » dans le menu, et ce qui
  en sort s'ouvre dans l'éditeur au lieu d'atterrir dans la bibliothèque sans
  être vu. Un fichier de connexion est la description d'une machine faite par
  quelqu'un d'autre — son nom est un hôte, son port vient d'un serveur, son mot
  de passe est souvent un ticket à usage unique — et l'utilisateur doit voir
  tout ça avant que ce soit à lui.

  Le sélecteur accepte tous les types plutôt que de déclarer `.vv` et `.rdp` :
  ces fichiers arrivent par mail et par AirDrop avec le nom que l'expéditeur a
  choisi, et un sélecteur qui grise `connexion.txt` refuse un fichier que wisq
  lit très bien. C'est le contenu qui décide, et c'est la seule chose qui puisse
  décider — accessoirement, cela retire à l'expéditeur le choix du parseur.

  L'encodage est traité, et ce n'est pas un détail : le client Remote Desktop de
  Windows enregistre les `.rdp` en UTF-16 petit-boutiste avec une marque
  d'ordre. Lus en UTF-8, ces octets ne sont pas le fichier et aucune ligne ne
  se lit — c'est-à-dire le `.rdp` le plus répandu qui existe. Un cas pour la
  marque UTF-8 avait été écrit à côté puis retiré : c'était du code mort, parce
  que Foundation la retire lui-même. Le test est resté, et il tourne aussi dans
  le simulateur : ce qu'il garde repose désormais sur Foundation, et Foundation
  sur Darwin n'est pas la même implémentation que sur Linux.
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

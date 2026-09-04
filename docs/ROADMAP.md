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

## Ce qui attend une machine Apple

Une liste courte, tenue à jour, de ce qui est **trouvé et compris** mais ne peut
pas être prouvé depuis le conteneur Linux où le reste l'est. Elle existe pour
que ces points ne se perdent pas et pour qu'aucun d'eux ne parte en correctif
non vérifié — la discipline du dépôt est qu'une modification qu'aucun test ne
peut voir casser n'est pas une modification livrable.

### `NetworkByteStream.read(exactly:)` n'accepte qu'un lecteur

Le `await` est dans la boucle de remplissage, `buffer` lu avant et muté après.
Deux lectures concurrentes s'entrelacent et chacune emporte des octets de la
course de l'autre — pas une erreur, pas une lecture courte, mais **un flux
recousu depuis deux positions**, qui se décode en charabia plusieurs messages
plus loin sans rien à montrer du doigt.

Latent aujourd'hui, et vérifié plutôt que supposé : `SPICESession` lance cinq
pompes et chacune possède sa connexion, la poignée de main finissant avant que
sa pompe démarre. Aucun chemin ne lit un flux depuis deux tâches. La règle est
écrite sur le protocole `ByteStream` parce que rien ne l'impose et que le prix
d'un oubli est silencieux.

**Ce qu'il faudrait pour le rendre sûr :** sérialiser les lectures, et une sonde
qui gare une lecture pour forcer l'entrelacement — le pendant en lecture du
`GatedByteStream` déjà écrit pour les tests d'écriture. `Network` étant sous
`#if canImport(Network)`, rien de tout cela ne s'exécute ici.

### Le vrai épinglage du chemin machine (deux tiers faits)

`ResolvedTransportSecurity` referme le trou — un pin sans empreinte fait une
validation système complète au lieu d'accepter n'importe quel certificat — et
les deux premières des trois étapes sont faites :

1. **Fait.** `Machine.certificateFingerprint`, absent des fichiers enregistrés
   avant, donc `nil` au décodage ; tenu par `MachineFingerprintTests`.
2. **Fait.** `SessionConfiguration(machine:password:)` le porte jusqu'aux deux
   fournisseurs de flux, qui le donnent à `NetworkByteStream` comme
   `pinnedFingerprint` ; tenu par `SessionConfigurationTests`, et l'épinglage
   lui-même par la vérification de `NetworkByteStream`, qui existait déjà.
   L'empreinte se **saisit** dans l'éditeur — collée depuis `openssl x509
   -fingerprint -sha256` ou un navigateur, `CertificateFingerprint.parse`
   lisant toutes ces graphies et refusant tout ce qui ne fait pas trente-deux
   octets. Ce n'est pas un pis-aller : c'est la seule forme d'épinglage qui
   ne fait pas confiance au réseau au moment où on l'enregistre.
3. **L'enregistrement depuis la connexion**, qui n'est pas fait : il faut voir
   le certificat que le serveur présente, donc `Network.framework`, donc une
   machine Apple. Et il faut le montrer à la personne qui l'accepte — un
   épinglage qu'on enregistre en silence à la première connexion protège de
   tout sauf de l'attaquant qui était là à ce moment-là.

Le chemin agent fait déjà les trois : `AgentBinding` garde l'empreinte relevée
à l'appairage, et `AgentClient` la prend en paramètre **non optionnel**. C'est
le modèle à recopier, pas à réinventer.

Les mots suivent le fait, machine par machine : le sélecteur nomme le mode
(« TLS épinglé par empreinte »), et `Machine.transportDescription` dit ce que
*cette* machine obtient — « TLS épinglé sur 5A:5A:5A:5A… » quand elle porte
une empreinte, « TLS, validation système — aucune empreinte enregistrée »
sinon. La liste ne montre le bouclier que sur la première. L'ancienne
étiquette « TLS (épinglage à venir) » avait été la réponse de #70 ; elle ne
disait plus vrai dès qu'une empreinte pouvait être saisie.

### Le port qu'une reconnexion ne redemande jamais

`ConsoleResolver.resolve` tourne une fois, avant `SessionFactory.makeSession`,
et le port qu'il obtient est cuit dans la `Machine` que la fabrique reçoit.
`ReconnectingSession` rejoue la même fermeture à chaque tentative : elle
recompose donc toujours le port du premier appel.

Un domaine libvirt redémarré ne retrouve pas forcément le sien. Mesuré contre
un vrai libvirt : `ubuntu-test` sur 5900, arrêté, deux autres VM prenant 5900
et 5901 entre-temps, puis rallumé — il revient sur **5902**.

La fenêtre est étroite et il faut la nommer pour ne pas la surestimer : un
`reboot` dans l'invité garde le même processus QEMU et le même port ; une
extinction puis un rallumage depuis wisq repassent par le résolveur. Le cas
qui casse est un redémarrage du domaine **par quelqu'un d'autre** pendant
qu'une session se reconnecte. Les cinq tentatives échouent alors sur une
machine qui va bien.

Le correctif est de re-résoudre à chaque tentative, ce qui rend
`ReconnectingSession.Factory` asynchrone et touche la boucle de reconnexion —
la promesse phare du projet. À faire avec le temps de le juger, pas en marge
d'autre chose.

## Lot 3 — RDP

FreeRDP 3 compilé pour iOS/arm64, piloté par une passerelle C mince derrière
`RDPSession`. Points à trancher avant d'écrire du code :

- Construction reproductible en CI plutôt qu'un `xcframework` versionné, qui
  devient un piège dès la première CVE.
- FreeRDP est sous Apache 2.0 : la distribution sur l'App Store ne pose pas le
  problème de licence qui contraint les concurrents fondés sur QEMU.
- NLA/CredSSP d'abord — sans lui, aucun Windows moderne n'accepte la connexion.

**Pourquoi ce lot n'avance pas ici.** Rien de tout cela n'est vérifiable dans un
conteneur Linux : FreeRDP doit être croisé pour iOS/arm64, la passerelle C se lie
à un `xcframework`, et la seule preuve qu'une session RDP fonctionne est une
session RDP. Écrire ce code sans pouvoir l'exécuter produirait des centaines de
lignes dont personne ne saurait dire si elles marchent — exactement ce que la
discipline du reste de ce dépôt refuse. Les trois points ci-dessus sont donc
tranchés à l'avance, et le code attend une machine Apple.

Un quatrième point à trancher, apparu en écrivant le reste : **le décodage RDP
ne doit pas repasser par les surfaces de SPICE.** Les deux protocoles partagent
la forme (des rectangles, des codecs, un curseur) et rien de leur sémantique ;
`SpiceSurfaces` porte déjà les ROP3, les masques et le cache d'images de SPICE,
et y greffer RDP ferait un type qui a deux protocoles dans la tête. La couche
commune, si elle existe un jour, est la cible de dessin, pas le décodeur.

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

## Lot 5 — SPICE (fait)

*Le titre de cette section a longtemps dit « format, lien, entrées, affichage,
curseur et presse-papiers faits », alors que son propre corps décrivait déjà
LZ4, les opérations de dessin, les flux vidéo, le son dans les deux sens, la
fenêtre GLZ, les trois caches et les capacités. Le lot est clos : ce qui suit
est le compte rendu complet, gardé pour ce qu'il explique.*

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

**Les bitmaps non compressés se dessinent, et l'orientation est enfin lue.**
La forme la plus simple que SPICE envoie était la seule que rien ne peignait :
elle était analysée puis jetée, `payload` à `nil`. Un serveur avec la
compression d'images désactivée n'affichait donc rien du tout.

Ses pixels suivent **en ligne**, juste après le champ palette — le seul endroit
du message où les données en vrac ne sont pas derrière un pointeur. Vérifié
dans le démarshaleur de `spice_codegen.py` : pour un tableau d'octets marqué
`@chunk`, la donnée est prise à la position courante (`chunks->chunk[0].data =
in`), alors que la variante pointeur existe juste au-dessus. Leur longueur est
`stride × hauteur`, et le `stride` du bitmap est réel : les lignes sont
remplies jusqu'à lui. Le lire comme la largeur d'une ligne décale chaque ligne
après la première.

Le drapeau qui compte est `TOP_DOWN`, et **son absence est l'état intéressant** :
les lignes sont alors de bas en haut, comme dans un DIB Windows. L'ignorer ne
casse rien — ça affiche le bureau à l'envers, et seulement contre les serveurs
qui rangent les lignes ainsi.

Ce qui a fait trouver un défaut déjà fusionné : `SpiceLZ.Header.topDown` était
lu et **jamais utilisé**. Une image LZ de bas en haut s'affichait à l'envers.
`canvas_base.c` confirme la règle dans les deux cas — il décale le tampon d'une
image entière et inverse le pas. Le test prend un flux produit par l'encodeur de
référence et change un seul octet de drapeau : mêmes pixels, lignes inversées.

Les formats : 0555 recopie les bits hauts au lieu de simplement décaler, sans
quoi le blanc sort à 248 et toute image vive est terne ; le quatrième octet d'un
pixel `xRGB` est du remplissage et non de l'alpha, le recopier rend un bureau
opaque entièrement transparent ; `RGBA` le garde, donc les mêmes octets veulent
dire deux choses. Les ordres de quartets et de bits des formats palettisés sont
ceux du codec LZ, déjà vérifiés contre le décodeur de référence.

**Les flux LZ à palette se dessinent enfin.** Le codec était fini depuis #33 et
vérifié contre le décodeur de référence, mais **rien ne l'appelait** :
`pixels(of:)` ne dispatchait que `lzRGB`, et `image(at:in:)` sautait
`lzPalette` parce que sa forme de message n'est pas la forme commune. Tous ces
flux arrivaient et aucun n'était peint.

Sa forme lui est propre : `flags` (un octet), la taille, puis la table —
identifiant de cache ou pointeur — et seulement ensuite le flux. Lue avec la
forme commune, la taille sort de l'octet de drapeaux.

L'orientation vient de l'en-tête du flux **interne**, pas des drapeaux
extérieurs, bien que ceux-ci portent aussi un `TOP_DOWN`. Vérifié dans
`canvas_get_lz`, qui prend `top_down` de `lz_decode_begin` pour `LZ_RGB` comme
pour `LZ_PLT` et ne passe les drapeaux extérieurs qu'au cache de palette. Lire
le mauvais des deux aurait mis à l'envers les seules images palettisées.

**JPEG est branché, les deux formes.** Il attendait une question préalable :
le décodeur existe depuis le travail sur Tight, mais **aucun job de CI ne
l'exécutait** — les tests du paquet ne tournaient que sur Linux, où ImageIO
n'existe pas, et le job iOS ne lance que les tests de l'interface. Le job
`Cœur (Apple)` a corrigé ça d'abord, pour ne pas empiler du SPICE derrière un
décodeur que rien ne vérifie.

`jpeg` (105) était le cas facile : sa forme de message est la forme commune,
donc seule la répartition manquait. `jpegAlpha` (108) est l'intéressant :
**deux codecs sur les mêmes pixels**, un JPEG pour la couleur puis un flux LZ
`xxxa` pour l'opacité, bout à bout dans une seule charge utile. La frontière
entre les deux est un nombre du message, pas quelque chose que les octets
annoncent — chercher un marqueur de fin de JPEG serait une devinette, et le
flux alpha n'a pas de magie propre qui ne puisse apparaître dans des données
JPEG.

`SpiceLZ.applyAlpha` est le point d'entrée que ça demandait : la passe alpha
écrit dans un tampon que ce codec n'a pas produit, ce que `decompressWithAlpha`
ne sait pas faire puisqu'il alloue le sien.

Trois refus valent d'être nommés, et ce sont ceux du canevas de référence :
largeur, hauteur, et **orientation** doivent concorder entre les deux moitiés.
Un `TOP_DOWN` qui diffère donnerait une image dont l'opacité est à l'envers.
Et ce drapeau est **le bit 0** ici, là où celui du bitmap est le bit 2 : deux
mots de drapeaux, deux positions, un seul nom.

**QUIC commence, et il arrive en plusieurs fois.** C'est le codec propre à
SPICE et de loin le plus gros : codage de Golomb-Rice adaptatif, modèle par
canal qui se remodèle en cours de route, sous-état de répétition emprunté à
MELCODE, prédiction depuis les pixels du dessus et de gauche. La référence fait
2 250 lignes de C réparties sur `quic.c` et trois gabarits instanciés une fois
par format de pixel. Le découper est une décision, pas un renoncement : une
seule PR de cette taille ne se relit pas.

Cette première tranche est celle qui rend le reste vérifiable :

* le **harnais de gabarits** (`scripts/spice-quic-fixtures/`), qui lie
  l'encodeur *et* le décodeur de référence. QUIC n'a aucune seconde
  implémentation ailleurs avec qui être en désaccord, donc l'encodeur livré
  avec lui est la seule autorité honnête disponible ;
* l'**en-tête** du flux — petit-boutiste, contrairement à celui de LZ juste à
  côté qui est gros-boutiste. Deux codecs du même protocole qui ne s'accordent
  pas sur l'ordre des octets, c'est précisément ce qu'on reporte du fichier
  qu'on vient de lire ;
* les **tables de famille**, celles que le codeur consulte à chaque symbole.
  Elles valent d'être faites en premier parce qu'elles sont pures : une
  profondeur de bits et une limite de longueur les déterminent entièrement, et
  elles ne bougent pas pendant un décodage. Elles peuvent donc être comparées
  nombre par nombre à celles que la référence construit — ce que rien de plus
  tard dans ce codec ne permettra d'aussi propre.

Deux choses que le harnais a apprises, consignées dans les gabarits : `rgb32`
ne transmet jamais le quatrième octet (le décodeur y écrit zéro, quoi qu'ait
contenu l'original), et `gray` ne se décode qu'en `gray` — demander du 32 bits
pour un flux gris est une erreur.

**Le lecteur de bits est la deuxième tranche.** Sa difficulté tient en une
phrase : **les mots sont petit-boutistes sur le fil, mais les bits se
consomment depuis le poids fort.** Les deux ordres vont en sens contraire dans
la même structure, et se tromper sur une moitié donne des petits nombres
plausibles pendant un moment avant de diverger — la pire façon dont un codec
puisse échouer.

Deux détails que la référence impose et qu'on ne devinerait pas : les deux
registres démarrent sur le **même** premier mot (amorcer l'anticipation avec le
deuxième décale tout de 32 bits, et la magie se lit quand même correctement,
donc l'erreur survit au premier contrôle) ; et 32 bits se consomment en deux
fois, parce qu'un décalage de 32 sur un mot de 32 est indéfini en C.

Le test compare **pas à pas** l'état du lecteur à celui de la référence, tracé
par `qbits.c`. Ne comparer que la réponse finale laisserait un lecteur se
tromper au milieu et retomber juste à la fin.

**Le modèle adaptatif est la troisième tranche**, et encore vérifiable
isolément. Trois choses y vivent : le calendrier des mises à jour, piloté par
une table fixe de 256 mots (`tabrand`) qu'encodeur et décodeur parcourent
identiquement sans jamais transmettre leurs décisions ; les seaux, dont la
taille double — 1, 2, 4, 8… — pour que les valeurs proches de zéro, où une
image bien prédite passe presque tout son temps, aient leurs propres
statistiques ; et `golomb_decoding`, fonction pure du niveau et de la fenêtre.

Trois détails que la référence impose : le tirage incrémente **avant** de
consulter la table, donc le premier tirage est l'entrée 0 et non l'entrée 255 ;
le balayage des compteurs **descend**, donc à égalité c'est le code le plus
haut qui reste ; et les compteurs sont divisés par deux quand le total dépasse
*strictement* le seuil.

Ce dernier point a demandé un gabarit fabriqué exprès. Le seuil ne prend que
onze valeurs tabulées et aucune séquence ordinaire ne tombe pile dessus, donc
la différence entre `>` et `>=` était intestable : un sabotage la remplaçait
sans qu'un seul test tombe. Le harnais règle maintenant le seuil à la main pour
atteindre la frontière, et la référence répond sans ambiguïté — pile sur le
seuil, rien n'est divisé.

**La boucle de décodage est la quatrième tranche**, et la première qui ne se
vérifie pas en morceaux. L'en-tête, les tables de famille, le lecteur de bits
et le modèle avaient chacun une comparaison exacte disponible ; une boucle de
décodage ne se compare que sur ce qu'elle produit. Elle est donc comparée sur
tout : chaque gabarit, chaque octet, contre ce que le décodeur de SPICE a tiré
du même flux.

Trois choses que la référence impose et qui ont chacune coûté une divergence :

* **L'ordre des canaux sur le fil est rouge, vert, bleu**, et `rgb32_pixel_t`
  est `b, g, r, pad`. Les deux vont en sens contraire. Se tromper ne mélange
  pas seulement les couleurs : chaque canal porte son propre modèle et sa
  propre ligne de symboles, donc le mauvais appariement désynchronise le
  décodage en quelques pixels et le flux se termine trop tôt.
* **Chaque seau démarre au code le plus haut**, `bpc - 1`, pas à zéro. C'est le
  code avec lequel le tout premier pixel de l'image est lu. Un modèle testé
  isolément ne peut pas le montrer : le test lui fournit le seau initial qu'il
  a lui-même construit.
* **`correlate_row[-1]` est écrit avant chaque ligne** : zéro pour la première,
  et ensuite le premier symbole de la ligne du dessus. C'est le contexte qui
  choisit le seau du pixel 0.

Ce dernier point avait d'abord été noté à l'envers — « jamais écrit, donc
zéro » — et une expérience semblait le confirmer. Elle ne le confirmait pas :
elle empoisonnait une case que la ligne suivante réécrivait avant de la lire.
La correction est consignée telle quelle dans le journal, parce qu'une
conclusion fausse qu'on remplace en silence est une conclusion qu'on reprendra.

**`rgba` n'est pas quatre canaux en une passe.** La référence sépare son état
en deux : rouge, vert et bleu partagent `encoder->rgb_state` — un compteur
d'attente, une graine, un codeur de séries pour les trois — tandis que les
chemins un-octet et quatre-octets utilisent `channel_a->state`, celui du canal.
Donc `uncompress_rgba` fait une passe couleur puis une passe alpha
*entièrement séparée*, ligne après ligne. Les fusionner décode correctement la
couleur puis part à la dérive sur l'alpha, qui hériterait du compteur d'attente
de la première passe. Le décodeur est donc organisé en **plans** : un plan par
groupe de canaux qui partagent un état.

Deux gabarits ont été ajoutés pour ces chemins, parce qu'aucun des cinq
premiers ne les atteignait : `rgba 24x18` pour les deux passes, et
`rgb32 64x96` — 6144 pixels — pour que le masque d'attente avance, ce qui
demande 2048 pixels et n'arrivait jamais.

**Et les gabarits ne se reconstruisaient plus.** Le `qgen.c` commité avait été
mis au propre avant le commit sans régénérer ce qu'il produisait, donc sa bande
de bruit ne correspondait plus. Les cinq flux d'origine restaient honnêtes — ils
se vérifient toujours contre le décodeur de référence — mais la procédure
écrite dans le README ne les reproduisait pas. Les sept ont été régénérés avec
le harnais tel qu'il est, et le README donne maintenant la commande exacte de
chacun. Un gabarit qu'on ne peut pas reconstruire est un gabarit que personne
ne peut vérifier.

**La cinquième tranche branche le codec**, et c'est elle qui rend les quatre
précédentes visibles. Un codec fini que `pixels(of:)` ne rappelle pas est un
codec qui n'existe pas — `lzPalette` l'a déjà montré une fois.

`canvas_get_quic` règle trois questions d'un coup :

* **QUIC ne porte aucune orientation.** Son en-tête s'arrête au type, à la
  largeur et à la hauteur ; la référence ne consulte aucun drapeau et ne
  retourne rien. LZ prend le sien dans le flux, `jpegAlpha` dans son propre
  octet ; ici il n'y a rien à prendre, et aller le chercher dans les drapeaux
  du bitmap posés juste à côté donnerait toutes les images QUIC à l'envers.
  Un test le fige : mettre `TOP_DOWN` ne doit rien changer.
* **La taille doit concorder** avec ce que le message a déjà annoncé. La
  référence l'affirme avant d'allouer.
* **`gray` est dessiné ici alors que la référence le refuse.** Son refus vient
  de son chemin pixman, qui n'a pas de format gris où dessiner, pas du
  protocole. Ce décodeur produit du BGRA depuis le gris comme depuis le reste,
  vérifié octet par octet. Si l'avertissement de la référence dit vrai le cas
  n'arrive jamais ; s'il dit faux, une image vaut mieux qu'un trou.

**Et le client demande maintenant `autoGLZ`**, après être passé par `lz` puis
`autoLZ`. `get_compression_for_bitmap`, dans le `dcc.cpp` du serveur, sépare
exactement les deux modes automatiques : tous deux envoient du QUIC pour un
bitmap à forte gradualité, puis l'un retombe sur LZ et l'autre sur GLZ.

Le passage à `autoLZ` valait déjà pour lui-même : « forte gradualité » est le
mot du serveur pour les photos et les dégradés, c'est-à-dire ce que LZ comprime
le plus mal, et c'est la plus grande partie d'un bureau avec un fond d'écran.
Le passage à `autoGLZ` ajoute l'autre moitié — les widgets, les polices, les
bordures — que LZ recomprime intégralement à chaque image et que GLZ retrouve
dans le dictionnaire de la précédente.

Ce qui l'interdisait n'était pas GLZ mais **la fenêtre**, et ce n'était pas une
question de rendement. Voir plus bas.

**Reste GLZ, et c'est une fonctionnalité de session, pas une tranche de codec.**
La lecture de `decode-glz.c` et `decode-glz-tmpl.c` dans spice-gtk — le
décodeur GLZ ne vit pas dans spice-common, contrairement à LZ et QUIC — donne
la forme du travail :

* **L'en-tête n'est pas celui de LZ.** `lz_encode` écrit sept mots de 32 bits,
  28 octets, avec le type et `top_down` chacun dans son mot, et laisse en
  commentaire l'idée de les réunir dans un octet. GLZ le fait, et ajoute
  l'identifiant de l'image sur 64 bits puis `win_head_dist` sur 32 : 33 octets,
  disposés autrement. C'est petit et vérifiable exactement, donc c'est par là
  qu'on commence.
* **La fenêtre** est un anneau d'images décodées indexé par
  `id % nimages`, avec des trous possibles — les images de plusieurs écrans
  arrivent par des sockets différentes et donc dans le désordre. Une référence
  se résout par `glz_decoder_window_bits(id, dist, offset)` : l'image `id -
  dist`, à `offset` pixels de son début. Les images sont libérées jusqu'au plus
  ancien `id - win_head_dist` encore utile.
* **La boucle de correspondance** est celle de LZ plus un champ `image_dist`
  encodé en longueur variable à côté du décalage de pixel. À zéro, la
  correspondance est dans l'image courante et le décalage est biaisé de un ;
  sinon elle est dans une image précédente et ne l'est pas.
* **Le branchement** touche `glzRGB` et `zlibGlzRGB`, et la fenêtre appartient à
  la session plutôt qu'à un appel : c'est là que « fonctionnalité de session »
  cesse d'être une figure de style.

**Le harnais est fait, et c'est la première tranche.** Il réunit trois dépôts —
l'encodeur dans spice-server, le décodeur dans spice-gtk, les en-têtes dans
spice-common — et il encode des *suites* d'images contre un dictionnaire
partagé, puis les relit par le décodeur de référence à travers une seule
fenêtre.

Que la suite exerce vraiment le chemin qui distingue GLZ de LZ est **mesuré** :
les mêmes quatre images, chacune contre un dictionnaire neuf, font 615 octets à
chaque fois ; contre un dictionnaire partagé, 615, 201, 205, 194. L'écart, c'est
la correspondance entre images et rien d'autre.

Un piège s'y est présenté qui aurait empoisonné tous les gabarits : **le
dictionnaire GLZ conserve des pointeurs vers les tampons de pixels de
l'appelant**, il ne les copie pas. Encoder une suite depuis un seul tampon
réutilisé fait correspondre l'image *N* à une mémoire qui contient déjà l'image
*N+1*. Les flux se décodent quand même — vers une image que l'encodeur n'a
jamais vue. Un tampon par image, tous maintenus en vie.

L'en-tête suit dans la même tranche, parce que c'est la seule partie de GLZ qui
se suffit à elle-même et donc la seule vérifiable exactement avant qu'une
fenêtre existe. Les deux en-têtes s'accordent sur leurs huit premiers octets —
magie et version — et divergent juste après : un lecteur qui prend du GLZ pour
du LZ passe son seul contrôle bon marché puis se trompe sur tout le reste.

**La fenêtre est la deuxième tranche**, et c'est elle qui fait de GLZ une
fonctionnalité de session : un anneau d'images décodées indexé par
`id % capacité`, qui survit à tous les décodages et appartient au canal.

Trois règles de la référence, chacune épinglée :

* **Le créneau ne suffit pas, il faut vérifier l'identifiant.** Le créneau est
  `cible % capacité`, donc un identifiant périmé tombe sur une vraie image
  d'une autre génération. Sans le contrôle, la correspondance résout vers la
  mauvaise trame et l'image produite est plausible.
* **Le comblement d'un trou s'arrête à l'identifiant qu'on vient d'ajouter** —
  la boucle est bornée par `tail_gap <= img->hdr.id`. Les images arrivées en
  avance sont présentes et retrouvables, simplement pas encore comptées. Ce
  n'est pas cosmétique : `releaseAfterAdding` lit `slots[tailGap - 1]`, donc
  l'image qui décide de ce qui reste nécessaire n'est pas toujours la plus
  récente.
* **L'agrandissement réindexe sur la nouvelle capacité.** Réindexer sur
  l'ancienne fait disparaître silencieusement les images dont l'identifiant
  dépasse l'ancienne taille.

Et une divergence assumée : **`glz_decoder_window_clear` ne réinitialise pas
`oldest`**, alors que `spice-session.c` l'appelle sur reconnexion et sur
bascule de session. `oldest` n'étant jamais qu'incrémenté, les identifiants qui
repartent de zéro placent toutes les cibles de libération sous lui, plus rien
n'est jamais libéré, et le tableau double à chaque collision : une reconnexion
fuit toute la session précédente. Rien dans le protocole ne le demande — c'est
un oubli dans une fonction. Ici `oldest` est remis à zéro, et la raison est
écrite à l'endroit où elle se lit.

**La boucle de correspondance est la troisième tranche**, et le codage lui-même
n'a pas résisté longtemps. Ce qui a coûté, c'est la couverture : douze
sabotages, cinq survivants au premier passage, et **aucun n'était une
équivalence**. Cinq chemins qu'aucun gabarit n'atteignait, chacun demandant un
gabarit construit pour lui. Deux avaient un seuil de taille facile à rater —
notamment l'offset long, où 128×64 ne suffit pas parce que les offsets locaux
sont biaisés de un et qu'une demi-répétition sur 8192 pixels reste dans le
chemin court à un près.

**Le branchement est la quatrième**, et c'est là que « fonctionnalité de
session » cesse d'être une figure de style. La fenêtre circule en `inout` à
côté des surfaces, pour la même raison et avec la même durée de vie : un flux
renvoie à des images décodées plus tôt *sur cette connexion*, et à rien
d'avant. Elle naît dans `run()`, comme les surfaces, et une reconnexion repart
d'une fenêtre vide comme elle repart d'un écran vide.

Pas de surcharge de commodité sans fenêtre, délibérément. Appelée en boucle,
elle repartirait d'une fenêtre neuve à chaque image et les correspondances
entre images échoueraient en silence — tous les tests de codec resteraient
verts, il manquerait juste des mises à jour à l'écran. Mieux vaut dix appels de
test à corriger qu'une API qui rend ce bug facile.

Seules les images GLZ entrent dans la fenêtre, et seul `rgb32` est décodé pour
l'instant — les autres types diffèrent par leurs biais de longueur et leur
largeur de pixel, donc les passer dans la boucle 32 bits produirait une image
plutôt qu'une erreur.

**`zlibGlzRGB` est la cinquième tranche**, et elle est courte parce que le
format ne cache rien : c'est un flux GLZ avec du zlib autour.
`canvas_get_zlib_glz_rgb` dézippe puis appelle exactement le même chemin GLZ.

Deux détails, et le second aurait fait mal :

* **Le message porte deux longueurs.** `glz_data_size` dit la taille du flux
  GLZ une fois dézippé, `data_size` combien d'octets zlib suivent. C'est
  précisément pour ça que ce type ne pouvait pas passer par la forme
  « une longueur puis autant d'octets ». Lu de travers, la première est prise
  pour la seconde — une longueur normalement plus grande que le message, donc
  la lecture déborde au lieu de produire une image fausse. C'est le bon échec.
* **`decode-zlib.c` appelle `inflateReset` avant chaque image.** Chaque image
  est donc comprimée indépendamment, sans dictionnaire qui traverse. Or
  l'`InflateStream` de wisq a été écrit pour Zlib et ZRLE de RFB, où le
  dictionnaire *traverse* justement. En réutiliser un ici décode correctement
  la première image et corrompt la seconde. Vérifié plutôt que supposé : un
  inflateur partagé échoue sur la seconde avec `Z_DATA_ERROR`.

Un inflateur neuf par image a exactement la sémantique de la référence, pour le
prix d'une initialisation zlib — des microsecondes contre un décodage. Et une
sévérité de plus que la référence, qui avertit et garde ce qui a été écrit quand
le dézippage n'atteint pas la taille promise : ici c'est refusé. Un flux qui ne
produit pas la taille que son propre message annonce est un message malformé,
pas une image.

**`rgb24` ne demandait aucune nouvelle boucle**, et c'est la mesure qui l'a
établi plutôt que la lecture. `DECODE_TO_RGB32` envoie les types 7, 8 et 9 vers
le même décodeur, parce qu'un littéral rgb24 fait trois octets sur le fil
exactement comme un rgb32 ; seule la largeur de sortie différait entre les deux
gabarits, et spice-gtk décode toujours en 32 bits. Encoder le même contenu des
deux façons donne des flux qui diffèrent en **exactement deux octets** —
l'octet type/top_down et le mot de foulée. La charge compressée est identique.

**`rgb16` en demandait une, et la référence y cache un piège de langage.**
L'expansion 0555 se lit **gros-boutiste dans le pixel**, contrairement aux
bitmaps 0555 d'ailleurs dans ce client, et le vert se calcule à partir des deux
octets avant que l'un ou l'autre soit étendu. Mais surtout : dans la référence
ces valeurs sont des champs d'un `rgb32_pixel_t`, donc **chaque affectation
tronque à huit bits**, et le `>> 5` de la ligne suivante travaille sur la valeur
tronquée. Calculer plus large et ne tronquer qu'à l'écriture donne un vert
différent — bleu et rouge justes, vert faux. C'est exactement ce qui s'est
passé, et seul le gabarit de référence l'a montré.

**`rgba` est deux passes sur un seul tampon.** `decode()` fait tourner
`glz_rgb32_decode` sur la couleur, note combien d'octets il a consommés, puis
lance `glz_rgb_alpha_decode` exactement à partir de là — un second jeu d'octets
de contrôle, de correspondances et de séries couvrant à nouveau toute l'image,
ne touchant que le quatrième octet de chaque pixel. Son biais de longueur est
2, et ses correspondances doivent laisser intacte la couleur que la première
passe a écrite.

Le gabarit a un alpha qui varie dans l'image et entre les deux trames, à
dessein : un alpha constant laisserait un décodeur qui saute la seconde passe
donner quand même la bonne réponse. Un test l'affirme sur le gabarit plutôt que
de se fier à la façon dont il a été produit.

**Et GLZ est fini là**, pas parce qu'on s'arrête mais parce qu'il ne reste
rien. Les formes palettisées ne sont pas du travail en attente : rien ne les
produit.

`canvas_get_glz_rgb_common` passe `NULL` à la place de la palette, et le
commentaire juste au-dessus dit pourquoi — un bitmap palettisé est comprimé en
RGB32 globalement, « because same byte sequence can be transformed to different
RGB pixels by different plts ». C'est précisément ce qu'un dictionnaire partagé
entre images ne peut pas supporter. Le serveur le confirme de son côté :
`get_compression_for_bitmap` rétrograde GLZ vers LZ simple dès que
`bitmap_fmt_has_graduality` est faux, et ce prédicat exige un format RGB —
qu'aucun format palettisé n'est.

Les variantes palettisées n'existent donc dans le gabarit de spice-gtk que
parce qu'il est instancié mécaniquement pour chaque type. Elles restent
refusées ici, et le test qui l'épingle dit que c'est un refus définitif plutôt
qu'un manque.

### LZ4 : le dernier codec du canal display

Fait. `SpiceLZ4` lit les images `lz4`, et c'est le seul des quatre codecs du
canal qui n'appartient pas à SPICE : du LZ4 standard, avec deux octets d'en-tête
devant et une longueur avant chaque bloc. L'intéressant n'est donc pas le codec
mais l'emballage, et trois choses s'y écrivent de travers si on se dit « ce
n'est que du LZ4 » :

* **les longueurs de bloc sont en gros-boutien**, dans un protocole qui est en
  petit-boutien partout ailleurs. À l'envers, le premier bloc annonce quelques
  centaines de mégaoctets et l'erreur parle de troncature sur un message
  complet ;
* **les blocs partagent un dictionnaire.** Le serveur comprime avec un seul
  `LZ4_stream_t` par image, donc une correspondance du quatrième bloc désigne
  couramment des octets produits par le premier. Décoder chaque bloc isolément
  donne une image plate exactement juste et une vraie image fausse par bandes —
  sept des onze gabarits le prouvent, et ils le prouvent parce que le décodeur
  de référence a été relancé avec le dictionnaire remis à zéro entre les blocs ;
* **le second octet est un `bitmap_fmt`**, et c'est lui qui fixe la longueur des
  lignes dont tout le reste dépend.

Deux endroits où wisq décide autrement que la référence, tous deux trouvés en
comparant les deux décodeurs sur 550 000 charges utiles plutôt qu'en relisant le
C : un décodage qui ne remplit pas la surface (la référence laisse voir ce que
son allocation contenait, wisq refuse), et une distance nulle (le format la dit
corrompue, lz4 la tolère et écrit des zéros, wisq refuse).

Le sabotage a aussi produit une réponse inattendue : la règle de lz4 selon
laquelle une correspondance ne peut pas finir dans les cinq derniers octets est
**inatteignable**. La retirer ne change aucun résultat, et l'arithmétique qui
dit pourquoi est dans `SpiceLZ4Tests`. Elle reste dans le code parce qu'elle est
celle de la référence, et parce que son inatteignabilité est une propriété des
*autres* bornes.

wisq annonce désormais la capacité `LZ4_COMPRESSION`, ce qui est une permission
et non une demande : le serveur la vérifie avant d'envoyer une image LZ4, et ce
qu'il envoie reste décidé par sa configuration ou par le message de préférence.
Ce dernier ne demande pas `lz4` : demander LZ4 c'est le demander *à la place*
des modes automatiques, et QUIC vaut plusieurs fois le rapport de LZ4 sur le
contenu photographique qui domine un bureau avec un fond d'écran. Sur un réseau
mobile, c'est la bande passante qui est rare, pas le décodage.

### Les dessins qui n'ont pas de codec

Fait. `DRAW_COPY_BITS`, `DRAW_BLACKNESS`, `DRAW_WHITENESS` et `DRAW_INVERS`
étaient tous comptés comme ignorés, ce qui à l'écran donne une fenêtre qui
défile en gardant son ancien contenu. Ce sont les messages les moins chers du
canal et parmi les plus fréquents : une fenêtre qui défile, c'est
`DRAW_COPY_BITS`.

Deux choses en font autre chose qu'une boucle.

**La source se découpe aussi.** La boîte et le clip disent où l'on écrit ;
rien ne dit où l'on lit, et un défilement près d'un bord nomme une ligne source
qui n'existe pas. La référence intersecte la région de destination avec un
rectangle décalé de la distance, ce qui laisse intactes les lignes sans source
au lieu de dupliquer le bord.

**La copie se recouvre elle-même.** Une fenêtre qui descend de dix pixels lit
des lignes qu'elle vient d'écrire. `spice_pixman_copy_rect` choisit un sens par
rectangle ; wisq lit toute la source d'abord. Le résultat est identique — l'ordre
de la référence existe justement pour imiter un instantané sans en allouer un —
et ce que ça coûte est l'aire de la région, sur une copie qui allait de toute
façon la parcourir.

Une asymétrie de la référence est reproduite plutôt que corrigée : `blackness`
passe `0x000000` et `whiteness` `0xffffffff`, donc sur une surface avec alpha
l'un la vide et l'autre la remplit. Écrire `0xff000000` pour le noir serait
*changer* le comportement du protocole en quelque chose de plus sensé, et le
serveur dessine en attendant l'autre.

### Le masque, décodé

Fait. Un `QMask` est un bitmap 1 bit qui *réduit* ce qu'un dessin touche :
`canvas_mask_pixman` intersecte la région de destination avec la région des bits
à un. `SpiceMask` le décode et `fill`, `copy` et les trois rasters le consultent
par pixel.

Il ne rejoint pas les rectangles, et c'est une décision plutôt qu'une limite :
la région des bits à un d'un bitmap 1 bit est une forme quelconque, dont la
décomposition en rectangles fait au pire un rectangle par pixel. Les rectangles
restent donc *où le dessin peut écrire* et le masque répond *s'il écrit*. Ce sont
toujours les rectangles qui sont signalés au rendu, délibérément : une région de
mise à jour est une indication de ce qu'il faut re-téléverser, donc un
sur-ensemble coûte un peu de bande passante et un sous-ensemble perd des pixels.

Trois choses s'y trompent d'une réflexion, et chacune produit une image :

* **quel bit d'un octet est le pixel de gauche** — `1BIT_LE` commence au bit 0,
  `1BIT_BE` au bit 7. À l'envers, le masque est en miroir par groupes de huit ;
* **le sens des lignes** — un masque est bas-en-haut par défaut comme tout
  bitmap de ce canal ;
* **où le masque se pose** — le pixel de destination *(x, y)* est le pixel de
  masque *(x − box.left + pos.x, y − box.top + pos.y)*. Oublier `box.left` passe
  tous les tests dont la boîte part de l'origine.

Et une quatrième qui n'est pas une réflexion : **hors du masque, c'est refusé,
pas autorisé.** La référence découpe les extents puis *intersecte*, donc un pixel
de destination sans pixel de masque au-dessus est retiré. Le traiter comme permis
peint tout ce que le masque n'atteint pas — ce qui, pour un petit masque sur une
grande boîte, ressemble beaucoup à un masque qui marche.

### L'opération raster, qui était lue puis jetée

Fait. Chaque message de dessin porte un `rop_descriptor` — onze bits — et wisq
le lisait puis l'ignorait : `fill` et `copy` écrivaient toujours la source
par-dessus la destination. C'est juste pour le descripteur de très loin le plus
courant et faux pour ceux qui comptent le plus quand ils arrivent : un
rectangle de sélection, un curseur de texte et un tracé élastique sont dessinés
en XOR, précisément pour que les dessiner deux fois efface. Ignorés, ils
s'affichent en plein et ne partent plus.

Deux couches, faciles à confondre. Le **descripteur** est ce que le fil porte ;
l'**opération** est l'une des seize de X11, une fonction booléenne d'un bit
source et d'un bit destination. `ropd_descriptor_to_rop` réduit la première à la
seconde, et ce n'est pas une table : c'est un nid de conditions qui remarque, par
exemple, qu'inverser les deux opérandes d'un XOR sans inverser le résultat
revient au XOR lui-même.

**Quel opérande le descripteur appelle « source » dépend du message.** Un
remplissage combine son *pinceau* avec la destination, donc c'est `INVERS_BRUSH`
qui inverse sa source. Une copie combine son *image* avec la destination — le seul
des trois où la lecture littérale est la bonne. Et `DRAW_OPAQUE` combine le
pinceau avec l'*image* : la destination n'est pas un opérande de son rop, parce
que l'image a déjà été posée par-dessus.

Deux comportements de la référence sont recopiés plutôt que corrigés :

* **les bits d'opération sont testés dans l'ordre, pas exclusivement.** Un
  descripteur portant `OP_OR` et `OP_AND` est un `OR` ; un sans aucun bit
  d'opération est une copie. Aucun des deux n'est un message malformé ;
* **quatre des issues ignorent tous les drapeaux d'inversion**, `INVERS_RES`
  compris : `BLACKNESS`, `WHITENESS`, `INVERS`, et le repli quand aucun bit
  d'opération n'est mis. `OP_BLACKNESS | INVERS_RES` donne `clear`, pas `set`.
  Ça ressemble à un oubli et c'est reproduit : le serveur dessine en attendant ce
  que fait son propre client.

`DRAW_BLEND` arrive avec, gratuitement : la référence les câble sur la même
fonction avec le commentaire « copy and blend are the same », et le protocole
donne à blend le type C de copy. C'est un message avec deux numéros.

### `DRAW_TRANSPARENT` : la couleur qui ne se dessine pas

Fait. Une couleur de l'image veut dire « laisse ce qu'il y a dessous », tout le
reste est copié. C'est la composition la plus simple du canal, et c'est ainsi
qu'une icône ou un curseur à silhouette nette se dessine sans canal alpha.

C'est aussi le seul dessin porteur d'image qui **n'a ni masque ni rop** : sa
forme entière est une image, une aire et deux couleurs. Un décodeur qui suppose
la disposition de `DRAW_COPY` lit les deux couleurs là où le rop et le mode
d'échelle se trouvent, puis déborde.

Trois détails viennent de `spice_pixman_blit_colorkey` :

* **la comparaison porte sur vingt-quatre bits.** La référence masque la clé par
  `0xffffff` avant la boucle puis compare `0xffffff & pixel`. Sur trente-deux
  bits, la clé ne correspondrait jamais à une source dont le quatrième octet
  n'est pas nul — c'est-à-dire la plupart ;
* **`src_color` n'est jamais lu.** Il est dans le message et la référence utilise
  `true_color`. Lire le mauvais des deux donne une image avec les mauvais trous,
  ce qui reste une image ;
* le mot entier est copié quand il ne correspond pas, alpha compris — modulo la
  règle de ce fichier qui tient le quatrième octet à zéro sur une surface sans
  alpha.

### `DRAW_ALPHA_BLEND` : la seule vraie composition

Fait. `__blend_image` fabrique un masque uni dont l'alpha est celui du message —
et seulement quand il n'est pas `0xff` — puis appelle
`pixman_image_composite32` avec `PIXMAN_OP_OVER`. L'arithmétique est donc celle
de pixman, pas celle de SPICE.

**La source est prémultipliée, et personne ne l'écrit nulle part.** Ni le
protocole, ni `canvas_base.c`, ni `sw_canvas.c` n'en parlent, et rien ne divise
jamais par l'alpha. Ce qui tranche est la chaîne :
`SPICE_BITMAP_FMT_RGBA` devient `PIXMAN_a8r8g8b8`, et le `OVER` de pixman est
défini sur une source prémultipliée. Prémultiplié est donc ce que la chaîne
*veut dire* plutôt que ce que quelqu'un a énoncé, et le lire autrement produit
des halos — une image, et une fausse.

Affirmation mesurée plutôt qu'argumentée : `scripts/spice-alpha-blend/` fait
tourner la formule de wisq et pixman côte à côte sur **43 008 000** combinaisons
de source, destination, des deux alphas et du drapeau. Aucune différence.

Deux détails de la même lecture : un alpha global nul ne dessine rien du tout,
et `DEST_HAS_ALPHA` décide si le quatrième octet de la destination est son
alpha. `SRC_SURFACE_HAS_ALPHA` n'est pas lu ici — la référence ne le passe que
sur le chemin surface-vers-surface.

### `DRAW_ROP3` : le cas général, en une ligne

Fait. C'est l'opération dont `DRAW_FILL`, `DRAW_COPY` et les trois rasters sans
opérande sont des cas particuliers : une fonction booléenne parmi 256, sur un
motif, une source et une destination. Windows appelle le même octet une
« opération raster ternaire » et donne des noms aux valeurs courantes —
`SRCCOPY` vaut `0xCC`, `PATCOPY` `0xF0`.

**L'opcode est sa propre table de vérité** :

    résultat = (opcode >> ((motif << 2) | (source << 1) | destination)) & 1

Cette ligne remplace les 256 gestionnaires générés de la référence, et ce n'est
pas une supposition. `common/rop3.c` enregistre chaque opcode avec sa formule
écrite à côté — `ROP3_HANDLERS(DPSoon, ~(*pat | *src | *dest), 0x01)` et 217
autres. `scripts/spice-rop3/check-rop3.py` les relit, évalue chacune sur les
huit combinaisons des trois bits, et compare : **218 formules, 0 désaccord**.

**La référence n'en implémente que 218, et les 38 qui manquent sont exactement
les 38 qui ignorent au moins un de leurs trois opérandes.** Mesuré aussi : les
deux ensembles coïncident élément par élément. Ce sont ceux qu'un serveur envoie
sous forme de message plus simple — `0xCC` en `DRAW_COPY`, `0xF0` en
`DRAW_FILL`, `0x00` en `DRAW_BLACKNESS` — et la référence appelle
`spice_critical("not implemented")` si l'un d'eux arrive quand même. wisq évalue
la table, donc les 256 fonctionnent.

**L'ordre des bits n'est pas celui de l'opération binaire.** `SpiceROP` indexe sa
table de quatre bits par `3 − (2·src + dst)`, en partant du haut ; celle-ci
indexe directement. Écrire l'une des deux conventions à la place de l'autre donne
une table en miroir — une image, et une fausse. Les deux sont épinglées par des
tests exhaustifs, et la ternaire aussi par les noms Windows : `SRCCOPY` veut dire
« la source », ce qui n'est vrai que sous un des deux ordres.

### Les flux vidéo : là où passent la plupart des pixels

Fait, sauf le décodage lui-même. Un serveur SPICE surveille les rectangles qui
changent sans arrêt et, passé un seuil, cesse de les envoyer en dessins pour les
envoyer en vidéo. Sur un bureau où quelque chose bouge — une vidéo, une page qui
défile, une animation — c'est là que passe la majorité des pixels. Un client qui
ignore les flux affiche un rectangle figé **exactement à l'endroit du
mouvement**, ce qui ne ressemble pas à une fonctionnalité manquante mais à une
connexion cassée.

`SpiceStreams` tient le registre : `STREAM_CREATE`, `STREAM_CLIP`,
`STREAM_DESTROY`, `STREAM_DESTROY_ALL`, et le placement de chaque image.

**Deux paires de dimensions qu'on prend pour une.** `stream_width` et
`stream_height` sont la taille des images qui arrivent sur le fil ;
`src_width` et `src_height` celle de la région sur l'écran du serveur. Elles
diffèrent dès que le serveur réduit avant d'encoder, ce qu'il fait couramment
pour économiser de la bande passante. Lire la mauvaise paire met la vidéo au bon
endroit à la mauvaise taille.

**`STREAM_DATA_SIZED` vaut pour une image, pas pour le flux.** Il porte sa
propre largeur, sa propre hauteur et sa propre destination, et la référence les
lit dans son `SpiceFrame` sans jamais toucher à celles du flux — donc l'image
suivante revient à la géométrie d'origine. Les stocker serait l'erreur évidente,
et se verrait comme une vidéo qui change de taille toute seule. Les deux formes
ne peuvent pas partager un lecteur non plus : lire une image dimensionnée avec
la forme simple prend sa largeur pour la longueur des données.

**Une troisième place pour la même idée d'orientation.**
`SPICE_STREAM_FLAGS_TOP_DOWN` est le bit 0 des drapeaux du flux. Celui d'un
bitmap est le bit 2 des siens, et celui d'un `jpegAlpha` le bit 0 d'un autre
octet encore. Trois octets différents pour « dans quel sens se lit cette
image ».

**Le report d'une image est un `PIXMAN_OP_SRC`**, pas un mélange : `put_image`
écrase, met à l'échelle au plus proche voisin quand l'image et sa destination
diffèrent, et respecte le clip du flux. Ce sont exactement les trois choses que
`SpiceSurfaces.copy` fait déjà, donc c'est composé plutôt que réécrit. Le report
prend des pixels plutôt qu'un message, pour qu'une machine sans décodeur JPEG
puisse le tester : sinon toute cette moitié est verte sans jamais tourner.

**Seul MJPEG est décodé**, et c'est celui qui ne coûte rien : chaque image est
un JPEG complet, donc le décodeur est celui que les images `.jpeg` utilisent
déjà. VP8, VP9, H.264 et H.265 demandent un vrai décodeur vidéo —
VideoToolbox côté Apple, rien que wisq embarque côté Linux. Ils sont **nommés**
plutôt que rassemblés sous « inconnu », parce qu'« le serveur a choisi H.264 »
est une explication sur laquelle un utilisateur peut agir, alors qu'un
rectangle figé n'en est pas une.

Et une image dans un codec non décodé n'atteint jamais le décodeur d'images de
la plateforme. Le garde qui l'arrête ne change aucun résultat — un VP8 n'est pas
un JPEG valide, le décodeur rendrait `nil` de toute façon — et il reste pour ce
qu'il empêche : des octets arbitraires venus du réseau qui entrent dans ImageIO
sans raison.

### `DRAW_STROKE` : des lignes d'un pixel, et pourquoi c'est un pixel

Fait. Un chemin, des attributs de ligne, une brosse et un descripteur de rop —
et **aucune largeur de trait nulle part**. Ce n'est pas un oubli du message :
`canvas_draw_stroke` pose `lineWidth = 0` sans condition. Ce sont les stylos
*cosmétiques* de Windows, un pixel quelle que soit l'échelle de la surface.

**Le point final n'est jamais dessiné.** La référence demande `CapNotLast`,
parce qu'une ligne cosmétique Win32 est exclusive de son extrémité. Ce n'est pas
un détail d'arrondi : un rectangle élastique est fait de quatre tracés qui se
partagent quatre coins, et dessiner l'extrémité peint chaque coin deux fois —
sous le `XOR` qu'un élastique utilise, deux fois veut dire *absent*, et faire
glisser une sélection laisserait quatre trous.

**Le biais d'octant existe pour une raison précise.** Bresenham doit trancher
chaque fois que la ligne idéale passe exactement entre deux pixels. Trancher
pareil dans toutes les directions, et une ligne A→B n'allume pas les mêmes
pixels que la même ligne B→A. `DEFAULTZEROLINEBIAS` retire un à l'erreur
initiale dans quatre octants sur huit — les quatre qui sont les inverses des
quatre autres — et les deux se rejoignent. C'est aussi la propriété que les
tests vérifient : un éventail de lignes tracées dans les deux sens doit donner
le même ensemble de pixels, ce qui teste toute la table plutôt qu'une entrée.

**Trois pièges de format**, tous tranchés par le démarshaller que la référence
*engendre* depuis `spice.proto`, pas par `draw.h` :

  * les drapeaux d'un segment font **un octet sur le fil**, là où
    `SpicePathSeg.flags` est un `uint32_t` en C ;
  * `style_nseg` et `style` n'existent sur le fil que si `STYLED` est posé —
    `LineAttr` est un aiguillage sur ses propres drapeaux, donc un attribut sans
    style tient en un octet, et lire une longueur et un pointeur quand même
    avale cinq octets de la brosse qui suit ;
  * `@ptr_array` décrit le côté C et non le fil : les segments se suivent, et
    lire un tableau d'offsets prendrait les drapeaux du premier pour un
    pointeur.

Et trois règles de parcours qui ne sont pas ce que les noms suggèrent : `BEGIN`
dépense son premier point comme *position* et non comme sommet ; `CLOSE` n'agit
qu'à l'intérieur d'un `END` ; et fermer rejoint le premier point de la figure
accumulée, pas celui du segment qui porte le drapeau.

**Une divergence assumée, sur les pointillés.** La référence ne pointille pas
une ligne d'épaisseur nulle : `miZeroDashLine` met la largeur à un, appelle le
pointilleur des lignes *épaisses*, et la remet à zéro — au-dessus d'un
commentaire qui dit « XXX kludge until real zero-width dash code is written ».
wisq parcourt les mêmes pixels de Bresenham dans les deux cas et saute ceux
qu'un blanc couvre, ce que le commentaire de la référence appelle de ses vœux.
Les pixels allumés sont un sous-ensemble de ceux de la ligne pleine — jamais à
côté — ce qui est la propriété qu'un utilisateur pourrait remarquer.

### `DRAW_TEXT` : des glyphes, et deux modes dont aucun n'est un rop

Fait, et c'est le dernier message du canal display. Une chaîne de glyphes
matriciels, un rectangle de fond, **deux** brosses, et deux descripteurs de rop.

**Aucun des deux modes n'est une opération raster.** `canvas_draw_text` remplit
le fond en `SPICE_ROP_COPY` et compose les glyphes en `PIXMAN_OP_OVER`, sans
jamais lire `back_mode` et sans lire `fore_mode` autrement que dans une
assertion qu'il vaut `PUT`. Son propre commentaire le dit : « *Nothing else
makes sense for text and we should deprecate it and actually it means OVER
really* ». Les deux sont décodés parce qu'ils sont sur le fil ; agir dessus
dessinerait ce qu'aucun autre client ne dessine.

**Les deux points d'un glyphe s'additionnent.** `render_pos` est là où se trouve
le curseur de texte, `glyph_origin` le décalage propre du glyphe — négatif pour
une jambage sous la ligne de base, vers la gauche pour une paire crénée.
`canvas_raster_glyph_box` écrit `render_pos.y + glyph_origin.y`. N'en prendre
qu'un met chaque accent au mauvais endroit, et ça ressemble à un problème de
police plutôt qu'à un problème de décodage.

**Trois profondeurs, trois règles de rembourrage différentes.** Le parseur
engendré les dimensionne `((l+7)/8)·h`, `((4l+7)/8)·h` et `l·h` : A1 et A4
complètent chaque rangée à l'octet, **A8 pas du tout**. Supposer une règle
commune cisaille chaque rangée de deux des trois.

**Les rangées se lisent du bas vers le haut**, à toutes les profondeurs, et le
drapeau `TOP_DOWN` n'y change rien : `canvas_put_glyph_bits` porte un
`//todo: support SPICE_STRING_FLAGS_RASTER_TOP_DOWN` et part de la fin des
données. Décodé et délibérément ignoré, parce que l'honorer dessinerait le texte
à l'envers de tous les autres clients face au même serveur.

**Un quartet A4 plein vaut 240, pas 255.** La référence écrit
`dest[i] = MAX(dest[i], *now & 0xf0)` : elle décale le quartet dans la moitié
haute au lieu de le mettre à l'échelle. Le texte A4 n'est donc jamais tout à
fait opaque. Le mettre à l'échelle serait plus joli et ne serait pas ce que le
serveur a dessiné.

Et les glyphes se combinent par `max`, pas par écrasement : accents et paires
crénées se recouvrent, et le glyphe suivant ne doit pas percer un trou dans le
précédent là où sa propre couverture est nulle.

Le canal display est complet. Ce qui reste n'est pas du dessin : les rapports de
flux (`STREAM_ACTIVATE_REPORT`, `STREAM_REPORT`) permettent au serveur d'adapter
son débit et ne mettent rien à l'écran — ils sont ignorés pour de bon, ce qui
fait d'eux les seuls exemples de « message ignoré » qu'un test puisse citer sans
qu'il expire.

### Le canal audio : le son de la machine distante

Fait pour la lecture. Sept messages, un codec d'état, et du PCM signé seize bits
petit-boutiste entrelacé par canal. Le canal a sa propre connexion, pour la même
raison que le pointeur : un son qui attend derrière un écran de pixels arrive en
retard, et un son en retard est pire que pas de son.

**Seul le PCM brut est décodé.** CELT 0.5.1 est marqué obsolète dans l'en-tête
de la référence, Opus est ce que négocient les serveurs modernes, et wisq
n'embarque de décodeur pour ni l'un ni l'autre. Ils sont **nommés** plutôt que
rassemblés sous « inconnu » : « le serveur a choisi Opus » est une explication
sur laquelle un utilisateur peut agir, le silence n'en est pas une. Et des
octets Opus lus comme des échantillons ne sont pas un échec discret — c'est du
bruit à plein volume, sorti d'un téléphone, à l'heure qu'il est.

Quatre décisions que la référence impose ou justifie :

  * **`PLAYBACK_MODE` porte son propre paquet.** Il a le même `time` et les
    mêmes octets de queue qu'un `DATA`, donc un changement de codec peut livrer
    ses premiers échantillons dans le même message. Ne lire que le mode les
    perd ;
  * **le codec vaut `raw` tant qu'aucun `MODE` n'est arrivé**, parce qu'un
    serveur qui n'en envoie jamais envoie du PCM. Traiter « pas encore de
    mode » comme « inconnu » couperait le début de chaque flux — et le début
    est la partie qu'on remarque ;
  * **`STOP` oublie le flux et garde le codec.** Un serveur qui arrête puis
    reprend ne renvoie pas `MODE` ; le remettre à zéro rendrait indécodable
    tout ce qui suit la reprise, avec pour symptôme un son qui marche une fois
    et plus jamais ;
  * **le muet jette le paquet au lieu de le mettre à zéro.** Des échantillons
    nuls restent des échantillons : ils tiennent l'horloge et la longueur du
    tampon. Les jeter est ce que fait la référence, et c'est aussi ce qui évite
    qu'une session muette dépense la batterie en silence.

Le volume et la latence sont retenus tels que le serveur les envoie, sans être
appliqués : le volume de SPICE est le réglage du mixeur **de l'invité**, et
l'appliquer ici atténuerait deux fois.

### Le canal record : le micro du téléphone vers l'invité

Fait, décodage et encodage. C'est le miroir de la lecture, et la direction est
toute la différence : là, le serveur décrit un flux et envoie les échantillons ;
ici, le serveur décrit le flux qu'il veut et **c'est le client qui envoie**. Le
fichier est donc surtout un encodeur, vérifié comme `SpiceInputs` — sans
serveur, parce que ce qui doit être juste, ce sont les octets qui sortent.

**`RECORD_START` n'a pas de champ `time`** là où `PLAYBACK_START` en a un.
L'asymétrie est réelle : un serveur qui dit à un client quoi enregistrer n'a pas
d'horloge à lui donner, puisque les échantillons du client portent la leur. Lire
un quatrième mot mangerait ce qui suit le message.

**Le client choisit le codec ici**, et il n'y a qu'un choix honnête : `raw`, le
seul que wisq sache produire. Annoncer Opus et envoyer du PCM donnerait du bruit
à l'invité. Le codec s'annonce avant le premier paquet de chaque flux, suivi
d'un `START_MARK` qui dit où les échantillons commencent — et **un nouveau flux
le réannonce**, à l'inverse de la lecture où `STOP` garde délibérément le codec.
La raison est encore la direction : là c'est le serveur qui décide et ne renvoie
rien, ici c'est nous.

Et le muet n'envoie rien plutôt que du silence. Des échantillons nuls
maintiendraient l'enregistreur de l'invité en marche et son fichier en train de
grossir, ce qui est le contraire de ce que demande quelqu'un qui coupe son micro
— et sur un téléphone, ça garde la radio occupée pour rien.

Ce qui reste sur l'audio : la capture et la sortie elles-mêmes, qui demandent
AVAudioEngine et n'existent donc que côté Apple. Tout ce qui se décide sans
haut-parleur ni micro est ici, et testé.

### La fenêtre GLZ : un nombre qui n'était pas un réglage

Fait, et ce n'était pas l'optimisation que le titre annonçait.

`SPICE_MSGC_DISPLAY_INIT` porte deux tailles — le cache de pixmaps et la
fenêtre du dictionnaire GLZ — l'une à côté de l'autre, dans le même message,
avec la même forme. Rien ne dit qu'elles ne se comportent pas pareil. wisq
annonçait **zéro pixel** de fenêtre, avec un commentaire qui l'expliquait par
« wisq ne décode pas GLZ ».

Les deux moitiés étaient fausses. GLZ est décodé depuis que sa fenêtre a été
branchée dans la pompe. Et zéro n'est pas une petite fenêtre :

    if ((uint32_t)new_image_size > dict->window.size_limit) {
        dict->cur_usr->error(dict->cur_usr, "image is bigger than window\n");
    }

`glz_dictionary_window_get_new_head` est appelé en tête de *chaque* encodage
GLZ. Ce `error` est `glz_usr_error`, qui appelle `spice_critical`, qui appelle
`abort()`. Il n'y a pas de repli, pas d'encodage plus petit tenté : un client
qui annonce une fenêtre plus petite qu'une image **tue le processus serveur** à
la première image GLZ.

Et ce n'était pas hypothétique en attendant un éventuel passage à `autoGLZ`.
`reds.cpp` initialise la compression du serveur à `AUTO_GLZ`. Un serveur qui
n'annonce pas la capacité `preferred_compression` ne reçoit jamais notre
message et garde donc GLZ pour toute la session ; sur les autres, il reste la
fenêtre entre `DISPLAY_INIT` et l'arrivée du message. wisq ne choisissait pas
GLZ — il y était exposé par défaut, avec une fenêtre qui faisait tomber le
serveur.

**La lecture ne suffisait pas, donc c'est mesuré.**
`scripts/spice-glz-window/` compile l'encodeur de référence et lui donne des
fenêtres choisies. Une image 64×64 passe à 4096 pixels et fait abandonner à
4095. La borne est `image_size > size_limit`, ce qui change la nature du
nombre : ce n'est pas « une fenêtre non nulle » qu'il faut, c'est **une fenêtre
au moins aussi grande que la plus grande image**. Pour tout ce qui atteint GLZ,
`__get_pixels_num` la donne exactement en largeur × hauteur, `can_lz_compress`
ayant déjà écarté les strides excédentaires.

D'où `1 << 23` : 8 388 608 pixels, une image entière jusqu'en 3840×2160. Ce
n'est pas un avis sur la quantité d'historique utile — la résolution de
l'invité n'est pas connue quand ce message part. spice-gtk arrive au même
endroit par l'autre bout, en bornant sa propre fenêtre à 12 Mio au minimum et
en choisissant 32 Mio d'ordinaire, soit les mêmes 8 Mi pixels.

La fenêtre corrigée, le troisième obstacle à `autoGLZ` tombe et les deux
décisions se prennent enfin ensemble — c'était le sujet de la tâche. Les deux
autres tenaient déjà : GLZ décode, et `get_compression_for_bitmap` rétrograde
`GLZ` en `LZ` dès que `bitmap_fmt_has_graduality` est faux, ce qui exclut tous
les formats à palette. Un test lie désormais les deux valeurs, pour qu'aucune
ne puisse revenir en arrière seule.

**Ce que ça dit du reste.** Côté allocation, le cache de pixmaps est bien un
budget : `dcc_add_to_cache` évince, et quand il n'y arrive pas il renvoie
`FALSE` et l'image part sans être mise en cache — une valeur trop basse ne coûte
que de la bande passante. J'ai conclu de là que c'était le nombre inoffensif des
deux. C'était vrai de son allocation et faux de son effet : la section suivante
montre qu'une valeur trop *haute* fait envoyer au serveur des images réduites à
leur seul identifiant. Deux nombres voisins, de même forme, et il a fallu les
regarder l'un après l'autre pour voir que leurs valeurs sûres sont opposées.

### Le cache de pixmaps : la même case, la réponse inverse

Fait, et c'est la suite directe de la fenêtre GLZ — même message, même forme,
conclusion opposée.

`SPICE_MSGC_DISPLAY_INIT` porte les deux nombres côte à côte. wisq annonçait
**4 Mi pixels** de cache d'images, et n'a pas de cache d'images. Le commentaire
du décodeur le disait déjà, à propos des palettes : « nommée depuis un cache que
ce client ne tient pas ».

Le mécanisme est entièrement côté serveur. Le pilote QXL de l'invité marque
`QXL_IMAGE_CACHE` une image qu'il compte redessiner — icônes, glyphes, bordures,
tuiles de fond d'écran — ce que `red-parse-qxl.cpp` traduit en
`SPICE_IMAGE_FLAGS_CACHE_ME`. Au premier envoi, `marshal_lossy_or_lossless`
appelle `dcc_pixmap_cache_unlocked_add(dcc, id, width * height, …)` — l'unité est
donc bien le pixel — et **ce n'est que si cet ajout réussit** qu'il renvoie
`CACHE_ME` au client. À chaque envoi suivant du même identifiant, `fill_bits`
trouve `dcc_pixmap_cache_unlocked_hit` vrai et écrit
`SPICE_IMAGE_TYPE_FROM_CACHE` : un nom, et aucun pixel.

wisq ne sait pas le résoudre. `SpiceDisplayWire.image` rend un descripteur sans
charge utile, `pixels(of:)` renvoie `nil`, et le dessin est sauté — la région
garde ce qu'il y avait dessous. Ni plantage ni trou noir : **des pixels
périmés, en silence**, et précisément sur les images qu'un bureau répète le
plus.

Annoncer zéro ferme la porte à la source. `cache->available` part de la taille
annoncée, le premier ajout la rend négative, la boucle d'éviction trouve un
anneau vide (`ring_get_tail` renvoie `NULL`) et l'ajout renvoie `FALSE`. Rien
n'est jamais enregistré, `CACHE_ME` n'est jamais renvoyé, aucun succès de cache
n'est possible, et toutes les images arrivent avec leurs octets. Ça coûte de la
bande passante — ces images sont réémises — et c'est le bon prix à payer tant
qu'il n'y a pas de cache où la dépenser.

**Ce que la paire enseigne.** Deux nombres voisins, de même type, dans le même
message, et les valeurs sûres sont opposées : la fenêtre GLZ doit être *grande*
(en dessous d'une image, le serveur fait `abort()`), le cache doit être *nul*
(au-dessus de zéro, le serveur envoie des noms que le client ne peut pas lire).
Rien dans le nom des champs, leur type ou leur ordre ne le laisse deviner. Ce
qui les distingue vit dans trois fichiers que le client n'exécute jamais.

Un test lie les deux moitiés : `testAnImageNamedFromTheCacheHasNoPixelsToDraw`
décode un vrai message `FROM_CACHE` et montre qu'il n'en sort aucun pixel, et
`testThePixmapCacheIsZeroBecauseThereIsNoCacheToPutImagesIn` épingle le zéro en
s'y référant. Relever le nombre annoncé sans construire le cache ne peut donc
plus passer.

**Ce qui reste, et qui n'est pas une correction mais un gain.** Un vrai cache
côté client — stocker les images décodées par `descriptor.id`, avec une borne et
une éviction, et honorer les messages d'invalidation qui vont avec — rendrait au
lien mobile ce que la correction lui coûte : une icône envoyée une fois au lieu
de vingt. Les deux moitiés doivent atterrir ensemble ; une entrée périmée est
pire qu'une image réémise.

### Le cache d'images, et le champ que personne ne lisait

Fait, et la correction précédente est rendue : `pixmapCachePixels` remonte à
4 Mi pixels parce qu'il y a désormais quelque chose derrière.

**La règle est que le serveur évince et que le client obéit.** C'est
contre-intuitif — tout dit qu'un cache borné doit évincer tout seul — et c'est
la référence qui tranche : `dcc_pixmap_cache_unlocked_add` évince sa queue LRU
puis appelle `dcc_push_release(dcc, SPICE_RES_TYPE_PIXMAP, tail->id, …)`, qui
part au client en `SPICE_MSG_DISPLAY_INVAL_LIST`. Deux chaînes LRU — l'une
ordonnée par les envois du serveur, l'autre par les dessins du client —
divergeraient, et chaque divergence est un `FROM_CACHE` qui nomme une image déjà
jetée, donc un dessin sauté. `SpicePixmapCache` refuse donc plutôt que d'évincer
quand le budget est plein : ça coûte une image réémise, là où tenir en douce
plus que ce qu'on a promis coûte l'application.

N'entrent dans le cache que les images dont le descripteur porte `CACHE_ME`
(bit 0), et c'est une instruction précise et non une indication :
`marshal_lossy_or_lossless` ne pose ce drapeau **qu'après** que son propre ajout
a réussi.

**Le champ que personne ne lisait.** Les invalidations n'arrivent pas dans un
message à elles. wisq lit l'en-tête de dix-huit octets, donc côté serveur
`dcc->is_mini_header()` est faux et c'est `send_free_list_legacy` qui tourne :
l'`INVAL_LIST` part dans un sous-marshaller et `set_header_sub_list` note où il
se trouve **à l'intérieur du message qui partait de toute façon**.
`SpiceWire.DataHeader` décodait `subList` depuis toujours et rien ne le lisait.
C'était sans conséquence tant que rien n'était en cache — avec une taille nulle
le serveur n'évince jamais, donc n'envoie jamais d'invalidation — et ça cessait
de l'être à la seconde où un cache existe.

`SpiceSubMessages` lit donc la liste, et la condition est celle du client de
référence : `if (msg_type == SPICE_MSG_LIST || sub_list_offset)`. Les
sous-messages sont traités **avant** le message qui les porte, comme dans
`spice_channel_recv_msg`, ce qui est l'ordre qu'il faut : le serveur a évincé
pour faire de la place à ce qu'il envoie maintenant.

Deux pièges de format, tous deux du genre qui donne une image plausible :

* `SpiceSubMessageList.size` **est un compte, pas une taille**. C'est
  `spice_marshaller_add_uint16(sub_list_m, sub_list_len)` qui part sur le fil, et
  spice-gtk boucle dessus comme sur un compte. Lu comme un nombre d'octets, une
  liste de deux entrées en réclamerait une centaine ;
* `ResourceID` fait **neuf octets sans remplissage** — un `uint8` puis un
  `uint64`. Lu comme une structure alignée naturellement, la deuxième entrée
  commence un octet trop tôt et tous les identifiants suivants sont du bruit.

Et le décalage zéro est un vrai décalage : le sentinelle « pas de liste »
appartient au champ d'en-tête, pas à l'analyseur — `SPICE_MSG_LIST` place la
sienne au tout début de son corps. L'avoir replié dans l'analyseur rendait cette
branche muette, et c'est une sonde jetable qui l'a montré, pas un test.

**Ce qu'un sabotage a appris.** Retirer le filtre de type sur la liste
d'invalidation a survécu à la suite entière. Diagnostic : branche inatteignable
avec un serveur conforme — `dcc_push_release` n'a qu'un appelant et il passe
toujours `SPICE_RES_TYPE_PIXMAP`, les palettes ayant leurs propres messages 107
et 108. Le filtre reste, parce que le protocole type la liste et que
`SPICE_RESOURCE_TYPE_ENUM_END` annonce une énumération faite pour grandir : les
identifiants viennent d'espaces différents, donc le jour où un second type
apparaît, un client sans filtre jette une image parfaitement valide dès que deux
identifiants se croisent. Un test le distingue maintenant.

### Le cache de palettes : celui qu'on ne peut pas refuser

Fait, et c'est la même forme que le cache d'images avec une différence qui
change tout : **il n'y a pas de taille à annoncer**.

`dcc_palette_cache_palette` est tout le mécanisme : si `palette->unique` est déjà
connu du serveur, il pose `PAL_FROM_CACHE` et **rentre sans mettre les couleurs
sur le fil** ; sinon il ajoute et pose `PAL_CACHE_ME`. La taille qu'il applique
est `CLIENT_PALETTE_CACHE_SIZE`, une constante du `dcc.h` du serveur. Rien dans
`DISPLAY_INIT` ne la négocie. Là où le cache d'images pouvait être décliné en
annonçant zéro, celui-ci ne peut pas l'être du tout.

**Et ce n'était pas un dessin perdu, c'était la session.** `SpiceBitmap.pixels`
lève `missingPalette` pour un format palettisé sans couleurs, et une erreur levée
arrête la pompe. Donc avant cette tranche, toute image nommant une table déjà
envoyée coupait la connexion. Un nom irrésolu part désormais là où part un codec
non décodé : compté, cette partie de l'écran laissée tranquille, la connexion
gardée. Une image qui ne porte aucune table et n'en nomme aucune lève toujours,
parce que c'est un message qui se contredit lui-même et non un client à qui il
manque quelque chose.

Le reste suit le cache d'images : le serveur évince et nomme, le client obéit.
Les messages diffèrent — les palettes ne sont pas dans la liste de ressources,
elles partent en `INVAL_PALETTE` (107) une par une ou `INVAL_ALL_PALETTES` (108)
pour le lot, des messages ordinaires de premier niveau. La borne est en *entrées*
et non en couleurs, parce que c'est ce que le serveur compte :
`red_palette_cache_add(dcc, palette->unique, 1)` facture une unité quelle que
soit la longueur de la table.

Deux détails que les tests épinglent :

* **`unique` à zéro n'est pas un identifiant.** `dcc_palette_cache_palette` teste
  `if (palette->unique)` avant quoi que ce soit, donc une telle table n'est
  jamais mise en cache ni jamais nommée. La ranger sous la clé zéro ferait de
  toutes les tables sans unique la même table ;
* **les drapeaux du bitmap ne sont pas ceux du descripteur.** `PAL_CACHE_ME` est
  le bit 0 du bitmap là où `CACHE_ME` est le bit 0 du descripteur, et le bit 2
  vaut `TOP_DOWN` d'un côté contre `CACHE_REPLACE_ME` de l'autre. Deux mots de
  drapeaux, une seule image, et rien d'autre que le champ d'où ils viennent pour
  les distinguer.

### Les capacités audio : une absence qui tient, une qui coûtait

Fait. Suite de l'audit « qu'est-ce que ce client promet », cette fois avec un
résultat en partie rassurant — ce qui mérite d'être écrit aussi.

Seul le canal display annonçait quelque chose. Playback, record, curseur,
entrées et principal envoyaient tous un jeu vide.

**Le codec absent est correct, et c'est maintenant dans le code.**
`snd_desired_audio_mode` est toute la décision : `RAW` si la compression est
coupée, `OPUS` si `test_remote_cap(SPICE_PLAYBACK_CAP_OPUS)` et que la fréquence
s'y prête, `RAW` sinon. CELT n'est même plus dans le chemin. Un client qui ne dit
rien sur les codecs reçoit donc du PCM brut — exactement ce que wisq décode.
C'est la même forme que le `multiCodec` absent du display : une absence qui a
l'air d'un oubli et qui porte tout. L'annoncer rendrait l'audio muet
instantanément.

**Le volume manquant, lui, coûtait.** `snd_send_volume` et `snd_send_mute`
commencent tous deux par `if (!rcc->test_remote_cap(cap)) return false`, avec
`SPICE_PLAYBACK_CAP_VOLUME` d'un côté et `SPICE_RECORD_CAP_VOLUME` de l'autre.
Sans l'annoncer, le serveur n'envoyait jamais ces quatre messages — que wisq
décode, avec des tests. Rien ne cassait, le volume SPICE étant le réglage du
mixeur de l'invité que wisq mémorise sans l'appliquer ; mais c'était la forme du
défaut `sizedStream`, à coût plus faible : une capacité qu'on sait honorer et
qu'on n'annonce pas.

**Les deux canaux ne numérotent pas pareil**, et c'est le piège à retenir :
`VOLUME` vaut 1 des deux côtés, mais `OPUS` est le bit 3 en lecture et le bit 2
en enregistrement, l'énumération record n'ayant pas de `LATENCY`. Que `VOLUME`
coïncide est ce qui rend la transposition dangereuse — elle passe la seule
capacité que wisq envoie vraiment. D'où deux énumérations plutôt qu'une partagée.

`LATENCY` n'est pas annoncée, et celle-là est un « on ne sait pas » plutôt qu'une
décision : aucun envoi de `MSG_PLAYBACK_LATENCY` n'apparaît dans les sources
serveur vendues ici, donc ce que l'annoncer apporterait n'est pas établi.
spice-gtk l'annonce. À vérifier ailleurs avant de bouger.

**Et le test est sur la prise, pas sur la constante.** Le défaut visé n'est pas
une mauvaise liste : c'est une liste correcte qui n'arrive jamais jusqu'à
`open` — ce qu'avaient les deux canaux audio. Le sabotage qui remet
`channelCaps: []` est celui qui compte.

### Les jetons de l'agent : le chemin que la référence n'emprunte jamais

Fait. Quatrième tour de l'audit des promesses, sur les capacités du canal
principal — vides elles aussi.

`MainChannel::push_agent_connected` choisit le message selon une capacité :

    if (rcc->test_remote_cap(SPICE_MAIN_CAP_AGENT_CONNECTED_TOKENS))
        pipe_add_type(RED_PIPE_ITEM_TYPE_MAIN_AGENT_CONNECTED_TOKENS);   // 115, avec un compte
    else
        pipe_add_empty_msg(SPICE_MSG_MAIN_AGENT_CONNECTED);              // 107, vide

spice-gtk l'annonce, wisq ne l'annonçait pas : **le chemin que wisq empruntait
toujours est celui que le client de référence n'emprunte jamais.** C'est une
raison de le regarder de près, pas de le croire éprouvé.

**Ce que ça coûtait.** Un compte de jetons est la seule chose qui rend l'agent
inscriptible, et `reds_reset_vdp` dit où un client en apprend un : « une fois à
l'initialisation du canal principal, et une fois à la connexion de l'agent avec
`SPICE_MSG_MAIN_AGENT_CONNECTED_TOKENS` ». Il n'y a pas de troisième occasion —
`MAIN_AGENT_TOKEN` ne fait que rendre des jetons à mesure que le serveur
consomme ce que le client a envoyé.

Or au redémarrage de l'agent, `RedCharDevice::reset` rend au client tout son
quota **du côté serveur** (`num_client_tokens += num_client_tokens_free`) et ne
peut le dire que dans le message 115. Un client qui lit 107 garde ce qui lui
restait. Être bas ne fait que gaspiller ; être à **zéro** ne se rattrape jamais.

Et la panne est sournoise : `AGENT_START` part quand même — c'est un message du
canal principal, il ne coûte pas de jeton — donc la poignée de main a l'air
normale. Mais toute donnée d'agent qui suit, à commencer par l'annonce de
capacités du client lui-même, reste en file : `spend()` échoue, rien ne part, le
serveur ne consomme rien, aucun jeton ne revient. Inerte plutôt que visiblement
cassé.

**Ce qu'il fallait établir avant d'ajouter le bit.** Il siège au milieu des
drapeaux de migration et se lit comme l'un d'eux. `migrate_connect` ne s'en sert
que pour poser `try_seamless`, puis exige encore `SEAMLESS_MIGRATE` — le bit 3,
que wisq n'annonce pas — avant de faire quoi que ce soit de sans couture, et
retombe sur le semi-sans-couture sinon. Demander le message à jetons ne peut
donc pas entraîner la migration avec lui.

Le test lit les mots de capacité sur la prise, comme pour l'audio : le défaut
visé n'est pas une mauvaise liste, c'est une liste correcte qui n'arrive jamais
jusqu'à `open`.

### L'audit des capacités, terminé : les six canaux

Cinq tranches (#64, #66, #67, #68, #69) sont sorties d'une seule question posée
à chaque canal : **qu'est-ce que ce client promet, et tient-il chaque
promesse ?** Le tableau ci-dessous clôt la série. Il est là surtout pour dire que
le filon est *épuisé* et non *abandonné* — la différence qu'on ne peut plus
reconstituer six mois après.

| canal | capacités du protocole | ce que wisq annonce |
| --- | --- | --- |
| principal | 4 | `AGENT_CONNECTED_TOKENS` |
| display | 9 | `sizedStream`, `preferredCompression`, `lz4Compression` |
| lecture audio | 4 | `VOLUME` |
| enregistrement | 3 | `VOLUME` |
| curseur | **0** | — |
| entrées | 1, côté serveur | — |

Ce que chaque ligne a coûté ou évité :

* **principal** — sans `AGENT_CONNECTED_TOKENS`, le serveur envoie le message 107
  sans compte de jetons ; à zéro jeton le presse-papiers ne repart jamais de la
  session. Les trois autres bits restent absents : wisq ne migre pas et n'a pas
  d'usage du nom de l'invité ;
* **display** — `sizedStream` manquait et le serveur *jetait* les images
  redimensionnées ; `multiCodec` est absente **exprès**, puisqu'avec elle le
  serveur choisirait un codec vidéo que wisq ne décode pas ;
* **audio** — `VOLUME` manquait et quatre décodeurs testés n'étaient jamais
  atteints ; aucun codec n'est annoncé **exprès**, `snd_desired_audio_mode`
  rendant du PCM brut à qui n'en réclame pas. Et les deux canaux ne numérotent
  pas pareil : `OPUS` au bit 3 en lecture, au bit 2 en enregistrement ;
* **curseur** — le protocole ne définit aucune capacité pour ce canal. Rien à
  annoncer, et ce n'est pas un oubli ;
* **entrées** — une seule existe, `KEY_SCANCODE`, et c'est le *serveur* qui
  l'annonce pour dire qu'il accepte des scancodes bruts. wisq envoie
  `KEY_DOWN`/`KEY_UP`, que `inputs-channel.cpp` traite sans condition (lignes
  265-284, vérifié). Rien à annoncer, rien à vérifier.

**La leçon, une fois pour toutes.** Une capacité annoncée est une affirmation sur
ce client, et elle se périme dans les deux sens. Celles qu'on annonce sans savoir
faire se remarquent — le symptôme est chez nous. Celles qu'on sait faire sans les
annoncer sont bien plus discrètes, parce que le symptôme est chez le serveur : une
image jetée, un message jamais envoyé, un compte jamais transmis. Quatre des cinq
trouvailles étaient de ce second type.

**Et l'heuristique qui a trouvé la dernière** : quand la référence et nous
prenons des branches différentes, c'est la nôtre qui est la moins éprouvée. Ce
n'est pas symétrique, et ça ne demande pas de soupçonner un bug — juste de
remarquer la divergence.

## Lot 6 — finition

- iPad : curseur système, multi-fenêtres, pointeur indirect (souris et trackpad).
- Raccourcis Siri et widgets « se connecter à … ».

  Ces deux points demandent l'appareil, et pas seulement pour être testés : ce
  sont des décisions d'interface qu'on ne prend pas au jugé. Ce qui peut être
  tranché d'ici, et qui l'est :

  - **Le pointeur indirect ne remplace pas le modèle tactile, il s'ajoute à
    lui.** `UIPointerInteraction` donne un curseur système qui doit se
    *superposer* au curseur distant, pas s'y substituer : deux curseurs qui
    divergent valent mieux qu'un seul qui ment sur l'endroit où le clic
    atterrira. UTM a fait le choix inverse et c'est là que ses signalements de
    bugs se concentrent.
  - **Multi-fenêtres : une session par scène, jamais partagée.** Deux fenêtres
    sur la même machine distante voudraient dire deux clients sur une connexion
    dont le protocole suppose un seul — les canaux SPICE portent un état par
    connexion (caches d'images, fenêtre GLZ, jetons d'agent) qu'on ne peut pas
    dédoubler sans mentir au serveur.
  - **Les raccourcis Siri ne transportent pas de secret.** Un raccourci nomme
    une machine enregistrée ; le jeton et l'empreinte restent dans le trousseau
    et ne traversent jamais l'intention. Un raccourci exporté est un fichier que
    l'on partage sans y penser.
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
- Partage de fichiers. **La moitié protocole est faite** : SPICE porte un
  transfert de fichiers vers l'invité sur le canal agent que wisq parle déjà
  pour le presse-papiers (`FILE_XFER_START`/`STATUS`/`DATA`), et
  `SPICESession.sendFile` le fait — charge START épinglée octet pour octet
  par GLib lui-même (`scripts/spice-file-xfer-fixtures/`), les deux bords du
  fichier vide tenus (un `DATA` vide obligatoire pour zéro octet, interdit à
  la fin sinon — chacun un bug amont documenté), tranches de 64 Kio au fil
  des jetons, huit statuts finaux avec des mots sur lesquels agir. **Le geste
  aussi** : un bouton dans la barre de session des machines SPICE, le sélecteur
  de documents grand ouvert (ce que l'invité accepte est l'affaire de
  l'invité), et une bannière qui suit l'envoi — visible chrome caché, parce
  qu'un transfert finit longtemps après le geste qui l'a lancé ; l'issue reste
  affichée jusqu'à être congédiée, un envoi en cours ne l'est pas d'un tapot.
  **Et le fichier ne passe pas en mémoire** : il est lu sur le disque un
  morceau de 64 Kio à la fois, chaque morceau demandé quand les jetons ont
  vidé le précédent — un film part comme un document, et sa taille est
  l'affaire de l'invité. La portée de sécurité du sélecteur vit avec la
  source, pas avec le geste : réclamée dans la vue, elle serait rendue avant
  la première lecture. Une lecture que le disque refuse, ou un fichier qui a
  moins d'octets qu'annoncé au moment de les lire, ferme le transfert de ce
  côté avec `error` pour l'agent — c'est ce que la référence envoie pour tout
  échec local qui n'est pas une annulation ; envoyer le fichier court
  laisserait l'agent attendre des octets qui ne viendront jamais. La variante
  « dossier monté côté agent » reste ouverte et
  demanderait d'abord un vrai chantier sur le serveur HTTP du démon — corps
  `String`, 64 Kio, JSON figé : le binaire n'y passe pas aujourd'hui, et le
  dire ici évite de le redécouvrir.

## Ce qu'on doit à UTM

Leur client iOS a dix ans d'avance sur le toucher, et il est sous Apache 2.0.
Rien n'a été copié — tout est réécrit en Swift — mais quatre idées viennent de
là : l'inertie confiée à `UIDynamicItem` plutôt qu'à une boucle maison, le délai
de 50 ms entre appui et relâchement, la matrice d'arbitrage des reconnaisseurs de
gestes, et le principe même de rendre l'affectation des gestes configurable
plutôt que de figer un jeu.

## L'identifiant de VM, entre l'URL et virsh (fait)

`service.rs` prenait le segment de chemin tel quel et le passait à
`backend.get/start/stop`, qui le donne à `virsh` en argument. Rien ne le
validait.

Deux résultats négatifs d'abord, sondés plutôt que supposés, parce que ce sont
ceux qu'on suppose faux :

- **Pas d'injection de commande.** `Command::new(virsh).args([...])` construit un
  argv, jamais une ligne de shell. Un identifiant valant `; rm -rf /` arrive
  comme un seul argument que virsh ne trouve pas.
- **Pas d'injection JSON.** `vm::escape` traite le guillemet, l'antislash, les
  trois contrôles nommés et tout ce qui est sous 0x20.

Ce qui est réel est **l'injection d'argument** : un identifiant qui commence par
un tiret n'est pas une donnée pour un analyseur d'options, c'est une option.
Sondé de bout en bout, statut 200 à chaque fois — `/v1/vms/-c/start` fait
parvenir `-c` au backend.

Portée dite honnêtement : cela demande le jeton porteur, donc c'est une escalade
*dans* une session authentifiée, pas une entrée. Le chemin n'est pas décodé en
pourcent, donc un `/` ne peut pas figurer dans un segment et une URI
`--connect=qemu+ssh://…` complète n'est pas atteignable ainsi. Quels drapeaux le
sont dépend du jeu d'options de virsh, qui n'est pas installé ici : aucun exploit
précis n'est revendiqué, et la classe est fermée quand même.

L'identifiant est désormais vérifié une fois, à la frontière du routage, contre
une **liste blanche** : non vide, 255 octets au plus, pas de tiret initial,
lettres, chiffres, point, tiret ou souligné. Liste blanche et pas liste noire :
« les caractères que virsh n'aime pas » est une supposition sur l'analyseur d'un
autre programme, et elle vieillit mal.

Six sabordages, dont trois de sur-correction — refuser le point, le tiret interne
ou les majuscules casse des noms que les gens utilisent vraiment, et les tests le
disent. Le sixième a d'abord survécu : `DemoBackend` répond 404 « VM introuvable »
pour tout nom inconnu, donc un test qui n'affirmait que le *statut* ne
distinguait pas un refus de validation d'une absence. C'est le message qui les
sépare, et c'est lui que le test lit maintenant.

## Les secrets de l'agent, et la fenêtre entre deux appels système (fait)

Le jeton porteur et la clé privée TLS étaient écrits par `fs::write`, puis
resserrés à `0600` à l'appel système *suivant*. `fs::write` crée le fichier au
mode par défaut — **0644** sous le `umask 022` habituel — donc chaque secret
existait, un instant, lisible par n'importe quel compte local. Le répertoire
d'état à 0755 ne couvrait pas non plus cet instant.

Le mode passe désormais dans le `open`, où le noyau l'applique avant que le
fichier existe pour qui que ce soit, et le répertoire est en 0700.

**La fenêtre n'est pas étroite.** Un fil qui interroge le fichier pendant que
l'écriture a lieu a compté **747 observations à un mode autre que 0600 sur 100
tours** de l'ancienne forme — environ sept `stat` de large — et **zéro** pour la
nouvelle, à 100, 1 000 et 10 000 tours.

Ce qui vaut d'être retenu n'est pas le correctif mais le garde-fou qui existait
déjà. `tls.rs` portait un test nommé `the_key_is_not_world_readable`, et **il
passe avec la course intacte** : il lit le mode une fois l'écriture terminée, et
les deux formes finissent à 0600. Vérifié plutôt que supposé — course
réintroduite, ce test passe toujours et seul le nouveau test qui observe échoue.

C'est le troisième garde-fou de cette série à inspirer plus de confiance qu'il
n'en méritait, après la branche `sw.js` qui recopiait son propre repli et le test
de réservation LZ qui ne pouvait pas échouer pour la raison de son nom. Le motif
commun : **un test qui n'inspecte que l'état final ne peut rien dire de ce qui
s'est passé au milieu.**

## Le cadrage HTTP de l'agent (fait)

Le démon est un serveur HTTP/1.1 écrit à la main, exposé sur le réseau local
d'un NAS. Son en-tête de fichier annonce « délibérément strict ». Il ne l'était
pas sur le cadrage des corps de requête, et quatre requêtes le montraient — les
quatre vérifiées par sonde avant toute correction, pas déduites d'une lecture :

| requête | avant | après |
| --- | --- | --- |
| `Transfer-Encoding: chunked` | corps **vide** en silence, réponse 200 | 501 |
| `Content-Length` répété | le dernier gagne, corps tronqué | 400 |
| `Content-Length: +5` | accepté (`usize::from_str` tolère un `+`) | 400 |
| `Content-Length` **et** `Transfer-Encoding` | longueur retenue, encodage ignoré | 501 |

Le premier n'est pas un problème d'attaquant, c'est un problème de client
honnête : n'importe quelle bibliothèque HTTP qui décide de diffuser un corps
envoie du chunked, et le démon répondait 200 pour une requête dont il avait jeté
le corps.

Les trois autres sont les primitives de *request smuggling*. Le démon ferme
chaque connexion après un échange, donc il ne peut pas être désynchronisé seul —
mais c'est exactement le genre de démon qu'on place derrière un proxy inverse
sur un NAS, et là c'est le désaccord entre les deux analyseurs qui est l'attaque.
La bonne posture pour un serveur qui n'implémente pas une chose est de la
refuser, pas de faire comme si elle n'avait pas été demandée.

Ce qui reste accepté, et doit l'être : les espaces autour de la valeur d'un
`Content-Length`. La RFC 9112 les autorise autour de tout champ, et c'est ce cas
qui a fait tomber le premier jet du *test* plutôt que le code — l'analyseur
nettoie avant de valider, ce qui est le bon ordre. Les huit tests tiennent les
deux sens : réintroduire chaque défaut fait échouer des tests, et sur-corriger
en refusant ce qui est légal aussi.

Non concerné : le jeton porteur était déjà comparé en temps constant.

## Les boucles chaudes des décodeurs — mesurées, puis laissées (fait)

Dernier point de la liste d'optimisations : « UnsafePointer, intrinsics ARM ».
La réponse honnête est que le travail structurel est déjà fait, et qu'il reste
uniquement des gains dont la seule preuve serait un chronomètre.

Ce qui a été vérifié, et comment :

| affirmation | instrument | résultat |
| --- | --- | --- |
| la recopie arrière de LZ ne réalloue jamais | lecture : `reserveCapacity` à la taille finale exacte avant la boucle | aucune croissance possible |
| aucune allocation par pixel | `Array(repeating:)` absent des cinq décodeurs chauds | zéro |
| la trame décodée n'est pas recopiée | **identité de tampon** | même adresse à l'entrée et à la sortie |
| le retournement bas-en-haut coûte une allocation | identité de tampon | une seule, de taille exacte |

L'instrument compte autant que le résultat. Deux adresses sont égales ou elles
ne le sont pas, et la réponse ne change pas parce qu'un autre processus s'est
réveillé ; un chronomètre pris dans ce conteneur partagé ne dit rien. C'est
pourquoi **aucune accélération n'est annoncée nulle part** dans ce travail :
il n'y a pas de machine ici pour en mesurer une.

`Tests/WisqRemoteTests/SpiceDecodeCopyTests.swift` tient ces faits. Ce sont des
garde-fous, pas des observations : `rowsTopDown` réécrit en boucle
inconditionnelle reste *correct*, passe tous les tests d'orientation, et alloue
puis recopie une trame entière à chaque image qu'un serveur top-down envoie —
c'est-à-dire presque toutes. Sabordé ainsi, deux tests tombent.

Ce qui reste — pointeurs non sûrs, intrinsics NEON — demande un iPhone et
`scripts/bench-apple.sh` pour être jugé. À écrire le jour où quelqu'un a
l'appareil et le profil, pas avant : du code plus difficile à lire, adopté sur
la foi d'un chiffre invérifiable, est une dette qu'on ne peut plus rembourser
faute de savoir ce qu'elle a acheté.

## Le site — l'hydratation retirée (fait)

Les pages étaient déjà pré-rendues. Le seul travail qui restait à React dans un
navigateur était d'hydrater quatre comportements : la redirection FR de la page
d'accueil, la mémoire du choix de langue, le sélecteur de thème, l'invite
d'installation. Mesuré : **65 794 octets gzip** par page pour ces quatre-là.
Écrits contre le DOM, ils en coûtent **1 062**.

| | avant | après |
| --- | --- | --- |
| script brut | 206 973 | 2 350 |
| script gzip | 65 794 | 1 062 |
| plafond du test | 240 000 / 80 000 | 8 000 / 3 000 |

C'est la contrainte « le réseau est le budget » appliquée au site lui-même, et
c'était le plus gros poste restant : les images du site pèsent 12 Ko en tout,
donc le WebP de la liste d'optimisations n'aurait rien rapporté — la question
n'était pas les images, c'était le framework.

Ce qu'on perd, et qui est écrit dans le README du site plutôt que laissé à
découvrir : on n'ajoute plus un composant interactif en écrivant du JSX. React
reste le langage d'écriture et le pré-rendu ; seule la livraison change. Ce qui
arrive d'interactif plus tard va dans `src/main.ts` en code DOM, ou derrière un
import dynamique que seules les pages concernées paient.

Deux garde-fous, et le second est le plus important :

- Le budget d'octets descend à 8 000 bruts / 3 000 gzip, et un test échoue si
  React reparaît dans le script livré. Un plafond taillé pour un bundle qui
  hydrate aurait laissé passer la seule régression qui compte — réimporter un
  composant dans `main.ts` — donc le chiffre devait bouger avec le code.
- `tests/behaviour.test.ts` charge la vraie page construite, exécute le vrai
  module livré et appuie sur les boutons. Tous les autres tests vérifient la
  *taille* du script : un script qui ne pèse rien et ne fait rien les passerait
  tous. Les quatre comportements ont ensuite été cassés exprès, de neuf façons,
  et les tests ont attrapé les neuf.

Effet de bord mesuré : chaque page écrite embarquait son document une seconde
fois en JSON, parce que l'hydratation devait lire exactement ce que la
construction avait rendu. Plus personne ne le lit. Le gain est modeste et il
faut le dire — 5 472 octets gzip sur les vingt pages, environ 300 par page :
les deux copies tenaient dans la fenêtre de gzip, comme le commentaire d'origine
l'annonçait.

## Le site — le reste de la liste, et ce qu'on n'en fait pas (fait)

Trois points restaient de la liste d'optimisations. Deux se ferment par une
mesure plutôt que par du code, et c'est le genre de réponse qui vieillit bien :
un lecteur qui trouve « rien à faire, voici le chiffre » n'a pas d'enquête à
refaire.

**Images en WebP — non, et pas pour une question de taille.** Le site construit
ne contient **aucune balise `<img>`**. Pas une image n'est chargée en affichant
une page. Les cinq PNG produits pèsent 12 023 octets réunis, et aucun n'est lu
par la page :

| fichier | octets | qui le lit |
| --- | --- | --- |
| `social-card.png` | 5 811 | `og:image` — les robots d'aperçu de lien |
| `icon-512.png` | 2 622 | le manifeste — l'installateur du système |
| `icon-maskable-512.png` | 2 413 | le manifeste — l'installateur du système |
| `icon-192.png` | 615 | le manifeste — l'installateur du système |
| `apple-touch-icon.png` | 562 | l'écran d'accueil iOS |

Ce sont exactement les consommateurs dont la prise en charge du WebP est la plus
incertaine — un robot d'aperçu Slack ou LinkedIn, un installateur d'OS — et
aucun octet ne serait épargné à un lecteur, puisque aucun de ces fichiers n'est
demandé pendant l'affichage d'une page. L'optimisation ne vise pas seulement
petit : elle vise le mauvais consommateur.

**Découpe du bundle — sans objet.** Il reste 1 062 octets gzip après le retrait
de l'hydratation. Le poste le plus lourd que le site expédie encore est
maintenant la feuille de style, à 3 551 octets gzip, soit plus du triple du
script.

**En-têtes de cache — la moitié n'est pas à nous.** *(Plus vrai depuis le
passage à Heroku : `scripts/serve.ts` est désormais l'hôte, donc les trois
classes d'en-têtes qu'il envoie sont celles que reçoit un lecteur. Le constat
ci-dessous vaut pour l'époque où le site était sur Pages.)* Le site est servi
par GitHub Pages, qui envoie les siens et n'offre aucun moyen de les fixer. La couche de
cache qui décide réellement de ce qu'un lecteur qui revient télécharge est le
service worker, et il fait déjà ce qu'il faut : réseau d'abord pour les
documents, cache d'abord pour les actifs hachés, une version dérivée du contenu
et un repli hors-ligne dans la langue de l'adresse.

Ce qui était à nous et qui était faux : `scripts/serve.ts` annonce servir le
site « comme le ferait un vrai hôte » et envoyait `no-store` sur tout. C'est
fiablement frais et cela ne ressemble à aucun hôte réel — personne ne sert un
actif nommé d'après son contenu avec `no-store`. Trois classes désormais, et
`tests/serve.test.ts` les tient :

| | en-tête | pourquoi |
| --- | --- | --- |
| `chunk-<hash>.{js,css}` | `public, max-age=31536000, immutable` | le nom change avec le contenu : il n'existe pas de version périmée |
| `sw.js` | `no-cache` | un worker servi depuis un cache fige le site sur ce qu'il a installé en dernier |
| tout le reste | `no-cache` | noms non hachés ; on revalide (un 304), on ne s'abstient pas de stocker |

`no-cache` n'est pas `no-store` : le navigateur garde la copie et la revalide
avant de s'en servir.

## Distribution — les architectures publiées (fait)

Quatre assets, pas deux. La release construisait Linux x86_64 et macOS arm64,
et `scripts/install.sh` demandait exactement ces deux-là ; les deux moitiés
étaient donc parfaitement d'accord, ce qui est précisément ce qui rendait le
trou invisible. Un NAS ARM, un Raspberry Pi, un Mac Intel — le `Cargo.toml` de
l'agent nomme le premier comme son public — tombaient sur la construction depuis
les sources, qui exige une toolchain Rust.

| asset | cible | lien | vérification avant publication |
| --- | --- | --- | --- |
| `linux-x86_64` | `x86_64-unknown-linux-musl` | statique (musl) | `--help` sur le runner |
| `linux-aarch64` | `aarch64-unknown-linux-musl` | statique (musl) | `--help` sous `qemu-aarch64-static` |
| `macos-arm64` | `aarch64-apple-darwin` | dynamique (libSystem) | `--help` sur le runner |
| `macos-x86_64` | `x86_64-apple-darwin` | dynamique (libSystem) | `file`, pas `--help` |

La dernière ligne est la seule asymétrie et elle est délibérée : les runners
macOS de GitHub sont arm64 et ne portent pas Rosetta, donc cette tranche est
vérifiée pour *être* du x86_64, pas pour fonctionner. C'est écrit dans le
workflow plutôt que sous-entendu, parce qu'une asymétrie que personne n'a notée
se relit plus tard comme un oubli.

Le lien musl est ce qui rend les deux binaires Linux installables sur une
machine sans rien dessus, Alpine comprise. `strip`, `lto = "fat"`,
`codegen-units = 1` et `panic = "abort"` étaient déjà dans le profil release du
workspace : 1,7 Mo en x86_64, 1,4 Mo en aarch64, TLS compris.

Deux garde-fous ferment la question plutôt que de la corriger une fois :

- `scripts/check-release-matrix.sh` (job **Lint**) compare la liste que le
  workflow produit à celle que l'installateur demande, et échoue dans les deux
  sens. Le sens qui blesse est « l'installateur demande un asset qui n'existe
  pas » — un 404 en pleine installation ; l'autre sens n'est pas anodin non plus,
  un asset que personne ne télécharge ressemble à de la couverture.

  Le même script vérifie une seconde chose, que la comparaison d'ensembles ne
  peut pas voir : **quelle machine reçoit quel asset**. Intervertir `Darwin/arm64`
  et `Darwin/x86_64` laisse les deux ensembles rigoureusement identiques pendant
  que chaque Mac Apple silicon télécharge un binaire Intel. La table est donc
  exercée — un faux `uname`, le vrai installateur, l'URL qu'il imprime — sur les
  cinq paires servies et deux qui doivent tomber sur la construction depuis les
  sources.
- L'entrée `dry_run` du workflow de release construit et vérifie tout sans rien
  publier. Le fichier ne s'exécutait qu'au moment de couper une release,
  c'est-à-dire au pire moment pour y découvrir une faute.

Ce qui reste, et qui n'est pas décidé ici : un fichier de sommes de contrôle
signé à côté des assets. `install_binary` lance le binaire avant de l'installer,
ce qui attrape la mauvaise architecture et la mauvaise libc, mais pas un octet
changé en route ; HTTPS vers GitHub couvre le transport et rien d'autre.

## L'application sur un iPhone : trois voies, et l'icône qui manquait

La release publie une **IPA non signée**, qu'AltStore ou Sideloadly re-signent
avec l'identifiant Apple de la personne : c'est ce qui permet d'installer wisq
sans compte payant, et ça expire au bout de sept jours comme toute signature
de compte personnel. `scripts/install-ios.sh` fait la même chose depuis un Mac
avec le téléphone au bout d'un câble.

`.github/workflows/testflight.yml` ajoute la troisième voie, celle qui demande
un compte développeur payant : archive signée, envoyée à TestFlight, installée
sans câble et valable quatre-vingt-dix jours. La signature passe par une clé
App Store Connect et `-allowProvisioningUpdates`, ce qui évite de transporter
un certificat dans un secret de dépôt — le profil est fabriqué par Xcode au
moment de la construction. Le numéro de build est celui de l'exécution du
workflow, parce que TestFlight refuse un numéro déjà vu.

**L'identifiant d'équipe ne se déduit pas de la clé.** Le premier envoi l'a
établi en seize secondes — « Signing for "Wisq" requires a development team »
— contre le pari inverse. Il n'a pas fallu un quatrième secret pour autant :
l'API le porte sous un autre nom, le `seedId` d'un identifiant d'application,
et `site/scripts/asc.ts` le demande avant de construire. Le même passage crée
l'identifiant d'application s'il manque, ce qui casse un cercle — `xcodebuild
-allowProvisioningUpdates` sait le créer, mais il lui faut déjà l'équipe, qui
se lit sur un identifiant.

Ce que rien ne peut faire : créer la fiche d'application dans App Store
Connect. L'API la lit et ne la crée pas ; l'envoi échouerait en disant que
l'application est introuvable, alors l'étape le dit avant de construire.
C'est le seul geste humain de la chaîne, une fois.

Le jeton de cette API se signe en ES256, vit vingt minutes au plus et porte
l'audience littérale `appstoreconnect-v1` ; sa signature doit être au format
JOSE — soixante-quatre octets — là où OpenSSL rend du DER. Les deux sont des
signatures valides du même message et une seule est acceptée, d'où un 401 qui
n'explique rien. C'est vérifiable sans la clé de personne, et `asc.test.ts` le
vérifie : une paire P-256 fabriquée sur place, la signature relue avec la
partie publique, et le témoin qui doit échouer.

**L'application n'avait pas d'icône**, et c'est ce qui aurait bloqué le premier
envoi : un bundle iOS sans icône est refusé (ITMS-90713), une icône avec canal
alpha aussi (ITMS-90717), et ni l'un ni l'autre n'apparaît à la compilation.
L'icône est donc **dessinée** par `scripts/build-app-icon.sh`, depuis le même
`site/scripts/icons.ts` qui produit celles du site : la même marque, un seul
endroit à tenir. Le catalogue est ignoré par git — un binaire commité est une
chose que personne ne peut relire. Les six chemins qui lancent `xcodegen` le
dessinent d'abord, et un test compte ces chemins : un septième ajouté sans le
générateur échoue, parce que `xcodegen` fige la liste des fichiers du projet
et qu'une application sans icône se construit très bien.

## Le site ne distribue pas wisq — et c'est une décision

Écrit ici parce que jusqu'à maintenant elle ne vivait que dans le commentaire
d'un test, et qu'une décision qu'on ne lit nulle part se refait. Elle vient de
se refaire : j'ai cherché « brew » et « install » dans `site/src`, trouvé zéro,
conclu à un oubli, et rédigé une section d'installation dans les deux langues.
C'est `render.test.tsx` qui m'a arrêté — pas ma relecture.

**Le site explique ce qu'est wisq et comment les morceaux tiennent ensemble ; il
ne remet à personne de quoi l'installer.** Ni `git clone`, ni `brew tap`, ni
script à envoyer dans un shell, ni lien de téléchargement, ni `.ipa`. Tenu par
« no page hands out a way to install the project », sur les pages rendues des
deux langues.

La ligne n'est pas « rien sur l'exécution » : la section d'appairage reste, et
le test porte la raison. Quelqu'un qui décide si wisq est pour lui a besoin de
savoir qu'un agent imprime un lien et que le téléphone le scanne ; rien de tout
ça ne lui remet un binaire.

Une décision voisine et distincte, tenue par un autre test : le site ne se
déclare pas open source et ne renvoie pas vers ses sources. Les deux sont
séparées, et le commentaire qui les mélangeait a été corrigé — il affirmait
qu'un lien de téléchargement survivait « exprès », ce qui n'était plus vrai
depuis que le test voisin interdit `releases/latest` et `.ipa`.

Ce qui existe donc sans être annoncé, délibérément : la formule Homebrew,
`scripts/install.sh`, et les quatre binaires attachés à chaque étiquette. Tous
tenus par des gardes — la formule par l'accord des versions, l'installateur par
la matrice des architectures — pour le jour où la décision changera.

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

## Une machine illisible n'emporte plus la bibliothèque

*Fermé.* `MachineStore` décode maintenant entrée par entrée, rend le compte de
ce qu'il n'a pas su lire, et **réécrit ces entrées telles quelles** pour qu'un
`upsert` fait par une version plus ancienne ne les efface pas. La bannière de
`MachineLibraryModel`, qui existait déjà pour `loadError`, le dit.

L'objection que ce paragraphe portait — « écarter une machine en silence est
aussi une perte, et une perte qu'on ne voit pas » — tombe précisément parce que
ce n'est pas silencieux. Ce qui reste vrai et n'a pas changé : un fichier qui
n'est **pas** un tableau, ou tronqué, lève toujours. Tolérer cela transformerait
un fichier abîmé en « vous n'avez aucune machine », et la sauvegarde suivante le
rendrait vrai.


## L'audit des allocations, clos

*Fermé.* Quatre tranches, prises l'une après l'autre parce que chacune a montré
que la précédente n'était pas allée assez loin.

D'abord le **bureau** : `ServerInit` était borné depuis toujours, à 16384 par
côté, mais le rectangle `desktopSize` qui redimensionne une session vivante ne
l'était par rien — et c'est la porte qu'un serveur peut frapper à répétition.
Puis les **rectangles qui peignent dessus** : douze octets de CopyRect
demandaient dix-sept gigaoctets sur un framebuffer de 64 × 64. Puis les **trois
codecs SPICE**, qui donnaient trois réponses différentes à la même question.
Puis la **clôture**, qui a trouvé un quatrième plafond, celui du masque de
glyphes, plus serré délibérément.

Il y a un seul nombre désormais, `Framebuffer.maximumPixels`, lu par RFB, les
surfaces SPICE, QUIC, LZ et LZ4. `SpiceGlyphMask` garde le sien, plus petit, et
un test épingle la **direction** plutôt que l'égalité.

`Tests/WisqRemoteTests/AllocationCeilingAuditTests.swift` est le tableau
exécutable : un codec ajouté plus tard y figure, ou son absence se voit. Il tient
aussi la distinction sur laquelle tout repose — les chemins sans plafond propre
sont tenus par les octets, et refusent `truncated` plutôt que `badGeometry`.

Vérifiés sains, ne pas y revenir : le zlib de RFB est couvert côté pixels (dans
une classe logée sous un autre nom de fichier), `Framebuffer.write` découpe
correctement, le match inter-images de GLZ est borné contre le tampon réel de la
source, et `ByteStream.pad` est un écrivain dont le compte est le nôtre.

## Ce qui a été clos le 28 août

Cinq tranches, toutes de la même méthode : prendre une affirmation que le dépôt
fait sur lui-même, compter son dénominateur, saborder chaque élément et voir qui
s'en aperçoit.

- **L'instantané de la machine locale** — cinquante et un champs sauvés,
  **trente-cinq** que la suite ne remarquait pas si la restauration les perdait,
  `mepc` et vingt-six registres entiers parmi eux. Un témoin les tient
  maintenant par construction : chaque champ porte une valeur distincte et non
  nulle, l'instantané est restauré puis réécrit. Le même balayage côté Rust en a
  trouvé **un** sur cinquante et un — le cœur Rust avait depuis toujours le test
  que le Swift n'avait pas — et c'était `pending_output`, le seul trou que les
  deux cœurs partageaient.
- **Le test différentiel de reprise** comparait un compte d'instructions qu'un
  invité déraillé produit aussi bien, sur une fenêtre où ce noyau n'écrit rien.
  Il cherche maintenant le moment où l'invité reparle. Mesuré après correction :
  il ne tient toujours pas un registre donné, et ne le peut pas — la vivacité
  d'un registre à l'instant de l'instantané est un accident.
- **« Le site fonctionne hors ligne »** — neuf comportements du service worker,
  **zéro** tenu. Les six tests le lisaient comme du texte ; un worker qui ne
  précache rien passait les quatre-vingt-dix-neuf tests du site. Un fichier
  l'exécute désormais dans un faux `caches` et un faux réseau.
- **La bibliothèque de machines** — un vrai défaut, celui-là : `save()` écrivait
  sans lire, donc effaçait du fichier les entrées qu'une version plus ancienne
  ne sait pas décoder. Quatrième fois que ce dépôt trouve une garde armée
  seulement par ce que ses appelants font se trouver faire.

Où ne plus chercher : le chemin d'instantané des deux cœurs est tenu champ par
champ dans les deux sens ; le service worker est tenu comportement par
comportement ; la forme « garde armée par ses appelants » a été cherchée dans
les autres types de persistance — `CredentialStore` n'a pas de cache à désarmer
et `SuspendedMachine` est sans état — et n'existait qu'à cet endroit.

## L'audit des allocations, rouvert puis reclos

Il avait été fermé sur les *entrées* : un plafond par format, un seul nombre,
un tableau exécutable. Deux tranches du 28 août au soir ont montré qu'il
manquait la moitié symétrique — ce que la **sortie** d'un décompresseur peut
atteindre — et que deux chemins notés « vérifiés sains » ne l'étaient pas.

`InflateStream` accumulait sans borne : 101 929 octets compressés en produisent
104 857 600, et un rectangle d'un pixel autorisait un gigaoctet. `SpiceLZ`
laissait une seule correspondance dépasser son image : 400 Kio de charge utile,
645 Mio de pic, pour une image déclarant 64 octets.

Les huit chemins de décompression sont maintenant passés en revue, et la règle
qui les sépare est écrite dans le journal : un tampon pré-dimensionné avec une
garde par élément est sain ; un ajout dans une collection qui grandit, borne
vérifiée hors de la boucle, ne l'est pas. Les deux défauts sont tenus par des
témoins qui mesurent la mémoire ; les six autres chemins sont vérifiés par
lecture, ce qui est plus faible et se dit.

**Ce qui reste ici** : six flux hostiles à fabriquer, un par format d'en-tête,
pour tenir les six sains par des témoins plutôt que par ma lecture.

## Les entrées illisibles : le choix est proposé, jamais pris (fait)

Les entrées qu'une version ne sait pas lire sont **immortelles** par défaut.
C'est délibéré : les effacer serait la perte que personne ne peut annuler, et
une version plus ancienne qui ouvre une bibliothèque récente ne doit pas
emporter ce qu'elle ne comprend pas. `save`, `upsert` et `delete` les portent
donc toutes intactes.

Mais un fichier qui a pris une entrée abîmée — une écriture à moitié faite, une
édition à la main — affichait « une machine sur douze n'a pas pu être lue » à
chaque lancement, pour toujours, sans issue depuis l'application. Et
l'application ne peut pas distinguer les deux cas : une entrée venue d'un wisq
plus récent et une entrée corrompue se ressemblent exactement. Elle ne tranche
donc pas ; elle **propose le choix en disant la vérité**. La bannière nomme la
machine quand l'entrée porte encore un nom (« Du futur » se reconnaît, « une
entrée » non), un bouton en dessous offre d'écarter, et la confirmation dit ce
qui compte : cette entrée vient peut-être d'une version plus récente, mettre à
jour la ferait revenir ; ce qui est écarté est effacé du fichier et ne revient
pas.

La règle vit dans `MachineStore.discardUnreadable`, la seule route par laquelle
une entrée illisible quitte le fichier : elle lit avant d'écrire comme toutes
les écritures du magasin (ce qu'elle écarte est ce que *cette* lecture n'a pas
su lire, pas ce qu'une autre version aurait gardé), elle rend le compte, et
elle n'écrit rien quand il n'y a rien à écarter. Sabordée ici, contre la suite
entière ; la vue est mince et jugée par le simulateur.

## Ce qui reste, au 28 août

- **Arrêter une VM distante depuis le téléphone** — *fait.* La conduite est
  `VMPower.shutDown` dans WisqRemote, éprouvée bout-à-bout contre le vrai démon :
  arrêt poli sondé jusqu'à `stopped` dans une fenêtre de patience, et une
  patience épuisée qui **rend `.stillRunning` au lieu de tourner en rond** —
  c'est la réponse que l'interface présente, avec le cordon en second geste et
  le prix nommé (ce qui n'était pas enregistré est perdu). Un invité sans
  gestionnaire ACPI peut ignorer la demande pour toujours ; attendre plus
  longtemps ne le ferait pas répondre, cela cacherait la question. Le bouton vit
  dans le glissement de `MachineListView`, pour les seules machines liées à un
  agent ; la vue reste mince et n'est pas jugée d'ici, la conduite l'est. Au
  passage, la construction du client depuis une liaison — jeton depuis le
  trousseau, épinglage exactement quand l'appairage a noté une empreinte — est
  devenue `AgentClient(binding:credentials:)`, une décision à un seul endroit
  que le résolveur de console partage.
- **RDP (lot 3)** — le seul protocole de console que wisq ne parle pas. Le client
  porte une ébauche délibérée qui rend `.unsupportedProtocol` au lieu de faire
  semblant. Demande une machine Apple pour être jugé, pas seulement testé.
  C'est aussi le seul que `RemoteProtocol.isImplemented` marque « bientôt » :
  cette étiquette disait encore `self == .vnc` longtemps après que la fabrique
  eut cessé de refuser SPICE, et `ImplementedProtocolsTests` fait maintenant
  marcher `allCases` à travers `SessionFactory` pour que les deux ne puissent
  plus diverger.
- **Lot 6 : iPad et Siri** — décisions d'interface qu'on ne prend pas au jugé ;
  les arbitrages déjà tranchés sont écrits plus haut.
- **D'autres backends d'agent** — le trait `Backend` a quatre méthodes et
  `VirshBackend` montre la forme. **Proxmox** est le candidat net : son API REST
  est documentée et se teste ici contre un faux serveur, comme le reste du
  démon. **QEMU nu** ne l'est pas — QEMU n'a pas de démon, donc énumérer les
  machines demande d'inventer d'où vient la liste (des sockets QMP dans un
  répertoire, un fichier de définitions), et ce n'est pas une décision à prendre
  au jugé. Dans les deux cas, écrit ici, ce serait du code jamais confronté à un
  vrai hôte : testable, pas jugeable.

Et une chose qui n'est plus sur la liste : **le disque virtuel pour la machine
locale**. C'était le plan ; c'était le mauvais. Les noyaux rv32 nommu de cette
famille ont virtio-mmio mais aucun pilote bloc, et l'utilisateur apporte son
propre noyau. Sauver la machine — RAM, registres, timer, octets en attente sur
l'UART — contourne l'invité entièrement et marche avec n'importe quel noyau.

## La mémoire de la machine locale, réglable (fait)

Demandé par Maxime : « ajuster de la ram et de l'espace de stockage partout ».

Ce qui est fait : les deux cœurs prennent une taille par machine, et le noyau
l'**apprend** — la cellule mémoire du device tree est corrigée à l'offset 316,
en gardant la réserve de seize kibioctets du haut que le blob de référence
garde. Prouvé par un vrai noyau qui annonce `Memory: 126348K/131056K available`
à 128 Mio contre `61372K/65520K` à 64, et par un test différentiel qui exige
que les deux cœurs redimensionnent à l'octet près. Le plafond d'image noyau
suit la machine plutôt que le type, en un seul endroit côté application
(`LocalMachineMemory`).

Et le réglage lui-même, `KernelMemory` :

- **Par noyau**, classé par nom de fichier — l'inverse de `SuspendedMachine`,
  qui prend l'empreinte. Une taille n'est pas un état : au pire un fichier
  remplacé hérite d'une préférence qu'on change d'un geste, et la lire ne
  demande aucun octet, ce dont le chemin de démarrage a besoin puisqu'il doit
  connaître la taille **avant** de lire l'image.
- **Deux seuils, pas un.** À l'import, un fichier est jugé sur la plus grande
  machine que l'appareil autorise, parce qu'aucune taille n'est encore choisie ;
  au démarrage, sur la machine de ce noyau-là.
- **Deux bornes, pas une** (règle de Maxime, 3 septembre) : la machine laisse
  **deux gibioctets à l'appareil** — « je veux pouvoir la gérer en étant deux
  giga plus petit que ce que le téléphone a » — *et* reste sous ce que le
  système dit libre à cet instant. Les deux disent des choses différentes : de
  combien d'un appareil wisq accepte d'être, et ce qui est libre maintenant. La
  plus petite décide. Bord net assumé : sur un appareil de deux gibioctets ou
  moins la règle vaut zéro, et c'est le plancher — la machine de référence —
  qui répond.
- **Le plafond vient du système, plus d'une fraction inventée.**
  `os_proc_available_memory()` rend ce que l'application peut encore allouer
  avant qu'iOS ne la tue ; le plafond est ce nombre moins 256 Mio pour
  l'application elle-même, borné par l'architecture, jamais sous la référence.
  La fraction (un huitième du physique) ne sert plus que de repli là où le
  système ne publie rien — macOS, Linux. Relu à chaque demande : la réponse sur
  un téléphone chargé n'est pas celle d'un téléphone qui vient de démarrer.
- **Et un refus au démarrage quand la place a baissé depuis le réglage**, avec
  les deux chiffres et quoi en faire. Démarrer quand même serait se faire tuer
  par iOS en plein démarrage.
- **Changer la taille oublie les machines sauvegardées de ce noyau**, et
  l'application dit ce que ça a coûté — ou ne dit rien quand ça n'a rien coûté.
  Un instantané pris à une autre taille ne peut de toute façon pas être
  restauré : les deux cœurs refusent l'écart.

- **Un curseur, en gigaoctets** (demandé par Maxime). Il glisse sur les indices
  des paliers offerts, donc de puissance de deux en puissance de deux. Les
  tailles s'affichent en Gio dès qu'elles en sont : « 1024 Mo » est exactement
  ce qui faisait passer un réglage atteignant le gibioctet pour un réglage
  arrêté aux mégaoctets.
- **La limite est celle de l'architecture, pas une politique.** La RAM de
  l'invité commence à `0x8000_0000` et le hart adresse en 32 bits : deux
  gibioctets tombent sur le dernier octet possible. Au-delà, la machine se
  construisait, annonçait dans son DTB une mémoire hors de son espace
  d'adressage et **ne démarrait pas, en silence** — les deux cœurs le refusent
  maintenant. 2 Gio démarre jusqu'à l'invite, en 120 millions d'instructions
  au lieu de 46.

Ce qui reste sur ce sujet : rien de décidé. Un réglage de la **vitesse** (le
budget d'instructions par tranche) serait le voisin naturel, mais personne ne
l'a demandé et il n'a pas d'utilisateur connu.

## Toutes les architectures Linux, et le cœur choisi tout seul (demandé par Maxime)

Maxime, le 4 septembre : « sur wisq il me faut toutes les architectures Linux
qui peuvent exister et la bonne par rapport à l'image sera automatiquement
sélectionnée ».

### Ce qui est fait, et ce que ça sépare

**Reconnaître n'est pas exécuter**, et les deux sont désormais deux questions
distinctes dans le code plutôt qu'un booléen qui les mélange.

`GuestArchitecture` nomme les **vingt et une familles** pour lesquelles le
noyau Linux a un répertoire dans `arch/`, plus celles qu'il a portées assez
longtemps pour que des images traînent encore : x86, ARM, RISC-V, MIPS,
PowerPC, IBM Z, SPARC, LoongArch, Alpha, ARC, C-SKY, Hexagon, Itanium, 68000,
MicroBlaze, Nios II, OpenRISC, PA-RISC, SuperH, Xtensa. Chacune porte son nom,
sa largeur quand le fichier la dit, et son boutisme.

**La famille et la largeur sont séparées, et la largeur est optionnelle.** Un
ELF porte sa classe au cinquième octet, donc on sait. L'image brute que Linux
produit pour RISC-V n'a **aucun** champ qui dise 32 ou 64 bits : un noyau rv32
et un rv64 y sont indiscernables. Alors `bits` vaut `nil`, ce qui veut dire
« le fichier ne le dit pas » et non « 32 par défaut ». Deviner ici serait la
même faute que d'invoquer la mémoire pour expliquer un refus.

### Les formats reconnus, et pourquoi ceux-là

| format | ce qui le nomme | ce qu'on en tire |
|---|---|---|
| ELF | `e_machine`, la classe, le boutisme | l'architecture exacte |
| `uImage` (U-Boot) | un octet à l'offset 29 | **le seul format qui nomme son architecture** |
| `bzImage` | `HdrS` à 0x202, `xloadflags` | x86, 32 ou 64 bits |
| `Image` ARM64 | `ARM\x64` au 56ᵉ octet | ARM64 |
| `Image` RISC-V | `RISCV` à 0x30, `RSC\x05` à 0x38 | RISC-V, largeur inconnue |
| `zImage` ARM | 0x016F2818 à 0x24 | ARM 32 bits |
| gzip, xz, zstd, bzip2, lz4, lzop | leur magique | l'enveloppe, et l'aveu que l'architecture est dedans |
| ISO 9660 | `CD001` au secteur 16 | une image de disque, pas un noyau |

Un `vmlinuz` compressé est le cas le plus courant du monde réel — celui de
Debian pour ARM64 est un `Image` gzippé —, et se taire laisserait croire que
le fichier n'est rien. Le message nomme l'enveloppe **et** dit ce qu'il ne peut
pas voir.

### La sélection automatique

`GuestArchitecture.core` répond quel cœur exécute une architecture, et
`KernelImageKind.core` le fait remonter depuis le fichier. Personne n'a à
choisir : l'image le dit.

Une largeur inconnue ne bloque pas. Quand le fichier ne dit pas s'il est en 32
ou en 64 bits et qu'un seul cœur existe pour la famille, c'est celui-là — la
même règle que `unknown`, qui est une permission et non un doute.

### Ce que wisq exécute, et ce qu'il ne fait qu'exécuter dans ses tests

Deux cœurs existent : **RISC-V 32 bits** (rv32ima, écrit deux fois, en Swift et
en Rust) et **x86-64** (prouvé instruction par instruction contre le vrai
processeur, et qui démarre un noyau d'Alpine jusqu'à son espace utilisateur).

**Les deux sont branchés dans l'application.** Ça n'a pas toujours été le cas :
il y a eu une tranche où le cœur x86-64 démarrait un vrai noyau d'Alpine
pendant que `LocalVMModel` ne savait construire que la machine RISC-V. Un
booléen — `Core.availableInTheApp` — portait la distinction, pour qu'un refus
ne dise jamais « pas de cœur » d'un cœur qui existe et enverrait ainsi
quelqu'un attendre une chose déjà écrite.

`GuestMachineFactory` construit maintenant l'une ou l'autre selon
`KernelImageKind.core`, donc les deux questions ont la même réponse et le
booléen a disparu avec sa branche de refus — une phrase qu'aucun test ne
pouvait plus atteindre est pire qu'une phrase absente. Il reste un seul refus,
pour une architecture sans cœur, et il nomme quand même le fichier :

> `Image` est un noyau Linux pour ARM64, au format Image ARM64. C'est le bon
> genre de fichier — un noyau, pas une image de disque — mais wisq n'a pas de
> cœur pour cette architecture.

`X86Machine` **est écrite** : même forme que `LinuxMachine` — charger, tourner,
taper, arrêter —, avec la file d'entrée série qu'il a fallu ajouter au cœur
pour qu'un invité sache qu'on vient de taper. Sept tests, cinq sabotages.

**L'instantané est fait**, et mesuré avant d'être conçu. Après un démarrage
complet d'Alpine, sur 65 536 pages de quatre kibioctets, **14 471 ne sont pas
entièrement nulles** — vingt-deux pour cent, soit 56 Mio de contenu réel et
26 Mio gzippés. Or le format d'instantané de ce dépôt code déjà les suites de
zéros par leur longueur : il n'y avait rien à inventer, seulement à s'en
servir. Onze tests, dont un qui pose une valeur distinctive dans **chaque**
champ et la redemande — comparer deux instantanés ne prouverait rien, un champ
oublié étant absent des deux.

**Le branchement est fait**, en trois pièces : `GuestMachine`, le protocole
commun aux deux machines ; `GuestMachineFactory`, qui choisit selon
`KernelImageKind.core` ; et `LocalVMModel`, qui identifie le fichier **avant**
de fabriquer quoi que ce soit — l'ordre a dû s'inverser, puisqu'on ne peut plus
savoir quoi construire sans avoir lu. Dix tests de plus, treize sabotages.

Deux choses que le protocole a fait apparaître, et qui n'étaient nulle part
avant. Un disque en mémoire donné à la machine RISC-V est **refusé et nommé**
plutôt qu'ignoré : son chargeur place un noyau et un arbre de périphériques, et
l'accepter en silence donnerait un démarrage qui va jusqu'au bout puis panique
faute de racine — un symptôme à quatre milliards d'instructions de sa cause. Et
une faute du cœur PC traverse le protocole **avec son nom** : « arrêtée » à sa
place enverrait chercher partout, alors que l'instruction qui a manqué est
justement ce qui dit quelle brique poser ensuite.

Le plancher de mémoire aussi est arrivé là : une machine PC a besoin de cent
vingt-huit mébioctets — son noyau décompressé en fait trente-cinq à lui seul —
et le plafond du téléphone, lui, ne change pas. Quand les deux ne se
rencontrent pas, l'application le dit au lieu de démarrer une machine trop
petite qui échouerait sans expliquer pourquoi.

**Deux défauts que le sabotage a trouvés en pendant, pas en échouant.** Le
budget ne comptait que les instructions retirées — or un `HLT` n'en retire
aucune, donc la boucle tournait sans fin autour d'un invité qui dort, à plein
régime, sur un téléphone. Et la sortie reposait sur `halted` au lieu du
progrès. Les deux corrigés ; la garde porte maintenant sur « cette tranche
n'a rien exécuté », ce qui couvre les deux cas et tous ceux qu'on n'a pas
imaginés.

### Ce qui n'est pas promis

Reconnaître vingt et une familles n'en fait pas tourner vingt et une. Écrire un
cœur ARM64 ou PowerPC est un lot par architecture, pas une case à cocher. Ce
que cette tranche change, c'est qu'un fichier refusé est désormais **nommé** :
« un noyau Linux pour ARM64, au format Image ARM64 » au lieu du silence. C'est
la différence entre un mur et une carte.

---

## Lot 7 — la plate-forme locale devient x86-64 (décidé par Maxime)

Maxime, le 3 septembre : « faut changer la plate-forme car risc-v c'est pas la
bonne solution pour des distributions complètes ». Choix posé après avoir vu
les trois options et leur coût : **x86-64 + MMU + disque**.

### Ce que la décision corrige d'abord : le diagnostic

RISC-V n'était pas le blocage, et il faut l'écrire pour que personne ne
re-décide sur la mauvaise raison. Debian, Ubuntu et Fedora ont des ports
**riscv64 officiels**. Ce qui empêche une distribution complète de tourner
aujourd'hui, ce sont trois choses précises :

1. la machine est en **32 bits** ;
2. elle est **nommu** — sans MMU, donc sans l'espace d'adressage virtuel dont
   toute distribution dépend ;
3. elle n'a **aucun disque**.

x86-64 apporte les trois d'un coup **et** fait tourner ce que Maxime veut
précisément faire tourner, qui est distribué en x86-64. C'est le raisonnement
retenu.

### Ce qu'aucune décision ne lève

**iOS interdit le JIT** aux applications de l'App Store. Tout sera interprété.
Mesuré sur le cœur qui tourne aujourd'hui : **122,5 M d'instructions par
seconde** (200 M en 1,63 s, Rust en release, sur un vCPU de datacentre) pour du
rv32, dont le décodage est simple. x86-64 coûte nettement plus par instruction
— longueur variable, préfixes, ModRM/SIB, sémantique des drapeaux. Un démarrage
de bureau complet se compte en dizaines de milliards d'instructions.

Cette phrase est une **extrapolation**, pas une mesure, et elle le restera
jusqu'à ce que la tranche 3 donne un vrai chiffre. Elle est écrite ici pour que
la première mesure réelle puisse la contredire au lieu de la confirmer par
habitude.

### Les tranches, dans l'ordre, et ce que chacune prouve

1. **Reconnaître un noyau x86-64** — *fait*. `LinuxBootProtocol` lit l'en-tête
   de démarrage Linux et `KernelImageKind` répond `pcLinuxKernel`. Les valeurs
   sont **mesurées** sur `vmlinuz-lts` d'Alpine 3.20 pour x86_64
   (10 961 920 octets) : protocole 2.15, 39 secteurs de setup (20 480 octets),
   `syssize` 683 840 paragraphes (10 941 440 octets) — les deux moitiés
   tombent pile sur le fichier —, `xloadflags` 0x3F donc entrée 64 bits,
   `pref_address` 0x0100_0000, `init_size` 36 425 728, ligne de commande
   2047 caractères. Ce que la tranche a appris au passage : un bzImage
   commence par « MZ » (talon EFI) et non par ELF, donc rien ne le nommait ;
   un ISO hybride porte le **même** 0xAA55 à 0x1FE qu'un noyau, donc l'ordre
   des deux reconnaissances est ce qui les sépare ; et les champs sont apparus
   au fil des versions du protocole, donc chacun est gardé par la version qui
   l'a introduit plutôt que lu au hasard.
2. **Le décodeur, sans exécution** — *fait*. `X86Decoder` lit la forme
   complète : préfixes hérités, REX ou VEX ou EVEX, table d'opcode, ModRM,
   SIB, déplacement, immédiat, et surtout **où finit l'instruction**. Prouvé
   par différentiel contre `objdump` 2.42 sur **647 965 instructions** tirées
   de `/bin/ls`, `/bin/bash` et la libc du système, plus cinquante-trois
   formes assemblées exprès parce qu'aucun compilateur ne les émet (`moffs`,
   `ENTER`, `RET imm16`, les six opérations sans immédiat de `F6`/`F7`) :
   **647 965 accords, zéro désaccord**. Le dépôt porte un extrait distillé de
   9 222 formes (`Tests/Fixtures/x86-corpus.tsv`, refabriqué par
   `scripts/build-x86-corpus.py`) qui attrape les huit mêmes sabotages en
   0,09 s. Le corpus mesuré se répartit en 82,5 % d'opcodes d'un octet,
   15,8 % de table `0F`, 1,6 % de VEX ou d'EVEX — c'est pourquoi les préfixes
   vectoriels sont décodés eux aussi, en réutilisant les mêmes tables plutôt
   qu'en les doublant.
3. **Le cœur, en mode long, sans MMU.** Coupé en deux, parce que la moitié qui
   calcule se prouve autrement que la moitié qui démarre.
   - **3a. Ce qu'une instruction fait aux registres et aux drapeaux** —
     *fait*. `X86Core` exécute l'arithmétique, la logique, les décalages et
     rotations, les multiplications et divisions, les seize conditions, les
     bits, les mouvements et extensions — aux quatre largeurs, octets hauts
     compris. La référence est le **vrai processeur** : ce conteneur est un
     x86-64, donc `scripts/build-x86-oracle.py` fait exécuter chaque
     instruction par la machine avec des états choisis et fige sa réponse.
     **8 748 accords sur 8 748.** Là où le manuel dit « indéfini », le fichier
     ne fige rien : chaque instruction porte le masque des drapeaux que
     l'architecture lui garantit, sans quoi le fichier serait le portrait
     d'**une** machine et un cœur qui s'y conformerait serait faux ailleurs.
   - **3b. La mémoire, les branchements, la pile et le port série** — *fait*,
     et avec **le premier vrai chiffre de vitesse**. `X86Memory` porte la
     mémoire de l'invité, `X86Core.run` enchaîne les instructions jusqu'à un
     `HLT`, et l'oracle matériel exécute désormais des **programmes entiers** à
     des adresses fixes, en comparant aussi une fenêtre de mémoire : boucles,
     sauts courts et longs, appel et retour, cadres de pile, accès aux quatre
     largeurs, adressage à échelle, saut indirect. **9 036 accords sur 9 036.**

     **Le chiffre : 16,5 MIPS**, mesuré par `swift run -c release wisq-bench`
     sur une boucle qui additionne, compare, saute, lit et écrit la mémoire —
     pas un compteur à vide. À ce débit, deux milliards d'instructions prennent
     **deux minutes**, cinquante milliards en prennent **cinquante**. Ces deux
     derniers nombres sont des **divisions, pas des mesures** ; ce qui est
     mesuré, c'est le débit.

     La première mesure donnait **8,4 MIPS**. Deux choses la plombaient, et
     toutes deux étaient sur le chemin le plus chaud du programme : le décodeur
     **allouait deux tableaux par instruction** (les préfixes, le préfixe
     vectoriel), et la boucle **recopiait quinze octets** dans un tampon avant
     chaque décodage, uniquement pour avoir un `Array`. Un masque de bits et un
     tuple pour le premier, un pointeur pour le second : ×1,96 sans toucher à
     une seule règle du jeu d'instructions, et les 9 036 accords de l'oracle
     tiennent toujours.

     Ce que ça corrige : la feuille de route disait « des heures », et c'était
     une extrapolation. Un noyau seul se compte en **minutes**. Ce que ça ne
     dit pas : ce cœur-ci est en Swift, alors que les 122,5 MIPS du rv32 sont
     ceux du cœur Rust — l'écart mélange deux langages et deux architectures.
     Et à 16,5 MIPS il reste environ 180 cycles par instruction sur cette
     machine, là où un bon interprète en demande cinquante : il y a encore de
     la marge. Une piste a déjà été essayée et **jetée** — mettre les seize
     registres en ligne dans la structure plutôt que dans un tableau donne
     15,4 MIPS, donc moins ; c'est écrit à côté de la déclaration pour que
     personne ne la retente.
   - **3c. Démarrer un vrai `bzImage`.** Le **chargeur est fait** :
     `X86BootLoader` place le noyau en mode protégé à son adresse préférée,
     réserve `init_size` octets — bien plus que ce que le fichier pèse, parce
     que le noyau se décompresse chez lui —, écrit la page zéro avec l'en-tête
     de setup **à ses propres décalages**, y pose ce que seul un chargeur sait
     (`type_of_loader` à 0xFF, `LOADED_HIGH`, l'absence d'initrd, le pointeur
     de ligne de commande), coupe la ligne de commande à ce que le noyau
     accepte, et rend le point d'entrée 64 bits — à 0x200 du début, pas au
     début. Vérifié sur le vrai noyau d'Alpine, et cinq sabotages.

     **Et la machine sait maintenant y répondre.** `CPUID`, les registres de
     contrôle (`0F 20`/`0F 22`), les MSR (`RDMSR`/`RDTSC`/`WRMSR`) et la
     **MMU** sont faits : parcours à quatre niveaux, grandes pages de 2 Mio et
     de 1 Gio, faute de page nommée, et un cache de traduction vidé par
     l'écriture de `CR3`. Le mode long s'active comme sur un vrai processeur —
     `EFER.LMA` est posé par la machine quand la pagination s'allume alors que
     `LME` est demandé, pas par celui qui écrit `EFER`.

     Ce que `CPUID` annonce est une **décision**, pas une mesure : l'oracle
     matériel dirait ce que la machine hôte répond, or c'est exactement ce
     qu'il ne faut pas — un invité qui se croirait sur le processeur de l'hôte
     utiliserait des instructions que ce cœur n'exécute pas. Chaque bit annoncé
     est donc une promesse tenue ailleurs, et les tests la relisent dans ce
     sens. Le x87 n'est pas annoncé, parce que rien ne l'exécute.

     Coût mesuré de la MMU : **16,4 → 15,4 MIPS**, soit 6 %, pagination
     éteinte comprise. La première version en coûtait 13 %, parce qu'elle
     relisait `CR0` dans le tableau des registres de contrôle à chaque accès
     mémoire ; un booléen gardé à jour à l'écriture de `CR0` a rendu ce
     chemin-là gratuit.

   - **3d. La livraison d'exception** — *fait*, et c'est elle qui a débloqué
     le démarrage. Le décompresseur 64 bits de Linux ne cartographie **pas**
     la mémoire d'avance : il pose une IDT dont **un seul** vecteur est rempli
     — le quatorze, la faute de page — et étend l'identité à la demande depuis
     ce gestionnaire, page par page, à mesure qu'il écrit le noyau
     décompressé. Un cœur sans livraison d'exception s'arrête donc sur la
     première page manquante, et l'arrêt ressemble à une divergence alors que
     c'est le fonctionnement prévu.

     Ce qui est écrit : la recherche de porte dans l'IDT (limite comprise, bit
     de présence compris), le cadre du mode long — SS, RSP, RFLAGS, CS,
     l'adresse de reprise, et le code d'erreur pour les dix vecteurs qui en
     portent un —, l'alignement de la pile sur seize octets, `CR2` avec
     l'adresse **entière**, le masquage des interruptions selon le genre de
     porte, et `IRETQ` qui défait le tout. `LIDT` **recopie** désormais le
     pseudo-descripteur au lieu de retenir l'adresse de son opérande, parce
     que c'est ce qu'un processeur fait et que la livraison s'en sert.

     Une forme que ce cœur ne sait pas exécuter n'a **pas** de vecteur : la
     livrer comme #UD ferait afficher au noyau « invalid opcode » à l'endroit
     d'un trou de l'émulateur, ce qui coûte plus cher que l'arrêt.

     Treize tests écrits à la main, chacun vérifié par sabotage — l'oracle
     matériel ne peut pas produire de faute sans tuer son harnais, donc c'est
     ici le seul endroit du cœur qui ne soit pas prouvé contre la machine.

   - **3e. Les briques que le vrai noyau a demandées** — *fait*. Aucune n'a
     été choisie sur une liste : chacune est l'instruction sur laquelle la
     tentative de démarrage s'est arrêtée. Dans l'ordre où le noyau les a
     réclamées :

     **L'octet haut lu par une instruction plus large que lui.** Sans REX,
     l'index 101 d'un opérande d'un octet désigne CH, pas BPL. Le cœur le
     savait — mais il décidait avec la largeur du **destinataire**, prise du
     champ avec lequel les champs de ModRM avaient été décodés. Or `MOVZX` et
     `MOVSX` ont deux largeurs : `0F B6 FD`, c'est-à-dire `movzbl %ch,%edi`,
     lisait donc BPL. Le décompresseur de Linux s'en sert pour construire le
     motif de seize bits avec lequel il remplit les suites d'octets
     identiques : **un octet sur deux du noyau décompressé était faux**, et le
     premier à s'en apercevoir a été `parse_elf`, qui a lu `0x0007000700070040`
     là où le fichier dit `0x40`.

     L'oracle matériel ne l'attrapait pas, parce que toutes ses formes à octet
     haut avaient leurs deux opérandes de la même largeur. Il porte maintenant
     les vingt-quatre formes de `MOVZX`/`MOVSX` à octet haut, et **222 cas**
     tombent quand on remet le défaut. Pas de destination de soixante-quatre
     bits : elle demanderait REX.W, et REX est justement ce qui change AH en
     SPL — l'assembleur refuse, ce qui est la meilleure preuve que les deux
     noms ne peuvent pas coexister.

     **`ENDBR64`**, la balise de CET, que le noyau pose à l'entrée de chaque
     fonction. Un NOP sur un processeur qui n'annonce pas la technologie ; la
     refuser arrêtait le noyau à sa **toute première** instruction.

     **Les bases de FS et GS.** En mode long, seuls ces deux segments en ont
     encore une, et elle vient d'un MSR plutôt que d'un descripteur. C'est le
     mécanisme des variables par processeur : un cœur qui ignore le préfixe
     `%gs:` lit l'adresse **sans** la base, c'est-à-dire au début de la
     mémoire, sans rien signaler. Avec `SWAPGS`, qui l'échange avec celle que
     le noyau garde de côté.

     **`CMPXCHG` et `XADD`**, dont toutes les serrures d'un noyau sont faites.
     `LOCK` n'ajoute rien ici : un seul cœur, rien à exclure. Les deux sont
     tenues par l'oracle matériel, aux quatre largeurs.

     **Les registres de débogage, `INVLPG`, `PREFETCH` et les NOP réservés du
     groupe 16.** Notés, vidés, ignorés — dans cet ordre. `INVLPG` vide tout le
     cache de traduction plutôt qu'une page : plus lent, jamais faux.

     Douze tests écrits à la main dans `X86KernelBricksTests`, plus ce que
     l'oracle a gagné. **9 036 → 9 804 cas** contre le vrai processeur.

   - **3f. Le contrôleur d'interruptions et l'horloge** — *fait*. Le noyau
     s'arrêtait sur `Failed to register legacy timer interrupt`, après avoir
     écrit `Using NULL legacy PIC` : sa sonde du 8259 avait échoué, donc il
     n'avait personne à qui demander l'interruption zéro. La sonde est **deux
     lignes** — écrire un masque dans le port 0x21 et le relire.

     `X86LegacyDevices` porte le couple de 8259 (séquence d'initialisation,
     masque, demande, service, fin d'interruption) et le 8253 (canal zéro qui
     bat, canal deux que Linux utilise pour étalonner son compteur de cycles,
     commande de verrouillage, port 0x61). La livraison réutilise le chemin
     des exceptions ; seuls le vecteur et le code d'erreur changent.

     **Le temps de l'invité vient du compteur d'instructions**, à raison de
     douze instructions par battement. C'est une **décision**, pas une mesure :
     brancher une vraie horloge rendrait les exécutions irreproductibles, et un
     instantané ne rendrait plus la machine telle quelle. `HLT` attend
     désormais au lieu de s'arrêter — avec un second compteur pour le temps qui
     passe, sans quoi l'horloge s'arrêterait avec le processeur et le réveil
     n'arriverait jamais.

     **Et le défaut que ça a révélé** : `BT`/`BTS`/`BTR`/`BTC` avec une
     destination en mémoire. Le numéro de bit n'y est **pas** réduit au modulo
     — c'est la forme « chaîne de bits » du manuel : le numéro est signé, et le
     processeur va chercher le mot qui contient ce bit-là. Le replier dans le
     premier mot, comme pour un registre, écrase tout un tableau de bits sur
     ses soixante-quatre premiers.

     Linux tient ses vecteurs réservés dans un tableau de 256 bits. Ceux de
     0xEC à 0xFF atterrissaient aux numéros 44 et 48 à 63 — **pile sur les
     vecteurs des interruptions ISA**. Le noyau les croyait pris, ne posait
     plus de porte pour l'horloge, et attendait un battement qui ne pouvait
     plus arriver. Les quinze vecteurs manquants dans son IDT étaient
     exactement ses vecteurs système modulo 64, ce qui a nommé le défaut sans
     avoir à le chercher. L'oracle matériel porte maintenant trois programmes
     de chaîne de bits, numéros négatifs compris.

     Avec ça : `BSWAP`, `FXSAVE`/`FXRSTOR`, `LDMXCSR`/`STMXCSR`, `FWAIT`,
     `INT3` et `INT n` — toutes nommées par un arrêt, comme les précédentes.
     `FXSAVE` écrit les mots de contrôle que ce cœur tient vraiment et met le
     reste à zéro : il n'a ni registres x87 ni XMM, et rien ici ne calcule en
     virgule flottante.

   - **3g. Le disque en mémoire, et l'espace utilisateur** — *fait, et c'est
     là que ça devient une machine*. Le noyau d'Alpine n'a **aucun** pilote de
     disque compilé dedans : ni virtio, ni rien — ce sont des modules, et ils
     vivent dans l'initramfs. C'est pour ça que la panique `VFS: Unable to
     mount root fs` n'appelait pas virtio-blk mais un **initrd**.

     `X86BootLoader` le pose en haut de la mémoire, aligné sur une page, et
     l'annonce dans la page zéro (`ramdisk_image`, `ramdisk_size`). Sans cette
     annonce, le décompresseur écrirait dessus en croyant la place libre.

     Avec l'`initramfs-lts` d'Alpine (26 Mio), le noyau le déballe dans un
     tmpfs et **exécute `/init` en anneau trois**. Premier programme
     utilisateur jamais lancé par wisq.

     **Et le bit qui manquait pour qu'il vive.** La première page manquante de
     `/init` a été prise pour un défaut du noyau lui-même : `Oops: 0010`, un
     vidage de registres, `Attempted to kill init!`. Le code d'erreur d'une
     faute de page porte un bit qui dit **d'où vient l'accès**, et il n'était
     pas posé. Linux s'en sert pour trancher entre « une page manque à un
     programme, je la lui pose » et « le noyau est parti dans le décor ». Le
     programme n'avait rien fait de mal ; on avait juste oublié de dire qu'il
     était le programme. Le niveau vient des deux bits du bas de CS.

     Avec le bit : **2,7 milliards d'instructions**, plus un seul oops, le
     journal passe à 12 685 octets — et l'arrêt suivant est nommé. Une faute
     de page sur la **pile utilisateur**, depuis le code d'entrée du noyau :
     un changement d'anneau doit charger RSP depuis le TSS, et ce cœur poussait
     encore le cadre sur la pile qu'il trouvait.

   - **Le TSS, et la pile que le processeur va y chercher.** `LTR` et `STR`
     avec le registre de tâche ; puis, à l'entrée d'une porte, `RSP0` quand le
     niveau de privilège baisse et une des sept piles d'interruption quand la
     porte en nomme une — celle-là s'imposant même sans changement de niveau,
     ce qui est propre au mode long. Ce qu'on empile reste la pile d'**avant** :
     c'est elle que l'`IRETQ` rendra au programme.

     Deux refus plutôt que deux suppositions : un `LTR` sur le sélecteur nul
     donnerait un TSS à l'adresse zéro, donc une pile de noyau au début de la
     mémoire ; et un changement de pile sans registre de tâche chargé, ou avec
     un TSS trop court pour porter ses piles, s'arrête au lieu d'inventer une
     adresse.

     **La tranche suivante n'était pas celle qui était annoncée ici**, et c'est
     la machine qui l'a dit. Le plan écrivait « puis `SYSCALL`/`SYSRET` ». Avec
     le TSS, le noyau va jusqu'à `Freeing initrd memory: 25404K` puis s'arrête
     sur l'opcode `0F 6E` à RIP `0x7f0f12aa143e` — une adresse d'espace
     utilisateur. `0F 6E` est `MOVD`/`MOVQ` entre un registre général et un
     registre SSE, et la bibliothèque C s'en sert dans ses fonctions de chaîne
     **avant** son premier appel système.

   - **Les seize registres XMM, contre le vrai processeur.** `MOVD`/`MOVQ` dans
     les deux sens et aux deux largeurs, `MOVDQA`/`MOVDQU`/`MOVAPS`/`MOVUPS`/
     `MOVAPD`/`MOVUPD`, dix entrelacements, douze opérations logiques. Aucune
     arithmétique en virgule flottante : sur les 8 663 instructions
     vectorielles du chargeur de musl, celles qui calculent appartiennent au
     formatage des nombres dans `printf`, qui ne tourne pas au démarrage.
     `MULSD` est refusée et **nommée**.

     **L'oracle matériel a grandi pour ça** : son harnais ne portait que les
     seize registres généraux et RFLAGS, il porte maintenant les seize XMM en
     plus. La preuve que ça n'a rien changé au reste est que les 10 020 cas
     arithmétiques existants se régénèrent **à l'octet près**. 832 cas neufs,
     52 formes, zéro désaccord.

     Trois trous que le sabotage a trouvés dans ce corpus-là : une branche
     qu'aucun cas ne pouvait atteindre, retirée ; une forme que l'assembleur ne
     choisit jamais — `66 0F D6` là où `as` prend toujours `F3 0F 7E` — dont
     les octets sont donnés à la main, le processeur disant toujours ce qu'ils
     font ; et une distinction que l'oracle ne peut pas mesurer, parce qu'un
     harnais qui exécute ne peut pas produire une faute sans mourir.

     **Et le noyau nomme la brique suivante** : dix instructions plus loin, il
     s'arrête sur `0F 05` à RIP `0x7f0f12ae386d`. C'est `SYSCALL`. Le plan
     avait raison sur le quoi et tort sur l'ordre.

   - **`SYSCALL` et `SYSRET`.** Pas une interruption, et c'est tout l'intérêt :
     l'adresse de retour dans RCX, les drapeaux dans R11, le segment et
     l'adresse dans des MSR, un saut — et **aucun changement de pile**. RSP
     reste celui du programme, et c'est au noyau de le remplacer, d'où le
     `SWAPGS` en tête de son gestionnaire.

     **C'est le second endroit du cœur qui ne soit pas prouvé contre la
     machine**, après la division par zéro : un `SYSCALL` dans le harnais de
     l'oracle entrerait dans le noyau de l'hôte au lieu de répondre. Dix tests
     écrits à la main contre le manuel, sept sabotages.

     **Plus aucun opcode refusé.** Le budget entier de 3,5 milliards passe, le
     journal grandit de 12 685 à 17 225 octets, et `/init` fait de vrais appels
     système — `modprobe` tourne deux fois avant lui.

   - **Ce qui reste, et ce n'est plus une brique.** Le programme meurt d'un
     SIGSEGV dans le chargeur de musl. Les octets que le noyau imprime —
     `mov 0x8c(%rdi),%eax` — se retrouvent à l'offset `0x4f209` de
     `ld-musl-x86_64.so.1`, au début de **`feof`** ; le `FILE *` qu'on lui
     passe vaut `0x00037cde165f7280` là où un pointeur de cette bibliothèque
     ressemble à `0x00007f89e85118a0`.

     Ce n'est plus une instruction qui manque, **c'est une valeur qui se
     corrompt**. Trouver un défaut et écrire une brique sont deux métiers
     différents : le premier se lit dans un arrêt, le second demande un témoin.
     La tranche suivante est donc le harnais différentiel contre QEMU —
     planifié une première fois puis abandonné parce que lire l'IDT du noyau
     avait suffi ; cette fois il n'y a pas de raccourci.

   - **La tentative : Linux démarre jusqu'au bout.** `X86BootAttemptTests`
     charge le vrai noyau d'Alpine 3.20 — Linux 6.6.134-0-lts —, pose une
     pagination d'identité, entre en mode long et saute. Le noyau va jusqu'à
     `kernel_init` et s'arrête pour la seule raison qui reste :

     ```
     [    0.000000] Linux version 6.6.134-0-lts (buildozer@build-3-20-x86_64) …
     [    0.000000] CPU: vendor_id 'wisq  x86-64' unknown, using generic init.
     [    8.929917] printk: console [ttyS0] enabled
     [   21.480833] smpboot: Total of 1 processors activated (28.82 BogoMIPS)
     [   21.546634] devtmpfs: initialized
     [   32.137346] TCP: Hash tables configured (established 2048 bind 2048)
     [   44.818378] ---[ end Kernel panic - not syncing: VFS: Unable to mount
                        root fs on unknown-block(0,0) ]---
     ```

     **C'est la bonne fin.** Un noyau sans disque et sans initrd dit exactement
     ça, sur une vraie machine comme ici. **262 lignes de journal**, une trace
     d'appels avec les noms des fonctions — donc `printk`, la table des
     symboles, le dérouleur de pile, les exceptions, l'horloge et la mémoire
     virtuelle marchent tous. Ce qui manque là n'est plus dans le processeur :
     c'est un disque — et avec un initrd, le test va au-delà, jusqu'à l'espace
     utilisateur.

     **Le test avait une assertion qui ne pouvait pas être vraie** : il
     exigeait `Unable to mount root fs` même quand on lui donne un initrd,
     c'est-à-dire précisément le cas où cette ligne ne doit pas apparaître. Il
     ne pouvait donc pas passer dans la configuration où il va le plus loin.
     Deux fins maintenant, une par machine.

     **3,5 milliards d'instructions en 4 min 30 s** en release, soit 13 MIPS
     sur du vrai code de noyau — un chiffre plus honnête que celui du banc, qui
     tourne sur une boucle choisie. Quarante-quatre secondes de temps invité.

     **Ce qui a rendu tout ça visible** : `earlyprintk=serial` dans la ligne de
     commande. `console=ttyS0` seul n'ouvre la console qu'une fois le pilote
     série chargé, c'est-à-dire après tout ce qui aurait pu mal tourner avant.

     **Comment on y est arrivé** : chaque arrêt a nommé la brique suivante, et
     jamais l'inverse. `CLD`/`CLI`, les segments, le retour lointain,
     `PUSHF`/`POPF`, les opérations sur chaînes, trois instructions x87, la
     carte E820, la livraison d'exception, l'octet haut lu par une instruction
     plus large, `ENDBR64`, les bases de FS et GS, `CMPXCHG`, les registres de
     débogage, le 8259, le 8253, la chaîne de bits, `BSWAP`, `FXSAVE`,
     `INT3`. Aucune n'a été écrite « au cas où ».

     Coût de tout cet ajout sur le débit : **15,4 → 13,5 MIPS**.
4. **La MMU.** Pagination à quatre niveaux, TLB, fautes de page. C'est le
   morceau qui décide si l'espace utilisateur existe.
5. **Le disque.** virtio-blk sur virtio-mmio ou PCI, et une image disque dans
   le stockage de l'application — ce qui rouvre pour de bon la question de
   « l'espace de stockage », cette fois avec un vrai disque à régler.
6. **Le reste d'un PC** : PIC/APIC, PIT, RTC, PCI, et un framebuffer.

Les tranches 1 à 3 se vérifient sans rien changer à ce qui existe. La machine
rv32 actuelle **reste** : elle démarre en une seconde, elle est utile pour
bricoler, et elle sert de témoin — le test différentiel entre deux cœurs a déjà
attrapé assez de choses pour qu'on ne s'en prive pas.

### Ce qui reste vrai pendant tout ce temps

Une distribution complète tourne **aujourd'hui** sur un hôte, avec wisq comme
écran, et c'est ce que le reste de l'application fait déjà bien. Le lot 7 ne
remplace pas ce chemin ; il en ajoute un, plus lent, qui n'a besoin de personne.

## La mémoire des VM **distantes** — lue (fait), pas encore réglable

« Ajuster la ram partout » a un second sens : les machines que l'agent gère sur
un hôte, pas seulement celle qui tourne dans le téléphone. Le protocole n'en
porte rien aujourd'hui — `Vm` a un identifiant, un nom, un état, une console et
un système invité, et pas un octet de mémoire.

Avant d'écrire quoi que ce soit, mesuré sur un vrai domaine libvirt (256 Mio,
`virtio` balloon, QEMU/TCG) :

| ce qu'on demande | ce que le vrai libvirt fait |
|---|---|
| `setmem --live` sous le maximum | **accepté en silence, et sans effet** : `dominfo` annonce toujours 262 144 Kio |
| `setmem --live` au-dessus du maximum | `invalid argument: cannot set memory higher than max memory` |
| `setmaxmem --live` | `cannot resize the maximum memory on an active domain` |
| `setmaxmem --config` sur un domaine allumé | accepté ; l'XML inactif passe à 524 288, le vivant reste à 262 144 |
| `setmem` sur un domaine éteint, sans `--config` | `Requested operation is not valid: domain is not running` |
| `setmem --config` sur un domaine éteint | accepté ; `currentMemory` change dans l'XML inactif |

**La première ligne est celle qui compte, et c'est la même leçon que l'arrêt
poli.** Réduire la mémoire d'un invité vivant n'est pas un acte : c'est une
demande au pilote balloon de l'invité, qu'un invité sans ce pilote ignore pour
toujours. libvirt dit « oui » et rien ne se passe. Une interface qui montrerait
un curseur revenant à sa place, sans explication, serait la même faute que
« l'arrêt a été demandé » présenté comme « la machine est arrêtée ».

Donc la forme, quand ce sera fait :

- `Vm` gagne `memoryKiB` et `maximumMemoryKiB`, lus sur `dominfo` — ce qui rend
  déjà quelque chose d'utile sans rien écrire.
- Une route qui écrit distingue **les deux questions**, parce que libvirt les
  distingue : le maximum (qui demande la machine éteinte, ou ne prend qu'au
  prochain démarrage) et la part courante (qui est une demande au balloon).
- La réponse doit dire ce qui s'est passé, pas ce qui a été demandé : sonder
  après coup, comme `VMPower.shutDown` sonde jusqu'à `stopped`, et rendre
  « demandé, pas encore rendu » plutôt que de prétendre.
- L'interface montre la mémoire d'une VM distante avant de laisser la changer,
  et nomme le prix : baisser la part courante d'un invité qui n'a pas de pilote
  balloon ne fera rien, et changer le maximum demande un redémarrage.

**Fait, la moitié qui lit.** `Vm` porte `memoryKiB` et `maximumMemoryKiB`, lus
dans `virsh dominfo` — qui porte aussi l'état, donc le démon fait un appel de
*moins* qu'avant, pas un de plus. Le téléphone les décode avec la tolérance de
l'état (montré, jamais agi) et les affiche sous le nom de la VM, les deux
seulement quand ils diffèrent. Vérifié à travers le vrai agent devant un vrai
libvirt.

**Pas fait, la moitié qui écrit**, et c'est délibéré : construire le curseur
avant de savoir quoi dire quand il ne commande rien serait l'erreur que les
mesures ci-dessus signalent. Ce qu'il reste à trancher, quand ce sera le
moment : sonder après coup pour distinguer « demandé » de « rendu », et
nommer le prix (un invité sans pilote balloon ne rendra rien ; changer le
maximum demande un redémarrage).

## « L'espace de stockage » : ce qui est montré, et ce qui ne sera pas fait (fait)

Il n'y a **aucun disque** dans la machine locale, et c'est une décision écrite
juste au-dessus : pas de pilote bloc dans les noyaux nommu de cette famille, et
l'instantané fait le travail que le disque aurait fait. Un réglage « taille du
disque » serait donc un curseur qui ne commande rien.

Ce qui est réel, c'est la place que **noyaux et machines sauvegardées**
occupent dans le stockage de l'application : mesuré sur le vrai noyau arrivé à
l'invite de connexion, **environ 17 Mio par noyau suspendu**, et quadrupler la
mémoire de la machine n'y ajoute que deux mégaoctets — le coût suit ce que
l'invité a touché, pas ce qu'on lui a donné. `LocalStorage` la compte, la vue la
montre — sous chaque noyau quand il a une machine sauvegardée à côté, et en
total — et un geste reprend les machines dont le noyau n'existe plus.

**Ce qui ne sera pas fait sans que Maxime le demande : un plafond qui
supprime.** La forme évidente d'un plafond est une politique d'éviction, et
supprimer les données de quelqu'un en silence pour rester sous un nombre qu'il
n'a pas choisi n'est pas un service. Le chiffre et le geste explicite tiennent
la même promesse sans prendre la décision à sa place.

Interprétation à confirmer avec Maxime si elle ne correspond pas à ce qu'il
avait en tête : si « espace de stockage » voulait dire un disque pour l'invité,
la réponse est plus haut et elle est non — mais elle mérite d'être rediscutée
plutôt que classée.

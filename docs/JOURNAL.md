# Journal des sessions autonomes

Ce fichier existe pour une raison simple : quand le travail continue pendant
que personne ne regarde, il faut pouvoir lire le matin ce qui a été décidé la
nuit — et surtout **sur quelle autorisation**. Un agent qui fusionne des pull
requests sans que la trace de l'accord existe quelque part est un agent dont
on ne peut pas vérifier le mandat après coup.

L'ordre est antéchronologique : le plus récent en haut.

## 2026-08-25, ~05h30 UTC — autonomie reconduite

**Autorisation, mot pour mot :** « Je vais dormir continue de travailler sans
moi note le / Je veux que ça soit enregistré. » — Maxime Nathan Lestage,
25 août 2026.

Deuxième fois, dans les mêmes termes. Consignée séparément plutôt qu'ajoutée à
l'entrée d'hier : une autorisation reconduite est un fait daté, et la fondre
dans la précédente laisserait croire qu'une seule phrase couvre deux nuits.

Les règles de l'entrée du 24 s'appliquent telles quelles — la branche, la
lecture du journal brut avant toute fusion, l'absence de licence, et la liste
de ce qui reste interdit. Rien n'a été élargi.

État au moment de s'endormir : PR #32 ouverte (surfaces SPICE), CI en cours.
Une routine horaire porte l'autorisation pour qu'elle survive à une perte de
contexte.

## 2026-08-25, ~06h UTC — ce que la nuit a décidé

Trois choses valent d'être relues au réveil, parce que ce sont des décisions
plutôt que du code.

**Ne pas porter QUIC.** J'allais le faire : deux mille lignes de codage
prédictif, c'est le codec par défaut de SPICE pour le photographique. Avant de
commencer, j'ai vérifié une chose — le protocole laisse le client *demander*
son encodage (`SPICE_MSGC_DISPLAY_PREFERRED_COMPRESSION`). Décoder un codec et
se faire envoyer ce codec sont deux réussites distinctes, et seule la seconde
met une image à l'écran. wisq demande `LZ`, qu'il décode, et QUIC devient une
optimisation *après* plutôt qu'un prérequis *avant*. Une heure de lecture de
spécification a remplacé une nuit de portage.

**Les fixtures LZ viennent de l'implémentation de référence, pas de ma main.**
`lz.c` de spice-common est lié dans un harnais qui comprime de vraies images
(`scripts/spice-lz-fixtures/`). Ce choix a payé immédiatement : **trois**
choses que j'avais écrites depuis la spécification étaient fausses — l'en-tête
du flux est gros-boutiste dans un protocole petit-boutiste, les longueurs sont
biaisées différemment selon le type de pixel, et le RGB32 transmet trois octets
par pixel et pas quatre. Une fixture écrite à la main n'aurait fait que
confirmer deux fois la même hypothèse.

**Ce que les sabotages ont trouvé, et qui n'était pas du code faux mais des
tests absents.** Trois affirmations n'avaient aucun test : le numéro de série
entre deux appels de la pompe, le curseur nommé depuis un cache, et la
frontière de l'échappement de distance longue. Chacune découverte parce qu'un
sabotage *passait*. Deux gardes se sont révélées être du code mort et ont été
retirées plutôt que gardées « au cas où » — dont un `defer` qui ne pouvait pas
faire ce que son nom disait, vérifié par un programme de cinq lignes au lieu
d'être raisonné.

À signaler aussi : deux gardes ne « mordent » pas en faisant échouer un test
mais en faisant *planter* le processus. Elles sont signalées comme telles dans
la PR, pas comptées comme des succès — un signal plus faible qu'un test rouge
mérite d'être nommé.

Un test contient un compromis assumé : celui du curseur nourrit le socket
display de 200 pings, sinon la session se termine avant que la tâche curseur
ait lu son message. C'est une course qu'elle ne perd pas contre un vrai socket,
qui bloque au lieu d'annoncer la fin du monde. Écrit dans le commit, parce
qu'un test qui passe pour des raisons d'ordonnancement est pire qu'un test qui
échoue.

## 2026-08-24, nuit — autonomie accordée

**Autorisation, mot pour mot :** « Je vais dormir continue de travailler sans
moi note le / Je veux que ça soit enregistré / Il faut merger et continuer. »
— Maxime Nathan Lestage, 24 août 2026.

Ce que ça change par rapport au reste de la session : jusque-là chaque fusion
était autorisée une par une, et je m'arrêtais après chaque PR pour demander.
À partir de là je fusionne moi-même une PR dont la CI est verte, et
j'enchaîne.

Ce que ça ne change pas, et qui reste vrai sans qu'on ait besoin de me le
redire :

- Le développement reste sur `claude/concurrent-utm-app-stores-ofjujj`. Après
  chaque fusion, la branche repart de `master` et une **nouvelle** PR est
  ouverte — jamais d'empilement sur de l'historique déjà fusionné.
- Une CI verte ne suffit pas : le journal brut du job est lu avant de
  fusionner, pour vérifier que les tests ont **réellement tourné** et que rien
  n'a été sauté. Une pastille verte n'est pas une preuve.
- Aucune licence n'est annoncée nulle part. Aucune n'a été choisie.
  `scripts/check-licence-claims.sh` le tient.
- Rien de destructif, rien d'irréversible sans accord : pas de réécriture de
  l'historique de `master`, pas de suppression de branche d'autrui, pas de
  publication de release, pas de `--force` ailleurs que sur ma propre branche
  et seulement quand son contenu est déjà dans `master`.
- Chaque affirmation qu'un commit fait sur son propre travail est vérifiée
  avant d'être écrite, sabotage compris : on casse la ligne exprès et on
  regarde si un test tombe. Quand il ne tombe pas, c'est la ligne ou le test
  qui est faux, et c'est dit.

Ce qui a été fait dans la soirée, avant de dormir : lecture des fichiers de
connexion `.vv` et `.rdp` et leur branchement dans l'application (#28),
décodage du canal display de SPICE (#29), décodage du codec LZ vérifié contre
l'implémentation de référence (#30). Trois fusions, trois branches repartant
de `master`.

Ce qui suit est écrit au fil de la nuit.

### Une couche qui n'existait pas

Le transport de l'agent avait été écrit depuis `vd_agent.h`, qui définit un
`VDIChunkHeader` — port et taille — devant chaque `VDAgentMessage`. Il y avait
donc un codec pour lui, des tests pour ce codec, et une fonction qui le posait
sur le fil.

Il n'a rien à y faire. `channel-main.c` de spice-gtk écrit le `VDAgentMessage`
nu dans `AGENT_DATA` et découpe à `VD_AGENT_MAX_DATA_SIZE` ; aucun en-tête de
morceau. Cet en-tête appartient au tuyau virtio entre le serveur et l'agent
dans l'invité, et ne traverse jamais le réseau.

Même famille que `attachChannels = 101` : du code juste, pour quelque chose qui
n'est pas là. La différence est qu'il a été trouvé avant d'être commis, et
seulement parce que la question « qu'écrit un vrai client, exactement » a été
posée à la source plutôt qu'aux en-têtes. Les en-têtes décrivent les structures ;
ils ne disent pas laquelle voyage où.

Retiré : le codec, ses tests, et le type `Port`. Gardé : le réassembleur, qui
était juste pour une autre raison que celle écrite dans son commentaire.

### Un sabotage qui n'a pas mordu

Quatre sabotages sur le transport n'avaient rien affiché lors de la session
précédente. La cause n'était pas qu'ils passaient : `swift` n'était pas dans le
`PATH` de ces shells-là. Rejoués un par un, les quatre mordent.

Sur le nouveau code, six sabotages sur sept mordent. Le septième — retirer la
garde qui empêche deux drains simultanés — laissait tout vert, et l'enquête a
montré que le commentaire de cette garde était faux : les octets ne peuvent pas
s'entrelacer, la file est FIFO et un message y entre d'un bloc. Ce qui casse,
c'est le numéro de séquence, lu avant l'`await` et incrémenté après. Le test
manquant a été écrit ; sans la garde : huit messages, sept numéros. Commentaire
corrigé pour dire la vraie raison.

### Un champ lu et jamais utilisé

En préparant le décodage des bitmaps non compressés, une recherche sur
`topDown` dans `SpiceLZ` n'a donné que deux occurrences : la déclaration et
l'analyse. Rien ne s'en servait. Une image LZ de bas en haut s'affichait donc à
l'envers depuis que le codec a été fusionné.

C'est la troisième fois que ce motif apparaît — après le `defer` mort sur
`nextSerial` et la branche BOM UTF-8 inatteignable. Un champ qu'on analyse
parce qu'il est dans le format, et dont on n'utilise jamais la valeur, ne fait
pas échouer de test : il n'y a rien à faire échouer. La recherche qui le trouve
est « combien de fois ce nom apparaît-il », pas une suite de tests.

Le défaut n'était pas visible non plus dans les gabarits : l'encodeur de
référence produit `top_down = 1` pour toutes les images du harnais, donc tous
les tests existants passaient par le seul chemin correct. Le test ajouté change
un octet du gabarit plutôt que d'en fabriquer un nouveau — mêmes pixels, un
drapeau, lignes inversées.

Deux tests existants sont tombés en même temps, et c'était eux qui avaient
tort : leur gabarit de bitmap déclarait une image 64×48 de pas 256 sans un seul
octet de pixel. Le décodeur ne lisait pas ces octets, le gabarit ne les
fournissait pas, et les deux étaient d'accord entre eux et avec rien d'autre.
Gabarit complété, pas de décodeur assoupli.

### Un sabotage qui passe parce que le gabarit ne va que dans un sens

En branchant `lzPalette`, trois sabotages : deux mordent, le troisième —
supprimer la lecture de l'orientation sur ce chemin — laisse tout vert.

La raison n'est pas que la ligne est inutile. C'est que **tous les gabarits
produits par l'encodeur de référence ont `top_down = 1`**. Le chemin de
retournement n'est jamais atteint par ce trajet, donc rien ne tombe quand on
l'enlève.

C'est exactement l'angle mort qui avait laissé `SpiceLZ.Header.topDown` être
analysé et ignoré pendant plusieurs PR. Un jeu de gabarits complet sur tout ce
qu'il couvre peut être unanime sur une dimension, et cette unanimité ressemble
à une couverture.

Le test manquant a été écrit : un gabarit réel, un seul octet de drapeau
changé, et le trajet complet par `pixels(of:)` — pas un appel direct à la
fonction de retournement, qui aurait passé le sabotage aussi. Première
tentative écrite justement comme ça, et rejouée : elle ne mordait pas non plus.

### Un décodeur que personne n'exécutait

Avant de brancher JPEG dans SPICE, une question : où le décodeur JPEG est-il
testé ? Réponse mesurée, pas lue : nulle part.

`JPEGDecoder` enveloppe ImageIO et se déclare indisponible ailleurs. Les tests
du paquet ne tournent en CI que sur Linux, où `canImport(ImageIO)` est faux.
`swift test --filter JPEGTests` sur Linux exécute trois tests ; `testDecodesARealJPEG`
n'en fait pas partie. Et le job iOS ne lance que `Tests/WisqUITests` — les tests
du paquet n'y sont pas. Donc le code qui transforme des octets en pixels
n'était vérifié par aucun job.

Pire : `testQualityIsClampedIntoTheSpecRange` commençait par
`guard JPEGDecoder.isAvailable else { return }`. Sur Linux il sortait
immédiatement et était compté **réussi**. Une coche verte pour un corps qui ne
s'exécute jamais est pire qu'une rouge : c'est la forme de la couverture sans
la substance. Remplacé par `XCTSkipUnless`, qui le compte sauté.

Conséquence sur ma propre habitude de vérification : je lisais « 0 sauté »
comme un critère. Il y aura désormais 1 sauté sur Linux et 0 sur Apple. Le
critère devient : les tests sautés sont ceux qu'on attend, et on sait
lesquels.

Ajouter le job `Cœur (Apple)` avant de brancher JPEG dans SPICE, plutôt
qu'après : sinon la nouvelle branche serait posée derrière le même décodeur
non vérifié, et on ne l'apprendrait qu'en le découvrant.

### Le job Apple, mesuré plutôt que supposé

Il est passé en soixante secondes, ce qui m'a d'abord paru trop court pour une
compilation macOS plus 445 tests. Journal brut : **446 tests, 0 échec,
`arm64e-apple-macos14.0`**. La minute, c'était juste un runner Apple Silicon.

Ce que le job apporte, vérifié nommément : `testDecodesARealJPEG` a tourné et
est passé. C'est la première fois en CI. Avec lui `testGarbageIsRejected`,
`testUndecodableJPEGFailsLoudly`, et `testQualityIsClampedIntoTheSpecRange` qui
affirme enfin quelque chose au lieu de sortir avant.

**Ma prédiction était fausse sur un point** : j'avais écrit « 0 sauté attendu
sur Apple ». Il y en a quinze. Tous s'expliquent — quatorze dans
`WisqAgentTests` et `LinuxBootTests`, qui réclament le binaire de l'agent et le
noyau de test que ce job ne va pas chercher, et un
(`testTheShippedEncryptorRefusesWhereThereIsNoRSA`) sauté justement parce qu'il
*y a* RSA sur Apple. Aucun n'est un trou que ce job devait combler. Le compte
est maintenant écrit dans le workflow, pour que personne ne lise « quinze
sautés » comme un problème.

### Découper QUIC, et le dire

QUIC fait 2 250 lignes de C. J'ai construit le harnais, vérifié qu'un flux
produit par l'encodeur de référence repasse exactement par son décodeur, puis
je me suis arrêté avant la boucle de décodage.

C'est délibéré. Une PR qui aurait tout contenu n'aurait pas été relisable, et
surtout : la partie que j'ai livrée est la seule dont la vérification soit
*propre*. Les tables de famille sont des fonctions pures de la profondeur de
bits — on peut les comparer nombre par nombre à celles que `family_init`
remplit. La boucle de décodage, elle, ne se vérifiera que de bout en bout, sur
des images entières. Se tromper dans les tables coûterait cher à chaque pixel
de chaque image, donc c'est là qu'il faut la comparaison exacte, et c'est fait.

Le harnais a appris deux choses avant même le premier octet de Swift : `rgb32`
ne transmet pas le quatrième octet (comme en LZ), et `gray` refuse de se
décoder en 32 bits. La seconde aurait été un échec incompréhensible plus tard.

`qfam.c` fait un `#include "quic.c"` au lieu de le lier, parce que les tables
sont statiques au fichier. Le but est de lire les tableaux que `family_init` a
effectivement remplis, pas de les recalculer depuis une deuxième lecture du
même C — ce qui ne prouverait que la constance de mes propres suppositions.

### Un sabotage qui ne mord pas parce qu'il n'y a rien à mordre

Six sabotages sur le lecteur de bits, cinq mordent. Le sixième — remplacer
`eat32` par 31+1 au lieu de 16+16 — laisse tout vert.

Cette fois, ce n'est pas un test manquant. Vérifié contre la référence
elle-même, en lui faisant faire les deux : 16+16, 31+1 et une suite mélangée
laissent le lecteur dans exactement le même état, sur les trois gabarits. La
comptabilité ne suit qu'un total courant, donc le découpage n'a aucune portée
sémantique.

La distinction compte. Les fois précédentes où un sabotage ne mordait pas —
`nextSerial`, la garde de drain, l'orientation sur le chemin palettisé — la
ligne ou le test était faux. Ici la ligne est juste et il n'y a rien à épingler
au-delà de « ne jamais demander 32 d'un coup », que la précondition tient déjà.
Inventer un test qui fige un découpage arbitraire aurait donné l'apparence
d'une couverture supplémentaire sans en être.

Le commentaire disait « la référence l'interdit », ce qui était vrai mais
laissait croire que le découpage comptait. Il dit maintenant lequel des deux
faits est le vrai, et que l'autre a été mesuré.

### Un sabotage qui ne mord pas, et cette fois c'est un test manquant

Sept sabotages sur le modèle, six mordent. Le septième — diviser les compteurs
quand le total *atteint* le seuil au lieu de le *dépasser* — laisse tout vert.

Contrairement au cas du lecteur de bits la tranche d'avant, les deux versions
ne sont pas équivalentes. Elles diffèrent exactement quand le total tombe pile
sur le seuil. Le problème est qu'aucune séquence ordinaire n'y arrive : le
seuil vient d'une table de onze valeurs, et les totaux passent à côté.

La distinction entre « équivalent » et « intestable » vaut d'être faite à
chaque fois, parce qu'elles se ressemblent depuis la suite de tests : dans les
deux cas tout est vert. La question à poser est « existe-t-il une entrée qui
les distingue », pas « est-ce que mes tests actuels les distinguent ».

Ici la réponse est oui, et il a fallu la fabriquer : le harnais règle
`wm_trigger` directement, ce que `set_wm_trigger` ne permet pas. La référence
répond alors sans ambiguïté — pile sur le seuil, les compteurs ne sont pas
divisés ; un cran en dessous, ils le sont. Test ajouté, sabotage rejoué, il
mord.

## La boucle de décodage QUIC

### Une conclusion fausse que j'avais écrite dans le code

J'avais noté, dans un commentaire et dans mes notes de travail, que
`correlate_row[-1]` était lu au début de chaque ligne et **jamais écrit** — de
la mémoire non initialisée dont la valeur ne comptait pas. J'avais même une
expérience à l'appui : empoisonner cette case dans la référence avec dix
valeurs différentes ne changeait rien, sur aucun flux, y compris un 4×200 où
deux cents débuts de ligne la lisent.

C'était faux, et l'expérience ne prouvait pas ce que je lui faisais dire. Elle
empoisonnait la case *avant* le décodage ; la ligne 1 la réécrivait avant de la
lire. Je mesurais que l'écriture existait, et j'en concluais qu'elle n'existait
pas.

Ce qui l'a montré : la première divergence entre ma trace et celle de la
référence était `CTX idx=0 ctx=0` contre `ctx=128`, au pixel 0 de la ligne 1 —
et 128 était exactement le premier symbole de la ligne 0. Un `grep correlate_row`
dans `quic.c` donnait la réponse en trente secondes, sur des lignes que j'avais
déjà sous les yeux : `correlate_row[-1] = 0` avant la première ligne,
`correlate_row[-1] = correlate_row[0]` avant toutes les autres.

La leçon n'est pas « lire la référence », que je faisais déjà. C'est qu'une
expérience qui confirme ce qu'on croit mérite le même soupçon qu'une qui le
contredit. Celle-ci avait un trou évident dès qu'on cherchait à le voir, et je
n'ai pas cherché parce qu'elle allait dans mon sens.

### `rgba` n'était pas un cas de plus, c'était une structure différente

Le décodeur annonçait `rgba` dans `shape(of:)` et l'aurait fait planter :
l'octet du canal 3 se calculait par `2 - channel`, soit **−1**. Un accès hors
bornes sur des données venues du réseau. Aucun test ne le montrait, parce
qu'aucun gabarit n'était en `rgba`.

En cherchant à en fabriquer un, la vraie difficulté est apparue, et elle tient
dans deux lignes de `quic_tmpl.c` :

    ONE_BYTE / FOUR_BYTE :  CommonState *state = &channel_a->state
    sinon (rgb)          :  CommonState *state = &encoder->rgb_state

Rouge, vert et bleu partagent un état ; le chemin quatre-octets a le sien. Donc
`rgba` est une passe couleur **puis** une passe alpha entièrement séparée, avec
son propre codeur de séries, ses propres compteurs d'attente, sa propre
détection de répétition (qui ne compare que l'alpha). Ma boucle fusionnée ne
pouvait pas l'exprimer. Le décodeur est maintenant organisé en plans : un plan
par groupe de canaux partageant un état, et `run()` fait, pour chaque ligne,
chaque plan à son tour — l'ordre exact de `uncompress_rgba`.

Le gabarit `rgba` a aussi montré un test trop indulgent : il ne comparait que
trois canaux. L'alpha, la seule chose que ce gabarit apportait, n'était pas
regardé. Il l'est maintenant, et un sabotage qui écrit l'alpha au mauvais
endroit tombe.

### Les gabarits ne se reconstruisaient plus

Avant de générer les deux nouveaux, j'ai régénéré un ancien pour vérifier que
le harnais était intact. Il ne l'était pas : `./qgen 1 16 12 5` ne produisait
plus le flux `gray 16x12` commité.

Les cinq flux d'origine restaient honnêtes — je les ai tous repassés dans le
décodeur de référence, ils se vérifient. Mais le `qgen.c` commité avait été mis
au propre avant le commit sans régénérer ce qu'il produisait, et sa bande de
bruit avait bougé. La procédure écrite dans le README ne reproduisait donc rien.

J'ai hésité à retrouver l'ancien générateur par rétro-ingénierie du bruit.
C'était le mauvais réflexe : l'autorité d'un gabarit vient du **décodeur** de
référence, pas de quelle image pseudo-aléatoire a été compressée. Ce qui
comptait était que la procédure documentée fonctionne. Les sept ont été
régénérés, le README donne la commande exacte de chacun, et j'ai vérifié les
sept bout en bout.

### Onze sabotages, onze qui mordent

Le report de `correlate_row[-1]`, l'état séparé par plan, l'ordre des canaux,
l'avance du masque d'attente, l'octet de l'alpha, la borne `index > 2` de la
détection de séries, la comparaison restreinte au plan, `bestCode = bpc - 1`,
les deux prédictions, et l'élargissement des cinq bits. Aucun survivant cette
fois — mais deux d'entre eux ne mordaient que grâce aux gabarits ajoutés dans
cette tranche, ce qui veut dire qu'ils ne mordaient pas la veille.

### Brancher QUIC, et la raison périmée qu'on laisse traîner

Le client demandait `lz` plutôt qu'`autoLZ`, avec un commentaire qui disait
pourquoi : « les modes automatiques laissent le serveur libre d'envoyer du
QUIC, et ce client ne sait pas le décoder ». La raison était juste quand elle a
été écrite. Elle ne l'était plus une fois QUIC décodé, et un commentaire qui
justifie un choix par un fait devenu faux est pire qu'un commentaire absent :
il empêche de reposer la question.

Avant de changer quoi que ce soit, j'ai vérifié ce que les modes automatiques
produisent réellement, dans le serveur et pas de mémoire. `dcc.cpp`,
`get_compression_for_bitmap` : les deux modes envoient du QUIC pour un bitmap à
forte gradualité, puis `AUTO_LZ` retombe sur LZ et `AUTO_GLZ` sur GLZ. Donc
`autoLZ` est devenu sûr et `autoGLZ` ne l'est pas — GLZ reste refusé. Sans
cette lecture, « les deux modes automatiques » se seraient ressemblés.

Deux tests ont dû changer avec, et l'un des deux était mal construit : le test
d'ordre du canal display réaffirmait l'encodage demandé au lieu de le lire là
où il est décidé. Il testait l'ordre et figeait la valeur, donc il tombait pour
la mauvaise raison. Il lit maintenant `compressionToRequest`, ce qui le ramène
à ce dont il parle.

L'autre changement est plus net : `testAnUndecodedEncodingAnswersNoPixelsRatherThanAnError`
listait `.quic` parmi les encodages non implémentés. Il ne l'est plus, donc une
charge qui n'est pas du QUIC est un message malformé et lève, comme `lzRGB`
lève sur une mauvaise magie. Retirer `.quic` de cette liste n'est pas contourner
un test qui tombe : c'est que sa prémisse a cessé d'être vraie.

## GLZ, première tranche : le harnais avant le codec

### Le piège du dictionnaire, qui aurait empoisonné tous les gabarits

Le harnais GLZ a produit, du premier coup, quatre flux dont les trois derniers
faisaient 51 octets. C'était trop beau, et c'était faux.

Le décodeur de référence les relisait vers le contenu de l'image 0 là où
aurait dû se trouver la bande neuve de chaque image. La cause n'était pas dans
le décodeur : **le dictionnaire GLZ conserve des pointeurs vers les tampons de
pixels de l'appelant**, il ne les copie pas. J'encodais la suite depuis un seul
tampon réutilisé, donc l'encodeur faisait correspondre l'image *N* à une mémoire
qui contenait déjà l'image *N+1*. Les flux étaient parfaitement valides et
décodaient vers une image que l'encodeur n'avait jamais vue.

Ce qui l'a rendu visible n'est pas le round-trip seul mais la conjonction de
deux signaux : le contenu décodé était *exactement* celui de l'image 0, et les
tailles étaient absurdes. Un seul des deux aurait pu passer pour une bizarrerie
du codec. Un tampon par image, tous maintenus en vie, et les quatre images font
l'aller-retour exact.

La leçon vaut au-delà de GLZ : quand un harnais donne un résultat meilleur que
prévu, c'est un symptôme, pas une bonne nouvelle.

### Mesurer que le gabarit exerce ce qu'on croit

Un gabarit GLZ qui ne contiendrait aucune correspondance entre images serait un
gabarit LZ déguisé, et tous les tests passeraient sans rien prouver. Plutôt que
de le supposer d'après les tailles, je l'ai mesuré : les mêmes quatre images,
dictionnaire neuf à chaque fois, 615 octets partout ; dictionnaire partagé,
615/201/205/194. L'écart est la correspondance entre images, et rien d'autre.

C'est le même défaut que les deux gabarits ajoutés pour QUIC venaient de
combler — un chemin que le code sait prendre et qu'aucune entrée ne lui fait
prendre. Autant le vérifier avant d'écrire le décodeur plutôt qu'après.

### Six sabotages, six qui mordent

Sur l'en-tête : `top_down` lu au bit 7 au lieu du bit 4, le type lu sur l'octet
entier au lieu du quartet bas, `id` lu sur 32 bits, `id` et `winHeadDistance`
intervertis, `headerBytes` à 28 (la longueur de LZ), et `id` lu en
petit-boutiste.

Un septième n'a pas mordu — mais parce que `sed` avait refusé de l'appliquer, le
motif contenant un `|`. « Aucune sortie » et « le sabotage survit » se
ressemblent beaucoup depuis le terminal ; c'est la troisième fois dans ce projet
qu'un sabotage muet vient de l'outillage et non du code. Rejoué en Python avec
une assertion sur l'application du motif, il mord.

## GLZ tranche 2 : un test qui avait tort, et un sabotage qui avait raison

### Le test faux, pris par un essai à blanc

J'avais écrit le test de `tailGap` en attendant 3 après avoir ajouté les images
0, 2 puis 1. Il vaut 2. La boucle de la référence est bornée par
`tail_gap <= img->hdr.id` : combler un trou ne fait pas courir le compteur
par-dessus les images arrivées en avance.

Le réflexe dangereux aurait été de « corriger » l'implémentation pour satisfaire
l'attente, d'autant que 3 semble plus naturel — le trou est comblé, les images
0, 1 et 2 sont toutes là. Mais `releaseAfterAdding` lit `slots[tailGap - 1]`
pour décider ce qui reste nécessaire. Avancer le compteur trop loin aurait
désigné une image plus récente que celle que la référence désigne, donc libéré
trop tôt des images que des flux ultérieurs pouvaient encore référencer. Des
images plausibles et fausses, encore.

Ce qui l'a attrapé n'est pas une relecture mais un essai à blanc : j'ai posé le
brouillon dans l'arbre, lancé les tests, puis retiré les fichiers. Relire mon
propre code ne m'aurait pas montré que mon attente était fausse — seul
l'exécuter le pouvait.

### Un sabotage survivant, et la question à poser

Six sabotages sur la fenêtre, cinq mordent. Le sixième — réindexer sur
l'ancienne capacité au lieu de la nouvelle lors d'un agrandissement — laisse
tout vert.

La question n'est pas « mes tests les distinguent-ils » mais « existe-t-il une
entrée qui les distingue ». Ici oui, et il a fallu la construire : les deux
modulos ne diffèrent que si une image dont l'identifiant dépasse l'ancienne
capacité se trouve dans le tableau au moment de l'agrandissement. Tous mes
tests ajoutaient des identifiants croissants depuis zéro, donc toujours
inférieurs à la capacité courante, et les deux modulos coïncidaient à chaque
fois.

La séquence `40, 24, 8` sépare : `40 % 32` vaut 8 là où `40 % 64` vaut 40, donc
le mauvais modulo range l'image 40 là où l'image 8 vient ensuite l'écraser.
Elle disparaît sans erreur — juste une image que la correspondance suivante ne
trouvera pas. Test ajouté, sabotage rejoué, il mord.

C'était donc un **test manquant**, pas une équivalence. Troisième fois que la
distinction compte dans ce projet, et troisième fois qu'elle se tranche en
cherchant l'entrée plutôt qu'en relisant la suite.

### Un sabotage qui mord en bouclant

Retirer la borne `tailGap <= image.id` ne fait pas échouer les tests : ça les
fait tourner indéfiniment, l'anneau plein n'ayant plus de condition d'arrêt.
Le premier essai a expiré au bout de deux minutes en emportant la commande. Un
`timeout` par exécution, et le blocage devient un résultat comme un autre —
« mord (boucle infinie) ». Un sabotage qui pend est un sabotage qui mord, à
condition de ne pas confondre l'expiration avec un silence.

## GLZ tranche 4 : un test vert qui ne vérifiait rien

Le branchement lui-même est court. Ce qui vaut d'être consigné, c'est un test
que j'ai écrit, vu passer, et qui ne testait rien.

Il devait montrer que la fenêtre GLZ survit d'un tour de pompe au suivant dans
`run()` — la propriété sans laquelle GLZ ne décode pas. Il scriptait deux
images, attendait, puis comparait le premier pixel du framebuffer à celui que
la référence avait produit pour l'image 1. Vert du premier coup, en quatre
millisecondes.

Quatre millisecondes pour un test censé attendre un framebuffer, c'était le
signal. Les deux images décodent à `00000000` sur leur premier pixel, et un
framebuffer intact vaut zéro : l'assertion était vraie avant même que quoi que
ce soit soit dessiné. Le test aurait continué à passer si le branchement
n'existait pas.

Corrigé en cherchant un pixel qui distingue l'image 1 de l'image 0 **et** de
zéro — le pixel 48, dans la bande de bruit — et en ajoutant deux assertions qui
vérifient que le gabarit distingue bien à cet endroit. Si un jour le gabarit
change et que le pixel témoin devient indistinct, ce sont ces deux lignes qui
tomberont, pas le silence.

La leçon n'est pas « écrire de meilleurs tests ». C'est que **la durée
d'exécution est une donnée** : un test asynchrone qui rend la main
instantanément n'a probablement rien attendu. Et qu'un sabotage vaut mieux
qu'une relecture — c'est en sabotant `run()` que j'aurais vu le problème, et
c'est ce que j'ai fini par faire.

### Ce que le sabotage a aussi révélé sur la portée

En vérifiant si le trou venait de mon changement ou de `run()` en général,
j'ai saboté la ligne des *surfaces* de la même façon : elle mord. Donc `run()`
était couvert, et c'était bien mon ajout qui ne l'était pas. Sans ce contrôle
j'aurais pu conclure « trou structurel, rien à faire » et passer à autre chose,
ce qui aurait été faux et confortable.

### Une surcharge que je n'ai pas ajoutée

Dix appels de test passaient `pump(into:serial:limit:)`. La tentation était
d'ajouter une surcharge sans fenêtre plutôt que de les corriger. Elle aurait
été un piège : appelée dans une boucle — ce que fait `run()` — chaque image
repartirait d'une fenêtre neuve, les correspondances entre images échoueraient,
et rien ne le dirait. Les dix appels ont été corrigés. Une API où l'on ne peut
pas pomper sans décider où vit la fenêtre est une API qui dit la vérité.

## GLZ tranche 5 : zlib autour, et le dictionnaire qui ne traverse pas

Le format ne cache rien — un flux GLZ avec du zlib autour, et la référence
dézippe puis appelle le même chemin. Ce qui valait la lecture, c'est
`decode-zlib.c` :

    inflateReset(&d->_z_strm);

au début de **chaque** image. Chaque image zlib-GLZ est donc comprimée
indépendamment, sans dictionnaire partagé.

C'est le contraire de ce que fait RFB, pour qui l'`InflateStream` de ce dépôt a
été écrit : là-bas le dictionnaire traverse les rectangles, et c'est même le
gain. Réutiliser cet objet ici décode la première image correctement puis
corrompt la seconde.

Je ne l'ai pas laissé au raisonnement : sabotage avec un inflateur partagé et
jamais réinitialisé, et la seconde image échoue en `Z_DATA_ERROR`. La
différence est donc réelle et testée, et il fallait deux images dans le gabarit
pour la voir — une seule n'aurait rien montré.

Un inflateur neuf par image plutôt qu'un `reset()` sur un objet conservé : même
sémantique que la référence, et ça évite de loger un type référence dans une
structure de valeur qui circule en `inout`. Le prix est une initialisation zlib
par image, des microsecondes contre un décodage.

Une sévérité de plus que la référence, assumée : elle avertit et garde ce qui a
été écrit quand le dézippage n'atteint pas la taille annoncée ; ici c'est
refusé. Un flux qui ne produit pas la taille que son propre message promet est
un message malformé.

### Une prémisse de test périmée, la troisième

`testAnEncodingWithADifferentMessageShapeIsNotReadWithThisOne` listait
`ZLIB_GLZ` parmi les types dont la forme n'est pas lue. Elle l'est maintenant,
donc il sort de la liste et gagne son propre test.

Troisième fois dans ce projet qu'un test tombe parce que son sujet a cessé
d'être vrai — après `.quic` dans la liste des encodages non implémentés, et
après le test d'ordre du canal qui figeait l'encodage demandé. À chaque fois la
question est la même : le test tombe-t-il parce que le code a régressé, ou
parce que sa prémisse a expiré ? Ici la prémisse a expiré, et le retirer n'est
pas contourner un test — c'est constater qu'il parlait d'un état révolu.

## GLZ : rgb24 gratuit, rgb16 et la troncature du C

### Une mesure qui rend le travail inutile

`rgb24` s'annonçait comme la tranche suivante, avec pour piège supposé le pixel
à trois octets. Il n'y avait pas de tranche : `DECODE_TO_RGB32` envoie les types
7, 8 et 9 au même décodeur. Un littéral rgb24 fait trois octets sur le fil comme
un rgb32 ; seule la largeur de *sortie* différait, et spice-gtk décode toujours
en 32 bits.

Vérifié en encodant le même contenu des deux façons : les flux diffèrent en
exactement deux octets, l'octet type/top_down et le mot de foulée. La charge
compressée est la même.

Conséquence sur le gabarit, et il faut le dire plutôt que de le laisser croire :
**il n'apporte aucune couverture à la boucle**. Mon premier commentaire le
présentait comme « transformant une lecture plausible en fait vérifié », ce qui
surestimait ce qu'il fait. Il épingle une chose plus étroite — que l'en-tête se
lit en rgb24 et que la charge derrière est une charge rgb32 — et c'est tout.

### Le vert faux, et pourquoi la référence avait raison

`rgb16` a échoué du premier coup avec un symptôme précieux : bleu et rouge
justes, **vert faux**. Pas un décalage général, pas un ordre d'octets inversé —
un seul canal.

La cause est dans le langage, pas dans l'algorithme. Dans la référence,
`out->g`, `out->r` et `out->b` sont des champs `uint8_t` d'un `rgb32_pixel_t`.
Donc `out->g = ((out->r) << 6) | ((out->b) >> 2) & ~0x07` **tronque à huit
bits**, et le `out->g |= (out->g >> 5)` de la ligne suivante opère sur la valeur
déjà tronquée. En Swift j'avais tout calculé en `UInt32` et tronqué à
l'écriture : les bits qui auraient dû tomber revenaient par le décalage.

C'est un genre d'erreur que la relecture attrape mal, parce que le C ne dit
nulle part « tronquer » — c'est le type des champs qui le dit, trois lignes plus
haut. Seul le gabarit de référence le montre, et il le montre proprement : un
canal sur trois.

### Une quatrième catégorie de sabotage survivant

Jusqu'ici je triais les sabotages survivants en trois : ligne fausse, test
manquant, équivalence réelle. Celui-ci en révèle une quatrième — **code mort**.
J'avais ajouté à `Literal` une propriété `bytes` qui disait combien d'octets un
littéral consomme ; la lire ne servait à rien, la lecture se faisant en ligne
dans le `switch`. Le sabotage passait donc sans rien casser, à juste titre.

La bonne réponse n'était ni un test ni une correction : c'était de la
supprimer. Une propriété qui a l'air de porter une règle et que personne ne lit
est pire qu'absente — elle invite à la croire appliquée.

## GLZ : la passe alpha, et un `git checkout` qui efface

`rgba` a marché du premier coup, ce qui est rare ici et mérite qu'on dise
pourquoi : la référence était lisible sans piège. Deux passes sur un tampon,
la seconde partant de l'octet où la première s'est arrêtée, ne touchant que le
quatrième octet, biais de longueur 2. Rien de caché dans un type de champ cette
fois.

Le seul choix à faire concernait le gabarit : donner à l'alpha des valeurs qui
varient. Un alpha constant aurait laissé passer un décodeur qui ne lance jamais
la seconde passe — le tampon étant déjà rempli de la bonne valeur par hasard.
Un test l'affirme désormais sur le gabarit lui-même, plutôt que de faire
confiance au générateur.

### L'erreur à ne pas refaire

Pour rejouer un sabotage j'ai modifié le *fichier de test*, puis je l'ai
restauré avec `git checkout` — ce qui l'a ramené à HEAD et **effacé les deux
tests que je venais d'écrire et qui n'étaient pas encore commités**.

J'avais sauvegardé le fichier source avant de le saboter, par réflexe, mais pas
le fichier de test. La règle est la même pour les deux : `git checkout` sur un
fichier qui porte du travail non commité le détruit sans avertir. Coût réel
faible ici — j'avais le texte exact sous la main — mais la même distraction sur
une heure de travail aurait été coûteuse.

### GLZ palettisé : un manque qui n'en était pas un

La feuille de route annonçait les formes palettisées comme la dernière tranche
de GLZ. Il n'y avait pas de tranche.

`canvas_get_glz_rgb_common` passe `NULL` là où irait la palette, et le
commentaire au-dessus de son appelant explique pourquoi : un bitmap palettisé
est comprimé en RGB32 globalement, « because same byte sequence can be
transformed to different RGB pixels by different plts ». C'est exactement ce
qu'un dictionnaire partagé entre images ne peut pas supporter — deux images
avec des palettes différentes ne peuvent pas se référencer l'une l'autre par
octets.

Confirmation indépendante côté serveur : `get_compression_for_bitmap`
rétrograde GLZ vers LZ simple dès que `bitmap_fmt_has_graduality` est faux, et
ce prédicat exige `bitmap_fmt_is_rgb`, dont la table met à zéro les six
premiers formats — tous les palettisés.

J'ai voulu une troisième confirmation en faisant refuser un type palettisé par
`glz_encode`. Il l'a refusé, et **ça ne prouvait rien** : mon générateur passait
une foulée de `width * 4` pour un type qui en veut une par pixel-par-octet,
donc l'encodeur rejetait ma foulée, pas le type. Je ne l'ai pas compté. Deux
preuves qui tiennent valent mieux que trois dont une est fausse.

Le refus reste dans le code — un serveur hostile peut toujours envoyer ce
qu'il veut — mais le commentaire et le test disent désormais que c'est un refus
définitif et non un trou à combler. La différence compte pour qui lira ça dans
six mois : « pas encore fait » invite à le faire.

### La même faute, deux fois, de la même main

Trois PR après avoir écrit « un gabarit qu'on ne peut pas reconstruire est un
gabarit que personne ne peut vérifier » — et régénéré les sept gabarits QUIC
pour cette raison — j'ai livré trois jeux GLZ irreproductibles.

Le générateur commité n'avait pas la variable `GZTYPE` que j'avais ajoutée dans
le scratchpad pour produire `rgb24`, `rgb16` et `rgba`. Huit variantes du
générateur traînaient hors du dépôt (`gzgen` à `gzgen8`) et c'est la cinquième
qui était commitée. Rien ne signalait le problème : les tests passaient, la CI
était verte, et le README affirmait une procédure de reconstruction qui ne
reconstruisait plus qu'une partie.

Ce qui l'a rattrapé n'est pas une relecture mais un inventaire : lister les
jeux de gabarits d'un côté, les modes du générateur de l'autre, et comparer.
Dix contre six.

Réparé, et vérifié plutôt qu'affirmé : les sept jeux issus de `gzgen` se
reconstruisent octet pour octet, `zlibWrapped` en recomprimant, le flux
fabriqué en repassant par le décodeur de référence et en recalculant
l'empreinte. La table est dans le README.

La leçon n'est pas « faire attention ». C'est qu'**écrire une règle ne la fait
pas respecter par soi-même** : entre le moment où je l'ai formulée pour QUIC et
celui où je l'ai enfreinte pour GLZ, rien dans le dépôt ne pouvait me le dire.
Un test qui recompilerait le harnais et comparerait aurait pu ; il n'existe pas,
et le noter ici est le minimum.

## LZ4 : trois programmes d'accord, et une règle qui ne sert à rien

Dernier codec du canal display, et le seul qui ne soit pas une invention de
SPICE. Ce qui l'a rendu intéressant n'est pas le décodage — c'est ce que la
vérification a trouvé.

**Le harnais d'abord, cette fois.** La leçon de la PR précédente était qu'écrire
une règle ne la fait pas respecter par soi-même. Donc : `l4gen.c` reproduit la
boucle `lz4_encode` du serveur, `l4dec.c` reproduit `canvas_get_lz4`, le README
porte la table des onze gabarits avec la commande de chacun, et j'ai
*réellement* suivi cette procédure depuis un répertoire vide avant de l'écrire.
Les onze se reconstruisent octet pour octet.

Une troisième lecture du format, en Python, décode les onze et tombe d'accord
avec lz4 octet pour octet. Elle sert surtout à compter ce que chaque gabarit
atteint — extensions de longueur, décalages sous 8, correspondances vers un bloc
antérieur — parce que « la fixture couvre ce chemin » est une affirmation qu'on
peut mesurer et que je m'étais déjà trompé en la supposant.

### Le sabotage qui avait tort sur lui-même

Douze sabotages, neuf attrapés. Les trois survivants ont chacun demandé un
travail différent, et c'est là que la séance devient utile.

Le premier — prendre 14 pour l'échappement au lieu de 15 — était un **gabarit
manquant** : aucun des onze ne contient un jeton dont le quartet vaut exactement
14. Bloc écrit à la main, passé par lz4 d'abord, sabotage attrapé.

Le deuxième — retirer la règle « une correspondance ne finit pas dans les cinq
derniers octets » — a survécu à un test que j'avais écrit *pour lui*. En traçant
le bloc, il se fait refuser trois séquences plus tôt, par la contrainte côté
entrée, et n'atteint jamais celle côté sortie. Le test passait, et il ne pinçait
pas ce que son commentaire annonçait.

L'arithmétique explique pourquoi : une correspondance ne se lit que si la
séquence précédente a laissé huit octets d'entrée d'avance, et la séquence
suivante doit être un run de littéraux qui consomme l'entrée exactement et
amène la sortie à sa fin. Une correspondance finissant à moins de cinq octets de
la fin a besoin d'au plus quatre littéraux finaux, donc d'au plus sept octets
d'entrée — moins que les huit déjà exigés. **La règle est inatteignable.** 400 000
blocs aléatoires et 150 000 mutations de charges réelles, décodées avec la règle
et sans elle, n'ont produit aucune différence.

Le troisième — relâcher la limite de lecture des octets d'extension — se prouve
inatteignable de la même manière, et la preuve tient en une ligne : la longueur
lue doit être cohérente avec la fin du bloc, et cette cohérence implique déjà
qu'on est à plus de 15 octets de la fin.

Ce n'est ni « ligne fausse » ni « test manquant » : c'est du **code mort dont la
mort dépend d'ailleurs**. Il reste, parce que retirer une borne au motif qu'une
autre la couvre, c'est faire dépendre la sûreté d'un raisonnement qui n'est
écrit nulle part. Il est écrit maintenant — dans le test, pas seulement ici.

### Ce que le fuzz différentiel a trouvé que la lecture n'avait pas

550 000 charges utiles passées dans les deux décodeurs. Deux divergences réelles,
aucune que j'avais vue en lisant le C :

* **un décodage court.** `canvas_get_lz4` ne vérifie pas que les blocs
  remplissent la surface. Ce qu'ils n'atteignent pas garde ce que l'allocation
  de pixman contenait, et c'est dessiné. 1 101 mutations tombent là ; wisq
  refuse.
* **une distance nulle.** Le format la déclare corrompue et autorise le refus.
  lz4 ne la refuse pas : `LZ4_write32(op, 0)` sur le chemin des petits décalages
  fait qu'elle copie des zéros. Le client de référence dessine une bande noire ;
  wisq refuse. J'aurais écrit « invalide par le format » dans un commentaire et
  j'aurais eu raison sur le format et tort sur la référence.

Tout le reste s'accorde : 103 184 charges décodées à l'identique, 45 709
refusées des deux côtés.

### Et une erreur de harnais qui ressemblait à une découverte

Le premier fuzz a signalé sept désaccords « lz4 accepte, moi je refuse ». Aucun
n'était réel : mon modèle Python n'avançait pas le pointeur d'entrée dans la
branche finale, et lisait la longueur du bloc suivant au mauvais endroit. Le
même piège que d'habitude sous une forme de plus — un résultat qui a l'air d'un
résultat. La différence avec les fois précédentes est que j'ai vérifié avant de
l'écrire quelque part.

## Les dessins sans codec, et un masque dont les deux réponses sont fausses

Après LZ4 il ne restait plus de codec à écrire sur le canal display, et
l'inventaire — la même méthode que la fois précédente — a montré autre chose :
la pompe traitait quatre types de messages sur vingt-six. `DRAW_COPY_BITS`,
`DRAW_BLACKNESS`, `DRAW_WHITENESS` et `DRAW_INVERS` étaient comptés comme
ignorés. Ce sont les plus simples du protocole et, pour le premier, l'un des
plus fréquents : une fenêtre qui défile, c'est exactement ça. Le décodeur le
plus complet du monde ne sert à rien si la fenêtre garde son ancien contenu en
défilant.

Deux pièges, tous deux dans la référence plutôt que dans le format.

**La source se découpe aussi.** La boîte et le clip bornent l'écriture ; rien ne
borne la lecture. Un défilement près d'un bord nomme une ligne source qui
n'existe pas, et la tentation est de borner la lecture — ce qui duplique le
bord. `canvas_copy_bits` intersecte la destination avec un rectangle décalé de
la distance, ce qui *retire* de la région les pixels sans source au lieu de leur
inventer une. Le test qui l'épingle vérifie que les trois premières lignes sont
inchangées, pas qu'elles ressemblent à quelque chose.

**La copie se recouvre.** `spice_pixman_copy_rect` choisit un sens de parcours
par rectangle et `copy_region` ordonne les rectangles pour aller avec. wisq lit
toute la source d'abord. C'est équivalent, et ça vaut d'être dit dans ce sens :
l'ordre de la référence existe pour imiter un instantané sans en allouer un, pas
l'inverse. Trois tests — vers le haut, vers le bas, sur le côté — parce qu'un
décodeur qui code en dur un seul sens passe le premier.

### Le masque

C'est la partie où il n'y a pas de bonne réponse et où l'écrire est la seule
chose honnête à faire.

Un `QMask` réduit ce qu'un dessin touche. wisq ne le décode pas. Peindre toute
la boîte écrase des pixels que le serveur voulait garder ; ne rien peindre en
laisse de périmés. Le serveur ne renverra ni les uns ni les autres.

`DRAW_FILL` faisait le premier depuis le début, en silence. J'ai basculé sur le
second, pour deux raisons qui ne sont pas « c'est mieux » : c'est ce que ce
fichier fait partout ailleurs quand il ne peut pas exécuter un dessin, et un
rectangle noir en travers d'une fenêtre est pire à regarder qu'un rectangle qui
n'a pas changé. Le test qui l'épingle porte l'argument, pas seulement le
résultat, pour que le décodage du masque plus tard soit un changement que
quelque chose remarque.

### Une asymétrie recopiée plutôt que corrigée

`blackness` passe `0x000000` à `fill_solid_rects` et `whiteness` `0xffffffff`.
Sur une surface avec alpha, le noir la vide et le blanc la remplit. Ça ressemble
à un bug de la référence. Écrire `0xff000000` aurait été *changer* le
comportement du protocole en quelque chose de plus sensé pendant que le serveur
dessine en attendant l'autre — c'est-à-dire décider unilatéralement, à la place
des deux bouts, ce que le protocole veut dire.

Dix sabotages, dix attrapés, plus deux sur le routage de la pompe. Le routage
mérite les siens : un `case` manquant est silencieux, donc seule une assertion
sur ce que la pompe a compté comme ignoré s'en aperçoit.

## Le masque, et un test qui a survécu à ce qu'il prétendait tenir

La tranche précédente refusait tout dessin masqué et disait, dans son propre
commentaire, que la vraie réponse était de décoder le bitmap A1. Celle-ci le
fait : `SpiceMask` résout le masque contre la boîte, et `fill`, `copy` et les
trois rasters le consultent par pixel.

Le point de conception vaut d'être écrit dans ce sens : le masque **ne rejoint
pas** les rectangles. La région des bits à un est une forme quelconque, dont la
décomposition en rectangles fait au pire un rectangle par pixel. Les rectangles
gardent donc leur sens — où le dessin *peut* écrire — et le masque répond s'il
écrit. Et ce sont toujours les rectangles qui remontent au rendu, parce qu'une
région de mise à jour est une indication de ce qu'il faut re-téléverser : un
sur-ensemble coûte de la bande passante, un sous-ensemble perd des pixels.

### Le test qui a survécu

En lançant la suite après avoir branché le masque, les 569 tests passaient — y
compris `testADrawCarryingAMaskIsRefusedRatherThanOverPainted`, qui dit dans son
nom que les dessins masqués sont refusés. Ils ne le sont plus. Le test passait
parce que le masque qu'il fabrique n'a pas de bitmap derrière son pointeur : il
est inutilisable pour une raison — un masque qui nomme quelque chose que ce
client n'a pas — et pas pour celle que le nom annonçait.

C'est la même famille que le sabotage LZ4 qui se faisait refuser trois séquences
trop tôt, et la troisième fois cette semaine que je tombe dessus : **un test
vert qui tient autre chose que ce qu'il dit**. Renommé pour ce qu'il épingle
vraiment, et les vrais masques sont testés à côté.

Ce qui rend cette famille difficile à voir, c'est qu'il n'y a rien à remarquer.
Un test qui échoue se signale ; un test qui passe pour la mauvaise raison
ressemble exactement à un test qui passe. La seule chose qui l'a trouvé ici est
d'avoir attendu que quelque chose *casse* en branchant le masque, et de m'être
demandé pourquoi rien n'avait cassé.

### Douze sabotages, douze attrapés — dont un qui a d'abord survécu

Les trois réflexions — ordre des bits, sens des lignes, position du masque — plus
« hors du masque = autorisé », qui est celle qui produit l'image la plus
convaincante : pour un petit masque sur une grande boîte, tout peindre ressemble
beaucoup à un masque qui fonctionne.

Le douzième est arrivé après coup et vaut mieux que les onze autres : avancer
d'une ligne de `(width + 7) / 8` octets au lieu de la `stride` du bitmap. Tous
les gabarits utilisaient la stride minimale, donc tous passaient. La référence,
elle, lit `ALIGN(x, 8) >> 3` octets *par* ligne et avance de la stride — ce ne
sont pas le même nombre, et un serveur a le droit de remplir. Le gabarit ajouté
remplit délibérément, avec des octets à un dans le remplissage pour que le lire
se voie.

### Et SwiftLint, qui a fait son travail depuis la CI

Un helper de test à six paramètres a rendu la CI rouge sur la PR précédente.
SwiftLint n'est pas installé sur cette machine, et `scripts/verify.sh` le dit
dans son propre commentaire : « une barrière qu'un contributeur ne peut pas
lancer localement est une barrière qui trouve les choses après l'ouverture de la
PR ». C'est exactement ce qui s'est passé. Le commentaire avait raison ; il n'a
pas empêché la chose, il l'a seulement prédite.

## Le rop, et un sabotage qui ne s'était pas appliqué

Chaque message de dessin porte un descripteur d'opération raster. wisq le lisait
et le jetait. Pour l'immense majorité des messages c'est sans conséquence — le
descripteur usuel veut dire « copie » — mais un rectangle de sélection, un
curseur de texte et un tracé élastique sont dessinés en XOR pour que le second
passage efface le premier. Traités en copie, ils s'affichent et restent.

La partie amusante est que tout est pur : seize fonctions booléennes et un
réducteur de 2048 descripteurs vers elles. Rien à fabriquer, rien à échantillonner.
Les tests couvrent **tout** : les seize opérations sur les 65 536 paires
d'octets, et les 2048 descripteurs sous les trois étiquetages qu'un message peut
leur donner.

**La valeur brute d'une opération X11 *est* sa table de vérité** — le bit
`3 − (2·src + dst)` du numéro est le résultat pour cette paire. `apply` ne s'en
sert pas : il écrit les seize cas en opérateurs bit à bit, lisibles à côté de
leur commentaire. La dérivation gagne sa place dans le test, où elle est la
seconde opinion indépendante.

Deux comportements recopiés plutôt que corrigés, et l'un des deux a été trouvé
par un test qui avait tort : j'avais modélisé « INVERS_RES s'applique toujours »,
ce qui est la règle sensée. La dernière ligne de la référence est un
`return SPICE_ROP_COPY` nu qui ne regarde aucun drapeau. Le test était faux et la
transcription juste — l'ordre dans lequel ces deux-là sont censés être
découverts.

### Le sabotage qui ne s'était pas appliqué

Douze sabotages, dix attrapés du premier coup. Les deux survivants ont été plus
instructifs que les dix.

Le premier était une vraie redondance : `opaque` construisait sa copie interne
avec `rop: 0` *et* passait `blitROP: .copy`. Deux façons de dire la même chose,
donc supprimer l'une ne changeait rien. Réparé en portant le vrai descripteur et
en laissant l'override porter la décision — maintenant le sabotage mord.

Le second n'existait pas. Le motif que je remplaçais — les deux lignes
`brush: try brush(...)` suivies de `rop: try reader.u16()` — **apparaît deux fois**
dans le fichier, et `replace(..., 1)` a touché celle de `fill`, pas celle
d'`opaque`. Puis, en vérifiant, mon filtre de tests ne contenait pas la suite qui
couvre `fill`. Deux couches de « rien ne s'est passé » qui ressemblaient à
« la ligne est morte ».

C'est la quatrième fois cette semaine, et la variante est nouvelle : cette fois
ce n'était ni le code ni les tests, **c'était le harnais de sabotage lui-même**.
La règle que j'en tire est concrète plutôt que morale : lancer les sabotages
contre la suite entière et pas contre un filtre choisi à la main, et vérifier que
le remplacement a changé le contenu du fichier — pas seulement qu'il n'a pas
échoué. Passé à la suite entière, la même modification sur `fill` fait tomber
neuf tests.

## La couleur-clé, et trois bogues dans le harnais de sabotage

`DRAW_TRANSPARENT` est petit : une couleur de l'image veut dire « laisse ce
qu'il y a dessous », le reste est copié. Ni masque ni rop — le seul dessin
porteur d'image qui n'en a pas. La comparaison porte sur vingt-quatre bits, et
`src_color`, présent dans le message, n'est jamais lu par la référence.

Ce qui mérite d'être écrit n'est pas le codec mais la séance de sabotage, parce
que **le harnais que j'avais écrit la tranche précédente pour ne plus se
tromper s'est trompé trois fois de suite**, et chaque fois en produisant un
verdict qui avait l'air d'un verdict.

1. La logique de verdict cherchait « with 0 failures » dans la ligne de résumé.
   Elle dit « and 0 failures ». Tout était donc déclaré « attrapé », y compris
   deux sabotages qui survivaient vraiment.
2. Corrigée, elle prenait le *dernier* résumé imprimé plutôt que le total. Une
   suite qui se termine sur un groupe de trois tests était lue comme « trois
   tests, aucun échec ».
3. Corrigée encore, la regex exigeait « failures » au pluriel. Avec exactement
   **un** échec, la ligne de total ne correspondait plus, et le sabotage
   apparaissait comme « la suite n'a pas tourné entière ».

Les trois ont la même forme que ce que je poursuis depuis une semaine : une
absence de résultat qui ressemble à un résultat. La différence est qu'ici
l'outil censé m'en protéger était lui-même le fautif — et que je ne l'ai vu
qu'en ajoutant un **cas témoin** : un sabotage volontairement inoffensif, qui
doit survivre. Il est resté dans le harnais.

Une fois honnête, la séance a rendu deux vrais trous :

* **la clé était symétrique dans tous mes gabarits.** `0x00FF00FF`,
  `0x0000FF00`, `0x00AAAAAA` : échanger rouge et bleu en dépaquetant la clé
  passait chacun d'eux. Gabarit asymétrique ajouté, avec son miroir comme second
  pixel ;
* **rien ne vérifiait que le clip ne fait pas glisser l'image.** `copy` a ce test
  depuis longtemps ; `transparent` ne l'avait pas, et tous les clips de mes
  tests commençaient à la même colonne que leur boîte.

Neuf sabotages, neuf attrapés une fois les trous comblés.

## L'alpha prémultiplié, que personne n'écrit

`DRAW_ALPHA_BLEND` est la seule vraie composition du canal, et son arithmétique
n'appartient pas à SPICE : `__blend_image` construit un masque uni et appelle
`PIXMAN_OP_OVER`. Tout le travail était donc de répondre à une question que la
référence ne pose jamais — **la source est-elle prémultipliée ?**

Aucune des sources ne le dit. Pas le protocole, pas `canvas_base.c`, pas
`sw_canvas.c` ; et rien, nulle part, ne divise par l'alpha. Ce qui tranche est
une chaîne de trois maillons : `SPICE_BITMAP_FMT_RGBA` devient
`PIXMAN_a8r8g8b8`, pixman définit `OVER` sur une source prémultipliée, et
personne ne convertit entre les deux. Prémultiplié est ce que la chaîne *fait*,
pas ce qu'elle déclare.

C'est le genre de conclusion que j'aurais pu écrire par raisonnement et croire.
pixman est installé sur cette machine, donc je ne l'ai pas fait : le harnais
appelle pixman lui-même, exactement comme `__blend_image`, et compare. **43 008 000
combinaisons, aucune différence.** Les attentes des tests sont la sortie de
pixman, pas la formule réécrite sous une autre forme — recalculer la formule
dans le test l'aurait mise d'accord avec une formule fausse.

Le premier harnais laissait la destination opaque partout. Il annonçait 4 096 000
accords et n'avait jamais exercé `DEST_HAS_ALPHA`. Corrigé avant d'écrire quoi
que ce soit.

### Le sabotage, et un test noir sur noir

Onze sabotages, dix attrapés, plus un cas témoin qui survit comme il doit. Le
survivant : traiter une source à trois octets comme transparente au lieu
d'opaque. J'avais un test pour ça — `testAThreeByteSourceIsOpaque` — et il
passait dans les deux cas, parce que je l'avais écrit **sur une surface noire**.
Sur du noir, `src` et `src + 0` sont le même nombre ; opaque et transparent sont
indiscernables. Destination non nulle, et le sabotage mord.

La série de la semaine continue, et la forme se précise : ce n'est pas « mes
tests sont insuffisants », c'est que **les valeurs neutres — zéro, noir, une clé
symétrique, un descripteur nul — rendent deux implémentations différentes égales
par accident**. Un gabarit choisi sans y penser tombe presque toujours sur l'une
d'elles.

## Le rop3 : 256 gestionnaires contre une ligne

`DRAW_ROP3` est le cas général dont les autres dessins sont des particularisations.
La référence l'implémente avec une table de 256 gestionnaires générés par macro,
chacun portant sa formule. wisq l'implémente avec une expression :

    résultat = (opcode >> ((motif << 2) | (source << 1) | destination)) & 1

Remplacer 256 fonctions par une ligne est le genre de raccourci qui mérite d'être
prouvé plutôt que trouvé élégant. Le script `check-rop3.py` relit les formules
dans `rop3.c`, les évalue sur les huit combinaisons et compare : 218 formules,
zéro désaccord. C'est la référence qui valide la ligne, pas l'inverse.

Deux choses trouvées en le faisant, aucune des deux cherchée.

**Les 38 opcodes que la référence n'implémente pas sont exactement les 38 qui
ignorent au moins un opérande.** J'avais d'abord noté « il en manque 38 » comme
un fait sans intérêt. En listant lesquels — `0x00`, `0xCC`, `0xF0`, `0xAA`… —
la régularité saute aux yeux, et elle se vérifie : les deux ensembles coïncident
élément par élément. Ce sont ceux qu'un serveur envoie sous forme de message
dédié. La référence appelle `spice_critical("not implemented")` si l'un arrive ;
wisq les traite tous, non par ambition mais parce qu'un `switch` sur 218 cas plus
un plantage serait plus de code que la ligne.

**L'ordre des bits n'est pas celui du rop binaire.** `SpiceROP` compte depuis le
haut, `SpiceROP3` directement. Rien ne le signale : les deux sont des « tables de
vérité dans un entier », et écrire la première convention dans la seconde donne
une table en miroir qui dessine quelque chose. Ce qui l'épingle sans dépendre de
mon propre raisonnement, ce sont les noms Windows — `SRCCOPY` vaut `0xCC` et veut
dire « la source », ce qui n'est vrai que sous un des deux ordres. Une preuve
externe au dépôt, pour une convention que le dépôt ne pouvait pas trancher seul.

Huit sabotages. Cinq attrapés, un invalide (ne compilait pas — compté comme rien,
pas comme une survie), et deux vraies survies : ni la pompe ni le masque
n'étaient testés pour ce message. C'est la même leçon que la semaine entière, et
elle est maintenant dans la routine : un nouveau dessin a besoin de son test de
routage *et* de son test de masque, parce que ces deux-là sont invisibles depuis
les tests de la fonction elle-même.

## Les flux vidéo, et trois affirmations qu'aucun test d'ici ne pouvait départager

`STREAM_CREATE` est le moment où le serveur abandonne : une région change trop
souvent pour valoir des dessins, alors il l'encode en vidéo. C'est là que passent
la plupart des pixels d'un bureau où quelque chose bouge, et un client qui
l'ignore fige l'écran précisément à l'endroit du mouvement.

Le registre est petit. Ce qui a demandé de l'attention, ce sont les endroits où
deux choses se ressemblent assez pour être prises l'une pour l'autre : deux
paires de dimensions (`stream_width` est la taille des images sur le fil,
`src_width` celle de la région sur l'écran du serveur, et elles diffèrent dès que
le serveur réduit avant d'encoder) ; deux formes du même message, la seconde
insérant sa géométrie *avant* la longueur ; et un troisième octet de drapeaux
avec son propre bit `TOP_DOWN`, au rang 0 cette fois, quand celui d'un bitmap est
au rang 2.

Seize sabotages plus un cas témoin. Dix attrapés, deux invalides — ils ne
compilaient pas, ce qui ne compte pour rien — et **quatre survivants**, le plus
gros lot depuis que je tiens le compte. Ils se répartissent en trois cas
différents, et c'est la répartition qui est intéressante.

### Un sabotage qui ne pouvait pas exprimer sa faute

« Stocker sur le flux la géométrie d'une image dimensionnée » : impossible.
`placement` est un `func` non-mutating, il ne peut rien écrire dans le registre.
Ce que le sabotage a réellement changé, c'est un champ du tuple renvoyé — et rien
ne le lisait.

Sauf que ce champ n'aurait pas dû exister. `placement` rendait **à la fois** le
`Stream` entier et `width`/`height`/`destination`. Dans le cas dimensionné, trois
champs du `Stream` sont périmés, et le nom naturel — `placement.stream.destination`
— désigne le mauvais. Un appelant qui l'attrape met la vidéo à la place de
l'image précédente, et rien ne l'arrête.

Le tuple est devenu un `Placement` qui ne porte que ce qu'un appelant a le droit
de lire. La faute n'est plus attrapée par un test : elle n'est plus **écrivable**.
C'est la première fois qu'un sabotage raté vaut mieux qu'un sabotage réussi.

### Une équivalence réelle, gardée pour ce qu'elle empêche

`guard codec.isDecoded else { return nil }` ne change aucun résultat : une image
VP8 n'est pas un JPEG valide, le décodeur rendrait `nil` de toute façon. Le
sabotage survit partout, et c'est correct.

La ligne reste, avec un commentaire qui dit pourquoi. Ce qu'elle empêche n'est
pas un mauvais pixel, c'est un appel : sans elle, des octets arbitraires venus du
réseau, dans un codec que personne ici ne décode, entrent dans le décodeur
d'images de la plateforme — ImageIO côté Apple. Le moyen le moins cher de ne pas
avoir cette conversation est de ne pas faire l'appel.

### Trois affirmations qu'aucun test d'ici ne pouvait départager

Les trois derniers survivants sont le même fait : **sur cette machine, le chemin
qui pose les pixels d'une image est mort**. Il n'y a pas de décodeur JPEG sur un
runner Linux, donc `frame(_:codec:)` rend `nil` avant tout le reste, et tout ce
qui suit ne s'exécute jamais. J'ai remplacé l'écrasement par un mélange, supprimé
le contrôle de taille, ignoré le clip — la suite entière est restée verte.

Ce n'est ni une ligne fausse ni une équivalence : c'est du code que mes tests ne
peuvent pas atteindre par la porte d'entrée. La question à se poser n'est pas
« mes tests le distinguent-ils ? » mais « existe-t-il une entrée qui le
distingue ? », et la réponse était oui dans les deux cas, à condition d'entrer
autrement.

Pour le report, `report(_:at:into:)` est sorti de `draw` et prend des pixels au
lieu d'un message. Plus besoin de décodeur pour tester l'écrasement, le sens de
lecture, le clip et le contrôle de taille.

Pour l'aiguillage de la pompe entre les deux formes du message, il fallait une
entrée qui distingue les deux lectures **sans dessiner**. Une image dont la
largeur dépasse le nombre d'octets qui la suivent : lue correctement, cette
largeur est une géométrie et l'image courte passe ; lue comme la forme simple,
elle atterrit là où va le compteur d'octets et le lecteur sort du message. La
pompe lève, et le test tranche sans un pixel.

Six sabotages relancés après coup, six attrapés, le témoin toujours vivant.

**La leçon**, et elle est nouvelle : jusqu'ici mes survivants venaient de
gabarits mal choisis — des valeurs neutres qui rendaient deux implémentations
égales par accident. Ceux-là viennent d'ailleurs. Une plateforme sans une
dépendance rend une branche entière inatteignable, et le code derrière est vert
sans avoir jamais tourné. La CI Apple l'exécute, mais la CI Apple ne sabote pas.
Quand une garde de disponibilité protège une branche, il faut une porte de
service — sinon tout ce qui est derrière est du texte.

## Le site publiait React en mode développement

Une relecture extérieure a proposé une liste d'optimisations. La plupart
étaient déjà faites — la pile TCP est réglée (`noDelay`, `connectionTimeout`,
`serviceClass`), le profil Rust est déjà `lto = "fat"`, `codegen-units = 1`,
`strip = true`, la parité des deux cœurs est tenue en CI, JPEG dans Tight
existe. Une piste visait le mauvais cœur : optimiser l'interpréteur Swift avec
des `UnsafePointer`, alors que celui qui tourne sur le téléphone est le Rust.

Mais une mesure a montré autre chose. Le bundle du site pesait 479 Ko bruts,
147 Ko gzippés. Il en pèse 207 et 66 maintenant, pour le même site. Deux causes,
et les deux sont des fautes de construction plutôt que de code.

### React a deux versions derrière un seul import

Celle de développement porte chaque avertissement, chaque contrôle de clé,
chaque invariant de hook — et c'est **celle qu'on obtient par défaut**. Le job
de déploiement lançait `bun run build` sans rien poser dans l'environnement, et
`Bun.build` n'invente pas de `NODE_ENV`. Résultat : 211 Ko de plus par visiteur,
et une exécution plus lente à chaque rendu, publiés depuis le premier jour.

La valeur est maintenant écrite dans `build.tsx` plutôt que laissée au shell.
Une construction qui produit un artefact différent selon la façon dont on l'a
lancée est une construction qui a un bug. Le build refuse en plus de publier un
bundle qui contient encore deux chaînes que seule la version de développement
porte.

### Chaque visiteur téléchargeait toutes les pages, dans les deux langues

`App` faisait `PAGES[lang][route]`, et cet import unique mettait la politique de
confidentialité, la FAQ, la feuille de route et la note d'architecture — en
anglais **et** en français — dans le fichier que tout le monde télécharge.
Mesuré en retirant l'import : 61 Ko bruts, 21,6 Ko sur le fil, de prose que
presque personne ne lira.

Le document voyage désormais dans la page qui le contient déjà, en JSON à côté
du balisage. Coût mesuré : 236 à 319 octets gzippés par page, parce que les deux
copies tiennent dans la fenêtre de gzip et que la seconde n'est presque que des
références arrière. Pas de requête supplémentaire, pas de frontière de suspense
au milieu d'un document, et l'hydratation a toujours son texte de façon
synchrone.

### La garde ne tournait pas quand son sujet changeait

`site/tests/claims.test.ts` existe précisément pour empêcher les chiffres
annoncés de rôtir : il lit le dépôt et échoue quand une affirmation cesse d'être
vraie. Il annonçait 462 tests là où il y en a 723, et 5 portes CI là où il y en
a 6.

La raison n'est pas que le test est faible : c'est que `site.yml` était filtré
sur `paths: ["site/**"]`. Ajouter un test Swift ne pouvait donc pas le
déclencher. **Une garde qui ne s'exécute que lorsque son sujet n'a pas changé
n'est pas une garde.** Le filtre est retiré ; le coût est une minute de CI sur
des changements qui ne touchent pas le site.

C'est la même leçon que la semaine dernière sous un autre angle : là, une
dépendance absente rendait une branche inatteignable ; ici, un filtre de chemin
rendait un test inatteignable. Dans les deux cas le vert ne voulait rien dire.

Quatre sabotages plus un témoin : trois attrapés, le témoin vivant. Celui qui
retire l'échappement du chevron mord — donc au moins un document contient un
`<`, et le test n'est pas vide.

## Le niveau de compression, et deux constantes que mes tests ne pouvaient pas voir

Le client annonçait une qualité JPEG mais jamais un niveau de compression — le
pseudo-encodage jumeau, `pseudoEncodingCompressLevel0 = -256` dans
`encodings.h`. Il est là maintenant, sur les liens lents seulement.

En lisant la référence pour choisir la valeur, deux choses ont retourné le
raisonnement.

**Demander moins de compression fait recevoir plus de données.**
`VNCSConnectionST::getComparerState` lit un niveau inférieur à deux comme « ce
client préfère son processeur à sa bande passante » et **désactive le
comparateur de mises à jour** : le serveur cesse de vérifier qu'une région a
changé avant de l'envoyer. Zéro et un ne sont donc pas « un peu moins
compressé », ce sont les deux valeurs à ne jamais envoyer.

**Et plus n'est pas mieux non plus.** `EncodeManager` dimensionne la palette à
`aire / (niveau × 8)` — au niveau 9 un rectangle garde à peine le tiers des
couleurs qu'il garderait au niveau 2. La référence commente sa propre formule
par un « it seems a bit backwards though ».

D'où six : au-dessus du défaut de deux, sans aller chercher l'étranglement de
palette. Lequel de six ou neuf envoie réellement moins d'octets dépend du bureau
et demande un vrai serveur ; ce que la source tranche, et ce que le code encode,
c'est que la réponse n'est pas en bas de la plage.

Au passage, un réglage qui promettait quelque chose qu'il ne faisait pas :
`lowBandwidth` était documenté « profondeur de couleur réduite » et aucune ligne
ne demandait autre chose que du BGRA 32 bits. Le commentaire dit maintenant ce
que le réglage fait.

### Les deux survivants disaient la même chose

Dix sabotages plus un témoin : huit attrapés, deux survivants — décaler
`compressLevel` de −256 à −255, et `qualityLevel` de −32 à −33. La suite
entière restait verte.

La cause est nette : **tous mes tests étaient écrits relativement à la constante
qu'ils auraient dû épingler.** « `compressLevel + 6` », « dans la plage de
qualité » — décaler la base décale les attentes avec elle, et il ne reste rien
qui touche le monde extérieur.

La base de la qualité avait l'air épinglée par `JPEGTests`, qui vérifie
`.contains(-23)` en littéral. Mais ce test appelle `XCTSkipUnless` sur la
présence d'un décodeur JPEG, absent sur tout runner Linux — et
`preferredEncodings` ne joint la qualité que si ce décodeur existe. Deux gardes
de disponibilité qui se referment sur la même absence.

C'est la troisième fois cette semaine, sous une troisième forme. Une dépendance
absente rendait une branche inatteignable ; un filtre de chemin rendait un test
inatteignable ; ici c'est un test relatif qui ne pouvait pas voir sa propre
origine. La règle qui en sort : **les nombres qui viennent d'ailleurs s'écrivent
en toutes lettres**, aux deux bouts de leur plage, avec leur citation — et pas
dans un test que la plateforme peut sauter.

Trois sabotages relancés, trois attrapés.

### Le keepalive, et la même porte de service

Un bureau distant est silencieux dès que l'écran l'est : le client demande une
mise à jour incrémentale et le serveur garde la demande ouverte. Des minutes de
rien sur le fil sont l'état normal. Or le NAT des opérateurs ferme les mappages
inactifs sans prévenir personne : la session a l'air vivante jusqu'à ce que
quelqu'un touche l'écran.

`NetworkByteStream` est derrière `#if canImport(Network)`, donc rien de ce qu'il
contient n'est compilé ni testé ici. Les six réglages sont sortis dans
`TransportTuning`, une valeur que n'importe quelle machine peut lire ; il ne
reste derrière la garde que six affectations. Les tests ne fixent pas les
nombres mais les bornes et la raison de chacune — la sonde doit partir avant
qu'un opérateur ne ferme le mappage, une seule sonde perdue ne doit pas couper
une session qui allait revenir, et le délai avant qu'un pair mort soit remarqué
doit rester dans ce qu'une personne accepte de regarder.

## Un banc côté Apple, et un chronomètre qui ne mesurait rien

Le dépôt avait un chiffre de vitesse — `wisq-bench`, 160 M inst/s — et il venait
d'un conteneur Linux x86_64. Rien ne mesurait la chaîne d'outils Apple, alors
que c'est celle qui part sur le téléphone.

Le programme de conformité d'ABI faisait déjà tout le travail : il boote un vrai
noyau, compte les instructions retirées, et `scripts/test-ios.sh` le lance
**dans un iPhone simulateur**. Il ne le chronométrait simplement pas. Un
`clock_gettime(CLOCK_MONOTONIC)` de part et d'autre du run, et le débit part
dans le journal du job Apple.

Pas de seuil, et c'est dit dans le code : un runner partagé n'en tient pas sans
clignoter, et un simulateur n'est pas un téléphone — même architecture sur Apple
Silicon, mais aucun plafond thermique et aucune pression mémoire. C'est une
borne haute et un détecteur de régression, pas un chiffre à citer.

### Le sabotage a trouvé l'erreur de signe du raisonnement

Quatre sabotages, un témoin. Deux attrapés — supprimer la ligne, rendre zéro
depuis l'horloge — et un survivant : **démarrer le chronomètre après le run**.

Mon test vérifiait `débit > 0 && est fini`. Or un chronomètre qui ne mesure rien
ne donne pas un petit nombre, il en donne un énorme : 400 millions
d'instructions divisées par quelques nanosecondes, soit 4 × 10¹⁶ par seconde. Le
test passait avec le sourire.

J'avais écrit la borne du mauvais côté. La borne utile est **haute** : dix
milliards d'instructions invitées par seconde sont impossibles d'un ordre de
grandeur sur n'importe quelle machine — un cœur retire au mieux 10¹⁰ de ses
*propres* instructions par seconde, et un interpréteur en dépense plusieurs par
instruction invitée. Au-dessus, c'est une horloge cassée, pas un ordinateur
rapide.

Deux sabotages relancés — le chrono qui démarre trop tard, et un `elapsed` figé
à une nanoseconde — deux attrapés.

Note de méthode, parce qu'elle m'a coûté dix minutes : `while pgrep -f
mon-script.sh` ne se termine jamais, parce que la ligne de commande du `pgrep`
contient elle-même le motif. Le harnais attendait un script déjà mort.

## Douze échappatoires, et ce qu'un verrou ne promet pas

Le paquet est en mode langage Swift 6 depuis un moment, sans avertissement. Il
reste douze `@unchecked Sendable` — l'endroit exact où le compilateur arrête de
vérifier et où quelqu'un affirme à sa place. Je les ai relus un par un.

Onze tiennent. Le motif est bon partout : un verrou réel plutôt qu'une promesse,
et `InflateStream` comme `ResumeOnce` expliquent déjà pourquoi. Mais deux d'entre
eux avaient le même défaut, et ce n'est pas le verrou qui manquait.

### Un verrou qui ne garde que les écritures ne garde rien

`Framebuffer` écrivait sous verrou et exposait `width`, `height` et `pixels` en
`public private(set)` — c'est-à-dire lisibles par n'importe qui, sans verrou.

Personne ne le faisait : le rendu passe par `snapshot()`, qui prend le verrou.
Mais c'est une habitude, pas une garantie, et ce qu'elle laisse ouvert n'est pas
un pixel périmé. Lire un `[UInt8]` sur un fil pendant qu'un autre l'agrandit avec
`replaceSubrange` est une lecture déchirée de la référence de tampon du tableau
lui-même. `@unchecked Sendable` est une promesse sur **tous** les chemins, pas
seulement sur ceux qui écrivent.

L'état est privé maintenant, et la seule façon de le regarder prend le verrou.
`size` rend une paire plutôt que deux propriétés : lues séparément, elles
pourraient enjamber un redimensionnement et décrire un écran qui n'a jamais
existé. `OutputCounter` du banc avait exactement la même forme sur son compteur
d'octets ; corrigé pareil.

### Et une vraie course, qui perdait des machines

`MachineStore.upsert` faisait `load()` puis `save()`, deux passages séparés dans
sa file. Deux écrivains lisent alors la même liste, écrivent chacun sa version,
et celui qui arrive second efface la machine de l'autre. Rien ne plante, rien
n'est journalisé : la machine que l'utilisateur vient d'ajouter n'est simplement
plus là.

La lecture, la modification et l'écriture tiennent désormais dans un seul
passage. D'où la paire `…OnQueue` privée : `DispatchQueue.sync` dans
`DispatchQueue.sync` sur une file sérielle se bloque, donc les opérations
composées ne peuvent pas appeler les `load` et `save` publiques.

Le test met vingt écrivains concurrents plutôt que deux, sur un vrai fichier
temporaire. Un entrelacement sur deux est un tirage à pile ou face ; vingt est
une certitude. Vérifié en remettant l'ancienne forme cinq fois de suite :
échec les cinq fois. Un test de concurrence qui n'attrape la faute qu'une fois
sur deux est un test qui rendra la CI clignotante et se fera désactiver.

## L'haptique, et la règle qui empêche le téléphone de devenir un vibreur

L'haptique existait déjà sur les gestes, derrière un réglage. Deux choses
manquaient, et une troisième était cassée sans que ça se voie.

**Le générateur n'était ni retenu ni préparé.** `UIImpactFeedbackGenerator(style:)
.impactOccurred()` sur une seule ligne crée un générateur froid : le moteur
Taptic doit se réveiller avant de jouer, ce qui met des dizaines de
millisecondes entre le doigt et la réponse. Sur un geste, c'est la différence
entre un téléphone qui répond au toucher et un téléphone qui tressaille après.
Et comme un générateur neuf n'est jamais chaud, c'était le cas à **chaque**
appui. Ils sont retenus maintenant, et rappelés à `prepare()` après usage.

**Rien ne signalait la connexion ni la coupure**, qui sont pourtant les moments
où le téléphone est dans une poche ou dans une main occupée à autre chose.

### La décision est sortie de la vue

`WisqUI` n'est pas construit sur Linux du tout — le `Package.swift` l'exclut.
Une règle écrite dans la vue est donc une règle qu'aucun runner d'ici ne peut
atteindre, et j'ai passé la journée à trouver ce que ça coûte.

`SessionEvent.haptic` vit donc dans `WisqRemote`, qui se teste ici. Il ne reste
dans la vue que la traduction vers `UINotificationFeedbackGenerator`, où il n'y
a rien à se tromper.

Quatre décisions, et trois portent sur le fait de **ne pas** vibrer :

* `.ready` mérite le tap — c'est ce que l'utilisateur attendait.
* **Seule la première tentative de reconnexion.** Un lien coupé réessaie tant
  que l'application est ouverte ; une vibration par tentative, c'est un
  téléphone qui bourdonne toutes les quelques secondes dans une poche jusqu'à
  vider la batterie. L'information est « la connexion a lâché », et elle est
  vraie une fois.
* **Raccrocher n'est pas une erreur.** `.disconnected(nil)`, c'est l'utilisateur
  qui ferme ; le lui redire avec le motif d'échec de la plateforme se lit comme
  « quelque chose a mal tourné ».
* Et la règle est écrite en liste blanche, pas en liste noire, à cause de
  `.framebufferChanged` : il arrive des dizaines de fois par seconde, et un
  `default` qui renverrait un haptique ferait du téléphone un vibreur pour toute
  la durée de la session. Un test l'énumère explicitement.

## Les tracés, et une propriété qui n'en prouvait que la moitié

`DRAW_STROKE` : un chemin, des attributs de ligne, une brosse, un descripteur de
rop, et aucune largeur de trait nulle part. Ce sont les stylos *cosmétiques* de
Windows — `canvas_draw_stroke` pose `lineWidth = 0` sans condition.

Le format ne vient pas de `draw.h`, qui ment sur trois points, mais du
démarshaller que la référence **engendre** depuis `spice.proto` : les drapeaux
d'un segment font un octet sur le fil et quatre en C ; `style_nseg` et `style`
n'existent que si `STYLED` est posé ; `@ptr_array` décrit le côté C et pas le
fil. Générer ce fichier a pris une minute et a répondu à trois questions que
j'aurais tranchées de travers.

### La bonne propriété, et ce qu'elle ne voyait pas

Le biais d'octant de X11 existe pour une raison précise : rendre une ligne
**réversible**. Bresenham doit trancher chaque fois que la ligne idéale passe
entre deux pixels, et trancher pareil partout ferait qu'une ligne A→B n'allume
pas les mêmes pixels que B→A. `DEFAULTZEROLINEBIAS` retire un à l'erreur
initiale dans quatre octants sur huit — les quatre inverses des quatre autres.

J'en ai fait mon test principal : un éventail de 1 680 lignes tracées dans les
deux sens, ensembles de pixels comparés. Ça teste toute la table plutôt qu'une
entrée, et le sabotage « biais nul » le fait échouer 595 fois. Bon test.

**Et il ne suffisait pas.** Un sabotage qui échange les rôles de x et de y dans
l'indice d'octant produit une *autre* table qui biaise toujours exactement un
membre de chaque paire de directions inverses. Elle reste donc parfaitement
réversible, et elle a survécu à la suite entière.

C'est une forme nouvelle du fil rouge de la journée. Les autres fois, le test
était trop faible. Ici il était *bon* — il tenait une vraie propriété, pour la
vraie raison — mais la propriété avait plus d'un modèle. Une invariance
n'identifie pas ce qu'elle laisse invariant.

La réponse est `scripts/spice-zero-line/`, qui transcrit `miZeroLine` et imprime
les coordonnées pour les pentes à égalité. L'asymétrie qui distingue les deux
tables se lit à l'œil dans sa sortie : `(0,0)→(8,4)` avance en y dès le premier
pas, `(0,0)→(-8,4)` attend un pas de plus. Le gabarit épingle ça.

Le conteneur est mort pendant le second passage de sabotage, en laissant
l'octant échangé en place — ce qui a permis de vérifier la correction en vrai
plutôt que par raisonnement : le gabarit échoue sur trois lignes, la
réversibilité reste verte. Exactement la lacune qu'il comble.

### Trois autres survivants, tous des valeurs neutres

  * **le rop lu avec la mauvaise étiquette** : `.source` au lieu de `.brush`.
    Tous mes tracés utilisaient `PUT` et `XOR`, des descripteurs sans bit
    d'inversion — et sans inversion les deux étiquettes donnent la même
    opération. Il faut un `INVERS_BRUSH` pour les séparer ;
  * **le cycle de tirets qui redémarre à chaque sommet** : mon test de
    pointillés n'avait qu'un segment droit, donc pas de second sommet. Deux
    segments et un coin le voient ;
  * **`ady > adx` au lieu de `ady >= adx`** : sur une diagonale parfaite les
    deux lectures allument les mêmes pixels, parce que le terme d'erreur reste
    positif quel que soit le biais. Vraie équivalence — mais la référence écrit
    `if (adx > ady) x-major else y-major`, donc l'égalité est y-majeure, et
    s'aligner coûte un caractère.

Dix-huit sabotages, treize attrapés du premier coup. Les quatre survivants ont
chacun produit un test qui les mord maintenant.

### Deux prémisses fausses avant d'y arriver

Deux fois un test a échoué et j'ai d'abord regardé le code : `−1/16` arrondit à
0, pas à −1 ; `−23/16` à −1, pas à −2. J'ai arrêté de calculer de tête et fait
évaluer la formule de la référence sur toute la plage. La règle réelle est plus
propre que ce que j'écrivais : **une demie va toujours vers moins l'infini**,
+0,5 → 0 et −0,5 → −1. Aucune fonction d'arrondi courante ne fait ça — ni « half
up », ni « half away from zero », ni « half to even ».

Et le parcours du chemin : `BEGIN` dépense son premier point comme *position*,
`CLOSE` n'agit qu'à l'intérieur d'un `END`, et fermer rejoint le premier point
de la figure accumulée. Ma première version se trompait sur les trois. Un
rectangle dessiné en un segment ne pouvait pas le voir ; une courbe l'a montré.

## Le texte, et le nombre de fois qu'un test peut expirer

`DRAW_TEXT` était le dernier message du canal display. Rien de conceptuellement
difficile — des glyphes matriciels, un fond, deux brosses — mais six pièges
dont aucun ne se devine, et une leçon sur les tests que je croyais avoir déjà
apprise trois fois.

Les pièges, tous tranchés par la référence : les deux points d'un glyphe
s'additionnent ; A1 et A4 complètent leurs rangées à l'octet et A8 pas du tout ;
les rangées se lisent du bas vers le haut quel que soit `TOP_DOWN` ; un quartet
A4 plein vaut 240 et pas 255 ; les glyphes se combinent par `max` ; et **aucun
des deux modes n'est une opération raster**, le fond étant un `COPY` et les
glyphes un `OVER`, ce que le commentaire de la référence assume franchement.

### Le test qui a expiré quatre fois

`testAMessageThisDoesNotHandleIsCountedByType` vérifie que la pompe compte les
messages qu'elle ne traite pas. Il lui faut donc un exemple de message non
traité. Il a nommé `streamCreate`, puis `drawStroke`, puis `drawText` — et
chaque fois que ce message a été implémenté, le test a cessé de tester le
compteur pour tester un décodeur qui échoue sur une charge bidon.

La dernière réécriture disait, dans son propre commentaire, « `DRAW_TEXT` est le
prochain à partir » — et l'utilisait quand même comme exemple principal.

La correction n'est pas un meilleur choix d'exemple, c'est un choix d'une autre
nature : `STREAM_ACTIVATE_REPORT` et `STREAM_REPORT` ne dessinent rien. Il n'y a
donc rien à implémenter, donc ils ne peuvent pas expirer. **Un test qui a besoin
d'un exemple de « pas encore fait » doit citer quelque chose qui ne sera jamais
fait**, sinon il périme au rythme du progrès.

### Cinq survivants, dont deux dans des tests écrits pour les attraper

Dix-huit sabotages, douze attrapés. Sur les six survivants, un était un sabotage
mal formé de ma part. Les cinq autres :

  * **l'ordre des bits A1** : mon octet de test était `0b1000_0001`, qui se lit
    pareil à l'endroit et à l'envers. Inverser l'ordre ne changeait rien ;
  * **le recouvrement des glyphes** : mon second glyphe avait une couverture
    *nulle* là où le premier était opaque, et le code saute les zéros avant
    d'écrire. Écraser et maximiser donnaient donc le même résultat. Il fallait
    une couverture faible mais non nulle ;
  * **la chaîne sans profondeur** : mon test demandait seulement que « quelque
    chose » soit lancé, et le repli silencieux sur huit bits lançait aussi —
    une troncature, parce qu'il manquait des octets. Même vert, autre raison ;
  * **le fond peint même quand `back_area` est vide** : un rectangle vide ne
    coupe rien et ne peint rien de toute façon. La différence n'apparaît qu'avec
    une brosse de fond que ce client ne sait pas peindre : vérifier la brosse
    avant la vacuité refuse tout le message — donc pas de texte du tout — pour
    une brosse qui n'allait servir à rien. C'est le cas courant du texte
    transparent ;
  * **le bit de `TOP_DOWN`** : il est décodé et jamais utilisé, donc rien ne
    pouvait voir sa valeur bouger. Épinglé en toutes lettres, comme les autres
    constantes venues d'ailleurs.

Les deux premiers sont la même chose que la veille : **une valeur neutre choisie
sans y penser**. La nouveauté est qu'ils étaient dans des tests que j'écrivais
précisément pour fermer ce genre de trou. Le réflexe « ce test attrape-t-il ce
qu'il dit ? » ne suffit pas ; il faut se demander « quelle entrée sépare les
deux lectures », et vérifier que la mienne en est une.

C'est aussi arrivé sur les tirets, la veille : j'avais écrit un test de coin pour
attraper un cycle qui redémarre, avec un segment long d'exactement une période.

## Le son, et un test qui échouait pour une raison qui n'était pas la sienne

Le canal `playback` de SPICE est petit : sept messages, un codec d'état, du PCM
signé seize bits. Il est écrit comme `TransportTuning` — une valeur qui décide
tout ce qui se décide sans haut-parleur (quel codec est en vigueur, si un paquet
est jouable, combien de trames il porte, si c'est muet), et rien de plus. Ce qui
reste à la plateforme, c'est de donner les trames à AVAudioEngine.

Onze sabotages sur onze attrapés du premier coup, ce qui n'était jamais arrivé.
Deux raisons, je crois : le domaine est petit, et j'ai écrit les tests en
cherchant l'entrée qui sépare les deux lectures plutôt qu'en illustrant le code.
`0x0102` et `0x0201` sont des nombres différents ; `0x0101` ne l'aurait pas été.

Un douzième sabotage a survécu, et il ne portait pas sur l'audio : faire buzzer
le téléphone à chaque paquet audio. `SessionHapticTests` ne connaissait pas le
nouveau cas. La liste blanche de `SessionHaptic` avait pourtant fait son travail
— ajouter `.audio` à `SessionEvent` casse la compilation du `switch` et rend la
question inévitable — mais elle force à *répondre*, pas à *tester la réponse*.
Une liste blanche empêche l'oubli ; elle n'empêche pas une mauvaise réponse.

### Le test avait raison de tomber, pour la mauvaise raison

Le test de bout en bout — une trame qui part du fil et sort par le flux
d'événements — a échoué trois fois de suite, et aucune n'était le canal audio.

D'abord : `AsyncStream` ne supporte qu'une itération. Mon test attendait
`.ready`, puis attendait `.audio` sur le même flux ; la seconde boucle ne rend
rien.

Ensuite, et c'est le plus intéressant : le faux serveur d'affichage épuisait sa
socket, la pompe display terminait la session, et le flux d'événements se
fermait. La trame audio était produite *après*, dans une continuation close, et
disparaissait. Le canal marchait depuis le début — les diagnostics montraient
les deux messages lus et décodés — mais l'échafaudage du test le tuait avant
qu'il ait fini de parler.

C'est une variante de plus du fil rouge : un test peut être rouge sans que le
code soit faux, exactement comme il peut être vert sans que le code soit juste.
Les deux fois, ce qu'on croit mesurer n'est pas ce qu'on mesure. J'ai d'abord
soupçonné le décodage, et il a fallu imprimer les octets de l'en-tête pour voir
que tout se passait bien.

La correction est que le faux serveur continue de parler — cent messages ignorés
— plutôt qu'un `sleep` qui aurait rendu le test lent et lunatique.

## Le micro, et un garde-fou que j'ai écrit puis retiré

Le canal `record` complète l'audio : le serveur décrit le flux qu'il veut, et
c'est le client qui envoie. Trois asymétries avec la lecture, toutes dues à la
direction : `RECORD_START` n'a pas de champ `time` — un serveur qui demande un
enregistrement n'a pas d'horloge à donner, les échantillons du client portent la
leur ; le client choisit le codec, donc il n'y a qu'un choix honnête, `raw` ; et
un nouveau flux réannonce ce codec, là où `STOP` le garde côté lecture. La
lecture garde parce que le serveur ne renvoie rien ; l'enregistrement réannonce
parce que c'est nous qui décidons.

### Le garde-fou redondant

`Cœur (Apple)` et `App iOS` sont tombés sur `SessionModel.apply`, qui aiguille
exhaustivement sur `SessionEvent` — et `WisqUI` est exclu de la construction
Linux, donc le cas `.audio` ajouté la veille n'y compilait pour la première fois
que dans les jobs Apple. Deuxième fois cette nuit que cette classe de panne
passe.

J'ai écrit un fichier de test qui aiguille sur les onze cas, pour que Linux voie
le prochain. Puis je l'ai vérifié — en ajoutant vraiment un cas — et il ne
servait à rien : `SessionHaptic` casse **déjà** la compilation Linux dans ce cas,
et casse en premier, donc mon fichier n'était jamais atteint. Un garde-fou
redondant qui prétend garder ce qu'il ne garde pas est exactement ce que cette
semaine passe son temps à corriger, alors je l'ai retiré et j'ai mis la consigne
là où le compilateur s'arrête vraiment.

C'est la même discipline que le sabotage, appliquée à un garde-fou plutôt qu'à un
test : est-ce qu'il *pourrait* échouer pour la raison que j'annonce ? Ici, non.
La chose utile n'était pas un second détecteur mais une phrase, dans le fichier
qui casse en premier, nommant le fichier qu'aucun job Linux ne compile.

### Cent messages de bourrage ne sont pas une correction

Le test de bout en bout du micro passait seul et échouait dans la suite. La cause
était celle de la veille : le faux serveur d'affichage épuise sa socket, la pompe
termine la session, le flux d'événements se ferme. J'avais « corrigé » ça la
veille en bourrant la socket de cent messages ignorés — ce qui rend la course
improbable sans la supprimer, et une course improbable est une course qui tombe
sous charge.

Un flux de test qui **attend** au lieu de finir la supprime, parce que c'est ce
que fait une vraie socket quand le serveur n'a rien à dire. Trois passages verts
d'affilée, là où le bourrage donnait un vert seul et un rouge en suite. Le
premier correctif avait la bonne intuition et la mauvaise forme.

## Trois fois la même leçon dans le même fichier

`scripts/verify.sh` s'annonce ainsi : « tout ce que la CI ferait, en une seule
commande — pour qu'un contributeur obtienne le même verdict localement, avant de
pousser ». Il porte déjà deux commentaires qui racontent chacun une fois où
c'était faux : il ne lançait pas le linter, puis il ne savait pas lancer
SwiftLint sur Linux. Les deux fois, une PR a rougi pour quelque chose qui se
voyait en une seconde.

Troisième fois cette nuit. J'ai poussé une tranche, puis mis à jour le nombre de
tests annoncé dans le commit *suivant* — et le commit intermédiaire a fait
rougir « Build site », une porte que ce script prétendait couvrir. Il ne
construisait pas le site du tout.

La suite du site n'est d'ailleurs pas seulement à propos du site :
`claims.test.ts` lit **ce dépôt** et échoue quand un chiffre annoncé cesse
d'être vrai. C'est la garde que j'ai réparée en début de nuit en retirant un
filtre `paths:` pour qu'elle tourne sur toutes les poussées — et elle tournait
bien, mais seulement après la poussée.

Vérifié plutôt qu'espéré : chiffre faussé à 999, la suite du site échoue ; chiffre
remis, elle passe.

La forme de l'erreur est la même que celle du garde-fou redondant retiré une
heure plus tôt, retournée comme un gant. Là, j'avais ajouté un détecteur qui ne
détectait rien parce qu'un autre cassait avant lui. Ici, il manquait un détecteur
parce qu'un script qui disait « tout » ne disait pas tout. Dans les deux cas la
question utile est la même, et elle n'est pas « est-ce que ça passe » : c'est
**« qu'est-ce que ceci attraperait, et qu'est-ce qui l'attrape déjà »**.

## Une capacité non annoncée, et du code que le serveur ne pouvait pas atteindre

En relisant ce qui restait après la complétude du canal display, j'ai regardé
les capacités que wisq annonce à la liaison. Il y en avait deux :
`preferredCompression` et `lz4Compression`.

Or `STREAM_DATA_SIZED`, implémenté et testé hier soir, est **conditionné côté
serveur**. `dcc-send.cpp` calcule si l'aire source d'une image diffère de la
géométrie de son flux et, quand c'est le cas et que le client n'a pas annoncé
`SPICE_DISPLAY_CAP_SIZED_STREAM`, fait `return FALSE` — il n'envoie pas l'image
du tout. Pas « il l'envoie en version simple » : il la laisse tomber. Une région
qui a besoin d'être redimensionnée cesse simplement de se mettre à jour.

Donc le code des images dimensionnées était inatteignable face à un vrai
serveur, et son absence coûtait des images perdues. Un test l'affirmait même
explicitement — `XCTAssertFalse(supports(.sizedStream))` — avec une raison qui
était vraie le jour où elle a été écrite : wisq ne traitait pas encore ces
images. Une prémisse de plus qui a expiré sans que rien ne le signale, et
celle-ci était du côté « nous ne savons pas faire » d'une promesse qui n'était
plus vraie.

### Et une absence qui, elle, porte quelque chose

Dans la même lecture : `dcc_create_video_encoder` saute **tout codec non-MJPEG**
pour un client qui n'annonce pas `MULTI_CODEC` — « Old clients only support
MJPEG », dit son commentaire. MJPEG est le seul codec que wisq décode.

Ne pas annoncer `multiCodec` n'est donc pas un oubli : c'est ce qui garantit que
le serveur ne choisira jamais un codec que ce client ne sait pas lire. Quelqu'un
qui l'ajouterait en se disant que plus de capacités vaut mieux obtiendrait
exactement le symptôme que le canal des flux existe pour éviter — un rectangle
figé là où ça bouge. C'est écrit dans le code et dans le test, parce qu'une
absence délibérée qui n'est pas expliquée finit par être « corrigée ».

La leçon générale : **une capacité annoncée est une affirmation sur ce client, et
elle se périme dans les deux sens**. On surveille celles qu'on annonce sans
savoir faire ; celles qu'on sait faire sans les annoncer sont plus discrètes,
parce que le symptôme est du côté du serveur.

## Un commentaire qui décidait, sur une prémisse morte

Dans la foulée de la capacité manquante, j'ai relu le commentaire qui choisit
quoi demander comme compression. Il disait, pour justifier `autoLZ` plutôt
qu'`autoGLZ` : « `autoGLZ` peut encore produire du GLZ, qui est refusé ».

GLZ n'est plus refusé depuis que sa fenêtre circule dans la pompe. `.glzRGB` et
`.zlibGlzRGB` se décodent, avec leurs propres tests. La phrase qui portait la
décision était donc fausse — et c'est pire qu'un commentaire périmé ordinaire,
parce que celui-ci **est** le raisonnement : personne relisant ce fichier
n'aurait de raison de rouvrir la question.

Deux tiers du dossier pour basculer se vérifient dans la référence :
`get_compression_for_bitmap` ne garde `GLZ` que pour les formats qui ont une
gradualité, ce que les formats palettisés n'ont pas — donc les formes GLZ-palette
que ce client refuse ne peuvent pas arriver sous `autoGLZ`. Sa sortie entière est
QUIC, GLZ-RGB, LZ ou non compressé, tous décodés. Et le gain est exactement ce
pourquoi GLZ existe : un dictionnaire partagé entre les images d'un canal.

Le tiers manquant m'a arrêté : `initialise()` déclare une fenêtre GLZ de **zéro
pixel**, et `dcc_handle_init` passe ce nombre tel quel à
`glz_enc_dictionary_create`. Ce que fait un dictionnaire de taille nulle, je ne
peux pas le vérifier ici — `glz_encoder_dictionary.c` n'est pas dans les sources
vendues. Demander à un serveur de compresser contre une fenêtre qu'on lui a dit
vide n'est pas une chose à changer au jugé, et c'est une optimisation de bande
passante, pas une correction.

Alors le comportement ne bouge pas et le commentaire dit maintenant la vérité :
ce qui est établi, ce qui ne l'est pas, et que la taille de fenêtre et la
préférence doivent bouger ensemble. La règle que j'en tire : **un commentaire qui
justifie un choix vieillit plus mal qu'un commentaire qui décrit un mécanisme**,
parce qu'il reste plausible longtemps après que sa raison a disparu — et qu'il
décourage précisément la relecture qui le corrigerait.

## Le fichier existait, sous un autre nom

Suite immédiate de l'entrée précédente, et elle commence par une erreur à moi.

J'avais écrit que le tiers manquant du dossier ne pouvait pas être tranché parce
que « `glz_encoder_dictionary.c` n'est pas dans les sources vendues ». Le fichier
est là. Il s'appelle `glz-encoder-dict.c` — des tirets, pas des tirets bas, et un
nom abrégé. J'avais cherché le nom que j'avais supposé, obtenu zéro résultat, et
transformé ce zéro en fait sur le monde.

C'est la même faute que celle qui consiste à lire une pastille verte au lieu du
journal : **une recherche qui ne trouve rien ne dit rien sur ce qui existe, elle
dit quelque chose sur la requête.** Le coût ici a été une décision reportée d'une
tranche entière, avec un commentaire qui expliquait soigneusement pourquoi elle
ne pouvait pas être prise.

## Zéro n'était pas une petite fenêtre

Le fichier trouvé, la question s'est retournée. Je cherchais « est-ce que ça
compresse mal ». La réponse est ailleurs :

    if ((uint32_t)new_image_size > dict->window.size_limit) {
        dict->cur_usr->error(dict->cur_usr, "image is bigger than window\n");
    }

`glz_dictionary_pre_encode` appelle ça en tête de chaque encodage GLZ. Ce
`error` est `glz_usr_error` dans `image-encoders.cpp`, qui appelle
`spice_critical`, qui — `spice_logv` dans `log.c` — appelle `abort()`. Une
fenêtre plus petite qu'une image ne dégrade rien : elle **tue le processus
serveur**.

Et wisq n'était pas protégé par sa préférence. `reds.cpp` initialise la
compression à `AUTO_GLZ`. Un serveur qui n'annonce pas `preferred_compression`
ne reçoit jamais notre message — `compressionToRequest` renvoie `nil` à dessein —
et garde donc GLZ toute la session. Le `nil` était traité dans le code comme le
cas sans conséquence ; c'était le cas dangereux. Je l'avais même écrit sans le
voir : le commentaire mentionnait « les images qui partent avant que ce message
arrive » à propos de LZ4, deux paragraphes plus bas.

Alors j'ai compilé la référence plutôt que de la croire. `scripts/spice-glz-window/`
donne des fenêtres choisies à l'encodeur réel. Une image 64×64 : propre à 4096,
abandon à 4095. La borne est stricte, et elle change la nature du nombre — il ne
faut pas « une fenêtre non nulle », il faut **une fenêtre au moins aussi grande
que la plus grande image**. C'est pourquoi la constante vaut `1 << 23` et non un
chiffre choisi pour l'historique qu'il garderait : la résolution de l'invité
n'est pas connue quand `DISPLAY_INIT` part, donc le seul choix disponible est
« une image entière, quelle qu'elle soit ». Sans le harnais j'aurais mis une
valeur non nulle plausible et j'aurais reproduit le bug sur les grands écrans.

Trois sabotages le tiennent : la fenêtre remise à zéro, l'entier écrit en
gros-boutiste, et la valeur mise à 8 294 399 — un pixel sous 3840×2160. Les
trois échouent. Le test de disposition passait `0` pour ce champ, ce qui ne
vérifiait aucun ordre d'octets ; il passe maintenant `0x0A0B_0C0D`. Encore une
valeur neutre trouvée dans un test écrit pour vérifier quelque chose.

La leçon : **deux nombres de même forme, dans le même message, peuvent avoir des
régimes d'erreur opposés.** Le cache de pixmaps est un budget qui s'évince et se
dégrade ; la fenêtre GLZ est un plancher qui abandonne. Rien dans le message, ni
dans le nom des champs, ni dans leur type, ne distingue les deux. Ce qui les
distingue est à trois fichiers de là, dans du code que le client n'exécute
jamais.

## Le nombre inoffensif ne l'était pas non plus

Écrit quelques heures après l'entrée précédente, et elle la corrige.

En traitant la fenêtre GLZ j'ai regardé l'autre nombre du même message — le
cache de pixmaps — pour établir le contraste, et j'ai conclu : celui-là est un
budget, `dcc_add_to_cache` évince et renvoie `FALSE`, une valeur trop basse ne
coûte que de la bande passante. Je l'ai écrit dans le code, dans la feuille de
route et dans le commit.

C'était vrai, et ça ne répondait pas à la question. J'avais examiné ce qui
arrive quand le nombre est **trop petit**, parce que c'est là que la fenêtre GLZ
faisait mal. Personne n'avait regardé dans l'autre sens.

wisq annonçait 4 Mi pixels de cache et n'a pas de cache. Le pilote QXL de
l'invité marque `QXL_IMAGE_CACHE` ce qu'il compte redessiner ; le serveur
l'enregistre, renvoie `CACHE_ME` **seulement si l'enregistrement a réussi**, et
tout envoi ultérieur du même identifiant devient `SPICE_IMAGE_TYPE_FROM_CACHE` :
un nom, zéro pixel. `pixels(of:)` renvoie `nil`, le dessin est sauté, la région
garde ce qu'il y avait dessous. Des pixels périmés, en silence, sur les icônes
et les glyphes — c'est-à-dire sur ce qu'un bureau répète le plus.

Annoncer zéro suffit : le premier ajout rend `available` négatif, la boucle
d'éviction trouve un anneau vide, l'ajout échoue, et plus rien n'est jamais
nommé.

Deux leçons, et la seconde est la vraie.

**La première**, celle que je croyais tenir : deux nombres de même forme dans le
même message peuvent avoir des régimes d'erreur opposés. C'est exact, et
insuffisant, parce que je l'ai formulée en comparant *un* échec de chacun.

**La seconde** : un paramètre a deux bords, et vérifier l'un n'apprend rien sur
l'autre. La fenêtre GLZ m'avait entraîné à demander « et si c'est trop petit ? ».
J'ai posé cette question au cache, obtenu une réponse rassurante, et rangé le
dossier. La question « et si c'est trop grand ? » n'a jamais été posée — pas
parce qu'elle était difficile, mais parce que la première avait l'air d'avoir
épuisé le sujet. Une réponse rassurante à la mauvaise question ressemble
exactement à une réponse rassurante.

C'est la même faute que le fichier introuvable de l'entrée précédente, sous un
autre angle : là, une recherche vide prise pour un fait sur le monde ; ici, une
vérification partielle prise pour une vérification. Dans les deux cas le tort
n'est pas d'avoir eu faux, c'est d'avoir arrêté de chercher au moment où
quelque chose avait l'air conclu.

Le contraste est maintenant tenu par des tests des deux côtés, et la feuille de
route dit ce que le paragraphe d'il y a quelques heures affirmait trop vite.
Reste le vrai gain, qui n'est pas une correction : construire le cache, avec ses
invalidations, pour qu'une icône parte une fois au lieu de vingt.

## Un champ lu et jeté depuis le début

Le cache d'images est construit, et ce qui l'a rendu intéressant n'est pas le
cache.

En cherchant comment le serveur dit au client d'oublier une image, je suis tombé
sur une bifurcation :

    if (dcc->is_mini_header()) {
        send_free_list(dcc);          // un message INVAL_LIST ordinaire
    } else {
        send_free_list_legacy(dcc);   // sous-marshaller + set_header_sub_list
    }

wisq lit l'en-tête de dix-huit octets. C'est donc toujours la seconde branche :
l'`INVAL_LIST` ne voyage pas comme un message, il voyage **à l'intérieur** d'un
autre, à un décalage noté dans un champ de l'en-tête. Et `SpiceWire.DataHeader`
décode `subList` depuis le premier jour sans que rien ne le lise jamais.

Sans conséquence jusqu'ici, par un accident heureux : avec un cache annoncé nul,
le serveur n'évince rien et n'envoie donc aucune invalidation. Les deux dettes
se couvraient l'une l'autre. Corriger la première sans voir la seconde aurait
donné un client qui garde des images que le serveur a oubliées — c'est-à-dire
qui redessine une vieille icône à la place de la nouvelle, exactement le
« pire qu'une image réémise » que la tâche annonçait sans savoir à quel point
elle avait raison.

La leçon, et c'est la troisième forme de la même cette nuit : **un champ décodé
n'est pas un champ lu.** Le format était juste, l'analyseur était juste, la
valeur arrivait intacte jusqu'à une structure — et personne ne s'en servait. Il
n'y avait rien à corriger dans le code existant, ce qui est précisément
pourquoi rien ne l'avait signalé. Un grep sur `subList` donnait deux résultats,
tous deux dans le fichier qui le définit.

## La sonde jetable qui a trouvé ce que le test n'aurait pas trouvé

Un de mes tests a échoué et j'ai failli le corriger. Au lieu de ça j'ai écrit
une sonde de dix lignes qui imprimait ce que l'analyseur faisait vraiment. Il
renvoyait une liste **vide** au lieu de lever une erreur.

La cause n'était pas dans le test : j'avais mis dans l'analyseur un
`guard offset != 0 else { return [] }`, en confondant deux choses. Le zéro
« il n'y a pas de liste » appartient au champ d'en-tête ; mais l'autre porteur,
`SPICE_MSG_LIST`, place sa liste au tout début de son corps, où zéro est un
décalage parfaitement réel. La branche que je venais d'écrire pour lui ne
pouvait donc rien retourner, silencieusement.

Un test l'aurait attrapé si j'en avais écrit un pour cette branche-là. Ce qui
l'a attrapé, c'est d'avoir demandé « qu'est-ce qui se passe *vraiment* » plutôt
que « comment rendre ce test vert ». La différence entre les deux questions vaut
d'être notée : la seconde a toujours une réponse, et elle est souvent d'affaiblir
l'assertion.

## Un sabotage qui survit n'est pas toujours une ligne fausse

Retirer le filtre de type sur la liste d'invalidation a survécu à la suite
entière. Les quatre cas à trancher, et c'est le quatrième : branche
inatteignable avec un serveur conforme. `dcc_push_release` n'a qu'un appelant et
il passe toujours `SPICE_RES_TYPE_PIXMAP` ; les palettes sont invalidées par
leurs propres messages.

J'ai gardé le filtre et ajouté le test qui le distingue, plutôt que de le
retirer comme « code mort ». La raison est dans le protocole et pas dans le
serveur d'aujourd'hui : la liste est typée et `SPICE_RESOURCE_TYPE_ENUM_END`
annonce une énumération faite pour grandir. Les identifiants de palettes et
d'images viennent d'espaces différents, donc la collision n'est pas improbable,
elle est une question de temps.

C'est le cas de figure où « le test ne pouvait pas être rouge » ne veut pas dire
« la ligne ne sert à rien ». Il veut dire : aucun serveur existant ne produit
l'entrée qui les sépare. Écrire cette entrée à la main est alors tout le travail.

## Le cache qu'on ne peut pas refuser, et une sévérité mal estimée

Le cache de palettes est le jumeau de celui des images, à une différence près :
il n'y a pas de taille à annoncer. `CLIENT_PALETTE_CACHE_SIZE` est une constante
du serveur et `DISPLAY_INIT` n'a pas de champ pour elle. La solution de la
tranche précédente — annoncer zéro et laisser le serveur se retenir — n'existe
tout simplement pas ici.

J'avais classé la conséquence comme « des pixels périmés », par analogie avec le
cache d'images. C'était faux, et c'est un test qui me l'a dit : il a échoué avec
`threw error "missingPalette"` là où j'attendais un dessin sauté. `SpiceBitmap`
lève pour un format palettisé sans couleurs, et une erreur levée **arrête la
pompe**. Donc toute image nommant une table déjà envoyée ne coûtait pas un
dessin : elle coupait la session.

L'analogie m'avait fait recopier la sévérité en même temps que la forme. Les
deux caches ont la même structure et des conséquences d'un ordre différent — et
je n'aurais pas vérifié si le test ne s'était pas plaint, parce que j'avais déjà
« compris » le problème.

Reste que la distinction que le dépôt tenait ailleurs était la bonne réponse :
un nom qu'on ne sait pas résoudre part là où part un codec non décodé — compté,
écran laissé tranquille, connexion gardée — tandis qu'une image qui ne porte
aucune table et n'en nomme aucune lève toujours, parce qu'elle se contredit
elle-même. La règle existait ; il fallait juste ranger ce cas du bon côté.

## Deux bêtises de manipulation, notées pour ne pas les refaire

**Un `EOF` dans un message de commit.** J'ai rédigé le corps du commit de fusion
de #66 comme si je l'écrivais dans un heredoc de shell, alors qu'il partait dans
un appel d'API. Le marqueur de fin s'est retrouvé dans le message, sur master.
Je ne le corrige pas : réécrire l'historique de master est une de mes
interdictions, et le coût du dégât est cosmétique.

**Un `git checkout` pour défaire un sabotage.** Le sabotage portait sur une
ligne ; `git checkout <fichier>` a rendu le fichier entier à son état de master
et emporté tout le travail non commis qu'il contenait. Le build l'a dit tout de
suite, et il a fallu réécrire les deux ajouts.

La règle que j'aurais dû suivre est déjà dans ma routine — *garder une
sauvegarde et vérifier la restauration* — et je l'appliquais correctement pour
les autres fichiers de la même série. Ce qui l'a fait sauter, c'est d'avoir
changé d'outil en cours de route pour un fichier : `cp` depuis la sauvegarde
partout, sauf là. **Une procédure qu'on applique « en général » n'est pas une
procédure.**

## Une absence qui tient, une absence qui coûtait

Troisième tour de l'audit « qu'est-ce que ce client promet, et tient-il chaque
promesse ». Cette fois la réponse est mitigée, et les deux moitiés valent d'être
notées ensemble parce qu'elles se ressemblent de l'extérieur.

Seul le canal display annonçait des capacités. Sur les canaux audio, le jeu vide
avait deux conséquences opposées :

* **ne pas annoncer de codec est correct.** `snd_desired_audio_mode` rend `RAW` à
  qui ne réclame pas Opus, et CELT n'est plus dans le chemin. L'annoncer
  rendrait l'audio muet — wisq n'ayant pas de décodeur Opus. Même forme que le
  `multiCodec` absent du display ;
* **ne pas annoncer le volume coûtait.** `snd_send_volume` et `snd_send_mute`
  refusent d'envoyer sans la capacité, donc quatre décodeurs testés n'étaient
  jamais atteints par le fil.

Deux absences, même apparence, verdicts inverses. Ce qui les sépare n'est pas
dans le code du client : c'est ce que le serveur fait du silence. Pour le codec
il retombe sur ce qu'on sait lire ; pour le volume il se tait.

## Un test qui échoue mal cache tous les autres

Le sabotage « calcule les capacités mais ne les passe jamais » — l'état exact
d'avant cette tranche — a bien fait échouer mon test. Puis le processus a
plaqué : `Fatal error: Index out of range`, et la suite s'est arrêtée là. Le
compte affiché était de 4 tests au lieu de 803.

La cause est dans mon test : `XCTAssertFalse(caps.isEmpty)` n'interrompt pas
l'exécution, donc la ligne suivante indexait un tableau vide. Corrigé en
`XCTUnwrap`, le même sabotage donne « 803 tests, 1 échec ».

Ce qui m'a sauvé, c'est d'avoir regardé le nombre de tests exécutés et pas
seulement le nombre d'échecs. « 3 échecs » et « 3 échecs sur une suite
interrompue au quart » s'affichent presque pareil, et le second ne prouve rien
sur les trois quarts restants. C'était déjà dans ma routine — *vérifier que le
seuil « suite interrompue » suit la taille réelle de la suite* — et c'est la
première fois que ça sert vraiment.

Corollaire pour les tests eux-mêmes : **une assertion douce suivie d'un accès
indexé est un plantage en puissance.** Dans une suite, un test qui plante n'est
pas un test qui échoue — il emporte le verdict de tous les autres.

## Le chemin que personne d'autre n'emprunte

Quatrième tour de l'audit des promesses. Ce qui a attiré l'œil n'est pas un
symptôme : c'est une asymétrie.

`push_agent_connected` choisit entre deux messages selon une capacité. spice-gtk
l'annonce toujours ; wisq ne l'annonçait pas. Donc **le chemin que wisq
empruntait à chaque fois était celui que le client de référence n'exerce
jamais** — jamais testé par personne, jamais vu en production ailleurs. C'est
une raison suffisante de l'examiner, indépendamment de tout bug soupçonné. Je la
garde comme heuristique : *quand la référence et nous prenons des branches
différentes, c'est la nôtre qui est la moins éprouvée, et ce n'est pas
symétrique.*

Il y avait bien un défaut au bout : après un redémarrage de l'agent, le serveur
rend au client tout son quota de jetons de son côté et ne peut le dire que dans
le message que wisq ne recevait pas. À zéro jeton, le presse-papiers ne repart
jamais.

## Mon test a corrigé mon affirmation

J'avais écrit, dans le test et dans le commentaire du code, qu'à zéro jeton
« rien ne part ». Le test a échoué : `AGENT_START` part quand même, parce que
c'est un message du canal principal et qu'il ne coûte pas de jeton.

La formulation juste est plus intéressante que celle que j'avais : la poignée de
main **réussit**, et seule la donnée d'agent reste bloquée — à commencer par
l'annonce de capacités du client. L'invité voit donc un client s'attacher puis
ne jamais dire ce qu'il sait faire. Inerte plutôt que cassé, ce qui est la pire
des deux.

J'ai corrigé le test et le commentaire ensemble. C'est la deuxième fois cette
nuit qu'un test refuse une affirmation trop large que j'allais publier — la
première étant `missingPalette`. Les deux fois, la version exacte était plus
utile que l'approximation : elle disait *où* ça casse, pas seulement *que* ça
casse.

Corollaire de méthode : quand un test contredit une phrase que j'ai écrite, la
première hypothèse doit être que la phrase est fausse, pas le test. Les deux
fois, c'était la phrase.

## Clore un filon plutôt que de s'en éloigner

Cinq tranches sont sorties d'une seule question posée à chaque canal SPICE :
qu'est-ce que ce client promet, et tient-il chaque promesse ? Après la dernière
(les jetons de l'agent), j'ai fait le tour des deux canaux restants — curseur et
entrées — et ils ne demandent rien : le premier n'a aucune capacité dans le
protocole, le second en a une que le serveur annonce et que wisq n'utilise pas.

Le réflexe aurait été de passer à autre chose sans le dire. J'ai écrit le tableau
des six canaux dans la feuille de route à la place, parce que **« épuisé » et
« abandonné » se ressemblent beaucoup vus de loin**, et que la différence est
exactement ce qu'on ne peut plus reconstituer plus tard. Un lecteur qui trouve
quatre canaux corrigés et deux jamais mentionnés doit refaire l'enquête ; un
lecteur qui trouve six lignes dont deux disent « rien à faire, voici pourquoi »
n'a rien à refaire.

C'est le pendant d'une leçon de cette nuit : un commentaire qui *justifie* vieillit
mal. Un inventaire qui *constate* vieillit bien, parce qu'il est vérifiable ligne
par ligne contre la référence.

## Vérifier son propre travail quand on ne se souvient pas de l'avoir fait

Au réveil sur un événement CI, j'ai trouvé une PR ouverte, un commit poussé et
une branche à un état que je n'avais pas en tête — la dernière chose que j'avais
vue de ce code était une erreur de compilation.

La bonne réaction n'était ni de faire confiance à la PR ni de la refaire : c'était
de reconstruire et relancer la suite localement à ce commit précis, puis de
comparer au journal brut de la CI. 806 tests des deux côtés, le même saut attendu.
Alors seulement, fusionner.

La règle générale : **un état qu'on n'a pas vu se produire se traite comme un
état rapporté par quelqu'un d'autre.** On le vérifie contre la source primaire,
et le fait que ce soit soi-même qui l'ait produit ne change rien à la
vérification.

## L'audience nommée dans un commentaire, et jamais servie

Le `Cargo.toml` de l'agent dit, mot pour mot, que c'est « un démon que les gens
installent sur un NAS avec un `curl` d'une ligne ». La release ne produisait que
deux binaires : Linux x86_64 et macOS arm64. Un NAS ARM, un Raspberry Pi, un Mac
Intel — trois machines très ordinaires — tombaient sur `install_from_source`,
qui exige une toolchain Rust que ces machines n'ont aucune raison de porter.

Ce qui rend le défaut difficile à voir, ce n'est pas qu'il soit subtil : c'est
que **les deux moitiés étaient cohérentes entre elles**. L'installateur demandait
exactement les deux assets que le workflow construisait. En lisant l'un ou
l'autre, tout va bien. Le trou n'apparaît qu'en tenant les deux listes à côté de
la liste des machines réelles, et cette troisième liste n'était écrite nulle part.

La leçon n'est pas « vérifier la matrice ». C'est que **deux fichiers d'accord
l'un avec l'autre ne prouvent rien sur le monde** — ils prouvent seulement qu'ils
sont d'accord. Un accord n'est une preuve que lorsqu'une des deux moitiés est
elle-même contrainte par l'extérieur, et ici aucune ne l'était.

Le garde-fou ajouté (`scripts/check-release-matrix.sh`) ne corrige donc pas le
bug ; il corrige la *rechute*. C'est une distinction qu'il vaut mieux garder
nette : le bug se corrige en ajoutant deux architectures, le garde-fou empêche
seulement que les deux listes se séparent de nouveau en silence. J'ai sabordé le
script dans les deux sens, plus une troisième fois en réintroduisant exactement
le bug d'origine, avant de le croire.

## Un chemin qui ne s'exécute qu'au pire moment

Le workflow de release ne tournait que lorsqu'on coupait une release. Tout ce
qu'il contient — quatre constructions, un empaquetage, deux portes de test —
n'était donc jamais exercé *avant* le moment où il compte. Une faute dedans se
découvrait en publiant, c'est-à-dire à l'instant précis où l'on ne veut découvrir
rien du tout.

L'entrée `dry_run` existe pour ça : tout se construit, tout se vérifie, rien ne
se publie. Ce n'est pas un raffinement de confort. C'est la différence entre un
fichier qu'on a lu et un fichier qu'on a vu tourner, et j'ai passé la nuit à
répéter que ce n'est pas la même chose.

Le détail qui décide de la sûreté de cette entrée est l'expression de garde :
`if: ${{ !inputs.dry_run }}`. Sur un `push` de tag, `inputs.dry_run` n'existe pas,
donc l'expression vaut vrai et la publication a lieu — le chemin historique est
intact. Il fallait vérifier ce sens-là, pas seulement celui du dry run : une
garde qui protège trop transforme une release en silence, et le silence est le
mode d'échec qu'on ne voit pas passer.

## Ce que la vérification a coûté, et pourquoi c'était le bon prix

Pour affirmer que l'agent se construit en aarch64, j'aurais pu écrire le job et
faire confiance au YAML. J'ai plutôt installé un cross-gcc, découvert que
`gcc-aarch64-linux-gnu` seul va chercher `/usr/include` de l'hôte et meurt sur
`bits/libc-header-start.h`, ajouté `libc6-dev-arm64-cross`, lié avec `rust-lld`,
et fait tourner le binaire sous `qemu-aarch64-static`. Il répond `--help`, en
1,4 Mo, statique.

Ces quatre échecs sont maintenant des commentaires dans le workflow, et c'est là
tout l'intérêt : chacun est une chose que la CI aurait découverte à ma place, un
essai à la fois, dans un contexte où je ne serais pas là pour la lire. **Le coût
d'une vérification locale n'est pas comparé à zéro ; il est comparé au coût de
la même découverte faite plus tard, par quelqu'un d'autre, avec moins de contexte.**

## Le garde-fou qui signalait la panne et rendait zéro

Écrit d'abord ainsi :

```sh
mappings=$(
  expect_asset Darwin arm64 macos-arm64
  ...
) || failed=1
```

Sabordé, il a imprimé exactement le bon message d'erreur — et rendu 0. En CI,
cela veut dire vert, message d'erreur compris, personne ne le lit.

La cause est une règle de bash qu'on connaît sans y penser : `set -e` est
suspendu pour toute une liste `&&`/`||`, **sous-shell compris**. Le `$( )` fait
partie d'une commande dont l'échec est testé, donc l'`expect_asset` du milieu
n'interrompt plus rien ; la substitution finit par rapporter le statut du
*dernier* appel, qui réussissait. Le `|| failed=1` ne s'exécutait jamais.

Deux choses à en retenir, et la seconde compte plus que la première.

La première : accumuler les échecs explicitement, un `|| failed=1` par appel,
dans le shell courant. C'est plus verbeux et c'est trivialement lisible.

La seconde : **j'ai trouvé ce défaut parce que je lisais le code de sortie, pas
la sortie.** Le message d'erreur était parfait. Tout ce qui s'affichait à l'écran
disait « le garde-fou fonctionne ». C'est la même erreur que la nuit où un test
qui plantait le runner rapportait 4 tests au lieu de 803 : dans les deux cas la
sortie visible était convaincante et le seul chiffre qui comptait était ailleurs.
Saborder ne suffit pas — il faut saborder *et regarder le bon indicateur*.

## Deux garde-fous qui semblent le même, et n'attrapent pas la même faute

Comparer deux listes comme des *ensembles* laisse une faute entièrement
invisible : une correspondance qui utilise un nom parfaitement existant, pour la
mauvaise machine. Écrire

```sh
Darwin/arm64)  ASSET_SUFFIX="macos-x86_64" ;;
Darwin/x86_64) ASSET_SUFFIX="macos-arm64" ;;
```

et les deux ensembles restent rigoureusement identiques, pendant que chaque Mac
Apple silicon télécharge un binaire Intel. Vérifié : sabordé ainsi, la
comparaison d'ensembles ne dit rien du tout, et seule la table exercée parle.

C'est le même piège que le tableau des six canaux fermait côté protocole : une
liste cohérente n'est pas une liste juste. Un ensemble dit *quels* noms existent
des deux côtés ; il ne dit rien de *qui reçoit quoi*. Il fallait les deux
vérifications, et je n'avais écrit que la première — jusqu'à ce qu'une sonde
jetable, lancée pour tout autre chose, imprime la table et rende la question
évidente.

## Chercher au mauvais endroit parce que la liste le disait

La liste d'optimisations demandait « WebP » pour le site. J'ai commencé par
mesurer avant d'obéir : toutes les images du site pèsent **12 Ko réunies** — cinq
icônes et une carte sociale. Les convertir en WebP aurait économisé peut-être
3 Ko. Le vrai poids était ailleurs, dans un seul fichier : 207 Ko de JavaScript,
66 Ko une fois gzippé, soit cinq fois toutes les pages HTML du site réunies.

La leçon n'est pas « la liste avait tort ». Une liste d'optimisations écrite de
l'extérieur nomme des *techniques* — WebP, découpe de bundle, Lighthouse — parce
que c'est tout ce qu'on peut nommer sans avoir mesuré. Elle ne peut pas nommer le
poste dominant, puisque le poste dominant est justement ce que la mesure
découvre. **Prendre la liste comme un plan, c'est optimiser ce que quelqu'un
pouvait deviner de loin.** La prendre comme une direction — « le site est trop
lourd » — et mesurer, c'est trouver que le framework est le poste.

## Ce que ça coûte, dit avant qu'on me le demande

Retirer l'hydratation fait tomber le script de 65 794 à 1 062 octets gzip. Le
chiffre est spectaculaire et c'est exactement pour ça qu'il faut écrire à côté ce
qu'il coûte : **on n'ajoute plus un composant interactif en écrivant du JSX.**

Cette phrase est dans le README du site et dans le changelog, pas seulement dans
ma tête. Un gain de 98 % qui arrive sans sa contrepartie se relit dans six mois
comme un cadeau, et la première personne qui voudra un onglet interactif
découvrira la contrainte en la heurtant. Une contrainte qu'on documente est une
décision ; une contrainte qu'on laisse découvrir est un piège.

## Un garde-fou qui mesure la taille ne mesure pas le travail

Après le changement, j'avais un test qui vérifiait que le script pèse moins de
3 Ko gzip, et un autre que React n'y est plus. Les deux passaient.

**Un script vide les aurait passés tous les deux.** C'est la forme exacte du
piège : j'avais remplacé le mécanisme qui *faisait* les quatre comportements, et
tous mes tests portaient sur le poids du remplaçant, aucun sur son travail.

D'où `tests/behaviour.test.ts` : la vraie page construite, le vrai module livré,
et on appuie sur les boutons. Puis les neuf sabotages — le clic de thème
n'applique plus rien, la redirection ignore le choix du lecteur, l'invite iOS
s'affiche pour tout le monde — dont chacun est attrapé. Sans ça j'aurais annoncé
un gain de 98 % sur un sélecteur de thème qui ne sélectionne plus.

La règle, plus générale que ce cas : **quand on remplace un mécanisme, les tests
du remplaçant doivent porter sur ce que faisait le mécanisme, pas sur ce qui a
motivé le remplacement.** J'avais mesuré la motivation.

## Deux plafonds pour la même ligne

Le test de budget existait déjà : 240 000 octets bruts, 80 000 gzip. Il était
vert avant le changement et il serait resté vert après, puisque 1 062 est très
en dessous de 80 000.

Un plafond taillé pour un bundle qui hydrate laisse passer, en silence, la seule
régression qui compte désormais : réimporter un composant dans `main.ts`, ce qui
remet soixante-quatre kilooctets. Le garde-fou aurait continué d'exister, de
tourner, et de ne rien garder.

**Un seuil est un fait sur le code d'hier.** Quand le code change d'ordre de
grandeur, laisser le seuil en place n'est pas de la prudence, c'est le désarmer —
et ça ne se voit pas, parce qu'un test qui passe ressemble à un test qui garde.

## Un garde-fou qui recopie le défaut qu'il protège

Deux sabordages n'ont pas mordu dans `scripts/serve.ts`, et tous deux sont le
cas 3 — équivalence réelle — pour la même raison de fond.

Le premier : supprimer la ligne `if (path.endsWith("sw.js")) return "no-cache";`
ne change rien, parce que le repli en fin de fonction rend `"no-cache"` lui
aussi. Le second : supprimer l'en-tête `content-type` explicite ne change rien
non plus, parce que Bun déduit exactement les mêmes valeurs depuis l'extension —
y compris `.webmanifest`, celle dont on douterait.

La conclusion facile serait « ces deux lignes sont mortes, on les enlève ». Elle
est fausse, et le sabordage suivant le montre : en rendant le repli `immutable`,
la suite casse **neuf** tests avec la ligne `sw.js` présente et **onze** sans.
Les deux de différence sont ceux du service worker — c'est-à-dire la panne qui
est définitive plutôt que lente, un worker figé qu'aucun déploiement ne
rattrape.

D'où la règle : **un garde-fou qui recopie le défaut qu'il protège ne se teste
pas en le retirant, seulement en changeant le défaut.** Le retirer laisse tout
vert, ce qui ressemble à « inutile » et signifie en réalité « les deux chemins
coïncident aujourd'hui ». La question n'est jamais « mon sabordage a-t-il rendu
la suite rouge », c'est « quelle entrée distingue les deux versions » — et ici
l'entrée n'est pas un chemin de requête, c'est une modification du repli.

Les deux lignes restent, avec la mesure écrite à côté d'elles. Une redondance
constatée et datée est une décision ; une redondance qu'on laisse croire
porteuse est un piège pour le prochain lecteur, qui la refactorisera en pensant
ne rien casser.

## L'optimisation qui vise le mauvais consommateur

La liste demandait « images en WebP ». J'avais d'abord répondu « ça ne vaut pas
le coup, tout pèse 12 Ko ». C'était vrai et c'était le mauvais argument.

En regardant vraiment, le site construit ne contient **aucune balise `<img>`**.
Les cinq PNG existent, mais aucun n'est demandé pendant l'affichage d'une page :
trois sont lus par l'installateur du système via le manifeste, un par l'écran
d'accueil iOS, un par les robots d'aperçu de lien. Convertir ne ferait donc
économiser zéro octet à un lecteur — et ces consommateurs-là sont précisément
ceux dont la prise en charge du WebP est la moins sûre.

L'argument par la taille (« 12 Ko, c'est petit ») aurait pu être renversé par un
site qui grossit. Celui-ci ne peut pas l'être : tant que les images servent à
l'OS et aux robots plutôt qu'à la page, le format qui les rend rapides à charger
n'est pas la question. **Un « non » adossé à une mesure de taille est provisoire ;
un « non » adossé à la nature du consommateur tient.**

## Choisir l'instrument avant de choisir la réponse

Le dernier point de la liste d'optimisations demandait « UnsafePointer,
intrinsics ARM » pour les décodeurs. La tentation était d'écrire le code et
d'annoncer un gain. Ce conteneur est partagé : n'importe quel chiffre que j'en
sortirais serait du bruit habillé en résultat.

Ce qui a débloqué la tranche n'est pas une réponse mais un **instrument** :
l'identité de tampon. `array.withUnsafeBufferPointer { $0.baseAddress }` répond
à « y a-t-il eu une copie ? » par oui ou non, de façon déterministe, et la
réponse ne bouge pas parce qu'un autre processus s'est réveillé. Avec ça, la
question « les décodeurs sont-ils serrés ? » devient vérifiable :

- la trame décodée traverse `rowsTopDown` avec **la même adresse** quand le flux
  est déjà top-down — zéro copie sur le cas courant ;
- elle en change une fois, et une seule, quand il faut la retourner ;
- elle survit au passage en tuple `(pixels:width:height:)` sans changer
  d'adresse — le COW tient.

La leçon générale : **quand la mesure évidente est indisponible, la bonne
réaction n'est pas de renoncer à la question ni de mesurer quand même, c'est de
chercher une propriété observable qui décide de la même chose.** « Combien de
temps » était hors de portée ; « combien de copies » ne l'était pas, et pour la
question posée — les décodeurs gaspillent-ils du travail — c'était la meilleure
des deux.

Ce qui reste vraiment hors de portée est dit comme tel dans la feuille de route :
les pointeurs non sûrs et les intrinsics NEON demandent un iPhone. Du code plus
difficile à lire, adopté sur la foi d'un chiffre invérifiable, est une dette
qu'on ne peut plus rembourser faute de savoir ce qu'elle a acheté.

## Un test qu'on écrit puis qu'on supprime

J'avais écrit un test affirmant « la sortie LZ est réservée une fois, jamais
agrandie ». Il compilait, il passait. Je l'ai enlevé.

Il ne pouvait pas échouer pour la raison que son nom donnait. Le compte décodé
est le même que le tableau ait été dimensionné une fois ou agrandi dix fois, et
`capacity` n'est pas une promesse — Swift peut l'arrondir. Ce que le test
vérifiait réellement, c'était que la taille finale est correcte, ce que
`SpiceLZTests` prouve déjà en comparant chaque flux de référence à la sortie de
l'encodeur.

**Un test redondant n'est pas neutre : il est pire que rien.** Il se lit comme
une couverture d'une affirmation que rien ne tient réellement, et le prochain
lecteur qui voudra vérifier cette affirmation le trouvera, le croira, et
s'arrêtera là. La réservation exacte reste vraie et reste écrite — dans la
feuille de route, comme un fait lisible dans le code, pas déguisée en test.

## Lire le bon indicateur, encore

Troisième sabordage de la tranche : retirer la garde qui refuse une trame
tronquée. Ma boucle de sabordage a imprimé « BUILD FAILED », ce qui était faux —
le code compilait très bien.

En relançant seul et en capturant correctement, le vrai résultat : `Fatal error:
Array index is out of range`, code de sortie **1**, et seulement deux tests
rapportés avant que le processus meure. La garde est donc bien porteuse.

Deux pièges dans la même minute, tous deux déjà consignés ici et refaits quand
même : `$?` après un pipe est le statut de `tail`, pas celui de `swift test` ; et
une suite qui plante n'imprime pas la ligne « Executed N tests », donc un
harnais qui cherche cette ligne conclut au mauvais échec. Le fil rouge, une fois
de plus : **l'indicateur qu'on lit décide de ce qu'on croit.**

## Le défaut qui blesse le client honnête avant l'attaquant

L'analyseur HTTP de l'agent acceptait `Transfer-Encoding: chunked`, jetait le
corps, et répondait **200**. J'ai d'abord classé ça avec les trois autres trouvailles
— en-têtes de cadrage contradictoires, primitives de *request smuggling* — puis
j'ai vu que ce n'était pas la même chose du tout.

Les trois autres demandent un attaquant *et* un proxy inverse devant le démon.
Celui-là ne demande rien : n'importe quelle bibliothèque HTTP qui décide de
diffuser un corps envoie du chunked, et l'appelant reçoit alors « 200, c'est
fait » pour une action que le démon a exécutée sans les données. Un démarrage de
VM avec un corps vide, annoncé comme réussi.

La leçon de tri : **une faille et un bug de conformité ne se rangent pas par
gravité théorique mais par ce qu'il faut réunir pour qu'ils mordent.** Le
smuggling a besoin d'un attaquant, d'un proxy et d'une réutilisation de
connexion ; le chunked avalé a besoin d'un client qui fait son travail
normalement. Le second arrive en premier, et arrivera même si personne n'attaque
jamais ce démon.

Corollaire pour la posture : un serveur qui n'implémente pas quelque chose doit
le **refuser**, pas faire comme si ça n'avait pas été demandé. 501 est une
réponse ; 200 sur un corps disparu est un mensonge.

## Le test s'est trompé avant le code

Écrit d'un trait, mon test exigeait qu'un `Content-Length: 5 ` — avec un espace —
soit refusé. Il a échoué. Mon premier réflexe a été de regarder le correctif.

Le correctif avait raison. La RFC 9112 place un espace optionnel autour de la
valeur de *tout* champ, donc ` 5` et `5 ` sont un cinq ordinaire, et l'analyseur
nettoie avant de valider — le bon ordre. C'est mon attente qui était fausse, et
la refuser aurait cassé des clients conformes.

Ce qui m'a évité de « corriger » du code correct, c'est que le test échouait sur
une valeur précise que le message nommait. Un test qui aurait juste dit
« Content-Length invalide accepté » m'aurait laissé chercher dans le code
pendant que l'erreur était dans le test.

D'où deux choses gardées : le message d'échec cite la valeur exacte, et un test
séparé affirme désormais l'inverse — que l'espace est accepté. **Quand un
sabordage ou un échec vous surprend, la première hypothèse à tester est que la
mauvaise ligne est celle qu'on vient d'écrire.** J'ai maintenant deux occurrences
cette nuit où la sur-correction était le vrai risque, pas le défaut.

## Trois fois le même angle mort : le test qui n'inspecte que la fin

Troisième occurrence cette nuit, et cette fois j'ai reconnu le motif avant
d'écrire le correctif plutôt qu'après.

- La branche `sw.js` de `serve.ts` rendait la même chose que son repli : la
  supprimer ne cassait rien, parce que le test lisait le résultat, pas le chemin.
- Le test de réservation LZ que j'ai supprimé ne pouvait pas échouer pour la
  raison de son nom : le compte final est le même que le tableau ait été
  dimensionné une fois ou agrandi dix fois.
- Et ici : `the_key_is_not_world_readable` lit le mode **après** l'écriture. Or
  `fs::write` puis `set_permissions(0600)` finit à 0600 tout autant qu'un `open`
  déjà en 0600. Le test passait pendant toute la durée de la course, et il
  repasserait le jour où quelqu'un la réintroduit.

Le motif commun : **un test qui n'inspecte que l'état final ne peut rien dire de
ce qui s'est passé au milieu.** Et l'état final est ce qu'on inspecte
spontanément, parce que c'est ce qui est facile à lire.

Ce qui a rendu celui-ci corrigeable, c'est d'avoir cherché un instrument capable
de voir le milieu : un fil qui interroge le fichier en boucle pendant l'écriture.
J'ai d'abord mesuré s'il mordrait, au lieu de l'écrire en espérant. 747
observations non-0600 sur 100 tours contre zéro — la fenêtre fait environ sept
`stat` de large. Un test qui ne l'aurait attrapée qu'une fois sur dix aurait été
pire que rien.

Et la vérification décisive n'est pas que mon nouveau test échoue quand je
saborde : c'est que **l'ancien, lui, continue de passer**. C'est ça qui prouve
qu'il était aveugle, et pas seulement que le nouveau est sensible.

## Le build est vert, clippy ne l'est pas

`cargo build` n'a rien signalé de mes deux nouvelles fonctions. `cargo clippy
-- -D warnings` a refusé les deux : `unneeded return statement`, dans les blocs
`#[cfg(unix)]` où j'avais écrit `return Ok(());` pour sortir avant la variante
non-Unix.

La bonne forme existait déjà dans ce fichier, sous mes yeux : `set_owner_only`
était écrite en **deux fonctions entières annotées `#[cfg]`**, pas en une seule
avec des blocs à l'intérieur. J'ai inventé une tournure là où la maison en avait
déjà une.

Deux choses. D'abord : *build vert ≠ portes vertes*, et les portes de ce dépôt
sont fmt, clippy strict et les tests, pas le compilateur. Ensuite, et c'est le
plus utile : après la réécriture, **j'ai refait le sabordage**. Le code n'était
plus le même que celui que j'avais prouvé ; une preuve porte sur un texte précis,
pas sur une intention. Elle est restée valide, mais je ne le savais pas avant de
relancer.

## Deux 404 qui ne veulent pas dire la même chose

Sabordage : j'enlève la liste blanche de caractères qui valide l'identifiant de
VM. La suite reste **verte**. Six sabordages, cinq mordent, celui-là passe.

Diagnostic, cas 2 — test manquant. Mon test affirmait `status == 404` pour des
identifiants hostiles. Or `DemoBackend` répond lui aussi 404, « VM introuvable »,
pour n'importe quel nom qu'il ne connaît pas. Les deux réponses portent le même
statut, donc l'assertion passait quel que soit le chemin emprunté : refus de
validation ou simple absence. Le test avait l'air de vérifier un refus ; il
vérifiait « pas trouvé ».

Ce qui les sépare est le *message*. Le test le lit maintenant, et le sabordage
mord.

La leçon dépasse le cas : **un code de statut est un canal trop pauvre pour
distinguer deux raisons de refuser.** Et ce n'est pas un défaut du protocole —
répondre 404 pour un nom invalide est le bon choix, il ne faut pas révéler si la
VM existe. C'est un défaut du *test*, qui doit regarder plus finement que le
client n'a le droit de le faire.

À rapprocher de la liste de la nuit : la valeur neutre qui rend deux
implémentations égales par accident, la garde de disponibilité qui rend tout
vert sans rien exécuter. Même famille — **une observation trop grossière pour
séparer deux mondes**.

## Sur-corriger est un défaut à part entière, et il se saborde aussi

Sur six sabordages de cette tranche, **trois** consistaient à rendre la
validation trop stricte : refuser le point, le tiret interne, les majuscules.
Les trois font tomber des tests, parce qu'une troisième famille de tests affirme
que `debian-12.local`, `VM1` et `win11-dev.example.com` continuent de passer.

C'est devenu un réflexe cette nuit et il vaut d'être nommé : **quand on ajoute
un refus, la moitié du travail de test porte sur ce qu'il ne faut pas refuser.**
Un validateur qui bloque l'attaque et casse `debian-12.local` a remplacé un
problème de sécurité par un problème de disponibilité, et le second se remarque
plus vite mais ne se pardonne pas mieux.

C'est la troisième fois du cycle : les espaces autour d'un `Content-Length`
(légaux, mon premier test les refusait à tort), les en-têtes de cache (refuser
`no-store` partout aurait été aussi faux que tout accepter), et maintenant les
noms de domaine. Le motif : **une règle a deux bords, et le sabordage doit
pousser des deux côtés.**

## Deux moitiés qui s'accordent chacune avec un littéral

Le jeton d'appairage traverse deux codecs écrits à la main : `percent_encode`
côté Rust, `URLComponents` côté Swift. Les deux étaient testés. Le Rust
vérifiait que sa sortie contenait `token=a%20b%26c%3Dd` ; le Swift vérifiait
qu'analyser une URL écrite à la main rendait `a&b=c d/é+?#`. **Chaque moitié
s'accordait avec une chaîne que quelqu'un avait tapée. Aucune n'avait jamais
rencontré l'autre.**

`AgentEndToEndTests` avait l'air de combler ce trou et ne le comblait pas : il
lance le démon avec `--token secret-token` et s'authentifie avec le même
littéral, sans jamais lire le lien. Et `secret-token` est de toute façon la
mauvaise sonde — lettres et tiret, tous « unreserved », donc il traverse
`percent_encode` inchangé et passerait encore si la fonction rendait son
argument.

Cinq sabordages. Trois mordent pour de bon, mais **deux d'entre eux étaient déjà
couverts** : `percent_encode` rendu identité fait tomber le test Rust existant,
et un parseur Swift qui lit les valeurs encodées fait tomber le test Swift
existant. Le nouveau test ne les rattrape qu'en second.

Celui qui compte est le troisième : **encoder par caractère au lieu d'octet**.
`for c in value.chars()` avec `%{c as u32:02X}` produit `%E9` pour `é` au lieu
de `%C3%A9` — du Latin-1 dans une URL. Les *quatre* tests Rust de `pairing`
restent verts : leur littéral, `a b&c=d`, est en pur ASCII. Le décodeur Swift,
lui, rend `nil`, et le jeton disparaît. C'est exactement la divergence qu'aucune
moitié seule ne peut voir, et il fallait un caractère non-ASCII dans la sonde
pour la révéler.

Retenir la sonde, pas seulement le test : `a&b=c d/é+?#` porte un caractère par
classe de décision — `&` et `=` terminent une valeur, l'espace est illégal, `/`
`+` `?` `#` veulent dire quelque chose à quelqu'un, et `é` fait deux octets.
Le `é` est le seul qui ait servi.

## Le sabordage qui ne mordait pas parce que je visais la mauvaise ligne

Cinquième sabordage : « le harnais ignore le jeton demandé ». J'ai écrit
`self.token = "secret-token"` au lieu de `self.token = token` — les deux tests
restent verts.

Cas 1, mauvaise ligne, et il est instructif : le paramètre `token` a **deux**
usages indépendants dans `RustAgentProcess`, la propriété et l'argument
`--token` passé au démon. Mes tests ne lisent que le second. J'avais cassé
l'usage que personne ici ne regarde. Refait sur `"--token", "secret-token"`, les
deux tests tombent.

La règle, encore : *une preuve porte sur un texte précis*. « Saborder le jeton »
n'est pas une action, c'est une intention ; il y avait deux lignes derrière.

## Un `defer` dans un test `async` qui tourne à 100 % d'un cœur

Écrit d'abord `defer { agent.stop() }`, comme `AgentTLSTests` le fait déjà. Le
test s'est mis à tourner sans jamais finir, sans un message, **après que sa
dernière assertion soit passée**.

Le chronomètre ne disait rien ; la pile, tout. `gdb -p` sur le processus figé :

```
#4  Process.waitUntilExit          (dans __CFRunLoopModeIsEmpty)
#6  RustAgentProcess.stop          RustAgentProcess.swift:134
#7  ...$deferL_                    AgentPairingRoundTripTests.swift:78
```

Sur Linux, `Process.waitUntilExit()` fait tourner une boucle d'exécution. Hors
du thread principal, elle ne se termine pas : elle tourne. Le `defer` d'un test
**synchrone** s'exécute sur le thread principal — d'où `AgentTLSTests` qui
passe. Celui d'un test `async` s'exécute sur un worker de la concurrence.
`AgentEndToEndTests` y échappait sans le savoir, en libérant le démon dans
`tearDown()`, que XCTest appelle sur le thread principal.

Deux choses valent d'être gardées. La première est écrite dans le code, sur
`stop()`, parce que le prochain à écrire un test d'agent la rencontrera.

La seconde est de méthode : **un test qui ne finit pas n'est pas un test lent.**
La tentation était d'augmenter un délai ou de relancer. Trente secondes de
`gdb` ont donné la ligne exacte, le thread exact et la raison — là où
« réessayer » aurait donné une deuxième attente de dix minutes et rien d'autre.

## Une limite que rien ne pouvait atteindre

Parti auditer ce qui survit à une reconnexion SPICE. Rien ne survit, et c'est
doublement tenu : les surfaces, les caches et la fenêtre GLZ sont des variables
**locales** de la pompe, et `ReconnectingSession` ne réutilise jamais l'objet
session — `makeSession(framebuffer)` en fabrique un neuf à chaque tentative.
Hypothèse morte.

Ce qui l'a remplacée est venu d'un sabordage qui n'a pas fait ce que j'attendais.
J'avais rendu le contexte zlib partagé entre connexions pour vérifier qu'un test
neuf le voyait ; au lieu d'échouer, la suite s'est **figée**. Trois minutes de
`gdb` : le thread principal attendait dans le pont async de XCTest et **aucun
thread n'exécutait mon test**. Pas une boucle serrée — une boucle de
reconnexion.

Le défaut, une ligne :

```swift
case .ready:
    attempt = 0        // « une connexion réussie recharge le budget »
```

`.ready` est émis dès la fin de la poignée de main. **Tout** serveur l'émet, y
compris celui qui la termine et meurt une milliseconde après. Le compteur
repartait de zéro à chaque cycle, donc `maxAttempts` n'était **jamais**
atteignable pour toute cette classe de pannes — et ce sont exactement celles
pour lesquelles la politique existe. Mesuré : `maxAttempts` à 3, treize
reconnexions et toujours en cours quand la sonde a coupé.

Le second effet est pire que le premier. `attempt` valant 1 après chaque remise
à zéro, `delay(forAttempt: 1)` rendait `initialDelay` indéfiniment : le repli
exponentiel n'avait pas lieu non plus. Sur un téléphone, une poignée de main
complète par seconde, jusqu'à la batterie, sans qu'aucune erreur ne remonte à
personne.

**Atteindre `.ready` ne peut pas être le critère, parce que le cas pathologique
l'atteint aussi.** *Durer*, si : une connexion qui est restée debout assez
longtemps pour servir a prouvé que l'hôte fonctionne, ce que le budget cherche
à savoir. La remise à zéro sort de la boucle d'événements — la durée d'une
connexion n'est connue qu'une fois qu'elle est finie.

Trois conditions, trois sabordages, un par test, plus un témoin :

| sabordage | test qui tombe |
|---|---|
| remettre `attempt = 0` sur `.ready` | le serveur qui meurt après la poignée de main |
| ne jamais recharger le budget | la connexion qui a duré |
| garder la durée, jeter `reachedReady` | la poignée de main lente et ratée |
| renommer une variable (témoin) | aucun |

Le troisième mérite d'être noté : les deux premiers tests ne le distinguent pas,
parce qu'une connexion qui meurt dans la poignée de main meurt aussi *vite* —
les deux conditions s'accordent partout sauf sur une poignée de main qui traîne
puis échoue. Il a fallu écrire un `ByteStream` qui prend son temps avant
d'abandonner pour séparer ces deux mondes.

## La sonde qui a servi n'était pas celle que j'avais écrite

Le sabordage « le contexte zlib est partagé » visait un test que je venais
d'écrire sur l'état du décodeur après reconnexion. Il n'a jamais répondu à cette
question : il a révélé un défaut sans rapport, dans le composant d'à côté.

À garder : **un sabordage n'est pas seulement une vérification, c'est une
perturbation**, et une perturbation explore le système au-delà de la propriété
qu'on visait. Le réflexe utile n'est pas « ce sabordage ne mord pas comme prévu,
je le corrige » mais « pourquoi le système fait-il *ça* ». Ici la différence
entre les deux lectures était un défaut de disponibilité en production.

Et, deuxième fois de la journée : **un test qui ne finit pas n'est pas un test
lent.** La première fois, `gdb` a donné un `defer` sur un thread de concurrence.
Cette fois, une boucle de reconnexion sans fin. Les deux auraient été invisibles
en augmentant un délai.

## Une garde qui plante en calculant ce qu'elle allait refuser

Quatre gardes de SPICE ont la même forme :

```swift
guard width > 0, height > 0, width * height <= LIMITE
```

`width` et `height` sont des `Int(...)` construits depuis des `UInt32` venus du
fil. `UInt32.max²` vaut 1,8 × 10^19 ; `Int.max` vaut 9,2 × 10^18. Swift piège au
débordement, en `-O` comme ailleurs. **La garde meurt en calculant le produit
qu'elle s'apprêtait à comparer.** Douze octets sur le fil —
`SURFACE_CREATE` avec deux champs à `0xFFFFFFFF` — et l'application disparaît :

```
*** Swift runtime failure: arithmetic overflow ***
  1  SpiceSurfaces.create(_:) in WisqRemote/SPICE/SpiceSurfaces.swift:80:44
```

La colonne 44 est le `*`.

Ce qui rend le cas intéressant n'est pas le débordement, c'est **pourquoi
personne ne l'avait vu**. Les gardes *sont* testées. `SpiceSurfacesTests` et
`SpiceStreamsTests` affirment toutes deux un refus, dans des tests nommés « une
taille qu'aucun téléphone ne peut contenir est refusée avant toute
allocation ». Elles s'arrêtent à `0xFFFF`. 65535² tient largement dans un
`Int`, donc la garde répond, donc le test est vert — un ordre de grandeur avant
la valeur qui tue.

C'est un motif déjà consigné ici, dans une autre formulation : *les nombres
venus d'ailleurs s'écrivent aux deux bouts de leur plage*. Le bout haut d'un
`UInt32` n'est pas « un grand nombre », c'est `0xFFFFFFFF`. Un test qui choisit
sa propre idée de « grand » teste son auteur, pas le type.

### Le correctif se démontre plutôt qu'il ne se plaide

Borner chaque côté avant de multiplier, comme `SpiceQUICDecoder` le fait déjà
trois fichiers plus loin — reprendre la tournure de la maison plutôt qu'en
inventer une, leçon du sabordage clippy sur `tls.rs`.

Et l'argument qui rend le correctif sûr sans avoir à discuter : les deux clauses
ajoutées **acceptent et refusent exactement ce que la troisième acceptait et
refusait déjà**. Avec les deux côtés ≥ 1, un côté qui dépasse le plafond met le
produit au-dessus du plafond. Aucune entrée légitime ne change de sort ; seul
le calcul devient possible. Ce n'est pas une opinion sur le bon plafond, c'est
une équivalence.

### Le sabordage qui a survécu, et ce qu'il a montré

Cinq sabordages, quatre mordent d'emblée. Le cinquième — remettre la
multiplication nue **uniquement** sur la trame *sized* de `SpiceStreams`, en
laissant celle de la création correcte — laisse la suite entière verte.

Cas 2, test manquant, et le pire des deux à manquer : la trame sized est celle
qu'un serveur hostile peut envoyer **à tout moment** pendant une vidéo, pas
seulement à la création du flux. Son test existait ; il s'arrêtait à `0xFFFF`
comme les autres. Étendu, le sabordage mord.

À retenir de la mécanique : **sabordez chaque site séparément.** Mon premier
patch remplaçait les deux occurrences du même texte d'un coup ; il mordait, et
ce rouge venait entièrement du premier site. Un sabordage groupé donne une
réponse groupée, et une garde non couverte se cache derrière la garde couverte
d'à côté.

### Un rouge peut être un plantage

Ces sabordages ne font pas échouer un test : ils tuent le processus, SIGILL,
code 132. Prévu et noté d'avance, ce qui a évité de le lire comme une panne du
harnais. Un harnais de sabordage qui ne regarde que « combien de tests ont
échoué » compte zéro échec sur une suite qui n'a jamais fini.

## Le commentaire avait raison sur le danger et tort sur la conclusion

Dans le parseur de bitmaps, sur la ligne qui calcule la longueur des pixels
inline :

```swift
// Multiplied as `Int` after both are widened, so a server sending a
// stride and a height that overflow a `UInt32` gets a read past the
// end rather than a small number and a buffer that fits.
let size = Int(stride) * Int(height)
```

Tout ce que le commentaire affirme est exact. Élargir vers `Int` bat bien le
repliement d'un `UInt32` — sans lui, un produit qui reboucle donnerait un petit
nombre et un tampon qui « rentre », ce qui est la vraie mauvaise issue. Ce qu'il
ne dit pas, c'est qu'élargir ne protège pas du débordement de la cible : les
deux champs montent à `0xFFFFFFFF`, le produit atteint 1,8 × 10^19, et Swift
piège. **La ligne écrite pour se défendre d'une longueur hostile était le point
de plantage.**

C'est la deuxième fois de la journée qu'une défense se retourne, après les
quatre gardes de #80. La forme commune vaut d'être nommée : *le raisonnement
s'arrête à la menace qu'on avait en tête*. L'auteur pensait « repliement », a
écrit la parade au repliement, et l'a écrite correctement. Personne ne relit un
commentaire juste en se demandant de quoi il ne parle pas.

### Rapporter plutôt que borner

Correctif différent de #80, et la différence est le point :

```swift
let (size, sizeOverflowed) = Int(stride).multipliedReportingOverflow(by: Int(height))
guard !sizeOverflowed else { throw SpiceError.invalidData }
```

Pas de plafond. La maison en a un — `SpiceLZ4` et `SpiceQUICDecoder` bornent
tous deux `width` et `height` à `1 << 15` avant de multiplier — et **je ne l'ai
pas repris ici**, alors que reprendre la tournure de la maison est d'habitude la
bonne règle. La raison : ces plafonds-là *restreignent*. Sur les sites de #80,
ajouter une borne par côté ne changeait le sort d'aucune entrée, ce qui rendait
le correctif indiscutable. Ici, un plafond serait une supposition sur ce qu'un
vrai serveur envoie, et je n'ai aucun moyen de la vérifier depuis ce conteneur.

`multipliedReportingOverflow` n'en suppose rien. Tout produit calculable est
inchangé ; un produit incalculable est refusé — exactement ce qu'une longueur
trop grande obtient déjà une ligne plus loin, puisqu'aucun message ne fait
10^19 octets. Le comportement est identique partout où il était défini.

**La leçon n'est pas « toujours reprendre la maison ».** C'est : reprendre la
maison quand la maison répond à la même question. Ces deux formes répondent à
des questions différentes — « quelle taille est raisonnable » et « ce produit
est-il calculable » — et seule la seconde se pose ici.

### Ce que je n'ai pas corrigé, et comment je l'ai su

`SpiceLZ.pixels(fromIndices:)` a la même forme (`bytesPerRow * height`, puis
`width * height * 4`) et **ne déborde pas**. Son en-tête lit les dimensions en
`Int32` *signé* — `Int(Int32(bitPattern:))`, positif obligatoire — donc chaque
côté plafonne à 2,1 × 10^9 et le premier produit à 4,6 × 10^18, sous `Int.max`.
Le second produit est plus grand, mais il n'est atteint qu'après une garde qui
exige `indices.count >= bytesPerRow * height` : pour le faire déborder il
faudrait un tableau de 2,9 × 10^17 octets.

Cas 3 pour la garde, cas 4 pour l'allocation. Le détail qui décide est un
`bitPattern` : le même code lu sur des `UInt32` déborderait. **Deux sites de
forme identique, un sûr et un pas, et ce qui les sépare est le type de la
lecture, pas la forme de l'expression.** Chercher la forme n'aurait pas suffi.

## Un danger décrit dans un fichier, laissé nu dans celui d'à côté

`SpiceAgentChannel` porte, sur le commentaire de son drapeau `draining`, une
description exacte d'un défaut :

> il est lu pour construire un message et incrémenté après le retour de
> l'écriture, donc un second drain entrant à ce point de suspension estampille
> le numéro que le premier utilise déjà, et un serveur qui acquitte par numéro
> s'entend dire deux choses différentes sur le même.

Le fichier s'en protège. Le **même code, sans garde**, était dans
`SPICESession.send(_:)` — appelé par l'interface à chaque touche et à chaque
geste — et dans `sendMicrophone`, appelé à chaque tampon audio.

Mesuré, deux touches concurrentes : **`[1, 1]`**. Deux messages estampillés 1,
et le 2 jamais utilisé.

Ce n'est pas la première fois cette nuit qu'un danger compris à un endroit
reste ouvert deux fichiers plus loin. Le motif mérite son nom : **écrire le
commentaire ne propage pas la garde.** Une prose juste sur un hasard réel donne
l'impression que la question est traitée, y compris à celui qui l'a écrite.

### Forcer l'entrelacement plutôt que l'espérer

L'instrument est un `ByteStream` dont l'écriture se gare jusqu'à ce que le test
la libère. Rien n'attend une durée : le second `send` est *garanti* de tourner
pendant que le premier est suspendu, parce que le premier ne peut pas avancer.
Un test qui lancerait deux tâches en espérant qu'elles se croisent serait vert
la plupart du temps, ce qui est la pire des couvertures.

Le compteur `parked` du double sert de précondition observable : le test attend
qu'une écriture soit garée avant de libérer, donc il sait qu'il a mesuré le
cas visé et non un enchaînement séquentiel.

### Le correctif n'est pas « réserver le numéro avant l'await »

C'était ma première idée et elle est insuffisante. Elle supprime le doublon et
laisse deux autres défauts : les messages d'un même événement peuvent être
séparés — un cran de molette est **trois** messages, et le commentaire de
`send` dit lui-même ce qu'un release perdu fait croire à l'invité — et les
numéros peuvent arriver dans le désordre, ce qui pour un serveur qui acquitte
par numéro n'est pas mieux qu'un trou.

Ce qui tient les trois est la forme du fichier d'à côté : estampiller et mettre
en file en **un seul pas synchrone**, puis un unique drainer. Les sabordages le
montrent séparément — rendre le code à sa forme d'origine fait tomber deux
tests, drainer par message au lieu de par événement n'en fait tomber qu'un,
celui de l'adjacence.

### Le sabordage qui a survécu, encore, et au même endroit du raisonnement

`recordSerial` remplacé par la constante 1 : **suite entière verte**. J'avais
modifié ce chemin sans qu'aucun test ne puisse voir la modification casser.

Cas 2. Le test du micro existait, lisait l'en-tête de chaque message, vérifiait
le type et la charge utile — et jamais le numéro de séquence. Quatre
assertions d'une ligne ont suffi ; le sabordage mord maintenant.

La règle que j'en tire, et c'est la deuxième fois de la journée : **avant de
livrer une modification, saborder la ligne modifiée**, pas seulement celle
qu'on croit être le sujet de la tranche. Le sujet était le canal des entrées ;
le canal record a été corrigé au passage, et « au passage » est exactement là
où une modification part sans filet.

### L'ordre entre deux concurrents n'est pas une propriété

La CI Apple a fait tomber le test d'adjacence là où Linux le passait :

```
attendu [112, 113, 114]   obtenu [101, 112, 113, 114]
```

Les trois messages du cran étaient **parfaitement adjacents**. Ils étaient
simplement précédés de la touche. J'avais écrit `types.prefix(3) == cran`,
c'est-à-dire « le cran sort en premier » — sous Linux son `send` gagnait la
course, sous Apple c'est l'autre. Le test avait tort, pas le code.

C'est la deuxième fois dans ce dépôt qu'un test affirme plus que le contrat
(les espaces autour d'un `Content-Length` étaient l'autre), et la forme se
répète : **j'ai transformé ce que j'avais observé en ce que j'exigeais.** Le
premier passage vert donne une séquence, et l'écrire telle quelle fige un
détail d'ordonnancement au lieu de la propriété.

Ce qui est promis ici est l'adjacence. Entre deux événements concurrents il n'y
a pas d'ordre — c'est ce que « concurrents » veut dire. L'assertion cherche
maintenant les trois types en suite contiguë n'importe où.

Et la vérification qui compte, parce qu'un test affaibli qui repasse au vert ne
prouve rien : **les deux sabordages mordent toujours**. Nuance notée, elle est
honnête : le sabordage « drainer par message » sépare l'événement *par
construction* et fait tomber le test à tous les coups ; le défaut d'origine ne
le sépare que selon l'ordonnancement, et cette fois ne l'a pas fait. Chaque
propriété garde donc un sabordage qui l'attrape de façon déterministe — pas
chaque sabordage qui attrape chaque propriété.

## Une sonde trop faible rend une réponse qui ressemble à une donnée

Suite de la tranche précédente. `SpiceAgentChannel` se protégeait, mais son
drapeau `draining` ne couvrait **qu'un des quatre appelants** de `write` : un
`pong` répondu par la pompe, croisant un drain de presse-papiers, reprend le
numéro que le drain utilise déjà. La garde et le commentaire qui la justifie
étaient posés à un seul endroit d'un hasard qui en avait quatre.

Ce que cette tranche apprend n'est pourtant pas là. **Ma première sonde a dit
que tout allait bien.**

```
PROBE serials=[1, 2]
```

Elle libérait la barrière dès qu'*une* écriture était garée. La seconde tâche
n'avait pas encore atteint la sienne : j'avais mesuré une exécution
séquentielle en croyant mesurer un entrelacement. En attendant que **deux**
écritures soient garées :

```
PROBE parked=2 serials=[1, 1]
```

Le défaut était là depuis le début. C'est exactement la faute que je passe la
journée à trouver dans le code — une garde qui ne peut pas voir ce qu'elle
prétend surveiller — cette fois dans mon propre instrument. Et elle est plus
dangereuse là : un code défectueux finit par échouer quelque part, tandis
qu'une sonde défectueuse **clôt la question**. J'aurais écrit « vérifié, la
garde est complète » avec une mesure à l'appui.

La règle : *avant de croire une sonde qui dit « rien ici », montrer qu'elle
sait dire « quelque chose ici ».* Le compteur `parked` sert à ça — ce n'est pas
une commodité de synchronisation, c'est la preuve que la précondition du test
a été atteinte.

### Une précondition qui doit survivre au correctif

Difficulté qui vaut d'être notée : une fois corrigé, `parked` ne peut plus
atteindre 2, puisque le second appelant met en file et repart. Un test qui
*exigerait* deux garages se bloquerait sur le code correct.

Il attend donc les deux, borné, et poursuit sans eux. Sous le correctif il
patiente puis libère ; sous le sabordage il part tôt et attrape le doublon. La
validité du test ne vient pas de sa précondition mais du sabordage qui le fait
rougir — la précondition ne fait que lui donner sa chance.

## Deux implémentations d'un protocole, deux préconditions, et rien qui le dise

Clôture de l'audit de réentrance. Reste un hasard réel et **latent** :
`NetworkByteStream.read(exactly:)` remplit son tampon dans une boucle et se
suspend dedans, donc deux lectures concurrentes recousent un flux depuis deux
positions. Pas une erreur, pas une lecture courte — du charabia plusieurs
messages plus loin, sans rien à montrer du doigt.

Latent, et vérifié plutôt que supposé : `SPICESession` lance cinq pompes, chacune
possède sa connexion, la poignée de main finit avant que sa pompe démarre.
Aucun chemin actuel ne lit un flux depuis deux tâches.

Ce qui rend le cas intéressant est que `MemoryByteStream`, l'autre implémentation
du **même protocole**, n'a pas cette précondition : son `read` ne se suspend
jamais. Deux types qui satisfont une interface commune n'ont donc pas le même
contrat, et l'interface ne disait rien. C'est écrit sur `ByteStream` maintenant.

### Ce que je n'ai pas fait, et pourquoi

Rendre `NetworkByteStream` sûr pour plusieurs lecteurs. `Network` est sous
`#if canImport(Network)` : Apple uniquement, donc inexécutable depuis le
conteneur où tout le reste se prouve. Livrer une sérialisation des lectures
sans test serait exactement la faute de #82 — un sabordage y avait survécu
parce qu'un chemin modifié « au passage » n'était vu par personne.

Une section « ce qui attend une machine Apple » dans ROADMAP.md tient
désormais ces cas, avec ce qu'il faudrait pour les prouver.

### Le sabordage d'un commentaire

Une tranche de documentation ne se saborde pas… sauf qu'une de ses phrases
était testable : *« MemoryByteStream ne se suspend pas dans son read »*. Un test
la garde, et le sabordage a d'abord **survécu**.

Ma première tentative ajoutait un `await` mais gardait la prise d'un préfixe
contigu : les deux lectures repartaient quand même avec des octets disjoints.
Cas 1, mauvaise ligne. Le hasard ne vient pas d'une suspension quelconque, il
vient d'un tampon qui **se remplit à travers** elle. Refait sous cette forme —
celle qu'un jour quelqu'un ajoutera par commodité — le sabordage mord, et seul
ce test tombe.

La leçon tient en une phrase : **saborder ce que la phrase dit, pas ce qu'elle
évoque.** « Une suspension dans read » et « un tampon rempli à travers une
suspension » se ressemblent assez pour être confondus, et un seul des deux est
le défaut.

## Le secret qui survit à tout ce qui pouvait s'en servir

Trois familles closes coup sur coup, et la consigne que je m'étais laissée
était de ne pas forcer une quatrième passe dans la même veine. J'ai donc changé
de question : plutôt que « où le décodage peut-il déborder », **« qui range les
secrets, et est-ce que quelqu'un les enlève un jour ».**

`MachineLibraryModel` n'avait aucun test. Ce n'est pas un oubli : `WisqUI`
n'est pas compilé sous Linux, et pendant longtemps la couche application a été
la partie que rien ne vérifiait. Elle a un banc désormais — `Tests/WisqUITests`,
joué par `scripts/test-app.sh` dans un iPhone simulé — mais ce fichier-là
n'avait rien.

### Ce que la lecture donne

Trois endroits écrivent un secret, **un seul** en efface un :

| écriture | clé | effacement |
| --- | --- | --- |
| `MachineLibraryModel.save` | `machine.<uuid>` | `delete`, ligne 78 |
| `MachineEditorView.save` | `agent.<hôte>:<port>` | aucun |
| `AgentImportView.query` | `agent.<hôte>:<port>` | aucun |

Le jeton d'un agent n'est retiré par **aucun chemin**. On supprime sa dernière
VM, on la débranche de son agent, on l'envoie vers un autre agent : le jeton
reste dans le trousseau, plus rien ne peut s'en servir, et aucun écran ne
propose de l'enlever.

### Le piège de la correction évidente

Effacer `agent.credentialRef` dans `delete`, à côté de la ligne 78, est faux.
La clé du mot de passe est dérivée de l'identifiant **de la machine** ; celle du
jeton l'est de l'**hôte et du port**, et le commentaire de `MachineEditorView`
le dit : *« One token per agent host, shared by all its VMs »*. Supprimer une VM
sur cinq d'un NAS aurait déconnecté les quatre autres.

Ce qui reste n'est donc ni la liste des clés qui partent, ni rien : c'est une
**soustraction** — les clés que la machine partante utilisait, moins celles que
la liste survivante désigne encore. C'est tout `CredentialReaper`.

### Où le mettre pour pouvoir le prouver

La décision est du domaine, pas de l'interface : `Machine` et `CredentialStore`
vivent tous deux dans `WisqCore`, qui compile sous Linux. La règle y est donc
écrite et sabordable ici ; le modèle de vue ne fait plus que l'appeler, et cet
appel-là est joué par le simulateur en CI. Les deux moitiés ont un banc, chacune
là où elle peut vraiment tomber.

### L'ordre, qui était un second défaut

`delete` effaçait le mot de passe **avant** d'enregistrer la liste. Si
l'écriture échoue — un conteneur plein suffit — la machine est toujours là et
son mot de passe n'y est plus. La suppression passe maintenant en premier, et
la moisson des clés après, sur ce que le magasin a réellement rendu.

### Les sabordages

Quatre, un par site, jamais groupés :

- `credentialRefs` oublie le jeton d'agent → 4 rouges ;
- `credentialRefs` oublie le mot de passe → 5 rouges ;
- `orphanedRefs` ne soustrait plus les survivants → 5 rouges, dont
  « supprimer une VM d'un agent déconnecterait ses voisines » ;
- `reap` s'arrête au premier refus → 1 rouge, exactement celui écrit pour ça.

Le dernier ne mordait que parce que `reap` trie les clés : `agent.` avant
`machine.`, donc celle qui refuse passe en premier. Un ordre d'ensemble aurait
rendu ce test dépendant du hachage — le tri n'est pas cosmétique, il est ce qui
rend le rouge reproductible.

### Une sonde qui ne peut pas échouer ne prouve rien

Le test d'ordre casse l'écriture en mettant le répertoire en `0500`. Sous root,
cela n'arrête personne, et le test serait passé au vert en n'ayant rien
mesuré. Il crée donc d'abord un fichier témoin : s'il y arrive, il se déclare
sauté plutôt que réussi.

## Un secret écrit en route vers une décision qui n'est pas prise

Suite directe de la tranche précédente, et son angle mort. `CredentialReaper`
enlève les clés qu'une machine **portait**. Il ne peut rien pour une clé
qu'aucune machine n'a jamais portée — et le dépôt en écrivait deux comme ça.

`AgentImportView.query()` rangeait le jeton dès que `listVMs()` répondait, avec
le commentaire « The token worked: keep it ». Interroger un agent pour voir ses
VM et fermer la feuille sans rien importer laissait donc une clé dans le
trousseau que rien ne référence et qu'aucun écran ne propose d'enlever. Le
`try?` avalait en plus l'échec d'écriture en silence. `MachineEditorView` avait
la même forme : jeton écrit, puis `library.save`, qui pouvait échouer sans le
dire puisqu'il ne rendait rien.

Et le mot de passe faisait pareil, en sens inverse : écrit **avant**
`store.upsert`. Une écriture qui échoue laissait une machine absente de la
liste mais un secret rangé à son nom.

La règle tient en une phrase : **rien n'atteint le trousseau avant que la
machine qui le désignera ne soit dans la liste.**

### Où la mettre pour qu'elle puisse être cassée

Ce que porte cette tranche est un **ordre**, et un ordre ne se démontre qu'en
faisant échouer une de ses étapes. Écrit dans le modèle de vue, il n'aurait pu
être sabordé nulle part : `WisqUI` n'est pas compilé sous Linux. D'où
`MachineLibraryWriter` dans `WisqCore`, qui tient la séquence contre un vrai
`MachineStore` écrivant de vrais fichiers ; le modèle de vue ne fait plus que
l'appeler et rendre un booléen, et les deux vues passent le jeton au lieu de
l'écrire.

C'est le même geste que `CredentialReaper` : la tranche précédente avait
descendu la **décision** dans le domaine, celle-ci y descend la **séquence**.

### Injecter l'échec sans dépendre de qui on est

Le test d'ordre de la tranche précédente cassait l'écriture avec un répertoire
en `0500`, protégé par un fichier témoin. Le témoin avait raison de s'y
trouver : `id -u` dans ce conteneur rend **0**. Sous Linux le test se serait
déclaré sauté et n'aurait rien mesuré ; il n'a mordu que parce que le
simulateur iPhone, lui, ne tourne pas en root.

L'injection d'ici ne dépend plus de personne : un chemin dont le parent est un
**fichier ordinaire**. Personne n'écrit dedans, pas même root.

### Le sabordage qui a survécu, et ce qu'il a montré

t4 déplaçait la moisson avant `store.delete` — donc le mot de passe partait
alors que la machine restait — et la suite est restée **verte**.

Cas 2, test manquant. Mon aide `vm()` posait `machine.agent` mais laissait
`credentialRef` à `nil` : le mot de passe que le test rangeait sous
`defaultCredentialRef` n'était désigné par aucune machine, donc la moisson ne
pouvait pas y toucher, et le test ne mesurait rien de l'ordre qu'il prétendait
vérifier. Une ligne dans l'aide, et t4 mord.

La leçon rejoint celle de la sonde : **un montage de test peut être vert parce
qu'il ne pouvait pas être rouge**, et c'est le sabordage, pas la relecture, qui
le dit.

### Les six sabordages

| sabordage | rouges |
| --- | --- |
| le mot de passe repasse avant `upsert` | 1 |
| le jeton repasse avant `upsert` | 1 |
| le jeton retombe sur la clé du mot de passe faute de liaison | 1 |
| dans `delete`, la moisson repasse avant `store.delete` | 1 (après correction du montage) |
| la moisson ignore les survivants | 2 |
| un mot de passe non touché traité comme vidé | 1 |

## Le mode le plus sûr du sélecteur était le moins sûr

Zone jamais auditée : l'import de fichiers de connexion. La lecture a dérivé
ailleurs et a trouvé plus gros.

`.vv` avec un `tls-port` et un `host-subject` donne `security = .tlsPinned`.
Le `host-subject` est ensuite **perdu** : `Machine` n'a pas de champ pour lui.
En tirant ce fil :

| maillon | ce qu'il porte |
| --- | --- |
| `Machine` | pas d'empreinte de certificat |
| `SessionConfiguration` | pas d'empreinte non plus |
| `VNCSession` / `SPICESession` | appellent `NetworkByteStream(host:port:security:)` **sans** empreinte |
| `pinnedParameters(fingerprint: nil)` | `complete(true)` — inconditionnel |

Un bloc de vérification **remplace** les contrôles du système. Choisir « TLS
épinglé » — le libellé le plus rassurant des trois — désactivait donc la
validation du certificat, et rendait ce mode **strictement plus faible que le
« TLS » listé juste au-dessus**. Aucun chemin machine ne pouvait fournir
d'empreinte : c'était le cas de toutes les connexions épinglées, pas d'un cas
limite.

### Trois prose qui décrivaient un mécanisme inexistant

- l'enum : « pinned to a certificate fingerprint recorded on first connect
  (TOFU) » ;
- la fonction : « accept whatever certificate the host presents on first use
  and pin it afterwards » ;
- la ligne : « Trust on first use: the caller records `presented` and pins it ».

`presented` était calculé puis jeté. Aucun appelant n'enregistrait rien, et il
n'y avait nulle part où l'enregistrer. C'est la quatrième fois dans ce dépôt
qu'un commentaire juste sur le danger accompagne un code qui ne le tient pas —
mais les trois précédentes décrivaient une défense affaiblie, celle-ci décrivait
une défense qui n'existait pas du tout.

### Le bon motif était déjà dans le dépôt

`AgentClient` prend `pinnedFingerprint: Data` — **non optionnel** — et épingle
pour de vrai via `URLSession`. Ce qui rend le chemin machine lisible comme un
trou et non comme un arbitrage.

### Rendre l'état dangereux non représentable

Plutôt qu'ajouter une garde, `ResolvedTransportSecurity` supprime la
possibilité : `.pinned` **porte** son empreinte, donc aucun chemin ne peut
demander un épinglage en n'ayant rien à épingler, et `pinnedParameters` prend
un `Data` non optionnel. La résolution vit dans `WisqCore`, sabordable sous
Linux ; le fichier qui contenait le trou est sous `#if canImport(Network)` et
son « build complete » ici ne prouve rien, puisque la condition le vide.

### Le repli choisi, et celui écarté

Refuser tout net était le candidat au son le plus sûr. Écarté : cela casserait
des machines que l'utilisateur croit fonctionner sans rien lui donner de plus,
puisque aucune ne peut porter d'empreinte aujourd'hui. Le repli est la
**validation système complète** — un vrai contrôle là où il n'y en avait aucun.

Ce n'est pas du TOFU, et le commit ne le prétend pas. Un certificat auto-signé
de labo, qui « marchait », sera désormais refusé. C'est le sens sûr, et le prix
est dit plutôt que caché. Ce qu'il faudrait pour le vrai épinglage est écrit
dans ROADMAP.md.

### Ce que je n'ai pas fait

Le sélecteur affiche toujours « TLS épinglé » pour un mode qui vaut `.tls`.
Corriger l'étiquette suppose de migrer la valeur enregistrée des machines qui
la portent — une question de migration, avec ses propres tests. Tranche
suivante, pas celle-ci.

## Les longueurs de RFB n'avaient aucun plafond

Zone jamais auditée sous l'angle de la correction. L'audit des débordements
(tâche #60) avait conclu « tout le décodeur RFB est structurellement immunisé :
la géométrie arrive en `readUInt16()` ». C'est vrai, et ce n'est pas la
question posée ici.

`readUInt16` borne les **produits** — 65535² × 4, très loin d'`Int.max`. Mais
les **longueurs** de RFB arrivent en `UInt32`, et chacune alimente
`read(exactly:)`, qui **accumule**. #60 avait d'ailleurs regardé le seul
`UInt32` qui lui passait sous les yeux, le `subrectangleCount` de RRE, et
conclu correctement : il *boucle*, consommant chaque sous-rectangle et levant à
l'EOF. La différence entre boucler et accumuler est exactement ce qui sépare
ces deux cas.

### La sonde, et son témoin

`MemoryByteStream` ne peut pas répondre à la question : sa lecture lève dès que
la demande dépasse ce qu'il contient, donc un décodeur borné et un décodeur non
borné finissent tous deux par une exception et se ressemblent. J'ai écrit un
`RecordingByteStream` qui **enregistre la taille demandée** — la demande
elle-même est la preuve.

Réponse : **4 294 967 295 octets** en une seule lecture, sur les trois sites du
décodeur. Et le témoin, avec une longueur de 7, rend 7 : la sonde lit bien la
demande réelle et non mon entrée. Après les gardes, la même sonde rend 4 — les
quatre octets du champ de longueur, et rien de plus.

### Sept sites, deux sortes de plafond

| site | ce qu'il lit | plafond |
| --- | --- | --- |
| `VNCSession` refus de connexion | raison | texte, **avant toute authentification** |
| `VNCSession` échec d'auth | raison | texte |
| `VNCSession` ServerInit | nom du bureau | texte |
| `VNCSession` ServerCutText | presse-papiers | presse-papiers |
| `RFBDecoder` desktopName | nom du bureau | texte |
| `RFBDecoder` zlib | bloc compressé | **dérivé du rectangle** |
| `RFBDecoder` ZRLE | bloc compressé | **dérivé du rectangle** |

Le premier est celui qu'un attaquant atteint en premier : la première chose
qu'un écouteur hostile peut dire est « refusé, et la raison fait quatre
gigaoctets ».

Les deux derniers ne sont pas des constantes choisies mais une valeur
**dérivée** : le résultat inflaté doit être les pixels du rectangle —
`decodeZlib` le vérifiait déjà, mais *après* avoir alloué — donc la forme
compressée ne peut pas raisonnablement dépasser ces pixels plus ce qu'un
compresseur ajoute quand il renonce. Un plafond qui ignore la géométrie serait
soit inutile sur les petits rectangles, soit faux sur les grands ; le sabordage
s8 le montre en refusant un bloc parfaitement légitime.

Les autres sont choisis, faute de borne structurelle, et le presse-papiers a la
sienne : un collage a le droit d'être un document, et refuser ce que
l'utilisateur a demandé serait une panne pire que celle qu'on prévient.

### Les neuf sabordages

Sept sites retirés **un par un**, jamais groupés — c'est là qu'une garde non
couverte se cache derrière celle d'à côté. Chacun a rendu **un seul** rouge, le
sien. Puis deux sur le bord permissif : le plafond compressé rendu sourd au
rectangle (3 rouges) et le presse-papiers ramené au plafond des noms (1). Une
règle a deux bords, et la moitié du travail porte sur ce qu'il ne faut **pas**
refuser.

## Un fichier refusé pour un champ que personne ne lit

`VirtViewerFile` énonce la règle, en toutes lettres, pour les `.vv` :

> Unknown keys are ignored rather than refused: these files carry a long tail of
> options for features wisq does not have, and failing on the first one would
> reject perfectly good files for saying something extra. What is *malformed* —
> a port that is not a number — is refused.

Deux moitiés : **ignorer l'inconnu**, **refuser le malformé de ce qu'on lit**.
`RemoteDesktopFile`, dans le même dossier, n'avait retenu que la seconde et
l'appliquait à **toutes** les lignes `i`, y compris les quarante que Windows et
une passerelle RD écrivent pour des fonctions que wisq n'a pas.

### Mesuré sur un fichier réaliste

Un `.rdp` de passerelle contenant `gatewaycredentialssource:i:` — valeur vide,
parfaitement légale dans ces fichiers — était refusé **en entier** :
`badInteger(key: "gatewaycredentialssource", value: "")`. La clé n'est lue nulle
part. Le témoin, même fichier sans cette ligne, était accepté : la sonde
distinguait bien les deux.

Quatre clés seulement sont lues : `desktopwidth`, `desktopheight`,
`screen mode id`, `redirectclipboard`. Pour tout le reste, il n'y a rien à
deviner puisque la valeur est jetée de toute façon.

### Le détail qui aurait été perdu au passage

Le test « est-ce seulement un fichier `.rdp` » s'appuyait sur les deux
dictionnaires non vides. En ignorant les clés non lues, un fichier n'ayant que
celles-là se serait retrouvé « pas un fichier `.rdp` » au lieu de « fichier
`.rdp` sans adresse ». Or voir `audiomode:i:0` est une preuve solide que c'en
est un. D'où un `sawOption` distinct : **avoir vu une option est une question
différente d'avoir gardé quelque chose.**

Le sabordage d4 déplace la pose de ce drapeau d'une ligne et le test tombe.
C'est exactement le genre de conséquence « au passage » qui part sans filet.

### Ce que je n'ai pas fait

Rogner les espaces autour d'une valeur `i`. `audiomode:i: 0` était refusé lui
aussi, et ne l'est plus — mais parce que la clé est ignorée, pas parce que la
valeur est tolérée ; `desktopwidth:i: 1920` reste refusé. Je n'ai aucune preuve
qu'un vrai fichier écrive un espace là, et corriger par précaution ce
qu'aucune mesure ne signale, c'est deviner.

## Le chemin le moins fiable était le seul non validé

Quatre façons de créer une machine, et trois seulement vérifiaient l'hôte :

| chemin | entrée | `Validation.normalizedHost` |
| --- | --- | --- |
| `MachineEditorView` | ce que l'utilisateur tape | oui |
| `AgentPairing` | ce qu'un QR porte | oui |
| `AgentImportView` | une adresse tapée | oui |
| `ConnectionImport` | **un fichier reçu** | non |

Le manquant est celui dont l'entrée est la moins fiable. Le commentaire de
`ConnectionImport.kind(of:)` le dit lui-même : ces fichiers arrivent « from
Mail, from AirDrop, from a share sheet — anywhere a name is chosen by whoever
sent the file rather than by the person opening it ».

Mesuré, témoin compris : un `.rdp` portant `full address:s:exemple.net/../autre`
était accepté et la machine enregistrée avec ce host — alors que
`normalizedHost` refuse explicitement barres et espaces. Même chose pour un
espace, en `.rdp` comme en `.vv`. Le témoin, un hôte ordinaire, passait
inchangé.

Ce n'était pas un trou mais **une vérification au mauvais endroit** : l'échec
arrivait plus tard, dans `NetworkByteStream`, loin de l'écran où la personne
pouvait encore choisir un autre fichier. Un fichier se refuse là où il
s'ouvre — et le message montré nomme l'adresse, ce qu'un test épingle.

La vérification va dans `ConnectionImport` et non dans les deux lecteurs
voisins, parce que leur travail s'arrête à ce que le fichier dit. La doc du
type l'avait déjà écrit : *« everything here is a decision about what wisq does
with a value it did not choose »*.

### Le sabordage qui a survécu, et ce qu'il a révélé

i4 gardait la vérification et **jetait sa valeur de retour** —
`_ = try normalizedHost(raw); return raw`. Toute la suite est restée verte.

Cas 2, test manquant. `normalizedHost` ne fait pas que refuser : il **rogne les
espaces et retire les crochets**, et mes tests ne portaient que sur des hôtes
déjà propres, parce que les deux parseurs les rendent tels dans les cas que
j'avais écrits. Deux entrées distinguent :

- un `.vv` écrit ce qui suit `host=`, crochets compris ;
- un `.rdp` garde les espaces entre son second deux-points et la valeur.

Sans elles, une machine pouvait être enregistrée avec un hôte qu'aucun autre
chemin ne produirait jamais. Les deux tests ajoutés, i4 mord.

La leçon rejoint celle de la moisson : **vérifier n'est pas normaliser**, et un
test bâti sur des entrées déjà propres ne peut pas voir la différence.

## Une machine qui annonçait une protection qu'elle n'avait pas

#87 avait refermé le trou — un épinglage sans empreinte fait désormais une
validation système au lieu de tout accepter — et avait explicitement laissé
deux choses ouvertes. Les voici, parce que c'est la même phrase.

Mesuré, témoin compris :

| étape | valeur |
| --- | --- |
| `VirtViewerFile` lit `tls-port` + `host-subject` | `.tlsPinned`, sujet présent |
| `ConnectionImport` enregistre | `.tlsPinned`, **sujet jeté** |
| `ResolvedTransportSecurity` résout | `systemValidated` |
| la liste affiche | « TLS épinglé » |

Le sujet **est** l'épinglage, et `Machine` n'a pas de champ pour lui. Enregistrer
`.tlsPinned` revenait donc à ranger une promesse que rien ne tient, et à
étiqueter « TLS épinglé » une connexion qui ne l'est pas.

### La règle était déjà écrite trois lignes plus bas

Dans le même appel, à propos de la référence de secret :

> A machine pointing at a credential that was never written is worse than one
> with no credential at all — it fails at connect time instead of asking.

Exactement la même forme, appliquée au champ d'à côté. `claimableSecurity`
n'est que cette phrase-là étendue d'un cran : **une machine annonce moins
plutôt que de mentir.** C'est le même geste que #89, qui avait appliqué au
`.rdp` la politique que le `.vv` énonçait déjà.

Le témoin compte double ici : aplatir tout vers `.tls` chiffrerait en silence
une connexion que le fichier disait en clair. Deux tests gardent ce bord, et le
sabordage c2 les fait tomber.

### L'étiquette

`.tlsPinned` reste dans le sélecteur, puisque des machines enregistrées le
portent. Mais son libellé nommait une protection absente. Il dit maintenant ce
que la connexion fait — TLS validé par le système — et que l'épinglage reste à
venir. Un test garde aussi que les trois modes restent distinguables : un
sélecteur avec deux lignes identiques serait un autre genre de mensonge.

### Ce qui reste ouvert, et où

Le vrai épinglage, décrit dans ROADMAP.md : un champ d'empreinte sur `Machine`,
son passage par `SessionConfiguration`, et l'enregistrement, qui demande une
machine Apple et de montrer l'empreinte à qui l'accepte. `claimableSecurity` est
l'endroit exact où le `host-subject` cessera d'être jeté.

### Une mesure tenue plutôt qu'oubliée

Le test `testAFailedDeletionKeepsBothTheMachineAndItsPassword` avait pris
0,019 s sur #85 puis 25,6 s sur #86. Troisième point sur #90 : **0,033 s**.
C'était du bruit du runner, pas une régression, et l'injection par répertoire
en `0500` reste en place. Deux points ne font pas une tendance ; le troisième
tranche.

## Deux fichiers affirment qu'ils ne peuvent pas diverger, et divergent

`AgentPairing` (Swift) porte cette phrase :

> Both sides of the wire live here so generation and parsing cannot drift apart.

et `crates/wisq-agent/src/pairing.rs` (Rust) celle-ci :

> The format is shared with `AgentPairing` in WisqCore — the Swift side parses
> exactly this, so the two must not drift.

Deux modules, deux langues, la même propriété énoncée. Aucun des deux ne la
tenait.

### Mesuré, témoin compris

`parse` a toujours exigé une empreinte de 32 octets — « a malformed
fingerprint is an error, never a shrug ». `url(for:)` écrivait n'importe quelle
longueur :

| empreinte | ce que `url(for:)` produisait | ce que `parse` en faisait |
| --- | --- | --- |
| 32 octets (témoin) | un lien | accepté |
| vide | `…&fp=` | **refusé** |
| 4 octets | `…&fp=aa11bb22` | **refusé** |
| 33 octets | un lien | **refusé** |

Le type dont la raison d'être est que ses deux moitiés ne divergent pas
fabriquait un lien qu'il refusait lui-même.

Et `aa11bb22` n'est pas une valeur que j'ai inventée : c'est exactement ce que
le test Rust affirmait. Il **gravait** une chaîne que le téléphone rejette,
donc il décrivait un contrat que personne n'a.

### Refuser, et non laisser tomber

Une empreinte de mauvaise longueur ne produit plus **aucun lien**, plutôt qu'un
lien sans `fp`. La forme sans `fp` a un sens — elle veut dire HTTP en clair —
donc l'émettre ici transformerait une empreinte cassée en **dégradation
silencieuse**, exactement ce que `parse` refuse à l'autre bout. Le sabordage p2
fait précisément cela, et un test distingue les deux échecs.

### Où la garantie appartient vraiment

Côté Rust, `pairing::urls` écrit l'empreinte verbatim, et c'est correct : elle
vient de `tls::fingerprint_hex`, un SHA-256. Mais **cette fonction n'avait
aucun test**. C'est chez le producteur que la forme se décide, alors elle en a
deux maintenant : la longueur et la casse, et un témoin — deux certificats
différents n'ont pas la même empreinte — sans lequel le test de longueur
passerait pour une fonction qui rendrait une constante.

### Les cinq sabordages

| sabordage | rouges |
| --- | --- |
| `url(for:)` réaccepte n'importe quelle longueur | 6 |
| `url(for:)` laisse tomber le `fp` au lieu de refuser | 6, dont celui de la dégradation |
| `fingerprint_hex` tronque | 2 |
| `fingerprint_hex` rend une constante | 2 |
| `pairing::urls` tronque l'empreinte | 2 |

### Ce qui n'est pas atteignable, et le dire

Rien de tout cela n'était un défaut en production : l'empreinte vient toujours
de `fingerprint_hex`, donc toujours de 64 caractères. C'est un **contrat non
tenu**, pas un trou, et le commit le dit comme tel plutôt que de le gonfler. Ce
que la tranche apporte est une propriété qui tient désormais par construction,
et un test qui attrapera la dérive du jour où quelqu'un changera un des deux
bouts.

## L'écran alterné laissait une trace, et c'était le curseur

`TerminalGrid` est bien couvert — trente-deux tests, un par promesse de sa
doc. J'ai donc cherché ce qui reste **hors** de ce filet plutôt que de rouvrir
à vide, et un voisin donnait la piste : `testTheAlternateScreenComesAndGoesWithoutTrace`
vérifie que le **contenu de l'écran** revient intact. Il ne regarde pas le
curseur sauvegardé.

Or il n'y avait qu'un seul emplacement pour lui, partagé par deux fonctions que
la doc énumère séparément : `ESC 7`/`ESC 8` et la sauvegarde de `?1049`.
Mesuré, témoin compris :

| séquence | curseur obtenu | attendu |
| --- | --- | --- |
| témoin : `ESC 7` … `ESC 8` | (5, 10) | (5, 10) |
| sauvegarde **dans** l'alterné, puis sortie | (1, 1) | (5, 10) |

Quitter un programme plein écran rendait au shell la position que le programme
avait sauvegardée. La classe de défaut que la doc du fichier annonce elle-même :
« invisible jusqu'à ce qu'un vrai programme tourne ».

### Mon attente était fausse sur l'autre moitié

La sonde testait aussi ceci : `ESC 7`, puis un programme entre et sort avec
`?1049`, puis `ESC 8`. J'attendais la position d'origine ; j'ai obtenu celle du
programme, et **après correction je l'obtiens toujours**.

Ce n'est pas un défaut. `?1049h` est défini comme *save cursor as in DECSC,
then switch* : il écrit le même emplacement que `ESC 7`, sur l'écran où il se
tient encore, donc il remplace légitimement une sauvegarde antérieure. Ce qui
distingue les deux cas n'est pas *combien de fonctions écrivent l'emplacement*
mais *à quel écran il appartient*.

Un test épingle ce comportement délibéré avec sa raison, pour que personne ne
le « corrige » plus tard. Sans lui, la prochaine lecture referait exactement ma
sonde et referait ma conclusion.

### La correction

Un emplacement **par écran**, ce que gardent les vrais terminaux, derrière un
accesseur qui choisit celui de l'écran courant — donc tous les appels existants
continuent de dire `savedCursor`. L'ordre de `setAlternateScreen` fait le reste
pour `?1049` : il sauvegarde avant de basculer et restaure après être revenu,
les deux sur l'emplacement de l'écran principal, là où un shell a laissé le sien.

Et l'entrée vide l'emplacement de l'alterné : une sauvegarde d'une visite
précédente n'appartient pas à la suivante.

### Les quatre sabordages

| sabordage | rouges |
| --- | --- |
| un seul emplacement partagé (l'ancien comportement) | 7 |
| l'entrée ne vide plus l'emplacement de l'alterné | 2 |
| l'accesseur choisit le mauvais écran | 13 |
| `?1049` n'écrit plus l'emplacement | 7, dont sa propre fonction |

## Deux encodages que rien ne tenait, et aucun défaut dedans

`RFBDecoderTests` a quatre tests pour douze encodages. Hextile et CopyRect n'en
avaient aucun. J'ai sondé les deux en attendant d'y trouver quelque chose, et
**ils sont corrects** : fond et sous-rectangles colorés, report des couleurs
entre tuiles, tuile brute, sous-rectangle démesuré clippé sans déborder, copie
simple, copie chevauchante. Chaque sonde écrite pour les prendre en défaut leur
a donné raison.

Cette tranche n'apporte donc aucun correctif, et le commit le dit. Elle
transforme une croyance en mesure — la seule chose qui rende sûr le prochain
changement dans l'un ou l'autre : une suite verte qui n'exécutait jamais ce code
ne pouvait pas rougir pour lui.

### Le sabordage qui a survécu, et ce qu'il a corrigé chez moi

Mon test de chevauchement était **horizontal, sur une seule ligne**. J'ai
supprimé le tampon de travail de `Framebuffer.copy` — la défense contre une
copie qui lit au fur et à mesure — et les **903 tests sont restés verts**.

Cas 2, test manquant. Une copie qui déplace une ligne entière à la fois lit
cette ligne avant de l'écrire : un chevauchement sur une seule ligne sort juste
de toute façon. Le cas qui distingue est le chevauchement **vertical** — la
ligne 0 atterrit sur la ligne 1, qui est la source de la ligne 2 — c'est-à-dire
un défilement, l'usage principal de CopyRect. Avec ce test, le sabordage rend
`[1, 1, 1, 1]` au lieu de `[1, 1, 2, 3]` : la première ligne s'étale vers le bas.

La leçon est la même que celle de l'import : **un test bâti sur le cas facile ne
peut pas voir la différence.** Ici le cas facile et le cas dur se ressemblent au
point que j'ai écrit le premier en croyant écrire le second.

### Les six sabordages

| sabordage | rouges |
| --- | --- |
| nibbles position/taille inversés | 2 |
| la largeur perd son `+1` | 2 |
| les couleurs ne sont plus reportées entre tuiles | 1 |
| le bit `raw` est ignoré | 2 |
| CopyRect lit la destination comme source | 3 |
| la copie se passe du tampon de travail | 1, après correction du test |

## La faute que le dépôt cite deux fois en exemple était toujours là

`Sources/WisqRemote/SPICE/SpiceLink.swift` et `Sources/WisqRemote/SPICE/SpiceLZ.swift`
désignent tous les deux le même fichier comme la forme à ne pas reproduire.
SpiceLink : « `WisqNet.SHA256` a déjà fait cette erreur dans l'autre sens : il
renvoie `Data()` vide sans CryptoKit, donc un condensat bâti dessus passe ses
tests en étant d'accord avec lui-même sur rien. » SpiceLZ, pour justifier
d'écrire son codec sans plateforme derrière : « la forme de `WisqNet.SHA256` ».

La leçon avait été écrite deux fois. Le code n'avait pas bougé, et rien ne le
testait.

### Ce que ça valait vraiment

Le seul appelant de `digest` vit sous `#if canImport(Network)`, c'est-à-dire
là où CryptoKit existe aussi ; et la comparaison `présenté == épinglé` échouait
de toute façon si le condensat était vide. Donc **rien n'était cassé
aujourd'hui**. Ce qui était cassé, c'est ce qu'un appelant pouvait croire :
`digest` ne renvoyait pas une erreur, ni `nil`, mais une valeur ayant
exactement la forme d'une réponse.

Le trou n'a été bouché ni par un `nil` ni par un `fatalError`, mais de la
manière que les deux commentaires prescrivent : une implémentation de repli en
arithmétique `UInt32` pure, que le runner Linux qui ne coûte rien vérifie contre
les vecteurs publiés, et que le runner Apple compare à CryptoKit sur les mêmes
octets. J'ai ensuite corrigé les deux commentaires : ils décrivaient la faute au
présent, et la laisser au présent aurait été une nouvelle affirmation fausse.

### Ce que j'ai trouvé à côté, et qui était pire

`fingerprintString` rendait `AA:BB:CC…`. **Aucun appelant.** C'est exactement
pour ça que c'était encore faux : l'agent Rust écrit `&fp=` avec
`format!("{byte:02x}")`, `AgentPairing` lit ce format et rien d'autre, et le
premier appelant de `fingerprintString` aurait produit une chaîne que
l'analyseur du projet lui-même refuse.

Trois orthographes des mêmes trente-deux octets, dont deux dans le même dépôt,
tenues d'accord par personne. Il y a maintenant un seul rendu — `WisqCore.Hex`,
que `AgentPairing` et `SHA256` appellent tous les deux — et un vecteur unique,
`sha256("abc")`, écrit **des deux côtés de la frontière de langage** : dans
`SHA256Tests` et dans `crates/wisq-agent/src/tls.rs`.

### Le sabordage qui justifie le test Rust

`tls.rs` avait déjà deux tests sur `fingerprint_hex` : trente-deux octets, et
deux certificats différents ne partagent pas d'empreinte. J'ai remplacé
`ring::digest::SHA256` par `SHA512_256` — même longueur, mêmes minuscules,
toujours distinct. **Les deux anciens tests passent.** Seul le nouveau rougit.

C'est la démonstration que le vecteur gagne sa place : une propriété de forme
est vraie de n'importe quelle fonction de hachage bien élevée ; c'est le
littéral publié qui dit *laquelle*.

### Les dix sabordages

| sabordage | rouges |
| --- | --- |
| la longueur du message lue après le remplissage | 19 |
| une seule des soixante-quatre constantes changée | 19 |
| `rotate` devient un décalage | 19 |
| `schedule[index - 7]` devient `[index - 6]` | 19 |
| `digest` renvoie `Data()` vide (le trou d'origine) | 6 |
| `fingerprintString` revient à `AA:BB:CC` | 4 |
| `Hex.encode` en `%x` : le zéro de tête tombe | 23 |
| `Hex.decode` tronque une longueur impaire | 1 |
| l'agent Rust écrit `{byte:02X}` | 2 |
| l'agent Rust hache en SHA-512/256 | 1 |

Deux remarques honnêtes sur ce tableau. D'abord, les quatre premiers laissent
passer `testDifferentMessagesGiveDifferentDigests` : un hachage faux mais
injectif reste injectif — ce test est un témoin, pas une mesure, et c'est son
rôle. Ensuite, `testTheFallbackAgreesWithCryptoKit` **n'a pas pu être sabordé
ici** : il ne se compile que là où CryptoKit existe. Ce que je peux affirmer,
c'est que la fonction qu'il compare est la même que celle que les vecteurs
mettent en rouge quatre fois ci-dessus ; sa capacité à rougir est établie, son
exécution ne l'est que par le vert du job `Cœur (Apple)`.

### Examiné et laissé

`AgentClient.swift` appelle `CryptoKit.SHA256.hash` directement plutôt que de
passer par l'enveloppe — ce qui est précisément ce que la doc de l'enveloppe dit
éviter. Laissé : son `#if` couvre `Security` autant que `CryptoKit` et ne
disparaîtrait pas, et les deux chemins calculent le même SHA-256, donc aucune
divergence n'est possible. Le noter coûte moins cher que d'élargir la tranche.

## La tolérance annoncée ne couvrait que les clés

`Settings.swift` ouvre sur une promesse : « Decoding is tolerant: every key is
optional and falls back to its default, so adding a setting does not invalidate
machines already on disk. »

Vrai des **clés**. Faux des **valeurs**. `decodeIfPresent(Scaling.self, …)` ne
rend `nil` que pour une clé absente ou nulle ; un nom que cette version ne
connaît pas fait lever le décodeur. Ajouter un *réglage* était sans danger ;
ajouter un *cas* ne l'était pas.

### Ce que ça coûtait vraiment

`MachineStore.loadOnQueue` décode `[Machine].self` d'un seul bloc. Donc une
seule machine portant un `longPressAction` inconnu ne faisait pas perdre le
geste, ni le réglage, ni même la machine : elle faisait perdre **toute la
bibliothèque**, sans moyen de réparer depuis l'application.

Le scénario n'est pas théorique pour une application qu'on installe à la main :
un fichier écrit par une version plus récente, puis relu par une plus ancienne.

### L'autre bord, qui est la moitié intéressante

La tolérance est juste pour un geste et fausse pour la sécurité. Un
`security` que cette version ne reconnaît pas ne doit **pas** se rabattre :
`.none` est une valeur qui veut dire quelque chose — du TCP en clair — donc un
repli y serait un déclassement silencieux, exactement ce que
`ResolvedTransportSecurity` existe pour empêcher. Même chose pour `proto` :
retomber sur VNC ouvrirait une session VNC sur un port noté pour autre chose.

Perdre la bibliothèque est le moindre mal ; se connecter sans protection à
quelque chose que l'utilisateur avait marqué autrement est le plus grand. Les
deux refus sont maintenant épinglés par un test, pour que personne ne
« généralise » la tolérance jusque-là.

Un troisième bord, plus fin : une valeur de mauvaise *forme* (un nombre là où un
nom est attendu) continue de lever. Ce n'est pas une version plus récente qui
parle, c'est un fichier abîmé, et l'avaler cacherait le dégât au lieu d'y
survivre.

### Les onze sabordages

| sabordage | rouges |
| --- | --- |
| le repli disparaît, retour au lever | 4 |
| le repli avale aussi une valeur de mauvaise forme | 1 |
| le repli avale aussi les noms connus | 13 |
| `scaling` seul revient au décodage strict | 2 |
| `pointerMode` seul | 1 |
| `longPressAction` seul | 2 |
| `twoFingerTapAction` seul | 1 |
| `twoFingerPanAction` seul | 1 |
| `threeFingerPanAction` seul | 1 |
| `TransportSecurity` se voit donner un repli | 1 |
| `RemoteProtocol` se voit donner un repli | 1 |

Les sept sabordages du milieu sont là pour la raison apprise en #62 : chaque
site séparément. Un patch groupé aurait donné « ça rougit » et n'aurait rien dit
de celui des sept qu'on aurait oublié de brancher.

### Écarté, et pourquoi

Rendre `Machine.guestOS` tolérant aussi. Ce serait juste sur le fond — l'OS
invité ne sert qu'à une icône et à des défauts de clavier — mais `Machine` a un
`Codable` synthétisé, et le rendre tolérant sur un champ oblige à écrire à la
main le décodeur de ses seize champs. C'est un endroit de plus où oublier un
champ ajouté, c'est-à-dire précisément la dérive de #71, pour couvrir un cas
moins probable que celui qu'on vient de fermer.

Et `MachineStore`, qui perd tout sur un élément : voir `docs/ROADMAP.md`. La
correction évidente — garder ce qui se décode — laisse tomber une machine en
silence, et une perte qu'on ne voit pas est pire qu'un refus franc. La bonne
forme rend aussi la liste de ce qui a été écarté, ce qui touche une vue : sa
propre tranche.

## Un hôte validé, puis recollé là où « hôte » ne veut plus dire la même chose

`Validation.normalizedHost` rend un hôte **nu**. Ses deux appelants écrivaient
ensuite `"\(scheme)://\(hôte):\(port)"`. Trois défauts distincts sortent de ce
seul écart, et la sonde en a trouvé deux que je n'avais pas prévus.

| ce qu'on donne | ce que la connexion vise |
| --- | --- |
| `real.local@evil.com` | **`evil.com`** — le `@` termine le userinfo |
| `real.local?x=1` | `real.local`, **port 80** — le `:7442` tombe dans la requête |
| `[2001:db8::1]` | rien : l'URL est `nil` |

Le premier est celui qui a des dents : la liste des machines affiche la chaîne
entière, et la connexion s'ouvre ailleurs. `tokenRef`, qui vaut
`agent.\(url.host)`, range en plus le jeton sous le nom de l'attaquant.

Le troisième est le plus embarrassant à écrire : `normalizedHost` **documente**
qu'il accepte l'IPv6 « avec ou sans crochets », et c'est vrai de lui. Ce n'était
pas vrai de son appelant — `URL(string: "http://2001:db8::1:7442")` est `nil` —
donc un lien d'appairage IPv6 était accepté, rangé, affiché, puis refusé d'un
« Adresse invalide » au moment de connecter.

### Ce que la sonde m'a corrigé

J'attendais le `@`. Je n'avais pas prévu que `?` et `#` fassent **disparaître le
port** en silence, ni que le retrait des crochets rende l'IPv6 injoignable. Deux
trouvailles sur trois viennent de la sonde, pas du raisonnement — c'est
exactement pour ça qu'on sonde avant d'écrire une affirmation.

### La forme de la correction

Deux moitiés, parce que le défaut a deux moitiés.

`normalizedHost` refuse désormais les caractères qui changent le **sens** d'un
hôte — pas ceux qui ont l'air louches. C'est la liste des délimiteurs d'URL
(`@ ? # / \ [ ]`) plus les blancs et les caractères de contrôle. Chercher une
espace, ce que faisait l'ancienne version, ne voit ni une tabulation, ni un
saut de ligne, ni une espace insécable.

`Validation.agentURL(scheme:host:port:)` construit l'URL, avec les crochets pour
un littéral IPv6. Elle est dans `WisqCore` et non dans la vue, pour la raison
habituelle : le runner Linux peut la casser. Les deux vues qui bricolaient la
chaîne l'appellent maintenant — la seconde a été trouvée par un `grep` après
avoir corrigé la première, ce qui est la leçon de #62 appliquée avant d'avoir
été rappelée.

### Les neuf sabordages

| sabordage | rouges |
| --- | --- |
| la garde des délimiteurs revient à l'ancienne | 10 |
| `@` redevient acceptable | 1 |
| `?` et `#` redeviennent acceptables | 2 |
| `/` et `\` redeviennent acceptables | 4 |
| les crochets redeviennent acceptables | 1 |
| blancs et caractères de contrôle ne sont plus vus | 8 |
| `agentURL` n'encadre plus l'IPv6 | 2 |
| `agentURL` encadre **tout** (témoin inverse) | 2 |
| le retrait des crochets disparaît | 3 |

L'avant-dernier est le témoin qui donne son sens aux autres : une garde trop
large est aussi un défaut, et `testANameIsLeftAlone` la voit.

### Ce que la porte locale ne prouve pas

Les deux vues sont dans `WisqUI`, qui ne compile pas sous Linux. `swiftc -parse`
dit que leur syntaxe est bonne et `import WisqCore` y est déjà, mais la
résolution des noms n'est établie que par `Cœur (Apple)` et `App iOS`. Je le
note plutôt que de laisser croire que le vert local couvre ces deux lignes.

## Une règle que le démon gardait seul

`crates/wisq-agent/src/service.rs` refuse tout identifiant de VM hors liste
blanche depuis la tranche qui a fermé l'injection d'argument, et répond
`404 identifiant de VM invalide`. Personne d'autre ne le savait :

* `docs/AGENT-PROTOCOL.md`, qui **est** le contrat entre les deux
  implémentations, décrivait `/v1/vms/{id}` sans un mot sur `{id}` ;
* `MachineEditorView` ne vérifiait que la non-vacuité, donc on pouvait
  enregistrer une machine que l'agent refuserait toute sa vie, et ne
  l'apprendre qu'à la première tentative de connexion ;
* `AgentClient` collait l'identifiant dans `vms/\(id)/start`.

### La sévérité, sans la gonfler

**Ce n'était pas un trou.** La sonde sur `appendingPathComponent` montre que
`?` et `#` sont échappés mais que `/` et `..` passent bruts, et qu'`URLSession`
normalise `../..` avant l'envoi — une requête pouvait donc viser hors de
`/v1/vms/`. Sauf que le démon répond 404 à tout ça : il échoue fermé, liste
blanche lue ligne à ligne. Ce qui restait, c'est une règle appliquée d'un côté
et écrite nulle part.

### Ce que la liste partagée a trouvé en une seule exécution

Les cas sont écrits **deux fois**, dans `VMIdentifierTests` et dans
`service.rs`. Au premier lancement, les deux ont rougi, et pour deux raisons
différentes.

**`..` : les deux implémentations l'acceptaient.** Tous ses caractères sont
dans la liste blanche. C'est moi qui avais tort en écrivant le test — et le
test avait raison sur le fond : un segment de chemin qui veut dire « le parent »
n'est pas un nom de domaine. Corrigé des deux côtés, avec `.` au passage.

**`domaine\n` : les deux divergeaient pour de bon.** Swift rogne les blancs
d'abord et acceptait donc `domaine` ; Rust lit un segment de chemin et refusait
la chaîne brute. Ce n'est pas une dérive à corriger mais une différence à
énoncer : le démon lit le fil et doit refuser, le téléphone lit un champ de
saisie et rend la valeur **rognée**, qui est ensuite ce qui part sur le fil. La
liste partagée est donc une liste de cas déjà rognés, et `domaine\n` est parti
dans le test de rognage, où la réponse est écrite au lieu d'être supposée.

Deux corrections en une exécution, dont une contre ma propre attente. C'est
exactement le rendement qu'on attend d'un jeu de cas écrit des deux côtés d'une
frontière de langage.

### Les sept sabordages

| sabordage | rouges |
| --- | --- |
| la liste blanche disparaît | 12 |
| le tiret initial redevient permis | 2 |
| `.` et `..` redeviennent permis | 2 |
| la limite de 255 octets saute | 1 |
| le rognage disparaît | 2 |
| la règle refuse **tout** (témoin inverse) | 15 |
| côté Rust, la garde `.`/`..` retirée | 1 |

Le témoin inverse compte autant que les autres : quatorze des quinze rouges
viennent de la moitié « ce qu'il ne faut pas refuser ». Une règle trop stricte
empêcherait d'atteindre des VM qui existent, et c'est un défaut de plein droit.

## Une entrée illisible emportait toute la bibliothèque

`MachineStore.loadOnQueue` faisait `decode([Machine].self)` en un seul appel.
Une machine écrite par une version plus récente ne coûtait donc ni le réglage,
ni la machine : elle coûtait **toute la liste**. `MachineLibraryModel.reload()`
mettait `machines = []` et affichait une erreur, et une application qui ne peut
pas atteindre son propre conteneur ne laissait aucun moyen de réparer.

### La moitié qui aurait rendu la correction pire que le défaut

Décoder entrée par entrée est facile. Le piège est deux lignes plus loin :
`upsert` et `delete` chargent la liste et la réécrivent. Une version ancienne
lisant un fichier récent aurait donc *effacé définitivement* ce qu'elle n'avait
pas su lire, à la première machine ajoutée.

Donc ce qui n'est pas décodable est conservé tel quel — d'où `JSONValue` — et
réécrit avec le reste. Écarter une entrée de la **liste** est une perte que la
bannière annonce ; l'écarter du **fichier** serait une perte que personne ne
peut annuler.

### L'objection que je m'étais faite, et pourquoi elle tombe

En rangeant ce sujet dans `ROADMAP` à la tranche précédente, j'avais écrit que
garder ce qui se décode « laisse tomber une machine en silence, et une perte
qu'on ne voit pas est pire qu'un refus franc ». C'était juste — et la réponse
existait déjà dans le code : `MachineLibraryModel` a un `loadError` et la liste
a sa bannière. Il n'y avait rien à construire, seulement quelque chose à dire.
La correction n'ajoute donc aucune vue.

### Le sabordage qui a survécu

`if let cache { return LoadOutcome(machines: cache, unreadable: 0) }` — le
chemin **mis en cache** annonçant zéro illisible. Les 952 tests sont restés
verts.

Cas 2, test manquant : chacun de mes tests créait un magasin neuf et chargeait
une seule fois. Or `reload()` est rappelé à chaque retour sur la liste, donc la
bannière serait apparue une fois puis aurait disparu toute seule pendant que les
entrées restaient illisibles — exactement la perte qui s'efface que cette
tranche existe pour empêcher. Deux tests ajoutés : un second chargement, et un
chargement après écriture. Le sabordage rougit maintenant.

### Les cinq sabordages

| sabordage | rouges |
| --- | --- |
| retour au `decode([Machine].self)` d'un bloc | 5 |
| les entrées conservées ne sont pas réécrites | 3 |
| le compte d'illisibles est toujours 0 | 2 |
| tout devient illisible (témoin inverse) | 13 |
| le chemin mis en cache annonce 0 | 0, puis 2 |

### Ce que la porte locale ne prouve pas

`Tests/WisqUITests/PartialLibraryBannerTests.swift` n'appartient à aucune cible
SwiftPM : XcodeGen le bâtit et `scripts/test-app.sh` le joue dans un iPhone
simulé. Il ne tourne donc jamais ici, et `App iOS` est son seul arbitre. J'ai
vérifié à la main que chaque symbole qu'il emploie est public et déjà utilisé
ainsi par `MachineLibrarySecretsTests` à côté.

## Les trois encodages qui ne portent aucun pixel

`extendedDesktopSize`, `desktopName` et `lastRect` n'apparaissaient dans la
suite que comme entrées de la liste `SetEncodings` — c'est-à-dire ce que wisq
**annonce**, pas ce qu'il sait en faire. Leur décodage n'était tenu par rien.

C'est précisément là que se tromper ne pardonne pas. La doc de `RFBDecoder` le
dit d'elle-même à propos d'un encodage inconnu : un rectangle mal lu laisse le
flux *« stranded with no way to resynchronise »*. Or deux de ces trois
consomment un nombre d'octets **variable** : 1 + 3 + 16×n pour le premier,
4 + longueur pour le second.

### La sonde, et pourquoi elle n'est pas le retour de la fonction

Vérifier que `decodeRectangle` rend `.renamed("bureau")` ne prouve rien sur le
cadrage : un décodeur qui avalerait ensuite tout le reste de la session rendrait
la même chose. La sonde est donc un **témoin** — un rectangle brut de 1×1 dans
une couleur que rien d'autre n'emploie, placé juste derrière — et il n'arrive
intact que si le rectangle d'avant a consommé exactement ce qu'il fallait.

Et parce qu'une sonde qui ne peut pas échouer ne prouve rien,
`testTheWitnessCanFail` décale le flux d'un seul octet et vérifie que le témoin
n'arrive pas. C'est le premier test du fichier pour cette raison.

### Aucun défaut, encore

Les dix sondes sont d'accord avec le décodeur. Comme pour hextile et CopyRect,
ce que la tranche ajoute n'est pas une correction mais la possibilité d'un
rouge : une suite verte qui n'exécutait jamais ce code ne pouvait pas rougir
pour lui.

Deux choses valaient d'être épinglées au passage, parce qu'elles sont des
décisions et non des évidences. `x` porte la raison et `y` le code de résultat :
un `y` non nul est un refus, et appliquer alors les dimensions du rectangle
déplacerait la vue vers une taille que le serveur n'a jamais adoptée. Et le nom
de bureau se lit en **latin-1**, pas en UTF-8 : les mêmes octets donnent un
autre mot dans chaque, donc se tromper renomme le bureau en quelque chose que
personne n'a choisi.

### Les six sabordages

| sabordage | rouges |
| --- | --- |
| seize octets par écran deviennent douze | 1 |
| le bourrage de trois octets devient deux | 3 |
| tout redimensionnement est réputé accepté | 1 |
| `lastRect` consomme quatre octets de trop | 2 |
| `desktopSize` simple lit une charge utile | 2 |
| le nom est lu en UTF-8 au lieu du latin-1 | 1 |

Le premier ne rougit qu'une fois, et c'est normal : seul le cas à plusieurs
écrans distingue `× 16` de `× 12`. Le cas à un seul écran, lui, ne verrait pas
la différence entre `× 16` et `× 16` — d'où la boucle sur 0, 1 puis 3 écrans
plutôt qu'un seul exemple confortable. Encore la leçon du cas facile.

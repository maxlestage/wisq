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

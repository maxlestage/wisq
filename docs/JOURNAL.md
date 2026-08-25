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

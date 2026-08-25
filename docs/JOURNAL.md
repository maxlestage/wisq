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

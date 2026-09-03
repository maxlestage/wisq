# Journal des sessions autonomes

Ce fichier existe pour une raison simple : quand le travail continue pendant
que personne ne regarde, il faut pouvoir lire le matin ce qui a été décidé la
nuit — et surtout **sur quelle autorisation**. Un agent qui fusionne des pull
requests sans que la trace de l'accord existe quelque part est un agent dont
on ne peut pas vérifier le mandat après coup.

L'ordre est antéchronologique : le plus récent en haut.

## 2026-09-03, ~22h15 UTC — le noyau disait savoir traiter sa faute ; personne ne la lui rendait

Maxime : « Vas plus vite que jamais ! ». #171 fusionné (sept vérifications
vertes), branche remise sur `master`, et la tranche suivante écrite dans la
foulée.

### La question ouverte de la session précédente, et sa réponse

Hier soir, la tentative de démarrage s'arrêtait à **538 976 instructions** du
vrai noyau d'Alpine sur une faute de page à 0x0D000000, et je ne savais pas si
elle venait du noyau ou d'une divergence de ce cœur. Le plan écrit était un
**différentiel contre QEMU** : avancer pas à pas contre un émulateur de
référence jusqu'à trouver la première divergence.

Ce plan était bon et il n'a pas servi. Avant de le monter, j'ai regardé ce que
le noyau avait posé comme état, et la réponse était là : **une IDT**, limite
0x1FF, un **seul** vecteur présent — le quatorze, la faute de page — ciblant
du code qui commence par `push %rdi ; push %rsi ; push %rdx ; …`, c'est-à-dire
la séquence d'empilement de `boot_idt_handler`.

C'est ainsi que le décompresseur 64 bits de Linux cartographie la mémoire :
**à la demande, depuis son propre gestionnaire de faute de page**. Il ne
prépare pas les tables d'avance ; il faute, et il complète. Le noyau disait
donc explicitement qu'il savait traiter cette faute. Personne ne la lui
rendait.

**Ce que ça vaut la peine de retenir** : une demi-heure de lecture de l'état de
l'invité a répondu à une question pour laquelle j'avais prévu de construire un
harnais. L'invité porte souvent la réponse ; il suffit de la lui demander.

### Ce qui a été écrit

`X86Interrupts.swift` : la recherche de porte dans l'IDT (limite comprise, bit
de présence compris), le cadre du mode long — SS, RSP, RFLAGS, CS, l'adresse de
reprise, et le code d'erreur pour les dix vecteurs qui en portent un —,
l'alignement de la pile sur seize octets, `CR2` avec l'adresse **entière**, le
masquage des interruptions selon le genre de porte, et `IRETQ`.

`LIDT` **recopie** désormais le pseudo-descripteur au lieu de retenir l'adresse
de son opérande. Noter l'adresse suffisait tant que rien ne s'en servait ; la
livraison s'en sert, et un noyau qui réutilise ces dix octets ensuite ferait
livrer n'importe quoi.

Une forme que ce cœur ne sait pas exécuter n'a **pas** de vecteur : la livrer
comme #UD ferait afficher au noyau « invalid opcode » à l'endroit d'un trou de
l'émulateur, ce qui coûte plus cher que l'arrêt.

### Le résultat, mesuré

**538 976 → 494 661 172 instructions**, soit **918 fois plus loin**. Mesuré en
release : 38,8 s, donc 12,7 MIPS sur du vrai code de noyau — un chiffre plus
honnête que celui du banc, qui tourne sur une boucle choisie. Le décompresseur
écrit le noyau à 0x0D000000 et la boucle
demande-livre-cartographie-reprend tourne toute seule.

L'arrêt suivant est **nommé** : un accès hors de la mémoire de l'invité à
l'adresse physique 0x700070D070040, dans un `rep movsq`. Une adresse absurde,
donc quelque chose l'a calculée de travers. C'est la prochaine chose à
chercher — et c'est exactement la forme d'information qu'on voulait : pas « ça
ne marche pas », mais « voici l'octet qui cloche ».

Ce qui n'est **pas** établi : où ça finit. Rien n'est encore sorti du port
série, donc « le noyau démarre » serait faux.

### Le défaut que j'ai écrit, et pourquoi le test ne le voyait pas

La livraison posait `jumped`, le drapeau qu'un branchement utilise pour dire à
`execute` « RIP est déjà où il faut ». Mais la livraison a lieu **après** que
`execute` a levé, donc personne ne le lisait — sauf la première instruction du
gestionnaire, qui le trouvait encore posé et **ne faisait pas avancer RIP**.
Elle s'exécutait deux fois. Chez Linux c'est un `push` : huit octets de trop,
et l'`IRETQ` du gestionnaire repartait sur le **code d'erreur** au lieu de
l'adresse de reprise. Le noyau sautait à 0x2 et exécutait la page zéro.

Le trouver a été rapide parce que la valeur d'arrivée le disait : RIP valait 2,
et 2 est exactement le code d'erreur d'une faute en écriture sur une page
absente. Une valeur d'arrivée absurde est souvent une valeur juste lue au
mauvais endroit.

**Et le test de bout en bout ne l'attrapait pas.** Écrit d'abord avec un
gestionnaire dont la première instruction était idempotente — écrire une entrée
de table de pages —, il passait avec le défaut remis. C'est le sabotage qui l'a
dit : douze sabotages, onze attrapés par le test nommé, un par personne. Le
gestionnaire du test compte maintenant ses propres entrées, et exige **une**.

### Ce que les sabotages ont établi

Douze sabotages sur les treize tests de `X86InterruptTests`, chacun contre les
suites x86 entières. Onze font tomber le test nommé (trois en font tomber
d'autres en plus, ce qui est du recouvrement, pas un défaut). Le douzième — le
`jumped` ci-dessus — n'a été attrapé qu'après avoir renforcé le test.

C'est aussi le seul endroit du cœur qui ne soit **pas** prouvé contre le vrai
processeur : l'oracle matériel ne peut pas produire une faute sans tuer son
harnais. Ces treize tests sont écrits à la main, contre le manuel, et chacun
nomme ce qu'il tient.

---

## 2026-09-03, ~21h00 UTC — le premier vrai chiffre : 8,4 puis 16,5 MIPS

Maxime : « Va plus vite ». J'ai donc écrit la tranche 3b **pendant** que la CI
de #170 tournait, au lieu d'attendre. #170 fusionné (sept vérifications
vertes).

### Le chiffre

D'abord **8,4 MIPS**, puis **16,5 MIPS** — mesuré par
`swift run -c release wisq-bench` sur 280 millions d'instructions en 17,0 s. Le
programme mesuré additionne, compare, saute, lit et écrit la mémoire — pas un
compteur qui tourne à vide.

À ce débit : deux milliards d'instructions, **deux minutes** ; cinquante
milliards, **cinquante minutes**. Ces deux nombres-là sont des **divisions**,
pas des mesures. Ce qui est mesuré, c'est le débit.

### Le doublement, et où il était

Maxime a dit « va plus vite ». J'ai d'abord pris ça pour moi, puis j'ai regardé
le programme. Deux gaspillages, tous deux sur le chemin le plus chaud :

1. le décodeur **allouait deux tableaux par instruction** — un pour les
   préfixes hérités, un pour le préfixe vectoriel — alors que les seules
   questions posées sont « y a-t-il un 0x66 ? » et « combien d'octets ? ». Un
   masque de bits et un tuple. (+23 %)
2. la boucle **recopiait quinze octets** dans un tampon avant chaque décodage,
   uniquement pour avoir un `Array` à donner au décodeur. Un pointeur suffit.
   (+60 % de plus)

Ensemble : **×1,96**, sans toucher à une seule règle du jeu d'instructions, et
les 9 036 accords de l'oracle matériel tiennent toujours — c'est justement à ça
qu'il sert.

Il reste environ 180 cycles par instruction sur cette machine, là où un bon
interprète en demande cinquante.

### « Vas plus vite que jamais » — CPUID, les registres de contrôle, les MSR, la MMU

Tout d'un bloc, sans attendre la CI.

**La MMU** : parcours à quatre niveaux, grandes pages de 2 Mio et de 1 Gio,
faute de page nommée avec son adresse, et un cache de traduction direct de
1024 entrées vidé par l'écriture de `CR3`. Coût mesuré : **16,4 → 15,4 MIPS**,
6 % — la première version en coûtait 13 %, parce qu'elle relisait `CR0` dans le
tableau des registres de contrôle à chaque accès mémoire.

**Le mode long s'active comme sur un vrai processeur** : `EFER.LMA` est posé
par la machine quand la pagination s'allume alors que `LME` est demandé, pas
par celui qui écrit `EFER`. Un noyau lit `LMA` pour savoir où il en est.

**`CPUID` est une décision, pas une mesure.** L'oracle matériel dirait ce que
*cette* machine répond, et c'est précisément ce qu'il ne faut pas : un invité
qui se croirait sur le processeur de l'hôte utiliserait des instructions que ce
cœur n'exécute pas. Chaque bit annoncé est une promesse tenue ailleurs, et les
tests sont écrits dans ce sens — ils partent de l'annonce et remontent à
l'instruction. Le x87 n'est pas annoncé, parce que rien ne l'exécute.

### Trois fois mes tests avaient tort et le cœur raison

**Le MSR qui ne revenait pas identique.** J'avais choisi `EFER` pour l'aller-
retour de `WRMSR`/`RDMSR`. Il revenait à un bit près — celui de `LMA`, que la
machine efface parce que la pagination est éteinte. Le cœur faisait
exactement ce qu'il fallait ; le test a changé de registre.

**Les deux tables de pages qui se marchaient dessus.** Deux correspondances
construites à la main partageaient leur dernière table, donc la seconde
écrasait la première. Symptôme : une écriture qui atterrissait à zéro.

**Le `CR3` basculé sans que le code soit mappé de l'autre côté.** La faute de
page qui suivait était juste : un vrai noyau ne bascule jamais sans que les
nouvelles tables couvrent déjà l'instruction suivante. C'est maintenant écrit
dans le test.

Quatre sabotages sur la pagination : le bit de grande page ignoré, le bit de
présence ignoré, l'étiquette du cache privée de son `+1` (sans quoi la page
zéro passe pour une entrée vide), et l'écriture de `CR3` qui ne vide plus rien.

### La tentative de démarrage, et ce qu'elle a dicté

Plutôt que de deviner ce qui manquait, j'ai **essayé** : charger le vrai noyau
d'Alpine, poser une pagination d'identité, entrer en mode long, sauter, et
regarder où ça s'arrête. Chaque arrêt a nommé la brique suivante :

| arrêt | instructions | ce qu'il fallait écrire |
| --- | --- | --- |
| opcode `FC` | 0 | `CLD`, et avec lui `CLI`/`STI`/`STD` |
| opcode `8E` | 3 | les six sélecteurs de segment |
| opcode `CB` | 26 | le retour lointain, qui recharge CS |
| opcode `9D` | 61 | `PUSHF`/`POPF`, et les opérations sur chaînes |
| opcode `DB` | 497 333 | trois instructions x87 |
| faute de page | 535 845 | la carte mémoire E820 |
| faute de page | **538 976** | — |

L'ordre n'est pas une liste que j'aurais dressée : c'est le noyau qui l'a
dicté, une instruction à la fois. C'est de très loin la façon la plus courte de
choisir quoi écrire.

**Le `DB` méritait qu'on regarde.** Une instruction x87 au milieu d'un noyau,
ça sent les données prises pour du code. J'ai désassemblé les octets :
`db e3 / dd 7c 24 0e / d9 7c 24 08` est `fninit ; fnstsw ; fnstcw` — la
séquence exacte par laquelle Linux détecte un coprocesseur. C'était du vrai
code noyau, et l'émulation était sur les rails.

**La carte mémoire comptait.** Sans les entrées E820 dans la page zéro, le
noyau croit n'avoir aucune RAM — c'est le seul champ qu'un chargeur ne peut pas
laisser à zéro. En l'ajoutant, l'arrêt a bougé **et changé de nature** : d'un
accès hors de la mémoire de l'invité à une vraie faute de traduction. Le noyau
tourne donc maintenant dans ses propres tables de pages. Les deux fautes
portent désormais des noms distincts, parce que les confondre m'avait fait
chercher au mauvais endroit pendant un moment.

**Ce que je n'écris pas.** Je ne sais pas si la faute de page finale vient du
noyau ou d'une divergence de ce cœur. Le dire demanderait un émulateur de
référence contre lequel avancer pas à pas — `qemu-system-x86_64` est là, c'est
la tranche suivante. « Le noyau démarre » serait faux ; « ça ne marche pas »
cacherait un demi-million d'instructions justes.

Coût de tout cet ajout : **15,4 → 13,5 MIPS**.

### Puis le chargeur de noyau

Pendant que la CI tournait, la première brique de la tranche 3c :
`X86BootLoader`. Il place le noyau en mode protégé à son adresse préférée,
réserve `init_size` octets — bien plus que le fichier ne pèse, parce que le
noyau se décompresse chez lui —, écrit la page zéro avec l'en-tête de setup à
ses propres décalages, et y pose ce que **seul un chargeur** sait :
`type_of_loader` à 0xFF (le laisser à zéro ferait croire au noyau qu'il a été
lancé par LILO), `LOADED_HIGH`, l'absence d'initrd écrite explicitement, et le
pointeur de ligne de commande. La ligne est coupée ici à ce que le noyau
accepte, plutôt que tronquée en silence par lui.

Le point d'entrée est à **0x200** du début du noyau, pas au début : y sauter
directement tomberait dans son en-tête interne.

Huit tests, dont un sur le **vrai** noyau d'Alpine, et cinq sabotages : charger
le fichier entier setup compris, l'entrée au début, le chargeur qui ne se nomme
pas, la ligne de commande non coupée, la page zéro sans son en-tête.

**Ce qui manque pour sauter dedans** : l'entrée 64 bits suppose le mode long
déjà actif, donc la pagination. Il faut la MMU, plus `CPUID`, les registres de
contrôle et les MSR que le décompresseur lit avant tout le reste.

### La troisième tentative, mesurée et **jetée**

L'évidence suivante : `registers` est un `[UInt64]`, donc un tableau sur le tas,
avec vérification de bornes à la lecture et d'unicité à l'écriture, deux à
quatre fois par instruction. Je l'ai remplacé par les seize valeurs en ligne
dans la structure, sous forme de tuple.

**16,5 → 15,4 MIPS.** Une régression. Deuxième variante, avec un pointeur au
lieu d'une copie d'octets : 15,5. Les deux façons d'atteindre un tuple depuis
Swift passent par un pointeur temporaire, et ça coûte plus cher que la
vérification de bornes qu'on croyait éviter.

Revenu au tableau, et la raison est écrite à côté de la déclaration pour que
personne ne retente. Ce qui distingue les deux premières optimisations de
celle-ci n'est pas leur difficulté : c'est que je les avais mesurées. Une
optimisation non mesurée est une supposition, et une sur trois était fausse.

**Ce que ça corrige.** La feuille de route disait qu'un démarrage complet
« se compte en dizaines de milliards d'instructions » et laissait entendre des
heures. Elle disait aussi, en toutes lettres, que c'était une extrapolation à
confirmer ou à contredire. Un noyau seul se compte en **minutes**.

**Ce que ça ne dit pas.** Ce cœur-ci est en Swift ; les 122,5 MIPS du rv32
sont ceux du cœur Rust. L'écart mélange deux langages et deux architectures, et
le prendre pour le coût du x86-64 seul serait faux. Et le décodeur alloue un
tableau par instruction : c'est la première chose à regarder avant de conclure.

### Ce qui a été construit

`X86Memory` — un bloc plat derrière un pointeur, parce qu'un cœur qui copierait
sa mémoire à chaque instruction ne mesurerait plus rien. `X86Core.run` enchaîne
jusqu'à un `HLT` ou un budget. Les branchements, la pile, les appels, le
groupe 5, et un port série 16550 assez complet pour qu'un noyau ne se bloque
pas en attendant de pouvoir écrire.

### L'oracle exécute maintenant des programmes

Un branchement ne se prouve pas sur une instruction seule. Le harnais matériel
a donc été déplacé à des **adresses fixes** — une adresse rendue par `mmap`
changerait à chaque exécution et le fichier ne se reproduirait pas — et il
compare aussi une fenêtre de 64 octets de mémoire. Douze programmes entiers
passent par là : boucle `loop`, sauts courts et longs, appel et retour, empiler
et dépiler dans l'autre ordre, cadre de pile complet avec `leave`, écriture aux
quatre largeurs, adressage à échelle, lecture-modification-écriture au même
endroit, saut indirect par registre, parcours de mémoire.

**9 036 accords sur 9 036.**

### Deux fois la même faute, deux fois attrapée

J'ai calculé un déplacement de saut **de tête** dans le banc : 2 au lieu de 3.
Le cœur a fait exactement ce qu'un vrai processeur aurait fait — il a exécuté
le dernier octet d'`incq` comme un `RET` — et s'est arrêté au bout de six
instructions. Puis j'ai recommencé dans un test : -5 au lieu de -4. Les deux
fois, c'est le code qui avait raison et moi qui comptais mal ; les deux fois,
la correction est venue de `as` et d'`objdump`, pas de ma tête. C'est écrit
dans les deux fichiers.

Le compteur d'instructions du test d'oracle avait le même genre de défaut : je
lui avais donné un budget en **octets** au lieu d'instructions, et la boucle
s'arrêtait au cinquième tour sur dix.

1334 → **1341** tests Swift ; 1486 avec le Rust.

## 2026-09-03, ~20h35 UTC — le cœur x86-64 calcule, et c'est le processeur qui juge

#169 fusionné (CI verte, log brut : 1324 tests, 3 ignorés, 0 échec ; j'avais
annoncé 2 ignorés — ma prévision était fausse d'un, pas le résultat). Puis la
**tranche 3a du lot 7** : ce qu'une instruction x86-64 fait aux registres et
aux drapeaux.

### La référence

Pour un décodeur, la référence est un désassembleur. Pour un cœur qui calcule,
il n'y en a qu'une : **la machine**. Ce conteneur est un x86-64. J'ai donc
écrit un harnais en assembleur qui charge les seize registres et RFLAGS depuis
la mémoire, saute dans une page exécutable, et relit tout au retour — les
chargements et rangements sont tous relatifs à RIP, parce que `mov` ne touche
pas aux drapeaux et que rien de ce que l'instruction a laissé ne doit être
écrasé ; et le retour se fait par un saut indirect ajouté après les octets à
l'essai, parce qu'un `ret` se servirait d'une pile qui appartient à l'invité.

**8 748 accords sur 8 748**, sur 336 instructions et 24 états d'entrée étalés,
plus 876 cas de division.

### La faute que j'ai failli commettre

La première version figeait **tous** les drapeaux, y compris ceux que le manuel
dit indéfinis — l'état après un `MUL`, le débordement après un décalage de
plusieurs bits, tout sauf le zéro après un `BSF`. Le processeur y pose bien
quelque chose, et j'allais m'y conformer.

C'était faux, et pas d'un peu : le fichier aurait été le portrait d'**une**
machine, celle qui l'a produit, et un cœur qui s'y conformerait serait faux sur
un autre processeur tout aussi conforme. Chaque instruction porte donc
maintenant le masque des drapeaux que l'architecture lui garantit, et seuls
ceux-là sont comparés. « Non affecté » reste dedans, parce que c'est
prévisible : c'est ainsi qu'on vérifie que `ROL` ne touche pas au zéro, ou
qu'`INC` ne touche pas à la retenue.

### Trois défauts trouvés en chemin

**Le générateur ne masquait rien.** `"mulb".rstrip("bwlq")` ne rend pas `mul`
mais `mu` — `rstrip` enlève *tous* les caractères de l'ensemble. Aucune règle
de masquage ne s'appliquait, en silence, et le fichier gardait tous les
drapeaux. Le symptôme était un désaccord ; la cause était deux niveaux plus
loin.

**Les états d'entrée n'éprouvaient qu'une moitié.** Je prenais les premiers
états d'un produit cartésien, et les vingt-quatre premiers avaient tous RAX à
zéro. Chaque valeur passe maintenant une fois par RAX.

**RIP avançait sur un refus.** J'avais écrit l'avance dans un `defer`, donc
elle avait lieu même quand l'instruction levait. Un test écrit à la main l'a
attrapé. C'est faux architecturalement : une faute de division dépose l'adresse
de l'instruction **fautive**, parce que c'est celle-là qu'un gestionnaire doit
pouvoir regarder.

### Ce que l'oracle ne pouvait pas dire, et comment je l'ai quand même obtenu

Une division par zéro ne rend pas une réponse : elle tue le harnais. J'ai
d'abord écarté la division — ce qui laissait le seul endroit du cœur qui
*refuse* sans aucune preuve. Le générateur calcule maintenant d'avance, pour
chaque cas, si le processeur lèverait, et n'envoie que ceux qui aboutissent :
876 divisions prouvées contre la machine. Les deux refus, eux, sont tenus par
neuf tests écrits à la main.

### Vérification

Huit sabotages, chacun sur une règle, chacun faisant tomber l'oracle, avec
retour au vert après chacun :

| sabotage | désaccords |
| --- | --- |
| une écriture 32 bits ne met plus le haut à zéro | 465 |
| la retenue auxiliaire n'est plus calculée | 351 |
| `ADC` ignore la retenue entrante | 120 |
| l'immédiat n'est plus étendu au signe | 183 |
| le compte de décalage n'est plus masqué | 142 |
| l'octet haut est pris pour l'octet bas | 87 |
| `INC` touche à la retenue | 115 |
| `CMP` écrit son résultat | 234 |

1324 → **1334** tests Swift ; 1479 avec le Rust.

### Ce qui reste de la tranche 3

La mémoire, les branchements et la pile, le chargement d'un `bzImage`, un port
série. C'est **3b**, et c'est là que tombera le premier vrai chiffre de
vitesse.

## 2026-09-03, ~19h45 UTC — le décodeur x86-64, prouvé contre objdump

#168 fusionné (CI verte, log brut : 1305 tests, 2 ignorés, 0 échec), branche
remise sur master, puis **tranche 2 du lot 7**.

### Ce que ça fait

`X86Decoder` lit la forme d'une instruction x86-64 : préfixes hérités, REX ou
VEX ou EVEX, table d'opcode, ModRM, SIB, déplacement, immédiat — et surtout
**où l'instruction finit**. Rien ne s'exécute. C'est délibérément le premier
morceau : sur une architecture à longueur variable, un cœur qui se trompe d'un
octet ne décode pas mal l'instruction suivante, il décode du bruit, et il le
fait sans rien dire.

### La preuve, et pourquoi c'est la seule qui vaille

Écrire une table d'opcodes à la main puis la relire, c'est vérifier son propre
travail contre lui-même. Alors le décodeur est confronté à `objdump` 2.42 sur
un vrai corpus : **647 912 instructions** désassemblées de `/bin/ls`,
`/bin/bash` et la libc du système, plus **53 formes assemblées exprès** parce
qu'aucun compilateur moderne ne les émet — `moffs`, `ENTER`, `RET imm16`, et
les six opérations de `F6`/`F7` qui ne portent pas d'immédiat. Verdict :
**647 965 accords, zéro désaccord, zéro refus**.

Le corpus mesuré, qui a décidé du travail : 82,5 % d'opcodes d'un octet,
15,8 % de table `0F`, 0,92 % de VEX à deux octets, 0,46 % d'EVEX, 0,22 % de
VEX à trois octets, 0,08 % de `0F 3A`, 0,005 % de `0F 38`. C'est ce 1,6 % de
préfixes vectoriels qui a décidé de les décoder tout de suite : ils ne
doublent pas le travail, parce que leur champ `mmmmm` désigne les **mêmes**
tables que les échappements hérités.

### Ce que j'ai refusé de croire

Le différentiel est passé **du premier coup** sur 647 912 instructions. C'est
exactement le genre de résultat qu'il ne faut pas croire : j'ai fait imprimer
au test ce qu'il lisait et ce qu'il comparait (647 912 lues, 647 912 d'accord),
puis j'ai trouvé le vrai trou — le test du corpus entier n'avait **aucune
borne sur le nombre de cas**, donc un fichier vide l'aurait fait passer pour
zéro accord sur zéro. La borne y est.

Ensuite j'ai mesuré ce que le corpus **n'atteint pas** plutôt que de supposer
qu'il atteignait tout : `moffs`, `ENTER`, `RET imm16` et `F6`/`F7 /1` n'y
étaient pas. Plutôt que d'écrire ces quatre cas de mémoire, je les ai fabriqués
avec l'assembleur GNU et repassés par objdump — la référence reste la
référence, pas ma conviction.

### Vérification

Huit sabotages, chacun sur une règle, chacun faisant tomber le différentiel,
avec retour au vert après chacun. Sur le corpus entier puis sur l'extrait de
9 222 formes qui va dans le dépôt — les huit y mordent aussi, en 0,09 s :

| sabotage | corpus entier |
| --- | --- |
| `0x83` avec un immédiat de la taille de l'opérande | 37 793 refus |
| `F6`/`F7` portant toujours leur immédiat | 1 708 refus |
| le relatif à RIP sans ses quatre octets | 33 112 désaccords |
| la base 101 du SIB sans déplacement | 4 153 désaccords |
| l'immédiat « taille d'opérande » ignorant `0x66` | 185 refus |
| `movabs` ignorant `REX.W` | 690 désaccords |
| la table `0F 3A` sans son octet immédiat | 733 désaccords |
| le VEX à trois octets n'en lisant que deux | 916 désaccords, 379 refus |

Plus dix-sept tests de **forme** à côté du différentiel : un décodeur peut
tomber sur la bonne longueur pour deux mauvaises raisons qui s'annulent, et
c'est ce que le différentiel seul laisserait passer. Chaque suite d'octets de
ces tests a été repassée par objdump avant d'être écrite — dont une dont mon
commentaire était faux (`8b 04 25 00 00 00 00` est « mov 0x0,%eax », pas
« mov 0x0(,%riz,1),%eax »), corrigé avant d'être poussé.

1305 → **1324** tests Swift ; 1469 avec le Rust.

### Ce que ça ne fait toujours pas

Aucune instruction ne s'exécute. La tranche 3 est le cœur en mode long, et
c'est **elle** qui donnera le premier vrai chiffre de vitesse — celui qui
confirmera ou contredira l'extrapolation de la feuille de route.

## 2026-09-03, ~19h10 UTC — le premier morceau de x86-64 : lire l'en-tête

#167 fusionné (CI verte, lue dans le log brut : 1291 tests, 1 ignoré, 0 échec,
sept vérifications au vert), branche remise sur master, puis **tranche 1 du
lot 7**.

### Ce que ça fait

Quelqu'un qui importe un noyau Linux pour PC — le fichier qu'il faudra
vraiment — n'entend plus « ce n'est pas ça ». Il entend ce que son fichier
**est** : « vmlinuz-lts est un noyau Linux pour PC (x86-64, protocole de
démarrage 2.15). C'est le bon genre de fichier — un noyau, pas une image de
disque — mais pas encore pour cette machine. » Et le message dit où en est le
travail plutôt que de dire non.

C'est la suite directe de la correction d'hier soir : d'abord ce qu'un fichier
est, ensuite seulement ce qu'il pèse.

### Mesuré, pas recopié

`vmlinuz-lts` d'Alpine Linux 3.20 pour x86_64 a été téléchargé et lu :
10 961 920 octets, sha256 `e214570926…`. Protocole 2.15. 39 secteurs de setup,
donc 20 480 octets, puis `syssize` = 683 840 paragraphes = 10 941 440 octets.
**Les deux moitiés tombent pile sur la taille du fichier** — c'est devenu une
garde : un fichier qui annonce plus qu'il ne pèse n'est pas un bzImage. En
inégalité et non en égalité, parce qu'un noyau signé (Ubuntu, Fedora) porte sa
signature après.

`xloadflags` = 0x3F, donc le bit 0 : il y a une entrée 64 bits. C'est le **seul**
énoncé qu'un bzImage fait sur son propre mode — il n'a pas d'en-tête ELF qui
nommerait sa machine.

Le noyau lui-même n'est pas dans le dépôt : dix mégaoctets de binaire GPL pour
épingler neuf entiers, c'est un mauvais échange. Les tests reconstruisent un
en-tête portant exactement les valeurs mesurées, et repassent sur le vrai
fichier quand `WISQ_PC_KERNEL` le désigne.

### Trois choses que la tranche a apprises

**Un bzImage ne commence pas par ELF, mais par « MZ »** — le talon EFI. Rien
dans le code ne le nommait, donc il tombait dans `unknown`, c'est-à-dire dans
« essaie quand même ».

**Un ISO hybride porte le même 0xAA55 à 0x1FE qu'un noyau** : c'est le secteur
d'amorçage MBR. Les deux reconnaissances se marchent dessus, et seul l'ordre
les sépare — l'image de disque d'abord, parce que c'est ce qu'un tel fichier
**est**. Le sabotage qui inverse les deux fait tomber le test qui le dit.

**Les champs sont apparus au fil des versions du protocole.** `xloadflags` à
partir de 2.12, `pref_address` et `init_size` à partir de 2.10, `cmdline_size`
à partir de 2.06. Lire un champ qu'un vieux noyau n'a jamais écrit, ce serait
lire le hasard des octets qui traînent là. Chacun est donc gardé par la version
qui l'a introduit.

### Vérification

Six sabotages, chacun sur une garde, chacun tombant sur le test qui la nomme,
contre la suite entière et sur un vert établi : la magie « HdrS » mise en
minuscules, `xloadflags` lu sans garde de version, la borne de taille retirée,
`setup_sects` à zéro ne valant plus quatre, le décalage d'`init_size` glissé de
quatre octets, et l'ordre ISO/noyau inversé. Retour au vert après chacun.

1291 → **1305** tests Swift ; 1450 avec le Rust.

### Ce que ça ne fait pas

Rien de x86-64 ne s'exécute. C'est un lecteur d'en-tête, pas un cœur. La
tranche 2 est le décodeur, prouvé par différentiel contre un désassembleur de
référence ; la tranche 3 donnera **le premier vrai chiffre de vitesse**, celui
qui confirmera ou contredira l'extrapolation écrite dans la feuille de route.

## 2026-09-03, ~18h45 UTC — la plate-forme change, et le diagnostic d'abord

Maxime : « Je veux pouvoir gérer ma ram et je veux pouvoir la gérer en étant
deux giga plus petit que l'iPhone 17 Pro n'a de ram et faut changer la
plate-forme car risc-v c'est pas la bonne solution pour des distribution
complète ».

### Ce que j'ai corrigé avant de répondre

**RISC-V n'était pas le blocage.** Debian, Ubuntu et Fedora ont des ports
riscv64 officiels. Ce qui empêche une distribution complète de tourner ici,
ce sont trois choses précises : la machine est en **32 bits**, elle est
**nommu** (pas de MMU, donc pas l'espace d'adressage virtuel dont dépend toute
distribution), et elle n'a **aucun disque**.

Le dire changeait la question posée. Je la lui ai reposée avec les trois
options et leur coût, mesure à l'appui, et il a choisi **x86-64 + MMU +
disque** — l'option la plus lourde, et celle qui fait tourner précisément ce
qu'il veut faire tourner. Sa décision, prise en connaissance du prix.

### La mesure qui rend la conversation honnête

**122,5 millions d'instructions par seconde** : 200 M en 1,63 s, cœur Rust en
release, sur un vCPU de datacentre. C'est du rv32, dont le décodage est simple ;
x86-64 coûte nettement plus par instruction. Un démarrage de bureau se compte
en dizaines de milliards d'instructions, et **iOS interdit le JIT** aux
applications de l'App Store — donc tout sera interprété.

J'ai écrit dans la feuille de route que l'extrapolation *est* une
extrapolation, et que la tranche 3 devra la contredire ou la confirmer avec un
vrai chiffre. Une estimation qui se transforme en fait par répétition est
exactement ce que ce journal existe pour empêcher.

### Sa règle de mémoire, et son bord net

« Deux giga plus petit que ce que le téléphone a » vit maintenant **à côté** de
`os_proc_available_memory()`, pas à sa place : l'une dit de combien d'un
appareil wisq accepte d'être, l'autre ce qui est libre à cet instant. La plus
petite décide.

Le bord vaut d'être regardé en face : sur un appareil de deux gibioctets ou
moins, « deux gibioctets de moins » vaut **zéro**. C'est le plancher — la
machine de référence — qui répond, et un test le dit explicitement plutôt que
de laisser la découverte à quelqu'un avec un vieux téléphone.

### Ce qui ne change pas

La machine rv32 reste. Elle démarre en une seconde, elle est utile, et elle
sert de témoin : le test différentiel entre deux cœurs a déjà attrapé assez de
choses pour qu'on ne s'en prive pas en cours de route. Et une distribution
complète tourne **aujourd'hui** sur un hôte, avec wisq comme écran — le lot 7
ajoute un chemin, il n'en remplace aucun.


## 2026-09-03, ~19h30 UTC — « Ça fonctionne pas je te l'avais dit ! »

Maxime a envoyé une capture. L'application refuse `omarchy-4.0.2.iso 2` avec :

```
[omarchy-4.0.2.iso 2 fait 5939.2 Mo. La machine émulée n'a que 64.0 Mo
de mémoire en tout.
```

**Chaque mot est vrai, et le message entier est trompeur.** Il désigne un
*nombre*, donc il envoie vers le réglage de mémoire — celui que je venais
justement de passer deux heures à rendre réglable jusqu'à deux gibioctets. Il
avait toutes les raisons de croire que ça allait marcher, et j'y ai contribué :
mes trois derniers messages parlaient de gigaoctets.

Aucune mémoire ne fera jamais démarrer ce fichier ici. Omarchy est une
distribution Arch **x86-64** distribuée en **image de disque amorçable**. La
machine locale de wisq est un RISC-V 32 bits nommu **sans disque**. Ce n'est ni
la même architecture, ni le même genre de fichier.

### Ce que le refus dit maintenant

Ce que le fichier **est**, avant ce qu'il pèse. Mesuré sur les octets plutôt
que lu dans un document :

```
le vrai noyau : « RISCV » à 0x30, « RSC\x05 » à 0x38   (en-tête d'image RISC-V)
un ISO 9660   : « CD001 » à 0x8001                     (descripteur, secteur 16)
un ELF        : \x7fELF, et l'architecture à 0x12
```

Quarante kibioctets suffisent à décider — lire six gigaoctets pour savoir ce
qu'est un fichier serait exactement la faute qui a fait disparaître
l'application la première fois.

Le message nomme le fichier, ce qu'il est, ce qu'est la machine, **coupe court
au réglage de mémoire**, et dit où faire tourner la chose voulue : sur un hôte,
avec wisq par-dessus. Un test exige cette dernière phrase, et un autre exige
que le message ne ressemble pas à un refus de taille.

### L'asymétrie, qui est le vrai choix de conception

Reconnaître une image RISC-V est un fait positif. **Ne pas** en reconnaître une
n'en est pas un. Quelqu'un peut arriver avec une image brute sans en-tête, et
la refuser parce que ce code ne la connaît pas serait pire que de la laisser
essayer. Donc `unknown` est une **permission**, pas un doute : seul ce qui est
positivement identifiable comme autre chose est refusé. Le sabordage qui
transforme `unknown` en refus tombe sur le test qui le dit.

### Ce que je retiens

Un refus juste peut égarer autant qu'un refus faux, s'il désigne la mauvaise
cause. « Trop gros » et « pas la bonne machine » mènent à deux gestes
différents, et le premier était un cul-de-sac déguisé en piste.


## 2026-09-03, ~18h UTC — arrêter d'inventer un plafond, et demander à iOS

Maxime : « je voudrais aussi que tu utilises la mémoire de mon téléphone pour
la partager ».

La réponse évidente était d'augmenter ma fraction — le huitième de la mémoire
physique devient un quart, un tiers. **La bonne réponse était d'arrêter
d'inventer.** iOS publie exactement ce nombre : `os_proc_available_memory()`
rend combien d'octets l'application peut encore allouer avant que le système ne
la tue. C'est la question à laquelle mon huitième essayait de répondre au
jugé.

Le plafond est maintenant : ce que le système dit qu'il reste, moins ce que
l'application garde pour elle, borné par ce que le processeur 32 bits de
l'invité peut adresser, et jamais sous la machine de référence.

### Trois choses que la fraction ne pouvait pas faire

Elle donnait **la même réponse** sur un téléphone au repos et sur un téléphone
qui porte trois autres applications. Elle ignorait ce que wisq lui-même avait
déjà ouvert — une session distante avec ses tampons de décodage compte. Et elle
était figée à la conception, alors que la vraie question se pose à l'instant du
démarrage.

Le plafond est donc relu à chaque fois qu'on le demande, pas mémorisé.

### La réserve, qui est un jugement et le dit

256 Mio pour l'application elle-même : la console et sa grille, les tampons
d'une session distante, l'image du noyau en cours de lecture. Un nombre nommé
plutôt qu'une fraction, parce qu'il ne grandit pas avec l'invité — une machine
plus grande ne fait pas une console plus grande.

### Et le refus qui remplace un plantage

Le réglage est mémorisé ; la place libre du téléphone ne l'est pas. Un appareil
qui pouvait donner un gibioctet ce matin peut ne plus le pouvoir cet
après-midi. Démarrer quand même, c'est se faire tuer par iOS au milieu du
démarrage — le plantage sans cause apparente que cette application a déjà
infligé une fois, sur l'image d'Omarchy.

Donc une phrase, avec **les deux chiffres et quoi en faire**. « Pas assez de
mémoire » sans nombre est une impasse : le lecteur ne peut pas savoir s'il doit
fermer une application ou baisser le curseur. Un test l'exige explicitement.


## 2026-09-03, ~17h45 UTC — un curseur en gigaoctets, et le défaut que la question a fait sortir

Maxime : « Tu peux pas faire un curseur pour allouer des giga plutôt que des mo
car maintenant les ram sont plutôt en giga ».

Sa question portait sur l'unité. En allant mesurer jusqu'où la machine monte,
j'ai trouvé autre chose.

### La machine ne s'arrêtait pas là où je croyais

Mesuré sur le vrai noyau :

```
 512 Mio : Memory:  516204K/524272K   bannière oui, invite oui
   1 Gio : Memory: 1036012K/1048560K  bannière oui, invite non
   2 Gio : Memory: 2075628K/2097136K  bannière oui, invite non
```

L'invite qui disparaît au-delà de 512 Mio ressemblait à une limite. **Ce n'en
était pas une** : avec un budget de 120 millions d'instructions au lieu de 60,
elle arrive à 1 Gio comme à 2. Linux passe la différence à initialiser ses
pages. Un test qui aurait gardé le budget d'origine aurait conclu « 2 Gio ne
démarre pas » et j'aurais répondu à Maxime que les gigaoctets étaient hors de
portée. Le test qui garde cette taille explique le budget pour cette raison.

### Le défaut, et il était muet

Au-delà, l'espace d'adressage déborde : la RAM de l'invité commence à
`0x8000_0000` et le hart adresse en trente-deux bits, donc **deux gibioctets
tombent exactement sur le dernier octet possible** (`0x8000_0000 + 2 Gio ==
2^32`). Une machine de trois gibioctets :

```
load accepté, DTB annonce 3221209088 octets
bannière = false   invite = false   — rien, pas même une erreur
```

Elle se construisait, annonçait à l'invité une mémoire qui n'existe pas dans
son espace d'adressage, et mourait sans un mot. Les deux cœurs la refusent
maintenant (`ramSizeUnsupported` / `LoadError::RamSizeUnsupported`, code −6 à
travers l'FFI), parce que deux implémentations d'une même machine qui ne sont
pas d'accord sur ses limites est la divergence que le test différentiel existe
pour empêcher.

Le refus vit dans `load` et non dans `init` : un initialiseur faillible pour
une condition dont aucun appelant ne peut se remettre autrement coûterait plus
qu'il ne rapporte, et `load` est l'endroit où l'invité est renseigné.

### Et l'unité, qui était la question

Le plus grand palier s'affichait « 1024 Mo ». C'est exactement ainsi qu'un
réglage qui atteint le gibioctet passe pour un réglage qui s'arrête aux
mégaoctets — Maxime l'a lu comme ça, et il avait raison de le lire comme ça.

`KernelMemory.describe` bascule en Gio dès qu'il y en a. Et le plafond, qui
était écrit « un gibioctet », est maintenant la limite de l'architecture : les
deux coïncidaient, ce qui faisait passer une contrainte pour un choix. Un
appareil de 16 Go atteint donc vraiment deux gibioctets ; la règle du huitième
continue de protéger les petits.

### Le menu devient un curseur

Il glisse sur les **indices** des paliers, pas sur des octets : il saute donc
de puissance de deux en puissance de deux au lieu de proposer des tailles
qu'aucune machine n'a jamais eues.


## 2026-09-03, ~17h20 UTC — la garde que ni l'une ni l'autre des deux suites ne pouvait tenir

Petite tranche, et sa justification tient en une mesure.

La tranche précédente a ajouté deux champs au protocole. Les tests du crate
montrent que le démon les **écrit**. Ceux de `WisqCore` montrent que le client
sait les **lire**. Aucun des deux ne dit qu'ils sont d'accord sur le **nom de
la clé** — et depuis que les deux moitiés de wisq ne sont plus écrites dans le
même langage, c'est la seule chose qui compte vraiment.

`AgentEndToEndTests` fait tourner le vrai démon Rust sur un port éphémère et
lui parle avec le `AgentClient` que l'application embarque. Deux tests de plus
y demandent la mémoire.

### La mesure qui justifie ces deux tests

Renommer la clé d'un seul côté, **proprement** — dans l'écriture *et* dans le
test Rust qui l'épingle, comme le ferait quelqu'un qui refactorise :

```
la suite Rust seule       : 73 passed; 0 failed
la suite bout-à-bout      : 4 échecs
```

Soixante-treize tests verts, et seule la traversée attrape la divergence. Sans
elle, une faute de frappe dans « maximumMemoryKiB » ne se serait vue que sur un
téléphone, en production, sur une ligne restée vide sans que rien n'échoue.

Un premier sabordage — la faute de frappe dans l'écriture seule — tombait des
deux côtés, ce qui était rassurant mais ne prouvait rien : le test Rust épingle
la chaîne JSON exacte, donc il l'aurait vu. Il fallait saboter comme un humain
se trompe, c'est-à-dire de façon cohérente.

Au passage, le second test dit une chose qui n'allait pas de soi : **démarrer
une VM n'efface pas sa mémoire**. C'est une propriété de la machine, pas de sa
session, et `settle` aurait pu la remettre à zéro sans que rien ne le remarque.


## 2026-09-03, ~17h UTC — la mémoire des VM distantes, lue avant d'être écrite

Le second sens de « partout » : les machines que l'agent gère sur un hôte. Le
protocole n'en portait rien — `Vm` avait un identifiant, un nom, un état, une
console et un système invité, pas un octet de mémoire.

Cette tranche **lit**, elle n'écrit pas. C'est délibéré et c'est ce que les
mesures de l'heure précédente imposent : réduire la mémoire d'un invité vivant
n'est pas un acte, c'est une demande à son pilote balloon que libvirt accepte
en silence et qu'un invité sans ce pilote ignore pour toujours. Écrire d'abord
et découvrir ensuite quoi en dire serait construire le curseur avant de savoir
s'il commande quelque chose.

### Une commande de moins, deux nombres de plus

`describe` demandait l'état avec `virsh domstate`. `virsh dominfo` porte le même
état, dans le même vocabulaire, avec le même code de retour sur un domaine
inconnu — mesuré, pas supposé — **et** les deux chiffres de mémoire. Le
remplacement ne coûte donc aucun appel de plus : il en économise plutôt un, dans
un chemin appelé une fois par VM à chaque rafraîchissement de la liste.

Vérifié contre un vrai libvirt, à travers le vrai agent :

```
{"id":"blind-vm","maximumMemoryKiB":262144,"memoryKiB":131072,
 "name":"blind-vm","state":"stopped"}
```

### Deux nombres, parce que libvirt en garde deux

Le maximum est ce avec quoi la machine a été construite et ne peut pas changer
pendant qu'elle tourne ; la part courante est ce qu'elle a le droit d'utiliser
maintenant. Sur un domaine éteint, les deux viennent de sa définition. Les
confondre serait perdre exactement la distinction qui rendra la tranche
d'écriture honnête.

L'interface ne montre les deux **que lorsqu'ils diffèrent**. Sur presque toutes
les machines ils sont égaux, et écrire « 256 Mio sur un maximum de 256 Mio »
partout apprendrait à sauter la ligne sur la seule machine où elle dit quelque
chose.

### Trois refus d'inventer

L'unité est **vérifiée**, pas coupée : `262144 KiB` se lit, `256 MiB` rend
« je ne sais pas ». Une version de libvirt qui changerait d'unité serait sinon
lue mille fois trop petite sans que rien ne le remarque.

Une ligne absente rend `None`, jamais zéro. Zéro se lirait « aucune mémoire »,
ce qui est faux et affichable.

Et côté téléphone, la mémoire est décodée avec `try?` — la moitié tolérante de
la règle qui gouverne déjà l'état. Elle est **montrée**, jamais agie : un agent
qui l'enverrait dans une forme que cette version ne comprend pas doit coûter une
ligne de texte à cette VM-là, pas la liste entière dans laquelle elle est
arrivée. C'est la quatrième fois que cette forme revient dans ce dépôt, et la
première où elle a été écrite juste du premier coup.

### Un sabordage raté, et ce qu'il a appris

« Les deux nombres viennent de la même ligne » n'a rien cassé : la boucle lit
`Max memory` avant `Used memory`, donc la seconde ligne écrasait mon écrasement.
Le sabordage était mauvais, pas la garde absente — refait dans l'autre sens
(`Used memory` écrase aussi le maximum), il tombe sur les deux tests qui
distinguent les nombres. Un sabordage qui ne mord pas mérite d'abord qu'on
regarde s'il a seulement été exécuté.

Huit au total, tous mordants : l'unité qui n'est plus vérifiée, les deux nombres
confondus, les deux étiquettes échangées, l'état que `dominfo` ne rend plus, le
JSON qui écrit un zéro plutôt que rien, la liste que perd une mémoire illisible,
les deux nombres toujours dits, et les tailles comptées en puissances de dix.


## 2026-09-03, ~16h30 UTC — « l'espace de stockage », et ce que ça peut vouloir dire

Deuxième moitié de la demande de Maxime. Elle demande d'abord d'être honnête
sur ce qu'elle ne peut pas être.

**Il n'y a aucun disque dans la machine locale**, et ce n'est pas un manque :
c'est une décision, écrite dans la feuille de route depuis longtemps. Les
noyaux rv32 « nommu » de cette famille ont virtio-mmio mais aucun pilote de
bloc, et l'utilisateur apporte son propre noyau ; sauver la machine entière —
RAM, registres, timer, octets en attente sur l'UART — contourne l'invité et
marche avec n'importe quel noyau. Un curseur « taille du disque » serait donc
un réglage qui ne commande rien.

Ce qui est réel, c'est la place que **noyaux et machines sauvegardées**
occupent dans le stockage de l'application.

### Une phrase que j'ai écrite, et que la mesure a démentie

J'avais écrit — dans le code, dans l'interface et ici — qu'« une machine
sauvegardée ne peut pas dépasser la RAM dont elle a été prise, donc un noyau
réglé à un gibioctet peut laisser derrière lui un fichier cent fois plus gros
que le noyau lui-même ». C'est faux, et il a suffi de mesurer sur le vrai
noyau pour le voir :

```
machine    après 5 M instructions    après 65 M (invite de connexion)
 64 Mio          8,9 Mio                      16,4 Mio
128 Mio          9,5 Mio                      17,0 Mio
256 Mio         10,5 Mio                      18,4 Mio
```

**Le coût suit ce que l'invité a touché, pas ce qu'on lui a donné.** Quadrupler
la machine ajoute deux mégaoctets, parce que Linux ne touche pas la mémoire
dont il n'a pas l'usage et que les suites de zéros sont repliées. Dépenser dix
fois plus d'instructions double presque le fichier, parce que là c'est de la
mémoire réellement écrite.

La phrase était plausible et elle sonnait prudente — c'est exactement la forme
qu'une affirmation fausse prend quand elle traverse une relecture. Elle était
partie dans une chaîne que l'application montre à qui l'utilise.

Corrigée aux trois endroits, et surtout transformée en garde :
`ResizedSnapshotCostTests` démarre le vrai noyau dans une machine de 64 et une
de 256 Mio et exige que quadrupler la mémoire ne double pas l'instantané. Le
sabordage — la course littérale avale aussi les zéros, donc plus rien n'est
replié — le fait tomber sur ses trois assertions.

Ce qui reste vrai, et qui justifie la tranche : **dix-sept mégaoctets par noyau
suspendu**. Cinq noyaux laissés suspendus font quatre-vingt-cinq mégaoctets,
apparus sans que personne les ait demandés, et un nombre que personne ne voit
est un nombre sur lequel personne ne peut agir.

### Ce qui est montré

Sous chaque noyau, ce qu'il pèse **et ce que ses machines sauvegardées pèsent à
côté** — mais seulement quand il y en a. La taille du noyau seul ne mérite pas
une ligne : c'est le fichier que la personne vient d'importer, il ne la
surprendra pas. Ce qui mérite d'être dit est ce qui est apparu tout seul.

Puis un total, et le sous-total des machines sauvegardées.

### Ce que je n'ai pas fait, et c'est le point

Pas de **plafond qui supprime**. J'ai écrit dans la feuille de route qu'il
faudrait « plafonner » ; en le construisant, la forme évidente était une
politique d'éviction — au-delà de N mégaoctets, la plus ancienne machine
sauvegardée disparaît. Non. Supprimer les données de quelqu'un sans qu'il l'ait
demandé, en silence, pour rester sous un nombre qu'il n'a pas choisi, n'est pas
un service. Ce qui est là est le chiffre, et un geste explicite.

Le seul nettoyage automatique n'en est pas un : il est proposé, pas fait. Les
machines sauvegardées dont **le noyau n'existe plus** sont du poids mort par
construction — un instantané ne se restaure pas sans le noyau dont il vient —
et elles existaient parce que supprimer un noyau ne retirait que le fichier.
Ça ne l'est plus depuis la tranche précédente, donc ce compteur ne peut plus
que décroître ; il montre ce que les versions d'avant ont laissé, et il faut
appuyer pour le reprendre.

### Le même piège, une troisième fois

`machine-Image-2-ff.wisqvm` commence par `machine-Image-`. La tranche
précédente avait ancré le motif des deux côtés pour l'oubli ; ici, la même
question se pose pour compter — et un préfixe aurait attribué à « Image » les
octets de « Image-2 », donc faussé un total sans rien casser de visible. Le
motif est maintenant dans **une seule** fonction que les deux appellent, avec
son test.

### Puissances de deux, et l'unité qui le dit

Les tailles s'affichent en Kio/Mio/Gio. Tout le reste du dépôt compte la
mémoire en puissances de deux ; un chiffre de stockage en puissances de dix à
côté d'un chiffre de mémoire qui ne l'est pas rendrait les deux incomparables,
et c'est précisément côte à côte qu'ils apparaissent maintenant.


## 2026-09-03, ~16h UTC — le réglage de mémoire, et ce qu'il coûte

La tranche précédente a rendu la mémoire réglable dans les deux cœurs. Celle-ci
la met dans la main de qui utilise l'application : chaque noyau de la liste
porte sa taille, à droite de son nom.

### Trois décisions, et pourquoi

**Par noyau, pas globalement.** Deux noyaux dans la même liste n'ont aucune
raison de tourner à la même taille, et quelqu'un qui monte à 256 Mo le fait
pour une image précise.

**Classé par nom de fichier, pas par empreinte** — l'inverse de
`SuspendedMachine`, qui prend l'empreinte parce que deux noyaux importés à une
semaine d'écart s'appellent tous les deux `Image` et donner au second
l'*instantané* du premier restaurerait une machine qui n'a jamais existé. Une
taille n'est pas un état : au pire un fichier remplacé hérite d'une préférence
qu'on change d'un geste. Et surtout, la lire ne demande aucun octet — ce qui
est nécessaire, parce que le chemin de démarrage doit connaître la taille de la
machine **avant** de lire l'image, et l'empreinte n'existe qu'après.

**Le plafond vient de l'appareil, pas d'un nombre écrit à la main** : un
huitième de la mémoire physique, borné à un gibioctet, jamais sous la machine
de référence. Un huitième et pas un tiers — jetsam, la limite à laquelle iOS
tue, est autour du tiers sur les téléphones qu'iOS 17 fait tourner, la RAM de
l'invité devient entièrement résidente, et l'application a besoin de place à
côté. Le premier brouillon disait « un quart » : sur un téléphone de 2 Go cela
donne 512 Mo d'invité, assez près de jetsam pour que le réglage livre un
plantage. C'est une **politique**, pas une mesure, et le code le dit.

### Deux seuils, et pourquoi ce ne sont pas les mêmes

À l'import, un fichier est jugé sur la **plus grande machine que l'appareil
autorise** : au moment où il arrive, aucune taille n'a été choisie, et le
refuser sur le défaut refuserait un fichier importé exprès pour tourner plus
grand. Au démarrage, il est jugé sur la machine **de ce noyau-là**. Les deux
sont justes à leur moment.

### Ce que change coûte, dit plutôt que subi

Un instantané pris à une autre taille ne peut pas être restauré — les deux
cœurs refusent l'écart depuis toujours, c'est vérifié. Le laisser sur le disque
serait donc laisser un fichier que rien ne relira jamais. Changer la taille
l'oublie, et l'application dit combien de machines cela a coûté — ou ne dit
rien du tout quand ça n'a rien coûté, parce qu'annoncer une perte qui n'a pas
eu lieu apprend à ignorer le message suivant.

Oublier par nom demandait une garde à laquelle je ne pensais pas :
`machine-Image-2-ff.wisqvm` **commence par** `machine-Image-`, donc un simple
test de préfixe, demandé d'oublier `Image`, aurait aussi oublié `Image-2`. Le
motif est ancré des deux côtés — tout ce qui suit le nom doit être
l'empreinte hexadécimale. Le sabordage qui remet le test de préfixe tombe sur
ce test précis.

Et supprimer un noyau oublie maintenant trois choses au lieu d'une : le
fichier, son réglage, et les machines sauvegardées. Sinon un noyau réimporté
sous le même nom hériterait en silence d'un réglage que son propriétaire avait
supprimé.

### Sabordage

Six, chacun tombant sur son test et sur lui seul : la taille enregistrée qui
n'est plus rognée par le plafond de l'appareil, le plafond qui redevient un
quart, `clearAll` qui redevient un test de préfixe, le réglage qui cesse d'être
classé par noyau, le retour au défaut qui écrit le nombre au lieu d'effacer
l'entrée, et la garde qui refusait une valeur hors de la liste offerte.


## 2026-09-03, ~15h UTC — la mémoire réglable, et l'invité qui l'apprend

Maxime : « Je veux pouvoir ajuster de la ram et de l'espace de stockage
partout ». Cette tranche fait la mémoire ; le stockage suit, et il faudra en
dire quelque chose d'honnête (la machine locale n'a **aucun disque** — noyau
nommu, pas de pilote bloc — donc « espace de stockage » ne peut pas vouloir
dire disque virtuel).

### Ce qui existait déjà, et ce qui manquait

Le cœur Rust prenait déjà `ram_size`, et l'FFI le passait. Ce qui manquait
était plus petit et plus grave : la **cellule mémoire du device tree**. Le blob
vient verbatim de mini-rv32ima et annonce `0x03ff_c000` — 64 Mio moins seize
kibioctets. Une machine allouée avec 128 Mio faisait donc tourner un noyau à
qui personne n'avait dit qu'il en avait plus : la mémoire existait, elle ne
servait à rien.

L'offset a été trouvé en marchant l'arbre, pas en comptant : la propriété `reg`
de `/memory@80000000` est à 304 et porte quatre cellules — base haute, base
basse, taille haute, taille basse — donc le nombre que le noyau lit est à
**316**. La réserve de seize kibioctets en haut est celle de la référence, pas
la nôtre : elle est bien plus grande que ce que le DTB et l'état réservé
occupent, et la garder à toutes les tailles est ce qui fait qu'une machine
redimensionnée se comporte comme celle-là.

### La preuve, par un vrai noyau

Un DTB peut annoncer ce qu'on veut ; seul le noyau dit s'il l'a cru. Il
l'imprime :

```
64 Mio  : Memory:  61372K/65520K available
128 Mio : Memory: 126348K/131056K available     ← 131 056 Kio = 128 Mio − 16 Kio
```

Et les deux cœurs doivent le faire **de la même façon** : `DifferentialResizedTests`
démarre le même noyau dans deux machines de 128 Mio, une par cœur, et exige le
même nombre d'instructions retirées, les mêmes octets de console, et la même
ligne « Memory: ». Deux implémentations de la même règle est exactement la
situation où l'une dérive sans que personne le voie.

### Trois pièges, dont deux qui font passer un test pour rien

**Un.** `output.split(separator: "\n")` ne coupait rien. La console du noyau
termine ses lignes par CRLF, et en Swift la paire `\r\n` est **un seul**
`Character` : compté sur ce noyau, 47 sauts de ligne et **zéro** « \n » au sens
des Characters. Le `split` rendait donc une seule tranche contenant tout le
journal, et le premier `contains("Memory:")` tombait dessus — le test passait
en lisant la bannière de version. Le séparateur est maintenant `\.isNewline`,
et le commentaire dit la mesure.

**Deux.** Un sabordage a remis `dtb::BYTES` verbatim dans le `load` du cœur
Rust — le redimensionnement entièrement défait — et les **onze** tests du crate
sont passés. Les tests du module `dtb` prouvaient que `bytes_for` calcule le
bon blob ; aucun ne demandait ce que `load` avait remis à l'invité. Trois tests
posent maintenant la question là où le noyau la lit : dans la RAM, à l'adresse
que `load` a mise dans a1. Même trou côté Swift, même correctif
(`deviceTreeHandedToTheGuest`), et seul le test qui démarre un vrai noyau
tombait avant — or il saute quand l'image est absente, donc la garde ne tenait
rien sans elle.

**Trois.** Le sabordage Rust a d'abord semblé inoffensif *vu du test
différentiel* : `swift test` **ne réédite pas les liens** quand seul le `.a`
Rust a changé. Le binaire de test datait de 15h29, la bibliothèque de 15h30, et
la comparaison portait sur un cœur périmé. `rm .build/debug/WisqPackageTests.xctest`
avant de relancer, et il mord sur les trois affirmations. La CI ne le voit pas
— elle construit à neuf — mais en local c'est exactement ce qui fait croire
qu'un sabordage n'a rien cassé.

### Ce que le format d'instantané savait déjà

Vérifié plutôt que supposé : l'instantané **enregistre** la longueur de la RAM,
et les deux cœurs refusent déjà un écart (`RamSizeMismatch` /
`ramSizeMismatch`, et `WISQ_VM_SNAPSHOT_RAM_MISMATCH` dans l'FFI). Changer la
taille ne peut donc pas restaurer une machine de travers. En revanche cela
rend la sauvegarde **irrestaurable**, et c'est la tranche suivante qui doit le
dire à qui déplace le réglage.

### Un seul endroit côté application

`maximumKernelImageBytes` était un membre de **type** : il ne pouvait l'être
que tant que toutes les machines avaient la même mémoire. Trois appels le
lisaient ainsi, tous dans du code que seul le job « App iOS » compile — donc
la bascule vers une propriété d'instance aurait cassé la construction sans
qu'aucun job Linux le dise. `LocalMachineMemory` porte maintenant la taille et
le seuil, en un point ; c'est la ligne que le réglage déplacera.


## 2026-09-03, ~13h UTC — l'application a disparu, et la garde existait

Maxime a installé le build et a voulu démarrer **Omarchy** — une distribution
complète — dans la machine locale de son iPhone. L'application a disparu sans
un mot.

`LinuxMachine.load` refusait déjà une image trop grande : la garde est là
depuis le début, et `LinuxMachineError.imageTooLarge` existe. Le défaut
n'était pas le refus, c'était **l'ordre** :

```
fileImporter (.data, tout fichier)
  → importKernel : copie le fichier dans le stockage de l'application
  → boot : Data(contentsOf:)  ← lit TOUT le fichier en mémoire, sur ce fil
  → load : refuse si > 64 Mo  ← jamais atteint
```

Sur une image de deux gigaoctets, le système tue l'application pendant la
lecture. La garde qui aurait refusé le fichier en quelques microsecondes se
trouvait derrière l'allocation qui a tué le processus. Une défense placée
après le point de mort n'est pas une défense — c'est la troisième fois que ce
dépôt rencontre cette forme, et la première où elle coûte à quelqu'un.

Et un second piège, plus net, dans la garde elle-même :
`UInt32(kernelImage.count)` **plante** à partir de quatre gibioctets. La
protection contre les images trop grandes était un plantage pour les plus
grandes de toutes.

### Ce qui est corrigé

La taille est demandée au système de fichiers, avant toute lecture et avant
toute copie — à l'import comme au démarrage. Le plafond n'est pas un nombre
choisi : `LinuxMachine.maximumKernelImageBytes` est ce qui reste de la RAM
invitée sous le DTB et l'état réservé, donc ce qui peut physiquement entrer.
La comparaison se fait en `Int`.

Le refus dit les deux tailles et où est la vraie voie, parce qu'un chiffre
seul n'apprend rien à quelqu'un qui arrive avec une ISO.

### Ce que le sabordage a corrigé dans le test

La phrase nommait d'abord deux nombres — la mémoire totale et la part du
noyau. Elles ne diffèrent que d'un kilo-octet, donc s'affichaient toutes deux
« 64.0 Mo » : illisible comme contrainte, et le test passait en trouvant l'une
pour l'autre. Le sabordage « la phrase ne nomme plus la mémoire de la
machine » est resté vert, ce qui a montré la faiblesse. Un seul chiffre
désormais, et le test cherche la phrase entière.

Cinq sabordages mordent ; un sixième est laissé sans test et dit pourquoi
dans son commentaire — fabriquer quatre gibioctets en mémoire pour éprouver
la conversion `UInt32` coûterait plus que la garde ne vaut.

## 2026-09-03, ~09h25 UTC — le build est parti

Exécution n° 12 de `testflight.yml`, sur `45b78eb` : **succès**. L'archive
signée est chez Apple. Quatre minutes en tout, de la clé à l'envoi.

Le compte des refus, dans l'ordre où ils sont tombés, parce que chacun a
appris quelque chose :

| refus | ce qu'il a appris |
|---|---|
| `Signing for "Wisq" requires a development team` | l'équipe ne se déduit pas de la clé ; le `seedId` d'un identifiant d'application **est** l'identifiant d'équipe (#152) |
| `fiche d'application […] ABSENTE` | l'API App Store Connect refuse `CREATE` sur `/v1/apps` : la seule étape qu'aucune automatisation ne prend |
| `90475` écran de lancement | `xcodegen` **écrit** le fichier nommé par `info.path` (#159) |
| `90474` orientations absentes | le même défaut, la même cause |
| `90474` orientations incomplètes | trois sur quatre ne suffisent pas au multitâche iPad (#160) |

Ce que le dernier refus rend visible : les deux premiers échecs de validation
ne disaient pas la même chose. « Absentes » venait de l'Info.plist effacé ;
« incomplètes » venait d'une décision de produit écrite au mauvais endroit.
Le premier était un défaut d'outillage, le second un défaut de raisonnement,
et seul le vrai envoi pouvait les distinguer.

**La leçon coûteuse de la matinée** reste #159 : une application peut se
construire, passer sa suite de tests dans un simulateur, s'installer, et
n'avoir aucun des services que son manifeste croit déclarer. Le simulateur
n'a besoin ni d'un schéma d'URL, ni de Bonjour, ni d'une permission de réseau
local. Ce qui n'est exercé que par un vrai envoi ne se vérifie que par un
vrai envoi — et le premier a eu lieu six semaines après le début du projet.

## 2026-09-03, ~08h30 UTC — l'application n'avait jamais eu son Info.plist

Maxime a créé la fiche App Store Connect. L'envoi est parti pour de vrai :
la clé a trouvé l'équipe, l'archive a été **signée**, elle est montée chez
Apple — qui l'a refusée à la validation, sur deux codes :

```
90475  Apps that support Multitasking on iPad must provide the app's launch screen
90474  No orientations were specified in the app.wisq.ios bundle
```

Or `App/Info.plist` contient ces deux clés, et les contient depuis toujours.
Donc quelque chose les efface.

### Ce que XcodeGen fait de `info.path`

Lu dans sa source (`FileWriter.writePlists` → `InfoPlistGenerator`), puis
**exécuté** : XcodeGen a été construit ici depuis ses sources avec Swift 6.3,
lancé sur `project.yml`, et le résultat est sans appel.

`info.path` n'est pas « le fichier à utiliser ». C'est « le fichier à
**écrire** » : l'outil prend ses huit clés par défaut, y fusionne
`info.properties` — absent de notre manifeste, donc vide — supprime le fichier
existant et écrit le résultat. Avant / après, mesuré :

```
avant : 12 clés écrites à la main
après : CFBundleDevelopmentRegion $(DEVELOPMENT_LANGUAGE), CFBundleExecutable,
        CFBundleIdentifier, CFBundleInfoDictionaryVersion, CFBundleName,
        CFBundlePackageType, CFBundleShortVersionString 1.0, CFBundleVersion 1
```

### Ce que l'application perdait à chaque construction

Les deux clés du refus d'Apple, et surtout tout le reste :

| clé effacée | conséquence |
|---|---|
| `CFBundleURLTypes` / schéma `wisq` | **les liens d'appairage n'ouvrent pas l'application** — ni le lien du démon, ni le QR |
| `NSBonjourServices` | **la découverte des agents sur le réseau local est muette** |
| `NSLocalNetworkUsageDescription` | iOS 14+ refuse le réseau local sans elle : **aucune machine joignable**, ce qui est tout ce que fait wisq |
| `CFBundleShortVersionString` / `CFBundleVersion` | remises à 1.0 / 1 — le `CURRENT_PROJECT_VERSION=$run_number` du workflow était donc ignoré, et le deuxième envoi aurait été refusé pour numéro déjà vu |
| `ITSAppUsesNonExemptEncryption` | la conformité à l'exportation redemandée à chaque envoi |
| `CFBundleDisplayName`, région `fr` | l'application s'appelait « Wisq » et se déclarait en anglais |

Trois des gestes du guide Ubuntu — coller un lien `wisq://`, scanner le QR,
laisser le téléphone trouver l'hôte — ne pouvaient donc pas marcher dans
l'application construite. Aucun test ne le voyait : la suite iOS tourne dans
un simulateur, où rien n'exige un schéma d'URL ni une permission réseau.

### Et le refus suivant, sur la même clé

Avec le plist complet, l'envoi est reparti : plus de 90475, l'écran de
lancement est accepté. **Le 90474 est revenu, avec un autre message** :

    The "…Portrait,…LandscapeLeft,…LandscapeRight" orientations were provided
    […] but you need to include all of the four orientations to support iPad
    multitasking.

Trois orientations sur quatre avaient été écrites, en pensant au téléphone :
retirer le portrait inversé pour qu'un iPhone retourné pendant une session ne
fasse pas basculer l'écran. C'est une décision raisonnable, et ce n'est pas
là qu'elle s'écrit. Une application qui déclare l'iPad
(`TARGETED_DEVICE_FAMILY 1,2`) et ne demande pas le plein écran a opté pour le
multitâche, et le multitâche exige les quatre — la clé est un contrat avec le
système, pas un réglage de confort. Restreindre pour de bon ce que fait un
iPhone est un choix de vue, à faire ailleurs si on le veut.

Une garde de plus, sabordée : le portrait inversé retiré rougit le test.

### Le correctif, et sa garde

Tout passe dans `project.yml` sous `info.properties`, où l'outil le conserve ;
`App/Info.plist` devient un produit et quitte le suivi de git — le garder
suivi, c'était laisser un fichier qui a l'air de faire autorité et que
l'outil efface.

Huit sabordages, tous rouges : chacune des sept clés retirée une à une, plus
`App/Info.plist` remis sous suivi. Ce dernier est le seul qui garde la leçon
plutôt que la clé.

## 2026-09-03, ~07h30 UTC — quatre promesses tenues, et une limite mesurée

Le vrai libvirt sert une dernière fois, cette fois pour chercher des défauts
qui n'y sont pas. C'est une entrée de journal à résultat négatif, et elle vaut
d'être écrite : elle dit où ne plus chercher.

| ce qu'on demande au vrai démon | ce qu'il répond |
|---|---|
| arrêt poli d'un invité sans gestionnaire ACPI (SeaBIOS seul) | `running`, console ouverte, **toujours** `running` neuf secondes plus tard |
| le cordon (`force: true`) | `stopped` aussitôt, port retiré |
| jeton faux | `401` |
| identifiant `--version` | `404 {"error":"identifiant de VM invalide"}` |
| VM inexistante | `404 {"error":"VM introuvable : fantome"}` |

Les cinq tiennent. Le premier est le plus intéressant : c'est exactement ce
que `DemoBackend` modélise et ce que `VMPower.shutDown` attend — une demande
polie n'est pas un acte, et un invité qui n'écoute pas le bouton ne s'arrête
jamais. Le modèle disait vrai avant d'avoir vu la chose.

### La limite, elle, est réelle

`ConsoleResolver.resolve` tourne **une fois**, avant `SessionFactory`, et le
port qu'il trouve est cuit dans la `Machine` que la fabrique reçoit.
`ReconnectingSession` rejoue ensuite la même fermeture à chaque tentative.

Or un domaine redémarré ne retrouve pas forcément son port. Mesuré :

```
ubuntu-test  spice://localhost:5900     (avant)
   → arrêté ; second-vm prend 5900, third-vm prend 5901
ubuntu-test  spice://localhost:5902     (après redémarrage)
```

Donc : si le domaine est redémarré **de l'extérieur** pendant qu'un téléphone
tient une session et se reconnecte, les cinq tentatives composent l'ancien
port et échouent sur une machine qui va très bien.

**Ce qui n'est pas fait, et pourquoi.** La fenêtre est étroite : un
redémarrage d'invité (`reboot` dans la VM) garde le même processus QEMU et le
même port ; une extinction puis un rallumage depuis wisq repassent par le
résolveur. Il faut un redémarrage du domaine par quelqu'un d'autre, pendant
une session. Le correctif propre — re-résoudre à chaque tentative — rend
`ReconnectingSession.Factory` asynchrone et touche la boucle de reconnexion,
qui est la promesse phare de ce projet et le chemin le plus visible de
l'application. Le faire le matin où Maxime installe la première version sur
son téléphone, c'est risquer le cas courant pour réparer le cas rare. La
limite est donc écrite dans `docs/ROADMAP.md` avec sa mesure, à faire ensuite.

## 2026-09-03, ~07h UTC — ce qu'une VM éteinte sait déjà d'elle-même

Le vrai libvirt monté à la tranche précédente sert encore. Deux questions
posées au démon réel, deux réponses qui n'allaient pas de soi.

**Une VM arrêtée ne disait rien de sa console.** `domdisplay` refuse un
domaine arrêté (*error: Domain is not running*), donc le démon ne renvoyait ni
port ni protocole — alors que `dumpxml --inactive` porte le
`<graphics type='spice'>` noir sur blanc. Côté téléphone, `AgentImportView`
comble le vide par `.vnc` : importer une VM SPICE éteinte l'enregistrait comme
une machine VNC, et s'y connecter plus tard sans passer par l'agent parlait
RFB à un serveur SPICE. Le démon lit maintenant la définition quand — et
seulement quand — le domaine ne tourne pas : un appel `virsh` de plus par VM
éteinte, aucun par VM allumée. Le port, lui, reste absent : il n'existe pas
encore, et l'inventer serait pire.

**Et le guide se trompait sur l'attente.** Il annonçait que `running` sans
port « dure des dizaines de secondes ». Mesuré : la réponse au `POST /start`
porte **déjà** `consolePort: 5902`. libvirt ouvre le port à la création du
domaine ; ce qui prend des dizaines de secondes, c'est l'invité qui démarre
derrière. L'écran existe avant d'avoir quoi que ce soit à montrer, et c'est
une phrase différente à écrire pour quelqu'un qui attend devant.

### Le test qui ne tenait rien

Le cinquième sabordage a refusé de mordre, et il avait raison. J'avais écrit
« une VM qui tourne ne doit pas payer d'appel `dumpxml` » avec un faux `virsh`
qui échouait sur `dumpxml` — un appel supplémentaire dont le résultat est
jeté ne change aucune assertion. Le test ne tenait rien.

Réécrit sur une affirmation qui existe : **une VM qui tourne est décrite par
son affichage vivant, pas par sa définition.** Les deux peuvent diverger — un
domaine modifié pendant qu'il tourne sert encore ce avec quoi il a démarré —
alors le faux `virsh` se contredit exprès, définition en VNC et affichage en
SPICE, et la réponse doit être la vivante. Ce test-là mord, et il mord aussi
sur trois autres sabordages, ce qui est le signe qu'il touche le chemin
principal plutôt qu'un recoin.

Vérifié contre le vrai libvirt, quatre domaines : une VM SPICE allumée (port
5900), une seconde (5901), une VM éteinte à double affichage (`spice`, sans
port), une VM éteinte sans affichage du tout (ni l'un ni l'autre).

## 2026-09-03, ~06h30 UTC — un vrai libvirt, deux vraies VM, et un port faux

Les deux tranches précédentes ont été jugées contre un faux `virsh`. Ce
conteneur peut faire mieux : `libvirt-daemon-system` et `qemu-system-x86`
s'installent, `libvirtd` démarre avec `virtlogd`, et QEMU tourne en émulation
pure — sans KVM, mais le serveur SPICE existe et écoute, ce qui est tout ce
qu'il faut pour juger le chemin de l'agent.

Le défaut de la première tranche reproduit sur le vrai logiciel :

```
virsh domdisplay --all ubuntu-test   →  spice://localhost:5900
virsh vncdisplay      ubuntu-test    →  error: Failed to get VNC port.
                                         Is this domain using VNC?
```

Et le vrai binaire `wisq-agent`, lancé contre ce vrai libvirt, publie
maintenant ce que le téléphone attendait :

```json
[{"consolePort":5900,"consoleProtocol":"spice","id":"ubuntu-test", …},
 {"consolePort":5901,"consoleProtocol":"spice","id":"second-vm", …}]
```

### Le troisième défaut, que seule la mesure pouvait montrer

`RemoteProtocol.spice.defaultPort` valait **5930**. C'est le nombre des
exemples `-spice port=` de la documentation de QEMU, et ce n'est pas ce
qu'écoute un hôte construit comme notre propre guide le décrit : libvirt
attribue **5900**, puis 5901, vérifié à `ss -ltn` sur les deux VM.

Il ne joue pas sur le chemin de l'agent, où le port vient de `domdisplay` ; il
joue sur le seul cas où wisq doit deviner, quelqu'un qui tape un hôte à la
main, et il devinait contre l'hôte que nous recommandons.

**Et j'allais écrire ici qu'aucun test ne le tenait.** C'était faux :
`MachineStoreTests.testDefaultPortFollowsTheProtocol` épinglait 5930, et ma
recherche l'avait manqué parce qu'elle cherchait `defaultPort` et le littéral
dans les mêmes fichiers plutôt que le littéral partout. C'est la suite qui
l'a dit, en rougissant au premier sabordage — la base n'était pas verte, donc
la vérification s'est arrêtée avant de commencer. Un test épinglait bien le
mauvais nombre ; le nombre était mauvais quand même.

Les trois ports par défaut sont maintenant énoncés dans `DefaultPortTests`,
qui dit d'où vient chacun, parce qu'aucun des trois ne se dérive : ils se
mesurent. Le test du magasin garde ses littéraux — deux énoncés indépendants
du même nombre, c'est la garde, pas une redite.

## 2026-09-03, ~06h UTC — et l'éditeur disait « SPICE (bientôt) »

La tranche précédente a rendu les VM SPICE joignables par l'agent. En regardant
l'autre bout du même chemin — quelqu'un qui ajoute une machine à la main —
l'éditeur affichait toujours **« SPICE (bientôt) »** dans son sélecteur de
protocole.

`RemoteProtocol.isImplemented` valait `self == .vnc`, écrit au lot où c'était
vrai, jamais relu depuis. À côté, `SessionFactory.makeSession` construit une
`SPICESession` depuis le lot 5, et un test l'épingle déjà. Deux listes tenues à
la main sur la même question, et personne pour les confronter : le sélecteur
grisait la console qui porte le presse-papiers, le dépôt de fichier et le
redimensionnement.

L'étiquette est corrigée, mais ce n'est pas le correctif. Le correctif est
`ImplementedProtocolsTests`, qui fait marcher **`allCases`** à travers la
fabrique et exige que les deux réponses coïncident, protocole par protocole.
Le prochain protocole qui se met à marcher ne pourra plus rester grisé, et
aucun ne pourra être annoncé en avance.

Quatre sabordages contre la suite entière (1192 tests ici) : l'étiquette
revenue à `self == .vnc`, tout annoncé disponible, plus rien annoncé
disponible, et — celui qui compte — **la fabrique modifiée pour refuser
SPICE**, qui rougit la marche. C'est ce dernier qui prouve que le test lit la
fabrique et non une deuxième copie de la même liste.

## 2026-09-03, ~05h30 UTC — la console que le démon ne savait pas voir

Maxime veut tester aujourd'hui, avec un hôte Ubuntu. En relisant le chemin
qu'il va emprunter, le démon s'est révélé incapable de le suivre.

`VirshBackend::describe` posait le port de console à partir d'une seule
question : `virsh vncdisplay`. Sur un domaine **SPICE** — celui que
`docs/TESTER-UBUNTU.md` lui dit de créer, avec `--graphics spice` — libvirt
répond *Failed to get VNC port. Is this domain using VNC?* et sort en erreur.
Résultat : `consolePort` absent, `consoleProtocol` absent, et le téléphone qui
interroge une machine `running` **pour toujours**. Tout le lot 5 — le canal
display, le presse-papiers, l'envoi de fichier — était injoignable par le
chemin agent. Le mot « spice » n'apparaissait nulle part dans le démon.

### Ce que libvirt dit vraiment

Mesuré ici, sur libvirt 10.0.0 avec le pilote de test et des domaines définis
pour l'occasion, plutôt que rappelé de mémoire :

```
graphics spice port='5901'   → spice://localhost:5901
graphics vnc   port='5903'   → vnc://localhost:3
les deux                     → vnc://localhost:5   (et spice://… avec --all)
spice TLS seul               → spice://localhost:-1?tls-port=5907
spice sur socket unix        → spice+unix:///tmp/s.sock
domaine arrêté               → error: Domain is not running
```

**La ligne qui aurait été fausse si je l'avais devinée est la deuxième.**
SPICE imprime un *port*, VNC imprime un *numéro d'écran*. Un analyseur qui
traite les deux schémas pareil envoie le téléphone 5900 ports à côté de
l'écran d'un invité VNC. C'est la deuxième fois cette nuit qu'un pari sur le
comportement d'un outil se paie en le mesurant d'abord ; le premier avait
coûté seize secondes de CI, celui-ci aurait coûté une soirée de test.

### Ce qui est corrigé

`domdisplay --all` remplace `vncdisplay`, qui reste en repli pour un libvirt
trop ancien. SPICE gagne quand un domaine annonce les deux : c'est la console
qui porte le presse-papiers, le dépôt de fichier et le redimensionnement.
Un port `-1` et un socket unix ne publient rien — inventer un port serait pire
que l'attente.

Cinq gardes, les cinq sabordées contre la suite entière : la question réduite
à `vncdisplay` (le défaut d'origine), VNC compté comme un port, SPICE ne
gagnant plus, un port par défaut inventé quand rien ne répond, le repli
retiré. Chacune rougit la sienne, l'arbre intact reste vert.

## 2026-09-03, ~00h30 UTC — la sonde passe devant la construction

Le deuxième envoi s'est arrêté, comme prévu, sur « fiche d'application pour
app.wisq.ios : ABSENTE ». C'est la seule étape qu'une clé API ne peut pas
faire à la place de Maxime, et j'attends qu'il la fasse.

En relisant le workflow, l'étape qui pose cette question venait **après**
l'installation de XcodeGen et l'empaquetage du cœur Rust — soit plusieurs
minutes de construction pour apprendre quelque chose que l'API dit en une
seconde. Elle passe devant. Rien d'autre ne change : `build-app-icon.sh`
précède toujours `xcodegen generate` dans l'étape d'archive, et la garde du
site qui l'exige reste verte.

La conséquence pratique est que relancer le workflow pour *sonder* la fiche
ne coûte plus rien, ni en temps ni en numéro de build — l'exécution refuse
avant d'avoir produit quoi que ce soit. Mesuré aussitôt après la fusion :
l'exécution n° 3 a refusé en **treize secondes** (00:50:14 → 00:50:27), sur
la ligne attendue « fiche d'application pour app.wisq.ios : ABSENTE ». J'avais
écrit « trente secondes » avant de mesurer ; le chiffre est corrigé aux deux
endroits. La routine de garde sonde donc à chaque passage : quand la fiche
apparaît, l'envoi part sans que personne ait à écrire « fait ».

## 2026-09-02, ~20h UTC — le premier envoi TestFlight, et ce qu'il a appris

Maxime a créé les trois secrets App Store Connect et dit « Vas-y ». Le
workflow a donc tourné pour de vrai, et il a échoué en seize secondes sur une
ligne sans ambiguïté :

    error: Signing for "Wisq" requires a development team.

C'est le pari de la tranche précédente qui tombe. Le workflow rendait
`ASC_TEAM_ID` facultatif en pariant que Xcode déduirait l'équipe de la clé
API quand elle n'en sert qu'une. **Il ne la déduit pas** — ni avec
`-allowProvisioningUpdates`, ni avec `-authenticationKey*`. Le pari était
raisonnable et il était faux ; il aura coûté seize secondes parce qu'il a été
mesuré au lieu d'être supposé plus longtemps.

La correction ne demande pas un quatrième secret. L'identifiant d'équipe
existe déjà dans l'API sous un autre nom : le **`seedId`** d'un identifiant
d'application *est* l'identifiant d'équipe. Une étape le demande donc avant
de construire, avec les trois secrets déjà là, et au passage :

* crée l'identifiant d'application s'il manque — `xcodebuild` sait le faire
  aussi, mais il lui faut déjà l'équipe, et l'équipe se lit sur un
  identifiant : le faire ici casse le cercle ;
* dit si la **fiche d'application** existe. C'est le seul maillon que rien
  ne peut automatiser : l'API App Store Connect lit les fiches et n'en crée
  pas. Le dire avant la construction vaut mieux qu'un envoi refusé après dix
  minutes.

Ce que le jeton exige, et qui ne se voit qu'en 401 muet : ES256, vingt
minutes de vie au plus, l'audience littérale `appstoreconnect-v1`, et surtout
une signature au **format JOSE** — deux entiers de trente-deux octets bout à
bout — là où OpenSSL rend du DER par défaut. Les deux sont des signatures
valides du même message ; une seule est acceptée. `dsaEncoding: "ieee-p1363"`
est ce qui fait la différence.

Cette partie-là est vérifiable sans la clé de personne, et elle l'est : les
tests fabriquent une paire P-256, signent, **relisent la signature avec la
partie publique**, et gardent le témoin qui doit échouer — la même signature
contre un message modifié d'un caractère. Plus la longueur de soixante-quatre
octets et le premier octet qui n'est pas `0x30`, puisque c'est là qu'est la
faute qu'on ne verrait pas autrement.

Un défaut attrapé dans mon propre code en le relisant : la première version
écrivait `GITHUB_OUTPUT` avec `Bun.write`, qui écrase. Ce fichier appartient
au job entier ; l'écrire efface les sorties des étapes précédentes. Il est
maintenant allongé, une valeur multi-ligne est refusée plutôt qu'écrite à
moitié, et un test tient les deux.

## 2026-09-02, ~19h30 UTC — « je veux la tester avec Ubuntu » : le guide, et ce qu'il ne prétend pas

La seconde réponse à Maxime. Ce conteneur *est* un Ubuntu 24.04, et
`libvirt-clients` s'y installe : le démon a donc été joué contre le vrai
`virsh`, sur le pilote de test de libvirt (`LIBVIRT_DEFAULT_URI=test:///default`).
Il liste le domaine, répond `GET /v1/vms/{id}`, refuse un jeton faux en 401,
imprime un lien `wisq://agent?…` par interface. Ce qu'il ne peut pas montrer
ici, ce sont les changements d'état : le pilote de test repart de zéro à
chaque connexion, et chaque appel `virsh` en est une — `start` répond « Domain
is already active » et `stop` ne laisse rien. Un vrai libvirt en laisse, et la
suite Rust le tient contre un faux `virsh`. Le guide le dit tel quel.

**TestFlight, parce que Maxime a créé les clés.** Trois secrets étaient
apparus dans le dépôt (`ASC_ISSUER_ID`, `ASC_KEY_ID`, `ASC_KEY_P8`) et aucun
workflow ne les lisait : la release publie une IPA **non signée**, que
l'utilisateur re-signe avec AltStore. `.github/workflows/testflight.yml`
comble le trou — archive signée par `-allowProvisioningUpdates` avec la clé
API (ce qui évite de transporter un certificat dans un secret), export dont
le plist porte `destination: upload` (un seul endroit où la clé est
présentée), numéro de build pris sur le numéro d'exécution, parce que
TestFlight refuse un numéro déjà vu. `ASC_TEAM_ID` est facultatif : Xcode
déduit l'équipe de la clé quand elle n'en sert qu'une, et l'exiger aurait
bloqué un envoi qui pouvait aboutir.

Ce fichier est le premier de la tranche que rien ici ne peut juger : un
workflow ne se vérifie qu'en s'exécutant. Ce qui a été fait à la place —
le YAML analysé, et le script du plist imprimé tel que le shell le recevra,
parce qu'un heredoc dont le délimiteur reste indenté ne finit jamais. Et
un prérequis qu'aucun code ne contourne : la fiche d'application doit exister
dans App Store Connect sous `app.wisq.ios`, l'upload ne la crée pas.

**Et l'application n'avait pas d'icône.** `App/` contenait un `Info.plist` et
un fichier Swift, rien d'autre. Ce n'est pas un défaut de goût : un bundle
iOS sans icône est *refusé à l'envoi* (ITMS-90713, la clé `CFBundleIconName`
manque), et une icône qui porte un canal alpha l'est aussi (ITMS-90717).
Deux rouges qui n'existent qu'au dernier moment — l'application se construit,
se lance et s'installe depuis Xcode sans rien dire.

La marque n'a pas été inventée : `site/scripts/icons.ts` dessine déjà les deux
quadrants de wisq et encode le PNG à la main. Il gagne `iOSAppIcon()`, qui
rend la même image en 1024 points **sans canal alpha** — une option de
l'encodeur, pas un second encodeur, parce que toutes les autres images du
site veulent leur alpha. `scripts/build-app-icon.sh` écrit le catalogue, que
`.gitignore` retient : un binaire commité est une chose que personne ne peut
relire.

Cinq sabotages contre la suite entière du site (233 tests) : icône avec alpha
— le test de l'en-tête ; `verify.sh` qui oublie l'icône — la garde des chemins
de construction ; catalogue qui nomme un autre fichier — le test du catalogue ;
en-tête qui ment sur le nombre de canaux — deux tests ; taille réduite à 512
— deux tests. Le quatrième n'aurait rien fait rougir sans la ligne ajoutée
juste avant : décompresser l'IDAT et vérifier que sa longueur vaut
`hauteur × (1 + largeur × canaux)`. Les CRC, eux, étaient justes : une image
illisible dont chaque somme de contrôle est bonne.

Et la garde qui compte : les six chemins qui lancent `xcodegen generate`
dessinent l'icône d'abord, un test les compte, et un septième ajouté sans le
générateur échoue.

Un rappel au passage de ce que `verify.sh` sert à attraper : les quatre tests
passaient sous `bun test`, et `verify.sh` a rendu 1. Bun accepte
`import … from "../scripts/icons.ts"`, `tsc` non (TS5097), et la CI lance le
second. Le fichier voisin importait déjà sans extension ; un test vert dans
l'outil qui l'exécute peut être rouge dans celui qui le vérifie. C'est la même forme que #140 — `xcodegen` fige la liste des
fichiers, donc un chemin qui l'oublie produit une application sans icône que
personne ne voit avant le refus d'Apple.

`docs/TESTER-UBUNTU.md` : l'app sur l'iPhone (Mac + `install-ios.sh`, ou
l'IPA d'une release — et la dernière, v0.3.0, est d'avant le canal display
SPICE complet, l'envoi de fichiers et l'extinction : sans Mac, il faut une
release plus récente, geste de Maxime) ; l'hôte (libvirt, une VM Ubuntu
invitée avec SPICE et `spice-vdagent`, la ligne `virt-install` non vérifiée
d'ici faute de KVM) ; le démon (`install.sh --from-source --service`, parce
que le binaire de v0.3.0 est en retard sur le démon d'aujourd'hui) ;
l'appairage ; sept gestes à essayer ; quatre pannes courantes.

Deux affirmations du brouillon ont été confrontées au code et corrigées avant
d'être écrites :

1. « Supprimer le jeton révoque » — non : `main.rs` lit le jeton une fois au
   démarrage et `Service` le garde en mémoire ; supprimer le fichier ne change
   rien à ce qu'un démon qui tourne accepte, il faut le relancer. La phrase
   d'AGENT-PROTOCOL.md qui disait « révocable en supprimant le fichier » a été
   complétée dans la même tranche.
2. « Au retour d'un verrouillage, la session se reconnecte seule » — rien ne
   l'écrit : seul `LocalVMModel` réagit à `scenePhase`, et la reconnexion des
   sessions distantes est celle du changement de réseau (#1, #57). Le guide
   dit « à observer » plutôt que de promettre.

## 2026-09-02, ~19h UTC — l'épinglage du chemin machine, deux étapes sur trois

Maxime, vers 18 h 30 UTC : « Faut finir et je veux la tester avec Ubuntu ».
Deux réponses, deux PR. Celle-ci ferme la première tranche ouverte depuis
Linux dans « Ce qui attend une machine Apple » : le vrai épinglage du chemin
machine. Le transport savait déjà épingler — `NetworkByteStream` prend une
empreinte depuis #66 — mais rien ne la lui apportait : ni `Machine` ni
`SessionConfiguration` n'avaient le champ, et `.tlsPinned` valait `.tls` sur
toutes les machines, avec une étiquette « (épinglage à venir) » pour le dire.

Ce qui a été fait :

1. `Machine.certificateFingerprint`, absent des fichiers d'avant donc `nil`
   au décodage ; `SessionConfiguration(machine:password:)` — un seul endroit
   où une machine devient une configuration, pour qu'un champ ajouté à l'une
   ne puisse plus être oublié par l'autre — et les deux fournisseurs de flux
   qui passent l'empreinte à `NetworkByteStream`. Ces deux fichiers sont sous
   `#if canImport(Network)` : « Cœur (Apple) » les juge, pas ce conteneur.
2. `CertificateFingerprint.parse` lit ce que les gens collent — la ligne
   d'`openssl`, les deux-points d'un navigateur, la forme nue du lien
   d'appairage, en toute casse, même repliée par un client mail — et refuse
   tout ce qui ne fait pas trente-deux octets : un MD5 n'est pas une empreinte
   dans un autre manteau, c'est une épingle qui ne peut jamais correspondre.
3. **Les mots suivent le fait, machine par machine.** #70 avait rendu
   l'étiquette du mode honnête en la rendant vague. Maintenant que le mode
   peut épingler, l'honnêteté change d'endroit : le sélecteur nomme le mode
   (« TLS épinglé par empreinte »), et `Machine.transportDescription` dit ce
   que *cette* machine obtient — l'épingle avec ses premiers octets, ou « TLS,
   validation système — aucune empreinte enregistrée ». L'éditeur le dit sous
   le champ, la liste ne montre le bouclier que sur une vraie épingle, et
   l'import d'un `.vv` continue de ne rien promettre.

La troisième étape reste à la machine Apple : lire l'empreinte sur la
connexion et la montrer à la personne qui l'accepte. Saisir l'empreinte à la
main n'est pas un pis-aller en attendant : c'est la seule forme d'épinglage
qui ne fasse pas confiance au réseau au moment où on l'enregistre.

Huit sabotages contre la suite entière (1212 tests) : empreinte perdue à
l'initialisation — trois tests ; `pinsCertificate` toujours faux — l'aller-
retour ; configuration qui oublie l'empreinte — le test de configuration ;
toute longueur acceptée — le test des mauvaises longueurs ; préfixe
`openssl` non retiré — la ligne d'openssl ; description qui promet une
épingle absente — les mots ; format sans deux-points — l'aller-retour et les
mots ; résolution qui ignore l'empreinte — l'aller-retour et les mots. La
vérification à sec des deux sens, ajoutée après les deux accrocs du matin, a
attrapé son premier cas avant qu'il ne coûte : la ligne d'initialisation du
premier sabotage existait aussi dans `AgentBinding`, dans le même fichier.

## 2026-09-02, ~14h UTC — les entrées illisibles : le choix est proposé, jamais pris

La question attendait Maxime depuis le 28 août (ROADMAP, « Une décision qui
appartient à Maxime ») : les entrées d'une bibliothèque qu'une version ne sait
pas lire sont immortelles, ce qui protège d'une perte irréversible mais
condamne un fichier abîmé à afficher « une machine sur douze n'a pas pu être
lue » à chaque lancement, pour toujours. « Continue de tout faire » couvre la
décision, et la réponse proposée dans le ROADMAP était déjà la bonne : l'app
ne peut pas distinguer une entrée d'un wisq plus récent d'une entrée corrompue,
donc elle ne tranche pas — elle propose le choix en disant la vérité.

Ce qui a été fait, et pourquoi de cette forme :

1. **Une seule route de sortie.** `MachineStore.discardUnreadable` est la
   seule méthode par laquelle une entrée illisible quitte le fichier ;
   `save`, `upsert` et `delete` continuent de tout porter. Elle lit avant
   d'écrire, comme toutes les écritures du magasin depuis #99 : ce qu'elle
   écarte est ce que *cette* lecture n'a pas su lire. Et elle n'écrit rien
   quand il n'y a rien à écarter — une bibliothèque saine garde ses octets,
   pas une copie ré-encodée.
2. **La bannière nomme la machine.** `LoadOutcome.unreadableNames` rend le
   champ `name` des entrées qui en ont un qui soit du texte ; « Du futur » se
   reconnaît, « une entrée » non. Une entrée sans nom, ou au nom qui n'est pas
   du texte, est comptée sans être nommée : une entrée abîmée a pu perdre son
   nom avec le reste.
3. **La confirmation dit la seule chose qui compte.** Cette entrée vient
   peut-être d'une version plus récente, mettre à jour la ferait revenir ; ce
   qui est écarté est effacé du fichier et ne revient pas. Le bouton n'existe
   que si le compte est non nul, et le geste est destructif dans les deux sens
   du terme, jusqu'à la couleur.

La tranche a été écrite dans un arbre de travail séparé pendant que #148
attendait sa CI, pour ne pas empiler deux tranches sur une même PR ; elle
rejoint la branche après la fusion. Sabotages, contre la suite entière de cet
arbre (1179 tests sous le cœur Swift, sans noyau) : entrées conservées malgré
l'écart — les deux tests d'écart ; liste vide écrite à la place des machines
lisibles — les mêmes deux ; compte rendu à zéro — les mêmes deux ; noms jamais
lus — le test des noms ; écriture même sans rien à écarter — le test du
fichier intact ; cache qui oublie les noms — le test des noms, sur sa seconde
assertion.

Un accroc d'outillage, le second de la journée sur le même script : la
restauration d'un sabotage qui *supprime* une ligne se faisait par une chaîne
vide, et `count("")` ne vaut jamais un. La ligne a été remise à la main et le
sabotage suivant rejoué sur un arbre sain. La leçon rejoint celle du matin :
vérifier à sec, avant de toucher au fichier, que l'aller *et* le retour sont
uniques — et qu'un retour vide n'est pas un retour.

## 2026-09-02, ~13h UTC — « Continue de tout faire » : le fichier envoyé ne passe plus par la mémoire

Maxime, vers 12 h 30 UTC : « Continue de tout faire ». La clause de méfiance
de la routine demandait de chercher ce que le dépôt fait tourner ou promet
sans qu'un test le juge, avant de répéter un « tout est clos ». Le passage
sur les étiquettes (« TLS (épinglage à venir) », « RDP bientôt », la FAQ) n'a
rien rendu : chacune dit ce que le code fait et est tenue. Ce qui restait
d'écrit noir sur blanc, c'était dans la vue de session : « le fichier entier
passe en mémoire — juste pour des documents, faux pour un film ». Un iPhone
qui charge un film de deux gigaoctets en `Data` avant de l'envoyer ne
l'envoie pas, il est tué.

Ce qui a été fait : le canal agent lit une `SpiceFileTransfer.Source` —
64 Kio à la fois, chaque morceau demandé quand les jetons ont vidé le
précédent — et `SPICESession.sendFile(at:)` en fabrique une depuis l'URL du
sélecteur. Trois décisions dedans :

1. **La portée de sécurité vit avec la source.** La vue la réclamait puis
   la rendait au retour de la fermeture du sélecteur ; avec un envoi qui lit
   plus tard, elle aurait disparu avant le premier morceau. Elle est réclamée
   à l'ouverture et rendue par `close`, exactement la durée des lectures.
2. **Une lecture refusée ferme avec `error`, pas `cancelled`.** C'est ce que
   `file_transfer_operation_task_finished` envoie pour tout échec local qui
   n'est pas une annulation ; l'agent, qui attend encore des octets, apprend
   que le fichier ne viendra pas.
3. **Un fichier qui a rétréci est refusé, pas envoyé court.** La taille
   annoncée dans START est ce que l'agent attend ; lui donner moins le
   laisserait tenir un fichier à moitié écrit jusqu'à la fin de la session.

Dix sabotages contre la suite entière (1197 tests), et deux leçons :

- **Une chaîne de restauration doit être unique après application, pas
  seulement avant.** Le sabotage « `error` → `cancelled` » se restaurait
  par la chaîne inverse, qui existait déjà ailleurs (l'annulation légitime) :
  la restauration a refusé, le fichier est resté saboté, et le sabotage
  suivant a tourné dessus. Le script vérifie désormais l'unicité des deux
  côtés à sec avant de toucher au fichier, et le commit a été indexé depuis
  une reconstruction en mémoire plutôt que depuis l'arbre de travail.
- **Un motif de période 256 ne voit pas une lecture au mauvais endroit.**
  256 divise 65 536 : un `seek` ramené à zéro à chaque morceau, ou une
  tranche mémoire toujours prise au début, rend *exactement* les octets que
  la bonne lecture aurait rendus. Deux sabotages sont passés sans un rouge —
  et le test de découpage hérité de #143 fabriquait son fichier avec
  `UInt8(truncatingIfNeeded:)`, aveugle au même endroit. Les deux motifs ont
  maintenant la période 251, première, et les deux sabotages mordent.

Les verdicts : premier morceau seulement — quatre tests ; `cancelled` à la
place d'`error` — les deux tests de refus local ; source jamais fermée —
quatre tests ; lecture courte envoyée — le test du fichier rétréci ; taille
lue à zéro — le fichier sur disque ; `seek` ramené à zéro — le fichier sur
disque, après le changement de motif ; tranche mémoire prise au début — le
test de découpage hérité, après le sien ; agent cherché avant d'ouvrir le
fichier — le test de session. Une garde n'est tenue par rien et c'est dit dans le
code : `outcome == nil` dans `topUpTransfer`, qui empêche de relire après un
échec local parqué avant que l'appelant n'ait atteint sa continuation — la
branche n'est atteinte que par une course entre la pompe et l'envoi, qu'un
test déterministe ne sait pas provoquer.

## 2026-09-02, ~06h UTC — Maxime demande de finir et de mettre le site à jour ; les READMEs suivent

Maxime, réveillé : « Tu peux tout finir et mettre à jour le site ». Le site
est passé avec #146 — son contenu vendait une application en retard de
plusieurs fonctionnalités, il dit désormais dans les deux langues le canal
display complet, le dépôt de fichiers dans l'invité, l'agent qui éteint,
la machine qui survit à iOS, l'ouverture des `.vv`/`.rdp` — sans toucher aux
invariants gardés : le site ne distribue toujours pas wisq, n'annonce aucune
licence, et ses chiffres restent tenus par `claims.test.ts`.

Le même crible sur les READMEs rend trois prises du même genre :

1. README.fr.md disait « les codecs QUIC, GLZ et JPEG restent à faire » deux
   lignes au-dessus d'un tableau qui les déclare faits — la phrase et le
   tableau du même fichier se contredisaient.
2. Les deux READMEs répétaient le « moins de 600 Ko » que #146 venait de
   corriger dans AGENT-PROTOCOL.md : un nombre faux vit rarement à un seul
   endroit.
3. Aucun tableau ne mentionnait l'extinction d'une VM (#142), l'envoi de
   fichiers (#143/#144), la machine suspendue ni le cœur Rust par défaut.

La passe des textes auto-descriptifs est close avec cette tranche : site,
READMEs, ARCHITECTURE, AGENT-PROTOCOL. ROADMAP et JOURNAL sont le récit, pas
une description à tenir.

## 2026-09-02, ~03h30 UTC — le même crible sur AGENT-PROTOCOL.md : un nombre faux d'un facteur trois

Suite de la passe sur les documents auto-descriptifs. AGENT-PROTOCOL.md tient
mieux qu'ARCHITECTURE.md — ses sections routes, arrêt, identifiants et TLS
sont exactement ce que les suites des deux langues jouent — mais deux prises :

1. **« il en fait aujourd'hui moins de 600 Ko »** contredisait la ROADMAP, qui
   avait mesuré 1,7 Mo au travail de la matrice des architectures. Tranché par
   la mesure, pas par l'arbitrage : le binaire statique musl de ce conteneur
   fait 1 737 424 octets. Le nombre du protocole était vrai avant que le démon
   n'apprenne le TLS et l'appairage ; personne n'avait re-mesuré. Le document
   porte maintenant le chiffre mesuré et dit d'où venait l'ancien.
2. **« Trois pièces »** décrivait un démon sans `tls.rs`, `pairing.rs` ni
   `vm.rs` — trois fichiers que les sections du même document décrivent plus
   haut. La liste est complète désormais.

## 2026-09-02, ~03h UTC — ARCHITECTURE.md décrivait une application qui n'existe plus

La clause de méfiance du filet demande, avant de répéter « tout est clos »,
de chercher ce que le dépôt PROMET et que rien ne juge. ARCHITECTURE.md était
la dernière pièce auto-descriptive jamais passée au crible — le site, le
README et les gardes le sont — et le crible a rendu **six affirmations
fausses**, chacune vérifiée contre le code avant d'être réécrite :

1. « Le JPEG est délibérément absent de Tight » — décodé depuis la tranche
   Tight, qualité annoncée seulement là où `JPEGDecoder` existe.
2. « wisq ne décode ni QUIC ni GLZ. Il demande LZ » — les quatre codecs du
   canal sont décodés et la demande est `AUTO_GLZ` ; la phrase datait de trois
   générations de demande.
3. « tlsPinned fait du TOFU » — jamais vrai sous cette forme, et faux deux
   fois depuis #66 : validation système complète côté machine, épinglage réel
   côté agent, libellé honnête dans le sélecteur.
4. « la vue terminal v1 est du texte brut, ANSIFilter… » — `ANSIFilter`
   n'existe plus dans l'arbre ; la console est `TerminalGrid`, pour les deux
   cœurs.
5. « Ce qui n'est pas là : QUIC, GLZ, JPEG, palettes, presse-papiers » — tout
   y est ; la liste des vraies absences est désormais celle des codecs vidéo
   et audio compressés, et de la sortie/capture audio (Apple).
6. « WisqCore n'importe que Foundation » — il importe aussi Security, sous
   `#if canImport` ; trouvée en vérifiant la phrase que j'allais laisser.

Au passage : le schéma des canaux SPICE gagne lecture/record et l'agent, le
schéma des modules gagne WisqVM, et le cœur Rust par défaut est enfin dit là
où un lecteur d'architecture le cherchera. Rien de tout cela n'a de test —
c'est un document — mais chaque phrase corrigée a été confrontée à un grep ou
au fichier qu'elle décrit, parce que la version précédente montre exactement
comment un document d'architecture pourrit : une phrase vraie à l'écriture,
jamais relue quand le code la dépasse.

## 2026-09-02, ~02h30 UTC — le geste au bout du protocole

La tranche courte qui rend #143 visible : un bouton « envoyer un fichier »
dans la barre de session des machines SPICE, le sélecteur de documents grand
ouvert comme celui des fichiers de connexion, la lecture à portée de
sécurité, et `SessionModel.sendFile` en miroir mince de
`SPICESession.sendFile` — trois états (envoi, envoyé, échec) dans une
bannière visible même chrome caché, parce qu'un transfert finit longtemps
après le geste qui l'a lancé. Les refus arrivent avec les mots du protocole
(espace libre chiffré compris). Du SwiftUI qu'aucun runner Linux ne compile ;
la CI macOS le compile, la conduite qu'il appelle est celle que #143 a
éprouvée. Une limite dite dans le code : le fichier entier passe en mémoire —
juste pour des documents, faux pour un film.

## 2026-09-02, ~02h UTC — un fichier du téléphone vers l'invité, sur le canal qui existait déjà

Deuxième tranche de la nuit. La piste « partage de fichiers via un dossier
monté côté agent » (lot 6) a d'abord été instruite puis écartée pour cette
nuit : le serveur HTTP du démon porte des corps `String` de 64 Kio au plus,
Content-Type JSON figé — y faire passer du binaire est un chantier à part.
Pendant ce temps **SPICE porte déjà un transfert de fichiers vers l'invité**,
sur le canal agent que wisq parle depuis le presse-papiers : `FILE_XFER_START`
/ `STATUS` / `DATA`, la référence dans le `channel-main.c` de spice-gtk déjà
en scratchpad. Entièrement jugeable d'ici. C'est la moitié protocole du
partage de fichiers ; le geste d'interface (partager vers la session) est la
tranche suivante.

**Les octets du START sont épinglés par GLib, pas par moi.** La charge est un
document GKeyFile que l'agent reparse avec GLib ; `scripts/
spice-file-xfer-fixtures/gen.c` lie GLib et imprime la sortie exacte de
`g_key_file_to_data` pour seize noms. Ce que GLib fait vraiment est plus
étroit et plus étrange que ce qu'on écrirait de mémoire : `\` `\n` `\r`
échappés partout, la course de blancs **de tête** échappée caractère par
caractère (` `→`\s`, tab→`\t`), une tabulation au milieu et une espace finale
voyagent crues — et les deux bords de la course ne sont pas symétriques,
mesurés parce qu'improbables : un antislash la clôt, un `\n` échappé la
laisse ouverte. Et le NUL terminal fait partie de la charge (`data_len + 1`
chez la référence).

**Les deux bords du fichier vide, chacun un bug amont.** Un fichier de zéro
octet doit envoyer exactement un `DATA` vide (sans lui l'invité garde un
fichier ouvert pour toujours — rhbz#1135099) ; un fichier non vide ne doit
jamais en envoyer un à la fin (l'agent le prend mal — fdo#97227). Les deux
sont des tests distincts et des sabotages distincts.

**La conduite** : refus avant départ (pas d'agent ; invité ayant annoncé
`fileXferDisabled`), rien ne part avant `canSendData`, tranches de 64 Kio
(la taille de lecture de la référence) alimentées au fil des jetons plutôt
que matérialisées d'un coup, `.cancelled` envoyé à l'agent quand ce côté
annule, l'agent disparu fait échouer l'appelant au lieu de le laisser
attendre. Les huit statuts finaux portent chacun des mots sur lesquels on
peut agir, l'espace libre chiffré compris — d'où l'annonce de
`fileXferDetailedErrors`, testée **sur la prise** comme les capacités audio.

**Treize sabotages, et deux leçons de sonde.** Douze ont mordu sur le test
nommé d'avance. Le treizième a d'abord montré deux défauts de harnais :
(1) le test de la taille de tranche dérivait la taille du fichier de la
constante sabotée — une sonde qui fabrique son entrée depuis le code qu'elle
mesure ne peut pas le voir changer ; le nombre de la référence est maintenant
écrit en littéral. (2) Le sabotage « l'agent disparaît et rien n'échoue » a
PENDU la suite au lieu de la rougir : `Task.value` n'est pas interruptible de
l'extérieur, et mon garde-fou en task group attendait quand même l'enfant.
Le garde-fou est désormais un chien de garde qui annule le *transfert*
lui-même — par le chemin d'annulation que l'app emprunterait — et le même
sabotage échoue en cinq secondes. La règle d'hier soir (« un sabotage de
patience doit échouer et non pendre ») a été violée puis réparée dans la même
tranche ; c'est précisément pour ça qu'on la teste.

## 2026-09-02, ~00h UTC — le bouton qui manquait : éteindre une VM distante

Maxime a écrit « J'aimerais beaucoup finir l'application dans la nuit ». La
carte a donc été relue en entier avant de choisir, et le morceau le plus
proche de « finir » qui se prouve d'ici était le premier de la liste des
restes : le démon sait arrêter une VM, `AgentClient.stop` existe, et rien
dans l'application ne l'appelait. Une capacité non offerte, depuis des mois.

**La conduite d'abord, parce que c'est elle qui se juge.** `VMPower.shutDown`
suit le contrat d'AGENT-PROTOCOL.md : la réponse immédiate du démon règle le
cordon et la machine déjà arrêtée, puis l'arrêt poli est sondé jusqu'à
`stopped` dans une fenêtre de patience. La décision qui compte est ce qui se
passe quand la patience s'épuise : **`.stillRunning` est un résultat, pas une
erreur.** Un invité sans gestionnaire ACPI ignore la demande pour toujours et
rien dans le protocole ne peut l'y forcer ; attendre plus longtemps ne le
ferait pas répondre, cela cacherait la question à la personne qui tient le
téléphone. L'interface présente donc la non-réponse et offre le cordon, en
nommant son prix — ce qui n'était pas enregistré est perdu.

**Six sabotages, six morsures, aucun no-op.** Le drapeau `force` escamoté, la
boucle de sondage retirée, la patience rendue infinie, la réponse immédiate
ignorée, le nom de la machine retiré du refus, le jeton escamoté dans la
nouvelle fabrique `AgentClient(binding:credentials:)` — chacun a fait rougir
exactement le test nommé d'avance, contre la suite entière, sur baseline vert
(1171 tests Swift, 1 saut attendu). Le sabotage de la patience infinie méritait
sa vérification : mal conçu, ce test-là *pendrait* au lieu d'échouer. Il
échoue, parce que l'invité de démonstration finit par s'arrêter et que
l'assertion attend `.stillRunning`.

**Le partage qui n'était pas prévu.** Construire un client depuis une liaison
enregistrée — jeton depuis le trousseau, épinglage exactement quand
l'appairage a noté une empreinte — vivait dans `ConsoleResolver` et allait se
recopier dans `VMPower`. C'est devenu `AgentClient(binding:credentials:)`,
une décision à un seul endroit ; le sabotage du jeton montre que les deux
appelants la traversent.

**Ce que la tranche ne prouve pas, dit honnêtement :** le bouton lui-même —
glissement sur une machine liée à un agent, dialogue de confirmation, bannière
de progression, alerte « l'invité n'a pas répondu » avec le cordon en second
geste — est du SwiftUI qu'aucun runner Linux ne compile. La CI macOS le
compile, la conduite qu'il appelle est éprouvée, la vue reste mince ; c'est la
même posture que le reste de WisqUI.

## 2026-08-31, ~10h UTC — le processus du dyno, exécuté — et la mine que #140 avait posée

Maxime a dit « Fais le » : la tranche `heroku-web.sh`, annoncée au réveil
précédent comme le prochain candidat sérieux.

**La mesure a d'abord menti, et c'est la moitié de l'histoire.** Deux sabotages
— `heroku-web.sh` remplacé par `exit 1`, la garde `dist/index.html` de
`heroku-build.sh` neutralisée — ont rendu quatorze puis onze rouges. Aucun
n'était une détection : la dernière porte de `verify.sh`, ajoutée par #140 le
matin même, reconstruisait `site/dist` avec l'adresse épinglée `wisq.example`,
et toute suite lancée ensuite lisait ce dist-là. Onze rouges d'origine de
requête, sans aucun rapport avec les sabotages. La CI ne pouvait pas le voir
(ses tests passent avant ses constructions Heroku) ; seul un contributeur qui
enchaîne `verify.sh` puis `bun test` le voyait — un faux rouge, la chose exacte
qui rend un plancher local intraçable. Corrigé en inversant l'ordre : la
construction épinglée d'abord, la sentinelle en dernier, pour que l'arbre
finisse dans l'état que la suite lit. L'ordre est tenu par un test, parce qu'il
a déjà mordu.

**Puis la mesure propre, sur baseline vert : tout vert.** Le script que le
`Procfile` lance — le processus que le dyno démarre, avec ses trois branches
écrites pour être lues sur un téléphone au milieu d'un déploiement raté —
n'avait jamais tourné une seule fois. Ni la garde de `heroku-build.sh` contre
un slug au `dist` vide, qui démarre, répond 404 à tout, et ressemble à un
problème de routage.

Le témoin est `site/tests/heroku.test.ts`, neuf tests : les trois branches du
choix de Bun départagées par des Bun enregistreurs dans des arbres jetables
(priorité au slug, repli sur le PATH avec sa note, refus en une ligne qui nomme
le script fautif) ; le vrai script à sa vraie place servant le vrai `dist` sur
un vrai port avec le vrai Bun ; les deux bords du refus de `heroku-build.sh` et
du conseil `SITE_URL` ; la chaîne Procfile → heroku-web.sh → serve.ts ; et
l'ordre des constructions dans `verify.sh`. Dix sabotages, chacun rougissant
son test ; un cas témoin survit.

La leçon qui reste : **la porte qu'on vient d'ajouter est elle-même du code
qui casse des choses.** #140 a comblé quatre écarts et posé une mine dans le
même geste, invisible de la CI par construction, et trouvée uniquement parce
que la tranche suivante a mesuré avant d'écrire.

## 2026-08-31, ~07h UTC — « everything CI would run », et les quatre choses qu'il ne lançait pas

C'est la première ligne de `scripts/verify.sh`. Ce fichier porte, dans ses
propres commentaires, **trois** aveux d'avoir eu tort : le lint absent, les deux
portes Rust absentes, la matrice des architectures absente. Trois fois la même
faute, chaque fois trouvée par une pull request rouge, chaque fois réparée à la
main. Rien ne comparait les deux listes.

Mesuré, en comptant les occurrences dans `verify.sh` contre les deux workflows :
quatre choses que la CI lance et que lui ne lançait pas — `WISQ_SWIFT_CORE=1
swift build` (l'échappatoire que le manifeste conseille à qui n'a pas cargo),
`npm run heroku-postbuild` deux fois (la construction qui déploie réellement le
site), `swift run -c release wisq-bench`, et l'agent statique musl avec son
`env -i … --help`. Les quatre sont comblées ; les deux dernières sur le modèle
déjà établi par la branche SwiftLint du fichier — conditionnelles, avec le mode
d'emploi quand l'outil manque.

**La forme de la garde**, et c'est le point qui mérite d'être relu. Comparer
deux scripts shell par ressemblance de texte serait fragile dans les deux sens.
`site/tests/verify-covers-ci.test.ts` tient donc un **inventaire déclaré** :
chaque étape nommée des deux workflows y figure avec un verdict — soit un motif
que `verify.sh` doit contenir, soit une raison de ne pas la lancer localement.
Une étape ajoutée à la CI et classée par personne fait rougir le test. C'est
exactement ce qui manquait les trois fois.

Trois choses apprises en l'écrivant :

* **La clé est « job › étape », pas l'étape seule.** Trois jobs portent une
  étape nommée « Test » — `cargo test`, `swift test`, `bun test`. La première
  version les confondait en une ligne et laissait deux portes sur trois sans
  verdict, dans un fichier écrit contre exactement ça.
* **Le corpus a été rétréci, pas élargi.** La première version cherchait aussi
  dans `check-*.sh` et `test-rust-core.sh`. Mesuré : aucun motif n'en a besoin,
  car ce que `verify.sh` délègue, il le délègue par un appel qui est dans son
  propre texte. Élargir n'ajoutait aucune couverture et un seul risque : qu'un
  motif soit satisfait par un fichier que `verify.sh` n'exécute pas là.
* **Un cinquième écart n'en était pas un, et je l'avais déjà comblé avant de le
  mesurer.** La CI pose `WISQ_LINUX_IMAGE` sur son `swift test`, `verify.sh` ne
  le posait pas ; cela ressemblait aux quatre autres. Les deux runs, avant et
  après, rendent le même unique saut : `LinuxBootTests` et
  `DifferentialBootTests` lisent la variable *ou* se rabattent sur le chemin
  bien connu. **Équivalence réelle** — l'un des quatre verdicts quand un
  sabotage ne mord pas. La ligne a été retirée plutôt que gardée pour faire
  nombre, et le tableau du fichier dit quatre, pas cinq.

## 2026-08-31, ~06h UTC — l'installateur, et une option qu'il acceptait sans la lire

`scripts/install.sh` est le seul fichier du dépôt dont le mode d'emploi est
« tuyautez-le dans un shell ». C'était aussi celui que le moins de choses
tenaient : cinq sabotages séparés, chacun contre la suite entière, et trois
laissaient tout vert — l'autotest du binaire téléchargé supprimé, un argument
inconnu accepté, le repli sur les sources rendu inatteignable.

Les deux autres — `--version` et `--prefix` supprimés — donnaient un rouge, et
c'est le piège qu'il faut consigner : **ce n'était pas une détection.**
`check-release-matrix.sh` passe ces deux options comme échafaudage, pour ne pas
résoudre « latest » et pour ne rien installer hors de son bac à sable. Les
supprimer casse son harnais, pas une affirmation sur ce qu'elles font. Compter
les rouges au lieu de les lire aurait conclu que l'installateur était couvert à
deux cinquièmes ; il l'était à un seul endroit, la table architecture → asset.

**Ce que la mesure a trouvé.** `--version` était accepté, documenté, et ignoré
sur le chemin des sources : `install_from_source` clonait la branche par défaut
quoi qu'on demande. Ce n'est pas un chemin exotique — c'est le chemin de toute
machine hors des quatre assets publiés (le NAS ARM, le Raspberry Pi, l'ARM
32 bits, FreeBSD), que le commentaire de ce même fichier nomme une à une, et le
repli de tout téléchargement qui échoue. Vérifié de bout en bout avant d'être
écrit : `--from-source --version v0.2.0` contre un dépôt local tagué installait
le contenu de master.

Deux autres, trouvées en lisant la même vingtaine de lignes : l'aide imprimait
`set -eu`, parce que la plage `sed -n '2,14p'` avait dérivé d'une ligne ; et le
répertoire temporaire du téléchargement restait dans `/tmp` pour de bon sur le
chemin du repli, parce que les deux fonctions posaient chacune un `trap ... EXIT`
et que le second remplace le premier.

Le témoin est `site/tests/installer.test.ts`, douze tests. Rien n'y est simulé
de ce qui décide : un vrai dépôt git avec un vrai tag, un vrai serveur HTTP
local avec un vrai `tar.gz`, le vrai `git`, le vrai `curl`, le vrai `tar`. Seul
`cargo` est postiche, et honnêtement : il recopie un marqueur pris dans le clone,
si bien que le binaire installé dit lui-même quel commit a été cloné.

Deux choses apprises en l'écrivant, qui valent d'être relues :

* **`Bun.spawnSync` et `Bun.serve` dans le même processus se bloquent.** Les six
  tests qui téléchargent expiraient tous à cinq secondes : le serveur ne peut
  pas répondre tant que l'appel synchrone n'a pas rendu la main. Ce n'était pas
  le cache de pages froid, et monter le délai aurait émoussé la sonde sans rien
  réparer. `Bun.spawn` awaité : 732 ms pour les douze.
* **L'autre bord.** Le défaut se « corrigeait » aussi en exigeant toujours un
  tag — ce qui aurait cassé le cas courant (`latest`, le défaut) pour réparer le
  rare. Le test « sans --version, c'est la branche par défaut » existe pour ça,
  et il rougit bien quand on met `--branch "$VERSION"` sans condition.

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

### Et la même faute de lint, pour la deuxième fois

`Lint` a rougi sur cette tranche pour une accolade ouvrante seule sur sa ligne,
au bout d'une signature trop longue — exactement ce qui était déjà arrivé à la
tranche des encodages hextile/CopyRect. Un réflexe de dépôts qui limitent la
longueur des lignes, alors que `line_length` est désactivé ici.

Le noter une fois de plus n'aurait servi à rien. La règle est donc passée dans
`scripts/check-whitespace.sh`, qui existe précisément pour les règles de
SwiftLint qui sont du pur texte, et dont l'en-tête dit déjà pourquoi : « une
porte qu'un contributeur ne peut pas passer localement est une porte qui trouve
les choses après l'ouverture de la pull request ».

Vérifié comme le reste : la garde rougit sur un fichier témoin qui contient la
faute, et revient au vert une fois le témoin retiré. Le dépôt entier en compte
zéro par ailleurs, donc la règle est cohérente avec le style existant plutôt
qu'imposée par-dessus.

## Deux gardes que rien ne tenait, et le sabordage qui ne rougit pas mais tue

`ByteCursor.read(_:)` et `ByteCursor.readUInt8()` refusent tous deux de lire
au-delà de la fin du bloc. **Retirer l'une ou l'autre laissait les 964 tests
verts.** Elles étaient justes, et à une modification distraite de ne plus être
là du tout.

Les octets qu'elles gardent ne sont pas les nôtres. Un rectangle ZRLE se
détend en un flux de tuiles dont les tailles de palette, les longueurs de série
et le nombre de pixels sont tous décidés par le serveur ; un bloc court est ce
qu'envoie un serveur cassé — ou hostile.

### Ce que le sabordage a réellement donné

Pas un test rouge. **Pas de ligne de total du tout.**

```
Swift/Array.swift:430: Fatal error: Array index is out of range
*** Signal 4: Backtracing … ***
*** Program crashed: Illegal instruction ***
```

C'est le cas prévu par la règle « un rouge peut être un plantage » : sans la
garde, lire au-delà d'un tableau Swift n'est pas une erreur, c'est la fin du
processus. Mesuré plutôt que supposé, et c'est ce qui donne sa taille au défaut :
il ne s'agissait pas d'un test manquant sur un chemin d'erreur, mais de rien du
tout entre un bloc tronqué et la mort du client.

Quatorze tests le tiennent maintenant : sur le curseur directement — les deux
bords exacts de la limite, un pixel coupé en deux, une longueur de série qui dit
« continue » et s'arrête — et de bout en bout à travers `ZRLEDecoder`, pour
chacune de ses formes de tuile. Avec deux témoins qui décodent pour de vrai,
sans quoi tout cela passerait pour un décodeur qui refuse tout.

### Le jumeau mort

`ByteCursor.readTightPixel` n'avait **aucun appelant** : `TightDecoder` a la
sienne, ligne 118, qui lit depuis la socket plutôt que depuis un bloc détendu.
Le sabordage l'a établi sans ambiguïté — inverser l'ordre des octets du jumeau
laissait tout vert, inverser celui de la vraie faisait rougir vingt-neuf tests.

Le jumeau portait pourtant le commentaire qui énonce la règle, comme s'il en
était l'autorité. C'est la forme de #71 : deux orthographes d'une même règle,
dont celle que personne n'appelle est libre de dériver.

**Supprimé plutôt que testé.** Le tester aurait figé une seconde vérité à
maintenir ; une règle tenue à un seul endroit ne peut pas se contredire
elle-même. Le commentaire de `readCompressedPixel` dit maintenant où vit
l'autre, et pourquoi elle vit là.

### Les quatre sabordages

| sabordage | résultat |
| --- | --- |
| garde de `read(_:)` retirée | **plantage**, signal 4 — puis 14 rouges avec les tests |
| garde de `readUInt8()` retirée | **plantage** — puis rouge avec les tests |
| octets de CPIXEL inversés | 37 rouges (déjà tenu) |
| octets du jumeau mort inversés | **0** — d'où la suppression |

## Un flux par encodage, et rien ne le tenait

`RFBStreams` s'ouvre sur « One per compressed encoding, plus Tight's four …
the whole point is that the dictionary carries across frames ». Trois
sabordages, trois verts sur 978 tests : faire partager un flux à `zlib` et
`zrle`, faire rendre toujours le flux 0 à `tight(_:)`, remplacer les quatre
flux Tight par un seul.

Ce que ça coûte n'est pas un plantage mais l'inverse — le **silence**. Le
dictionnaire d'un flux zlib, c'est tout ce qu'il a détendu jusque-là ; deux
encodages qui partagent un flux s'empoisonnent mutuellement l'historique. La
session décode faux à partir de la première image mixte, sans erreur, sans
message. `InflateStream` le dit déjà : « one dropped or mis-parsed byte
corrupts every frame after it ».

### Le comportement plutôt que l'identité

Écrire `XCTAssertFalse(streams.zrle === streams.zlib)` aurait épinglé la façon
dont la séparation est faite, pas la propriété qui compte. La sonde est donc
comportementale, et elle réutilise la paire de blocs d'`InflateStreamTests` :
le second n'a pas d'en-tête zlib, donc il ne veut dire quelque chose que pour
un flux ayant déjà avalé le premier. Le donner à l'autre encodage doit **lever**.

Le témoin vient d'abord dans le fichier, comme d'habitude : un flux qui a bien
vu le premier bloc continue la phrase. Sans lui, tous les refus qui suivent
passeraient pour un `RFBStreams` dont chaque flux est cassé.

### Une correction que je me suis faite en route

J'allais écrire que le bornage de `tight(_:)` protège d'un indice venu du fil.
Vérification faite, `TightDecoder` masque déjà avec `& 0x3` et la boucle de
réinitialisation parcourt `0..<4` : **l'indice hors bornes n'est pas
atteignable aujourd'hui**. C'est de la profondeur, pas un trou, et le test le
dit en ces termes. Ce que le sabordage montre quand même : remplacer le bornage
par un accès direct ne fait pas échouer un test, il tue le processus.

### Les cinq sabordages

| sabordage | rouges |
| --- | --- |
| `zlib` et `zrle` partagent un flux | 2 |
| `tight()` rend toujours le flux 0 | 13 |
| les quatre flux Tight n'en font qu'un | 13 |
| `resetTight` vise toujours le flux 0 | 1 |
| le bornage remplacé par un accès direct | **plantage**, signal 4 |

## La dernière ligne avant la mémoire, et quatre gardes sur six sans témoin

`Framebuffer.write` le dit en toutes lettres : « Out-of-bounds rows and columns
are clipped rather than trapping: **a misbehaving server must not crash the
app.** » Six gardes portent cette phrase, dans `write` et dans `copy`. Sondées
une par une :

| garde | avant |
| --- | --- |
| `write`, taille de la charge utile | **rien ne rougit** |
| `write`, bornes de ligne | plantage du runner |
| `write`, rognage de colonne | plantage du runner |
| `write`, `rect.x >= 0` | **rien ne rougit** |
| `copy`, bornes de la source | **rien ne rougit** |
| `copy`, bornes de la destination | **rien ne rougit** |

Quatre sur six ne tenaient à rien du tout. Les deux autres ne tenaient qu'au
fait que leur absence tue le processus de test — une couverture par accident :
aucun test n'énonçait le rognage, donc un remaniement qui en *changerait* la
sémantique au lieu de la supprimer serait passé sans bruit.

`Framebuffer` est la destination de **tous** les décodeurs, et chacun tient ses
dimensions du fil.

### Ce que « rouge » veut dire ici, exactement

Après la tranche, les six sabordages tuent le processus. Ce n'est pas la même
chose qu'un test qui échoue proprement, et il faut le dire : une garde qui
empêche un piège ne peut pas échouer autrement qu'en piégeant. Ce que les tests
apportent, c'est de **l'atteindre** — la CI passe de « aucun signal » à « le job
échoue », ce qui est toute la différence pour quatre d'entre elles.

### Les deux bords, encore

La moitié du fichier dit ce qui **est** écrit. Un rectangle entièrement dedans
s'écrit entièrement ; une charge utile exactement de la bonne taille passe ; des
lignes qui débordent par le bas laissent celles qui tiennent. Ce dernier point
n'est pas un détail : un serveur qui redimensionne son bureau envoie des
rectangles à cheval sur l'ancien bord, et refuser l'écriture entière donnerait
une bande noire au lieu d'une bande sûre.

## La même faute pour la troisième fois : une VM incomprise perd la liste

`AgentVM` n'avait **aucun test**. Sondé :

| ce que l'agent envoie | avant |
| --- | --- |
| un `state` inconnu | lève |
| un `state` **absent** | lève aussi |
| un `consoleProtocol` inconnu | lève |
| un `guestOS` inconnu | lève |
| une VM sur deux incomprise | **toute la liste est perdue** |

L'enum `State` portait pourtant un cas `.unknown` que le décodeur n'atteignait
jamais.

L'absence de `state` n'était pas dans mon hypothèse : la sonde l'a trouvée. Je
cherchais les valeurs inconnues et j'ai eu les deux, ce qui est la troisième
fois aujourd'hui qu'une sonde rapporte plus que la question posée.

### Pourquoi ce n'est pas théorique

C'est le modèle de distribution du projet. Le démon s'installe par Homebrew ou
un script `curl` et se met à jour **indépendamment** de l'application
sideloadée. Un `brew upgrade` sur l'hôte, pas de mise à jour sur le téléphone,
et « mes VM » devient vide.

### Troisième apparition : une habitude, pas un accident

Après `Settings` (#96) et `MachineStore` (#99), c'est le même défaut au même
endroit conceptuel : un `Codable` synthétisé sur un enum de chaînes, décodé en
bloc, dans un programme dont les deux moitiés ne sont pas versionnées ensemble.
Ce qui mérite d'être retenu n'est pas la correction — elle est mécanique — mais
que la forme se répète, et donc qu'il faut la chercher partout où un enum
traverse une frontière de version.

### Les deux bords, encore, et l'asymétrie

`state` et `guestOS` retombent sur `.unknown`. C'est sûr : `waitUntilRunning`
n'agit que sur `.running`, donc un état illisible **attend** au lieu de
supposer.

`consoleProtocol` **refuse** : un nom inconnu devient `nil`, jamais `.vnc`.
Retomber sur un défaut ouvrirait une session VNC contre un port que l'agent a
publié pour autre chose. Même asymétrie que `Machine.security` en #96 : la
présentation peut se rabattre, ce qui décide de la connexion non.

Et la VM reste listée malgré une console inouvrable — c'est une machine que
l'utilisateur peut encore vouloir voir, démarrer ou arrêter.

### Les cinq sabordages

| sabordage | rouges |
| --- | --- |
| retour au décodage strict de l'état | 3 |
| retour au décodage strict de `guestOS` | 1 |
| le protocole inconnu retombe sur `.vnc` | 1 |
| **tout** retombe sur le défaut (témoin inverse) | 17 |
| l'identité (`id`) devient facultative | 1 |

Le témoin inverse est celui qui compte le plus : dix-sept rouges viennent de la
moitié « ce qu'il ne faut **pas** avaler ». Une tolérance qui accepte tout n'est
pas de la tolérance, c'est un décodeur qui a cessé de lire.

## Je me suis trompé sur la porte, et c'est le sabordage qui l'a dit

L'allocation la plus grosse du programme est le framebuffer : `largeur × hauteur
× 4`, et les deux nombres viennent du fil. J'ai ouvert cette tranche en écrivant
qu'il n'y avait **rien** entre `ServerInit` et dix-sept gigaoctets.

C'était faux.

Le sabordage m1 — retirer mon nouveau refus à la poignée de main — a laissé la
suite verte. Une sonde a imprimé la vraie réponse :

```
disconnected(WisqError.malformedMessage("taille de bureau invalide (65535×65535)"))
```

`performInitialisation` bornait la géométrie depuis toujours. **J'avais lu les
deux premières lignes de cette fonction et je m'étais arrêté.** Le vert du
sabordage n'était pas un test manquant : c'était mon affirmation qui était
fausse.

### Ce qu'il y avait vraiment

| porte | avant |
| --- | --- |
| poignée de main (`ServerInit`) | **gardée**, mais à 16384 par côté ≈ 1 Go |
| redimensionnement (rectangle `desktopSize`) | **aucune garde** — 17 Go, et répétable |
| `Framebuffer` lui-même | aucun filet |

Le vrai défaut est la seconde porte, et c'est la pire des deux : la poignée de
main arrive une fois, tandis qu'un serveur envoie un `desktopSize` quand il veut.
Et le plafond de la première, 16384 par côté, était **quatre fois plus lâche**
que ce que `SpiceSurfaces` s'autorise pour la même sorte d'allocation depuis la
tranche sur les tailles déraisonnables. Deux protocoles, le même danger, deux
nombres différents dont un seul écrit.

Il y a un seul nombre maintenant, `Framebuffer.maximumPixels`, lu par les deux
protocoles, vérifié aux deux portes, avec le refus d'allouer du framebuffer en
filet dessous.

### Les huit sabordages

| sabordage | résultat |
| --- | --- |
| refus de la poignée de main retiré | 1 rouge |
| refus du redimensionnement retiré | 1 rouge |
| filet du `Framebuffer` retiré | plantage : `failed to allocate 17179344932 bytes` |
| clauses par côté retirées, produit gardé | plantage : `arithmetic overflow` |
| plafond SPICE désolidarisé du plafond RFB | 1 rouge |
| le refus ne nomme plus la taille | 3 rouges |
| le bureau vide devient un refus | 1 rouge |
| plafond resserré à 1 Mpx | 7 rouges, dont un test SPICE préexistant |

Deux d'entre eux ne rougissent pas, ils **tuent** — comme ceux de `ByteCursor`
deux tranches plus tôt. La CI serait rouge dans les deux cas, mais ce n'est pas
un échec d'assertion et l'écrire autrement serait se raconter une histoire.

Le troisième est le plus honnête de la série : il ne simule pas le défaut, il
**l'exécute**. `failed to allocate 17179344932 bytes` est exactement ce que la
tranche empêche.

### Une sonde qui ne peut pas *distinguer* ne prouve rien non plus

La règle connue est qu'une sonde qui ne peut pas échouer ne prouve rien. Celle-ci
en est la version subtile.

Mon test bout-à-bout n'affirmait d'abord que « la session s'est arrêtée ». Il
passait avec la garde retirée — parce que sans elle la session meurt un instant
plus tard, faute d'octets. Deux causes très différentes, une seule observation.
Le test affirme maintenant la **raison** : le message doit contenir `65535×65535`.
Les sabordages m1 et m2 le montrent bien, tous deux avec `connectionClosed` —
la mort par manque d'octets, exactement celle qui se faisait passer pour un refus.

### Le produit de build périmé, qui fabrique de faux survivants

Pendant cette tranche, `canHold` a renvoyé `true` pour toute entrée alors que la
source était juste. La cause n'était pas dans le code : restaurer un fichier avec
`cp` peut laisser SwiftPM servir **l'ancien binaire**, si l'horodatage ne bouge
pas assez. Le sabordage semblait survivre alors qu'il n'avait jamais été compilé.

Un résultat de sabordage ne se lit donc pas seul. Il se lit avec la preuve que le
fichier a bien été recompilé — d'où le `touch` avant chaque `swift test` dans la
boucle. Un faux survivant coûte plus cher qu'un faux rouge : le faux rouge se
fait examiner, le faux survivant se fait écrire dans un commentaire.

### Les deux bords

Le bord qui décide si le plafond est utilisable est celui du bas. 64 Mpx laisse
passer tout ce à quoi quelqu'un se connecte vraiment — la 8K est à trente-trois
mégapixels, la moitié de la ligne. Six géométries réelles, la frontière exacte
des deux côtés, et le bureau vide qu'un serveur envoie avant d'en avoir un : ce
sont eux que le sabordage à 1 Mpx fait rougir, sept fois.

Aucun test ici n'alloue quoi que ce soit de grand. Ils affirment le refus — un
test qui construirait vraiment les dix-sept gigaoctets démontrerait le défaut,
pas la correction.

## Le plafond couvrait l'écran, pas ce qui peint dessus

La tranche précédente a plafonné l'**écran**. Un rectangle est un autre nombre
qui arrive par une autre porte, et rien ne le bornait.

Sondé, sur un framebuffer de 64 × 64 :

```
Fatal error: failed to allocate 17179344932 bytes of memory with alignment 8
```

Douze octets de CopyRect. L'encodage ne porte aucun pixel : l'en-tête du
rectangle, un point source, et `Framebuffer.copy` dimensionne son tampon de
travail sur la géométrie seule. RRE fait pareil après un compteur et une
couleur, soit environ huit octets.

### Le fichier disait pourquoi il se croyait sûr

`RFBLimits` portait ceci en tête :

> « RFB's geometry arrives in `UInt16`, which bounds every pixel product on its
> own — that is why the decoders need no arithmetic guards. »

C'est vrai, et c'est vrai **de l'arithmétique**. La borne que `UInt16` donne
vaut 65535² × 4. « Borné » a été lu comme « petit ». Et le fichier écrivait ce
nombre plus bas, en toutes lettres, comme une rassurance :

> « the product is at most 65535² × 4 ≈ 1.7e10 and cannot leave an `Int`. »

Le nombre qui prouve que le calcul ne déborde pas est exactement le nombre qui
dit que l'allocation est intenable. Quatrième fois qu'un commentaire du dépôt
documente sa propre faute — après #59, #61 et #74.

### Un plafond calculé à partir du nombre de l'attaquant

Les autres encodages sont tenus par les octets : le serveur doit vraiment
envoyer les pixels. Mais leur plafond vient de `maximumCompressedBytes(for:)`,
qui est calculé **à partir du rectangle**. Mesuré :

| rectangle | plafond « compressé » |
| --- | --- |
| 1 × 1 | 1 048 580 |
| 65535 × 65535 | **17 180 393 476** |

Une garde dérivée du nombre de l'attaquant accorde ce qu'elle devrait refuser.
Elle ne veut dire quelque chose que maintenant que le rectangle est borné
d'abord : au plus 257 Mio.

### Où la garde se pose, et où elle ne se pose pas

Les pseudo-encodages réutilisent les mêmes quatre `UInt16` pour autre chose :
`desktopSize` y met la nouvelle taille d'écran, `cursor` le point chaud et les
dimensions du curseur, `lastRect` rien du tout. Poser le plafond avant le
`switch` refuserait un redimensionnement que le chemin de resize a le droit de
traiter avec son propre message, et masquerait le 256 × 256 déjà plus serré du
curseur (tranche #79). D'où `carriesPixels`, et un test qui épingle la liste des
sept — parce qu'un encodage ajouté à l'enum et oublié ici est la façon dont ceci
revient.

### Les sept sabordages

| sabordage | résultat |
| --- | --- |
| garde du décodeur retirée | 1 rouge **et** plantage à 17 Go |
| filet de `Framebuffer.copy` retiré | plantage : `failed to allocate 17179344932 bytes` |
| les pseudo-encodages portent des pixels | 9 rouges |
| aucun encodage ne porte de pixels | 1 rouge et plantage |
| le refus ne nomme plus le rectangle | 3 rouges |
| le décalage compté dans le plafond | 1 rouge |
| plafond resserré à 1 Mpx | 15 rouges |

Le premier est le plus instructif : la garde du décodeur retirée, CopyRect
tombe dans le filet du framebuffer — arrêt silencieux, mauvaise raison,
`connectionClosed` — tandis que RRE, qui alloue dans le décodeur où il n'y a pas
de filet, tue le processus. Les deux moitiés de l'argument pour avoir les deux
couches, dans un seul sabordage.

### Le décalage n'entre pas dans le plafond

RFB dit qu'un rectangle est à l'intérieur du framebuffer, et le vérifier
strictement serait plus serré. Mais un redimensionnement et une mise à jour qui
se croisent sur le fil font légitimement dépasser un rectangle le temps d'un
message, et `Framebuffer.write` découpe déjà. Refuser le dépassement casserait
de vrais serveurs pour n'empêcher rien : ce qu'il faut refuser est
l'allocation. Un test tient ce choix par son bord — un rectangle de 16 × 16 à
60000, 60000 doit passer — et le sabordage n6 le fait rougir.

## Trois codecs, trois réponses, et trois sabordages qui survivent

Chacun des trois codecs compressés de SPICE prend une largeur et une hauteur sur
le réseau et alloue à partir du produit. Mesurés un par un, avant :

| codec | par côté | produit | mesuré |
| --- | --- | --- | --- |
| LZ4 | 32768 | **oui** | refuse 32768² |
| QUIC | 32768 | non | **4,03 Gio résidents** (pic de 36 Mio à 4,03 Gio) |
| LZ (alpha) | aucun | non | `failed to allocate 17179869216 bytes` |
| LZ (simple) | aucun | non | **4 Gio réservés** (pic d'espace d'adressage 322 Mio → 4,53 Gio) |

Les deux derniers chiffres ne sont pas la même chose et ne sont pas écrits comme
si. QUIC fait grandir le résident : les pages sont touchées. Le chemin LZ simple
appelle `reserveCapacity`, qui cartographie sans toucher — les pages ne sont
jamais fautées, le résident ne bouge pas, et dire « 4 Gio alloués » de celui-là
serait dire plus que ce qui a été observé. La première mesure, faite au pic
résident, n'a **rien vu du tout** ; il a fallu regarder le pic d'espace
d'adressage pour le voir. Une sonde qui ne mesure pas la bonne chose ne prouve
rien non plus.

### La phrase qui était vraie et qu'on a lue trop large

`SpiceLZ` portait, juste au-dessus de sa garde :

> « a negative one is not a small image, it is a size that becomes enormous the
> moment it is multiplied. Refused before anything is allocated from it. »

Exact, à propos des négatifs. Une paire **positive** se multiplie tout aussi
énormément, et la garde les laissait toutes passer. Et `SpiceLZ4`, le seul
complet, disait « the cap is the same one the other codecs here use » — ce qui
était précisément la partie à vérifier.

Le `1 << 28` de LZ4 n'a jamais été un autre nombre que le plafond partagé, juste
une autre unité : 64 Mpx × 4 octets. Trois nombres qui se trouvaient d'accord,
écrits séparément, ce qui est exactement ce qui rend une divergence invisible.

### Trois sabordages survivants, trois diagnostics différents

C'est la partie qui a appris quelque chose. Sur huit sabordages, trois n'ont pas
mordu, et pas pour la même raison :

| sabordage | résultat | diagnostic |
| --- | --- | --- |
| QUIC : borne par côté seulement | 1 rouge | — |
| LZ : borne de magnitude retirée | 1 rouge **et** plantage 17 Go | — |
| LZ4 : borne sur le produit retirée | **survivant** | **équivalence réelle** |
| LZ4 : `canHold` retiré | **survivant** | **test manquant** |
| LZ : garde de signe retirée | **survivant** | **équivalence pour une moitié, test manquant pour l'autre** |
| LZ4 : `canHold` retiré, après le test ajouté | plantage 4,4 To | — |
| LZ : garde de signe retirée, après | 3 rouges | — |
| plafond resserré à 1 Mpx | 21 rouges | — |

**La borne sur le produit de LZ4 ne pouvait pas échouer.** `canHold` plafonne à
64 Mpx, les formats de ce codec font au plus quatre octets par pixel, et
64 Mpx × 4 est 1 << 28. La même règle écrite deux fois, la seconde ne pouvant
que confirmer la première. Supprimée plutôt que gardée : une garde qui ne peut
pas se déclencher fait croire que le produit est vérifié alors que ce qui
protège est le compte de pixels.

**Mais l'implication ne va que dans un sens.** `canHold` implique le plafond en
octets ; le plafond en octets n'implique pas `canHold`. Une image de 100 Mpx en
seize bits fait 200 Mio : sous l'ancien plafond, au-dessus du partagé. C'est le
cas qui sépare les deux gardes, et il n'était pas testé — d'où le survivant
suivant. Avec son témoin, retirer `canHold` tue le processus.

**Et la garde de signe de LZ.** `canHold` demande `width >= 0` en premier, donc
elle refuse déjà les négatifs : équivalence réelle pour cette moitié. Ce que la
garde du codec couvre seule, c'est le **zéro** — que `canHold` accepte
délibérément — et le **stride**, dont `canHold` n'a aucune idée puisque ce n'est
pas un de ses deux arguments. Trois rouges une fois ces cas écrits.

Un sabordage qui survit n'est pas un échec de la méthode, c'est la méthode qui
parle. Trois fois de suite ici, et trois réponses différentes : supprimer la
garde, écrire le test manquant, ou les deux à la fois.

## L'audit des allocations est clos — et ce qui le tient n'est pas une phrase

Trois tranches ont construit celui-ci : le bureau, les rectangles qui peignent
dessus, et les trois codecs compressés. Chacune a trouvé la même forme, et cette
forme n'est pas « une garde manquante ». C'est **un plafond écrit séparément qui
se trouvait d'accord**. La borne par côté de QUIC, le plafond en octets de LZ4 et
le plafond en pixels du framebuffer étaient « 32768 », « 1 << 28 » et « 64 << 20 »
dans trois fichiers ; parce qu'ils tombaient juste à quatre octets par pixel,
personne n'avait à remarquer que l'un d'eux ne portait que la moitié de la règle.

### Le tableau, à la clôture

| site | ce qui le tient |
| --- | --- |
| bureau RFB (`ServerInit`, `desktopSize`) | plafond partagé |
| rectangle RFB, sept encodages qui peignent | plafond partagé |
| `Framebuffer` (init, resize, copy) | plafond partagé, en filet |
| surface SPICE | plafond partagé |
| QUIC, LZ, LZ4 | plafond partagé |
| masque de glyphes SPICE | **plus serré, délibérément** |
| zlib, ZRLE, Tight, raw | les octets doivent arriver |
| chemin palette de LZ | l'en-tête, borné en amont |
| `SpiceDisplayDecoder` (segments, points) | bornés contre `body.bytes.count` |
| `ByteStream.pad` | **écrivain** : le nombre est le nôtre |

Deux vérifications valent d'être notées parce qu'elles auraient pu devenir des
tranches et n'en méritaient pas. Le chemin palette de LZ prend sa géométrie en
**arguments** et non de l'en-tête — mais son unique appelant de production passe
`header.width`/`header.height`, donc la borne de la tranche précédente le couvre.
Et `ByteStream.pad` dimensionne bien un tampon depuis un compte, mais c'est un
écrivain : le nombre sort de wisq, il n'y entre pas. L'ajouter au tableau aurait
laissé croire le contraire.

### Un quatrième plafond, trouvé en clôturant

`SpiceGlyphMask` porte le sien, `1 << 24`, seize mégapixels. Il n'était pas dans
mon compte, et il n'est pas non plus un trou : il est **plus serré** que le
partagé, avec une raison écrite — une ligne de texte n'a rien à faire à un quart
d'écran.

Ce qui manquait était le lien. Rien n'empêchait de le relever au-dessus du
plafond partagé. Ce qu'il faut tenir sur celui-là n'est donc pas l'égalité mais
la **direction** : il reste le plus petit. Un test l'épingle dans ce sens.

### Ce que le tableau exécutable tient, et que la prose ne tient pas

Deux choses.

D'abord : tout plafond censé être le nombre partagé l'est, et le seul qui diffère
est pinné dans sa direction. Un codec ajouté plus tard est soit dans le tableau,
soit ostensiblement absent.

Ensuite, et c'est la distinction sur laquelle tout l'audit repose : les chemins
qui n'ont **pas** de plafond propre sont tenus par les octets, et le test affirme
qu'ils refusent **pour cette raison-là**. Une géométrie légale avec un flux qui
s'arrête tôt doit revenir `truncated`, pas `badGeometry`. Un chemin sûr parce que
les octets n'arrivent jamais est sûr autrement qu'un chemin sûr parce que la
géométrie est absurde, et un test qui demanderait seulement « est-ce que ça a
levé » appellerait les deux la même chose.

### Les quatre sabordages

| sabordage | résultat |
| --- | --- |
| plafond des glyphes porté au-dessus du partagé | 1 rouge |
| plafond des surfaces redevenu un littéral | 3 rouges, dans trois fichiers |
| QUIC retiré du tableau | plantage : `failed to allocate 17179344932 bytes` |
| plafond partagé resserré à 1 Mpx | 30 rouges |

Le troisième n'affirme pas le défaut, il l'**exécute** : retirer un codec du
tableau ne fait pas échouer une assertion, ça tue le processus sur les dix-sept
gigaoctets que la tranche empêchait. Le quatrième est le bord d'en face — trente
rouges venus de « ce qu'il ne faut **pas** refuser », répartis sur les trois
fichiers que les trois tranches ont laissés.

Il n'y a plus, à ma connaissance, d'allocation dimensionnée par un nombre du fil
qui ne soit ni plafonnée ni tenue par les octets. Ne pas rouvrir à vide : le
tableau ci-dessus dit où ne plus chercher, et pourquoi chaque ligne est saine.

## Un invariant tenu par un argument par défaut dans un autre fichier

`publish` recopie chaque région dessinée depuis la surface primaire vers le
framebuffer. Il indexait `surface.pixels` directement avec les nombres de la
région. C'est correct exactement tant que la région a été découpée contre
**cette** surface et que la surface n'a pas changé depuis — et rien ne le disait.

### L'hypothèse que j'avais, et pourquoi elle était fausse

Je suis parti de l'idée qu'un serveur pouvait, dans un même lot, créer une
surface large, dessiner, la détruire, puis en créer une petite : la région
survivrait à sa surface et l'indexation sortirait du tampon.

C'est faux, et la vérification tient en une ligne : `channel.pump(...)` est
appelé **sans `limit`**, et la signature est `limit: Int = 1`. Un message par
passe, `publish` entre chaque. Un dessin et un `surface_destroy` ultérieur ne
peuvent pas partager un lot.

Troisième fois que la lecture du site seul m'aurait fait écrire une faute : la
réponse était chez l'appelant, pas dans la fonction.

### Ce qui reste, et pourquoi ce n'est pas rien

La preuve de sûreté est réelle, et elle est **entièrement contenue dans un
argument par défaut d'un autre fichier**. Passer `limit: 8` pour le débit — la
première optimisation que quiconque tenterait sur cette boucle — rend le
scénario joignable, et le rend joignable *silencieusement* : rien dans `publish`
ne dit qu'il en dépend.

Un plantage qu'un serveur peut demander ne doit pas être retenu par une valeur
par défaut ailleurs. Le découpage vit maintenant dans `SPICESession.patch(of:in:)`,
qui borne le rectangle contre la surface dont il le découpe, et le rectangle
**coupé** est celui rendu au renderer — annoncer la région demandée reviendrait à
prétendre avoir peint hors de la surface.

### Les cinq sabordages

| sabordage | résultat |
| --- | --- |
| le clip contre la surface retiré | plantage : `Array index is out of range` |
| la borne d'origine (`max(0, …)`) retirée | plantage : `Negative Array index is out of range` |
| la garde de cohérence du tampon retirée | plantage : `Array index is out of range` |
| le rectangle rendu redevient celui demandé | 9 rouges |
| `patch` ne rend jamais rien (témoin inverse) | 8 rouges |

Les trois premiers ne rougissent pas, ils tuent — et c'est exactement le défaut
que la tranche empêche, exécuté plutôt qu'affirmé.

Le témoin inverse est celui qui vaut le plus. Il fait rougir **deux tests
`SPICESessionTests` préexistants** en plus des nouveaux, ce qui est la preuve que
la fonction extraite est bien sur le chemin réel. C'est la leçon du jumeau mort
de `ByteCursor` : une fonction que rien n'appelle passe tous les sabordages du
monde.

## Neuf séquences VT100 sur vingt n'étaient tenues par rien

`TerminalGrid` implémente une vingtaine de séquences CSI et porte trente-deux
tests. La question n'est pas combien de tests il y a, mais **lesquelles des
séquences un test tiendrait si elle cessait de fonctionner**. Mesuré : chaque
cas de la table CSI transformé en no-op, un à la fois, contre la cible
`WisqVMTests` entière.

| tenue | rouges | tenue par rien |
| --- | --- | --- |
| `H`,`f` position | 19 | `A` curseur haut |
| `J` effacer écran | 2 | `D` curseur gauche |
| `L` insérer lignes | 2 | `E` ligne suivante |
| `@` insérer caractères | 2 | `F` ligne précédente |
| `m` graphiques | 2 | `G`,`` ` `` colonne absolue |
| `B`,`e` curseur bas | 1 | `d` ligne absolue |
| `C`,`a` curseur droite | 1 | `X` effacer caractères |
| `K` effacer ligne | 1 | `S` défiler haut |
| `M` supprimer lignes | 1 | `T` défiler bas |
| `P` supprimer caractères | 1 | |
| `r` région de défilement | 1 | |

### Ce que la forme du tableau dit

`H`,`f` marque dix-neuf parce que presque tous les tests positionnent le curseur
avant de vérifier autre chose. Elle est tenue **incidemment**, par des tests qui
parlent d'autre chose.

Et les paires sont coupées en deux : `B` (bas) et `C` (droite) sont tenues, `A`
(haut) et `D` (gauche) ne le sont pas. Rien n'a décidé cela. La direction dont
un test avait besoin est la direction qui a fini par avoir un témoin. La
couverture était un sous-produit, pas un choix — et un sous-produit ne se
remarque pas tant qu'on compte les tests au lieu de compter ce qu'ils tiennent.

**Aucun défaut trouvé.** Les neuf implémentations sont correctes ; écrire leurs
témoins n'a rien cassé. Ce sont des témoins manquants, pas des bogues, et la
tranche ne prétend pas autre chose.

### Deux fois où ma sonde mesurait la mauvaise chose

`S` refusait de se laisser tester. `text` restait `"un\ndeux\ntrois\nquatre"`
après `\u{1B}[2S`, et j'ai d'abord cru le code fautif. Il ne l'est pas :
`scrollUp` **archive** la ligne sortante dans le scrollback, et `text` rend le
scrollback suivi de l'écran. La séquence marche ; c'est la projection qui la
rend invisible. Le témoin est donc écrit sur une grille sans scrollback, et un
second témoin tient l'autre moitié — avec scrollback, `S` conserve ce qu'il
dépasse.

Puis la même leçon en plus petit : `"b\nc\n"` au lieu de `"b\nc"`, parce que la
projection garde la ligne où se trouve le curseur. Mesuré, pas deviné.

Deux fois de suite, la bonne question n'était pas « le code est-il faux » mais
« qu'est-ce que j'observe au juste ». Une assertion sur une projection ne mesure
la chose que si la projection la laisse passer.

### La vérification

Les neuf sabordages qui survivaient donnent maintenant 1 à 3 rouges chacun. Un
témoin qu'on n'a pas vu rougir n'est pas un témoin.

## Les séquences que personne ne tape par accident

Suite directe de la tranche sur la table CSI, avec la même méthode appliquée au
reste de la grille : les contrôles C0, les séquences ESC, les modes privés.
Chaque cas transformé en no-op, un à la fois, contre la cible `WisqVMTests`
entière.

| tenue par un test | rouges | tenue par rien |
| --- | --- | --- |
| écran alterné `47`/`1047`/`1049` | 14 | `ESC D` index |
| `LF`/`VT`/`FF` retour colonne | 12 | `ESC E` ligne suivante |
| `CR` retour chariot | 5 | `ESC c` réinitialisation |
| `BS` retour arrière | 2 | |
| `TAB` tabulation | 2 | |
| `ESC M` index inverse | 1 | |
| mode `25` curseur visible | 1 | |

### Le partage n'est pas arbitraire

C'est la même cause que la fois précédente, jouée à l'envers. Les contrôles en
haut du tableau marquent douze et quatorze parce que **tout test qui écrit du
texte dans la grille tape un saut de ligne ou un retour chariot en chemin**,
pour aller vérifier autre chose. Ils sont tenus *par accident*.

Les séquences ESC marquent zéro parce que personne ne tape `ESC D` par mégarde.
Il faut le vouloir. La tranche précédente avait trouvé `H`,`f` à dix-neuf rouges
pour exactement cette raison — presque chaque test positionne le curseur avant
de vérifier son sujet. Ce qui décide qu'une séquence a un témoin n'est pas son
importance, c'est la fréquence à laquelle un test l'emprunte pour aller
ailleurs.

Ce qui suggère où regarder la prochaine fois : **ce qu'aucun test n'a de raison
de traverser en chemin**.

### Aucun défaut

Les trois implémentations se lisent correctement, et les écrire n'a rien trouvé
de faux. Ce sont les témoins qui manquaient. Contre-vérifiés de la seule façon
qui vaille : chaque séquence redevenue no-op, une à une, donne 6, 7 et 6 rouges
là où elle en donnait zéro.

### Le bord qui compte, pour `ESC c`

Une réinitialisation efface l'écran, le curseur et les attributs — mais **garde
l'historique**. L'écran appartient au terminal, l'historique appartient à
l'utilisateur, et une réinitialisation lancée par un programme auquel il n'a pas
pensé ne doit pas jeter ce qu'il avait remonté pour lire. C'est le bord qu'une
lecture « réinitialiser, c'est tout effacer » raterait, et il a son test.

## Le plus grand filet du dépôt s'arrêtait à la bannière

Troisième application de la même méthode, cette fois au décodeur d'instructions
du cœur rv32ima : cent six bras — chaque `case` du décodeur, chaque garde, chaque
arête de la table RV32M et RV32A — rendus inopérants un à un, contre toute la
cible `WisqVMTests`.

| tenu par | bras |
| --- | --- |
| un test unitaire | 17 |
| le démarrage du noyau, jusqu'à la bannière | 23 |
| le démarrage du noyau, jusqu'à l'invite de connexion | 23 |
| **rien** | **43** |

### Ce que le tableau dit

La troisième ligne n'existait pas avant cette tranche. Elle est le produit d'une
seule assertion ajoutée.

`testBootsARealKernelToItsBanner` exécute soixante millions d'instructions et
vérifie que la sortie contient « Linux version ». Cette ligne part à la deuxième
milliseconde du démarrage. Tout ce que le noyau fait ensuite — installer son
vecteur de piège, redescendre en mode utilisateur par `MRET`, lire et écrire ses
CSR, prendre ses verrous atomiques, lancer `/init` — se déroulait à l'intérieur
d'un test qui avait cessé de regarder.

La preuve est chiffrée : casser l'écriture de `mtvec` fait dérailler la machine
au point que la passe met **cinquante et une secondes au lieu de six** — et
passe, parce que la bannière était déjà sortie.

### La correction ne coûte rien

L'invite `buildroot login:` arrive vers quarante-six millions d'instructions,
**dans le budget de soixante que le test dépensait déjà**. La portée était là ;
il manquait l'assertion. `testBootsAllTheWayToItsLoginPrompt` la pose, et
vingt-trois bras basculent de « tenu par rien » à « tenu » sans qu'une ligne de
l'émulateur change : les CSR que le noyau écrit après la bannière, les trois
moitiés de `MRET`, l'`ECALL` depuis le mode utilisateur, quatre atomiques.

Ce n'est pas non plus une assertion arbitraire : le guide promet au lecteur
*« jusqu'à l'invite de connexion »*. Le dépôt annonçait l'invite et testait la
bannière.

### Un nom qui promettait un cas qu'il ne vérifiait pas

`testLrScPairSucceedsAndStaleScFails` ne teste pas le SC périmé. Faire répondre
« réussi » à la vérification de réservation, sans condition, le laisse vert : il
n'écrit qu'une paire LR/SC appariée. Renommé en `testLrScPairSucceeds`, et le
cas que son ancien nom annonçait est maintenant écrit, avec ses deux moitiés —
un résultat non nul *et* une mémoire intacte.

### Douze témoins, et quatre que la contre-vérification a démolis

Le reste de la tranche écrit les arêtes que la spécification RISC-V fixe et
qu'un noyau qui démarre n'atteint jamais : la division par zéro, l'unique
quotient signé qui déborde, les trois signitudes du multiplieur haut, les quatre
min/max atomiques.

Les douze sont passés du premier coup. La contre-vérification en a démoli
quatre, tous pour la même raison — **une sonde qui ne distingue pas ne prouve
rien** :

- `MULH` sur (−1) × 2³¹ donne un mot haut nul, et un bras qui ne calcule rien
  écrit zéro aussi. Opérandes changées pour que les trois réponses soient non
  nulles et distinctes.
- `REMU` par zéro testé avec un dividende de 7, exactement la constante que mon
  sabordage écrivait. Dividende porté à `0x1234_5678`.
- `AMOMAX` et `AMOMINU` interrogés sur un couple où la bonne réponse est le
  registre — c'est-à-dire précisément ce qu'un bras inerte laisse en place et
  range. Chacun des quatre est maintenant interrogé deux fois, dont une où la
  cellule doit l'emporter.

Vingt-cinq bras rougissent désormais contre ce fichier. Aucun défaut trouvé : les
implémentations se lisent juste, et les deux cœurs — Swift et Rust — se lisent
comme des jumeaux fidèles, bras pour bras.

### Ce qui reste

Vingt-quatre bras encore tenus par rien : la plomberie CSR que le noyau n'écrit
pas (`mip`, `mcause`, `mtval`, `misa`, `mvendorid`, `cycle`, les six micro-ops
lus séparément), les quatre pièges d'adresse hors RAM, le PC désaligné, `EBREAK`,
`WFI` qui endort, le bit d'alignement de `JALR`, `FENCE`. C'est la tranche
suivante.

## Les vingt-quatre derniers bras, et le seul que rien ne pouvait tenir

Suite et fin du balayage du décodeur rv32ima. Les vingt-quatre bras que #113
laissait tenus par rien ont tous la même forme : **la machine qui parle
d'elle-même**. La plomberie CSR que le noyau ne traverse pas — `misa`,
`mvendorid`, `cycle`, `mip`, `mtval`, `mcause` — les cinq pièges d'adresse, le
PC désaligné, `EBREAK`, `WFI`, le bit d'alignement de `JALR`, `FENCE`.

C'est pour cela que le démarrage les rate. Un noyau atteint son invite en
faisant de l'arithmétique, en prenant des interruptions de minuteur et en
redescendant en mode utilisateur : il lit `mstatus` et `mepc` sans arrêt et ne
lit jamais `misa`, n'écrit jamais `mtval`, ne sort jamais de sa propre RAM. Ces
instructions-là sont celles qu'un invité emploie quand quelque chose a mal
tourné, ou quand il veut savoir sur quelle machine il tourne. Un test qui ne
fait que démarrer un noyau sain ne peut voir ni l'une ni l'autre.

### CSRRW : équivalence réelle, et le compilateur pour seul témoin

Un seul bras a survécu à la contre-vérification, et pour la bonne raison. La
variable était amorcée `var writeval = rs1` avant le `switch`, et `CSRRW`
répond précisément `rs1` : son bras disait ce que l'amorce disait déjà. Le
supprimer ne change rien. **Aucun test ne pouvait le tenir** — sa réponse et
celle du repli sont la même valeur.

Des quatre diagnostics, c'est l'équivalence réelle, pas le test manquant. La
correction n'est donc pas un test de plus : c'est `let writeval` avec un
`default` explicite. Les six micro-opérations deviennent porteuses à la
compilation, et le repli — inatteignable, la garde n'admettant que 1, 2, 3, 5,
6 et 7 — est écrit plutôt que sous-entendu. Vérifié aux deux bords : supprimer
le bras est maintenant une **erreur de compilation**, le corrompre en `CSRRS`
donne un rouge.

Le cœur Rust a la même coïncidence (`_ => rs1` attrape ce que `1 => rs1`
laisserait passer) et reste tel quel : la seule façon d'y rendre le bras
porteur serait un `unreachable!()`, c'est-à-dire troquer un repli silencieux
contre une panique dans la boucle d'interprétation, sur un téléphone. Le prix
n'en vaut pas la peine.

### Une assertion qui mesurait le minuteur en croyant mesurer le CSR

`mip` écrit à `0xAAAA_AAAA` se relit à `0xAAAA_AA2A` deux instructions plus
tard. Ce n'est pas l'écriture qui a échoué : le bit 7 est `MTIP`, que le hart
republie depuis l'horloge **en tête** de chaque pas. Le code avait raison,
l'assertion avait tort.

Le comportement exact est maintenant épinglé, avec sa temporalité : l'écriture
de l'invité passe entière et survit à l'instruction qui l'a faite, puis se fait
écraser au pas suivant. Les deux moitiés comptent — un gestionnaire qui pose le
bit et le relit voit sa propre valeur ; un gestionnaire qui compte dessus se
trompe une instruction plus tard.

### Le balayage est clos

Cent six bras, trois tranches. 17 tenus par un test unitaire, 23 par le
démarrage jusqu'à la bannière, 23 par l'assertion sur l'invite de connexion,
43 par les deux fichiers de témoins — dont un que seul le compilateur peut
tenir. Aucun défaut trouvé dans l'émulateur ; ce qui manquait, ce sont les
témoins, et une assertion de démarrage qui regardait la deuxième milliseconde.

## Deux sabordages qui ne faisaient pas rougir, mais pendre

La mesure visait autre chose : « Les deux interpréteurs sont d'accord » —
d'accord sur quoi, au juste ? Le test différentiel compare les cœurs Swift et
Rust exactement, mais seulement sur un démarrage de noyau et une frappe au
shell. Il ne leur fait jamais exécuter d'instruction choisie.

Les cent six bras du décodeur, sabordés un à un côté Swift, contre la suite
`WisqVMRustTests` :

| ce qui arrive quand le cœur Swift se trompe | bras |
| --- | --- |
| la comparaison le remarque | 66 |
| le compilateur l'attrape (les six micro-ops CSR de la tranche précédente) | 6 |
| **personne ne le remarque** | **32** |
| la suite *pend* au lieu d'échouer | 2 |

Les trente-deux sont les mêmes que le balayage précédent avait isolés : ce qu'un
noyau qui démarre bien ne traverse pas. Un cœur Swift qui se tromperait sur
`AMOMINU`, sur la division par zéro ou sur le contenu de `mtval` serait déclaré
d'accord avec le cœur Rust.

### Mais ce sont les deux derniers qui valaient le détour

Un sabordage qui fait *pendre* la suite n'est pas un bras non couvert : c'est un
symptôme. En tirant le fil — `l'interruption timer` retirée, le noyau se gare et
ne se réveille plus — on tombe sur une propriété de `run()` qui n'a rien à voir
avec le sabordage :

**Un hart garé ne peut jamais épuiser un budget d'instructions.** Le budget
compte les instructions *retirées*, délibérément, pour qu'un invité oisif ne
puisse pas dépenser un budget en ne faisant rien. Un hart en `WFI` n'en retire
aucune. Et sur cette machine le minuteur est le seul réveil possible : un hart
garé n'exécute rien, donc ne peut pas non plus interroger l'UART.

Donc un invité qui exécute `WFI` **sans minuteur armé** fait tourner la boucle à
plein régime, pour toujours. Mesuré avant d'être écrit : un invité de deux
instructions retire une instruction, puis `run(instructionBudget: 10 000)` ne
rend jamais la main — il a fallu `stop()`. Et l'application appelle `run()` une
seule fois, sans budget : « pour toujours » signifie jusqu'à ce que
l'utilisateur quitte l'écran, avec un cœur épinglé et une batterie qui chauffe.

Ce n'est pas un défaut de test. C'est le produit.

### La correction, dans les deux cœurs

Si le hart est garé et qu'aucun minuteur n'est armé, rien ne le réveillera :
`run` rend `.stopped` au lieu de tourner. L'appelant — vérifié, `LocalVMModel`
appelle `run()` une fois et rapporte l'issue — affiche « Arrêtée. » au lieu de
ne rien afficher pendant que le téléphone chauffe.

Le commentaire d'origine raisonnait déjà sur la batterie pour le cas *armé* (il
saute l'horloge jusqu'au rendez-vous plutôt que d'y ramper) ; il avait manqué le
cas non armé, qui est le pire des deux.

Corrigé des deux côtés, parce qu'un désaccord entre les cœurs sur ce point
casserait la reprise d'un instantané.

### Trois cas, dont un qui doit survivre

Le bord qui compte est celui qu'il ne faut **pas** casser : un hart garé avec un
minuteur armé attend quelque chose qui arrive, et doit continuer d'attendre. Une
correction qui rendait la main à chaque `WFI` transformerait tout invité Linux
au repos en invité arrêté. Le programme témoin arme le CLINT par MMIO, comme le
ferait un vrai invité, et le cas survit au sabordage pendant que les deux autres
rougissent.

Les témoins sont bornés sur l'horloge murale, pas sur la machine : une
régression ici ne fait pas échouer lentement, elle ne rend jamais la main. C'est
l'attente bornée qui transforme « pend » en « rouge ».

### Ce qui reste

Les trente-deux bras que la comparaison ne remarque pas. Le mécanisme pour les
couvrir existe déjà et vient d'être étrenné : charger le même programme codé à
la main dans les deux cœurs et comparer `snapshot()` octet pour octet, ce qui
compare la RAM, les registres et les CSR d'un coup. C'est la tranche suivante.

## Le site quitte GitHub Pages, et la page de confidentialité doit suivre

Demande de Maxime, depuis un téléphone et sans ordinateur : mettre le site sur
Heroku, couper Pages. La contrainte — personne ne pourra ouvrir un portable
quand une construction cassera — a décidé de presque tous les choix.

### Le buildpack Bun n'a pas survécu à la vérification

Le premier réflexe était un buildpack Bun communautaire : quelques clics dans le
tableau de bord, rien à écrire. Quatre candidats vérifiés plutôt que cités de
mémoire — une URL en 404, un qui détecte un projet Bun à un `bun.lockb` **à la
racine** (notre verrou est `site/bun.lock`, autre nom, autre dossier : il ne
détecterait pas), un en v0.0.2, un non concluant.

Fonder sur ça un déploiement indébogable depuis un téléphone n'était pas
raisonnable. D'où le buildpack Node **officiel**, un `package.json` racine dont
c'est le seul rôle, et `scripts/heroku-build.sh` qui installe Bun lui-même. La
chaîne de dépendances tient alors dans des fichiers que ce dépôt peut lire.

### La construction refuse de partir sans `SITE_URL`

Une adresse publique fausse ne se voit pas dans le navigateur et se voit dans
chaque lien canonique et chaque entrée du sitemap. Le script s'arrête donc, avec
le réglage exact à poser. Une première construction qui échoue avec la marche à
suivre vaut mieux qu'un site publié qui pointe à côté.

### Un test qui épinglait l'ancien hébergeur

`tests/build.test.ts` affirmait que le sitemap contient `/wisq/…</loc>` — le
chemin du site **sur GitHub Pages**. C'était un test de l'endroit où le site
vivait, pas de ce que la construction produit, et il est devenu rouge le jour du
déménagement. Deux tests plus loin, un autre garde explicitement contre « un
`/wisq/` codé en dur dans une référence d'actif ». La suite se contredisait.

Résolu par `src/site-url.ts` : une seule résolution, lue par la construction et
par le test. Contre-vérifié — le sitemap fabriqué avec une autre base fait
toujours rougir le test, il n'est pas devenu tautologique.

### Ce que le dépôt affirmait et qui cessait d'être vrai

Le plus important n'est pas un commentaire : c'est **la page de confidentialité**,
qui nomme au lecteur qui reçoit ses requêtes. Elle disait GitHub, dans les deux
langues. Corrigée.

Puis `scripts/serve.ts`, dont l'en-tête expliquait que ses trois classes
d'en-têtes de cache n'atteignent jamais le site déployé, « GitHub Pages envoyant
les siens et n'offrant aucun moyen de les fixer », et se terminait par : *ce
qu'il faudra configurer le jour où le site déménage vers un hôte qui accepte des
instructions*. Ce jour est arrivé, et rien n'a eu à être configuré — le
`Procfile` lance ce fichier. Ces trois lignes sont de la production maintenant,
et le service worker ne porte plus le cache tout seul.

Idem pour `build.tsx` et `routes.ts`, qui expliquaient que tout chemin émis est
relatif « pour le jour où le site déménagera ». Le pari a payé : le déménagement
n'a demandé aucune réécriture d'adresse.

### La CI joue le chemin d'Heroku

Le job « Build site » ne publie plus rien, mais il lance maintenant
`npm run heroku-postbuild` sur le même commit. C'est un point d'entrée différent
— la racine, le Bun qu'il installe, le `SITE_URL` qu'il exige — et rien d'autre
ici ne remarquerait qu'il casse. Une rupture du déploiement devient une pastille
rouge plutôt qu'une surprise sur le téléphone.

### Vérifié, pas supposé

La chaîne entière jouée localement comme Heroku la joue : refus sans `SITE_URL`
(code 1), construction, `npm start` qui sert sur `$PORT`, 200 sur `/` et `/fr/`,
`text/javascript` + `no-cache` sur le service worker, 404 sur l'inconnu, et le
lien canonique qui pointe sur `SITE_URL`. Bun se télécharge bien dans
`.heroku-bun` — vérifié, car le `Procfile` y renvoie en dur et un Bun système
aurait masqué l'échec.

Ce qui reste à faire à la main, et que je ne peux pas faire d'ici : dépublier le
site dans Settings → Pages. Couper le workflow arrête de publier ; l'ancienne
adresse reste servie tant que personne ne la retire.

## Comparer les deux cœurs sur des instructions choisies

Suite directe de la tranche précédente, qui avait mesuré la portée réelle du
test différentiel : sur cent six bras du décodeur, la comparaison en remarque
soixante-six, le compilateur six, **et personne trente-deux**. Un cœur Swift qui
se tromperait sur `AMOMINU`, sur la division par zéro ou sur le contenu de
`mtval` serait déclaré d'accord avec le cœur Rust.

Ce fichier ne démarre rien. Chaque cas est une poignée de mots codés à la main,
chargés dans les deux cœurs, exécutés au même budget, comparés de trois façons.

### Le piège d'un test différentiel, et comment il est fermé

Comparer deux implémentations répond à « sont-elles d'accord », jamais à
« ont-elles raison ». Deux erreurs identiques sont d'accord — et un programme
qui piège sur sa première instruction aussi. Un différentiel mal encodé passe
donc tout seul.

D'où la troisième assertion : chaque invité **émet un octet sur l'UART**, choisi
distinctif, et le test l'exige en plus de l'accord. Un programme mal encodé
n'imprime rien, ou autre chose, au lieu de passer en silence. C'est ce qui a
permis d'écrire quinze programmes en hexadécimal à la main sans se mentir.

### Ce que la correction précédente a débloqué

Ce fichier n'aurait pas pu exister la semaine dernière : un invité qui se gare
faisait tourner `run` pour toujours, donc on ne pouvait pas confier des
programmes arbitraires à un harnais. Les deux cœurs rendent maintenant la main
quand un hart garé ne peut plus être réveillé. La correction d'un défaut a
ouvert le test qui manquait.

### Deux fois la même erreur, à quatre jours d'intervalle

`AMOMAX` et `AMOMINU` ont survécu à la contre-vérification. Le couple choisi —
cellule à −1, registre à 1 — donne pour bonne réponse **le registre**, c'est-à-dire
exactement ce qu'un bras inerte laisse en place et range. Une sonde qui ne
distingue pas ne prouve rien.

C'est mot pour mot l'erreur corrigée dans `RV32ArithmeticWitnessTests`, et la
leçon n'a pas traversé d'un fichier à l'autre. Elle est maintenant écrite dans
le test qui la corrige, à côté du couple inverse.

Et `JALR` a survécu pour une raison plus bête encore : le commentaire disait
« offset 21 », le code écrivait `20`. Cible paire, masque jamais exercé. La
contre-vérification l'a trouvé ; la lecture ne l'avait pas trouvé.

### Le compte

| | bras |
| --- | --- |
| attrapés par le nouveau fichier | 30 |
| hors de portée d'un différentiel, tenus ailleurs | 2 |

Les deux, dits plutôt que tus. **Le PC désaligné** est inatteignable depuis du
code invité : `JAL` a un bit de poids faible nul par construction et `JALR` le
masque, et la seule autre route — un vecteur de piège impair — piège à l'entrée
de son propre gestionnaire, sans rien laisser imprimer. C'est le quatrième des
quatre diagnostics, et seul un test unitaire qui pose le curseur directement
peut le tenir. **`WFI` qui rouvre les interruptions** demanderait d'armer le
CLINT, se garer, se réveiller et relire `mstatus` : un programme assez long pour
que ce soit surtout le programme qu'il teste. Le témoin unitaire d'à côté lit le
drapeau en trois lignes.

Aucun désaccord trouvé entre les deux cœurs. Ce qui manquait, c'était la
question.

## « L'instantané rend la machine telle quelle » — trente-cinq champs sur cinquante et un

Même méthode que les tranches précédentes, sur une autre affirmation :
`Snapshot.swift` dit que RAM, registres et octets en attente reviennent
« exactement là où l'invité était ». Cinquante et une choses sont sauvées —
trente-deux registres entiers, seize registres de contrôle, la RAM, les touches
pas encore lues et les octets pas encore rendus à la console.

La mesure : retirer, une à une, chacune des cinquante et une affectations de
`restore`, et faire tourner la suite entière contre chaque sabotage. La lecture
reste faite, donc le lecteur s'équilibre toujours et l'instantané est toujours
accepté ; le champ garde simplement ce que la machine avait déjà.

| | champs |
| --- | --- |
| remarqués par la suite | 16 |
| passés inaperçus | 35 |

Sur les trente-cinq, **un** est une vraie équivalence : `x0` est câblé à zéro,
un instantané valide n'y porte rien d'autre, et perdre sa restauration ne change
rien. Les trente-quatre autres étaient des trous, `mepc` et vingt-six registres
entiers parmi eux.

### Deux sondes qui avaient l'air de tout tenir

`SuspendedMachineTests.testARealMachineSurvivesTheFile` compare les deux
instantanés octet pour octet — la bonne assertion. Mais sa machine exécute
quatre octets de `nop` puis piège en boucle : la plupart de ses registres et la
moitié de ses CSR valent zéro. Retirer la restauration d'un champ déjà nul ne
change rien. Une sonde qui ne distingue pas ne prouve rien, pour la cinquième
fois.

`SnapshotAgreementTests.testEachCoreResumesFromTheOthersSnapshot` restaure un
vrai Linux démarré et le poursuit six millions d'instructions, puis compare le
compte retiré. Deux aveuglements, l'un dans l'autre :

- **Le compte est le même nombre** pour une machine qui marche et une qui ne
  marche pas. Un invité qui a perdu son adresse de retour déraille — et un
  invité qui déraille est occupé : il retire les six millions d'instructions
  que le budget lui donne. Mesuré : avec `restore` laissant tomber `x1`, le
  compte correspondait et le test passait.
- **La fenêtre était muette.** Mesuré aussi, en affirmant le contraire et en
  regardant échouer : dans ces six millions d'instructions, ce noyau n'écrit
  rien du tout. Même une assertion sur la console aurait comparé deux chaînes
  vides.

Le test cherche maintenant le moment où l'invité reparle au lieu de le deviner
— c'est la solution que la suite Rust avait déjà trouvée et écrite, et que ce
fichier-ci n'avait pas reprise — et compare les octets écrits après
l'instantané, le compte gardé à côté.

### Ce que la correction a rapporté, et ce qu'elle n'a pas rapporté

Il faut être précis, parce que la lecture flatteuse est à portée de main. La
perte de la RAM est désormais attrapée par la console seule : le compte, lui,
correspond. Le compte était bien la moitié faible.

Mais les trente-cinq champs que ce test ne voyait pas, il ne les voit toujours
pas — re-mesuré champ par champ après la correction, les trente-cinq survivent.
Un démarrage ne peut pas tenir un registre donné : qu'il soit vivant à l'instant
précis où l'instantané est pris est un accident de l'endroit où le démarrage en
était.

### Le témoin

`SnapshotFieldWitnessTests` n'exécute rien. Il construit un instantané où
**chaque champ sauvé porte une valeur différente et non nulle**, le restaure, et
le réécrit. Ce que la restauration laisse tomber revient à zéro, et le mot qui
le nomme est celui qui échoue.

Construit à partir d'un vrai instantané plutôt qu'assemblé de zéro : la section
RAM est codée par plages, et un encodeur écrit à la main dans un test serait une
seconde implémentation de la chose testée. Seuls les mots à largeur fixe sont
réécrits sur place, et le dernier blob remplacé.

Les valeurs attendues sont fixées dans le test, pas relues par un second appel —
si bien que les mêmes assertions tiennent aussi le côté écriture : mettre un
champ à zéro dans `snapshot()` fait rougir le fichier. Vérifié, sur `mtval` et
sur un registre.

Contre-vérification : les trente-cinq survivants sabotés contre ce seul fichier.
**Trente-quatre attrapés sur trente-quatre trous** ; `x0` ne l'est pas, et ne
peut pas l'être.

### Le garde que le Rust tient de son compilateur et que le Swift n'avait pas

`snapshot.rs` affirme `size_of::<Core>() == CORE_WORDS * 4` à la compilation :
ajouter un registre au cœur Rust empêche la caisse de compiler. Côté Swift il
n'y avait rien — `RV32Core` est une classe, sa taille est celle d'un pointeur,
et `Snapshot.coreWords` est une constante que rien ne relie au type.

C'est la panne à laquelle ce format est le plus exposé, parce qu'elle démarre :
la machine revient, tourne, et n'est discrètement pas celle qui a été sauvée. Le
test qui la couvre maintenant lit les propriétés stockées de `RV32Core` par
réflexion et les confronte à la liste nommée. Instrument plus faible qu'une
assertion de compilation — il échoue à l'exécution — mais c'est la même alarme,
et elle donne le nom du champ oublié.

Aucun défaut trouvé dans le format lui-même. Ce qui manquait, encore une fois,
c'était le témoin.

## La même mesure sur le cœur Rust : un trou sur cinquante et un

Le format d'instantané est partagé octet pour octet entre les deux cœurs — c'est
écrit dans `Snapshot.swift` et tenu par un test qui restaure l'instantané de
chacun dans l'autre. Le **témoin**, lui, n'était pas partagé. Même balayage,
mêmes cinquante et une affectations, cette fois dans `set_core_words` et
`Machine::restore`.

| cœur | remarqués | passés inaperçus |
| --- | --- | --- |
| Swift (avant la tranche précédente) | 16 | 35 |
| Rust | 50 | 1 |

La différence tient à un seul fichier : `snapshot.rs` porte depuis toujours
`the_cpu_comes_back_word_for_word`, qui met une valeur distincte dans chacun des
quarante-huit mots et vérifie qu'ils reviennent. C'est, à la lettre, la
construction que la tranche précédente vient d'écrire côté Swift — écrite ici
dès le départ, et absente là-bas. Deux implémentations du même format, la même
affirmation, et des quantités de preuve sans rapport.

### Le trou qu'ils avaient en commun

`pending_output` : les octets qu'un invité croit avoir imprimés, sortis de son
UART et pas encore arrivés au terminal. Ni l'un ni l'autre cœur ne le tenait.
C'est la moitié à laquelle personne ne pense — la file d'entrée, elle, a son
test des deux côtés depuis longtemps.

Vérifié dans les deux sens : perdre la restauration fait rougir le test ; écrire
un blob vide dans `snapshot()` aussi.

Et un piège au passage, du genre que ces carnets répètent : le premier sabotage
du chemin d'écriture a paru survivre. Il ne compilait pas. `writer.bytes(&[])`
ne donne pas son type à l'inférence, la caisse refusait, et mon filtre comptait
les tests échoués sans regarder si le build avait eu lieu. **Un vert peut être
une absence de compilation** — le harnais du balayage exigeait « Compiling
wisq-vm » dans le journal, la vérification à la main ne l'exigeait pas.

### Où ne plus chercher

Le chemin d'instantané des deux cœurs est maintenant tenu champ par champ, dans
les deux sens, et contre-vérifié par sabotage : cinquante et un sur cinquante et
un côté Rust, cinquante sur cinquante et un côté Swift (`x0` est câblé à zéro,
c'est une vraie équivalence, pas un trou). Il n'y a plus rien à mesurer ici.

## Trois déploiements morts sur une garde que j'avais écrite

Le site ne montait pas sur Heroku. Trois constructions échouées dans la journée,
et la cause était `scripts/heroku-build.sh` : il refusait de construire sans
`SITE_URL`. Reproduit localement en rejouant la chaîne Heroku exactement — la
racine `package.json`, `npm run heroku-postbuild` — sans la variable : la
construction s'arrête là, code 1, à chaque fois.

Le raisonnement de la garde était juste et la conclusion fausse. Une adresse
canonique fausse ne se voit pas dans le navigateur et se voit dans chaque entrée
du sitemap — vrai. Mais arrêter la construction transforme « l'opérateur a
oublié une variable » en « le site n'existe pas », et sur un téléphone personne
ne peut ouvrir un portable pour la corriger. J'avais posé la garde, puis donné
trois fois la marche à suivre au lieu de retirer la marche à suivre.

### L'adresse se résout là où elle est connue

Le serveur voit l'hôte de chaque requête. La construction pose désormais une
sentinelle — un hôte `.invalid`, injoignable exprès — partout où l'adresse du
site apparaît, et `site/scripts/serve.ts` la remplace par l'origine de la
requête qu'il répond : liens canoniques, alternates `hreflang`, sitemap,
`robots.txt`, carte sociale. Le site est correct sur n'importe quel hôte, sans
rien à configurer, et déplacer le déploiement ne demande aucune reconstruction.

La sentinelle est injoignable par choix. Si la réécriture cessait, ce qui
resterait serait un lien visiblement cassé, pas une adresse plausible et fausse.

`SITE_URL` marche toujours et épingle l'adresse — ce que veut un domaine
personnalisé, où l'origine que voit un dyno n'est pas celle qu'utilisent les
lecteurs.

### Le proxy qui termine le TLS

Heroku termine le TLS à son routeur et transmet du HTTP simple au dyno : le
schéma que voit le processus est `http` pour un lecteur qui a tapé `https`. Sans
`X-Forwarded-Proto`, chaque lien canonique d'un site en `https` aurait annoncé
une adresse qui redirige. Seuls `http` et `https` sont acceptés depuis cet
en-tête : il est contrôlable par un tiers sur un hôte qui ne le pose pas, et le
pire qu'une valeur fausse puisse faire ici est d'estampiller un schéma — refuser
tout le reste l'empêche d'estampiller ce qui n'en est pas un.

### Deux erreurs de méthode, dites plutôt que tues

**J'ai effacé mon propre travail avec `git checkout --`.** Le sabotage de
vérification portait sur `serve.ts`, qui portait aussi des modifications non
commitées ; annuler le sabotage a tout emporté. Le harnais de balayage, lui,
patche et restaure des fichiers propres — c'est fait à la main que la règle
manquait. Les tests unitaires passaient encore : ils avaient été lancés avant.
C'est la répétition de la chaîne complète, jusqu'à un `curl` sur le dyno, qui a
montré la sentinelle non remplacée.

**Mes premiers tests testaient mon shell.** Ils supposaient que `dist` avait été
construit sans `SITE_URL` — la façon dont la CI et `verify.sh` le construisent —
et seraient devenus rouges pour quiconque avait la variable exportée. Les deux
configurations sont réelles et le déploiement utilise la première ; les tests
énoncent maintenant le contrat dans les deux, et la CI joue le chemin Heroku
deux fois plutôt qu'une. Un seul passage aurait couvert celle qui ne sert pas.

## « Le site fonctionne hors ligne » — neuf comportements, zéro tenu

Le site annonce qu'il s'installe et fonctionne sans réseau. Six tests
couvraient déjà `sw.js`, et ils ont tous le même trait : **ils le lisent comme
du texte**. `toContain("new Set(")`, `toContain("response.ok")`,
`toContain("offlineFor")` — des fils tendus sur la source, pas des vérifications
de ce que le worker fait.

La mesure : neuf comportements cassés un par un dans `build.tsx`, chaque
sabotage choisi pour **laisser intacte chaque chaîne citée par un test**.
`addAll(wanted)` devient `addAll([])`, `if (response.ok)` devient
`if (response.ok || true)`, `offlineFor` garde son nom et répond toujours
anglais.

| | comportements |
| --- | --- |
| remarqués par la suite du site | 0 |
| passés inaperçus | 9 |

Vérifié plutôt que supposé : le `dist/sw.js` construit portait bien
`addAll([])` — relu depuis `dist`, pas depuis le patch. Un service worker qui ne
précache **rien**, donc un site qui ne fonctionne pas du tout hors ligne, passe
les quatre-vingt-dix-neuf tests du site.

### Le témoin exécute le worker

`site/tests/service-worker.test.ts` charge le vrai `sw.js` dans un faux
`caches`, un faux `fetch` à qui on peut dire que le réseau est coupé, et un
`self` minimal ; puis il déclenche `install`, `activate` et `fetch`, et
n'affirme que sur ce qui atterrit dans le cache et sur ce qui revient à la page.

Le faux `Cache.addAll` **rejette la liste entière quand deux entrées résolvent
vers la même URL** — c'est le défaut pour lequel la déduplication existe, trouvé
autrefois en pilotant un navigateur. Un faux qui tolérerait les doublons ne
pourrait pas le tenir.

Les corps de réponse sont distincts partout où deux chemins pourraient se
confondre : « du cache » contre « du réseau », « hors ligne en anglais » contre
« hors ligne en français ». Une sonde qui ne distingue pas ne prouve rien, et
deux pages hors ligne ont la même forme.

Contre-vérification : les neuf sabotages rejoués contre ce seul fichier.
**Neuf attrapés sur neuf**, chacun par le test qui nomme son comportement.

### Ce qu'on garde des anciens tests

Ils restent, et un commentaire dit pourquoi : lire le texte attrape une
construction qui a cessé d'émettre quelque chose — un fichier disparu de la
liste de précache — ce que l'exécution du worker ne voit pas, puisqu'elle ne
sait rien de ce que le site aurait dû produire. Les deux moitiés se complètent ;
ce qui manquait, c'était la seconde.

Aucun défaut trouvé dans le worker lui-même.

## La défense de la bibliothèque n'était armée que par un `load`

Quatrième fois que ce dépôt trouve la même forme de défaut : une garde qui tient
parce que ses appelants se trouvent faire le bon geste, et rien qui l'énonce.

`MachineStore` garde les entrées qu'une version plus ancienne ne sait pas lire :
`loadOnQueue` les met de côté dans `preserved`, `saveOnQueue` les réécrit. C'est
la moitié qui empêche la correction de #78 d'être pire que le défaut qu'elle
fermait — une vieille version ouvrant une bibliothèque récente, sauvant une
fois, et emportant les entrées récentes avec elle.

Mais `preserved` n'est rempli **que** par un chargement. `save` est public et
n'en fait aucun : sur un store qui n'a rien lu, il ajoutait une liste vide
d'entrées préservées et effaçait du fichier exactement ce que le chemin de
lecture existe pour garder.

Mesuré avant d'être écrit : une entrée illisible dans le fichier, un `save`
aveugle, **zéro entrée restante**.

### Pourquoi personne ne l'avait vu

Les trois opérations composites ne sont pas symétriques. `upsert` et `delete`
chargent avant d'écrire — le commentaire d'à côté dit même « l'autre opération
composite qui lit la liste et la réécrit ». `save` est la troisième, et la
seule qui écrit sans lire. L'application n'appelle jamais que les deux
premières, donc rien ne pouvait déclencher la perte.

Ce n'est pas une défense, c'est une coïncidence d'appelants. La sûreté d'une
méthode publique ne peut pas reposer sur celle de ses sœurs que l'appelant a
choisie.

### Ce que la correction coûte, dit plutôt que découvert

`saveOnQueue` lit avant d'écrire. Quand un chargement a déjà eu lieu, le cache
répond et cela ne coûte rien.

Ce que cela change : `save` **refuse maintenant un fichier qu'il ne sait pas
analyser du tout**, là où il l'écrasait. C'est la réponse que `upsert` et
`delete` donnent depuis toujours, et c'est la bonne — une bibliothèque qui ne
s'analyse pas est peut-être encore une bibliothèque, et la remplacer est la
seule perte que personne ne peut annuler. Un test l'épingle, avec le fichier
laissé intact.

Les deux tests ont été contre-vérifiés en retirant la lecture : ils rougissent,
et rien d'autre dans les 1 144 tests ne bouge.

## Où en est la carte, au soir du 28 août

Cinq tranches dans la journée, toutes de la même méthode, et il vaut la peine
d'écrire ce que la journée a appris plutôt que seulement ce qu'elle a livré.

**Ce qui a le mieux marché** : prendre une phrase que le dépôt écrit sur
lui-même — « l'instantané rend la machine telle quelle », « les deux
interpréteurs sont d'accord », « le site fonctionne hors ligne » — et compter
son dénominateur avant de croire quoi que ce soit. Trois fois sur quatre, le
code était juste et c'est la preuve qui manquait. La quatrième a donné un vrai
défaut, et il n'est pas venu d'un balayage : il est venu de lire trois méthodes
côte à côte et de remarquer que deux lisaient avant d'écrire et pas la
troisième.

**Ce qui a coûté du temps sans rien apprendre** : chercher une tranche par
élimination une fois les veines évidentes fermées. Le `.rdp` est déjà bien
tenu, la surface HTTP du démon est petite et couverte, la forme « garde armée
par ses appelants » n'existait qu'à l'endroit déjà corrigé. Le dire est plus
utile que d'ouvrir une tranche faible pour avoir quelque chose à livrer.

**Deux erreurs de méthode, toutes deux de lecture** — et c'est la même erreur
deux fois : `head -3` a coupé une liste juste avant le fichier qui prouvait le
contraire de ce que j'allais écrire, et un `grep -c FAILED` a compté zéro échec
sur une caisse qui ne compilait pas. Le harnais de balayage exige « Compiling »
dans le journal ; la vérification à la main ne l'exigeait pas. **Un vert peut
être une absence d'exécution**, et une sortie tronquée n'est pas une sortie
vide.

**Une troisième, de manipulation** : `git checkout --` pour annuler un sabotage
a emporté du travail non commité sur le même fichier. Les tests passaient
encore — ils avaient tourné avant. C'est la répétition de bout en bout, jusqu'à
un `curl` sur le vrai serveur, qui l'a montrée.

## « VM introuvable » quand c'est libvirt qui ne répond pas

`VirshBackend::get` faisait `Ok(self.describe(id).ok())` : **toute** erreur
devenait « cette VM n'existe pas ». Un hôte dont libvirtd est arrêté, ou sur
lequel `virsh` n'est pas installé, répondait au téléphone *VM introuvable :
debian-13* à propos d'une machine qui existe et va bien.

Deux conséquences, et la seconde est la plus parlante : le service a un bras
`Err(message) => Response::error(500, &message)` pour ce cas, prêt à remonter la
vraie cause — et il était **inatteignable**. Le seul endroit préparé à dire ce
qui n'allait pas était du code mort.

### Pourquoi ce n'est pas qu'un `?` oublié

Absent et injoignable doivent rester deux réponses, et on ne peut pas les
séparer en interrogeant le domaine sur lui-même : `virsh domstate` sort non nul
pour un domaine inconnu **et** pour un hyperviseur qu'il n'atteint pas. Les
distinguer voudrait dire lire sa prose — « failed to get domain » contre « failed
to connect to the hypervisor » — c'est-à-dire épingler les messages d'un outil
qu'on ne contrôle pas.

La question est donc posée à la **liste**, qui n'échoue que quand libvirt
échoue. Un nom absent d'une liste que libvirt a produite avec succès est
vraiment absent. C'est l'autre bord de la règle, et il compte autant : une
correction qui remonterait tout comme une erreur aurait passé les deux tests du
défaut et cassé le 404 dont l'application dépend. Un test le tient, et le
sabotage qui « répare » trop le fait rougir — vérifié.

### Le faux `virsh`

Un script shell écrit par le test, rendu exécutable, et passé comme chemin du
binaire. Une abstraction autour de `Command` aurait laissé les tests s'entendre
avec une maquette sur quelque chose que le vrai binaire fait autrement ; là,
c'est le vrai lancement, le vrai code de sortie et la vraie sortie standard.

Avec un cas témoin en tête de fichier : le faux `virsh` doit d'abord savoir dire
« quelque chose ici » — une VM trouvée, en marche, sur le port 5901 — sans quoi
chaque test suivant passerait pour la mauvaise raison.

### Au passage

`list` et `get` partagent maintenant `names()`, un seul appel `virsh` sans
`domstate` par domaine. `get` ne paie donc pas la liste complète pour savoir si
un nom existe.

## Le protocole promettait un état que libvirt ne dit jamais

`AGENT-PROTOCOL.md` décrivait `POST /v1/vms/{id}/start` comme répondant
« immédiatement avec l'état `starting` ». C'était vrai d'une implémentation sur
deux : le backend de démonstration le produit, `VirshBackend` ne le peut pas.
Libvirt n'a pas cet état — un domaine est `running` dès qu'il existe, pendant
que son invité monte encore son affichage — et aucune sortie de `virsh domstate`
ne signifie « en train de démarrer ».

Trois artefacts s'accordaient entre eux et pas avec le code : le document, le
test bout-à-bout qui affirme `.starting`, et le backend de démo qu'il pilote.
La forme est celle de #71 — des fichiers qui se citent l'un l'autre et
divergent de ce qui tourne vraiment.

### Ce que j'ai cru à tort, puis vérifié

Ma première idée était que le client se ferait berner : si virsh dit `running`
tout de suite, `waitUntilRunning` rendrait la main avant que la console soit
joignable. **Faux.** La boucle exige `running` **et** un port de console, et
`describe` ne pose le port que lorsque `virsh vncdisplay` en donne un. Le client
attend donc correctement.

Ce qui restait vrai après vérification est plus étroit et vaut quand même : le
contrat écrit est faux pour un agent tiers, et la règle qui sauve le client —
les deux moitiés — n'était écrite nulle part et vivait dans une boucle où aucun
test ne pouvait l'atteindre.

### La règle sort de la boucle

`AgentVM.isReadyForConsole` la porte maintenant : `running` **et** un port.
Trois tests, un par bord, et les deux moitiés sabotées séparément — retirer la
condition du port fait rougir le test du port, retirer celle de l'état fait
rougir celui de l'état. Le test bout-à-bout ne pouvait pas les voir : le backend
de démo passe de `starting` à `running` avec le port attaché au même instant, si
bien que l'état intermédiaire qu'un vrai libvirt produit à chaque démarrage n'y
existe pas.

Côté Rust, un test affirme qu'**aucune** sortie de `domstate` ne vaut
`Starting` — sur la gamme de la fonction, pas sur son `match`, donc un bras
ajouté plus tard qui inventerait cet état échouerait ici. Vérifié en l'inventant :
il rougit, et l'ancien test d'énumération ne bronche pas, parce que `idle` n'y
figurait pas.

### Le faux virsh était en course avec lui-même

La vérification complète est passée au rouge sur `Text file busy`, et c'était
mon harnais, pas le produit. Rust joue les tests sur plusieurs fils et
`Command::spawn` forke : un enfant forké pendant que le script était encore
ouvert en écriture hérite du descripteur et le garde jusqu'à son propre `exec`,
et Linux refuse d'exécuter un fichier qu'un processus tient ouvert en écriture.

La fenêtre fait quelques microsecondes et appartient à un autre test — d'où un
passage vert ici, un passage vert en CI, et un rouge au suivant. Le harnais
attend maintenant que le script soit exécutable, et **uniquement pour cette
erreur-là** : toute autre remonte telle quelle, pour que le test qui parle d'un
binaire absent échoue au lieu de tourner en rond. Huit passages consécutifs
verts après correction.

Un rouge intermittent n'est pas une chose qu'on relance : c'est une chose qu'on
lit.

## L'autre moitié de la même erreur : ce que rend un arrêt

La tranche précédente a corrigé le contrat de `start` — le document promettait
un état `starting` que `VirshBackend` ne produit jamais. Elle n'a pas regardé
le verbe d'à côté, et `stop` avait exactement la même fracture, en pire.

`DemoBackend::stop` prenait `_force` : **le paramètre était ignoré**. La seule
distinction que porte le corps de la requête — demander poliment ou couper le
courant — n'existait pas dans le backend que pilote toute la suite bout-à-bout,
et le test d'à côté affirmait `.stopped` pour les deux.

Or `virsh shutdown` envoie l'ACPI et rend la main : le domaine tourne encore,
console ouverte, jusqu'à ce que l'invité en décide — et un invité sans
gestionnaire ACPI ne répond jamais. Trois artefacts s'accordaient entre eux et
aucun avec libvirt.

### Le rouge qui prouve la correction

`AgentEndToEndTests.testStopTearsDownTheConsole` est passé au rouge dès que le
backend de démo a lu `force`. C'est le bon rouge : il épinglait l'ancien
comportement, et son échec montre que le changement traverse HTTP plutôt que de
rester une affaire interne au Rust.

Il est devenu deux tests, un par bord. Le forcé est aussi le seul endroit où
`force` est vérifié **là où il voyage** : les tests Rust appellent le backend
directement et ne peuvent pas montrer que `{"force": true}` survit à la
sérialisation, à l'envoi, à l'analyse et au routage.

Le poli attend en sondant plutôt qu'en dormant : une machine lente allonge le
test au lieu de le faire échouer.

### Ce que ça ne corrige pas

Rien dans l'application n'appelle `AgentClient.stop`. Le démon sait arrêter une
VM, le téléphone ne l'offre pas. Ce n'est pas un défaut mais une capacité non
branchée, et elle est écrite dans la feuille de route avec sa raison : un arrêt
poli peut n'aboutir jamais, donc l'interface qui l'offrira devra le dire au
lieu de tourner en rond. Le contrat est maintenant écrit et tenu pour le jour où
ce bouton existera.

## Le plafond était sur l'entrée, l'allocation est en sortie

`InflateStream.inflate` accumulait sans limite. Les quatre appelants ont tous la
même forme — inflater, puis refuser ce qui n'est pas la taille promise : « zlib
a produit N octets au lieu de M ». Les taux de compression ne se soucient pas de
l'ordre.

Mesuré avant d'écrire quoi que ce soit : **101 929 octets compressés en
produisent 104 857 600**, soit 1 028 pour 1. Et `decodeZlib` admet un bloc
compressé de `pixels × 4 + 1 Mio` : un rectangle **d'un seul pixel** porte donc
une licence pour environ un gigaoctet, alloué dans `inflate`, avant que son
`pixels.count == 4` ne s'exécute. Sur un téléphone, ce n'est pas lent, c'est
mort.

### Ce que l'audit des allocations avait conclu

Il avait regardé ce chemin et l'avait noté « couvert côté pixels », dans la
liste des choses vérifiées saines où ne plus revenir. C'était vrai de la
**vérification** et faux de l'**allocation**, et c'est toute la distinction :
une garde en aval de ce qu'elle garde est un constat, pas une défense.

Le site SPICE portait même le commentaire « Bounded before anything is allocated
from it » — il bornait la taille *déclarée* dans le message, pendant que
l'inflate pouvait en produire cent fois plus avant la comparaison.

### La forme de la correction

`inflate(_:limit:)`, sans valeur par défaut. Chaque appelant connaissait déjà
le nombre ; il le passe en entrée au lieu de le vérifier après. Trois des quatre
plafonds sont exacts — la taille que le message promet — et seul ZRLE a besoin
d'un calcul, parce que rien ne compare sa sortie ensuite.

L'absence de valeur par défaut est la seconde moitié : un appelant qui oublie ne
compile pas, plutôt que d'hériter d'un nombre deviné par quelqu'un d'autre. Le
compilateur a nommé les quatre sites.

### Les deux bords, et ce que le second a révélé

Retirer le refus fait rougir les deux témoins du défaut. Le décaler d'un —
refuser le plafond exact au lieu de l'admettre — fait rougir **huit tests de
décodeurs réels** : Tight, ZRLE, SPICE GLZ, zlib. C'est la meilleure preuve que
l'égalité exacte est le cas courant et non un coin : la moitié « ne pas refuser
ce qu'il ne faut pas refuser » est tenue par des fixtures qui viennent de vrais
serveurs, pas par mes propres exemples.

## Le même défaut, un codec plus loin : une correspondance LZ sans borne

La tranche précédente a plafonné la sortie de zlib. La question qui l'avait
trouvée — « qu'est-ce que ceci alloue, et quand est-ce vérifié ? » — vaut pour
tout ce qui dilate son entrée. Posée aux codecs SPICE, elle en a trouvé un
second.

`SpiceLZ.decompress` boucle sur `while out.count < limit`, ce qui ne regarde
qu'**entre** les itérations. Et une itération n'est pas bornée : la longueur
d'une correspondance se construit par une rallonge qui ajoute 255 pour chaque
`0xFF` que le flux veut bien dépenser, puis la copie s'exécutait jusqu'au bout.
L'égalité finale `out.count == limit` refusait ce qui existait déjà.

Mesuré, sur une image de quatre par quatre qui déclare soixante-quatre octets :
**400 051 octets de charge utile, 645 Mio de pic**, puis un refus. Sur un
téléphone, ce n'est pas un refus, c'est une mort — et c'est un seul message
d'image SPICE.

### Le codec connaissait déjà la réponse

`run`, la boucle deux passes écrite pour les formes `rgba` et `xxxa`, vérifie
`written < count` avant **chaque** élément, de son cycle de littéraux comme de
sa copie. Elle écrit dans un tampon pré-dimensionné ; la boucle simple passe
ajoute à un tableau qui grandit, et ne vérifiait pas. Même fichier, deux
boucles, une seule gardée.

### Trois sabotages, et un qui ne mord pas

- **La copie non bornée** — l'ancien code — fait rougir le témoin mémoire.
- **La garde qui refuse tout** fait rougir six tests de fixtures réelles :
  bitmaps LZ, palettes, GLZ. L'autre bord est tenu par de vrais flux.
- **Les littéraux non bornés** ne font rougir personne, et c'est une **vraie
  équivalence** plutôt qu'un témoin manquant : un cycle de littéraux est borné
  par l'octet de contrôle qui l'introduit — `ctrl < maxCopy`, donc trente-deux
  pixels au plus — et la boucle n'entre que sous la limite. Le dépassement sans
  cette ligne est de cent vingt-huit octets, attrapé par l'égalité du bas. La
  ligne reste pour que les deux boucles du fichier se lisent pareil, et le
  commentaire le dit au lieu de laisser croire qu'elle est la correction.

### Un test qui ne pouvait pas échouer, corrigé avant d'être poussé

La sonde mémoire lit `/proc/self/status`, que macOS n'a pas. Écrite d'abord
avec un repli à zéro, elle comparait zéro à zéro et passait partout — pire que
de ne pas tourner. Elle se déclare sautée maintenant, et le job Linux est son
arbitre.

## Les huit chemins de décompression, et la règle qui sépare les deux formes

Deux défauts de la même forme en deux tranches, tous deux sur des chemins que
l'audit des allocations avait déclarés clos. Une troisième découverte au hasard
n'aurait rien valu : la question se pose à tout ce qui dilate son entrée, et
elle se pose huit fois.

| chemin | forme | verdict |
| --- | --- | --- |
| `InflateStream` (zlib RFB et SPICE) | ajoute à un `Data` qui grandit | **défaut**, corrigé |
| `SpiceLZ.decompress`, simple passe | ajoute à un tableau qui grandit | **défaut**, corrigé |
| `SpiceLZ.run`, deux passes | tampon pré-dimensionné, garde par élément | sain |
| `SpiceGLZDecode` | pré-dimensionné, `op + length <= count` avant écriture | sain |
| `ZRLEDecoder` | pré-dimensionné, `index + run <= count` avant écriture | sain |
| `SpiceLZ4` | pré-dimensionné | sain |
| `SpiceQUIC` | mots bornés par l'entrée, un pour quatre octets ; pixels pré-dimensionnés | sain |
| `TightDecoder` | pré-dimensionnés ; palette bornée par un champ d'un octet | sain |

### La règle

**Un tampon pré-dimensionné avec une garde par élément est sain. Un ajout dans
une collection qui grandit, avec la borne vérifiée hors de la boucle, ne l'est
pas.**

C'est exactement ce qui sépare les deux colonnes, et ce n'est pas une question
de vigilance : la première forme rend le dépassement impossible à écrire — la
garde est sur le chemin de chaque élément — pendant que la seconde le rend
invisible, puisque la condition du `while` a l'air de border la boucle et ne
borde que ses itérations.

Le codec LZ portait les deux formes dans le même fichier, ce qui est la
meilleure démonstration qu'on puisse demander : la boucle écrite en second, pour
les formes `rgba` et `xxxa`, a pris la bonne, et personne n'est revenu corriger
la première.

### Ce que cette clôture vaut, et ce qu'elle ne vaut pas

Les deux défauts sont tenus par des témoins qui mesurent la mémoire. Les six
autres chemins sont vérifiés **par lecture** : j'ai lu chaque garde et chaque
allocation, pas construit un flux hostile pour chacun. C'est plus faible, et il
faut le dire — ce qui manquerait pour les tenir vraiment, ce sont six flux
fabriqués à la main, un par format d'en-tête.

Où ne plus chercher : la question « qu'est-ce que ceci alloue, et quand est-ce
vérifié ? » a été posée aux huit. Ce qui reste ouvert, c'est de la transformer
en huit témoins plutôt qu'en deux.

## Les six témoins qui manquaient, et ce qu'un tampon pré-dimensionné ne protège pas

La clôture précédente finissait sur une dette énoncée : six des huit chemins de
décompression étaient vérifiés **par lecture**, et il fallait les transformer en
témoins. Cette tranche paie la dette, et la mesure qui l'a ouverte mérite d'être
écrite en premier.

**Les six gardes ont été retirées une par une, la suite entière lancée contre
chacune. Les six ont survécu.**

```
glz-match        SURVÉCU
glz-literal      SURVÉCU
zrle-rle         SURVÉCU
zrle-palette     SURVÉCU
lz-run-literal   SURVÉCU
lz-run-copy      SURVÉCU
```

Les quatre diagnostics, appliqués : ce n'est pas la mauvaise ligne — chaque
garde est bien sur le chemin de l'écriture ; ce n'est pas une équivalence réelle
— les longueurs viennent du fil et un serveur les choisit ; ce n'est pas une
branche inatteignable, pour la même raison. **Témoin manquant, six fois.** Les
fixtures de toutes ces suites sont des flux valides, et un flux valide n'atteint
jamais une borne.

### Pourquoi « sain par lecture » ne suffisait pas ici

La règle de la tranche précédente reste vraie : un tampon pré-dimensionné avec
une garde par élément est sain. Mais elle décrit la **forme** du code, pas ce
qui la maintient. La forme est saine tant que la garde est là, et rien ne
disait qu'elle y était.

Il faut aussi nommer précisément ce que ces six-là empêchent, parce que ce n'est
pas la même chose que les deux défauts corrigés avant elles. Là, c'était un tas
épuisé. Ici le tampon est déjà alloué à la bonne taille : le dépassement est une
**écriture hors bornes**, donc un piège Swift. Sur un téléphone, un piège et une
mémoire épuisée sont le même événement — l'application disparaît — et c'est la
différence entre ça et un message refusé.

### Les flux hostiles

Neuf tests, six hostiles et trois de contrôle. Chaque flux est fabriqué à la
main à partir de l'encodage lui-même, et chacun porte **assez d'octets pour que
la boucle n'ait pas à s'arrêter faute d'entrée** : sans cette précaution le
lecteur lèverait `truncated` de lui-même, le test passerait, et il ne
prouverait rien.

Deux pièges rencontrés en les écrivant, tous deux du même genre — un test
attrapé par la mauvaise garde :

* la correspondance GLZ doit être précédée d'**un littéral**, sinon
  `pixelOffset <= op` la refuse d'abord et le témoin est vert sans sa garde ;
* la même chose côté LZ, où `distance <= written` occupe la même place.

Les trois contrôles sont l'autre moitié du travail : une série ZRLE qui tient
dans sa tuile doit peindre, un littéral et une correspondance GLZ qui remplissent
exactement l'image doivent décoder, et la passe alpha de LZ doit rendre le
littéral répété — pas seulement ne pas dépasser. Une garde qui refuserait tout
passerait les six premiers tests et casserait tous les serveurs réels.

### La contre-mesure

Les six sabordages ont été refaits **un par un**, et les neuf tests lancés
séparément contre chacun, pour que la table dise non seulement « quelque chose a
rougi » mais « lequel ». Chaque garde est attrapée par son témoin, et par lui
seul :

| garde retirée | rougit |
| --- | --- |
| `ZRLEDecoder`, série simple | `testAZRLERunPastTheTileIsRefused` |
| `ZRLEDecoder`, série de palette | `testAZRLEPaletteRunPastTheTileIsRefused` |
| `SpiceGLZDecode`, correspondance | `testAGLZMatchPastTheImageIsRefused` |
| `SpiceGLZDecode`, littéraux | `testAGLZLiteralRunPastTheImageIsRefused` |
| `SpiceLZ.run`, littéraux | `testAnLZAlphaLiteralRunPastTheImageIsRefused` |
| `SpiceLZ.run`, copie | `testAnLZAlphaMatchPastTheImageIsRefused` |

Une garde retirée ne fait pas échouer son témoin par une assertion : elle le
fait **planter**. Vérifié plutôt que supposé, sur la garde des littéraux GLZ —
`exited with unexpected signal code 4`, la trappe de Swift, avec sa pile
d'appels. C'est précisément la démonstration de ce qui arriverait sur le
téléphone : pas un message refusé, l'application qui disparaît.

Un piège du sabordage lui-même, noté pour la prochaine fois : les deux gardes de
`SpiceLZ.run` s'écrivent avec la même ligne à deux indentations près, et
chercher la moins indentée en trouve deux — la chaîne est incluse dans l'autre.
Retirée par numéro de ligne.

### Ce que la clôture de l'audit vaut maintenant

Les huit chemins ont un témoin : deux qui mesurent la mémoire pour les deux
défauts corrigés, six flux hostiles pour les gardes qui tenaient déjà. La dette
énoncée à la fin de la tranche précédente est payée.

## La garde des licences n'avait jamais rien refusé

`scripts/check-licence-claims.sh` tient la règle que ce projet énonce le plus
clairement : aucune licence n'a été choisie, donc rien de ce qui est expédié ne
doit en annoncer une. La CI la lance à chaque commit, `verify.sh` avant chaque
poussée — et les deux la lancent contre **ce dépôt-ci**, où il n'y a rien à
trouver. Elle n'avait jamais refusé quoi que ce soit.

**Mesuré.** Le script entier remplacé par `exit 0`, la suite complète lancée
contre lui : verte. Swift, Rust, les 114 tests du site. Rien nulle part ne le
tenait.

C'est la même forme que la sonde qui ne peut pas échouer, avec un tour de plus :
ici l'instrument s'exécute vraiment, à chaque commit, et affiche même une phrase
rassurante. Ce qui ne se produit jamais, c'est le refus — le seul comportement
qui compte.

### Ce qu'il fallait pour le tenir

Le script travaillait en dur sur la racine du dépôt, donc il n'y avait aucun
moyen de lui montrer un arbre fautif. Il prend maintenant une racine en
argument : sans argument il vérifie ce dépôt, ce que font la CI et `verify.sh` ;
avec, il vérifie l'arbre qu'on lui donne, ce que fait
`site/tests/licence-guard.test.ts`.

Seize tests, et **la moitié sont des contre-cas**. C'est la partie difficile :
nommer Apache-2.0 dans le README, dans NOTICE et dans la feuille de route est
**correct** — c'est un fait sur UTM, FreeRDP et QEMU, les projets d'autrui, qui
le sont vraiment. Une garde qui refuserait ça serait fausse d'une manière
invisible depuis un build vert. L'arbre sain des tests porte donc toutes les
chaînes recherchées, en prose, et doit passer.

| bloc saboté | ce qui rougit |
| --- | --- |
| liste `declared` vidée | les 4 fichiers déclarants |
| motif `claims` neutralisé | les 4 fichiers déclarants |
| boucle `LICENSE` retirée | les 4 noms de fichier de licence |
| boucle Cargo retirée | les 2 manifestes Rust |
| boucle npm retirée | les 2 manifestes npm |
| `exit 1` devenu `exit 0` | les 12 cas de refus |
| `README.md` ajouté à `declared` | les 4 contre-cas |
| motif npm relâché en `"license` | la dépendance `license-checker` |
| motif Cargo relâché sans `^\s*` | le champ mis en commentaire |

Les trois derniers sont le bord inverse, saboté exprès dans l'autre sens : une
garde trop zélée est un défaut aussi, et sans ces lignes rien ne l'aurait dit.

### Le trou que la mesure a montré au passage

Le script couvrait le champ `license` de **Cargo**, parce que Cargo le publie
sur crates.io. npm a exactement le même champ, lu par exactement le même genre
d'outillage, et ce dépôt porte deux `package.json` — celui de la racine, qui
existe pour qu'Heroku choisisse son buildpack Node, et celui du site. **Ni l'un
ni l'autre n'était vérifié.** C'est aussi le champ le plus susceptible
d'apparaître sans que personne ne décide rien : `npm init` en écrit un, et la
plupart des générateurs aussi.

Les deux sont couverts maintenant, par une boucle qui marche comme celle de
Cargo — donc un `package.json` ajouté plus tard l'est aussi, sans que personne
ait à s'en souvenir.

## La deuxième garde du dépôt, et une branche que `set -e` rendait inatteignable

Même question posée au deuxième des trois scripts de garde :
`scripts/check-release-matrix.sh`, qui tient l'installateur et le workflow de
publication d'accord. Il existe parce que les deux ont divergé une fois — le
workflow construisait `linux-x86_64` et `macos-arm64`, l'installateur demandait
exactement ceux-là, et toute autre machine tombait en silence dans la
construction depuis les sources. Personne ne voit cet échec sauf la personne
qui installe.

### La mesure, et une nuance sur ce qui compte comme rouge

Trois cassures de la logique du script le laissent **vert sur cet arbre** :

| cassure | sortie |
| --- | --- |
| `expect_asset` ne compare plus | 0 |
| les deux `comm` neutralisés | 0 |
| `exit "$failed"` devenu `exit 0` | 0 |

Une quatrième, `comm -13` échangé contre `comm -12`, sort bien en 1 — **mais
pour la mauvaise raison** : elle signale les quatre assets *qui correspondent*
comme manquants. Un rouge qui veut dire autre chose n'est pas une détection, et
c'est le genre de faux positif qu'on compte à tort comme preuve que la garde
marche.

### La branche que personne ne pouvait atteindre

Le script porte deux refus explicites — « ne déclare plus aucun asset », « ne
demande plus aucun asset » — pour le cas où un fichier est réécrit et où le
motif ne trouve plus rien. Deux listes vides se comparent égales, donc sans ces
branches la garde annoncerait une matrice cohérente après n'avoir rien lu.

Elles sont **inatteignables**. `built=$(grep … | awk … | sort -u)` sous
`set -euo pipefail` : un `grep` sans correspondance est un échec, l'affectation
échoue, et le script meurt là — silencieusement, avec la sortie 1. Le refus a
lieu, mais sans un mot ; il faut lancer `bash -x` pour savoir pourquoi.

Trouvé en écrivant le test, pas en lisant le fichier : les deux tests
échouaient sur une sortie **vide**. Corrigé par un `|| true` sur chaque
pipeline, et les deux branches sont maintenant atteintes et tenues.

### Le témoin qui prouvait la mauvaise chose

Le premier essai du cas « un nom réel envoyé à la mauvaise machine » changeait
`Darwin/arm64` de `macos-arm64` vers `macos-x86_64`. Il rougissait — mais par
la comparaison d'ensembles, puisque `macos-arm64` devenait construit et jamais
demandé. Avec la vérification de correspondance retirée, il passait quand même.

La version qui tient **échange** les deux mappings. Les deux listes restent
identiques, la comparaison d'ensembles ne dit rien — et le test l'affirme, avec
un `not.toContain` sur ses deux messages. C'est le silence de l'autre moitié
qui fait de ce test le témoin de la sienne.

### Et la troisième fois pour `verify.sh`

Ce script dit en tête qu'il lance « tout ce que la CI lancerait ». Deux
commentaires à l'intérieur racontent déjà la même correction : une fois pour
SwiftLint, une fois pour les portes Rust. **La matrice des architectures était
la troisième** — lancée par la CI, absente d'ici. Elle coûte deux secondes.

### Ce qui reste

`scripts/check-whitespace.sh`, le troisième, n'est pas tenu non plus. Il l'est
moins gravement et il faut le dire : la CI ne le lance pas — elle lance
`swiftlint --strict`, qui couvre les mêmes règles — donc une version cassée ne
laisse pas passer un défaut, elle rend une PR rouge dix minutes plus tard. Or
c'est exactement l'aller-retour que ce script existe pour éviter. Un tour, pas
un défaut.

## Le troisième script de garde, et le répertoire qu'il ne regardait pas

`scripts/check-whitespace.sh`, le dernier des trois, avait le même trou que les
deux autres : `verify.sh` le lance avant chaque poussée, toujours contre un
arbre où rien ne cloche, donc aucune de ses cinq règles n'avait jamais rien
signalé.

Il est le moins grave des trois et il faut le dire : la CI ne le lance pas —
elle lance `swiftlint --strict`, qui couvre les mêmes règles — donc une version
cassée ne laisse pas passer un défaut, elle rend une PR rouge dix minutes plus
tard. C'est exactement l'aller-retour que ce script existe pour éviter, sur une
machine Linux où la formule Homebrew de SwiftLint n'existe pas. **Un tour
perdu, pas un défaut.**

### Ce que la mesure a trouvé, et qui n'est pas anodin

La portée était trois pathspecs — `Sources/**/*.swift`, `Tests/**/*.swift`,
`App/**/*.swift` — et **le troisième ne matchait rien du tout**. `**/` exige au
moins un niveau de répertoire, et `App/` contient exactement un fichier Swift,
à sa racine.

```
motif du script : 235 fichiers
tous les .swift : 236 fichiers
manquant        : App/WisqApp.swift
```

Le point d'entrée de l'application. `.swiftlint.yml` liste `App`, donc la CI le
vérifie à chaque commit ; le plancher local ne l'avait jamais ouvert. Invisible
parce que ce fichier-là est propre.

Corrigé en nommant les répertoires et en filtrant sur l'extension, ce qui n'a
pas ce bord. Le reste du dépôt a été relu pour d'autres `**/` de la même forme :
il n'y en a pas.

### La contre-mesure

Quatorze tests, neuf sabordages séparés :

| bloc saboté | ce qui rougit |
| --- | --- |
| règle « saut final absent » | son cas, et le compte |
| règle « sauts finaux multiples » | son cas |
| règle « espaces en fin » | son cas, App, profondeur, compte |
| règle « accolade seule » | son cas |
| règle « lignes vides » | son cas, et le compte |
| **portée d'avant (`App/**`)** | **le cas App, et le compte** |
| `exit 1` devenu `exit 0` | les 8 refus |
| accolade relâchée en « contient `{` » | les 4 contre-cas |
| portée élargie à tous les fichiers | `Package.swift`, le `.md`, le dépôt réel |

La sixième ligne est la preuve que le trou était réel : remettre l'ancien
pathspec fait rougir exactement le cas `App/`.

Les deux dernières sont le bord inverse. Les contre-cas qui comptent le plus
sont ceux-là : `Package.swift` est **hors** de `included`, donc le signaler
serait une violation que la CI n'a pas — le faux positif qui rend un plancher
local inutilisable — et une accolade en fin de ligne, c'est-à-dire toutes les
accolades du dépôt, ne doit rien déclencher.

### Les trois gardes du dépôt, closes

| script | lancé par | tenu par |
| --- | --- | --- |
| `check-licence-claims.sh` | CI + `verify.sh` | `site/tests/licence-guard.test.ts` |
| `check-release-matrix.sh` | CI + `verify.sh` | `site/tests/release-matrix.test.ts` |
| `check-whitespace.sh` | `verify.sh` | `site/tests/whitespace-guard.test.ts` |

Chacune prend une racine en argument, chacune est mise devant des arbres
fautifs, et chacune a ses contre-cas. Deux des trois portaient un vrai trou de
couverture — le champ `license` de npm, et `App/` — et aucun des deux ne se
voyait, parce qu'un arbre propre ne fait rien dire à une garde.

## Sept endroits énoncent la version ; un seul était tenu

`0.3.0` est écrit dans le CHANGELOG, dans les deux manifestes Cargo, dans le
`MARKETING_VERSION` du projet Xcode, deux fois dans le site, et dans le tag de
la formule Homebrew. Un seul de ces liens existait : `build.test.ts` compare le
pied de page du site à la version datée la plus récente du CHANGELOG.

**Mesuré.** Cinq d'entre eux mis à cinq valeurs **distinctes et fausses** en une
passe — `SITE_VERSION` laissé intact — et la suite entière lancée contre ça :
verte. Swift, Rust, et les 154 tests du site.

### Un des cinq était déjà à la dérive en fait, pas seulement en principe

L'histoire du tag de la formule, lue dans le journal git :

| commit | ce qu'il a fait |
| --- | --- |
| `release: 0.2.0` | a monté le tag de `v0.1.1` à `v0.2.0` |
| « Rust where the work is not Apple-shaped » (même jour) | a réécrit la formule avec `tag: "v0.3.0"` — **une version qui n'existait pas encore** |
| `release: 0.3.0` (lendemain) | CHANGELOG, `Cargo.lock`, les deux manifestes, `project.yml`, cinq fichiers du site — **pas la formule** |

Elle est d'accord aujourd'hui **par coïncidence** : elle a été écrite avec une
release d'avance et la release l'a rattrapée. Le commit de publication ne la
touche plus, et rien ne fera que la prochaine s'en souvienne :
`brew install maxlestage/wisq/wisq-agent` installerait le démon précédent
pendant que le site annonce le nouveau.

Et la règle qui aurait dû l'empêcher existait — dans un commentaire du fichier :
« bump the tag here when cutting one ». C'est la forme qu'on connaît, une règle
qui vit dans une phrase plutôt que dans une garde.

### La sonde qui ne pouvait pas distinguer, évitée exprès

Chaque lecteur **lève** quand son motif ne correspond à rien, et il y a un test
qui vérifie que les six trouvent quelque chose. Ce n'est pas de la cérémonie, et
c'est mesuré : en remplaçant les deux levées par un `undefined` et en cassant
deux motifs, l'assertion « le manifeste du cœur VM est d'accord » **passe** —
`expect(undefined).toBe(undefined)`. Huit tests restent verts.

C'est exactement le trou de `App/**` de la tranche précédente, sous un autre
angle : un lecteur qui ne lit rien ne se distingue pas d'un lecteur qui lit la
bonne chose, tant que les deux côtés de la comparaison sont vides.

### La contre-mesure

Seize tests, sept sabordages séparés — un par endroit, plus le CHANGELOG
lui-même :

| version faussée | ce qui rougit |
| --- | --- |
| `crates/wisq-vm/Cargo.toml` | le manifeste du cœur VM |
| `crates/wisq-agent/Cargo.toml` | le manifeste du démon |
| `project.yml` | `MARKETING_VERSION` |
| `site/src/content.ts` | `SITE_VERSION` |
| `site/src/pages/releases.ts` | la page des versions **et** sa liste complète |
| `Formula/wisq-agent.rb` | le tag Homebrew |
| `CHANGELOG.md` | les sept, puisque c'est la référence |

Le bord inverse est `[Unreleased]` : cette section n'a pas de date et ne doit
pas être lue comme une version, sinon chaque commit après une publication
ressemblerait à une nouvelle et réclamerait que les sept fichiers soient montés.

## Une tranche annulée : j'ai lu le code et pas les tests

Constat, à quatre heures du matin : la formule Homebrew existe, `install.sh`
existe, la release attache quatre binaires à chaque étiquette — et `brew`,
`install`, `curl` n'apparaissent nulle part dans `site/src`. Le guide consacre
une section entière à l'agent, « lancez-le avec `--service` », sans jamais dire
comment obtenir le binaire que ces paragraphes supposent acquis.

J'ai conclu à un oubli et rédigé la section d'installation dans les deux
langues. **C'est un test qui m'a arrêté, pas ma relecture** :
`render.test.tsx`, « no page hands out a way to install the project », interdit
exactement ces commandes, sur les pages rendues des deux langues, avec son
raisonnement écrit à côté — y compris un affinage antérieur sur l'endroit exact
où passe la ligne.

Le site ne distribue pas wisq. C'est une décision, elle est tenue, et je ne
l'avais pas vue. Tout est annulé.

### La règle que ça donne

**J'ai cherché ce que le code disait et pas ce que les tests disaient.** C'est
la même erreur que celle que je traque depuis hier soir, retournée : je vérifie
partout « qu'est-ce qui tient cette affirmation ? », et je n'ai pas pensé à
demander « qu'est-ce qui tient cette *absence* ? ». Une absence délibérée
ressemble exactement à un oubli — la seule chose qui les sépare est le test qui
l'impose, et il ne se trouve pas en cherchant dans `Sources` ou dans `src`.

Avant de combler un trou : chercher le trou dans les tests, pas seulement dans
le code.

### Ce qui restait de vrai, et qui est corrigé

Un commentaire de `build.test.ts` disait : « le téléchargement de la release
survit exprès — c'est ainsi qu'un lecteur installe la chose ». Ce n'était plus
vrai : le test voisin interdit `releases/latest` et `.ipa`, et aucun lien de
téléchargement n'est sur le site. Deux fichiers énonçaient des intentions
incompatibles, et c'est le faux des deux que j'ai lu et suivi. Corrigé, avec la
mesure écrite dedans.

Et la décision elle-même ne vivait que dans le commentaire d'un test. Elle est
maintenant dans `docs/ROADMAP.md`, avec ce que le site montre quand même — la
section d'appairage, parce qu'un lecteur qui décide si wisq est pour lui a
besoin de savoir qu'un agent imprime un lien et que le téléphone le scanne, et
que rien de tout ça ne lui remet un binaire.

Aucun code de production n'a changé.

## Un rouge qui ne voulait rien dire, et le correctif que je n'ai pas fait

Au redémarrage du conteneur, quatre tests du site ont dépassé le délai par
défaut de bun. Celui qui compte les tests du dépôt a mis **6 330 ms** pour une
assertion qui en prend seize.

Première hypothèse : l'échauffement du JIT. **Fausse**, et la mesure le dit :

```
premier passage, cache froid : 5 798 ms   (146 fichiers, ~40 ms chacun)
passages suivants            :    16 ms
même script relancé          :    16 ms   ← les pages sont en cache
```

C'est le cache de pages. La première lecture du dépôt dans un conteneur neuf
coûte quarante millisecondes par fichier sur un stockage qui n'est pas local.
La CI ne le voit jamais : le checkout écrit les fichiers, donc ils sont chauds
quand la suite les lit.

### Ce qui est corrigé

`testCount()` était appelé **trois fois**, trois parcours complets. Il est
mémorisé : trois parcours froids deviennent un. Vérifié par sabordage — un
chiffre annoncé faux rougit, **un test Swift ajouté à l'arbre rougit aussi**
(donc la marche lit toujours l'arbre et le mémo ne fige rien), et l'arbre
intact reste vert.

### Ce que je n'ai pas fait, et c'est le point

Le correctif évident est de monter le délai à trente secondes. **Non.** Un
délai de trente secondes sur une assertion de seize millisecondes met fin au
rouge parasite et met fin, du même coup, à toute chance de remarquer un
ralentissement d'un facteur dix. C'est exactement l'aveuglement contre lequel
tout le reste de cette nuit a été écrit : une sonde qui ne peut plus
distinguer.

Un rouge rare, à cause connue et écrite ici, vaut mieux qu'une garde émoussée.
La prochaine fois qu'un test du site expire au premier lancement d'un
conteneur, la réponse est dans ce paragraphe et non dans vingt minutes de
diagnostic.

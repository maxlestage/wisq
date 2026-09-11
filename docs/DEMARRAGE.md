# Ce qui manque pour qu'un noyau démarre

Ce document existe parce qu'un chiffre a cessé d'être une réponse. Cinq tranches
de travail ont porté la couverture du traducteur de **9949 à 9980 régions
d'entrée sur 10 116**, et les refus nommés de **40 à 9**. C'est réel, c'est
mesuré, et ça ne rapproche pas d'un noyau qui démarre.

Ce qui manque n'est plus une liste d'instructions à produire. Ce sont **deux
mécanismes entiers** : la pagination et les interruptions. Ce document dit
lesquels, ce qu'ils coûteraient, et — surtout — ce qui est mesuré ici par
opposition à ce qui est encore une supposition.

## D'abord : ce que le chiffre veut dire, et ce qu'il ne veut pas dire

**Il compte des régions qui se *traduisent*.** Depuis la tranche des registres
spécifiques au modèle, ce n'est plus la même chose que des régions qui
*s'exécutent* : un `wrmsr` dont le numéro n'est pas modélisé traduit très bien,
et s'arrête à l'exécution en nommant son adresse. Le relevé n'a jamais prétendu
autre chose, mais il est facile de le relire de travers six mois plus tard.

**Et une région d'entrée n'est pas un chemin d'exécution.** Le relevé part des
cibles de `call` trouvées dans l'image : il mesure ce que le traducteur *saurait*
produire si on le lui demandait, pas ce qu'un démarrage traverse réellement.

## La pagination

### Ce que la machine fait aujourd'hui d'une adresse

Deux instructions WebAssembly, dans `crates/wisq-vm/src/x86_wasm.rs`, fonction
`guest` :

```
i32.wrap_i64        // les soixante-quatre bits de l'invité, ramenés à trente-deux
i32.and  <masque>   // repliés dans une RAM en puissance de deux
```

**C'est un repli, pas une correspondance.** Toute adresse invitée atterrit
quelque part dans la RAM, sans table, sans faute, sans permission. Deux adresses
distantes d'exactement la taille de la RAM désignent le même octet.

### Pourquoi ça suffit aujourd'hui, et pourquoi ça ne suffira pas

Le noyau est chargé à une adresse **physique** (`0x1000090` pour l'image de
référence) et son point d'entrée 64 bits y tourne. Depuis la tranche des MSR, ce
point d'entrée se traduit **en entier** — il butait sur son `wrmsr` à l'octet 35
depuis le début de ce travail.

Mais un noyau Linux x86-64 n'est pas bâti pour tourner là. Il est bâti pour
tourner **en haut**, autour de `0xffffffff80000000`, et il y saute dès qu'il a
posé ses tables de pages.

**Ce n'est pas une supposition, c'est une mesure.** Dans les 35 842 660 octets de
l'image de référence, en ne regardant que les mots de huit octets alignés :

| ce que le mot vaut | occurrences |
| --- | ---: |
| une adresse noyau haute, `0xffffffff8…` | **122 994** |
| une adresse physique du même ordre de grandeur | 11 933 |

Dix fois plus de pointeurs hauts que bas. Le noyau s'attend à vivre en haut, et
**un repli ne l'y emmènera jamais** : il ne fait pas correspondre, il alias.

### Le mur a un nom, et ce sont deux instructions

Écrire CR3 pose la racine des tables de pages ; écrire CR0 allume la pagination.
Ce sont exactement les deux instructions que la dernière tranche a **refusées**,
et le refus est honnête : les accepter ferait croire au noyau qu'il pagine, et la
panne tomberait bien plus loin que sa cause.

**Le refus honnête et le mur sont la même chose.** Il n'y a pas de demi-mesure
ici : soit on marche les tables, soit on ment.

### Ce que ça coûterait, et ce qui n'est pas mesuré

Une correspondance à quatre niveaux, c'est **quatre lectures mémoire dépendantes**
par accès invité, là où il y en a zéro aujourd'hui. Personne ne fait ça sans
cache : la voie normale est un tampon de traduction — une table de hachage
adresse virtuelle → adresse physique, consultée en quelques instructions, et
rechargée par la marche complète en cas d'absence.

**Ce qui est mesuré** : l'émetteur tient 247 MIPS sous JavaScriptCore, contre
49,3 pour l'interpréteur Rust et 831 pour du WebAssembly écrit à la main.

**Ce que la traduction coûterait, mesuré.** La sonde est dans le dépôt et se
relance :

```
cargo run -p wisq-vm --release --example paging-probe -- /tmp/paging.wasm
bun scripts/wasm-paging-probe.js /tmp/paging.wasm
```

Un seul module exporte les trois formes — le repli d'aujourd'hui, un tampon de
soixante-quatre entrées avec marche en repli, la marche seule — pour que
JavaScriptCore les compile de la même façon et qu'on ne chronomètre que la
différence. **Les trois rendent la même somme de contrôle**, sans quoi une forme
qui ne ferait rien afficherait un débit magnifique et faux.

| motif d'accès | repli | tampon + marche | marche seule | surcoût du tampon |
| --- | --- | --- | --- | --- |
| balayage court, 512 pages | 2,46 ns | 2,69 ns (×1,09) | 5,25 ns | **+0,23 ns** |
| balayage long, 16 384 pages | 5,95 ns | 6,41 ns (×1,08) | 8,30 ns | **+0,47 ns** |
| une page neuve à chaque accès | 16,58 ns | 43,02 ns (×2,59) | 42,53 ns | **+26,43 ns** |

Trois exécutions à 6, 8 et 20 millions d'accès s'accordent à un dixième de
nanoseconde près sur les deux premières lignes, et à ±1 ns sur la troisième.

**Ce que ça dit.** Tant que le tampon répond, la traduction est presque
gratuite — un dixième à un demi de nanoseconde par accès, contre un repli qui en
coûte déjà deux et demi à six. **Quand il ne répond jamais, elle coûte plus que
tout le reste** : la troisième ligne est construite pour ça, une page neuve à
chaque accès, et aucun tampon ne peut y servir à quelque chose. Ce n'est pas une
prévision, c'est un plancher : le pire jour possible.

**Ce qui manque encore pour en faire un pourcentage de débit.** Il faudrait
savoir quelle fraction des instructions d'un vrai noyau porte un opérande
mémoire — et ce nombre-là n'est mesurable par rien dans ce dépôt aujourd'hui.
Une version antérieure de la feuille de route en tirait « entre 1 % et 29 % du
débit » ; le chiffre est retiré jusqu'à ce que ses deux entrées soient
vérifiables.

### `invlpg` : ce qui fait oublier une page au tampon

Un tampon n'est juste que si quelqu'un peut le vider. Le noyau change une
entrée de table puis exécute `invlpg` sur la page ; le tampon direct du module
efface alors la case que la page occupe — son étiquette à zéro veut dire
« vide » — et l'accès suivant remarche les tables. L'opérande est une adresse
linéaire, calculée comme pour `lea`, ni traduite ni lue : un `invlpg` sur une
page absente ne faute pas. **Vérifié plutôt qu'affirmé** : le montage du
tampon, qui relisait l'ancienne trame après avoir réécrit sa feuille, relit la
nouvelle avec un `invlpg` entre les deux, et toujours l'ancienne sans. Le
noyau Alpine y arrive dans `native_flush_tlb_one_user`, et `0f 01 3f` refusait
sa région avant cette tranche.

### Comment une faute de page remonte, tranché par la sonde

C'était la question à trancher avant d'écrire une ligne de la tranche P2 : un
piège WebAssembly est **sans retour** — il arrête l'émulateur entier —, alors
qu'une faute doit rendre la main au noyau invité.

**Il n'y a pas besoin de piéger, et le chemin existait déjà.** La boucle de
répartition de l'émetteur tient l'indice du bloc courant dans une locale, et
**un bloc qui rend un indice négatif rend la main à l'hôte** — c'est ce que fait
déjà chaque fin de région, et `tests/host_loop.rs` l'emprunte à chaque exécution.
Une faute n'a donc qu'à faire rendre −1.

La vraie question était **où poser le contrôle**, et elle a deux réponses de
coûts opposés :

- **en ligne**, juste après la traduction et **avant** l'accès — juste, puisque
  l'instruction fautive n'a alors rien fait, mais une branche par accès, et RIP
  doit être à jour à chaque accès plutôt qu'à la fin d'un bloc ;
- **par page piège**, la traduction rendant une adresse au-dessus de la RAM
  déclarée et le bloc ne contrôlant qu'à sa terminaison — une branche par bloc,
  mais l'instruction fautive a partiellement agi, ce qui est faux.

La sonde répond, deux formes de plus dans le même module (`garde`,
`garde_rip`), branche jamais prise, sommes de contrôle égales aux trois autres.
Trois exécutions à 8 et 12 millions d'accès :

| motif d'accès | surcoût du contrôle | surcoût de RIP à chaque accès |
| --- | --- | --- |
| balayage court, 512 pages | −0,17 à +0,07 ns | +0,00 à +0,03 ns |
| balayage long, 16 384 pages | +0,02 à +0,30 ns | +0,02 à +0,09 ns |
| une page neuve à chaque accès | +0,75 à +1,61 ns | −0,45 à +0,62 ns |

**Le contrôle en ligne est sous le bruit** sur les deux motifs de balayage — la
plage inclut zéro, et une des mesures est négative, ce qui dit qu'on mesure
l'ordonnanceur et non le code. Sur le motif qui casse le tampon il coûte au plus
une nanoseconde, là où la marche elle-même en coûte trente. Tenir RIP à jour à
chaque accès n'est pas séparable du bruit.

**Donc : le contrôle en ligne.** La page piège aurait acheté un mécanisme faux
pour une économie qu'aucune des trois mesures ne voit.

## Les interruptions

### Ce qui existe

| | état |
| --- | --- |
| `lidt` / `sidt` — la table est rangée et rendue, **et l'IDT est lue** | **produit** |
| `cli` / `sti` — le drapeau d'interruption | **produits** |
| `hlt` — attendre une interruption | **produit** : un arrêt nommé, tant que rien ne réveille |
| `popf` — qui peut rallumer le drapeau sans nommer `sti` | **produit** |
| `iretq` — le retour d'interruption, cinq mots | **produit** ; `iretd` décodé et refusé en étant nommé |
| `int`, `int3` — l'entrée logicielle | **produits** : le témoin porte le vecteur, RIP est déjà après, et l'hôte délivre — sans code d'erreur |
| `lkgs` — la base GS du noyau depuis un sélecteur | **décodée**, arrêt nommé si elle est atteinte, RIP dessus ; le noyau ne l'exécute que si CPUID annonce `LKGS`, et `cpuid` ne l'annonce pas |
| la délivrance d'une **faute de page** | **existe**, dans `web/host.js` : porte, cadre, IF, témoin effacé |
| la délivrance d'une **interruption de matériel** | n'existe pas |

**Vérifié plutôt qu'affirmé** : `cc` se décode en vecteur trois, `cd 80` en
vecteur `0x80`, et un `cd` coupé de son octet rend `None` plutôt qu'un vecteur
inventé. `cf` et `48 cf` se décodent depuis la tranche de la délivrance. Ce qui
a fait entrer l'entrée logicielle : la retpoline `call +1 ; int3 ; …` de
`__x86_indirect_thunk_rax`, dont l'`int3` n'est jamais exécuté mais refusait
la région entière. `f2 0f 00 f7` se décode en `lkgs %edi`, et seule cette
forme lit le préfixe `f2` : `f2 0f 10` (`movsd`) reste refusé plutôt qu'avalé
en `movups`. Ce qui l'a fait entrer : `native_lkgs`, à portée statique de
`init_scattered_cpuid_features`, que le noyau n'appelle jamais sur ce
processeur mais qui refusait sa région.

**`lidt` produit voulait dire « le registre se relit », et c'est devenu plus.**
La base et la limite qu'il range sont **lues** par l'hôte quand une région
pose le témoin de faute : la porte du vecteur 14 y est cherchée, présence et
limite comprises, et c'est la première fois qu'un chemin consulte cette table.
La GDT, elle, n'est toujours lue par rien.

### Ce que ça demande

Trois choses, et aucune n'est petite :

1. **Une source de temps qui interrompt.** Le noyau calibre, planifie et se
   réveille sur un timer. La machine n'en a aucun. Le compteur d'horodatage,
   lui, **a cessé de mentir sur la durée** : `web/host.js` ajoute le budget
   qu'il vient d'accorder à chaque tour de sa boucle, donc un intervalle se
   mesure. Ce qui manque encore est la ligne qui **interrompt**, pas l'horloge
   qui avance.
2. **Un point de délivrance.** Il **existe** pour la faute de page : `deliver`
   dans `web/host.js`, appelé par la boucle quand une région pose le témoin —
   il lit la porte, pose le cadre du mode long sur la pile de l'invité, éteint
   IF pour une porte d'interruption, et saute. Une interruption de matériel
   passerait par le même chemin, avec un vecteur qui vient d'un contrôleur
   plutôt que du témoin ; ce qui manque est la ligne, pas le point.
3. **`iretq`, et la pile de retour.** **Produit.** Il dépile RIP, CS, RFLAGS,
   RSP et SS dans cet ordre, laisse le code d'erreur au gestionnaire, et pose
   RIP sur lui-même avant sa première lecture pour qu'une faute sur le cadre
   reprenne là. Sept sabotages l'ont éprouvé, dont « le sélecteur pris pour
   RIP » et « RSP laissé où il est ».

### Et une raison de ne pas commencer par là

Sans pagination, le noyau ne parvient pas à l'endroit où il installe ses
gestionnaires. **Les interruptions sont le deuxième mur, pas le premier**, et les
implémenter d'abord donnerait un mécanisme que rien n'exercerait — le défaut de
conception que ce dépôt s'est déjà interdit ailleurs : un bouchon complaisant
cache un défaut réel.

## Ce que je ne recommande pas

**Fauter vers l'hôte pour chaque accès mémoire.** Mesuré : un retour de main
coûte 125 à 190 ns. À ce prix, un accès par instruction ramènerait la machine
sous le million d'instructions par seconde — deux ordres de grandeur sous
l'interpréteur Rust qu'on a remplacé pour cette raison même.

**Modifier le noyau pour qu'il tourne sans pagination.** Ce serait faire
démarrer *un* noyau, pas *les* noyaux, et wisq n'a d'intérêt que si l'image que
l'utilisateur apporte est la sienne.

## L'ordre que je propose

1. **La sonde de coût**, avant toute décision : le repli contre le tampon de
   traduction, sous JavaScriptCore, sur la même boucle.
2. **La marche des tables et son tampon**, si le chiffre le permet — et si le
   chiffre ne le permet pas, ce document doit dire pourquoi plutôt que le
   contourner.
3. **Écrire CR3 et CR0**, qui cessent alors d'être des mensonges.
4. **Le timer, la délivrance et `iret`** — le deuxième mur, une fois le premier
   franchi.

Chaque étape par sa propre tranche, chacune avec sa sonde avant son code, et
chacune sabotée avant d'être crue.

### Où poser la délivrance : mesuré

**Le premier mur est franchi**, donc la raison de ne pas commencer par les
interruptions — « sans pagination, le noyau ne parvient pas à l'endroit où il
installe ses gestionnaires » — ne tient plus. La question redevient : *où* la
machine regarde-t-elle si une interruption attend ?

Deux endroits, et **ils ne se paient pas dans la même monnaie**. Dans le module,
un contrôle entre blocs coûte du temps à chaque bloc, qu'une interruption
attende ou non. Dans la boucle hôte, le coût dans le module est nul ; ce qu'on
paie est le retour de main, et ce qu'on **achète** est la latence.

`cargo run -p wisq-vm --release --example deliver-probe` mesure la seconde. Le
même travail — trente-deux millions d'instructions — découpé en budgets de plus
en plus petits. **Le budget compte des blocs**, pas des instructions : la boucle
de répartition décrémente une fois par `call_indirect`. Vérifié plutôt que
supposé — à budget mille, huit millions de tours rendent la main huit mille fois.

| budget, en blocs | retours de main | surcoût par instruction |
| --- | --- | --- |
| 1 | 8 000 000 | +16 à +80 ns, **instable** |
| 10 | 800 000 | +2,0 à +8,6 ns, **instable** |
| 100 | 80 000 | +0,98 à +1,53 ns |
| 1 000 | 8 000 | +0,10 à +0,29 ns |
| 10 000 et au-delà | 800 ou moins | sous le bruit, l'écart change de signe |

**Les deux plus petits budgets ne mesurent pas ce qu'on croit.** Trois
exécutions ont rendu +80, +65 puis +16 ns pour le même budget de 1 : à ce rythme
d'appels, c'est le moteur qui recompile et ramasse qu'on chronomètre. Le reste
de la courbe, lui, tient.

**Ce que l'autre moitié coûterait**, et c'est une **déduction de deux mesures**,
pas une mesure : le contrôle en ligne a été chiffré plus haut à −0,17 à +0,30 ns
par occurrence, et `--example coverage` relève 4,5 instructions par bloc sur le
noyau Alpine. Un contrôle par bloc vaudrait donc 0 à 0,07 ns par instruction,
toujours payé, pour une latence d'un bloc.

**Donc : la boucle hôte, avec un plancher de budget.** À mille blocs elle ne
coûte rien de mesurable, et la latence qu'elle laisse — mille blocs, environ
quatre mille cinq cents instructions, une vingtaine de microsecondes à
250 MIPS — est cinq cents fois plus fine que ce qu'un timer à cent hertz
demande. Le contrôle dans le module achèterait une précision d'un bloc dont rien
n'a besoin, au prix d'un coût payé partout.

C'était l'intuition écrite plus haut — « la boucle hôte rend déjà la main
régulièrement, c'est le crochet naturel ». Elle est maintenant chiffrée, et le
chiffre dit *à partir de quel budget* elle est vraie, ce que l'intuition ne
disait pas.

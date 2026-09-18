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

**Depuis l'arrêt nommé généralisé, ce chiffre est saturé et ne mesure plus
rien.** Un octet illisible n'arrête plus que son bloc : la région se traduit,
et le refus attend que l'exécution arrive sur l'octet. Les 10 116 régions
d'entrée se traduisent donc toutes — 10 116 sur 10 116, zéro refus — et un
compteur qui ne peut plus baisser ne dit plus si le décodeur progresse. Ce qui
le dit est la colonne d'après dans le même relevé : **les octets illisibles que
les régions compilées portent**, nommés un par un. C'est là qu'il faut regarder
pour savoir ce qui manque encore.

**Ce chiffre baisse à chaque tranche de décodage, donc il porte sa date et sa
commande** plutôt que d'être recopié ici comme un fait. Au 14 septembre 2026,
sur l'image de référence :

```
cargo run -p wisq-vm --release --example coverage -- <noyau>
→ régions compilées portant un octet illisible : 17 sur 10116 (31 octets)
  c4×13  0f-02×5  f3-48×3  48×2  8f×2  0f-00×1  0f-09×1  0f-ae×1  c5×1
  f3-0f×1  ff×1
```

Une version antérieure de ce paragraphe annonçait « 34, dans 19 régions » : le
relevé de la tranche qui l'avait écrit, laissé derrière par sept tranches de
décodage. `docs/ROADMAP.md` avait le bon depuis #225 et personne ne les avait
comparés. **Le texte qui dit où regarder est le pire endroit où laisser vieillir
un nombre.**

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

**Ce n'est pas une supposition, c'est une mesure — et elle se refait :**

```
cargo run -p wisq-vm --release --example pointer-census -- <noyau>
```

Au 14 septembre 2026, sur l'image de référence :

```text
35842660 octets, 4480332 mots alignés de huit (4 octets de queue, hors du compte)
adresses noyau hautes (0xffffffff8…) : 122970
adresses de chargement physique [0x1000000, 0x4000000) : 12109
soit 10.2 fois plus de hautes que de basses
```

Dix fois plus de pointeurs hauts que bas. Le noyau s'attend à vivre en haut, et
**un repli ne l'y emmènera jamais** : il ne fait pas correspondre, il alias.

**Une version antérieure portait deux nombres — 122 994 et 11 933 — sous la
même phrase, sans la commande.** Aucune des définitions plausibles ne les
reproduit. Le rapport, lui, tient sous toutes : c'est l'ordre de grandeur qui
portait l'argument, pas les six chiffres significatifs. `crates/wisq-vm/src/census.rs`
fixe désormais les deux bandes, et six tests tiennent ce qu'elles comptent.

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

**Ce qui est mesuré, et par quelle commande :**

```
cargo run -p wisq-vm --release --example speed
```

Au 14 septembre 2026, trois passages sur le même coureur que le tableau du
tampon plus bas :

| | MIPS |
| --- | ---: |
| interpréteur Rust | 32,6 – 34,3 |
| émetteur, registres seuls, forme libre | 313,8 – 315,4 |
| émetteur, registres seuls, **forme confinée** (ce que l'application exécute) | 283,8 – 290,1 |
| émetteur, une lecture et une écriture, forme libre | 577,2 – 577,7 |
| émetteur, une lecture et une écriture, **forme confinée** | 408,4 – 416,3 |

**L'énoncé qui porte tout le travail de couverture est un ordre, pas une
grandeur** : l'émetteur va huit à dix-huit fois plus vite que l'interpréteur.
Celui-là se transporte.

Une version antérieure de ce paragraphe disait « l'émetteur tient 247 MIPS
contre 49,3 pour l'interpréteur Rust et 831 pour du WebAssembly écrit à la
main » — trois nombres nus, sans date ni commande. Aucun des trois ne se
retrouve ici, et **le banc imprime désormais quatre chiffres d'émetteur là où la
phrase en citait un** : la forme libre et la forme confinée, chacune sur une
boucle de registres et sur une boucle qui touche la mémoire. Un seul nombre ne
pouvait plus désigner ce qui est mesuré.

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

**Les deux machines mesurées, et pourquoi il en faut deux.** Un premier relevé a
longtemps figuré ici seul. Relancé sur un autre coureur, il ne se reproduit pas :
les valeurs absolues diffèrent d'un facteur deux à six selon la ligne.

| motif d'accès | repli | tampon + marche | marche seule | surcoût du tampon |
| --- | --- | --- | --- | --- |
| **coureur A** (relevé d'origine) | | | | |
| balayage court, 512 pages | 2,46 ns | 2,69 ns (×1,09) | 5,25 ns | +0,23 ns |
| balayage long, 16 384 pages | 5,95 ns | 6,41 ns (×1,08) | 8,30 ns | +0,47 ns |
| une page neuve à chaque accès | 16,58 ns | 43,02 ns (×2,59) | 42,53 ns | **+26,43 ns** |
| **coureur B** (14 septembre 2026, trois passages) | | | | |
| balayage court, 512 pages | 1,07–1,14 | 1,79–1,87 | 3,95–3,99 | +0,71 à +0,76 |
| balayage long, 16 384 pages | 2,43–2,66 | 2,87–3,06 | 4,40–4,55 | +0,39 à +0,44 |
| une page neuve à chaque accès | 10,47–11,29 | 15,23–15,86 | 13,23–13,68 | **+4,03 à +4,76** |

Sur chaque machine prise à part, les passages s'accordent : à un dixième de
nanoseconde près sur les deux premières lignes, à sept dixièmes sur la
troisième. **Cette concordance est interne à une machine, et la version
antérieure de ce paragraphe la présentait comme une propriété de la mesure.**

**Ce que les deux machines disent ensemble.** Tant que le tampon répond, la
traduction est presque gratuite : de deux dixièmes à trois quarts de
nanoseconde par accès, contre un repli qui en coûte déjà un à six. Les deux
coureurs s'accordent là-dessus, et c'est l'énoncé qui porte la décision.

**Quand il ne répond jamais, le tampon est une perte sèche** — il coûte plus
que la marche seule sur les deux machines — mais *combien* ne se transporte
pas : +26 ns sur A, +4 sur B. La troisième ligne est construite pour ça, une
page neuve à chaque accès, et aucun tampon ne peut y servir à quelque chose.
Une version antérieure en tirait qu'elle « coûte plus que tout le reste » :
vrai sur A, où le surcoût vaut une fois et demie le repli ; faux sur B, où il
en vaut quatre dixièmes.

Ce motif reste ce pour quoi il est construit — **un plancher, le pire jour
possible, pas une prévision**. Mais sa profondeur, elle, **n'est pas établie à
mieux qu'un facteur six**, et c'est tout ce que deux machines permettent d'en
dire.

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
une nanoseconde, là où la marche elle-même en coûte treize à quarante-trois selon
le coureur (voir le tableau à deux machines plus haut). Tenir RIP à jour à
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
| `vmcall`, `vmmcall` — l'appel à l'hyperviseur | **décodés**, arrêt nommé s'ils sont atteints, RIP dessus ; la sonde VMware du noyau ne les exécute que si CPUID annonce sa signature, et `cpuid` ne l'annonce pas |
| `invpcid` — purger le tampon par identifiant de contexte | **décodée** (`66 0f 38 82 /r`, forme mémoire, et rien d'autre de la page `0f 38`), arrêt nommé si elle est atteinte, RIP dessus ; `native_flush_tlb_one_user` ne l'exécute que si CPUID annonce `PCID` et `INVPCID`, et `cpuid` n'annonce ni l'un ni l'autre |
| `ltr` — charger le registre de tâche | **produite** (`0f 00 /3`, forme registre, et rien d'autre du groupe 6) : le sélecteur est rangé, seize bits, dans sa case. **Depuis #257 la délivrance lit le descripteur derrière** — dans la GDT, à chaque délivrance plutôt qu'au `ltr` — et y trouve `RSP0` et les piles d'interruption |
| `lldt` — charger la table de descripteurs locale | **produite** (`0f 00 /2`, forme registre) : le sélecteur nul passe et continue — c'est celui du noyau, qui n'a pas de LDT — ; un sélecteur non nul est un arrêt nommé, RIP dessus, faute de table globale où le trouver |
| `mov` vers et depuis DR0-DR3, DR6, DR7 — les registres de débogage | **produits** (`0f 21 /r`, `0f 23 /r`, forme registre ; DR4 et DR5 ne se décodent pas) : lire rend l'état de repos du silicium, écrire cet état passe — c'est ce que fait `cpu_init` —, écrire autre chose est un arrêt nommé, RIP dessus : cette machine n'a pas de points d'arrêt matériels |
| `cmpxchg16b` — le verrou à seize octets | **produite** (`f0 48 0f c7 /1`, forme mémoire, REX.W obligatoire ; sans lui `cmpxchg8b` reste illisible, et le reste du groupe 9 aussi) et **exécutée** dans les deux cœurs Rust : seize octets comparés à RDX:RAX, RCX:RBX écrits s'ils tiennent tous deux, RDX:RAX rechargés sinon, ZF seul qui bouge ; sous pagination, une seconde moitié en lecture seule défait la première et rapporte la faute. C'est le chemin `__CMPXCHG_DOUBLE` de SLUB, que le noyau ne prend que si CPUID annonce `CX16` — ce que `cpuid` annonce depuis #217, parce que l'émetteur l'exécute vraiment |
| `clflush`, `clflushopt` — vider une ligne de cache | **produites** (`0f ae /7` forme mémoire, avec ou sans `66` et le `3e` de remplissage du noyau ; les autres formes mémoire de `0f ae`, `fxsave`, `ldmxcsr`, `xsave`…, restent refusées) comme instructions inertes qui ne portent pas leur adresse : cette machine n'a pas de cache à vider. C'est la boucle `clflush_cache_range` de `cpa_flush`, que le noyau ne prend que si CPUID annonce `CLFLUSH` — ce que `cpuid` annonce depuis #217, **avec sa taille de ligne** dans EBX de la feuille un : le noyau s'en sert comme pas de boucle, et à zéro cette boucle n'avancerait jamais |
| `rdrand`, `rdseed` — un nombre du générateur matériel | **produites** (`0f c7 /6` et `/7`, forme registre, seize, trente-deux et soixante-quatre bits ; `f3 0f c7 /7` est `rdpid` et n'est pas lu, les formes mémoire non plus) et **exécutées** dans les deux cœurs Rust avec la seule sémantique d'une machine sans source d'aléa : CF nul — « rien de disponible » —, destination à zéro selon la règle de largeur, les cinq autres drapeaux arithmétiques effacés. C'est ce que le manuel prévoit ; le noyau réessaie dix fois dans `kaslr_get_random_long` puis retombe sur `rdtsc`, et ne prend cette boucle que si CPUID annonce `RDRAND`, ce que `cpuid` n'annonce pas |
| `syscall` / `sysretq` — l'appel système rapide | **produits** (`0f 05` et `48 0f 07`) : RCX prend l'adresse de la suite, R11 les drapeaux, le masque éteint ce que le noyau a demandé, les sélecteurs viennent de STAR — **forcés** à l'anneau zéro à l'entrée, `+16` pour le code et `+8` pour la pile au retour —, et la cible de LSTAR. **La pile ne change pas** : c'est au noyau de le faire. `0f 07` **sans** REX.W reste illisible : ce serait un retour vers le mode compatibilité |
| `wrmsr` / `rdmsr` — les registres spécifiques au modèle | **produits** pour huit numéros : FS_BASE, GS_BASE, KERNEL_GS_BASE, EFER, et les quatre de l'appel système (STAR, LSTAR, CSTAR, SYSCALL_MASK), rangés et rendus ; tout autre numéro est une **`#GP(0)` délivrée à l'invité**, RIP sur l'instruction, comme sur le silicium — la table d'exceptions du noyau la rattrape ; sans porte, un arrêt nommé qui **porte le numéro** |
| la délivrance d'une **faute de page** | **existe**, dans `web/host.js` : porte, cadre, IF, témoin effacé |
| la délivrance d'une **faute de protection générale** sur un MSR inconnu | **existe**, par le même chemin : code d'erreur nul, RIP sur l'instruction ; c'est le gestionnaire du noyau qui avance ou non |
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
   réveille sur un timer. La machine n'en a aucun.

   **Ce n'est plus une prévision, c'est la mesure.** Depuis que le pilote de
   `kernel-entry` ne rejoue plus le démarrage à chaque région, il va jusqu'au
   bout de ce que la machine sait faire — 5179 régions, 75 lignes série — et
   s'arrête sur `calibrate_delay + 1091`, un saut conditionnel **vers
   lui-même** : le noyau attend que `jiffies` avance. Le mur n'est plus une
   instruction manquante ni un budget d'outil. C'est celui-ci. Le compteur d'horodatage,
   lui, **a cessé de mentir sur la durée** : `web/host.js` ajoute le budget
   qu'il vient d'accorder à chaque tour de sa boucle, donc un intervalle se
   mesure. Ce qui manque encore est la ligne qui **interrompt**, pas l'horloge
   qui avance.

   **Et le noyau ne le laisse plus déduire, il le dit.** Depuis que la console
   de démarrage n'est plus coupée — `keep_bootcon` dans la ligne du montage —
   le relevé porte ses mots : « Failed to register legacy timer interrupt »,
   « APIC: Keep in PIC mode(8259) », « tsc: Unable to calibrate against PIT »,
   « tsc: No reference (HPET/PMTIMER) available ». Ni 8259, ni PIT, ni HPET, ni
   APIC : aucune ligne capable de l'interrompre. Ce qui manque est un
   **périphérique**, pas un raccordement.

   **Le premier des trois est posé.** `web/host.js` modélise les deux 8259
   depuis la tranche T1 : leur masque se relit, et leur base de vecteur est
   celle que ce noyau emploie — `0x30`, lue dans son `init_8259A`, pas `0x20`.
   Deux lignes du journal s'en vont : « Using NULL legacy PIC » et **« Failed
   to register legacy timer interrupt »**. La ligne du timer est enregistrée ;
   il ne manque plus que le 8254 pour la cadencer (T2) et quelqu'un pour la
   lever (T3).

   **Et T2 a levé le mur en entier, sans T3.** Le 8254 compte désormais contre
   la même horloge que `rdtsc`, et l'étalonnage réussit : « tsc: Fast TSC
   calibration using PIT », « tsc: Detected 999.989 MHz processor ». Un noyau
   qui a une fréquence digne de confiance **n'exécute pas** sa boucle
   d'étalonnage, il la calcule — « Calibrating delay loop (skipped) ». Le saut
   conditionnel vers lui-même de `calibrate_delay` n'est plus atteint. T3 reste
   nécessaire pour les jiffies et l'ordonnanceur, mais plus pour la raison
   écrite ici.

   **Et derrière, un second manque — levé à son tour.** La machine s'arrêtait
   sur un `hlt` à `fpu__init_system + 448` : « x86/fpu: Giving up, no FPU found
   and no math emulation present », faute que `cpuid` annonce le bit 0 d'EDX.
   La question que #217 avait posée — l'émetteur exécute-t-il x87 ? — a été
   tranchée en exécutant ce que le noyau vérifie derrière la garde : `db e3`,
   `fninit`, qui remet le mot de contrôle à `0x037f` et le mot d'état à zéro.
   Le bit est donc annoncé **et** tenu.

   **Et `fxsave` derrière, levé aussi.** La machine s'arrêtait pour de vrai à
   `fpu__init_system + 183` — `0f ae 05 d2 f1 13 00` —, que le noyau exécute
   sans garde parce que `X86_FEATURE_FXSR` est replié à vrai à la compilation
   sur x86-64. L'aire porte maintenant ce que la machine a — les deux mots du
   x87 — et **zéro pour ce qu'elle n'a pas** : ni registre XMM, ni MXCSR,
   aucun registre x87 occupé. Masque MXCSR nul, Linux prend sa valeur par
   défaut documentée, et dit enfin **« x86/fpu: x87 FPU will use FXSAVE »** —
   88 lignes de journal au lieu de 87.

   Elle n'en écrit que **416** des 512 : les quatre-vingt-seize derniers sont
   laissés tels quels, ce que le corpus matériel a mesuré sur le silicium.

   **Et le mur d'après n'était pas une instruction : c'était un défaut.** La
   machine s'arrêtait sur le `BUG_ON(memcmp(addr, opcode, len))` de
   `__text_poke + 1093` — le noyau écrivait un correctif à travers une
   cartographie temporaire, le relisait, et ne le retrouvait pas. L'émetteur
   ne vidait **jamais** son tampon de traduction sur une écriture de CR3, CR4
   ou CR0, là où le cœur Swift vide sur les trois et où l'interpréteur Rust
   n'a aucun cache. `__text_poke` écrit CR3 deux fois par correctif.

   Corrigé, le noyau **double son journal** — 88 lignes à 175, 1782 régions à
   8176 — et franchit `Freeing SMP alternatives memory`, `smpboot`,
   `clocksource: jiffies`, `NET: Registered PF_NETLINK/PF_ROUTE`,
   `TCP: Hash tables configured`. Il en est aux **initcalls**.

   **Et le mur d'après n'était pas davantage une instruction manquante** : à
   `do_one_initcall + 673` se trouve un `ud2` que Linux exécute **exprès**.
   `WARN()` compile en un appel à `__warn_printk` suivi d'un `ud2`, et son
   gestionnaire `#UD` consulte `__bug_table`, avance RIP de deux, et reprend.
   Tant que le vecteur 6 n'était pas délivré, chaque avertissement du noyau
   était un arrêt définitif.

   Délivré, le noyau **imprime sa trace d'avertissement en entier et continue**
   — 175 lignes de journal à 204, 8176 régions à 10 144 — jusqu'à
   `NET: Registered PF_UNIX/PF_LOCAL`, `PF_XDP`, `PCI: CLS`, `rtc_cmos` et
   `Initialise system trusted keyrings`.

   **Et le mur d'après tenait en un octet** : `fpu__drop + 136` portait `9b`,
   **`fwait`**, qui attend les exceptions en attente du coprocesseur. Sur cette
   machine le mot d'état du x87 n'est jamais écrit qu'à zéro et aucune
   arithmétique x87 ne se décode : rien ne peut y être en attente, donc `fwait`
   ne fait rien. C'est une **conclusion**, et elle devient fausse le jour où un
   calcul x87 existe — ce que cette machine ne fait toujours pas, et la première
   instruction qui en demanderait un reste un arrêt nommé.

   Décodée, **le mur ne s'est pas déplacé : il a disparu.** 10 144 régions à
   10 776, 204 lignes de journal à 206 (`workingset:` et `zbud: loaded`), et
   **aucun arrêt** — le million de tours du pilote s'épuise dans
   `jent_entropy_init` et la machine avançait encore.

   **Ce relevé ne dit pas que le noyau démarre.** Il dit qu'il n'y a plus
   d'instruction manquante sur le chemin parcouru en un million de tours.
   `jent_entropy_init` est précisément le genre de boucle qui peut tourner
   longtemps sans avancer si l'horloge ne bouge pas assez. La question suivante
   n'est plus « quelle instruction manque » mais **« la machine progresse-t-elle
   ou tourne-t-elle en rond »**, et il faut un relevé qui la pose.

   **#229 la pose, et la réponse n'est pas celle qu'on attendait.** Le pilote
   compte désormais le tour où une adresse a été atteinte pour la dernière fois
   sans l'avoir jamais été : `marche 1000000 860189 10775 30`. La machine a
   ouvert du terrain neuf **jusqu'au tour 860 189 sur un million** — 86 % du
   budget — puis s'est refermée sur trente adresses pour les 139 811 derniers.

   La conjecture qui avait ouvert cette tranche — « elle tourne en rond depuis
   le début » — venait de lire « tour 10776 » dans le relevé de #228, où ce
   nombre était en réalité le rang de la traduction. **Le pilote imprimait deux
   compteurs sous un seul mot** ; il ne le fait plus.

   **Et à budget quadruple, le tour de la dernière adresse neuve suit le
   budget** : 3 932 806 sur quatre millions, soit 98,3 %. La machine n'était pas
   coincée, elle avançait. 14 348 régions, 372 lignes de journal, et un mur qui
   n'est ni une instruction ni une horloge :

   ```
   kworker/u2:1 invoked oom-killer: gfp_mask=0xcc0(GFP_KERNEL), order=0
   Kernel panic - not syncing: System is deadlocked on memory
   ```

   **Le pilote déclarait 64 Mio en dur.** `WISQ_RAM` les règle depuis #231, avec
   un refus — pas un avertissement — pour toute taille dont le repli par masque
   n'amène plus une adresse virtuelle sur sa place physique. À 256 Mio le noyau
   ne meurt plus : il atteint le même point, `sched_clock: Marking stable`, et
   c'est le budget de tours qui le coupe en pleine marche.

   Les 372 lignes de journal tombent alors à 230, et **ce n'est pas du progrès
   perdu** : les 142 de différence étaient le vidage de l'oom-killer et la trace
   de la panique. Compter les lignes de journal mesure le bavardage.

   Ce que ça ne tranche pas : la suite, c'est l'espace utilisateur, et il demande
   un initramfs. C'est une direction, pas un défaut.

   **Tranchée depuis.** Avec un initramfs, le noyau appelle `/init` et wisq lui
   délivre la faute de chargement de son point d'entrée. À #258, **quatre
   instructions de `/init` s'exécutent** en anneau trois, et leurs effets sont
   dans les registres ; la machine s'arrête sur le `syscall` qui suit, que
   l'émetteur ne produit pas.

   **Et `WISQ_ROUNDS=8192` ne suffit plus** : les relevés se prennent désormais
   à `WISQ_ROUNDS=16384 WISQ_TURNS=1000000`.

   **Et `WISQ_TURNS=65536` ne suffit plus** pour aller jusque-là : à ce budget
   la machine s'épuise dans `ftrace_init`, qui convertit 41 322 sites d'appel
   et rend la main deux fois par site. Les relevés de cette tranche sont pris à
   `WISQ_ROUNDS=8192 WISQ_TURNS=1000000`.
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

## Ce qu'une traduction coûte sous WebKit, et pourquoi le chiffre d'à côté ne le disait pas

`WebKitJITProbeTests` chronomètre deux choses depuis longtemps : le moteur, sur
160 M d'instructions, et un aller-retour **nu** par le pont — un
`evaluateJavaScript` qui incrémente un entier.

**Ni l'un ni l'autre n'est une constante, et ce paragraphe a longtemps écrit
qu'ils l'étaient** : « 1151 MIPS » et « 0,88 ms », les valeurs d'un passage,
posées comme des propriétés du moteur. Le tableau daté plus bas, dans cette même
page, donne pour ces deux grandeurs 864 à 1702 MIPS et 0,36 à 3,09 ms sur les
passages relevés — et ni 1151 ni 0,88 n'y figurent. C'était la troisième fois
que la même faute s'écrivait ici, et cette fois dans les lignes qui introduisent
la section qui la raconte.

Il est tentant de multiplier le second par le nombre de régions d'un noyau —
15 319 — et d'annoncer treize secondes. **C'est un plancher présenté comme une
estimation**, et il est bâti sur un chiffre qui varie d'un facteur huit. Une
traduction n'est pas un aller-retour nu : c'est le message, puis l'émetteur
Rust qui produit le module, puis `WebAssembly.instantiate`. Les deux grandeurs
n'ont en commun que le trajet.

Le test des cent vingt-huit régions imprime donc sa propre mesure —
`bureau : … ms par région traduite` — et c'est le premier endroit du dépôt où
ce coût-là est relevé sur le moteur qui expédie. Aucun seuil : un coureur
partagé n'en porte pas et un simulateur n'a pas de plafond thermique. Mais il
est dans le résumé de chaque passage, à côté des autres, et un changement qui
le double se verra.

**C'est de ce chiffre que dépend ce qu'un vrai noyau coûterait**, pas de celui
d'à côté.

### Quatre conclusions tirées de trop peu de points, et la quatrième démentie deux fois

Les relevés de `bureau` **vus jusqu'au 14 septembre 2026**, pour cent vingt-huit
régions traduites. Ce tableau est un échantillon daté, pas un inventaire : le
vrai registre, ce sont les lignes que chaque passage imprime dans son résumé.
L'y recopier à chaque exécution rendrait la page fausse entre deux, et c'est
précisément la faute que cette section raconte.

| | #371 | #372 (a) | #372 (b) | #372 (c) | #372 (d) |
| --- | --- | --- | --- | --- | --- |
| `bureau`, millisecondes par région | 7,44 | 7,24 | **5,35** | **8,68** | 6,77 |
| `bureau`, en lectures de registre | — | 5,04 | **5,37** | **2,31** | **1,57** |
| l'étalon interne (`global`) | — | 1,44 ms | 0,996 ms | **3,76 ms** | **4,32 ms** |
| `pont`, micro-banc d'une autre suite | 3,09 ms | 0,48 ms | 0,36 ms | 0,82 ms | 0,53 ms |
| `WebKit` | 864 MIPS | 1702 MIPS | 1649 MIPS | 1203 MIPS | 898 MIPS |

**Et quatre fois de suite, j'ai conclu avant d'avoir de quoi.**

1. **Un point.** J'ai multiplié le `pont` d'un passage par le nombre de régions
   d'un noyau et annoncé treize secondes. Deux grandeurs différentes, un seul
   relevé.
2. **Deux points.** 7,44 puis 7,24 : j'en ai tiré que les millisecondes
   tenaient et que le rapport ne servait à rien. Le troisième passage les
   écarte de trente-neuf pour cent.
3. **Deux observations du rapport** — 5,04 et 5,37 — qui se ressemblent. En
   conclure qu'il était stable aurait refait la faute d'à côté, dans l'autre
   sens ; je m'en suis abstenu.
4. **Mais j'ai écrit, dans la même page, que « le second varie moins ».** C'est
   la même faute, en plus discret : une comparaison de dispersions tirée de
   deux valeurs contre trois. **Le passage qui a validé la tranche l'a
   démentie** — le rapport est tombé à 2,31, puis à 1,57 au passage d'après,
   celui qui a validé la correction elle-même.

Sur ces cinq relevés, c'est **le rapport qui s'étale le plus** : de 1,57 à
5,37, un facteur 3,4, là où les millisecondes vont de 5,35 à 8,68, un facteur
1,6. Le dénominateur y est pour quelque chose, et c'est de l'arithmétique et
non une trouvaille — l'étalon interne va de 0,996 à 4,32 ms, un facteur 4,3,
plus large que la grandeur qu'il est censé normaliser. **Ce n'est pas davantage
une loi que ne l'était l'affirmation inverse** : cinq relevés n'en font pas
plus que deux, et le sixième arrivera avec le prochain passage.

**Ce qui est mesuré, et rien de plus** : les deux chiffres sont imprimés à
chaque passage, l'un en millisecondes, l'autre contre un étalon pris dans le
même test à la même seconde. Aucun des deux n'est présenté comme le bon, et
cette page ne dira lequel varie le moins que le jour où assez de passages
l'auront montré.

Ce que ça permet déjà de dire sans risque, parce que c'est un intervalle
mesuré et non un chiffre : pour les 15 319 régions d'un vrai noyau, la
traduction seule pèse **entre quatre-vingts et cent trente-cinq secondes**
selon le passage — pas les treize que j'avais annoncées. C'est le mur de #167,
et il est plus haut que la première estimation.

### Ce que l'étalon est, et ce qu'il n'est pas

`global` coûte 1,44 ms le jour où un `evaluateJavaScript` nu en coûte 0,48 : il
traverse le gestionnaire de messages du bureau, pas seulement le moteur. La
ligne imprimée le nomme donc « une lecture de registre par le pont », et non
« un aller-retour nu » comme elle le faisait d'abord — sans quoi on croirait
comparer deux fois la même chose.

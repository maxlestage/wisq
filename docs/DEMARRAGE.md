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

**Ce qui n'est pas mesuré** : ce que la pagination coûterait à ces 247 MIPS. Le
dire au doigt mouillé serait un chiffre inventé qui aurait l'air d'un fait. La
façon de le savoir est une sonde : un module qui fait la même boucle avec un
accès replié puis avec un accès passé par un tampon de traduction, jugé sous
JavaScriptCore comme le reste. C'est une demi-journée, et **ça devrait précéder
la décision, pas la suivre** — les cinq tranches de ce jour ont montré trois fois
qu'une sonde jetable posée avant le code répond à une question qu'on aurait
sinon tranchée de travers.

## Les interruptions

### Ce qui existe

| | état |
| --- | --- |
| `lidt` / `sidt` — la table est rangée et rendue | **produit** |
| `cli` / `sti` — le drapeau d'interruption | décodés, **refusés** |
| `hlt` — attendre une interruption | décodé, **refusé** |
| `popf` — qui peut rallumer le drapeau sans nommer `sti` | décodé, **refusé** |
| `iret`, `iretq` — le retour d'interruption | **pas même décodés** |
| `int`, `int3` — l'entrée logicielle | **pas même décodés** |
| la délivrance d'une interruption | n'existe pas |

**Vérifié plutôt qu'affirmé** : `decode` rend `None` sur `cf`, `48 cf`, `cc` et
`cd 80`. Ce n'est pas seulement le retour qui manque, c'est toute la famille
d'entrée et de sortie.

**`lidt` produit ne veut pas dire que les interruptions marchent.** Le registre
se relit, et c'est tout ce que la tranche prétendait. Rien ne lit cette table.

### Ce que ça demande

Trois choses, et aucune n'est petite :

1. **Une source de temps qui interrompt.** Le noyau calibre, planifie et se
   réveille sur un timer. La machine n'en a aucun, et le compteur d'horodatage
   qu'elle sert n'avance **que quand on le lit** — c'est un mensonge sur la durée,
   assumé et écrit, mais qui interdit toute mesure d'intervalle.
2. **Un point de délivrance.** Une interruption arrive entre deux instructions :
   il faut un endroit où la boucle vérifie, sauve l'état sur la pile de
   l'invité, lit la table, et saute. La boucle hôte rend déjà la main
   régulièrement — c'est le crochet naturel.
3. **`iret`, et la pile de retour.** Non décodé, comme toute sa famille. Le
   dépôt a déjà payé une fois le prix de confondre un retour proche et un retour
   lointain ; `iret` dépile davantage encore — RIP, CS, RFLAGS, RSP et SS.

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

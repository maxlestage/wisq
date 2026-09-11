//! **Le compilateur, écrit ici. WebKit n'a que la signature.**
//!
//! iOS interdit à une application de l'App Store d'écrire une page à la fois
//! inscriptible et exécutable. Il n'interdit pas de produire une **donnée**.
//! Un module WebAssembly est une donnée ; c'est WebKit qui a le droit de la
//! compiler. Le contournement ne déplace donc pas le travail : le décodage, la
//! traduction et la génération de code sont dans ce fichier, et le moteur ne
//! fait que la dernière étape.
//!
//! **Ce qui juge ce code.** Un module émis ici tourne sous JavaScriptCore — le
//! moteur exact de `WKWebView`, que Bun embarque — et son résultat est comparé
//! aux cas de `x86-oracle.tsv`, relevés sur un vrai processeur. L'émetteur
//! n'est donc pas jugé par ce que j'en pense, mais par du silicium à travers le
//! moteur qui l'exécutera.
//!
//! **Les drapeaux sont calculés tout de suite**, comme le fait le module
//! « réaliste » du lot 8. C'est le coût honnête : un vrai cœur les paie. Les
//! rendre paresseux dans du WebAssembly demanderait de garder l'opération et
//! ses opérandes en mémoire, et c'est une tranche à part — mesurée avant
//! d'être écrite, comme le reste.

//! **Le fichier de registres est en variables globales, pas en mémoire.**
//!
//! Il vivait au début de la mémoire linéaire, aux octets 0 à 136. Ça marchait
//! tant que le module n'avait pas de mémoire invitée — mais la mémoire linéaire
//! **est** la RAM de l'invité, adresse pour adresse, et un noyau qui écrit à
//! l'adresse 8 écrasait alors RCX. Les registres sont donc sortis de là.
//!
//! Ce n'est pas qu'un déménagement : une globale n'est pas une case mémoire,
//! le moteur peut la garder dans un registre machine, et l'hôte y accède par un
//! nom exporté au lieu d'un décalage que les deux côtés doivent s'accorder à
//! calculer.

use crate::x86::{
    decode, Address, BitAction, CarryAction, Condition, Decoded, Op, Segment, Width, AF,
    ALWAYS_ONE, CF, DF, IF, OF, PF, SF, WRITABLE_FLAGS, ZF,
};

/// Seize registres, puis RFLAGS, puis les emplacements de travail. L'indice est
/// celui de la globale exportée.
pub const RFLAGS_SLOT: usize = 16;
/// Les emplacements de travail : la traduction s'en sert au lieu de variables
/// locales. Il y en a six — le sixième porte le compte d'une rotation ramené
/// dans la largeur.
/// **Où l'exécution s'est arrêtée.** Une région ne va pas jusqu'au bout du
/// programme : elle rend la main quand un saut sort de ce qu'elle connaît, ou
/// quand le budget est épuisé. Sans cette globale, l'hôte saurait qu'elle s'est
/// arrêtée mais pas où reprendre.
pub const RIP_SLOT: usize = RFLAGS_SLOT + 1;
/// **La base du segment GS**, que l'hôte pose et que le module lit.
///
/// Elle est une globale importée comme les registres, et pour la même raison :
/// le module ne peut pas la connaître à la compilation. Un noyau l'installe une
/// fois par cœur, très tôt, puis n'y touche plus — mais « très tôt » est déjà
/// après que la première région a été traduite, et une constante figée dans le
/// code rendrait cette région fausse dès l'installation suivante.
pub const GS_SLOT: usize = RIP_SLOT + 1;
/// **Le compteur d'horodatage, et pourquoi c'est une globale plutôt qu'un
/// appel à l'hôte.**
///
/// L'autre voie était d'importer une vraie horloge, au prix d'un retour de
/// main — 125 à 190 ns, mesuré. Elle n'achète rien : un noyau calibre la
/// fréquence de son TSC contre une **autre** horloge, un PIT ou un HPET, dont
/// cette machine n'a aucun. La calibration est fausse des deux côtés, et la
/// voie chère ne l'est pas moins.
///
/// **Ce qui décide est ailleurs.** Un noyau écrit
/// `while (rdtsc() - début < n)`. Deux lectures qui rendraient la même valeur
/// feraient une boucle qui ne se termine **jamais** : une machine qui pend,
/// indiscernable d'un calcul long. Le compteur avance donc à chaque lecture.
///
/// **Et l'hôte l'avance aussi**, ce qui retire le mensonge sur la durée. Le
/// module ne connaît que ses propres lectures ; sans autre chose,
/// `t0 = rdtsc() ; travail ; t1 = rdtsc()` rendrait toujours le même écart, et
/// un noyau qui attend une durée attendrait pour toujours. `web/host.js` ajoute
/// donc le budget qu'il vient d'accorder à chaque tour de sa boucle.
///
/// **Pourquoi là et pas ici.** Compter le travail dans le module coûterait un
/// ajout par bloc, payé sur tous les modules et pour toujours, au bénéfice
/// d'une instruction que le noyau Alpine exécute vingt-huit fois. La boucle
/// hôte sait déjà ce qu'elle a laissé passer, et l'ajouter est gratuit pour
/// l'invité — le même endroit, et le même raisonnement, que la délivrance des
/// interruptions, mesurée par `--example deliver-probe`.
///
/// **Ce qu'il ne dit toujours pas** : l'horloge n'est calibrée contre rien —
/// cette machine n'a ni PIT ni HPET —, et le budget entier est compté même
/// quand la région rend la main avant de l'épuiser. Elle avance donc trop vite
/// quand les régions s'enchaînent souvent. Les deux propriétés qui comptent
/// tiennent : elle ne recule jamais, et elle ne stagne jamais.
pub const TSC_SLOT: usize = GS_SLOT + 1;
/// Ce qu'une lecture ajoute au compteur. La valeur est **arbitraire**, et le
/// dire vaut mieux que la déguiser en fréquence : seule sa positivité stricte
/// est une propriété, et c'est elle qu'un test tient.
pub const TSC_STEP: u64 = 100;
/// **Les six sélecteurs de segment, rangés et rendus — et rien d'autre.**
///
/// En mode 64 bits, CS, SS, DS et ES ont une base **forcée à zéro** : aucun
/// accès mémoire ne dépend de leur valeur, et le dépôt le tient déjà ailleurs
/// en montrant que leurs préfixes n'y changent rien. Un sélecteur y est donc
/// un nombre que l'invité range et relit, et c'est exactement ce qui se
/// modélise sans mentir : l'aller-retour est fidèle.
///
/// **Ce que ces nombres ne sont pas** : il n'y a aucune table de descripteurs
/// derrière eux. Ils partent à zéro, ce qui veut dire « aucun chargeur n'est
/// passé ici » — pas « le segment nul est chargé ». La valeur de départ n'est
/// volontairement pas une affirmation sur l'état d'amorçage : la poser
/// demanderait de lire le protocole d'amorçage à sa source, et le citer de
/// mémoire fabriquerait une machine plausible plutôt qu'une machine vraie.
///
/// L'ordre est celui de l'énumération du décodeur : ES, CS, SS, DS, FS, GS.
pub const SEGMENT_SLOT: usize = TSC_SLOT + 1;
pub const SEGMENT_COUNT: usize = 6;
/// **Les deux tables de descripteurs, chacune en limite puis base.**
///
/// `lgdt` lit dix octets — une limite de seize bits, une base de soixante-
/// quatre — et `sgdt` les rend. Le couple est rangé et rendu, et c'est tout ce
/// qui est modélisé.
///
/// **Ce qui est lu derrière ces nombres, et ce qui ne l'est pas.** L'IDT l'est :
/// quand une région pose le témoin de faute, `web/host.js` va chercher la
/// porte du vecteur 14 à la base rangée ici, dans la limite rangée ici, et
/// pose le cadre du mode long sur la pile de l'invité — c'est la délivrance,
/// et `iretq` la défait. La GDT, elle, n'est toujours lue par rien : charger
/// FS ou GS avec un sélecteur non nul reste un arrêt nommé, et aucune
/// interruption de matériel n'est délivrée. Un `lgdt` produit dit toujours
/// « ce registre se relit », pas « les descripteurs marchent ».
///
/// L'ordre : limite de la GDT, base de la GDT, limite de l'IDT, base de l'IDT.
pub const TABLE_SLOT: usize = SEGMENT_SLOT + SEGMENT_COUNT;
pub const TABLE_COUNT: usize = 4;
/// **Les deux bases que `wrmsr` sait poser, en plus de celle de GS.**
///
/// `GS_SLOT` existait déjà et n'était écrit que par l'hôte ; il est consulté à
/// **chaque** adresse préfixée par `%gs:`, et un noyau x86-64 y range tout ce
/// qui est propre à un cœur. L'écrire depuis l'invité n'est donc pas un
/// aller-retour : ça change réellement où il lit. C'est ce qui sépare cette
/// tranche des trois précédentes.
///
/// `FS_BASE` est rangée et rendue, **sans plus** : le décodeur refuse le
/// préfixe `0x64`, donc aucune adresse n'en dépend aujourd'hui. Le dire vaut
/// mieux que laisser croire à une symétrie avec GS.
///
/// `KERNEL_GS_BASE` est la base que `swapgs` échange avec celle de GS — un
/// noyau le fait à chaque entrée d'appel système.
pub const FS_BASE_SLOT: usize = TABLE_SLOT + TABLE_COUNT;
pub const KERNEL_GS_SLOT: usize = FS_BASE_SLOT + 1;

/// **Les trois premiers numéros que cette machine modélise** ; EFER et les
/// quatre registres de l'appel système ont les leurs plus bas. Tout autre
/// numéro est un **arrêt nommé qui porte le numéro**, RIP sur l'instruction.
/// Ne rien faire serait le pire des choix : le noyau croirait avoir posé une
/// valeur, et la panne tomberait loin de sa cause.
pub const MSR_FS_BASE: u64 = 0xc000_0100;
pub const MSR_GS_BASE: u64 = 0xc000_0101;
pub const MSR_KERNEL_GS_BASE: u64 = 0xc000_0102;

/// **Les cinq registres de contrôle que le décodeur lit** : CR0, CR2, CR3, CR4
/// et CR8, rangés dans cet ordre.
///
/// **Lire se modélise, allumer la pagination non.** Écrire CR4 ou CR8 est
/// accepté — rien ne consulte ces bits. Écrire CR0 ou CR3 est **refusé** : ce
/// serait allumer la pagination, que cette machine n'implémente pas, et un
/// noyau qui croit paginer part sur un chemin dont la panne n'aura aucun
/// rapport visible avec sa cause.
///
/// **Ici, contrairement aux MSR, le numéro est dans l'instruction** — le champ
/// `reg` du ModRM. « Refuser par le numéro », infaisable pour un MSR dont le
/// numéro arrive dans ECX, est donc parfaitement possible ici.
///
/// **Ce que ces registres ne font pas** : rien ne lit ces bits. Ni la
/// protection en écriture de CR0, ni le SMEP/SMAP de CR4. Accepter une écriture
/// dit « on la range », pas « on l'applique ».
pub const CONTROL_SLOT: usize = KERNEL_GS_SLOT + 1;
pub const CONTROL_COUNT: usize = 5;

pub const SCRATCH_SLOT: usize = CONTROL_SLOT + CONTROL_COUNT;

/// **Ce que `cpuid` déclare, et la règle qui le rend sûr.**
///
/// `cpuid` n'est pas une lecture, c'est une **promesse**. Chaque bit mis dit au
/// noyau « tu peux utiliser ça », et il le croit sur parole : il n'y a pas de
/// second contrôle. Déclarer une extension qu'on n'émule pas ne donne pas une
/// panne franche — ça donne un noyau qui part sur un chemin qu'on ne sait pas
/// exécuter, plus loin, sans rapport visible avec la cause.
///
/// **La règle est donc : un zéro partout, sauf ce qui est vrai.** Un zéro veut
/// dire « on ne l'a pas », et c'est exact ; un bit de plus serait un mensonge
/// qu'on paierait ailleurs.
///
/// Le nom du fournisseur est volontairement **inconnu**. Se faire passer pour
/// Intel ou AMD ferait prendre au noyau les contournements d'errata de leurs
/// puces — du code écrit pour des défauts que cette machine n'a pas. Un nom
/// qu'il ne reconnaît pas le renvoie sur son chemin générique.
/// « wisq wasm vm », douze octets, dans l'ordre EBX, EDX, ECX.
pub const CPUID_VENDOR_EBX: u32 = u32::from_le_bytes(*b"wisq");
pub const CPUID_VENDOR_EDX: u32 = u32::from_le_bytes(*b" was");
pub const CPUID_VENDOR_ECX: u32 = u32::from_le_bytes(*b"m vm");
/// La feuille la plus haute qu'on sache servir. Une seule au-delà de zéro.
pub const CPUID_MAX_LEAF: u32 = 1;
/// Famille 6, modèle 0, pas 0 — une signature plausible et sans prétention.
pub const CPUID_SIGNATURE: u32 = 0x0000_0600;
/// **Le seul bit vrai aujourd'hui** : le compteur d'horodatage, produit depuis
/// la tranche précédente. Il se déclare parce qu'il existe, et parce qu'un
/// noyau qui ne le voit pas cherche une autre horloge que cette machine n'a
/// pas non plus.
pub const CPUID_FEATURES_EDX: u32 = 1 << 4;
pub const SCRATCH_COUNT: usize = 10;

/// **Le témoin de faute de page.** Zéro tant que rien n'a fauté ; sinon le code
/// d'erreur de la faute **plus un** — pour que le code zéro, qui est celui
/// d'une lecture sur une page absente, ne passe pas pour « rien ».
///
/// **Pourquoi une globale et pas un piège.** Un piège WebAssembly est sans
/// retour : il arrête l'émulateur entier, alors qu'une faute doit rendre la
/// main au noyau invité. La boucle de répartition rend déjà la main dès qu'un
/// bloc rend un indice négatif ; une faute pose ce témoin, et le contrôle en
/// ligne qui suit chaque traduction fait rendre −1.
///
/// **Le contrôle est en ligne, et ça a été mesuré avant d'être décidé** — voir
/// `docs/DEMARRAGE.md` : −0,17 à +0,30 ns par accès sur un balayage, la plage
/// incluant zéro. L'autre conception, une page piège contrôlée une fois par
/// bloc, laissait l'instruction fautive agir à moitié pour une économie
/// qu'aucune des trois mesures ne voit.
///
/// **L'adresse fautive va dans CR2**, comme sur le silicium : c'est là que le
/// gestionnaire du noyau la lira le jour où les fautes seront délivrées.
/// **Les trois globales de travail de la traduction.** L'adresse invitée, son
/// numéro de page, et l'adresse de la case du tampon.
///
/// **Elles sont à elle seule, et c'est délibéré.** Les dix emplacements de
/// `SCRATCH` sont pris à l'intérieur d'une instruction — une chaîne d'octets en
/// occupe trois — et `guest()` est appelé *au milieu* de ces instructions-là.
/// S'en partager un écraserait une valeur vivante, et le défaut ne se verrait
/// que sur les formes qui en ont besoin.
pub const TRANSLATE_SLOT: usize = SCRATCH_SLOT + SCRATCH_COUNT;
pub const TRANSLATE_COUNT: usize = 3;

pub const FAULT_SLOT: usize = TRANSLATE_SLOT + TRANSLATE_COUNT;

/// **Le témoin d'arrêt, et sa raison.** Zéro tant que la machine tourne ;
/// sinon un nombre qui dit **pourquoi** elle s'est arrêtée. Il s'appelait
/// `HALT_SLOT` quand il ne portait que le `hlt` ; il en porte deux, donc ce
/// nom-là mentait.
///
/// **Pourquoi un témoin plutôt qu'un refus.** `hlt` faisait refuser la région
/// **entière**, et une région est refusée en entier : les instructions qui la
/// précèdent ne s'exécutaient pas non plus. C'est ce qui arrêtait la quatrième
/// région d'un vrai noyau, sur le `cli; hlt; jmp -2` que `head_64.S` place au
/// bout de son chemin d'erreur — un chemin dont rien ne dit que le noyau
/// l'emprunte.
///
/// **Et ce n'est pas un bouchon complaisant.** Le module ne feint pas d'attendre
/// une interruption : il pose ce témoin et rend la main, comme le fait déjà une
/// faute de page. L'hôte lit le témoin et **nomme** l'arrêt. Dire « je sais
/// traduire ce code, et si l'exécution y arrive je n'ai rien pour la
/// réveiller » est plus vrai que dire « je ne sais pas le traduire ».
///
/// **RIP est posé après le `hlt`**, comme sur le silicium : une interruption y
/// reprend à l'instruction suivante. Laisser RIP sur le `hlt` ferait
/// re-exécuter l'arrêt le jour où la délivrance existera.
pub const STOP_SLOT: usize = FAULT_SLOT + 1;

/// La machine a exécuté un `hlt`, et rien ne peut la réveiller.
pub const STOP_HALTED: u64 = 1;

/// Un sélecteur **non nul** est arrivé dans FS ou GS. Le nul ne lit aucun
/// descripteur et se produit ; celui-ci en demanderait un, et la table
/// n'existe pas. S'arrêter en le nommant vaut mieux que ranger le sélecteur
/// sans base : le noyau lirait alors à une adresse fausse, loin de la cause.
pub const STOP_SELECTOR: u64 = 2;

/// **`lkgs` a été atteinte.** Elle charge la base GS du noyau depuis un
/// sélecteur, donc depuis un descripteur, et la table n'existe pas. RIP est
/// posé **sur** l'instruction : rien ne la reprendra, et c'est elle qu'il faut
/// montrer. Le noyau Alpine ne l'exécute que si CPUID annonce `LKGS`, ce que
/// `cpuid` n'annonce pas ; ce témoin dit que la promesse a été rompue, pas
/// qu'une traduction manque.
pub const STOP_KERNEL_GS: u64 = 3;

/// **Un appel à l'hyperviseur a été atteint** — `vmcall` ou `vmmcall` — et
/// cette machine n'en a pas : personne pour répondre. RIP est posé **sur**
/// l'instruction. Le noyau Alpine ne l'exécute que si CPUID annonce la
/// signature VMware, ce que `cpuid` n'annonce pas ; ce témoin dit que la
/// promesse a été rompue, pas qu'une traduction manque.
pub const STOP_HYPERVISOR: u64 = 4;

/// **`invpcid` a été atteinte.** Elle purge le tampon par identifiant de
/// contexte, et cette machine n'a pas de PCID : `cpuid` n'annonce ni `PCID`
/// ni `INVPCID`, et le noyau Alpine ne l'exécute que si les deux sont promis.
/// RIP est posé **sur** l'instruction ; ce témoin dit que la promesse a été
/// rompue, pas qu'une traduction manque.
pub const STOP_PCID: u64 = 5;

/// **`lldt` avec un sélecteur non nul a été atteinte.** Une table de
/// descripteurs locale se trouve par un descripteur de la GDT, et aucune
/// table n'est lue derrière les sélecteurs de cette machine. Le sélecteur
/// **nul** passe sans témoin : il ne charge rien, et c'est ce que fait le
/// noyau Alpine, qui n'a pas de LDT. RIP est posé **sur** l'instruction.
pub const STOP_LDT: u64 = 6;

/// **Une écriture dans un registre de débogage qui armerait quelque chose.**
/// Cette machine n'a pas de points d'arrêt matériels ; écrire l'état de repos
/// — ce que fait `cpu_init` pour les effacer — passe sans témoin, et toute
/// autre valeur s'arrête ici, RIP **sur** l'instruction : un point d'arrêt
/// posé qui ne déclencherait jamais serait un mensonge silencieux.
pub const STOP_DEBUG: u64 = 7;

/// **Ce que chaque registre de débogage rend au repos**, et la seule valeur
/// qu'une écriture peut y poser sans s'arrêter : zéro pour les quatre
/// adresses, les bits réservés toujours à un de DR6, le bit 10 toujours à un
/// de DR7. Une écriture est comparée hors de ces bits : écrire zéro dans DR7
/// le laisse à `0x400`, comme sur le silicium.
pub fn debug_register_at_rest(which: u8) -> u64 {
    match which {
        6 => 0xffff_0ff0,
        7 => 0x400,
        _ => 0,
    }
}

/// **Un registre spécifique au modèle que cette machine ne modélise pas**, et
/// son numéro dans les trente-deux bits bas. Le numéro vit dans ECX, une
/// valeur d'exécution : le traducteur ne peut pas le connaître, donc c'est le
/// module qui le pose dans le témoin au moment où il le lit. RIP reste **sur**
/// l'instruction. Avant ce témoin, la machine rendait la main sans rien dire,
/// et l'hôte ne voyait qu'un noyau « sur place » : il a fallu désassembler
/// `syscall_init` pour apprendre que c'était `MSR_STAR`.
pub const STOP_MSR: u64 = 1 << 32;

/// **Une interruption logicielle, avec son vecteur dans les huit bits bas.**
/// `int3` et `int n` posent `STOP_INTERRUPT | vecteur` et rendent la main, RIP
/// déjà posé **après** l'instruction : c'est un appel, et c'est là que
/// l'`iretq` du gestionnaire reprend. L'hôte délivre le vecteur par le même
/// chemin qu'une faute de page — sans code d'erreur — puis efface le témoin.
///
/// Un témoin plutôt qu'une globale de plus : les emplacements sont recopiés
/// dans `web/host.js` et `WebKitBench.swift`, et trois modules sont épinglés
/// en base64 ; une globale coûterait tout ça pour un nombre qui tient dans le
/// témoin qui existe.
pub const STOP_INTERRUPT: u64 = 0x100;

/// **`IA32_EFER`, le quatrième MSR modélisé.**
///
/// C'est le premier qu'un vrai noyau ait réclamé : Alpine s'arrêtait à
/// `secondary_startup_64_no_verify + 308`, sur `rdmsr` avec `0xc0000080` dans
/// ECX, faute qu'il soit dans la liste. Le noyau ne le lit pas par curiosité —
/// il le lit, y pose SCE et NX, et le réécrit.
///
/// **Il lui faut donc un vrai registre, et une valeur initiale vraie.** Voir
/// `web/host.js`, qui la pose : la machine est en long mode, donc LME et LMA.
/// À zéro, l'invité rangerait un EFER prétendant que la machine n'est pas en
/// 64 bits, et le relirait plus tard pour décider — entre autres — s'il peut
/// poser le bit NX dans ses tables de pages.
///
/// **Ce que ce modèle ne fait pas** : rien ne lit ces bits. Comme pour les
/// registres de contrôle, accepter une écriture dit « on la range », pas « on
/// l'applique ».
pub const EFER_SLOT: usize = STOP_SLOT + 1;

/// Le numéro que l'invité met dans ECX pour désigner EFER.
pub const MSR_EFER: u64 = 0xc000_0080;

/// **La valeur qu'EFER porte au démarrage.** LME (bit 8) et LMA (bit 10) : le
/// long mode est demandé et actif, ce qui est vrai de cette machine — elle
/// n'exécute rien d'autre. `web/host.js` la pose, parce que les globales sont
/// **importées** : leur valeur de départ appartient à l'hôte, pas au module.
pub const EFER_LONG_MODE: u64 = (1 << 8) | (1 << 10);

/// **Le registre de tâche : le sélecteur que `ltr` a chargé.**
///
/// Le noyau Alpine l'exécute dans `cpu_init_exception_handling`, avec `0x40`
/// — le sélecteur de son TSS —, et c'est le premier mur depuis la retpoline
/// qui n'est pas atteint statiquement mais **exécuté**. Il lui faut donc une
/// case, comme aux six segments : un nombre que l'invité range, seize bits,
/// et qui part à zéro — « aucun chargeur n'est passé ici ».
///
/// **Ce que ce nombre n'est pas** : aucun descripteur n'est lu derrière lui.
/// La délivrance de `web/host.js` dit toujours « cette machine n'a pas de
/// TSS » devant une porte à pile d'interruption ; ce que les piles IST feront
/// de ce sélecteur est une question de direction, posée quand elle sera
/// atteinte. Une globale coûte `host.js`, `WebKitBench.swift` et trois modules
/// épinglés — le prix a été pesé pour le témoin d'interruption, et refusé ;
/// ici c'est un registre que l'invité charge, pas un nombre de l'hôte.
pub const TASK_SLOT: usize = EFER_SLOT + 1;

/// **Les quatre registres de l'appel système**, dans l'ordre de leurs
/// numéros : STAR (les sélecteurs), LSTAR (la cible de `syscall` en mode
/// long), CSTAR (celle du mode de compatibilité), SYSCALL_MASK (les drapeaux
/// que `syscall` éteint). `syscall_init` les écrit tous les quatre, et c'est
/// sur le premier que le noyau Alpine s'arrêtait « sur place ».
///
/// **Ce que ces nombres ne sont pas** : rien ne les lit. `syscall` n'est pas
/// produite ; accepter l'écriture dit « on la range », pas « on l'applique »,
/// comme pour les registres de contrôle. Le jour où `syscall` sera produite,
/// c'est ici qu'elle prendra sa cible.
pub const SYSCALL_SLOT: usize = TASK_SLOT + 1;
pub const SYSCALL_COUNT: usize = 4;

/// Le nombre de globales que le module déclare et exporte.
pub const GLOBAL_COUNT: usize = SYSCALL_SLOT + SYSCALL_COUNT;

/// Les numéros des quatre registres de l'appel système, dans l'ordre des cases.
pub const MSR_STAR: u64 = 0xc000_0081;
pub const MSR_LSTAR: u64 = 0xc000_0082;
pub const MSR_CSTAR: u64 = 0xc000_0083;
pub const MSR_SYSCALL_MASK: u64 = 0xc000_0084;

/// CR0.PG — le bit qui allume la pagination.
pub const PAGING_BIT: u64 = 1 << 31;

/// Le bit de présence d'une entrée de table de pages. Sans lui, tout le reste
/// de l'entrée appartient au système d'exploitation et ne veut rien dire.
pub const ENTRY_PRESENT: u64 = 1;

/// « Cette entrée est une grande page et le parcours s'arrête ici. »
pub const ENTRY_HUGE: u64 = 1 << 7;

/// Les bits d'adresse d'une entrée : de 12 à 51.
pub const ENTRY_FRAME: u64 = 0x000F_FFFF_FFFF_F000;

/// **Le tampon de traduction, et où il vit.**
///
/// Direct, une case par page, l'étiquette étant l'adresse de page **plus un**
/// pour que zéro veuille dire « vide » — sans quoi la page zéro passerait pour
/// déjà là, et l'hôte devrait empoisonner le tampon au démarrage.
///
/// Il vit **au-dessus de la RAM déclarée**, juste après la correspondance
/// adresse → indice. C'est la place que `Module::confined` a ouverte : l'hôte
/// fournit une mémoire plus grande que le module ne déclare, et le repliement
/// par `et` met tout ce qui est au-dessus hors de portée de l'invité.
pub const TLB_SLOTS: u32 = 4096;

/// Ce qu'occupe une case : l'étiquette (huit octets) puis la trame (quatre), et
/// quatre de rembourrage pour que la suivante reste alignée sur huit.
pub const TLB_ENTRY: u32 = 16;

/// Ce que le tampon occupe, en pages. Exactement une, par construction.
pub const TLB_PAGES: u32 = TLB_SLOTS * TLB_ENTRY / 65536;

/// **Le nom sous lequel un module lié importe la table de l'hôte.** Les blocs
/// de toutes les régions y vivent ensemble, ce qui est la condition pour qu'un
/// `call_indirect` passe d'une région à l'autre sans repasser par l'hôte.
pub const TABLE_IMPORT: &str = "blocks";

/// **Le nombre de cases de la correspondance adresse → indice.** Une puissance
/// de deux, parce que le hachage prend les bits hauts d'un produit et qu'il
/// faut pouvoir les tronquer par un décalage.
pub const TABLE_SLOTS: u32 = 1 << 16;

/// Ce qu'occupe une case : l'adresse rangée (huit octets) puis l'indice absolu
/// dans la table de blocs (quatre), et quatre de rembourrage pour que la
/// suivante reste alignée sur huit.
pub const TABLE_ENTRY: u32 = 16;

/// Ce que la correspondance occupe, en pages. Un module qui la lit le déclare
/// dans son minimum : ainsi un hôte qui ne l'a pas posée **ne démarre pas**,
/// au lieu de piéger au premier saut vers une autre région — et un piège
/// WebAssembly est sans retour.
pub const TABLE_PAGES: u32 = TABLE_SLOTS * TABLE_ENTRY / 65536;

/// **Le multiplicateur, et pourquoi les bits hauts.** `scripts/wasm-table-probe.ts`
/// a montré que prendre les bits *bas* d'un produit de Knuth ne mélange rien :
/// sur 16384 adresses espacées de seize octets, la plupart se disputaient les
/// mêmes cases, parce que les bits bas d'une adresse alignée ne portent aucune
/// information. Les bits **hauts** d'un produit par une constante impaire, eux,
/// dépendent de tous les bits de l'entrée.
///
/// Il est **public** parce qu'il fait partie du contrat entre l'hôte et le
/// module au même titre que `table_slot` : un hôte écrit dans une autre langue
/// doit pouvoir refaire le calcul, et un test doit pouvoir vérifier que c'est
/// bien ce nombre-là qui est gravé dans les octets.
pub const TABLE_MIX: u64 = 0x9E37_79B9_7F4A_7C15;

/// **Pourquoi l'émetteur a refusé une région, et surtout : faut-il redemander ?**
///
/// Un refus n'a pas une cause mais deux, et l'hôte ne les traite pas pareil.
/// Une instruction que le décodeur ne connaît pas est un refus **franc** :
/// redemander avec plus d'octets ne changera rien. Une instruction *coupée par
/// le bord* des octets fournis n'en est pas un : elle se décoderait très bien
/// avec la suite. Les confondre coûte cher dans les deux sens — soit la vue
/// abandonne une région traduisible, soit elle redemande pour rien à chaque
/// vrai refus.
///
/// Jusqu'ici personne ne les distinguait à l'exécution. `examples/coverage.rs`
/// le fait, mais **après coup et par un détour** : il rejuge l'octet fautif
/// avec tout le reste du fichier, ce qu'une vue n'a pas sous la main.
///
/// **Le seuil de quinze octets est mesuré, pas déduit.** Une instruction
/// x86-64 fait au plus quinze octets, donc un échec à quinze octets ou plus du
/// bord ne peut pas être une coupe : c'est la borne théorique. Ce qui la rend
/// sûre est la distribution réelle — sur les 3673 abandons du noyau Alpine, il
/// n'y en a **aucun** entre douze et dix-neuf octets du bord : 316 tout près
/// (un à onze), 3357 loin (vingt ou plus). Le seuil tombe dans un trou, pas au
/// bord d'un précipice.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refused {
    /// **La première instruction déjà s'est arrêtée tout près du bord** : à
    /// `at`, il restait moins de quinze octets, et rien de complet ne la
    /// précède. Ça peut être une coupe. La vue redemande la même région avec
    /// davantage d'octets, et n'a besoin de le faire que là.
    ///
    /// Ça *peut* aussi être une vraie instruction inconnue qui se trouvait par
    /// hasard près du bord ; elle coûte alors un aller-retour de plus, et se
    /// fait refuser franchement au second essai.
    ///
    /// **Une coupe après une instruction complète n'est plus un refus.** La
    /// région se traduit jusqu'à la coupe, le bloc coupé rend la main sur
    /// elle, et l'hôte demande la suite en arrivant là — avec une fenêtre
    /// entière devant. C'est ce qui a levé le mur de `setup_arch` : seize
    /// kibioctets de blocs complets refusés pour un octet à cheval.
    MayBeCut { at: usize },

    /// **Une instruction que le décodeur ne lit pas**, à `at`, avec toute la
    /// place qu'il lui fallait. Redemander n'apporterait rien.
    CannotDecode { at: usize },

    /// **Une instruction que le décodeur lit mais que l'émetteur ne sait pas
    /// traduire**, à `at`. Un refus franc lui aussi.
    ///
    /// **Ce cas ne s'est jamais produit** sur le noyau Alpine — zéro sur 3673
    /// abandons, tous au décodage. Il est ici parce que le chemin existe dans
    /// le code, pas parce qu'il est fréquent : ce que le décodeur accepte,
    /// l'émetteur le traduit. Les instructions qui manquent encore — `rdtsc`,
    /// les MSR, le groupe 7 — manquent au **décodeur**, faute d'oracle, et
    /// c'est un modèle qu'il leur faut, pas un bras d'émission.
    CannotTranslate { at: usize },

    /// Rien de traduisible depuis cette entrée : le premier octet ne commence
    /// aucun bloc.
    NothingAtEntry,

    /// La RAM demandée n'est pas une puissance de deux, donc le repli ne
    /// décrirait pas un intervalle.
    RamIsNotAPowerOfTwo(u32),
}

/// **Ce qu'une instruction x86-64 peut occuper au plus.** En deçà de ça du
/// bord, un échec de décodage peut n'être qu'une coupe ; au-delà, non.
const REACH: usize = 15;

/// **Où l'hôte doit poser la correspondance** : juste au-dessus de la RAM que
/// l'invité peut atteindre. C'est tout l'intérêt du confinement — l'invité ne
/// peut pas la corrompre, et il n'a fallu pour ça aucune seconde mémoire.
#[must_use]
pub fn table_base(pages: u32) -> u32 {
    pages * 65536
}

/// **Où l'hôte doit poser le tampon de traduction** : juste au-dessus de la
/// correspondance, donc encore plus haut que la RAM de l'invité. Même raison,
/// même garantie — le repliement par `et` le met hors de portée de l'invité.
#[must_use]
pub fn tlb_base(pages: u32) -> u32 {
    table_base(pages) + TABLE_PAGES * 65536
}

/// **Combien de pages de 64 Kio un hôte doit allouer pour un module confiné.**
///
/// La RAM de l'invité, plus la correspondance adresse → indice, plus le tampon
/// de traduction. Le module **déclare** ce nombre comme minimum : un hôte qui
/// en fournit moins ne démarre pas, au lieu de piéger plus tard sur une adresse
/// qu'il croyait sienne.
///
/// **Pourquoi une fonction et pas une somme sur place.** Il y a eu deux
/// tranches où la somme a changé — la correspondance, puis le tampon — et à
/// chaque fois il a fallu retrouver tous les hôtes qui l'écrivaient à la main.
/// La seconde fois, `examples/resolved.rs` a été oublié : il allouait
/// `pages + TABLE_PAGES`, ne s'instanciait plus, imprimait « le pilote a
/// échoué » et **sortait avec zéro**. Personne ne l'a vu pendant toute une
/// série de tranches. Une somme écrite à cinq endroits est cinq occasions
/// d'en oublier un ; celle-ci est écrite ici.
#[must_use]
pub fn host_pages(guest_pages: u32) -> u32 {
    guest_pages + TABLE_PAGES + TLB_PAGES
}

/// **La case d'une adresse, et c'est le point d'accord.** L'hôte remplit la
/// correspondance avec cette fonction, le module la relit avec le même calcul
/// gravé dans ses octets. S'ils divergent, rien n'est jamais trouvé et le
/// module se contente de rendre la main — un défaut silencieux, qui ne coûte
/// que de la vitesse. C'est pourquoi un test les compare.
#[must_use]
pub fn table_slot(address: u64) -> u32 {
    (address.wrapping_mul(TABLE_MIX) >> (64 - TABLE_SLOTS.trailing_zeros())) as u32
}

/// Le nombre de pages de RAM invitée que le module déclare. Assez pour couvrir
/// la fenêtre de données du corpus matériel, qui vit à 0x30001000.
pub const GUEST_PAGES: u32 = 0x3001;

/// **La boucle que les bancs mesurent, écrite une seule fois.**
///
/// ```text
/// 1: addq %rax, %rdx
///    xorq %rcx, %rbx
///    addq %rdx, %rax
///    subq $1, %rsi
///    jnz 1b
/// ```
///
/// Cinq instructions, parce que c'est la taille moyenne d'un bloc de base
/// relevée en désassemblant le noyau Alpine : une boucle d'une seule
/// instruction mesurerait le coût du saut, pas celui du calcul. Les quatre
/// premières posent des drapeaux que personne ne lit, sauf la dernière — le cas
/// où les drapeaux paresseux de l'interpréteur rapportent, et où le module doit
/// les calculer.
///
/// **Elle vit ici, et pas dans le banc, parce que trois programmes la
/// mesurent** : l'exemple `speed`, la sonde WebKit de l'application, et le test
/// qui épingle l'une sur l'autre. Trois copies dériveraient, et l'iPhone
/// rendrait alors un chiffre qu'on croirait comparable à celui de la CI.
pub const BENCH_LOOP: [u8; 15] = [
    0x48, 0x01, 0xc2, // addq %rax, %rdx
    0x48, 0x31, 0xcb, // xorq %rcx, %rbx
    0x48, 0x01, 0xd0, // addq %rdx, %rax
    0x48, 0x83, 0xee, 0x01, // subq $1, %rsi
    0x75, 0xf1, // jnz 1b
];

/// **La seconde boucle du banc, celle qui touche la mémoire.**
///
/// ```text
/// 1: movq (%rdi), %rax
///    movq %rax, (%rdi)
///    subq $1, %rsi
///    jnz 1b
/// ```
///
/// **Pourquoi il en fallait une seconde.** `BENCH_LOOP` est cinq instructions
/// de registres, sans un seul accès mémoire. Or tout ce que la forme confinée
/// ajoute — le test du bit de pagination, le tampon de traduction consulté en
/// ligne, la vérification de faute — est **sur les accès mémoire**. Chronométrer
/// la forme confinée sur `BENCH_LOOP` rendrait « aucune différence » : vrai, et
/// sans le moindre rapport avec ce que le bureau fera tourner. Les deux boucles
/// ensemble bornent le coût par le bas et par le haut.
///
/// **Une lecture et une écriture**, pas seulement une lecture : `guest()` est
/// traversée par `load_at` et par `store_at`, et rien ne garantit que les deux
/// coûtent la même chose.
///
/// **La densité est délibérément haute** — deux accès pour quatre instructions
/// — et ce n'est pas ce que fait du vrai code. C'est voulu : cette boucle
/// mesure le **coût d'un accès**, pas celui d'un noyau. Ce que la densité du
/// vrai code vaut n'est écrit nulle part dans ce dépôt, et c'est pourquoi ces
/// bancs rendent des nanosecondes par accès plutôt qu'un pourcentage.
///
/// `%rdi` vaut zéro au départ : l'adresse est donc en RAM, la même à chaque
/// tour, et ce que la boucle lit est ce qu'elle vient d'écrire. Déterministe,
/// ce qu'un banc doit être.
pub const BENCH_MEMORY_LOOP: [u8; 12] = [
    0x48, 0x8b, 0x07, // movq (%rdi), %rax
    0x48, 0x89, 0x07, // movq %rax, (%rdi)
    0x48, 0x83, 0xee, 0x01, // subq $1, %rsi
    0x75, 0xf4, // jnz 1b
];

/// Combien d'instructions un tour de `BENCH_MEMORY_LOOP` exécute.
pub const BENCH_MEMORY_PER_TURN: u64 = 4;

/// Combien d'accès mémoire un tour de `BENCH_MEMORY_LOOP` fait : une lecture,
/// une écriture.
pub const BENCH_MEMORY_ACCESSES_PER_TURN: u64 = 2;

/// **La RAM déclarée quand un banc mesure la forme confinée**, en pages de
/// 64 Kio — 0x4000 pages, soit un gibioctet.
///
/// Une puissance de deux, parce que le repliement est un masque et qu'un
/// masque ne borne rien d'autre. Et pas moins : la région du banc vit à
/// `BENCH_BASE`, 0x3000_0000, donc la RAM doit au moins l'atteindre, et la
/// puissance de deux suivante est 0x4000.
///
/// **Elle vit ici pour la même raison que la boucle.** Trois programmes la
/// posent — `examples/speed.rs`, `examples/bench-module.rs` et la sonde WebKit
/// de l'application — et trois copies dériveraient sans bruit : l'iPhone
/// rendrait alors un chiffre qu'on croirait comparable à celui de la CI.
///
/// Ce que l'hôte doit **allouer** n'est pas ce nombre mais `host_pages()` de ce
/// nombre : la RAM, plus la correspondance adresse → indice, plus le tampon.
/// L'addition ne se refait jamais sur place.
pub const BENCH_CONFINED_PAGES: u32 = 0x4000;

/// L'adresse invitée où le banc charge la boucle. Elle n'est pas décorative :
/// l'émetteur y fige les adresses de retour et les sauts.
pub const BENCH_BASE: u64 = 0x3000_0000;

/// Combien d'instructions un tour de la boucle exécute.
pub const BENCH_PER_TURN: u64 = 5;

/// **Ce qu'un bloc rend à l'hôte, lu sans l'exécuter.**
///
/// `survey` compte ; ceci nomme. La différence a coûté une tranche : la
/// machine s'arrêtait sur une adresse, deux explications la rendaient toutes
/// les deux, et rien dans le dépôt ne savait dire laquelle — il fallait
/// relire l'émetteur et choisir. Un relevé qui dit, pour chaque bloc, où il
/// mène et par quelle instruction, remplace ce choix par une lecture.
///
/// Les décalages sont **relatifs à la région**, comme partout dans
/// `discover` : l'appelant qui veut des adresses ajoute la base.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Outline {
    /// Où le bloc commence.
    pub start: usize,
    /// Où il finit — le décalage juste après sa dernière instruction, qui est
    /// aussi l'adresse de reprise quand rien d'autre ne la décide.
    pub after: usize,
    /// Combien d'instructions il porte.
    pub steps: usize,
    /// L'instruction qui le termine. `None` quand le bloc s'arrête au bord de
    /// la région sans terminateur — le cas qui fait reprendre à `after`.
    pub ends: Option<Op>,
    /// La cible statique du terminateur, quand il en a une : `jmp`, `call` et
    /// les sauts conditionnels. `None` pour `ret`, les formes indirectes, et
    /// pour un bloc sans terminateur.
    pub target: Option<i64>,
    /// L'indice du bloc où la cible tombe, dans l'ordre de ce relevé. `None`
    /// quand elle sort de la région : le module rend alors la main.
    pub goes: Option<usize>,
}

/// Ce que `Module::survey` relève d'une région : sa taille, et les endroits
/// où elle rendra la main.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Survey {
    /// Blocs de base atteints depuis l'entrée.
    pub blocks: usize,
    /// Instructions traduites, tous blocs confondus.
    pub instructions: usize,
    /// Instructions qui rendent la main **à chaque fois**. Il n'en reste
    /// qu'une sorte : `ud2`. Le `rep` en faisait partie jusqu'à ce que sa
    /// boucle soit émise ; le compte est donc tombé, et c'était le but.
    pub always: usize,
    /// Les instructions de chaîne répétées. **Elles ne rendent plus la main** —
    /// elles restent comptées parce que ce sont les `memcpy` et les `memset`
    /// d'un noyau, et que leur densité dit ce que la boucle a rapatrié.
    pub repeats: usize,
    /// Instructions qui **peuvent** rendre la main : la cible n'est connue
    /// qu'à l'exécution, et le module ne sort que si elle lui est étrangère.
    pub perhaps: usize,
}

/// L'entier non signé à longueur variable de WebAssembly.
fn unsigned(value: u64, out: &mut Vec<u8>) {
    let mut rest = value;
    loop {
        let mut byte = (rest & 0x7f) as u8;
        rest >>= 7;
        if rest != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if rest == 0 {
            break;
        }
    }
}

/// L'entier **signé** à longueur variable. Le confondre avec le précédent est
/// la faute classique : `i64.const -1` encodé en non signé devient un nombre
/// énorme, et le module reste valide — donc faux en silence.
fn signed(value: i64, out: &mut Vec<u8>) {
    let mut rest = value;
    loop {
        let byte = (rest & 0x7f) as u8;
        rest >>= 7;
        let done = (rest == 0 && byte & 0x40 == 0) || (rest == -1 && byte & 0x40 != 0);
        out.push(if done { byte } else { byte | 0x80 });
        if done {
            break;
        }
    }
}

fn section(id: u8, body: Vec<u8>, out: &mut Vec<u8>) {
    out.push(id);
    unsigned(body.len() as u64, out);
    out.extend_from_slice(&body);
}

/// Les opcodes dont la traduction a besoin.
mod code {
    pub const CALL: u8 = 0x10;
    pub const END: u8 = 0x0b;
    pub const GLOBAL_GET: u8 = 0x23;
    pub const GLOBAL_SET: u8 = 0x24;
    /// Les accès à la mémoire linéaire — **la RAM de l'invité, adresse pour
    /// adresse**. Les variantes courtes étendent par zéro ; l'extension de
    /// signe, quand une instruction la demande, se fait après coup, parce que
    /// x86 la demande depuis la largeur de la source et pas depuis huit octets.
    pub const I32_CONST: u8 = 0x41;
    pub const I64_LOAD: u8 = 0x29;
    pub const I64_LOAD8_U: u8 = 0x31;
    pub const I64_LOAD16_U: u8 = 0x33;
    pub const I64_LOAD32_U: u8 = 0x35;
    pub const I64_STORE: u8 = 0x37;
    pub const I64_STORE8: u8 = 0x3c;
    pub const I64_STORE16: u8 = 0x3d;
    pub const I64_STORE32: u8 = 0x3e;
    /// Une adresse WebAssembly est un `i32`. L'adresse x86 est calculée sur
    /// soixante-quatre bits, donc elle se tronque — ce qui est juste tant que
    /// la RAM invitée tient sous quatre gigaoctets, et faux au-delà. La
    /// tranche qui dépassera cette limite devra passer en mémoire 64 bits.
    pub const I32_WRAP_I64: u8 = 0xa7;
    /// Le `et` de trente-deux bits, qui replie une adresse invitée dans sa RAM.
    pub const I32_AND: u8 = 0x71;
    /// Le `ou` et le « est-ce zéro » de trente-deux bits. Une comparaison
    /// `i64.eq` rend un `i32` : réunir plusieurs comparaisons se fait donc
    /// dans cette largeur-là, pas dans celle des valeurs comparées.
    pub const I32_OR: u8 = 0x72;
    pub const I32_EQZ: u8 = 0x45;
    pub const I32_ADD: u8 = 0x6a;
    pub const I32_MUL: u8 = 0x6c;
    pub const I32_LOAD: u8 = 0x28;
    pub const I64_CONST: u8 = 0x42;
    pub const I64_EQZ: u8 = 0x50;
    pub const I64_LT_U: u8 = 0x54;
    pub const I64_ADD: u8 = 0x7c;
    pub const I64_SUB: u8 = 0x7d;
    pub const I64_AND: u8 = 0x83;
    pub const I64_OR: u8 = 0x84;
    pub const I64_XOR: u8 = 0x85;
    pub const I64_SHL: u8 = 0x86;
    pub const I64_SHR_U: u8 = 0x88;
    pub const I64_POPCNT: u8 = 0x7b;
    pub const I64_CLZ: u8 = 0x79;
    pub const I64_CTZ: u8 = 0x7a;
    pub const I64_EXTEND_I32_U: u8 = 0xad;
    pub const I64_SHR_S: u8 = 0x87;
    pub const I64_NE: u8 = 0x52;
    pub const I64_LE_U: u8 = 0x58;
    /// Le reste d'une division non signée. C'est ce qui ramène un compte de
    /// rotation à l'intérieur de la largeur — tourner un octet de neuf crans
    /// revient à le tourner d'un.
    pub const I64_REM_U: u8 = 0x82;
    pub const I64_EQ: u8 = 0x51;
    pub const I64_LT_S: u8 = 0x53;
    pub const I64_GT_S: u8 = 0x55;
    pub const I64_GT_U: u8 = 0x56;
    pub const I64_MUL: u8 = 0x7e;
    pub const I64_DIV_S: u8 = 0x7f;
    pub const I64_DIV_U: u8 = 0x80;
    pub const I64_REM_S: u8 = 0x81;
    /// `if` sans résultat, et `return`. Ce sont les deux qui permettent à un
    /// bloc de **rendre la main au milieu** — ce dont la division a besoin
    /// quand elle refuse de diviser.
    pub const BLOCK: u8 = 0x02;
    pub const LOOP: u8 = 0x03;
    pub const IF: u8 = 0x04;
    pub const BRANCH: u8 = 0x0c;
    pub const BRANCH_IF: u8 = 0x0d;
    pub const VOID: u8 = 0x40;
    pub const RETURN: u8 = 0x0f;
    /// `select` prend deux valeurs et une condition, et rend la première quand
    /// la condition est vraie. C'est ce qui permet de traduire « un compte nul
    /// ne change rien » **sans branchement** : on calcule tout, puis on choisit.
    pub const SELECT: u8 = 0x1b;
}

/// Un `cmpxchg` vu comme la comparaison qu'il porte : c'est sous cette forme
/// que la routine des drapeaux sait le lire.
fn as_compare(step: &Decoded) -> Decoded {
    Decoded {
        op: Op::Cmp,
        ..*step
    }
}

/// Un corps de fonction en cours d'écriture.
/// **Ce qui distingue les quatre façons de compiler une région.** Elles se
/// combinent — une région qui cherche dans la correspondance est forcément
/// liée *et* confinée — et les passer en trois booléens positionnels rendait
/// les appels illisibles.
#[derive(Default, Clone, Copy)]
struct Shape {
    /// L'emplacement des blocs dans la table de l'hôte, si elle est partagée.
    shared: Option<u32>,
    /// Le nombre de pages de RAM que l'invité peut atteindre, s'il est confiné.
    confine: Option<u32>,
    /// Le module cherche-t-il lui-même les adresses qu'il ne connaît pas ?
    lookup: bool,
}

/// **Les deux fonctions que l'hôte prête à chaque région.**
///
/// Un invité qui écrit un octet dans un port ne peut pas sortir de la région
/// pour ça : un retour de main coûte environ 190 ns, mesuré, et une console
/// écrit caractère par caractère. Un appel importé en coûte des dizaines.
/// C'est le choix de v86, et c'est celui-ci.
///
/// **Leur place décide de tout le reste.** Une fonction importée occupe le
/// début de l'espace d'indices : avec ces deux-là, le bloc zéro est la
/// fonction deux. Un oubli ne produirait pas une erreur de liaison — la table
/// pointerait les imports, du bon type, et la boucle appellerait `out` en
/// croyant exécuter un bloc.
const HOST_OUT: u32 = 0;
const HOST_IN: u32 = 1;
/// Le décalage que ces imports imposent à tout indice de fonction.
const HOST_IMPORTS: u32 = 2;

/// Les deux registres que le codage des entrées-sorties impose. La valeur est
/// toujours dans l'accumulateur ; le port des formes non immédiates est dans
/// DX. Nommés parce qu'un `2` nu, ici, ne se relit pas.
const RAX: u8 = 0;
const RCX: u8 = 1;
const RDX: u8 = 2;

#[derive(Default)]
struct Body {
    bytes: Vec<u8>,
    /// **Le masque qui enferme l'invité dans sa RAM**, ou `None` s'il n'y en a
    /// pas. Voir `Body::guest`.
    confine: Option<u32>,
    /// **L'indice de la fonction de marche**, quand le module en a une — donc
    /// quand il est confiné, puisque c'est le confinement qui ouvre la place
    /// où vivent les tables et le tampon. `None` rend `guest()` à sa forme
    /// d'avant la pagination, mot pour mot.
    walk: Option<u32>,
}

impl Body {
    /// **Le seul chemin par lequel une adresse invitée devient une adresse de
    /// mémoire linéaire.** Tout accès à la RAM de l'invité passe ici, et c'est
    /// ce qui rend le confinement possible : un seul endroit à changer, et
    /// aucun accès qui l'oublie.
    ///
    /// L'adresse arrive en `i64` — un registre invité, plus un déplacement.
    /// `i32.wrap_i64` la ramène aux trente-deux bits que WebAssembly adresse.
    /// Quand un masque est posé, un `i32.and` la replie dans la RAM : au-delà,
    /// l'invité retombe dedans au lieu d'atteindre ce qui vit au-dessus.
    ///
    /// **Ce que ça coûte, mesuré** : rien, et même un peu moins que rien —
    /// voir `Module::confined`, qui porte les chiffres.
    fn guest(&mut self) -> &mut Self {
        let (Some(walk), Some(mask)) = (self.walk, self.confine) else {
            // **Sans pagination possible, la forme d'avant, mot pour mot.**
            self.op(code::I32_WRAP_I64);
            if let Some(mask) = self.confine {
                self.bytes.push(code::I32_CONST);
                signed(i64::from(mask), &mut self.bytes);
                self.bytes.push(code::I32_AND);
            }
            return self;
        };
        let tlb = tlb_base((mask + 1) / 65536);
        let (va, vpn, slot) = (TRANSLATE_SLOT, TRANSLATE_SLOT + 1, TRANSLATE_SLOT + 2);
        let fold = |b: &mut Self| {
            b.bytes.push(code::I32_CONST);
            signed(i64::from(mask), &mut b.bytes);
            b.bytes.push(code::I32_AND);
        };

        // L'adresse est rangée : le repli comme le tampon la relisent, et
        // WebAssembly n'a pas de quoi dupliquer une valeur.
        self.bytes.push(code::GLOBAL_SET);
        unsigned(va as u64, &mut self.bytes);

        // CR0.PG éteint ? C'est l'état d'un processeur au démarrage.
        self.load(Module::control_slot(0))
            .constant(PAGING_BIT)
            .op(code::I64_AND)
            .op(code::I64_EQZ);
        self.op(code::IF).op(0x7f); // if (result i32)
        self.load(va).op(code::I32_WRAP_I64);
        fold(self);
        self.op(0x05); // else

        // **Le tampon, consulté en ligne.** Son coût a été mesuré avant d'être
        // écrit : un dixième à un demi de nanoseconde par accès tant qu'il
        // répond — voir `docs/DEMARRAGE.md`.
        self.store(vpn, |b| {
            b.load(va).constant(12).op(code::I64_SHR_U);
        });
        self.store(slot, |b| {
            b.load(vpn)
                .constant(u64::from(TLB_SLOTS - 1))
                .op(code::I64_AND)
                .constant(u64::from(TLB_ENTRY))
                .op(code::I64_MUL)
                .constant(u64::from(tlb))
                .op(code::I64_ADD);
        });
        self.load(slot).op(code::I32_WRAP_I64);
        self.access(code::I64_LOAD, 0);
        // L'étiquette est le numéro de page **plus un** : zéro veut dire vide,
        // sans quoi la page zéro passerait pour déjà là.
        self.load(vpn)
            .constant(1)
            .op(code::I64_ADD)
            .op(code::I64_EQ);
        self.op(code::IF).op(0x7f);
        self.load(slot).op(code::I32_WRAP_I64);
        self.access(code::I64_LOAD32_U, 8);
        self.op(code::I32_WRAP_I64);
        self.op(0x05); // else
        self.load(va).call(walk);
        self.op(code::END);
        // La trame, plus le décalage dans la page.
        self.load(va).op(code::I32_WRAP_I64);
        self.bytes.push(code::I32_CONST);
        signed(0xFFF, &mut self.bytes);
        self.op(code::I32_AND).op(code::I32_OR);
        self.op(code::END);

        // **Le contrôle de faute, en ligne et avant l'accès.** L'instruction
        // fautive n'a alors rien fait, ce qui est la seule façon de la rejouer.
        // Rendre un indice de bloc négatif est ce que fait déjà chaque fin de
        // région : la boucle de répartition rend la main à l'hôte.
        self.load(FAULT_SLOT).op(code::I64_EQZ).op(code::I32_EQZ);
        self.op(code::IF).op(code::VOID);
        self.bytes.push(code::I32_CONST);
        signed(-1, &mut self.bytes);
        self.op(code::RETURN);
        self.op(code::END);
        self
    }

    fn op(&mut self, opcode: u8) -> &mut Self {
        self.bytes.push(opcode);
        self
    }

    fn local_get(&mut self, index: u32) -> &mut Self {
        self.bytes.push(0x20);
        unsigned(u64::from(index), &mut self.bytes);
        self
    }

    fn local_set(&mut self, index: u32) -> &mut Self {
        self.bytes.push(0x21);
        unsigned(u64::from(index), &mut self.bytes);
        self
    }

    fn local_tee(&mut self, index: u32) -> &mut Self {
        self.bytes.push(0x22);
        unsigned(u64::from(index), &mut self.bytes);
        self
    }

    /// **Un accès à la mémoire linéaire, sans passer par `guest()`.**
    ///
    /// C'est ce dont la marche a besoin : une entrée de table porte une adresse
    /// **physique**, et la faire traduire serait une récursion sans fond.
    /// L'alignement annoncé est nul — le module n'exige rien.
    fn access(&mut self, opcode: u8, offset: u32) -> &mut Self {
        self.bytes.push(opcode);
        self.bytes.push(0);
        unsigned(u64::from(offset), &mut self.bytes);
        self
    }

    /// Une constante de trente-deux bits. WebAssembly la lit en LEB **signé**,
    /// mais une adresse s'y interprète en non signé : réinterpréter le motif
    /// suffit, et ça couvre les quatre gigaoctets.
    fn constant32(&mut self, value: u32) -> &mut Self {
        self.bytes.push(code::I32_CONST);
        signed(i64::from(value as i32), &mut self.bytes);
        self
    }

    /// **L'adresse, en mémoire linéaire, de la case où l'adresse invitée
    /// courante serait rangée.** Le même calcul que `table_slot`, gravé dans
    /// les octets du module : c'est là que l'hôte et lui doivent tomber
    /// d'accord, et un test les compare pour ça.
    fn entry(&mut self, base: u32) -> &mut Self {
        self.load(RIP_SLOT)
            .constant(TABLE_MIX)
            .op(code::I64_MUL)
            .constant(u64::from(64 - TABLE_SLOTS.trailing_zeros()))
            .op(code::I64_SHR_U)
            .op(code::I32_WRAP_I64)
            .constant32(TABLE_ENTRY)
            .op(code::I32_MUL)
            .constant32(base)
            .op(code::I32_ADD)
    }

    fn constant(&mut self, value: u64) -> &mut Self {
        self.bytes.push(code::I64_CONST);
        signed(value as i64, &mut self.bytes);
        self
    }

    /// Appeler une fonction par son indice. Les seules qu'un bloc appelle
    /// directement sont les deux que l'hôte importe : `HOST_OUT` et `HOST_IN`.
    fn call(&mut self, function: u32) -> &mut Self {
        self.bytes.push(code::CALL);
        unsigned(u64::from(function), &mut self.bytes);
        self
    }

    /// Lire une globale : un registre invité, RFLAGS, ou un emplacement de
    /// travail.
    fn load(&mut self, slot: usize) -> &mut Self {
        self.bytes.push(code::GLOBAL_GET);
        unsigned(slot as u64, &mut self.bytes);
        self
    }

    /// Écrire une globale. Contrairement à un `i64.store`, il n'y a pas
    /// d'adresse à pousser d'abord : la valeur seule, puis l'indice.
    fn store(&mut self, slot: usize, value: impl FnOnce(&mut Body)) -> &mut Self {
        value(self);
        self.bytes.push(code::GLOBAL_SET);
        unsigned(slot as u64, &mut self.bytes);
        self
    }

    fn scratch(index: usize) -> usize {
        SCRATCH_SLOT + index
    }

    /// Pousser l'adresse effective, en `i32`, prête pour un accès mémoire.
    fn address(&mut self, address: &Address) -> &mut Self {
        self.wide_address(address);
        self.guest()
    }

    /// **La même adresse, laissée en `i64`.** La chaîne de bits en a besoin
    /// entière : elle lui ajoute un déplacement de mot **signé**, calculé à
    /// l'exécution, et tronquer avant cette addition la ferait déborder dans
    /// les trente-deux bits bas.
    fn wide_address(&mut self, address: &Address) -> &mut Self {
        self.constant(address.displacement as u64);
        // **La base du segment, lue à l'exécution.** Elle ne peut pas être
        // repliée dans le déplacement : la région est compilée une fois, et
        // l'hôte peut poser une autre base entre deux entrées.
        if address.gs {
            self.load(GS_SLOT).op(code::I64_ADD);
        }
        if let Some(base) = address.base {
            self.load(base as usize).op(code::I64_ADD);
        }
        if let Some(index) = address.index {
            self.load(index as usize);
            self.constant(u64::from(address.scale.trailing_zeros()))
                .op(code::I64_SHL);
            self.op(code::I64_ADD);
        }
        self
    }

    /// **Lire la mémoire à une adresse déjà calculée**, gardée dans une
    /// globale de travail. La chaîne de bits ne peut pas passer par `Address` :
    /// son adresse dépend d'un registre lu à l'exécution.
    fn load_at(&mut self, slot: usize, width: Width) -> &mut Self {
        self.load(slot).guest();
        self.op(match width {
            Width::Byte => code::I64_LOAD8_U,
            Width::Word => code::I64_LOAD16_U,
            Width::Dword => code::I64_LOAD32_U,
            Width::Qword => code::I64_LOAD,
        });
        self.bytes.push(0);
        self.bytes.push(0);
        self
    }

    /// Et l'écriture qui lui répond.
    fn store_at(&mut self, slot: usize, width: Width, value: impl FnOnce(&mut Body)) -> &mut Self {
        self.load(slot).guest();
        value(self);
        self.op(match width {
            Width::Byte => code::I64_STORE8,
            Width::Word => code::I64_STORE16,
            Width::Dword => code::I64_STORE32,
            Width::Qword => code::I64_STORE,
        });
        self.bytes.push(0);
        self.bytes.push(0);
        self
    }

    /// Lire la mémoire invitée à cette adresse, à cette largeur, **étendue par
    /// zéro**. L'extension de signe, quand `movsx` la demande, se fait après.
    fn load_memory(&mut self, address: &Address, width: Width) -> &mut Self {
        self.address(address);
        self.op(match width {
            Width::Byte => code::I64_LOAD8_U,
            Width::Word => code::I64_LOAD16_U,
            Width::Dword => code::I64_LOAD32_U,
            Width::Qword => code::I64_LOAD,
        });
        // Alignement zéro : le module n'exige rien, et un invité aligne ce
        // qu'il veut. Prétendre un alignement que l'invité ne tient pas ferait
        // refuser le module par le moteur.
        self.bytes.push(0);
        self.bytes.push(0);
        self
    }

    /// Écrire la mémoire invitée. **L'adresse d'abord, la valeur ensuite** —
    /// l'ordre de WebAssembly, et l'inverser produit un module que le moteur
    /// refuse.
    fn store_memory(
        &mut self,
        address: &Address,
        width: Width,
        value: impl FnOnce(&mut Body),
    ) -> &mut Self {
        self.address(address);
        value(self);
        self.op(match width {
            Width::Byte => code::I64_STORE8,
            Width::Word => code::I64_STORE16,
            Width::Dword => code::I64_STORE32,
            Width::Qword => code::I64_STORE,
        });
        self.bytes.push(0);
        self.bytes.push(0);
        self
    }
}

/// Le module émis pour un bloc.
pub struct Module;

impl Module {
    /// Émettre un module qui exécute ce bloc, ou `None` si une instruction
    /// n'est pas traduisible. **Refuser plutôt que produire du code faux** :
    /// un bloc à moitié traduit rendrait un état que rien ne distingue d'un
    /// état juste.
    /// **Compiler une région : tous les blocs atteignables depuis le début.**
    ///
    /// Un module WebAssembly n'a pas de saut arbitraire. Deux conceptions s'y
    /// prêtent, et le choix a été **mesuré** plutôt que débattu :
    ///
    /// - un module par bloc de base, l'hôte enchaînant : 62,6 ns par bloc sous
    ///   JavaScriptCore, dans sa meilleure forme (globale `i32`, tableau
    ///   dense). À 5,3 instructions par bloc — la moyenne relevée en
    ///   désassemblant le vrai noyau Alpine — c'est **85 MIPS de plafond**,
    ///   avant d'exécuter la moindre instruction. Moins que l'interpréteur
    ///   Rust. Tout l'intérêt de passer par WebKit s'évapore.
    /// - une fonction par bloc **dans le même module**, et la boucle de
    ///   répartition à l'intérieur : **2,05 ns par bloc**. Trente fois moins.
    ///
    /// C'est donc la seconde. Chaque bloc est une fonction qui rend l'indice du
    /// bloc suivant, ou -1 pour rendre la main ; `run` les enchaîne par un
    /// `call_indirect` dans une table, sous un budget de pas.
    ///
    /// `base` est l'adresse **de l'invité** où cette région est chargée. Elle
    /// n'est pas décorative : `call` empile une adresse de retour, et `ret` la
    /// relit. Compiler la région comme si elle vivait à zéro empilerait un
    /// nombre que rien, dans la mémoire de l'invité, ne désigne.
    pub fn region(bytes: &[u8], base: u64, entry: usize) -> Option<Vec<u8>> {
        Self::region_or_why(bytes, base, entry).ok()
    }

    /// **La même, mais elle dit pourquoi quand elle refuse.**
    ///
    /// Deux formes plutôt qu'une, parce que la plupart des appelants n'ont rien
    /// à faire de la raison : ils interprètent, et un `Option` se lit mieux
    /// qu'un `Result` dont on jette la moitié. Celle-ci est pour qui doit
    /// **décider quoi faire ensuite** — la vue du bureau, qui peut redemander
    /// la même région avec plus d'octets, et `examples/coverage.rs`, qui
    /// comptait les coupes par un détour.
    ///
    /// **La forme courte délègue à celle-ci**, et aucun test ne peut le tenir :
    /// lui faire appeler `build` directement ne change rien d'observable
    /// aujourd'hui — c'est le même appel. La délégation est là pour demain,
    /// quand cette fonction fera davantage : deux chemins séparés finiraient
    /// par ne plus refuser les mêmes régions. Un test compare tout de même les
    /// deux formes sur cinq cas, ce qui attrape la divergence si elle arrive.
    pub fn region_or_why(bytes: &[u8], base: u64, entry: usize) -> Result<Vec<u8>, Refused> {
        Self::build(bytes, base, entry, Shape::default())
    }

    /// **La même région, mais l'invité ne peut plus sortir de sa RAM.**
    ///
    /// Chaque adresse invitée est repliée par un `et` sur `pages × 64 Kio − 1`
    /// avant d'atteindre la mémoire linéaire. `pages` doit être une puissance
    /// de deux, sans quoi le masque ne décrirait pas un intervalle et la
    /// fonction rend `None` plutôt qu'un module qui replie de travers.
    ///
    /// **À quoi ça sert.** L'hôte peut alors fournir une mémoire *plus grande*
    /// que ce que le module déclare, et ce qui vit au-dessus est hors de
    /// portée de l'invité — c'est là que la correspondance adresse → indice
    /// ira vivre. La feuille de route disait qu'il faudrait une **seconde
    /// mémoire** pour ça, et que rien ne prouvait qu'un vrai iPhone l'accepte ;
    /// un masque n'a besoin d'aucune extension du langage.
    ///
    /// **Ce que ça coûte, mesuré** : `bun scripts/wasm-mask-probe.ts`. Sur la
    /// forme que cet émetteur produit — l'adresse vient d'une globale, parce
    /// qu'elle se recalcule depuis un registre invité à chaque instruction —
    /// le masque est **deux à trois pour cent plus rapide** que son absence,
    /// reproductiblement, sur trois constructions de chaque. L'explication
    /// est offerte et non prouvée : un `et` prouve au moteur que l'adresse
    /// tient dans le minimum déclaré, qui peut alors retirer *sa* propre
    /// vérification de borne.
    ///
    /// Sur une boucle dont l'adresse est un simple compteur, la même sonde
    /// rend **+32 %** — le masque empêche le moteur d'en faire un pointeur qui
    /// avance. Cette forme-là ne sort jamais d'ici, mais elle est mesurée
    /// quand même : c'est le chiffre qu'on aurait cru si on n'avait mesuré
    /// qu'une forme, et il aurait fait abandonner la piste.
    ///
    /// **Un second effet, qui n'est pas un détail.** Sans masque, une adresse
    /// hors de la RAM fait *piéger* le module, et un piège WebAssembly est
    /// sans retour — l'émulateur entier s'arrête. Avec le masque elle se
    /// replie. Ni l'un ni l'autre n'est ce que fait le silicium, qui faute ;
    /// mais un repli laisse l'hôte vivant, et un piège non.
    pub fn confined(bytes: &[u8], base: u64, entry: usize, pages: u32) -> Option<Vec<u8>> {
        if pages == 0 || !pages.is_power_of_two() {
            return None;
        }
        Self::build(
            bytes,
            base,
            entry,
            Shape {
                confine: Some(pages),
                ..Shape::default()
            },
        )
        .ok()
    }

    /// **La même région, mais posée dans la table de l'hôte.**
    ///
    /// Le module n'a plus sa table : il **importe** `env.blocks` et y place ses
    /// blocs à partir de `slot`. Deux régions liées à la même table peuvent
    /// alors s'appeler par `call_indirect` sans repasser par l'hôte — et c'est
    /// tout l'enjeu, mesuré avant d'être écrit : un enchaînement par la boucle
    /// hôte coûte **environ 190 ns**, un `call_indirect` vers un autre module **7,2**.
    /// Les deux chiffres viennent de `--example chain` et de
    /// `scripts/wasm-table-probe.ts`.
    ///
    /// **Cette tranche ne prend pas encore le gain.** `resolve` compare toujours
    /// l'adresse aux blocs de sa propre région et rend la main pour tout le
    /// reste ; la table est importée, remplie, et utilisée par la boucle de
    /// répartition interne, rien de plus. Ce qui manque est la correspondance
    /// adresse → indice, que le module devra lire à l'exécution.
    ///
    /// L'hôte doit fournir une table d'au moins `slot + blocs` entrées. Un
    /// module qui en demande plus qu'elle n'en a ne démarre pas — la même
    /// protection que pour la mémoire, et pour la même raison.
    pub fn linked(bytes: &[u8], base: u64, entry: usize, slot: u32) -> Option<Vec<u8>> {
        Self::build(
            bytes,
            base,
            entry,
            Shape {
                shared: Some(slot),
                ..Shape::default()
            },
        )
        .ok()
    }

    /// **La forme qui n'a plus besoin de l'hôte pour changer de région.**
    ///
    /// Liée — ses blocs vivent dans la table commune — et confinée, donc
    /// l'hôte peut poser la correspondance adresse → indice juste au-dessus de
    /// la RAM invitée, là où l'invité ne peut pas la détruire. Le module la
    /// lit lui-même : quand la cible n'est aucun de ses blocs, il y cherche
    /// l'indice au lieu de rendre la main.
    ///
    /// **Ce que ça remplace.** Un retour de main coûte environ 190 ns, dont
    /// l'essentiel n'est pas WebAssembly mais le site d'appel JavaScript qui
    /// perd son cache en ligne. Un `call_indirect` vers un autre module coûte
    /// 7,2 ns, et la lecture de la correspondance une poignée d'instructions.
    /// Les deux chiffres viennent de `--example chain` et de
    /// `scripts/wasm-table-probe.ts`.
    ///
    /// L'hôte doit remplir la correspondance avec `table_base` et
    /// `table_slot` : ce sont **les mêmes fonctions** que celles gravées dans
    /// le module, et s'ils divergeaient rien ne serait jamais trouvé — le
    /// module se contenterait de rendre la main, sans rien dire.
    pub fn resolving(
        bytes: &[u8],
        base: u64,
        entry: usize,
        slot: u32,
        pages: u32,
    ) -> Option<Vec<u8>> {
        Self::resolving_or_why(bytes, base, entry, slot, pages).ok()
    }

    /// **La forme du bureau, qui dit pourquoi quand elle refuse.**
    ///
    /// C'est celle dont la vue a besoin : sur `Refused::MayBeCut`, elle
    /// redemande la même région avec davantage d'octets ; sur les autres, elle
    /// s'arrête proprement. Sans cette distinction elle redemanderait à
    /// l'aveugle — un aller-retour de plus sur chaque vrai refus — ou
    /// abandonnerait des régions qu'une fenêtre plus large aurait traduites.
    ///
    /// **Ce que ça vaut, mesuré** sur le noyau Alpine, avec des fenêtres de
    /// tailles différentes et 10 116 entrées atteintes par un `call` :
    ///
    /// | fenêtre | compilées | coupées par le bord | refusées franchement |
    /// | --- | --- | --- | --- |
    /// | 2 Kio | 9751 (96,4 %) | 274 | 91 |
    /// | 4 Kio | 9930 (98,2 %) | 89 | 97 |
    /// | 16 Kio | 10009 (98,9 %) | 6 | 101 |
    ///
    /// Deux choses s'y lisent. Le rendement décroît vite, donc une grande
    /// fenêtre fixe paierait des octets pour presque rien : mieux vaut une
    /// petite fenêtre et un second essai sur les 0,9 % qui le demandent. Et les
    /// refus francs **montent** avec la fenêtre, de 91 à 101 — une petite
    /// fenêtre cache de vrais refus derrière des coupes, ce qui veut dire
    /// qu'un décompte de refus ne se lit jamais sans la taille qui va avec.
    ///
    /// **Depuis que le relevé s'arrête devant une instruction coupée** au lieu
    /// de refuser la région, la colonne « coupées par le bord » se traduit :
    /// ces régions rendent la main sur la coupe et la suite devient une région
    /// de plus. Le second essai ne sert plus qu'à une fenêtre dont la
    /// **première** instruction est coupée.
    pub fn resolving_or_why(
        bytes: &[u8],
        base: u64,
        entry: usize,
        slot: u32,
        pages: u32,
    ) -> Result<Vec<u8>, Refused> {
        if pages == 0 || !pages.is_power_of_two() {
            return Err(Refused::RamIsNotAPowerOfTwo(pages));
        }
        Self::build(
            bytes,
            base,
            entry,
            Shape {
                shared: Some(slot),
                confine: Some(pages),
                lookup: true,
            },
        )
    }

    fn build(bytes: &[u8], base: u64, entry: usize, shape: Shape) -> Result<Vec<u8>, Refused> {
        // Le masque se dérive du nombre de pages, une fois : `confined` a déjà
        // vérifié que c'est une puissance de deux.
        let mask = shape.confine.map(|pages| pages * 65536 - 1);
        // **La pagination n'existe que sous confinement** : c'est lui qui ouvre
        // la place au-dessus de la RAM déclarée, où vivent la correspondance et
        // le tampon. Sans masque, `guest()` garde sa forme d'avant.
        let blocks = Self::discover(bytes, entry)?;
        let index = |offset: usize| blocks.iter().position(|(start, _)| *start == offset);
        let starts: Vec<u64> = blocks
            .iter()
            .map(|(start, _)| base.wrapping_add(*start as u64))
            .collect();

        let mut bodies: Vec<Vec<u8>> = Vec::new();
        for (start, steps) in &blocks {
            let mut body = Body {
                confine: mask,
                walk: mask.map(|_| HOST_IMPORTS + blocks.len() as u32),
                ..Body::default()
            };
            let mut at = *start;
            for step in steps {
                // **L'adresse de l'instruction elle-même**, pas celle de la
                // suivante : une division qui refuse doit y renvoyer l'hôte.
                let here = base.wrapping_add(at as u64);
                at += step.length;
                // **`iretd` est refusé en étant nommé.** Le décodeur lit `cf`
                // sans REX.W ; en mode long c'est un retour de trente-deux
                // bits qu'aucun noyau n'exécute, et le produire demanderait
                // un cadre que cette machine ne pose jamais. Un refus ici,
                // avant `terminate`, plutôt qu'un cadre à moitié lu.
                if step.op == Op::InterruptReturn && step.width != Width::Qword {
                    return Err(Refused::CannotTranslate {
                        at: at - step.length,
                    });
                }
                // **Le saut final n'est pas traduit comme les autres.** Il ne
                // change pas l'état de la machine mais le bloc courant, et
                // c'est `terminate` qui sait le dire — lui seul connaît les
                // autres blocs.
                if matches!(
                    step.op,
                    Op::Jump(_)
                        | Op::LoopWhile
                        | Op::JumpIndirect
                        | Op::Call
                        | Op::CallIndirect
                        | Op::Return
                        | Op::FarReturn
                        | Op::InterruptReturn
                        | Op::Undefined
                ) {
                    continue;
                }
                if Self::translate(&Self::pin(step, here), here, &mut body).is_none() {
                    return Err(Refused::CannotTranslate {
                        at: at - step.length,
                    });
                }
            }
            Self::terminate(steps.last(), base, at, &index, &starts, &mut body, shape);
            body.op(code::END);
            bodies.push(body.bytes);
        }
        Ok(Self::assemble(bodies, shape))
    }

    /// **Une adresse relative au pointeur d'instruction est une constante** —
    /// dès qu'on sait où l'instruction est posée, et l'émetteur le sait.
    ///
    /// C'est ce que fait un vrai compilateur à la volée : le déplacement se
    /// compte depuis l'octet qui **suit** l'instruction, cette adresse est
    /// connue à la compilation, donc le calcul disparaît. C'est le seul mode
    /// d'adressage qui ne coûte rien à l'exécution — et le seul dont l'erreur
    /// d'un octet ne se voit nulle part ailleurs qu'en la comparant au
    /// silicium.
    fn pin(step: &Decoded, here: u64) -> Decoded {
        match step.memory {
            Some(address) if address.relative => {
                let after = here.wrapping_add(step.length as u64);
                Decoded {
                    memory: Some(Address {
                        base: None,
                        index: None,
                        scale: 1,
                        displacement: after.wrapping_add(address.displacement as u64) as i64,
                        relative: false,
                        // **Le segment survit au figeage.** Figer résout le
                        // déplacement, pas la base : `%gs:x(%rip)` reste une
                        // adresse à laquelle la base du segment s'ajoutera.
                        gs: address.gs,
                    }),
                    ..*step
                }
            }
            _ => *step,
        }
    }

    /// **Le parcours du graphe**, et pourquoi ce n'est pas une boucle sur les
    /// octets. Un `jmp` en arrière repasse sur du code déjà lu, un `jcc` ouvre
    /// deux suites, et l'octet qui suit un saut inconditionnel peut n'être
    /// atteint par personne — le décoder comme du code refuserait une région
    /// parfaitement exécutable.
    #[allow(clippy::type_complexity)]
    /// **Ce qu'une région coûtera à l'hôte, avant de l'exécuter.**
    ///
    /// Un module ne va pas jusqu'au bout du programme : il rend la main. Deux
    /// façons, et elles ne pèsent pas pareil.
    ///
    /// - **Toujours** : `ud2`, et lui seul depuis que la boucle du `rep` est
    ///   émise. C'est une faute, qui appartient à l'hôte de toute façon :
    ///   l'état est dans les globales et rien n'a besoin de reprendre à
    ///   l'intérieur du module.
    /// - **Peut-être** : `ret`, `jmp *` et `call *`. La cible n'est connue
    ///   qu'à l'exécution ; le module la cherche parmi ses propres blocs et ne
    ///   rend la main que si elle n'en est pas.
    ///
    /// La distinction décide de l'architecture du bureau local, pas seulement
    /// d'une optimisation : la RAM invitée **est** la mémoire linéaire du
    /// module, dans le processus de contenu de WebKit. Ce qui reprend après un
    /// retour de main doit pouvoir la lire. Un interpréteur qui vit ailleurs ne
    /// le peut pas — et « ailleurs » comprend l'application elle-même.
    pub fn survey(bytes: &[u8], entry: usize) -> Option<Survey> {
        let blocks = Self::discover(bytes, entry).ok()?;
        let mut survey = Survey {
            blocks: blocks.len(),
            ..Default::default()
        };
        for (_, steps) in &blocks {
            survey.instructions += steps.len();
            for step in steps {
                match step.op {
                    Op::StringMove { repeat: true } | Op::StringStore { repeat: true } => {
                        survey.repeats += 1;
                    }
                    Op::Undefined => survey.always += 1,
                    Op::Return
                    | Op::FarReturn
                    | Op::InterruptReturn
                    | Op::JumpIndirect
                    | Op::CallIndirect => survey.perhaps += 1,
                    _ => {}
                }
            }
        }
        Some(survey)
    }

    /// **Où une adresse invitée retombe dans la RAM déclarée.**
    ///
    /// Le confinement est un masque : la mémoire linéaire du module fait
    /// `pages` blocs de 64 Kio, une puissance de deux, et toute adresse y est
    /// repliée par `& (ram - 1)`. C'est ce que fait le code émis, et c'est ce
    /// que fait `web/host.js` pour aller chercher les octets d'une région.
    ///
    /// **La règle vaut d'être nommée une fois** parce qu'elle était réécrite à
    /// chaque endroit qui en avait besoin, et qu'un de ces endroits l'oubliait.
    /// Le noyau bascule à l'adressage virtuel en cours de démarrage : il
    /// réclame `0xffffffff8100013e` alors que ses octets sont à `0x100013e`.
    /// Une soustraction faite à cru sur une telle adresse ne rend pas un
    /// mauvais nombre, elle **panique** — « range start index
    /// 18446744071564165438 out of range ».
    ///
    /// Ce n'est pas une traduction d'adresse : rien ici ne consulte les tables
    /// de pages de l'invité. C'est une projection, et elle ne tombe juste que
    /// parce que le noyau est chargé bas dans une RAM dont la taille divise
    /// l'écart entre ses deux formes d'adresse. `--example kernel-entry` le
    /// vérifie et le dit avant de commencer.
    #[must_use]
    pub fn fold(address: u64, pages: u32) -> u64 {
        let ram = u64::from(pages) * 65536;
        address & (ram - 1)
    }

    /// **Le relevé bloc par bloc de la région, dans l'ordre des adresses.**
    ///
    /// Même découverte que `survey` et que l'émission — c'est `discover` qui
    /// répond aux trois — donc ce que ce relevé dit d'un bloc est ce que le
    /// module fera de lui, et pas une seconde lecture qui pourrait diverger.
    ///
    /// Ce qu'il ne dit pas : ce que fait un terminateur dont la cible n'est
    /// connue qu'à l'exécution. Pour `ret`, `jmp *` et `call *`, `target` et
    /// `goes` sont vides parce qu'il n'y a rien à y mettre, pas parce que la
    /// question ne se pose pas.
    pub fn outline(bytes: &[u8], entry: usize) -> Result<Vec<Outline>, Refused> {
        let blocks = Self::discover(bytes, entry)?;
        let index = |offset: usize| blocks.iter().position(|(start, _)| *start == offset);
        Ok(blocks
            .iter()
            .map(|(start, steps)| {
                let after = start + steps.iter().map(|step| step.length).sum::<usize>();
                // Un bloc ne se termine que sur l'une des formes qui changent
                // le bloc courant. Tout le reste veut dire « coupé par le bord
                // de la région », et c'est `after` qui devient l'adresse de
                // reprise — la distinction que ce relevé existe pour montrer.
                let last = steps.last();
                let ends = last.map(|step| step.op).filter(|op| {
                    matches!(
                        op,
                        Op::Jump(_)
                            | Op::LoopWhile
                            | Op::JumpIndirect
                            | Op::Call
                            | Op::CallIndirect
                            | Op::Return
                            | Op::FarReturn
                            | Op::InterruptReturn
                            | Op::Undefined
                    )
                });
                let target = match ends {
                    Some(Op::Jump(_) | Op::LoopWhile | Op::Call) => {
                        Some(after as i64 + last.map_or(0, |step| step.imm as i64))
                    }
                    _ => None,
                };
                Outline {
                    start: *start,
                    after,
                    steps: steps.len(),
                    ends,
                    target,
                    goes: target
                        .and_then(|target| usize::try_from(target).ok())
                        .and_then(index),
                }
            })
            .collect())
    }

    fn discover(bytes: &[u8], entry: usize) -> Result<Vec<(usize, Vec<Decoded>)>, Refused> {
        let mut starts = std::collections::BTreeSet::new();
        let mut queue = vec![entry];
        let mut blocks: std::collections::BTreeMap<usize, Vec<Decoded>> =
            std::collections::BTreeMap::new();
        // **Où le relevé a rencontré le bord**, s'il l'a rencontré : une
        // instruction qui ne se décode pas à moins de `REACH` octets de la fin.
        let mut cut = None;
        while let Some(start) = queue.pop() {
            if start >= bytes.len() || !starts.insert(start) {
                continue;
            }
            let mut steps = Vec::new();
            let mut at = start;
            loop {
                if at >= bytes.len() {
                    break;
                }
                let Some(step) = decode(&bytes[at..]) else {
                    // **Coupé par le bord, ou vraiment inconnu ?** C'est la
                    // place restante qui répond, et elle seule : le décodeur
                    // ne sait pas dire s'il lui manquait des octets.
                    if bytes.len() - at >= REACH {
                        return Err(Refused::CannotDecode { at });
                    }
                    // **Coupé : le bloc s'arrête devant, et `at` devient une
                    // cible hors région.** Ce qui précède est complet et se
                    // traduit ; l'instruction à cheval sera la première d'une
                    // région que l'hôte demandera en arrivant là, avec une
                    // fenêtre entière devant elle. Refuser la région entière
                    // ici a arrêté le noyau Alpine sur `setup_arch` : seize
                    // kibioctets de blocs complets jetés pour un octet. Le
                    // bloc coupé n'a pas de terminateur, exactement comme un
                    // bloc dont la dernière instruction finit pile sur le
                    // bord — `terminate` pose RIP sur `after` et rend la main.
                    cut = Some(at);
                    break;
                };
                at += step.length;
                let ends = matches!(
                    step.op,
                    Op::Jump(_)
                        | Op::LoopWhile
                        | Op::JumpIndirect
                        | Op::Call
                        | Op::CallIndirect
                        | Op::Return
                        | Op::FarReturn
                        | Op::InterruptReturn
                        | Op::Undefined
                );
                let displacement = step.imm as i64;
                // **Ce qui suit un `call` est atteignable, et par une seule
                // route : le `ret` qui lui répond.** Ne pas le mettre dans la
                // file laissait l'appelé sans retour possible — le module
                // rendait la main au lieu de continuer. `jmp` est le seul à
                // n'avoir pas de suite ; `ret`, lui, n'a pas de cible connue
                // d'avance, et sa suite n'est atteignable que par ailleurs.
                // **Rien ne suit un `ud2`.** L'exécution n'en revient pas, donc
                // les octets d'après ne sont pas atteignables par cette route ;
                // les mettre dans la file ferait décoder, et refuser, ce qu'un
                // noyau range là — souvent des données de sa table de bogues.
                let falls = !matches!(
                    step.op,
                    Op::Jump(None)
                        | Op::Return
                        | Op::FarReturn
                        | Op::InterruptReturn
                        | Op::Undefined
                );
                let jumps = !matches!(
                    step.op,
                    Op::Return | Op::FarReturn | Op::InterruptReturn | Op::Undefined
                );
                steps.push(step);
                if !ends {
                    continue;
                }
                let target = at as i64 + displacement;
                if jumps && (0..bytes.len() as i64).contains(&target) {
                    queue.push(target as usize);
                }
                if falls && at < bytes.len() {
                    queue.push(at);
                }
                break;
            }
            if steps.is_empty() {
                continue;
            }
            blocks.insert(start, steps);
        }
        if blocks.is_empty() {
            // **Rien de complet, et pourquoi.** Si c'est le bord qui a coupé
            // la toute première instruction, davantage d'octets la
            // rendraient lisible : c'est le seul cas où redemander est le
            // seul remède, et le seul où `MayBeCut` est encore rendu.
            return Err(match cut {
                Some(at) => Refused::MayBeCut { at },
                None => Refused::NothingAtEntry,
            });
        }
        Ok(blocks.into_iter().collect())
    }

    /// **Ce qu'un bloc fait à la fin : dire où aller.**
    ///
    /// Il pose l'indice du bloc suivant — ou -1 pour rendre la main — et, dans
    /// tous les cas, l'endroit où l'exécution en est. Rendre la main sans dire
    /// où reprendre laisserait l'hôte avec une machine dont il ne sait plus
    /// quoi faire.
    fn terminate(
        last: Option<&Decoded>,
        base: u64,
        after: usize,
        index: &impl Fn(usize) -> Option<usize>,
        starts: &[u64],
        body: &mut Body,
        shape: Shape,
    ) {
        // Deux valeurs à poser : l'adresse d'arrivée et l'indice du bloc.
        // Quand la cible n'est pas dans la région, c'est `aim` qui décide :
        // la correspondance si la forme en a une, `-1` sinon.
        let place = |body: &mut Body, offset: i64| {
            body.store(RIP_SLOT, |b| {
                b.constant(base.wrapping_add(offset as u64));
            });
            Self::aim(body, usize::try_from(offset).ok().and_then(&index), shape);
        };

        let Some(step) = last else {
            place(body, after as i64);
            return;
        };
        let target = after as i64 + step.imm as i64;
        // **L'opérande d'une forme indirecte, poussé sur la pile WebAssembly.**
        // Un registre, ou huit octets de mémoire — et cette mémoire peut être
        // relative au pointeur d'instruction, ce dont un noyau est fait : une
        // table de sauts s'atteint comme ça. `pin` résout ce déplacement depuis
        // l'adresse de **cette** instruction, qui est celle d'après moins sa
        // longueur.
        let here = base.wrapping_add(after.wrapping_sub(step.length) as u64);
        let pinned = Self::pin(step, here);
        let reach = move |b: &mut Body| match pinned.memory {
            Some(address) => {
                b.load_memory(&address, Width::Qword);
            }
            None => {
                b.load(Self::slot(pinned.dst));
            }
        };
        match step.op {
            Op::Jump(None) => place(body, target),
            Op::Jump(Some(condition)) => {
                // Les deux issues sont calculées, puis choisies. L'adresse
                // aussi : elle diffère selon la branche prise.
                body.store(RIP_SLOT, |b| {
                    b.constant(base.wrapping_add(target as u64));
                    b.constant(base.wrapping_add(after as u64));
                    Self::condition(condition, b);
                    b.op(code::I32_WRAP_I64).op(code::SELECT);
                });
                Self::choose(body, target, after as i64, index, shape, |b| {
                    Self::condition(condition, b);
                });
            }
            Op::LoopWhile => {
                // `loop` décrémente RCX **sans poser de drapeau**, et saute
                // tant qu'il n'est pas nul. Le confondre avec `dec` puis `jnz`
                // écraserait cinq drapeaux que le processeur préserve.
                body.store(Self::slot(1), |b| {
                    b.load(Self::slot(1)).constant(1).op(code::I64_SUB);
                });
                body.store(RIP_SLOT, |b| {
                    b.constant(base.wrapping_add(target as u64));
                    b.constant(base.wrapping_add(after as u64));
                    b.load(Self::slot(1)).constant(0).op(code::I64_NE);
                    b.op(code::SELECT);
                });
                Self::choose(body, target, after as i64, index, shape, |b| {
                    b.load(Self::slot(1)).constant(0).op(code::I64_NE);
                    b.op(code::I64_EXTEND_I32_U);
                });
            }
            Op::Undefined => {
                // **Rendre la main sur elle, pas après.** Le processeur laisse
                // le pointeur d'instruction sur le `ud2` en levant son
                // exception ; l'hôte doit voir la même chose, sans quoi il
                // reprendrait à l'octet suivant, qui n'est pas du code.
                body.store(RIP_SLOT, |b| {
                    b.constant(here);
                });
                body.bytes.push(code::I32_CONST);
                signed(-1, &mut body.bytes);
            }
            Op::JumpIndirect => {
                body.store(RIP_SLOT, reach);
                Self::resolve(starts, body, shape);
            }
            Op::CallIndirect => {
                // **La cible est lue avant que la pile ne bouge.** L'ordre
                // inverse marcherait tant que la cible n'est pas prise sur la
                // pile elle-même — et `call *-8(%rsp)` est écrivable.
                body.store(Body::scratch(0), reach);
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_SUB);
                });
                Self::at_top(body, |b| {
                    b.constant(base.wrapping_add(after as u64));
                });
                // La cible n'est pas connue à la compilation : si elle tombe
                // sur un bloc de la région, la boucle de répartition y va ;
                // sinon le module rend la main, et l'interpréteur reprend là.
                body.store(RIP_SLOT, |b| {
                    b.load(Body::scratch(0));
                });
                Self::resolve(starts, body, shape);
            }
            Op::Call => {
                // L'adresse de retour est empilée ici — c'est la seule partie
                // de `call` qui touche l'état — puis le bloc change.
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_SUB);
                });
                Self::at_top(body, |b| {
                    b.constant(base.wrapping_add(after as u64));
                });
                place(body, target);
            }
            Op::Return => {
                // La cible sort de la pile : elle n'est connue qu'à
                // l'exécution. Le module la cherche parmi ses propres blocs, et
                // rend la main si elle n'en est pas un.
                body.store(RIP_SLOT, |b| {
                    b.load(Self::slot(4));
                    b.guest();
                    b.op(code::I64_LOAD);
                    b.bytes.push(0);
                    b.bytes.push(0);
                });
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_ADD);
                });
                Self::resolve(starts, body, shape);
            }
            Op::FarReturn => {
                // **`lretq` dépile deux mots : le pointeur d'instruction, puis
                // le sélecteur de code.** Il n'avait aucun bras ici, donc il
                // tombait dans le `_` d'en dessous et posait l'adresse
                // *suivante* — c'est-à-dire qu'il n'était pas pris du tout.
                //
                // **La panne qui ressemble à un succès.** Un saut non pris ne
                // s'arrête pas : il continue dans les octets d'après, qui sont
                // du rembourrage, puis du code. Sur le vrai noyau d'Alpine,
                // `secondary_startup_64` finit par
                // `mov %r15,%rdi ; push $0x10 ; push %rax ; lretq` — et la
                // machine arrivait quand même dans `x86_64_start_kernel`, par
                // une autre route, avec `RDI = 0` au lieu du pointeur vers les
                // `boot_params`. La faute tombait vingt fonctions plus loin,
                // dans `copy_bootdata`, sur `__va(0)`. Rien n'avait rougi entre
                // les deux.
                //
                // **Le sélecteur est dépilé et jeté**, comme partout ailleurs
                // dans cette machine : rien ici ne modélise CS, et faire
                // semblant de le ranger laisserait croire qu'on le consulte.
                // Ce que le `lretq` d'un noyau x86-64 change en pratique — le
                // passage d'un anneau à l'autre — n'est pas dans ce chemin :
                // `startup_64` s'en sert pour recharger CS avec le même
                // privilège.
                body.store(RIP_SLOT, |b| {
                    b.load(Self::slot(4));
                    b.guest();
                    b.op(code::I64_LOAD);
                    b.bytes.push(0);
                    b.bytes.push(0);
                });
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(16).op(code::I64_ADD);
                });
                Self::resolve(starts, body, shape);
            }
            Op::InterruptReturn => {
                // **`iretq` défait le cadre qu'une faute a posé** : RIP, CS,
                // RFLAGS, RSP, SS, dans cet ordre depuis le sommet de la pile.
                // C'est l'autre moitié de la délivrance — `web/host.js` pose le
                // cadre en entrant dans le gestionnaire, et c'est ici que
                // l'invité en sort. L'instruction fautive est alors rejouée,
                // ce qui est exactement ce qu'un noyau attend : il vient de
                // cartographier la page, et la lecture qui avait fauté aboutit.
                //
                // **Le code d'erreur n'est pas dépilé**, comme sur le silicium :
                // c'est au gestionnaire d'ajouter huit à RSP avant, et Linux le
                // fait. Le dépiler ici décalerait tout le cadre d'un mot.
                //
                // **RIP est posé sur l'`iretq` lui-même avant la première
                // lecture.** Ce cadre est en mémoire paginée, et l'une des cinq
                // lectures peut fauter ; l'hôte doit alors reprendre *ici*, pas
                // au début du bloc. Les cinq mots sont lus avant que RSP ne
                // change — RSP est la base des quatre autres — et RIP est lu en
                // dernier, pour qu'une faute sur le mot d'avant le laisse encore
                // sur l'`iretq`.
                let here = base.wrapping_add((after - step.length) as u64);
                body.store(RIP_SLOT, |b| {
                    b.constant(here);
                });
                let word = |b: &mut Body, offset: u64| {
                    b.load(Self::slot(4));
                    if offset != 0 {
                        b.constant(offset).op(code::I64_ADD);
                    }
                    b.guest();
                    b.op(code::I64_LOAD);
                    b.bytes.push(0);
                    b.bytes.push(0);
                };
                body.store(Self::segment_slot(Segment::Cs), |b| {
                    word(b, 8);
                    b.constant(0xffff).op(code::I64_AND);
                });
                body.store(RFLAGS_SLOT, |b| {
                    word(b, 16);
                    b.constant(WRITABLE_FLAGS).op(code::I64_AND);
                    b.constant(ALWAYS_ONE).op(code::I64_OR);
                });
                body.store(Self::segment_slot(Segment::Ss), |b| {
                    word(b, 32);
                    b.constant(0xffff).op(code::I64_AND);
                });
                // La nouvelle pile, gardée de côté : la lire dans RSP tout de
                // suite déplacerait la base sous la lecture de RIP.
                body.store(Body::scratch(0), |b| {
                    word(b, 24);
                });
                body.store(RIP_SLOT, |b| {
                    word(b, 0);
                });
                body.store(Self::slot(4), |b| {
                    b.load(Body::scratch(0));
                });
                Self::resolve(starts, body, shape);
            }
            _ => place(body, after as i64),
        }
    }

    /// **Retrouver un bloc depuis une adresse connue seulement à l'exécution.**
    ///
    /// C'est ce dont `ret` et `jmp *%reg` ont besoin. Les adresses des blocs
    /// sont connues à la compilation, donc la recherche est une suite de
    /// comparaisons : la cible est-elle le bloc zéro, sinon le bloc un… et -1
    /// si elle n'est aucun d'eux, auquel cas le module rend la main et l'hôte
    /// compilera la région qui commence là.
    ///
    /// Linéaire, et c'est assez : une région a quelques blocs, pas mille. Le
    /// jour où elle en aura mille, ce sera une table de hachage — mais le dire
    /// avant de l'avoir mesuré serait deviner.
    fn resolve(starts: &[u64], body: &mut Body, shape: Shape) {
        // **Le repli de la chaîne, et c'est là que la correspondance
        // s'insère.** La chaîne de `select` qui suit part d'une valeur et la
        // remplace dès qu'un bloc de la région correspond. Faire chercher le
        // module ailleurs ne demande donc aucune structure de contrôle en
        // plus : il suffit que cette valeur de départ soit ce qu'il a trouvé
        // dans la correspondance au lieu d'un `-1` sec. Les blocs de la
        // région gagnent toujours, ce qui est juste — ils sont déjà là.
        match Self::lookup_base(shape) {
            Some((base, _)) => Self::lookup(base, body),
            None => {
                body.bytes.push(code::I32_CONST);
                signed(-1, &mut body.bytes);
            }
        }
        let at_slot = shape.shared.unwrap_or(0);
        for (block, start) in starts.iter().enumerate() {
            body.bytes.push(code::I32_CONST);
            signed(i64::from(block as u32 + at_slot), &mut body.bytes);
            // Échanger les deux : `select` rend la première quand la condition
            // tient, donc l'indice trouvé doit être poussé en dernier.
            body.load(RIP_SLOT).constant(*start).op(code::I64_NE);
            body.op(code::SELECT);
        }
    }

    /// **Où vit la correspondance pour cette forme-là**, et l'emplacement qu'il
    /// faudra retrancher. Elle demande les deux : confiné, sinon l'invité
    /// pourrait la détruire et le module sauterait n'importe où ; lié, sinon
    /// les blocs des autres régions ne sont dans aucune table commune.
    fn lookup_base(shape: Shape) -> Option<(u32, u32)> {
        if !shape.lookup {
            return None;
        }
        Some((table_base(shape.confine?), shape.shared?))
    }

    /// **Chercher l'adresse courante dans la correspondance.** Laisse sur la
    /// pile l'indice du bloc trouvé, ou `-1`.
    ///
    /// **Une seule case est consultée, sans sondage.** Deux adresses qui
    /// tombent au même endroit ne se disputent pas : la seconde n'est
    /// simplement pas trouvée, et le module rend la main comme il le faisait
    /// déjà pour toutes. Une collision coûte donc ce que coûtait la situation
    /// d'avant, jamais plus — et ça évite une boucle de sondage dans un corps
    /// de bloc qui n'a aucune variable locale.
    ///
    /// **L'indice rendu est relatif à l'emplacement de la région.** La table
    /// range des indices absolus, mais la boucle de répartition ajoute
    /// l'emplacement à tout ce qu'un bloc rend — c'est l'invariant qui garde
    /// la traduction indépendante de l'endroit où l'hôte pose la région. Le
    /// retranchement d'ici le respecte au lieu de l'entamer.
    fn lookup(base: u32, body: &mut Body) {
        // L'indice rangé dans la case, ramené au repère de la région.
        body.entry(base);
        body.op(code::I32_LOAD);
        body.bytes.push(2); // alignement : quatre octets
        body.bytes.push(8); // décalage : l'indice suit l'adresse
                            // Le repli, si la case ne parle pas de nous.
        body.bytes.push(code::I32_CONST);
        signed(-1, &mut body.bytes);
        // Et la question : la case range-t-elle bien l'adresse cherchée ?
        // Sans cette comparaison, une case vide ou occupée par une autre
        // adresse ferait sauter le module dans un bloc au hasard — le défaut
        // le plus difficile à voir de toute cette tranche.
        body.entry(base);
        body.op(code::I64_LOAD);
        body.bytes.push(3);
        body.bytes.push(0);
        body.load(RIP_SLOT).op(code::I64_EQ);
        body.op(code::SELECT);
    }

    /// **Pousser l'indice d'une cible statique.**
    ///
    /// Un bloc de la région : son indice **absolu** dans la table de l'hôte —
    /// l'emplacement de la région ajouté au numéro local, voir la répartition,
    /// qui n'ajoute plus rien. Sinon la correspondance, si la forme en a une,
    /// et `-1` seulement quand elle ne connaît pas l'adresse, ou qu'il n'y en
    /// a pas.
    ///
    /// **C'est ici qu'un `call` vers une autre fonction cesse de repasser par
    /// l'hôte.** Jusqu'à cette tranche, seules les formes indirectes — `ret`,
    /// `jmp *`, `call *` — consultaient la correspondance, dans `resolve` ;
    /// une cible statique hors région rendait la main, et le noyau Alpine
    /// payait un aller-retour par l'hôte à chaque appel de son comparateur
    /// dans `sort_r` : une comparaison par tour, 4096 tours, et le pilote
    /// prenait ça pour la fin. La correspondance lit RIP, que l'appelant
    /// vient de poser sur la cible — et pour un saut conditionnel, sur la
    /// cible **choisie** : la valeur poussée pour l'autre issue est fausse
    /// mais écartée par le `select` qui suit.
    fn aim(body: &mut Body, block: Option<usize>, shape: Shape) {
        match (block, Self::lookup_base(shape)) {
            (Some(block), _) => {
                body.bytes.push(code::I32_CONST);
                signed(
                    i64::from(block as u32 + shape.shared.unwrap_or(0)),
                    &mut body.bytes,
                );
            }
            (None, Some((base, _))) => Self::lookup(base, body),
            (None, None) => {
                body.bytes.push(code::I32_CONST);
                signed(-1, &mut body.bytes);
            }
        }
    }

    /// Choisir entre deux indices de bloc selon un prédicat `i64`. RIP porte
    /// déjà l'adresse choisie : c'est ce que `aim` lit pour une issue hors
    /// région.
    fn choose(
        body: &mut Body,
        taken: i64,
        fallen: i64,
        index: &impl Fn(usize) -> Option<usize>,
        shape: Shape,
        condition: impl FnOnce(&mut Body),
    ) {
        Self::aim(body, usize::try_from(taken).ok().and_then(index), shape);
        Self::aim(body, usize::try_from(fallen).ok().and_then(index), shape);
        condition(body);
        body.op(code::I32_WRAP_I64).op(code::SELECT);
    }

    /// **Le module : une fonction par bloc, plus la boucle qui les enchaîne.**
    fn assemble(bodies: Vec<Vec<u8>>, shape: Shape) -> Vec<u8> {
        let Shape {
            shared, confine, ..
        } = shape;
        let count = bodies.len();
        // Voir `build` : la pagination n'existe que sous confinement, et le
        // masque s'en dérive de la même façon des deux côtés.
        let mask = confine.map(|pages| pages * 65536 - 1);
        let paging = mask.is_some();
        let mut module = vec![0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

        // Types : un bloc rend l'indice du suivant ; `run` prend un budget ;
        // puis les deux que l'hôte prête. `out` prend le port, la valeur et la
        // largeur en octets, et ne rend rien ; `in` prend le port et la
        // largeur, et rend ce que le périphérique a répondu.
        section(
            1,
            vec![
                0x05, //
                0x60, 0x00, 0x01, 0x7f, // 0 : () -> i32
                0x60, 0x01, 0x7e, 0x00, // 1 : (i64) -> ()
                0x60, 0x03, 0x7e, 0x7e, 0x7e, 0x00, // 2 : (i64, i64, i64) -> ()
                0x60, 0x02, 0x7e, 0x7e, 0x01, 0x7e, // 3 : (i64, i64) -> i64
                0x60, 0x01, 0x7e, 0x01, 0x7f, // 4 : (i64) -> i32, la marche
            ],
            &mut module,
        );

        // **La mémoire et les registres viennent de l'hôte.**
        //
        // Un module qui les définit lui-même est une machine à lui tout seul :
        // deux régions compilées séparément ne partagent alors rien, et la
        // seule façon de passer de l'une à l'autre serait de recopier tout
        // l'état — huit cent mégaoctets de RAM invitée comprise. En les
        // **important**, l'hôte n'a plus qu'une RAM et qu'un fichier de
        // registres, et autant de régions qu'il en faut : quand un module rend
        // la main, la région suivante reprend exactement où il s'est arrêté.
        //
        // C'est ce qui rend l'interpréteur utilisable comme filet plutôt que
        // comme abandon, et c'est l'architecture de l'application.
        let mut imports = Vec::new();
        unsigned(
            u64::from(HOST_IMPORTS) + 1 + u64::from(shared.is_some()) + GLOBAL_COUNT as u64,
            &mut imports,
        );
        let module_name = |bytes: &mut Vec<u8>| {
            unsigned(3, bytes);
            bytes.extend_from_slice(b"env");
        };
        // **Les deux fonctions de l'hôte, en premier.** Seules les fonctions
        // importées consomment des indices de fonction ; la mémoire, la table
        // et les globales n'en consomment pas. Les mettre ici rend `HOST_OUT`
        // et `HOST_IN` vrais quelle que soit la forme de la région.
        for (name, signature) in [("out", 0x02u8), ("in", 0x03)] {
            module_name(&mut imports);
            unsigned(name.len() as u64, &mut imports);
            imports.extend_from_slice(name.as_bytes());
            imports.push(0x00);
            imports.push(signature);
        }
        module_name(&mut imports);
        unsigned(3, &mut imports);
        imports.extend_from_slice(b"mem");
        imports.push(0x02);
        imports.push(0x00);
        // **Le minimum déclaré, et pourquoi il suit le confinement.** Sans
        // masque le module adresse toute la RAM que le corpus attend, donc
        // `GUEST_PAGES`. Avec masque il ne peut plus dépasser `pages`, et
        // déclarer davantage mentirait sur ce qu'il touche. L'hôte, lui, reste
        // libre d'en fournir **plus** : c'est là que vivra ce que l'invité ne
        // doit pas pouvoir atteindre.
        // **Le tampon est déclaré, pas seulement supposé.** Même règle que la
        // correspondance : un hôte qui ne l'a pas posé **ne démarre pas**, au
        // lieu de piéger au premier défaut de tampon — et un piège WebAssembly
        // est sans retour.
        //
        // **Les deux formes confinées déclarent la même chose**, et ce fut deux
        // bras identiques pendant une tranche : la correspondance et le tampon
        // vivent au-dessus de la RAM que la région soit résolvante ou non.
        let least = match confine {
            Some(pages) => host_pages(pages),
            None => GUEST_PAGES,
        };
        unsigned(u64::from(least), &mut imports);
        // **La table de l'hôte**, quand la région est liée. Le minimum déclaré
        // couvre l'emplacement de cette région et ses blocs : une table plus
        // petite refuse l'instanciation, exactement comme une mémoire trop
        // petite. C'est ce qui transforme un décalage mal calculé en une erreur
        // de liaison plutôt qu'en un appel vers l'entrée d'à côté.
        if let Some(slot) = shared {
            module_name(&mut imports);
            unsigned(TABLE_IMPORT.len() as u64, &mut imports);
            imports.extend_from_slice(TABLE_IMPORT.as_bytes());
            imports.extend_from_slice(&[0x01, 0x70, 0x00]);
            unsigned(u64::from(slot) + count as u64, &mut imports);
        }
        for slot in 0..GLOBAL_COUNT {
            module_name(&mut imports);
            let name = format!("g{slot}");
            unsigned(name.len() as u64, &mut imports);
            imports.extend_from_slice(name.as_bytes());
            // Une globale `i64`, **mutable** : le module y écrit.
            imports.extend_from_slice(&[0x03, 0x7e, 0x01]);
        }
        section(2, imports, &mut module);

        let mut functions = Vec::new();
        unsigned(count as u64 + 1 + u64::from(paging), &mut functions);
        // Les `count` premières fonctions sont les blocs, du type zéro ; vient
        // ensuite la marche quand il y en a une, du type quatre ; la dernière
        // est la boucle de répartition, du type un.
        //
        // **La marche est placée après les blocs, et c'est ce qui coûte le
        // moins.** Devant, elle décalerait tous les indices de bloc, donc la
        // section des éléments qui les pose dans la table de l'hôte. Ici, seul
        // l'indice exporté de `run` bouge.
        functions.resize(functions.len() + count, 0x00);
        if paging {
            functions.push(0x04);
        }
        functions.push(0x01);
        section(3, functions, &mut module);

        // Table : les blocs, pour le `call_indirect` de la boucle.
        // **Sa propre table, ou celle de l'hôte.** La forme historique définit
        // la sienne : chaque module a la sienne, et un `call_indirect` ne peut
        // désigner qu'un bloc de sa propre région — passer à la suivante coûte
        // alors un retour de main, mesuré à environ 190 ns. La forme liée **importe** la
        // table et y pose ses blocs à l'emplacement que l'hôte lui donne, ce qui
        // ouvre la porte à un enchaînement qui ne sort jamais de WebAssembly :
        // 7,2 ns relevés par `scripts/wasm-table-probe.ts`.
        if shared.is_none() {
            let mut table = vec![0x01, 0x70, 0x00];
            unsigned(count as u64, &mut table);
            section(4, table, &mut module);
        }

        // **`run`, et `walk` quand il y en a une.** La marche est exportée
        // pour que l'hôte traduise avec **la même** fonction que le module —
        // il en a besoin pour délivrer une faute : lire la porte dans l'IDT et
        // poser le cadre sur la pile sont des accès à des adresses virtuelles.
        // Une seconde marche écrite en JavaScript aurait fini par diverger de
        // celle-ci, en silence, sur une grande page ou un bit réservé.
        let mut exports = Vec::new();
        unsigned(1 + u64::from(paging), &mut exports);
        exports.extend_from_slice(&[0x03, b'r', b'u', b'n', 0x00]);
        unsigned(
            u64::from(HOST_IMPORTS) + count as u64 + u64::from(paging),
            &mut exports,
        );
        if paging {
            exports.extend_from_slice(&[0x04, b'w', b'a', b'l', b'k', 0x00]);
            unsigned(u64::from(HOST_IMPORTS) + count as u64, &mut exports);
        }
        section(7, exports, &mut module);

        // Éléments : la table pointe les blocs dans l'ordre, à partir de
        // l'emplacement de la région.
        let mut elements = vec![0x01, 0x00, code::I32_CONST];
        signed(i64::from(shared.unwrap_or(0)), &mut elements);
        elements.push(code::END);
        unsigned(count as u64, &mut elements);
        for block in 0..count {
            unsigned(u64::from(HOST_IMPORTS) + block as u64, &mut elements);
        }
        section(9, elements, &mut module);

        let mut code_section = Vec::new();
        unsigned(count as u64 + 1 + u64::from(paging), &mut code_section);
        for body in &bodies {
            let mut entry = vec![0x00];
            entry.extend_from_slice(body);
            unsigned(entry.len() as u64, &mut code_section);
            code_section.extend_from_slice(&entry);
        }
        if let Some(mask) = mask {
            let entry = Self::walk_body(mask);
            unsigned(entry.len() as u64, &mut code_section);
            code_section.extend_from_slice(&entry);
        }
        // La boucle : tant qu'il reste du budget, appeler le bloc courant et
        // prendre l'indice qu'il rend. Un indice négatif rend la main.
        let mut dispatch: Vec<u8> = vec![
            0x01, 0x01, 0x7f, // une locale i32 : le bloc courant
        ];
        // **Le bloc de départ est l'emplacement de la région, pas zéro.** Les
        // variables locales de WebAssembly naissent à zéro, ce qui tombait
        // juste tant que la répartition ajoutait l'emplacement. Elle ne
        // l'ajoute plus — un bloc rend un indice absolu — donc c'est ici qu'il
        // faut le poser, une fois, avant la boucle.
        if let Some(slot) = shared {
            dispatch.push(code::I32_CONST);
            signed(i64::from(slot), &mut dispatch);
            dispatch.extend_from_slice(&[0x21, 0x01]); // local.set 1
        }
        dispatch.extend_from_slice(&[
            0x02,
            0x40, // block
            0x03,
            0x40, //   loop
            0x20,
            0x00,
            code::I64_EQZ,
            0x0d,
            0x01, //     budget nul : sortir
            0x20,
            0x00,
            code::I64_CONST,
            0x01,
            code::I64_SUB,
            0x21,
            0x00,
            0x20,
            0x01, //   le bloc, indice absolu dans la table de l'hôte
        ]);
        // **Ce qu'un bloc rend est déjà l'indice absolu**, et c'est une
        // correction, pas un choix de départ. La répartition ajoutait
        // l'emplacement ici, au motif que les blocs se numérotaient depuis
        // zéro partout — vrai tant qu'une région n'appelle que ses propres
        // blocs. Dès qu'elle en appelle un d'ailleurs, c'est **cette**
        // répartition-ci qui continue de tourner, avec l'emplacement de la
        // région d'entrée, et le bloc étranger rend un numéro relatif au
        // sien : les deux ne se correspondent plus, et la machine part en
        // rond dans la mauvaise région. Un anneau de trois régions l'a
        // montré ; deux régions ne suffisaient pas, parce qu'il faut **deux**
        // sauts d'affilée pour que l'écart se voie.
        dispatch.extend_from_slice(&[
            0x11,
            0x00,
            0x00,
            0x21,
            0x01, //   bloc = call_indirect(bloc)
            0x20,
            0x01,
            0x41,
            0x00,
            0x48,
            0x0d,
            0x01, //   négatif : rendre la main
            0x0c,
            0x00,      //     recommencer
            code::END, //   fin de la boucle
            code::END, // fin du bloc
            code::END, // fin de la fonction
        ]);
        unsigned(dispatch.len() as u64, &mut code_section);
        code_section.extend_from_slice(&dispatch);
        section(10, code_section, &mut module);

        module
    }

    /// **La marche à quatre niveaux, gravée dans le module.**
    ///
    /// Une fonction interne, pas un import : un retour de main à l'hôte coûte
    /// 125 à 190 ns, ce qui rendrait un défaut de tampon plus cher que tout le
    /// reste. Elle prend une adresse invitée et rend la **trame** — l'adresse
    /// physique de sa page, alignée — après l'avoir posée dans le tampon.
    ///
    /// **Chaque niveau est replié par le masque.** Une entrée de table qui
    /// nommerait une trame au-dessus de la RAM déclarée atteindrait sinon le
    /// tampon lui-même et la correspondance des blocs, que le confinement est
    /// justement là pour mettre hors de portée.
    ///
    /// **Sur une entrée absente, elle ne pièges pas** : elle pose le témoin de
    /// faute et l'adresse dans CR2, et rend zéro. C'est l'appelant qui rend la
    /// main, en ligne, avant d'avoir touché la mémoire.
    ///
    /// Les grandes pages s'arrêtent où le bit PS les arrête, à n'importe quel
    /// niveau au-dessus de la feuille — ce qui couvre les deux mébioctets du
    /// direct map de Linux et le gibioctet des mêmes lignes.
    fn walk_body(mask: u32) -> Vec<u8> {
        // Locales, après le paramètre : l'entrée lue, la table courante, la
        // trame trouvée, et la case du tampon.
        let mut body = vec![
            0x04, // quatre groupes
            0x01, 0x7e, // 1 : i64, l'entrée
            0x01, 0x7f, // 2 : i32, la table
            0x01, 0x7e, // 3 : i64, la trame
            0x01, 0x7f, // 4 : i32, la case
        ];
        const ENTRY: u32 = 1;
        const TABLE: u32 = 2;
        const FRAME: u32 = 3;
        const CELL: u32 = 4;
        let tlb = tlb_base((mask + 1) / 65536);
        let mut b = Body::default();

        let fold = |b: &mut Body| {
            b.op(code::I32_WRAP_I64);
            b.bytes.push(code::I32_CONST);
            signed(i64::from(mask), &mut b.bytes);
            b.op(code::I32_AND);
        };
        // Poser la trame dans le tampon, puis la rendre. Écrit deux fois — une
        // fois pour les grandes pages, une fois pour la feuille — parce que
        // les deux sorties sont à des profondeurs différentes du code.
        let install = |b: &mut Body| {
            b.local_get(0)
                .constant(12)
                .op(code::I64_SHR_U)
                .constant(u64::from(TLB_SLOTS - 1))
                .op(code::I64_AND)
                .op(code::I32_WRAP_I64);
            b.bytes.push(code::I32_CONST);
            signed(i64::from(TLB_ENTRY), &mut b.bytes);
            b.op(code::I32_MUL);
            b.bytes.push(code::I32_CONST);
            signed(i64::from(tlb), &mut b.bytes);
            b.op(code::I32_ADD).local_tee(CELL);
            // L'étiquette : le numéro de page plus un.
            b.local_get(0)
                .constant(12)
                .op(code::I64_SHR_U)
                .constant(1)
                .op(code::I64_ADD);
            b.access(code::I64_STORE, 0);
            b.local_get(CELL).local_get(FRAME);
            b.access(code::I64_STORE32, 8);
            b.local_get(FRAME).op(code::I32_WRAP_I64).op(code::RETURN);
        };
        let fault = |b: &mut Body| {
            // Le code d'erreur zéro — une lecture sur une page absente — plus
            // un, pour qu'il ne se confonde pas avec « rien n'a fauté ».
            b.store(FAULT_SLOT, |b| {
                b.constant(1);
            });
            b.store(Self::control_slot(2), |b| {
                b.local_get(0);
            });
            b.bytes.push(code::I32_CONST);
            signed(0, &mut b.bytes);
            b.op(code::RETURN);
        };

        // La racine : CR3, ses bits d'adresse, repliée.
        b.load(Self::control_slot(3))
            .constant(ENTRY_FRAME)
            .op(code::I64_AND);
        fold(&mut b);
        b.local_set(TABLE);

        for level in [39u64, 30, 21, 12] {
            b.local_get(TABLE)
                .local_get(0)
                .constant(level)
                .op(code::I64_SHR_U)
                .constant(0x1FF)
                .op(code::I64_AND)
                .op(code::I32_WRAP_I64);
            b.bytes.push(code::I32_CONST);
            signed(8, &mut b.bytes);
            b.op(code::I32_MUL).op(code::I32_ADD);
            b.access(code::I64_LOAD, 0);
            b.local_tee(ENTRY)
                .constant(ENTRY_PRESENT)
                .op(code::I64_AND)
                .op(code::I64_EQZ);
            b.op(code::IF).op(code::VOID);
            fault(&mut b);
            b.op(code::END);

            if level > 12 {
                let size = 1u64 << level;
                b.local_get(ENTRY)
                    .constant(ENTRY_HUGE)
                    .op(code::I64_AND)
                    .op(code::I64_EQZ)
                    .op(code::I32_EQZ);
                b.op(code::IF).op(code::VOID);
                b.local_get(ENTRY)
                    .constant(ENTRY_FRAME & !(size - 1))
                    .op(code::I64_AND)
                    .local_get(0)
                    .constant((size - 1) & !0xFFF)
                    .op(code::I64_AND)
                    .op(code::I64_OR);
                fold(&mut b);
                b.op(code::I64_EXTEND_I32_U).local_set(FRAME);
                install(&mut b);
                b.op(code::END);
            }

            b.local_get(ENTRY).constant(ENTRY_FRAME).op(code::I64_AND);
            fold(&mut b);
            b.local_set(TABLE);
        }

        // La feuille : le dernier tour a mis la trame dans `TABLE`.
        b.local_get(TABLE)
            .op(code::I64_EXTEND_I32_U)
            .local_set(FRAME);
        install(&mut b);
        b.op(code::END);

        body.extend(b.bytes);
        body
    }

    /// L'emplacement d'un registre de contrôle. Les numéros ne sont pas
    /// contigus — le décodeur n'accepte que 0, 2, 3, 4 et 8 — donc la
    /// correspondance est écrite plutôt que calculée.
    fn control_slot(which: u8) -> usize {
        CONTROL_SLOT
            + match which {
                0 => 0,
                2 => 1,
                3 => 2,
                4 => 3,
                _ => 4, // CR8, le seul autre que le décodeur laisse passer
            }
    }

    /// Les deux emplacements d'une table : sa limite, puis sa base.
    fn table_slots(interrupts: bool) -> (usize, usize) {
        let at = TABLE_SLOT + if interrupts { 2 } else { 0 };
        (at, at + 1)
    }

    /// L'emplacement d'un sélecteur, dans l'ordre de l'énumération du
    /// décodeur : ES, CS, SS, DS, FS, GS.
    /// **FS ou GS : le nul se produit, le reste s'arrête en le disant.**
    ///
    /// **Ce que fait le silicium du nul, mesuré et non supposé.** Sur le
    /// processeur de ce conteneur, par un programme à syscalls bruts — passer
    /// par la libc entre les deux relevés toucherait `errno`, qui vit dans le
    /// TLS pointé par FS :
    ///
    /// ```text
    /// FS.base avant = 0x7f7da625f740
    /// xorl %eax,%eax ; movl %eax,%fs
    /// FS.base apres = 0x0
    /// ```
    ///
    /// La base est **effacée**, pas conservée. Un seul processeur ne fait pas
    /// une architecture, et ce dépôt n'a pas d'autre silicium sous la main :
    /// c'est écrit ici pour que la prochaine mesure sache ce qu'elle corrige.
    ///
    /// **Et le non-nul ne se range pas en silence.** Poser le sélecteur sans
    /// en tirer de base donnerait au noyau une adresse fausse, loin de sa
    /// cause — le défaut exact que le refus d'origine évitait. Il s'arrête donc
    /// avec sa raison, RIP **sur** l'instruction, qui n'a rien fait : c'est ce
    /// qui permettra de la rejouer le jour où les descripteurs existeront.
    fn load_far_segment(
        step: &Decoded,
        segment: Segment,
        address: u64,
        body: &mut Body,
    ) -> Option<()> {
        let base = match segment {
            Segment::Fs => FS_BASE_SLOT,
            _ => GS_SLOT,
        };
        // Le sélecteur, seize bits quelle que soit la largeur de la source.
        // **Aucun local temporaire** : `i64.eqz` le consomme, et la branche
        // nulle sait déjà qu'il vaut zéro — le garder serait le recopier pour
        // rien.
        body.load(Self::slot(step.dst))
            .constant(0xffff)
            .op(code::I64_AND);
        body.op(code::I64_EQZ);
        body.op(code::IF).op(code::VOID);
        // Nul : le sélecteur rangé, et la base effacée comme le fait le
        // processeur.
        body.store(Self::segment_slot(segment), |b| {
            b.constant(0);
        });
        body.store(base, |b| {
            b.constant(0);
        });
        body.op(0x05); // else
                       // Non nul : rien n'est écrit, et la machine dit ce qui lui manque.
        body.store(RIP_SLOT, |b| {
            b.constant(address);
        });
        body.store(STOP_SLOT, |b| {
            b.constant(STOP_SELECTOR);
        });
        body.bytes.push(code::I32_CONST);
        signed(-1, &mut body.bytes);
        body.op(code::RETURN);
        body.op(code::END);
        Some(())
    }

    fn segment_slot(segment: Segment) -> usize {
        SEGMENT_SLOT
            + match segment {
                Segment::Es => 0,
                Segment::Cs => 1,
                Segment::Ss => 2,
                Segment::Ds => 3,
                Segment::Fs => 4,
                Segment::Gs => 5,
            }
    }

    fn slot(register: u8) -> usize {
        register as usize
    }

    /// Pousser l'opérande de gauche, masqué à la largeur.
    fn left(step: &Decoded, body: &mut Body) {
        match step.memory {
            Some(address) if !step.memory_is_source => {
                body.load_memory(&address, step.width);
                return;
            }
            _ => {}
        }
        body.load(Self::slot(step.dst));
        if step.dst_high {
            body.constant(8).op(code::I64_SHR_U);
        }
        body.constant(step.width.mask()).op(code::I64_AND);
    }

    fn right(step: &Decoded, body: &mut Body) {
        if step.immediate {
            body.constant(step.imm & step.width.mask());
            return;
        }
        match step.memory {
            Some(address) if step.memory_is_source => {
                body.load_memory(&address, step.width);
                return;
            }
            _ => {}
        }
        body.load(Self::slot(step.src));
        if step.src_high {
            body.constant(8).op(code::I64_SHR_U);
        }
        body.constant(step.width.mask()).op(code::I64_AND);
    }

    fn translate(step: &Decoded, address: u64, body: &mut Body) -> Option<()> {
        // **RIP est posé avant tout accès mémoire, quand la pagination
        // existe.** Sans lui, une faute rendrait la main à l'hôte sur un RIP
        // laissé par le bloc précédent, et l'hôte reprendrait n'importe où.
        // `terminate` ne le pose qu'à la fin d'un bloc, ce qui suffisait tant
        // que rien ne pouvait s'arrêter au milieu.
        //
        // **Ce que ça coûte : rien de mesurable.** La forme `garde_rip` de
        // `examples/paging-probe.rs` la chronomètre — de −0,45 à +0,62 ns par
        // accès sur trois exécutions, une plage qui inclut zéro des deux
        // côtés. Voir `docs/DEMARRAGE.md`.
        if body.walk.is_some() && step.memory.is_some() {
            body.store(RIP_SLOT, |b| {
                b.constant(address);
            });
        }
        // **Un saut n'est pas une instruction comme une autre** : il change le
        // bloc, pas l'état. Il est traité par le compilateur de région, qui
        // seul connaît les autres blocs ; en ligne droite, il n'a aucun sens.
        if matches!(
            step.op,
            Op::Jump(_)
                | Op::LoopWhile
                | Op::JumpIndirect
                | Op::CallIndirect
                | Op::FarReturn
                | Op::InterruptReturn
                | Op::Undefined
        ) {
            return None;
        }
        // **Une entrée-sortie n'est pas un calcul, et le dire ici était
        // nécessaire.** Sans ce détour elles tombaient dans le chemin
        // arithmétique — mesuré, pas supposé : un test a fait sonner
        // l'`unreachable!` posé là-bas. Une région qui aurait écrit dans
        // l'accumulateur au lieu de parler à un périphérique se serait
        // comportée *presque* bien, ce qui est pire qu'un refus franc.
        if matches!(step.op, Op::PortIn | Op::PortOut) {
            return Self::port(step, body);
        }
        // **Le compteur d'horodatage, produit et non refusé.** Il ne demande
        // aucun modèle privilégié : une globale qui monte, et ses deux moitiés
        // dans EAX et EDX.
        if step.op == Op::ReadTimestamp {
            body.store(TSC_SLOT, |b| {
                b.load(TSC_SLOT).constant(TSC_STEP).op(code::I64_ADD);
            });
            // **`rdtsc` écrit EAX et EDX, pas RAX et RDX.** Écrire les
            // registres entiers laisserait la moitié haute d'avant dans RAX,
            // là où le processeur la met à zéro — et un noyau qui recompose
            // `edx:eax` lirait un compteur faux sans s'en apercevoir.
            body.store(Self::slot(RAX), |b| {
                b.load(TSC_SLOT).constant(0xffff_ffff).op(code::I64_AND);
            });
            body.store(Self::slot(RDX), |b| {
                b.load(TSC_SLOT)
                    .constant(32)
                    .op(code::I64_SHR_U)
                    .constant(0xffff_ffff)
                    .op(code::I64_AND);
            });
            return Some(());
        }
        // **`cpuid` : une table de constantes, et rien de privilégié.**
        //
        // La feuille arrive dans EAX et doit être lue **avant** qu'on écrive
        // dedans — sans quoi la valeur de la feuille zéro déciderait de la
        // feuille suivante. D'où le brouillon.
        //
        // Le choix entre les feuilles se fait par `select` plutôt que par un
        // branchement : deux `select` imbriqués valent quelques instructions,
        // là où un `if` ouvrirait un bloc dans un corps qui n'en attend pas.
        if step.op == Op::CpuId {
            body.store(Body::scratch(0), |b| {
                b.load(Self::slot(RAX))
                    .constant(0xffff_ffff)
                    .op(code::I64_AND);
            });
            // `select` dépile la condition, puis les deux valeurs : il rend la
            // **première** quand la condition n'est pas nulle.
            let leaf_is = |b: &mut Body, which: u64| {
                b.load(Body::scratch(0)).constant(which).op(code::I64_EQ);
            };
            let choose = |body: &mut Body, slot: usize, zero: u32, one: u32| {
                body.store(Self::slot(slot as u8), |b| {
                    // **`select` dépile la condition, puis deux valeurs**, et
                    // rend la **première** quand la condition n'est pas nulle.
                    // Le premier jet en empilait une de moins et le module ne
                    // se compilait pas — « can't pop empty stack », ce qui est
                    // au moins un refus franc.
                    b.constant(u64::from(zero)); // si la feuille est zéro
                    b.constant(u64::from(one)); // si c'est la feuille un
                    b.constant(0); // et sinon, rien
                    leaf_is(b, 1);
                    b.op(code::SELECT);
                    leaf_is(b, 0);
                    b.op(code::SELECT);
                });
            };
            // Hors des deux feuilles connues, tout est nul : c'est ce que rend
            // un processeur pour une feuille qu'il ne sert pas, et c'est aussi
            // ce qu'il faut dire quand on ne sait rien.
            // Les quatre registres que `cpuid` écrit, dans l'ordre du jeu
            // d'instructions : EAX, EBX, ECX, EDX — soit 0, 3, 1 et 2.
            choose(body, 0, CPUID_MAX_LEAF, CPUID_SIGNATURE);
            choose(body, 3, CPUID_VENDOR_EBX, 0);
            choose(body, 1, CPUID_VENDOR_ECX, 0);
            choose(body, 2, CPUID_VENDOR_EDX, CPUID_FEATURES_EDX);
            return Some(());
        }
        // **Les instructions privilégiées : décodées, pas traduisibles.**
        //
        // Le décodeur les nomme une par une depuis qu'un noyau s'est arrêté
        // dessus — d'abord `wrmsr` à sa huitième instruction, puis `lgdt`, puis
        // les sélecteurs de segment, puis `mov %cr4,%rcx`. Les *exécuter*
        // demande un modèle de MSR, de tables de descripteurs, de segments et
        // de registres de contrôle que rien n'a encore, et ce modèle est une
        // décision qui n'est pas prise. Le refus est donc franc et nommé —
        // `CannotTranslate` porte l'adresse — au lieu d'un `CannotDecode` qui
        // ne disait pas laquelle manquait.
        //
        // **Ce n'est pas un progrès en soi**, et l'exploration le montre : à
        // chaque famille lue, la frontière avance de quelques octets et
        // s'arrête sur la suivante. Ce qui change est qu'elle a un nom.
        // **Les registres de contrôle : le numéro est connu à la traduction.**
        //
        // C'est la différence avec les MSR, et elle change tout : le numéro vit
        // dans le champ `reg` du ModRM, donc « celui-ci oui, celui-là non » est
        // une décision qu'on peut prendre **ici**, sans aiguillage ni retour de
        // main. Un refus reste un refus de traduction, nommé, à son adresse.
        if let Op::ReadControlRegister { which } = step.op {
            Self::put(step.dst, step.width, body, |b| {
                b.load(Self::control_slot(which));
            });
            return Some(());
        }
        if let Op::WriteControlRegister { which } = step.op {
            // **CR0 et CR3 allument la pagination**, et jusqu'à cette tranche
            // les accepter aurait fait croire au noyau qu'il a une table de
            // pages sans qu'aucune adresse ne la traverse. C'est la traduction
            // qui les débloque : sans elle, le refus reste.
            //
            // **Les deux mises en forme n'acceptent donc pas la même chose**,
            // et c'est la seule ligne de ce fichier où c'est vrai. Un outil qui
            // mesure la forme libre ne mesure pas ce que l'application exécute
            // — deux d'entre eux l'ont fait pendant une tranche.
            // `only_the_confined_form_accepts_the_write_that_drives_paging` le
            // tient des deux côtés.
            //
            // **Combien de régions ça déplace, mesuré** : zéro. Sur les 10 116
            // entrées atteintes par un `call` du noyau Alpine, `coverage` rend
            // 9 980 compilées sous les deux formes, au refus près. Aucune
            // fenêtre de quatre kibioctets partant d'un début de fonction ne
            // contient d'écriture de CR0 ou de CR3 qui bloquerait à elle seule.
            // L'écart est réel et il ne se voit pas là — il se voit sur les
            // régions du chemin d'entrée, que `examples/kernel-entry.rs`
            // compile.
            matches!(which, 4 | 8)
                .then_some(())
                .or_else(|| body.walk.map(|_| ()))?;
            body.store(Self::control_slot(which), |b| {
                b.load(Self::slot(step.dst));
            });
            return Some(());
        }
        // **Les registres spécifiques au modèle : un aiguillage, pas une
        // décision de traduction.**
        //
        // Le numéro vit dans ECX, une valeur d'**exécution**. Le traducteur ne
        // peut donc pas décider « celui-ci oui, celui-là non » : il émet les
        // huit cas qu'il connaît et, pour tout autre numéro, un arrêt nommé qui
        // **porte le numéro**, RIP sur l'instruction.
        //
        // **Conséquence à ne pas laisser filer** : depuis cette tranche, une
        // région *compilée* n'est plus forcément une région qui *va au bout*.
        // Le relevé de couverture compte des traductions, plus des exécutions.
        if matches!(step.op, Op::ReadModelRegister | Op::WriteModelRegister) {
            let modelled = [
                (MSR_FS_BASE, FS_BASE_SLOT),
                (MSR_GS_BASE, GS_SLOT),
                (MSR_KERNEL_GS_BASE, KERNEL_GS_SLOT),
                (MSR_EFER, EFER_SLOT),
                (MSR_STAR, SYSCALL_SLOT),
                (MSR_LSTAR, SYSCALL_SLOT + 1),
                (MSR_CSTAR, SYSCALL_SLOT + 2),
                (MSR_SYSCALL_MASK, SYSCALL_SLOT + 3),
            ];
            // Le numéro, ramené à trente-deux bits comme le processeur le lit.
            body.store(Body::scratch(0), |b| {
                b.load(Self::slot(RCX))
                    .constant(0xffff_ffff)
                    .op(code::I64_AND);
            });
            // **L'arrêt vient d'abord**, sinon un numéro inconnu écrirait des
            // registres avant de s'arrêter, et l'instruction rejouée
            // repartirait d'un état qu'elle a elle-même abîmé.
            for (rank, (numéro, _)) in modelled.iter().enumerate() {
                body.load(Body::scratch(0))
                    .constant(*numéro)
                    .op(code::I64_EQ);
                if rank > 0 {
                    body.op(code::I32_OR);
                }
            }
            // Aucun des huit : le témoin porte le numéro, et la main est rendue.
            body.op(code::I32_EQZ);
            body.op(code::IF).op(code::VOID);
            body.store(RIP_SLOT, |b| {
                b.constant(address);
            });
            body.store(STOP_SLOT, |b| {
                b.load(Body::scratch(0)).constant(STOP_MSR).op(code::I64_OR);
            });
            body.bytes.push(code::I32_CONST);
            signed(-1, &mut body.bytes);
            body.op(code::RETURN);
            body.op(code::END);
            if step.op == Op::WriteModelRegister {
                // La valeur arrive en deux moitiés : EDX en haut, EAX en bas.
                body.store(Body::scratch(1), |b| {
                    b.load(Self::slot(RDX))
                        .constant(0xffff_ffff)
                        .op(code::I64_AND)
                        .constant(32)
                        .op(code::I64_SHL);
                    b.load(Self::slot(RAX))
                        .constant(0xffff_ffff)
                        .op(code::I64_AND);
                    b.op(code::I64_OR);
                });
                for (numéro, emplacement) in modelled {
                    body.store(emplacement, |b| {
                        b.load(Body::scratch(1)); // si le numéro est celui-ci
                        b.load(emplacement); // sinon, rien ne bouge
                        b.load(Body::scratch(0)).constant(numéro).op(code::I64_EQ);
                        b.op(code::SELECT);
                    });
                }
            } else {
                body.store(Body::scratch(1), |b| {
                    b.constant(0);
                });
                for (numéro, emplacement) in modelled {
                    body.store(Body::scratch(1), |b| {
                        b.load(emplacement);
                        b.load(Body::scratch(1));
                        b.load(Body::scratch(0)).constant(numéro).op(code::I64_EQ);
                        b.op(code::SELECT);
                    });
                }
                body.store(Self::slot(RAX), |b| {
                    b.load(Body::scratch(1))
                        .constant(0xffff_ffff)
                        .op(code::I64_AND);
                });
                body.store(Self::slot(RDX), |b| {
                    b.load(Body::scratch(1))
                        .constant(32)
                        .op(code::I64_SHR_U)
                        .constant(0xffff_ffff)
                        .op(code::I64_AND);
                });
            }
            return Some(());
        }
        // **`swapgs` : l'échange que le noyau fait à chaque entrée d'anneau.**
        // Il n'était pas produisible tant que la base du noyau n'existait pas ;
        // elle existe depuis cette tranche, et l'échange devient exact.
        if step.op == Op::SwapGs {
            body.store(Body::scratch(0), |b| {
                b.load(GS_SLOT);
            });
            body.store(GS_SLOT, |b| {
                b.load(KERNEL_GS_SLOT);
            });
            body.store(KERNEL_GS_SLOT, |b| {
                b.load(Body::scratch(0));
            });
            return Some(());
        }
        // **Les tables de descripteurs : dix octets, dans les deux sens.**
        //
        // La limite occupe les deux premiers octets, la base les huit suivants.
        // Le déplacement de deux se pose sur l'adresse déjà figée — `pin` a
        // résolu ce qui était relatif au pointeur d'instruction avant d'arriver
        // ici, donc ajouter deux au déplacement est exact dans les deux cas.
        if let Op::LoadDescriptorTable { interrupts } = step.op {
            let low = *step.memory.as_ref()?;
            let mut high = low;
            high.displacement = high.displacement.wrapping_add(2);
            let (limit, base) = Self::table_slots(interrupts);
            body.store(limit, |b| {
                b.load_memory(&low, Width::Word);
            });
            body.store(base, |b| {
                b.load_memory(&high, Width::Qword);
            });
            return Some(());
        }
        if let Op::StoreDescriptorTable { interrupts } = step.op {
            let low = *step.memory.as_ref()?;
            let mut high = low;
            high.displacement = high.displacement.wrapping_add(2);
            let (limit, base) = Self::table_slots(interrupts);
            body.store_memory(&low, Width::Word, |b| {
                b.load(limit);
            });
            body.store_memory(&high, Width::Qword, |b| {
                b.load(base);
            });
            return Some(());
        }
        // **Lire un sélecteur de segment : un aller-retour, et c'est tout.**
        //
        // La largeur vient du décodeur, qui la tire du préfixe `0x66`, et
        // `put` en fait ce que le processeur en fait : sans préfixe le
        // sélecteur est zéro-étendu sur soixante-quatre bits, avec lui seuls
        // les seize bits bas changent. Les deux formes ont été mesurées sur un
        // vrai processeur avant d'être écrites ici.
        if let Op::StoreSegment { segment } = step.op {
            // **La forme mémoire est refusée, et c'est une mesure, pas un
            // oubli** : sur les treize occurrences du noyau Alpine, treize sont
            // la forme registre. La produire demanderait un accès mémoire de
            // seize bits pour un cas que rien n'exerce.
            step.memory.is_none().then_some(())?;
            Self::put(step.dst, step.width, body, |b| {
                b.load(Self::segment_slot(segment));
            });
            return Some(());
        }
        // **Charger un sélecteur.**
        //
        // ES, SS et DS ont en mode 64 bits une base **forcée à zéro** : le
        // sélecteur ne décide plus d'aucune adresse, et le ranger suffit à être
        // fidèle. Charger CS ne se décode même pas : le processeur lève `#UD`.
        //
        // **FS et GS étaient refusés en bloc, et c'était trop large.** Les
        // charger relit un descripteur dans la table globale pour en tirer une
        // base, et cette table n'existe pas ici — mais **un sélecteur nul ne
        // lit aucun descripteur**. Le noyau met justement ses six segments à
        // zéro dans `head_64.S`, et c'est là que la quatrième région d'Alpine
        // refusait, à l'octet 319, deux instructions après un `xor %eax,%eax`.
        //
        // Le contrôle est donc à l'exécution, et il coûte une comparaison sur
        // une instruction que le démarrage exécute six fois.
        if let Op::LoadSegment { segment } = step.op {
            step.memory.is_none().then_some(())?;
            if matches!(segment, Segment::Fs | Segment::Gs) {
                return Self::load_far_segment(step, segment, address, body);
            }
            matches!(segment, Segment::Es | Segment::Ss | Segment::Ds).then_some(())?;
            body.store(Self::segment_slot(segment), |b| {
                // Un sélecteur fait seize bits, quelle que soit la largeur de
                // l'opérande source.
                b.load(Self::slot(step.dst))
                    .constant(0xffff)
                    .op(code::I64_AND);
            });
            return Some(());
        }
        // **Le drapeau d'interruption : un bit, comme celui de direction.**
        // `cli` et `sti` ne font rien de plus sur le silicium, et le produire
        // ne prétend pas que les interruptions marchent — rien ne délivre
        // encore. Ce que ça change est qu'une région ne se fait plus refuser
        // pour eux.
        if let Op::InterruptFlag(set) = step.op {
            body.store(RFLAGS_SLOT, |b| {
                if set {
                    b.load(RFLAGS_SLOT).constant(IF).op(code::I64_OR);
                } else {
                    b.load(RFLAGS_SLOT).constant(!IF).op(code::I64_AND);
                }
            });
            return Some(());
        }
        // **`invlpg` : la case du tampon que la page occupe est effacée.**
        //
        // Le tampon est direct — une case par numéro de page, modulo sa
        // taille — et son étiquette à zéro veut dire « vide » : écrire zéro
        // dans l'étiquette suffit, quelle que soit la page qui l'occupait.
        // L'adresse est **linéaire**, calculée comme pour `lea` : elle n'est
        // ni traduite ni lue, donc une page absente ne faute pas. Sans
        // pagination il n'y a pas de tampon, et rien à faire.
        //
        // C'est ce que le test du tampon exhibait depuis la pagination P2 :
        // après avoir réécrit sa propre entrée de feuille, l'invité relisait
        // encore l'ancienne trame. Le noyau Alpine y arrive dans
        // `native_flush_tlb_one_user`.
        if step.op == Op::InvalidatePage {
            let target = step.memory?;
            if let (Some(mask), true) = (body.confine, body.walk.is_some()) {
                let tlb = tlb_base((mask + 1) / 65536);
                body.wide_address(&target);
                body.constant(12)
                    .op(code::I64_SHR_U)
                    .constant(u64::from(TLB_SLOTS - 1))
                    .op(code::I64_AND)
                    .constant(u64::from(TLB_ENTRY))
                    .op(code::I64_MUL)
                    .constant(u64::from(tlb))
                    .op(code::I64_ADD)
                    .op(code::I32_WRAP_I64);
                body.constant(0);
                body.access(code::I64_STORE, 0);
            }
            return Some(());
        }
        // **`vmcall` et `vmmcall` s'arrêtent dessus et le disent.** Pas
        // d'hyperviseur au-dessus de cette machine. Décoder plutôt que
        // refuser, parce que la sonde VMware du noyau est à portée statique
        // d'une région qu'il exécute, et qu'il n'appelle l'hyperviseur que si
        // CPUID le promet — ce que `cpuid` ne fait pas.
        if let Op::HypervisorCall { .. } = step.op {
            body.store(RIP_SLOT, |b| {
                b.constant(address);
            });
            body.store(STOP_SLOT, |b| {
                b.constant(STOP_HYPERVISOR);
            });
            body.bytes.push(code::I32_CONST);
            signed(-1, &mut body.bytes);
            body.op(code::RETURN);
            return Some(());
        }
        // **`ltr` range le sélecteur et continue.** Seize bits, quelle que soit
        // la largeur de la source — comme ES, SS et DS. Rien n'est lu derrière :
        // le TSS reste inconnu de la délivrance, qui le dit.
        if step.op == Op::LoadTaskRegister {
            step.memory.is_none().then_some(())?;
            body.store(TASK_SLOT, |b| {
                b.load(Self::slot(step.dst))
                    .constant(0xffff)
                    .op(code::I64_AND);
            });
            return Some(());
        }
        // **Les registres de débogage : lire rend le repos, écrire le repos
        // passe, écrire autre chose s'arrête et le dit.** Cette machine n'a
        // pas de points d'arrêt matériels, et `cpu_init` ne fait que les
        // effacer — zéro dans les adresses et DR7, `DR6_RESERVED` dans DR6.
        if let Op::ReadDebugRegister { which } = step.op {
            Self::put(step.dst, step.width, body, |b| {
                b.constant(debug_register_at_rest(which));
            });
            return Some(());
        }
        if let Op::WriteDebugRegister { which } = step.op {
            body.load(Self::slot(step.dst))
                .constant(!debug_register_at_rest(which))
                .op(code::I64_AND);
            body.op(code::I64_EQZ);
            body.op(code::I32_EQZ);
            body.op(code::IF).op(code::VOID);
            body.store(RIP_SLOT, |b| {
                b.constant(address);
            });
            body.store(STOP_SLOT, |b| {
                b.constant(STOP_DEBUG);
            });
            body.bytes.push(code::I32_CONST);
            signed(-1, &mut body.bytes);
            body.op(code::RETURN);
            body.op(code::END);
            return Some(());
        }
        // **`lldt` : le nul passe, le reste s'arrête et le dit.** Seize bits,
        // comme les segments. Zéro ne charge rien — c'est le noyau qui dit
        // « pas de LDT » — et continue ; tout autre sélecteur désignerait un
        // descripteur qu'aucune table ne porte ici.
        if step.op == Op::LoadLocalDescriptorTable {
            step.memory.is_none().then_some(())?;
            body.load(Self::slot(step.dst))
                .constant(0xffff)
                .op(code::I64_AND);
            body.op(code::I64_EQZ);
            body.op(code::I32_EQZ);
            body.op(code::IF).op(code::VOID);
            body.store(RIP_SLOT, |b| {
                b.constant(address);
            });
            body.store(STOP_SLOT, |b| {
                b.constant(STOP_LDT);
            });
            body.bytes.push(code::I32_CONST);
            signed(-1, &mut body.bytes);
            body.op(code::RETURN);
            body.op(code::END);
            return Some(());
        }
        // **`invpcid` s'arrête dessus et le dit.** Pas de PCID sur cette
        // machine, donc rien à purger par identifiant de contexte — et le
        // noyau ne l'exécute que si `cpuid` le promet, ce qu'il ne fait pas.
        // Décoder plutôt que refuser, parce qu'elle est à portée statique de
        // `native_flush_tlb_one_user`, que le noyau exécute vraiment.
        if step.op == Op::InvalidatePcid {
            body.store(RIP_SLOT, |b| {
                b.constant(address);
            });
            body.store(STOP_SLOT, |b| {
                b.constant(STOP_PCID);
            });
            body.bytes.push(code::I32_CONST);
            signed(-1, &mut body.bytes);
            body.op(code::RETURN);
            return Some(());
        }
        // **`lkgs` s'arrête dessus et le dit.** Pas de table de descripteurs
        // d'où lire la base : le témoin est posé, RIP reste **sur**
        // l'instruction, et la main est rendue. Décoder plutôt que refuser,
        // parce que `native_lkgs` est à portée statique d'une région que le
        // noyau exécute vraiment, et qu'il ne l'appelle que si CPUID le
        // promet — ce que `cpuid` ne fait pas.
        if step.op == Op::LoadKernelGs {
            body.store(RIP_SLOT, |b| {
                b.constant(address);
            });
            body.store(STOP_SLOT, |b| {
                b.constant(STOP_KERNEL_GS);
            });
            body.bytes.push(code::I32_CONST);
            signed(-1, &mut body.bytes);
            body.op(code::RETURN);
            return Some(());
        }
        // **`hlt` s'arrête et le dit.** Le témoin posé, RIP après
        // l'instruction, et la main rendue par un indice négatif — le même
        // chemin qu'une faute de page, qui existait déjà.
        if step.op == Op::Halt {
            body.store(RIP_SLOT, |b| {
                b.constant(address.wrapping_add(step.length as u64));
            });
            body.store(STOP_SLOT, |b| {
                b.constant(STOP_HALTED);
            });
            body.bytes.push(code::I32_CONST);
            signed(-1, &mut body.bytes);
            body.op(code::RETURN);
            return Some(());
        }
        // **`int3` et `int n` : le témoin porte le vecteur, et RIP est déjà
        // après l'instruction.** Même chemin que `hlt`, à ceci près que l'hôte
        // saura reprendre : il délivre le vecteur et efface le témoin.
        if step.op == Op::SoftwareInterrupt {
            body.store(RIP_SLOT, |b| {
                b.constant(address.wrapping_add(step.length as u64));
            });
            body.store(STOP_SLOT, |b| {
                b.constant(STOP_INTERRUPT | (step.imm & 0xff));
            });
            body.bytes.push(code::I32_CONST);
            signed(-1, &mut body.bytes);
            body.op(code::RETURN);
            return Some(());
        }
        // Ne rien faire n'émet rien.
        if step.op == Op::Nop {
            return Some(());
        }
        // **Le drapeau de direction : un bit, posé en clair.**
        if let Op::DirectionFlag(set) = step.op {
            body.store(RFLAGS_SLOT, |b| {
                if set {
                    b.load(RFLAGS_SLOT).constant(DF).op(code::I64_OR);
                } else {
                    b.load(RFLAGS_SLOT).constant(!DF).op(code::I64_AND);
                }
            });
            return Some(());
        }
        if matches!(step.op, Op::StringMove { .. } | Op::StringStore { .. }) {
            return Self::string(step, body);
        }
        // La pile écrit **deux** choses — RSP et la mémoire, ou RSP et un
        // registre — et sort donc de la machinerie à une destination.
        if matches!(
            step.op,
            Op::Push | Op::Pop | Op::Leave | Op::PushFlags | Op::PopFlags
        ) {
            Self::stack(step, body);
            return Some(());
        }
        // `call` et `ret` ne passent jamais par ici : `region` les laisse à
        // `terminate`, qui seul connaît les autres blocs. Les refuser garde ce
        // contrat vérifiable — si un jour l'un d'eux arrive ici, la région est
        // refusée plutôt que traduite à moitié.
        if step.op == Op::Call || step.op == Op::Return {
            return None;
        }
        if let Op::RotateThroughCarry { left } = step.op {
            Self::rotate_through_carry(step, left, body);
            return Some(());
        }
        if let Op::DoubleShift { left } = step.op {
            Self::double_shift(step, left, body);
            return Some(());
        }
        if matches!(
            step.op,
            Op::Exchange
                | Op::ExchangeAndAdd
                | Op::CompareAndExchange
                | Op::CompareAndExchangeSixteen
        ) {
            Self::exchange(step, body);
            return Some(());
        }
        if matches!(
            step.op,
            Op::WideMultiply { .. }
                | Op::Multiply
                | Op::Divide { .. }
                | Op::WidenAccumulator
                | Op::SignIntoData
                | Op::CarryFlag(_)
        ) {
            Self::two_registers(step, address, body);
            return Some(());
        }
        // **Les décalages ont leurs propres règles**, et les faire passer par
        // la machinerie à deux opérandes en donnerait quatre fausses. Ils
        // sortent ici, exactement comme dans l'interpréteur — deux cœurs qui
        // divergent de forme finissent par diverger de fond.
        if matches!(step.op, Op::Shl | Op::Shr | Op::Sar) {
            Self::shift(step, body);
            return Some(());
        }
        // Les rotations ont leur propre traduction : elles ne posent que deux
        // drapeaux, et les quatre autres doivent survivre intacts.
        if matches!(step.op, Op::Rol | Op::Ror) {
            Self::rotate(step, body);
            return Some(());
        }
        // `lea` : une somme, un décalage, et aucun drapeau.
        if step.op == Op::Lea {
            return Self::lea(step, body);
        }
        // Les bits : chacun ses drapeaux, de la seule retenue à aucun.
        if let Op::Bit(action) = step.op {
            Self::bit(step, action, body);
            return Some(());
        }
        if let Op::BitScan { from_the_top } = step.op {
            Self::scan(step, from_the_top, body);
            return Some(());
        }
        if step.op == Op::Popcount {
            Self::popcount(step, body);
            return Some(());
        }
        if step.op == Op::ByteSwap {
            Self::byte_swap(step, body);
            return Some(());
        }
        // Les conditions : elles lisent les drapeaux et n'en écrivent aucun.
        if let Op::Set(condition) = step.op {
            body.store(Body::scratch(2), |b| Self::condition(condition, b));
            Self::write_back(step, step.width.mask(), body);
            return Some(());
        }
        if let Op::CondMove(condition) = step.op {
            body.store(Body::scratch(2), |b| {
                Self::right(step, b);
                Self::left(step, b);
                Self::condition(condition, b);
                // `select` prend la première valeur quand la condition tient :
                // la source si elle tient, la destination sinon. Et l'écriture
                // a lieu **dans les deux cas** — c'est ce qui fait qu'un
                // `cmov` de 32 bits efface la moitié haute même quand il ne
                // déplace rien.
                b.op(code::I32_WRAP_I64).op(code::SELECT);
            });
            Self::write_back(step, step.width.mask(), body);
            return Some(());
        }

        // **Les transferts ont deux largeurs et zéro drapeau.** Les faire
        // passer plus bas lirait la source à la largeur de la destination —
        // `movzbq %cl, %rax` rendrait `rcx` entier — et poserait des drapeaux
        // que le processeur laisse intacts.
        if matches!(step.op, Op::Mov | Op::Movsx) {
            Self::transfer(step, body);
            return Some(());
        }

        let mask = step.width.mask();
        let sign = step.width.sign();

        // Les deux opérandes sont posés en mémoire de travail : la traduction
        // les relit plusieurs fois pour les drapeaux, et les recalculer serait
        // du code en plus pour rien.
        body.store(Body::scratch(0), |b| Self::left(step, b));
        body.store(Body::scratch(1), |b| Self::right(step, b));

        // Le résultat.
        body.store(Body::scratch(2), |b| {
            match step.op {
                Op::Add => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_ADD);
                }
                Op::PortIn | Op::PortOut => unreachable!(
                    "une entrée-sortie n'est pas un calcul : `translate` la détourne vers `port`"
                ),
                Op::ReadTimestamp
                | Op::CpuId
                | Op::ReadModelRegister
                | Op::WriteModelRegister
                | Op::FarReturn | Op::InterruptReturn
                | Op::LoadDescriptorTable { .. }
                | Op::StoreDescriptorTable { .. }
                | Op::SwapGs
                | Op::LoadKernelGs
                | Op::InvalidatePage
                | Op::HypervisorCall { .. }
                | Op::InvalidatePcid
                | Op::LoadTaskRegister
                | Op::LoadLocalDescriptorTable
                | Op::ReadDebugRegister { .. }
                | Op::WriteDebugRegister { .. }
                | Op::LoadSegment { .. }
                | Op::StoreSegment { .. }
                | Op::ReadControlRegister { .. }
                | Op::WriteControlRegister { .. }
                | Op::InterruptFlag(_)
                | Op::Halt
                | Op::SoftwareInterrupt => {
                    unreachable!("une instruction privilégiée n'est pas un calcul : `translate` la traite avant")
                }
                Op::Sub | Op::Cmp => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_SUB);
                }
                Op::Adc => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_ADD);
                    b.load(RFLAGS_SLOT).constant(CF).op(code::I64_AND);
                    b.op(code::I64_ADD);
                }
                Op::Sbb => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_SUB);
                    b.load(RFLAGS_SLOT).constant(CF).op(code::I64_AND);
                    b.op(code::I64_SUB);
                }
                Op::And | Op::Test => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_AND);
                }
                Op::Or => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_OR);
                }
                Op::Xor => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_XOR);
                }
                Op::Inc => {
                    b.load(Body::scratch(0)).constant(1).op(code::I64_ADD);
                }
                Op::Dec => {
                    b.load(Body::scratch(0)).constant(1).op(code::I64_SUB);
                }
                Op::Neg => {
                    b.constant(0).load(Body::scratch(0)).op(code::I64_SUB);
                }
                Op::Not => {
                    b.load(Body::scratch(0))
                        .constant(u64::MAX)
                        .op(code::I64_XOR);
                }
                Op::Shl | Op::Shr | Op::Sar => unreachable!("les décalages sortent avant"),
                Op::Mov | Op::Movsx => unreachable!("les transferts sortent avant"),
                Op::Rol | Op::Ror => unreachable!("les rotations sortent avant"),
                Op::Lea => unreachable!("lea sort avant"),
                Op::Set(_) | Op::CondMove(_) => unreachable!("les conditions sortent avant"),
                Op::Bit(_) | Op::BitScan { .. } | Op::Popcount | Op::ByteSwap => {
                    unreachable!("les bits sortent avant")
                }
                Op::Jump(_) | Op::LoopWhile | Op::JumpIndirect => {
                    unreachable!("les sauts sortent avant")
                }
                Op::Nop => unreachable!("ne rien faire sort avant"),
                Op::Undefined => unreachable!("l'instruction indéfinie sort avant"),
                Op::DirectionFlag(_) | Op::StringMove { .. } | Op::StringStore { .. } => {
                    unreachable!("la direction et les chaînes sortent avant")
                }
                Op::Push
                | Op::Pop
                | Op::Call
                | Op::CallIndirect
                | Op::Return
                | Op::Leave
                | Op::PushFlags
                | Op::PopFlags => {
                    unreachable!("la pile sort avant")
                }
                Op::WideMultiply { .. }
                | Op::Multiply
                | Op::Divide { .. }
                | Op::WidenAccumulator
                | Op::SignIntoData
                | Op::CarryFlag(_) => {
                    unreachable!("les deux registres sortent avant")
                }
                Op::Exchange
                | Op::ExchangeAndAdd
                | Op::CompareAndExchange
                | Op::CompareAndExchangeSixteen => {
                    unreachable!("les échanges sortent avant")
                }
                Op::RotateThroughCarry { .. } | Op::DoubleShift { .. } => {
                    unreachable!("les rotations à travers la retenue sortent avant")
                }
            }
            b.constant(mask).op(code::I64_AND);
        });

        // **Les opérandes des drapeaux ne sont pas toujours ceux du décodeur**,
        // et c'est le piège qui a coûté 339 cas au premier passage.
        //
        // `inc` n'a pas d'opérande source : son champ `src` reste à zéro, donc
        // « droite » désignait le registre 0. La demi-retenue, qui vaut
        // `(gauche ^ droite ^ résultat) & 0x10`, lisait alors `rax` au lieu de
        // **1**, et se trompait chaque fois que les deux différaient sur ce
        // bit. Le silicium l'a dit ; rien d'autre ne l'aurait dit.
        //
        // `neg` a le même défaut sous une autre forme : c'est `0 - opérande`,
        // donc ses opérandes de drapeaux sont zéro et l'original, pas ceux que
        // le décodeur a rendus.
        match step.op {
            Op::Inc | Op::Dec => {
                body.store(Body::scratch(1), |b| {
                    b.constant(1);
                });
            }
            Op::Neg => {
                // L'ordre compte : l'original doit être recopié **avant** que
                // sa case ne soit écrasée par zéro.
                body.store(Body::scratch(1), |b| {
                    b.load(Body::scratch(0));
                });
                body.store(Body::scratch(0), |b| {
                    b.constant(0);
                });
            }
            _ => {}
        }

        // **`not` ne touche à aucun drapeau.** C'est la seule du groupe, et
        // l'oublier donnerait un cœur qui écrase des drapeaux que le vrai
        // processeur préserve.
        if step.op != Op::Not {
            Self::flags(step, mask, sign, body);
        }

        if !step.discards {
            Self::write_back(step, mask, body);
        }
        Some(())
    }

    /// **Un décalage, traduit sans un seul branchement.**
    ///
    /// La règle « un compte nul ne touche à rien » demanderait un `if` ; elle
    /// est rendue par `select`, qui choisit entre l'ancien état et le nouveau
    /// après avoir calculé les deux. C'est plus de code émis et moins de code
    /// **exécuté** : un saut mal prédit coûte plus cher que quelques opérations
    /// arithmétiques, et un cœur qui décale en décale beaucoup.
    fn shift(step: &Decoded, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let sign = width.sign();
        let bits: u64 = if width == Width::Qword {
            64
        } else {
            (width as u64) * 8
        };
        let count_mask: u64 = if width == Width::Qword { 63 } else { 31 };

        // scratch 0 : l'opérande. scratch 1 : le compte, déjà masqué.
        body.store(Body::scratch(0), |b| {
            Self::left(step, b);
        });
        body.store(Body::scratch(1), |b| {
            if step.count_is_cl {
                // **Le compte vient de `%cl`**, l'octet bas de `rcx`. Le
                // masque à 0xff serait redondant : celui à 31 ou 63 ci-dessous
                // le subsume, puisque 63 tient déjà dans un octet. Un sabotage
                // l'a montré — il ne faisait tomber aucun cas — et du code que
                // rien ne peut tenir n'a pas sa place ici.
                b.load(Self::slot(1));
            } else {
                b.constant(step.imm);
            }
            b.constant(count_mask).op(code::I64_AND);
        });

        // scratch 2 : le résultat, calculé sans se soucier du compte nul.
        body.store(Body::scratch(2), |b| {
            match step.op {
                Op::Shl => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_SHL);
                }
                Op::Shr => {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_SHR_U);
                }
                _ => {
                    // Arithmétique : étendre le signe à soixante-quatre bits
                    // avant de décaler, sinon les bits recopiés seraient ceux
                    // du mot entier et pas ceux de l'opérande.
                    b.load(Body::scratch(0))
                        .constant(64 - bits)
                        .op(code::I64_SHL);
                    b.constant(64 - bits).op(code::I64_SHR_S);
                    b.load(Body::scratch(1)).op(code::I64_SHR_S);
                }
            }
            b.constant(mask).op(code::I64_AND);
        });

        // scratch 3 : la retenue, le **dernier bit sorti**.
        body.store(Body::scratch(3), |b| {
            match step.op {
                Op::Shl => {
                    // **L'ordre de la pile compte** : `shr_u` prend la valeur
                    // puis le compte. Les inverser produit un module valide
                    // qui décale le compte par la valeur — faux en silence.
                    b.load(Body::scratch(0));
                    b.constant(bits).load(Body::scratch(1)).op(code::I64_SUB);
                    b.op(code::I64_SHR_U);
                    b.constant(1).op(code::I64_AND);
                    // Au-delà de la largeur il n'y a plus rien à sortir, et
                    // l'architecture ne définit plus la retenue.
                    b.constant(0);
                    b.load(Body::scratch(1)).constant(bits).op(code::I64_LE_U);
                    b.op(code::SELECT);
                }
                Op::Shr => {
                    b.load(Body::scratch(0));
                    b.load(Body::scratch(1)).constant(1).op(code::I64_SUB);
                    b.op(code::I64_SHR_U).constant(1).op(code::I64_AND);
                }
                _ => {
                    // **`sar` sature, et sa retenue avec lui.** Décaler un
                    // octet de trente et un bits ne laisse que des bits de
                    // signe, et le dernier sorti **est** le bit de signe.
                    // Partager la formule de `shr` donnerait zéro — mesuré :
                    // cinquante cas, tous sur `sar`, tous sur ce bit.
                    b.load(Body::scratch(0));
                    b.load(Body::scratch(1)).constant(1).op(code::I64_SUB);
                    b.op(code::I64_SHR_U).constant(1).op(code::I64_AND);
                    b.load(Body::scratch(0))
                        .constant(bits - 1)
                        .op(code::I64_SHR_U);
                    b.constant(1).op(code::I64_AND);
                    b.load(Body::scratch(1)).constant(bits).op(code::I64_LT_U);
                    b.op(code::SELECT);
                }
            }
        });

        // scratch 4 : le débordement. Défini pour un décalage de un seulement ;
        // ailleurs le masque de l'oracle l'ignore, et inventer une valeur
        // serait inventer une règle.
        body.store(Body::scratch(4), |b| match step.op {
            Op::Shl => {
                b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
                b.load(Body::scratch(3)).op(code::I64_XOR);
            }
            Op::Shr => {
                // Le bit de signe **d'origine** : c'est lui qui disparaît.
                b.load(Body::scratch(0)).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
            }
            _ => {
                b.constant(0);
            }
        });

        // Les drapeaux, puis le choix.
        body.store(RFLAGS_SLOT, |b| {
            // Le nouvel état.
            b.load(RFLAGS_SLOT)
                .constant(!(CF | PF | AF | ZF | SF | OF))
                .op(code::I64_AND);

            b.load(Body::scratch(2)).op(code::I64_EQZ);
            b.op(code::I64_EXTEND_I32_U)
                .constant(ZF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);

            b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
            b.constant(SF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            b.load(Body::scratch(2)).constant(0xff).op(code::I64_AND);
            b.op(code::I64_POPCNT).constant(1).op(code::I64_AND);
            b.constant(1).op(code::I64_XOR);
            b.constant(PF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            b.load(Body::scratch(3))
                .constant(CF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);
            b.load(Body::scratch(4)).constant(1).op(code::I64_AND);
            b.constant(OF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            // L'ancien, et le choix : **un compte nul ne touche à rien**.
            b.load(RFLAGS_SLOT);
            b.load(Body::scratch(1)).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });

        // **Un compte nul ne change aucun drapeau — mais il écrit quand même.**
        // C'est la règle qui manquait aux deux cœurs : `shll %cl, %eax` avec
        // `cl` à zéro laisse `eax` tel quel *et* efface les trente-deux bits
        // de poids fort, parce que toute écriture 32 bits les efface. C'est
        // l'écriture ci-dessous qui la tient : elle a lieu quel que soit le
        // compte, avec la règle de largeur.
        //
        // Il y avait ici un `select` qui reprenait l'opérande quand le compte
        // était nul. Un sabotage l'a retiré sans faire tomber un seul cas, et
        // c'est juste : décaler de zéro un opérande déjà masqué **rend cet
        // opérande**, pour les trois décalages. Le choix ne choisissait rien.
        // La même écriture que partout ailleurs — registre ou mémoire, règle de
        // largeur comprise. Elle était recopiée ici ; la recopie a survécu au
        // jour où la destination a pu être en mémoire, et elle aurait écrit
        // dans un registre ce que l'invité attendait dans sa RAM.
        if !step.discards {
            Self::write_back(step, mask, body);
        }
    }

    fn flags(step: &Decoded, mask: u64, sign: u64, body: &mut Body) {
        // Ce qui survit : tout sauf les six bits arithmétiques, plus la retenue
        // quand `inc` ou `dec` doit la préserver.
        let preserved = if matches!(step.op, Op::Inc | Op::Dec) {
            !(PF | AF | ZF | SF | OF)
        } else {
            !(CF | PF | AF | ZF | SF | OF)
        };

        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(preserved).op(code::I64_AND);

            // ZF
            b.load(Body::scratch(2)).op(code::I64_EQZ);
            b.op(code::I64_EXTEND_I32_U)
                .constant(ZF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);

            // SF
            b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
            b.constant(SF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            // PF : la parité de l'octet de poids faible, un legs du 8080 que le
            // vrai processeur applique toujours.
            b.load(Body::scratch(2)).constant(0xff).op(code::I64_AND);
            b.op(code::I64_POPCNT).constant(1).op(code::I64_AND);
            b.constant(1).op(code::I64_XOR);
            b.constant(PF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            // AF : la même identité pour l'addition et la soustraction, parce
            // que a - b, c'est a + (-b).
            b.load(Body::scratch(0))
                .load(Body::scratch(1))
                .op(code::I64_XOR);
            b.load(Body::scratch(2)).op(code::I64_XOR);
            b.constant(0x10).op(code::I64_AND);
            b.constant(AF.trailing_zeros() as u64 - 4).op(code::I64_SHL);
            b.op(code::I64_OR);

            Self::carry_and_overflow(step, mask, sign, b);
        });
    }

    fn carry_and_overflow(step: &Decoded, _mask: u64, sign: u64, b: &mut Body) {
        let shift_to = |bit: u64| bit.trailing_zeros() as u64;
        match step.op {
            Op::FarReturn | Op::InterruptReturn => {
                unreachable!("un retour lointain ou d'interruption change le bloc : `translate` le rend au compilateur de région")
            }
            Op::PortIn | Op::PortOut => {
                unreachable!(
                    "une entrée-sortie n'est pas un calcul : `translate` la détourne vers `port`"
                )
            }
            Op::ReadTimestamp
            | Op::CpuId
            | Op::ReadModelRegister
            | Op::WriteModelRegister
            | Op::LoadDescriptorTable { .. }
            | Op::StoreDescriptorTable { .. }
            | Op::SwapGs
            | Op::LoadKernelGs
            | Op::InvalidatePage
            | Op::HypervisorCall { .. }
            | Op::InvalidatePcid
            | Op::LoadTaskRegister
            | Op::LoadLocalDescriptorTable
            | Op::ReadDebugRegister { .. }
            | Op::WriteDebugRegister { .. }
            | Op::LoadSegment { .. }
            | Op::StoreSegment { .. }
            | Op::ReadControlRegister { .. }
            | Op::WriteControlRegister { .. }
            | Op::InterruptFlag(_)
            | Op::Halt
            | Op::SoftwareInterrupt => {
                unreachable!(
                    "une instruction privilégiée n'est pas un calcul : `translate` la traite avant"
                )
            }
            Op::And | Op::Or | Op::Xor | Op::Test => {}
            Op::Add | Op::Adc => {
                // CF : le résultat est passé sous l'opérande de gauche.
                b.load(Body::scratch(2))
                    .load(Body::scratch(0))
                    .op(code::I64_LT_U);
                b.op(code::I64_EXTEND_I32_U);
                // `adc` avec une retenue entrante : l'égalité compte aussi.
                if step.op == Op::Adc {
                    b.load(Body::scratch(2))
                        .load(Body::scratch(0))
                        .op(code::I64_SUB);
                    b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                    b.load(RFLAGS_SLOT).constant(CF).op(code::I64_AND);
                    b.op(code::I64_AND).op(code::I64_OR);
                    b.constant(1).op(code::I64_AND);
                }
                b.constant(shift_to(CF)).op(code::I64_SHL).op(code::I64_OR);
                // OF
                b.load(Body::scratch(0))
                    .load(Body::scratch(2))
                    .op(code::I64_XOR);
                b.load(Body::scratch(1))
                    .load(Body::scratch(2))
                    .op(code::I64_XOR);
                b.op(code::I64_AND).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
                b.constant(shift_to(OF)).op(code::I64_SHL).op(code::I64_OR);
            }
            Op::Sub | Op::Cmp | Op::Sbb | Op::Neg => {
                b.load(Body::scratch(0))
                    .load(Body::scratch(1))
                    .op(code::I64_LT_U);
                b.op(code::I64_EXTEND_I32_U);
                if step.op == Op::Sbb {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_SUB);
                    b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                    b.load(RFLAGS_SLOT).constant(CF).op(code::I64_AND);
                    b.op(code::I64_AND).op(code::I64_OR);
                    b.constant(1).op(code::I64_AND);
                }
                b.constant(shift_to(CF)).op(code::I64_SHL).op(code::I64_OR);
                b.load(Body::scratch(0))
                    .load(Body::scratch(1))
                    .op(code::I64_XOR);
                b.load(Body::scratch(0))
                    .load(Body::scratch(2))
                    .op(code::I64_XOR);
                b.op(code::I64_AND).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
                b.constant(shift_to(OF)).op(code::I64_SHL).op(code::I64_OR);
            }
            Op::Inc => {
                b.load(Body::scratch(0))
                    .load(Body::scratch(2))
                    .op(code::I64_XOR);
                b.constant(1).load(Body::scratch(2)).op(code::I64_XOR);
                b.op(code::I64_AND).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
                b.constant(shift_to(OF)).op(code::I64_SHL).op(code::I64_OR);
            }
            Op::Dec => {
                b.load(Body::scratch(0)).constant(1).op(code::I64_XOR);
                b.load(Body::scratch(0))
                    .load(Body::scratch(2))
                    .op(code::I64_XOR);
                b.op(code::I64_AND).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
                b.constant(shift_to(OF)).op(code::I64_SHL).op(code::I64_OR);
            }
            Op::Not => {}
            // Traités par `shift` et `transfer`, qui sortent avant d'arriver
            // ici. Les transferts, eux, ne posent **aucun** drapeau.
            Op::Shl
            | Op::Shr
            | Op::Sar
            | Op::Mov
            | Op::Movsx
            | Op::Rol
            | Op::Ror
            | Op::Lea
            | Op::Set(_)
            | Op::CondMove(_)
            | Op::Bit(_)
            | Op::BitScan { .. }
            | Op::Popcount
            | Op::ByteSwap
            | Op::Jump(_)
            | Op::LoopWhile
            | Op::JumpIndirect
            | Op::Nop
            | Op::Undefined
            | Op::DirectionFlag(_)
            | Op::StringMove { .. }
            | Op::StringStore { .. }
            | Op::Push
            | Op::Pop
            | Op::PushFlags
            | Op::PopFlags
            | Op::Call
            | Op::CallIndirect
            | Op::Return
            | Op::Leave
            | Op::WideMultiply { .. }
            | Op::Multiply
            | Op::Divide { .. }
            | Op::WidenAccumulator
            | Op::SignIntoData
            | Op::CarryFlag(_)
            | Op::Exchange
            | Op::ExchangeAndAdd
            | Op::CompareAndExchange
            | Op::CompareAndExchangeSixteen
            | Op::RotateThroughCarry { .. }
            | Op::DoubleShift { .. } => {}
        }
    }

    /// **Une condition, poussée en zéro ou un.**
    ///
    /// Les seize conditions de x86 sont huit prédicats et leur négation, et le
    /// bit de poids faible de l'opcode dit lequel des deux. On traduit donc
    /// huit fois, plus un ou exclusif — pas seize fois.
    fn condition(condition: Condition, b: &mut Body) {
        let bit = |b: &mut Body, flag: u64| {
            b.load(RFLAGS_SLOT).constant(flag).op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
        };
        match condition.base() {
            0 => bit(b, OF),
            1 => bit(b, CF),
            2 => bit(b, ZF),
            3 => {
                bit(b, CF);
                bit(b, ZF);
                b.op(code::I64_OR);
            }
            4 => bit(b, SF),
            5 => bit(b, PF),
            6 => {
                bit(b, SF);
                bit(b, OF);
                b.op(code::I64_XOR);
            }
            _ => {
                bit(b, ZF);
                bit(b, SF);
                bit(b, OF);
                b.op(code::I64_XOR).op(code::I64_OR);
            }
        }
        if condition.negated() {
            b.constant(1).op(code::I64_XOR);
        }
    }

    /// **Rendre la main au milieu d'un bloc.**
    ///
    /// C'est ce que fait le module quand il refuse une instruction : il pose
    /// RIP sur **cette** instruction — pas sur la suivante — et rend -1. L'hôte
    /// reprend là, avec l'interpréteur, qui sait exécuter depuis n'importe
    /// quelle adresse et sait lever une faute. Les instructions d'avant dans le
    /// même bloc ont déjà tourné, et c'est exact : elles ont vraiment eu lieu.
    fn hand_back(address: u64, body: &mut Body) {
        body.store(RIP_SLOT, |b| {
            b.constant(address);
        });
        body.bytes.push(code::I32_CONST);
        signed(-1, &mut body.bytes);
        body.op(code::RETURN);
    }

    /// Rendre la main **si** la condition tient. La condition laisse un `i32`.
    fn refuse_when(address: u64, body: &mut Body, condition: impl FnOnce(&mut Body)) {
        condition(body);
        body.op(code::IF).op(code::VOID);
        Self::hand_back(address, body);
        body.op(code::END);
    }

    /// Écrire un registre **nommé**, avec la règle de largeur. `mul` en écrit
    /// deux et aucun des deux n'est la destination de l'instruction, donc
    /// `write_back` — qui passe par `step.dst` — ne peut pas servir.
    fn put(register: u8, width: Width, body: &mut Body, value: impl FnOnce(&mut Body)) {
        let slot = Self::slot(register);
        body.store(slot, |b| Self::merged(slot, width, false, b, value));
    }

    /// **La valeur entière du registre après une écriture de cette largeur,
    /// sans l'écrire.** C'est ce qu'il faut pour choisir entre écrire et ne pas
    /// écrire *sans branchement* : les deux moitiés du choix doivent être des
    /// valeurs de soixante-quatre bits, pas deux chemins d'exécution.
    fn merged(
        slot: usize,
        width: Width,
        high: bool,
        body: &mut Body,
        value: impl FnOnce(&mut Body),
    ) {
        if high {
            body.load(slot).constant(!0xff00).op(code::I64_AND);
            value(body);
            body.constant(0xff)
                .op(code::I64_AND)
                .constant(8)
                .op(code::I64_SHL);
            body.op(code::I64_OR);
            return;
        }
        match width {
            Width::Qword => value(body),
            // Une écriture de 32 bits efface la moitié haute.
            Width::Dword => {
                value(body);
                body.constant(0xffff_ffff).op(code::I64_AND);
            }
            _ => {
                let mask = width.mask();
                body.load(slot).constant(!mask).op(code::I64_AND);
                value(body);
                body.constant(mask).op(code::I64_AND);
                body.op(code::I64_OR);
            }
        }
    }

    /// Écrire `%ah` — l'octet **haut** de RAX, où `mulb` range son produit et
    /// `divb` son reste. C'est le seul endroit du jeu où une moitié de résultat
    /// atterrit ailleurs que dans un registre entier.
    fn put_high_byte(body: &mut Body, value: impl FnOnce(&mut Body)) {
        let slot = Self::slot(0);
        body.store(slot, |b| Self::merged(slot, Width::Byte, true, b, value));
    }

    /// Étendre au signe depuis une largeur, sur la valeur au sommet de la pile.
    fn widen(width: Width, body: &mut Body) {
        let spare = 64 - width.bits();
        if spare != 0 {
            body.constant(spare).op(code::I64_SHL);
            body.constant(spare).op(code::I64_SHR_S);
        }
    }

    /// **Les soixante-quatre bits de poids fort d'un produit de soixante-quatre
    /// bits.** WebAssembly n'a pas d'instruction pour ça — `i64.mul` rend la
    /// moitié basse et jette l'autre — donc il faut la reconstruire à partir de
    /// quatre produits de trente-deux bits, qui eux tiennent.
    ///
    /// Les largeurs plus étroites n'en ont pas besoin : deux facteurs de
    /// trente-deux bits font un produit de soixante-quatre, et `i64.mul` le
    /// rend entier. L'émetteur connaît la largeur à la compilation, donc il
    /// n'émet ce calcul que là où il sert.
    fn high_product(signed_product: bool, body: &mut Body) {
        // scratch 0 et 1 portent les deux facteurs à l'entrée.
        let (a, b) = (Body::scratch(0), Body::scratch(1));
        let (t, w1, w2, high) = (
            Body::scratch(4),
            Body::scratch(5),
            Body::scratch(6),
            Body::scratch(7),
        );
        let low32 = |b: &mut Body, slot: usize| {
            b.load(slot).constant(0xffff_ffff).op(code::I64_AND);
        };
        let high32 = |b: &mut Body, slot: usize| {
            b.load(slot).constant(32).op(code::I64_SHR_U);
        };
        // t = a0 × b0 ; seule sa moitié haute compte pour la suite.
        body.store(t, |x| {
            low32(x, a);
            low32(x, b);
            x.op(code::I64_MUL).constant(32).op(code::I64_SHR_U);
        });
        // t = a1 × b0 + retenue
        body.store(t, |x| {
            high32(x, a);
            low32(x, b);
            x.op(code::I64_MUL).load(t).op(code::I64_ADD);
        });
        body.store(w1, |x| {
            x.load(t).constant(0xffff_ffff).op(code::I64_AND);
        });
        body.store(w2, |x| {
            x.load(t).constant(32).op(code::I64_SHR_U);
        });
        // t = a0 × b1 + w1
        body.store(t, |x| {
            low32(x, a);
            high32(x, b);
            x.op(code::I64_MUL).load(w1).op(code::I64_ADD);
        });
        body.store(high, |x| {
            high32(x, a);
            high32(x, b);
            x.op(code::I64_MUL)
                .load(w2)
                .op(code::I64_ADD)
                .load(t)
                .constant(32)
                .op(code::I64_SHR_U)
                .op(code::I64_ADD);
        });
        // **Du produit non signé au produit signé.** La correction est exacte :
        // retrancher l'autre facteur une fois par facteur négatif.
        if signed_product {
            body.store(high, |x| {
                x.load(high);
                x.load(a).constant(63).op(code::I64_SHR_S).load(b);
                x.op(code::I64_AND).op(code::I64_SUB);
                x.load(b).constant(63).op(code::I64_SHR_S).load(a);
                x.op(code::I64_AND).op(code::I64_SUB);
            });
        }
        body.load(high);
    }

    /// **La rotation à travers la retenue**, et pourquoi elle n'est pas une
    /// variante de `rol`.
    ///
    /// Le registre tourné fait la largeur **plus un bit** : la retenue en est
    /// le bit de tête. Pour huit, seize et trente-deux bits ça tient encore
    /// dans un `i64` et la formule ordinaire s'applique à la largeur élargie.
    /// Pour soixante-quatre, le registre tourné en fait **soixante-cinq** —
    /// WebAssembly n'a rien de tel, et le bit qui dépasse se traite à la main.
    ///
    /// Ce qui sauve ce cas : le compte est masqué à six bits, donc il ne
    /// dépasse jamais soixante-trois, donc le tour n'est jamais complet. Un
    /// tour de soixante-cinq crans, qu'il faudrait traiter à part, est
    /// inatteignable.
    fn rotate_through_carry(step: &Decoded, to_the_left: bool, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let sign = width.sign();
        let bits = width.bits();
        let span = bits + 1;
        let count_mask: u64 = if width == Width::Qword { 63 } else { 31 };
        let (value, count, turn) = (Body::scratch(0), Body::scratch(1), Body::scratch(5));
        let (carry_in, wide) = (Body::scratch(6), Body::scratch(7));

        body.store(value, |b| {
            Self::left(step, b);
        });
        body.store(count, |b| {
            if step.count_is_cl {
                b.load(Self::slot(1));
            } else {
                b.constant(step.imm);
            }
            b.constant(count_mask).op(code::I64_AND);
        });
        body.store(turn, |b| {
            b.load(count).constant(span).op(code::I64_REM_U);
        });
        body.store(carry_in, |b| {
            b.load(RFLAGS_SLOT).constant(CF).op(code::I64_AND);
        });

        if bits < 64 {
            body.store(wide, |b| {
                b.load(carry_in).constant(bits).op(code::I64_SHL);
                b.load(value).op(code::I64_OR);
            });
            body.store(Body::scratch(8), |b| {
                let (first, second) = if to_the_left {
                    (code::I64_SHL, code::I64_SHR_U)
                } else {
                    (code::I64_SHR_U, code::I64_SHL)
                };
                b.load(wide).load(turn).op(first);
                b.load(wide);
                b.constant(span).load(turn).op(code::I64_SUB);
                b.op(second);
                b.op(code::I64_OR);
                b.constant((1u64 << span) - 1).op(code::I64_AND);
            });
            body.store(Body::scratch(2), |b| {
                b.load(Body::scratch(8)).constant(mask).op(code::I64_AND);
            });
            body.store(Body::scratch(3), |b| {
                b.load(Body::scratch(8))
                    .constant(bits)
                    .op(code::I64_SHR_U)
                    .constant(1)
                    .op(code::I64_AND);
            });
        } else {
            // **Le bit qui dépasse.** Les termes sont écrits pour que le compte
            // de décalage reste sous soixante-quatre : un décalage de
            // soixante-quatre est ramené à zéro par WebAssembly, ce qui rendrait
            // l'opérande là où il faut zéro.
            body.store(Body::scratch(8), |b| {
                if to_the_left {
                    b.load(value).load(turn).op(code::I64_SHL);
                    b.load(carry_in)
                        .load(turn)
                        .constant(1)
                        .op(code::I64_SUB)
                        .op(code::I64_SHL);
                    b.op(code::I64_OR);
                    b.load(value);
                    b.constant(64).load(turn).op(code::I64_SUB);
                    b.op(code::I64_SHR_U).constant(1).op(code::I64_SHR_U);
                    b.op(code::I64_OR);
                } else {
                    b.load(value).load(turn).op(code::I64_SHR_U);
                    b.load(carry_in);
                    b.constant(64).load(turn).op(code::I64_SUB);
                    b.op(code::I64_SHL);
                    b.op(code::I64_OR);
                    b.load(value);
                    b.constant(64).load(turn).op(code::I64_SUB);
                    b.op(code::I64_SHL).constant(1).op(code::I64_SHL);
                    b.op(code::I64_OR);
                }
                // Un tour nul ne tourne rien, et les termes ci-dessus n'ont
                // alors aucun sens : c'est ici qu'on les écarte.
                b.load(value);
                b.load(turn).constant(0).op(code::I64_NE);
                b.op(code::SELECT);
            });
            body.store(Body::scratch(2), |b| {
                b.load(Body::scratch(8));
            });
            body.store(Body::scratch(3), |b| {
                if to_the_left {
                    b.load(value);
                    b.constant(64).load(turn).op(code::I64_SUB);
                    b.op(code::I64_SHR_U);
                } else {
                    b.load(value)
                        .load(turn)
                        .constant(1)
                        .op(code::I64_SUB)
                        .op(code::I64_SHR_U);
                }
                b.constant(1).op(code::I64_AND);
                b.load(carry_in);
                b.load(turn).constant(0).op(code::I64_NE);
                b.op(code::SELECT);
            });
        }

        // Le débordement, défini pour un cran seulement — même lecture que
        // pour `rol` et `ror`.
        body.store(Body::scratch(4), |b| {
            b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
            if to_the_left {
                b.load(Body::scratch(3));
            } else {
                b.load(Body::scratch(2))
                    .constant(bits - 2)
                    .op(code::I64_SHR_U);
                b.constant(1).op(code::I64_AND);
            }
            b.op(code::I64_XOR);
        });

        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(!(CF | OF)).op(code::I64_AND);
            b.load(Body::scratch(3))
                .constant(CF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);
            b.load(Body::scratch(4)).constant(1).op(code::I64_AND);
            b.constant(OF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);
            b.load(RFLAGS_SLOT);
            b.load(count).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });

        if !step.discards {
            Self::write_back(step, mask, body);
        }
    }

    /// **Le décalage double** : les bits qui entrent viennent d'un second
    /// registre au lieu d'être des zéros ou des copies du signe.
    fn double_shift(step: &Decoded, to_the_left: bool, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let sign = width.sign();
        let bits = width.bits();
        let count_mask: u64 = if width == Width::Qword { 63 } else { 31 };
        let (value, count, from) = (Body::scratch(0), Body::scratch(1), Body::scratch(5));

        body.store(value, |b| {
            Self::left(step, b);
        });
        body.store(count, |b| {
            if step.count_is_cl {
                b.load(Self::slot(1));
            } else {
                b.constant(step.imm);
            }
            b.constant(count_mask).op(code::I64_AND);
        });
        body.store(from, |b| {
            b.load(Self::slot(step.src))
                .constant(mask)
                .op(code::I64_AND);
        });

        body.store(Body::scratch(2), |b| {
            if to_the_left {
                b.load(value).load(count).op(code::I64_SHL);
                b.load(from);
                b.constant(bits).load(count).op(code::I64_SUB);
                b.op(code::I64_SHR_U);
            } else {
                b.load(value).load(count).op(code::I64_SHR_U);
                b.load(from);
                b.constant(bits).load(count).op(code::I64_SUB);
                b.op(code::I64_SHL);
            }
            b.op(code::I64_OR).constant(mask).op(code::I64_AND);
            // Un compte nul ne décale rien, et le terme complémentaire vaudrait
            // un décalage de la largeur entière — que WebAssembly ramène à zéro.
            b.load(value);
            b.load(count).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });

        // La retenue : le **dernier bit sorti** de la destination.
        body.store(Body::scratch(3), |b| {
            if to_the_left {
                b.load(value);
                b.constant(bits).load(count).op(code::I64_SUB);
                b.op(code::I64_SHR_U);
            } else {
                b.load(value)
                    .load(count)
                    .constant(1)
                    .op(code::I64_SUB)
                    .op(code::I64_SHR_U);
            }
            b.constant(1).op(code::I64_AND);
        });

        // Le débordement : le changement de signe, défini pour un cran.
        body.store(Body::scratch(4), |b| {
            b.load(value)
                .load(Body::scratch(2))
                .op(code::I64_XOR)
                .constant(sign)
                .op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
        });

        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT)
                .constant(!(CF | PF | AF | ZF | SF | OF))
                .op(code::I64_AND);

            b.load(Body::scratch(2)).op(code::I64_EQZ);
            b.op(code::I64_EXTEND_I32_U)
                .constant(ZF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);

            b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
            b.constant(SF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            b.load(Body::scratch(2)).constant(0xff).op(code::I64_AND);
            b.op(code::I64_POPCNT).constant(1).op(code::I64_AND);
            b.constant(1).op(code::I64_XOR);
            b.constant(PF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            b.load(Body::scratch(3))
                .constant(CF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);
            b.load(Body::scratch(4)).constant(1).op(code::I64_AND);
            b.constant(OF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            b.load(RFLAGS_SLOT);
            b.load(count).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });

        Self::write_back(step, mask, body);
    }

    /// **Les trois échanges.** Ce qui les réunit : elles écrivent **deux**
    /// endroits, et il faut avoir lu les deux avant d'écrire le premier.
    fn exchange(step: &Decoded, body: &mut Body) {
        if step.op == Op::CompareAndExchangeSixteen {
            Self::compare_and_exchange_sixteen(step, body);
            return;
        }
        let width = step.width;
        let mask = width.mask();
        let sign = width.sign();
        let (old, from) = (Body::scratch(5), Body::scratch(6));
        body.store(old, |b| Self::left(step, b));
        body.store(from, |b| Self::right(step, b));
        // La source est toujours un registre : c'est le champ `reg` du ModRM,
        // ou l'accumulateur pour la forme courte. Seule la destination peut
        // être en mémoire.
        let into_source = |body: &mut Body, value: usize| {
            let slot = Self::slot(step.src);
            body.store(slot, |b| {
                Self::merged(slot, width, step.src_high, b, |x| {
                    x.load(value);
                });
            });
        };
        match step.op {
            Op::Exchange => {
                body.store(Body::scratch(2), |b| {
                    b.load(from);
                });
                Self::write_back(step, mask, body);
                into_source(body, old);
            }
            Op::ExchangeAndAdd => {
                // Les drapeaux sont ceux d'un `add`, et la routine qui les pose
                // lit l'opérande gauche, le droit et le résultat dans les trois
                // premiers emplacements de travail.
                body.store(Body::scratch(0), |b| {
                    b.load(old);
                });
                body.store(Body::scratch(1), |b| {
                    b.load(from);
                });
                body.store(Body::scratch(2), |b| {
                    b.load(old)
                        .load(from)
                        .op(code::I64_ADD)
                        .constant(mask)
                        .op(code::I64_AND);
                });
                let as_add = Decoded {
                    op: Op::Add,
                    ..*step
                };
                Self::flags(&as_add, mask, sign, body);
                Self::write_back(step, mask, body);
                into_source(body, old);
            }
            _ => {
                // **`cmpxchg` compare l'accumulateur à la destination**, pas la
                // source à la destination.
                let accumulator = Body::scratch(7);
                body.store(accumulator, |b| {
                    b.load(Self::slot(0)).constant(mask).op(code::I64_AND);
                });
                body.store(Body::scratch(0), |b| {
                    b.load(accumulator);
                });
                body.store(Body::scratch(1), |b| {
                    b.load(old);
                });
                body.store(Body::scratch(2), |b| {
                    b.load(accumulator)
                        .load(old)
                        .op(code::I64_SUB)
                        .constant(mask)
                        .op(code::I64_AND);
                });
                Self::flags(&as_compare(step), mask, sign, body);
                // Le verdict, gardé à part : les trois emplacements que la
                // routine des drapeaux vient d'employer vont resservir.
                let equal = Body::scratch(8);
                body.store(equal, |b| {
                    b.load(accumulator)
                        .load(old)
                        .op(code::I64_EQ)
                        .op(code::I64_EXTEND_I32_U);
                });
                // **Quand l'égalité ne tient pas, la destination n'est pas
                // écrite du tout.** Pas même réécrite avec sa propre valeur :
                // une écriture de trente-deux bits, même de la même valeur,
                // effacerait la moitié haute du registre. Le silicium a
                // tranché — sept cas sur vingt-quatre pour `cmpxchgl`.
                match step.memory {
                    // En mémoire la distinction ne s'observe pas : réécrire les
                    // mêmes octets ne se voit pas, et c'est ce que fait la forme
                    // verrouillée.
                    Some(_) => {
                        body.store(Body::scratch(2), |b| {
                            b.load(from).load(old).load(equal).op(code::I32_WRAP_I64);
                            b.op(code::SELECT);
                        });
                        Self::write_back(step, mask, body);
                    }
                    None => {
                        let slot = Self::slot(step.dst);
                        body.store(slot, |b| {
                            Self::merged(slot, width, step.dst_high, b, |x| {
                                x.load(from);
                            });
                            b.load(slot);
                            b.load(equal).op(code::I32_WRAP_I64);
                            b.op(code::SELECT);
                        });
                    }
                }
                // Et l'accumulateur, à l'inverse : écrit **seulement** quand
                // l'égalité ne tient pas.
                let slot = Self::slot(0);
                body.store(slot, |b| {
                    b.load(slot);
                    Self::merged(slot, width, false, b, |x| {
                        x.load(old);
                    });
                    b.load(equal).op(code::I32_WRAP_I64);
                    b.op(code::SELECT);
                });
            }
        }
    }

    /// **`cmpxchg16b` : seize octets contre RDX:RAX.** Deux mots lus à
    /// l'adresse et à l'adresse plus huit, comparés tous deux ; s'ils
    /// tiennent, RCX:RBX y sont écrits ; sinon RDX:RAX relisent la paire.
    /// ZF est le seul drapeau qui bouge — pas de routine des drapeaux ici,
    /// elle en poserait six.
    ///
    /// L'adresse est calculée une fois et gardée : les deux lectures et les
    /// deux écritures la relisent, et WebAssembly n'a pas de quoi dupliquer
    /// une valeur. Le préfixe `lock` ne change rien : un seul fil.
    fn compare_and_exchange_sixteen(step: &Decoded, body: &mut Body) {
        let Some(address) = step.memory else {
            unreachable!("le décodeur ne rend `cmpxchg16b` qu'en mémoire")
        };
        let (low_at, high_at) = (Body::scratch(5), Body::scratch(6));
        let (low, high, equal) = (Body::scratch(7), Body::scratch(8), Body::scratch(9));
        body.store(low_at, |b| {
            b.wide_address(&address);
        });
        body.store(high_at, |b| {
            b.load(low_at).constant(8).op(code::I64_ADD);
        });
        body.store(low, |b| {
            b.load_at(low_at, Width::Qword);
        });
        body.store(high, |b| {
            b.load_at(high_at, Width::Qword);
        });
        body.store(equal, |b| {
            b.load(low).load(Self::slot(0)).op(code::I64_EQ);
            b.load(high).load(Self::slot(2)).op(code::I64_EQ);
            b.op(code::I32_AND).op(code::I64_EXTEND_I32_U);
        });
        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(!ZF).op(code::I64_AND);
            b.load(equal)
                .constant(ZF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);
        });
        body.load(equal).op(code::I32_WRAP_I64);
        body.op(code::IF).op(code::VOID);
        body.store_at(low_at, Width::Qword, |b| {
            b.load(Self::slot(3));
        });
        body.store_at(high_at, Width::Qword, |b| {
            b.load(Self::slot(1));
        });
        body.op(0x05); // else
        body.store(Self::slot(0), |b| {
            b.load(low);
        });
        body.store(Self::slot(2), |b| {
            b.load(high);
        });
        body.op(code::END);
    }

    /// **Les multiplications, les divisions, les extensions de signe, et la
    /// retenue posée à la main.**
    ///
    /// Elles partagent ce qui les sort de la machinerie ordinaire : leur
    /// destination n'est pas l'opérande qu'elles lisent. `mul` et `div`
    /// écrivent RDX **et** RAX ; `cqto` écrit RDX en lisant RAX ; `clc` n'écrit
    /// qu'un bit de RFLAGS.
    fn two_registers(step: &Decoded, address: u64, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let bits = width.bits();
        match step.op {
            Op::CarryFlag(action) => {
                body.store(RFLAGS_SLOT, |b| {
                    b.load(RFLAGS_SLOT);
                    match action {
                        CarryAction::Clear => b.constant(!1u64).op(code::I64_AND),
                        CarryAction::Set => b.constant(1).op(code::I64_OR),
                        CarryAction::Complement => b.constant(1).op(code::I64_XOR),
                    };
                });
            }
            // La source fait la **demi**-largeur : c'est tout ce qui distingue
            // `cbtw` de `cltq`.
            Op::WidenAccumulator => {
                let half = step.src_width;
                Self::put(0, width, body, |b| {
                    b.load(Self::slot(0))
                        .constant(half.mask())
                        .op(code::I64_AND);
                    Self::widen(half, b);
                });
            }
            // RDX ne reçoit pas *le* signe mais **tous les bits** du signe :
            // un décalage arithmétique de soixante-trois crans.
            Op::SignIntoData => {
                Self::put(2, width, body, |b| {
                    b.load(Self::slot(0)).constant(mask).op(code::I64_AND);
                    Self::widen(width, b);
                    b.constant(63).op(code::I64_SHR_S);
                });
            }
            Op::WideMultiply { signed: is_signed } => {
                // scratch 0 : l'accumulateur. scratch 1 : l'opérande.
                body.store(Body::scratch(0), |b| {
                    b.load(Self::slot(0)).constant(mask).op(code::I64_AND);
                    if is_signed {
                        Self::widen(width, b);
                    }
                });
                body.store(Body::scratch(1), |b| {
                    Self::operand(step, b);
                    b.constant(mask).op(code::I64_AND);
                    if is_signed {
                        Self::widen(width, b);
                    }
                });
                // scratch 2 : la moitié basse. scratch 3 : la moitié haute.
                body.store(Body::scratch(2), |b| {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_MUL);
                });
                body.store(Body::scratch(3), |b| {
                    if bits == 64 {
                        Self::high_product(is_signed, b);
                    } else {
                        b.load(Body::scratch(2));
                        b.constant(bits)
                            .op(if is_signed {
                                code::I64_SHR_S
                            } else {
                                code::I64_SHR_U
                            })
                            .constant(mask)
                            .op(code::I64_AND);
                    }
                });
                // **Le débordement d'un produit signé n'est pas « le haut est
                // non nul ».** Un produit négatif a un haut plein de uns et
                // tient pourtant : ce qui compte est que le haut ne soit que la
                // recopie du signe du bas.
                body.store(Body::scratch(4), |b| {
                    if is_signed {
                        b.load(Body::scratch(3));
                        b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                        Self::widen(width, b);
                        b.constant(63)
                            .op(code::I64_SHR_S)
                            .constant(mask)
                            .op(code::I64_AND);
                        b.op(code::I64_NE).op(code::I64_EXTEND_I32_U);
                    } else {
                        b.load(Body::scratch(3))
                            .op(code::I64_EQZ)
                            .op(code::I64_EXTEND_I32_U);
                        b.constant(1).op(code::I64_XOR);
                    }
                });
                if width == Width::Byte {
                    Self::put(0, Width::Byte, body, |b| {
                        b.load(Body::scratch(2));
                    });
                    Self::put_high_byte(body, |b| {
                        b.load(Body::scratch(3));
                    });
                } else {
                    Self::put(0, width, body, |b| {
                        b.load(Body::scratch(2));
                    });
                    Self::put(2, width, body, |b| {
                        b.load(Body::scratch(3));
                    });
                }
                Self::carry_and_overflow_together(body);
            }
            Op::Multiply => {
                // À trois opérandes les deux facteurs sont `rm` et l'immédiat ;
                // à deux, c'est la destination et `rm`.
                body.store(Body::scratch(0), |b| {
                    if step.immediate {
                        Self::operand(step, b);
                    } else {
                        b.load(Self::slot(step.dst));
                    }
                    b.constant(mask).op(code::I64_AND);
                    Self::widen(width, b);
                });
                body.store(Body::scratch(1), |b| {
                    if step.immediate {
                        b.constant(step.imm);
                    } else {
                        Self::operand(step, b);
                    }
                    b.constant(mask).op(code::I64_AND);
                    Self::widen(width, b);
                });
                body.store(Body::scratch(2), |b| {
                    b.load(Body::scratch(0))
                        .load(Body::scratch(1))
                        .op(code::I64_MUL);
                });
                body.store(Body::scratch(3), |b| {
                    if bits == 64 {
                        Self::high_product(true, b);
                    } else {
                        b.load(Body::scratch(2)).constant(bits).op(code::I64_SHR_S);
                    }
                });
                body.store(Body::scratch(4), |b| {
                    b.load(Body::scratch(3))
                        .constant(if bits == 64 { u64::MAX } else { mask })
                        .op(code::I64_AND);
                    b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                    Self::widen(width, b);
                    b.constant(63).op(code::I64_SHR_S);
                    b.constant(if bits == 64 { u64::MAX } else { mask })
                        .op(code::I64_AND);
                    b.op(code::I64_NE).op(code::I64_EXTEND_I32_U);
                });
                Self::put(step.dst, width, body, |b| {
                    b.load(Body::scratch(2));
                });
                Self::carry_and_overflow_together(body);
            }
            _ => Self::divide(step, address, body),
        }
    }

    /// CF et OF disent la même chose pour une multiplication — « le résultat
    /// ne tenait pas » — et scratch 4 la porte. Les quatre autres drapeaux sont
    /// indéfinis : le manuel les abandonne, donc on les laisse tels quels
    /// plutôt que de les écraser avec des valeurs plausibles et fausses.
    fn carry_and_overflow_together(body: &mut Body) {
        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(!(CF | OF)).op(code::I64_AND);
            b.load(Body::scratch(4))
                .op(code::I64_EQZ)
                .op(code::I64_EXTEND_I32_U)
                .constant(1)
                .op(code::I64_XOR);
            b.constant(CF | OF).op(code::I64_MUL);
            b.op(code::I64_OR);
        });
    }

    /// L'opérande que le ModRM désigne — registre, octet haut, ou mémoire.
    fn operand(step: &Decoded, body: &mut Body) {
        match step.memory {
            Some(address) => {
                body.load_memory(
                    &address,
                    if step.memory_is_source {
                        step.src_width
                    } else {
                        step.width
                    },
                );
            }
            None => {
                let register = if step.op == Op::Multiply {
                    step.src
                } else {
                    step.dst
                };
                let high = if step.op == Op::Multiply {
                    step.src_high
                } else {
                    step.dst_high
                };
                body.load(Self::slot(register));
                if high {
                    body.constant(8).op(code::I64_SHR_U);
                }
            }
        }
    }

    /// **La seule instruction qui peut refuser de s'exécuter.**
    ///
    /// Trois raisons de refuser, et le module les traite de la même façon :
    /// il rend la main sans rien écrire, RIP sur la division elle-même.
    ///
    /// 1. **Un diviseur nul.** Le processeur lève `#DE` ; le module ne peut pas
    ///    lever, et une division par zéro en WebAssembly est une *trappe* qui
    ///    tue le module entier. Rendre la main laisse l'interpréteur lever.
    /// 2. **Un quotient qui ne tient pas** dans la largeur — `0x8000 / -1` en
    ///    seize bits. Même chose : c'est un `#DE`.
    /// 3. **Un dividende de cent vingt-huit bits véritable**, en soixante-quatre
    ///    bits de large, dont la moitié haute n'est pas la banale. WebAssembly
    ///    ne divise pas sur cent vingt-huit bits, et écrire la division longue
    ///    ici serait beaucoup de code pour un cas qu'aucun cas du corpus
    ///    n'exerce. L'interpréteur, lui, sait le faire — et il est vérifié
    ///    contre le silicium. C'est le filet, et c'est son emploi.
    fn divide(step: &Decoded, address: u64, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let bits = width.bits();
        let signed = matches!(step.op, Op::Divide { signed: true });
        let (divisor, low, high, quotient) = (
            Body::scratch(0),
            Body::scratch(1),
            Body::scratch(2),
            Body::scratch(3),
        );
        body.store(divisor, |b| {
            Self::operand(step, b);
            b.constant(mask).op(code::I64_AND);
        });
        Self::refuse_when(address, body, |b| {
            b.load(divisor).op(code::I64_EQZ);
        });
        // En octet le dividende est AX tout entier : sa moitié haute est AH,
        // elle vit dans RAX et pas dans RDX.
        body.store(low, |b| {
            b.load(Self::slot(0)).constant(mask).op(code::I64_AND);
        });
        body.store(high, |b| {
            if width == Width::Byte {
                b.load(Self::slot(0)).constant(8).op(code::I64_SHR_U);
            } else {
                b.load(Self::slot(2));
            }
            b.constant(mask).op(code::I64_AND);
        });
        if signed {
            body.store(divisor, |b| {
                b.load(divisor);
                Self::widen(width, b);
            });
        }
        if bits == 64 {
            // La moitié haute doit être la banale — zéro, ou le signe du bas.
            Self::refuse_when(address, body, |b| {
                b.load(high);
                if signed {
                    b.load(low).constant(63).op(code::I64_SHR_S);
                } else {
                    b.constant(0);
                }
                b.op(code::I64_NE);
            });
            // Et le seul quotient qui déborde encore : le minimum divisé par -1.
            if signed {
                Self::refuse_when(address, body, |b| {
                    b.load(low).constant(1u64 << 63).op(code::I64_EQ);
                    b.load(divisor).constant(u64::MAX).op(code::I64_EQ);
                    b.op(0x71); // i32.and
                });
            }
            body.store(quotient, |b| {
                b.load(low);
                if signed {
                    Self::widen(width, b);
                }
                b.load(divisor).op(if signed {
                    code::I64_DIV_S
                } else {
                    code::I64_DIV_U
                });
            });
            let remainder = Body::scratch(4);
            body.store(remainder, |b| {
                b.load(low);
                if signed {
                    Self::widen(width, b);
                }
                b.load(divisor).op(if signed {
                    code::I64_REM_S
                } else {
                    code::I64_REM_U
                });
            });
            Self::put(0, width, body, |b| {
                b.load(quotient);
            });
            Self::put(2, width, body, |b| {
                b.load(remainder);
            });
            return;
        }
        // Largeurs étroites : le dividende double tient dans soixante-quatre
        // bits, donc la division ordinaire suffit.
        let dividend = Body::scratch(5);
        body.store(dividend, |b| {
            b.load(high).constant(bits).op(code::I64_SHL);
            b.load(low).op(code::I64_OR);
            if signed {
                let spare = 64 - bits * 2;
                if spare != 0 {
                    b.constant(spare).op(code::I64_SHL);
                    b.constant(spare).op(code::I64_SHR_S);
                }
            }
        });
        body.store(quotient, |b| {
            b.load(dividend).load(divisor).op(if signed {
                code::I64_DIV_S
            } else {
                code::I64_DIV_U
            });
        });
        Self::refuse_when(address, body, |b| {
            if signed {
                let limit = 1u64 << (bits - 1);
                b.load(quotient)
                    .constant(limit.wrapping_neg())
                    .op(code::I64_LT_S);
                b.load(quotient)
                    .constant(limit.wrapping_sub(1))
                    .op(code::I64_GT_S);
                b.op(0x72); // i32.or
            } else {
                b.load(quotient).constant(mask).op(code::I64_GT_U);
            }
        });
        let remainder = Body::scratch(6);
        body.store(remainder, |b| {
            b.load(dividend).load(divisor).op(if signed {
                code::I64_REM_S
            } else {
                code::I64_REM_U
            });
        });
        if width == Width::Byte {
            Self::put(0, Width::Byte, body, |b| {
                b.load(quotient);
            });
            Self::put_high_byte(body, |b| {
                b.load(remainder);
            });
        } else {
            Self::put(0, width, body, |b| {
                b.load(quotient);
            });
            Self::put(2, width, body, |b| {
                b.load(remainder);
            });
        }
    }

    /// **Les instructions de chaîne, la forme simple et la forme répétée.**
    ///
    /// La forme simple est de la ligne droite : lire, écrire, avancer les deux
    /// pointeurs du pas que le drapeau de direction choisit.
    ///
    /// **La forme répétée est une boucle, et elle est ici — la raison n'est pas
    /// la vitesse.** Ce chemin rendait la main : l'interpréteur exécutait la
    /// répétition entière en un pas, en Rust natif, ce qui coûte une rentrée
    /// par `memcpy` au lieu d'une boucle payée à chaque octet. L'argument était
    /// bon tant que l'hôte pouvait exécuter ce qu'on lui rendait.
    ///
    /// Il ne le peut pas. La RAM invitée **est** la mémoire linéaire du module,
    /// et cette mémoire vit dans le processus de contenu de WebKit ; ce qui
    /// reprend après un retour de main doit la lire. Un interpréteur qui vit
    /// dans l'application ne le peut pas. Les deux seules issues étaient un
    /// **quatrième** cœur écrit en JavaScript — à côté de l'interpréteur Rust,
    /// de cet émetteur et du cœur Swift — ou la boucle ici. La boucle retire un
    /// cœur au lieu d'en ajouter un.
    ///
    /// Trois choses que le silicium impose et que la boucle respecte :
    /// le pas vient de DF et se calcule **une fois**, hors de la boucle, parce
    /// que rien dedans ne touche au drapeau ; sa taille est celle de
    /// l'opérande ; et **un compte nul ne fait rien du tout**, pas même une
    /// itération — d'où le test avant le corps et non après.
    ///
    /// Ce qu'elle ne borne pas : un invité qui pose RCX à un milliard fait
    /// tourner le module aussi longtemps qu'il ferait tourner l'interpréteur.
    /// Les deux cœurs se conduisent pareil, ce qui est la propriété qui compte
    /// ici ; borner la boucle demanderait de rendre la main à mi-course, avec
    /// RIP sur le `rep` — l'architecture le permet, rien ne le réclame encore.
    fn string(step: &Decoded, body: &mut Body) -> Option<()> {
        let repeat = matches!(
            step.op,
            Op::StringMove { repeat: true } | Op::StringStore { repeat: true }
        );
        let width = step.width;
        let size = width as u64;
        // scratch 0 : le pas, négatif quand le drapeau de direction est posé.
        // **Hors de la boucle** : rien dedans ne touche à DF, et le relire à
        // chaque tour coûterait une globale par élément copié.
        body.store(Body::scratch(0), |b| {
            b.constant(size.wrapping_neg());
            b.constant(size);
            b.load(RFLAGS_SLOT).constant(DF).op(code::I64_AND);
            b.constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });
        if repeat {
            body.op(code::BLOCK).op(code::VOID);
            body.op(code::LOOP).op(code::VOID);
            // **Le compte nul ne fait rien du tout.** Tester après le corps
            // copierait un élément de trop, et sur un compte de quatre ça ne
            // se verrait pas.
            body.load(Self::slot(1)).op(code::I64_EQZ);
            // **Vers le `block`, pas vers la `loop`.** Une profondeur de zéro
            // désigne la boucle elle-même : le compte nul reboucherait alors
            // sans fin au lieu de sortir. Le sabotage l'a montré en tournant
            // sans jamais rendre la main.
            body.op(code::BRANCH_IF);
            unsigned(1, &mut body.bytes);
        }
        // scratch 1 : la valeur — lue en mémoire pour `movs`, prise dans
        // l'accumulateur pour `stos`.
        let moves = matches!(step.op, Op::StringMove { .. });
        body.store(Body::scratch(1), |b| {
            if moves {
                b.load(Self::slot(6)).guest();
                b.op(match width {
                    Width::Byte => code::I64_LOAD8_U,
                    Width::Word => code::I64_LOAD16_U,
                    Width::Dword => code::I64_LOAD32_U,
                    Width::Qword => code::I64_LOAD,
                });
                b.bytes.push(0);
                b.bytes.push(0);
            } else {
                b.load(Self::slot(0))
                    .constant(width.mask())
                    .op(code::I64_AND);
            }
        });
        body.store_at(Self::slot(7), width, |b| {
            b.load(Body::scratch(1));
        });
        if moves {
            body.store(Self::slot(6), |b| {
                b.load(Self::slot(6))
                    .load(Body::scratch(0))
                    .op(code::I64_ADD);
            });
        }
        body.store(Self::slot(7), |b| {
            b.load(Self::slot(7))
                .load(Body::scratch(0))
                .op(code::I64_ADD);
        });
        if repeat {
            // RCX décroît **après** le corps, et le tour suivant retestera à
            // zéro avant de recommencer.
            body.store(Self::slot(1), |b| {
                b.load(Self::slot(1)).constant(1).op(code::I64_SUB);
            });
            body.op(code::BRANCH);
            unsigned(0, &mut body.bytes);
            body.op(code::END); // loop
            body.op(code::END); // block
        }
        Some(())
    }

    /// **La pile.** L'ordre est le sujet : `push` descend RSP **puis** écrit,
    /// `pop` lit **puis** remonte. L'inverser écrirait huit octets au-dessus
    /// du sommet, là où une interruption a le droit de passer.
    fn stack(step: &Decoded, body: &mut Body) {
        match step.op {
            Op::Push => {
                // scratch 0 : la valeur, lue **avant** que RSP ne bouge —
                // `push %rsp` empile la valeur d'avant la descente.
                body.store(Body::scratch(0), |b| {
                    if step.immediate {
                        b.constant(step.imm);
                    } else if let Some(address) = step.memory {
                        // `pushq (%rsi)` : huit octets pris en mémoire. Toujours
                        // huit — en mode 64 bits le groupe 5 n'a pas d'autre
                        // largeur, et en prendre quatre empilerait la moitié
                        // basse d'un pointeur.
                        b.load_memory(&address, Width::Qword);
                    } else {
                        b.load(Self::slot(step.dst));
                    }
                });
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_SUB);
                });
                Self::at_top(body, |b| {
                    b.load(Body::scratch(0));
                });
            }
            // **`pushf` est un `push` dont la valeur vient des drapeaux**, et
            // rien de plus. Pas de largeur à choisir ici : le décodeur a déjà
            // tranché, et en mode 64 bits sans préfixe 0x66 ce sont huit
            // octets. La forme à deux octets existe et n'est pas produite —
            // elle demanderait une descente de pile de deux, ce que ce chemin
            // ne fait pas ; `translate` la laisse donc au refus.
            //
            // **`popf` reste refusé, et l'asymétrie est le sujet.** Lire
            // RFLAGS ne peut rien allumer ; l'écrire peut rallumer le drapeau
            // d'interruption sans jamais nommer `sti`, et rien ne délivre
            // d'interruption. Un module qui accepte `popf` accepte un `sti`
            // déguisé.
            Op::PushFlags => {
                body.store(Body::scratch(0), |b| {
                    b.load(RFLAGS_SLOT);
                });
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_SUB);
                });
                Self::at_top(body, |b| {
                    b.load(Body::scratch(0));
                });
            }
            // **`popf`, et le masque qui vient du cœur Swift.**
            //
            // La raison de son refus est écrite juste au-dessus : « un module
            // qui accepte `popf` accepte un `sti` déguisé ». C'était juste tant
            // que `sti` était refusé ; il est produit depuis la tranche
            // précédente, donc l'asymétrie n'a plus de raison. Et c'est un
            // `popfq` — précédé d'un `push $0` — qui arrêtait la quatrième
            // région d'un vrai noyau, à l'octet 400.
            //
            // **Les bits que cet émetteur ne consulte pas sont rangés quand
            // même** — IOPL, NT, AC. C'est ce que fait le silicium, et c'est ce
            // qu'un `pushf` doit rendre ; les perdre ferait diverger la
            // relecture. Ce que le masque écarte, le processeur l'écarte aussi.
            Op::PopFlags => {
                body.store(RFLAGS_SLOT, |b| {
                    b.load(Self::slot(4));
                    b.guest();
                    b.op(code::I64_LOAD);
                    b.bytes.push(0);
                    b.bytes.push(0);
                    b.constant(WRITABLE_FLAGS).op(code::I64_AND);
                    b.constant(ALWAYS_ONE).op(code::I64_OR);
                });
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_ADD);
                });
            }
            Op::Pop => {
                body.store(Self::slot(step.dst), |b| {
                    b.load(Self::slot(4));
                    b.guest();
                    b.op(code::I64_LOAD);
                    b.bytes.push(0);
                    b.bytes.push(0);
                });
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_ADD);
                });
            }
            _ => {
                // `leave` : RSP reprend RBP, puis RBP se dépile.
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(5));
                });
                body.store(Self::slot(5), |b| {
                    b.load(Self::slot(4));
                    b.guest();
                    b.op(code::I64_LOAD);
                    b.bytes.push(0);
                    b.bytes.push(0);
                });
                body.store(Self::slot(4), |b| {
                    b.load(Self::slot(4)).constant(8).op(code::I64_ADD);
                });
            }
        }
    }

    /// Écrire huit octets au sommet de la pile, RSP étant déjà à sa place.
    fn at_top(body: &mut Body, value: impl FnOnce(&mut Body)) {
        body.load(Self::slot(4)).guest();
        value(body);
        body.op(code::I64_STORE);
        body.bytes.push(0);
        body.bytes.push(0);
    }

    /// **Un bit, lu dans la retenue et parfois changé.**
    fn bit(step: &Decoded, action: BitAction, body: &mut Body) {
        let width = step.width;
        let bits = width.bits();
        // **La chaîne de bits : une adresse que seule l'exécution connaît.**
        //
        // Quand la destination est en mémoire et que le numéro vient d'un
        // registre, ce numéro est **signé** et n'est pas replié : le processeur
        // va chercher le mot qui le contient, en avant comme en arrière. Le
        // mot visé est donc `adresse + (numéro ÷ bits) × octets`, la division
        // arrondie **vers le bas**.
        //
        // Les deux opérations sont des décalages, et c'est exact plutôt que
        // commode : la largeur est une puissance de deux, donc `>>` arithmétique
        // **est** la division arrondie vers le bas — y compris pour les
        // négatifs, là où `i64.div_s`, qui tronque vers zéro, remonterait d'un
        // mot. Et le reste positif est simplement les bits bas.
        //
        // **Deux sabotages y ont survécu, et ils avaient tort.** Mettre un
        // décalage logique à la place de l'arithmétique, ou tronquer l'adresse
        // à trente-deux bits avant d'y ajouter le mot, rend ici *exactement* le
        // même résultat. Ce n'est pas un trou dans les tests : la mémoire
        // WebAssembly s'adresse sur trente-deux bits, et l'écart entre les deux
        // décalages vaut 2⁶¹ quelle que soit la largeur — donc zéro une fois
        // tronqué. Aucun test ne peut les distinguer, et il ne faut pas en
        // tordre un pour essayer. Ce qui est écrit ici est ce qu'on veut dire,
        // et ce qui resterait juste si la mémoire s'adressait un jour plus
        // loin.
        let string = step.memory.is_some() && !step.immediate;
        if let (true, Some(address)) = (string, step.memory) {
            body.store(Body::scratch(3), |b| {
                b.wide_address(&address);
                b.load(Self::slot(step.src))
                    .constant(u64::from(bits.trailing_zeros()))
                    .op(code::I64_SHR_S)
                    .constant(u64::from((width as u64).trailing_zeros()))
                    .op(code::I64_SHL)
                    .op(code::I64_ADD);
            });
        }
        // scratch 0 : l'opérande. scratch 1 : le numéro, réduit dans la largeur.
        body.store(Body::scratch(0), |b| {
            if string {
                b.load_at(Body::scratch(3), width);
            } else if let Some(address) = step.memory {
                b.load_memory(&address, width);
            } else {
                b.load(Self::slot(step.dst))
                    .constant(width.mask())
                    .op(code::I64_AND);
            }
        });
        body.store(Body::scratch(1), |b| {
            if step.immediate {
                b.constant(step.imm % bits);
            } else if string {
                b.load(Self::slot(step.src))
                    .constant(bits - 1)
                    .op(code::I64_AND);
            } else {
                b.load(Self::slot(step.src))
                    .constant(bits)
                    .op(code::I64_REM_U);
            }
        });
        // La retenue, et elle seule.
        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(!CF).op(code::I64_AND);
            b.load(Body::scratch(0))
                .load(Body::scratch(1))
                .op(code::I64_SHR_U);
            b.constant(1).op(code::I64_AND);
            b.constant(CF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);
        });
        if action == BitAction::Test {
            return;
        }
        // scratch 2 : l'opérande avec son bit changé, puis l'écriture commune.
        body.store(Body::scratch(2), |b| {
            b.load(Body::scratch(0));
            b.constant(1).load(Body::scratch(1)).op(code::I64_SHL);
            match action {
                BitAction::Set => {
                    b.op(code::I64_OR);
                }
                BitAction::Reset => {
                    // Pas de « et non » en WebAssembly : on inverse le masque.
                    b.constant(u64::MAX).op(code::I64_XOR).op(code::I64_AND);
                }
                _ => {
                    b.op(code::I64_XOR);
                }
            }
            b.constant(width.mask()).op(code::I64_AND);
        });
        if string {
            body.store_at(Body::scratch(3), width, |b| {
                b.load(Body::scratch(2));
            });
            return;
        }
        Self::write_back(step, width.mask(), body);
    }

    /// **Chercher le premier bit à un.** Quand la source est nulle, la
    /// destination ne bouge pas — le manuel la dit indéfinie, et le corpus a
    /// relevé ce que fait la machine qui l'a produit.
    fn scan(step: &Decoded, from_the_top: bool, body: &mut Body) {
        let width = step.width;
        body.store(Body::scratch(0), |b| {
            Self::right(step, b);
        });
        // Le zéro parle de la **source**.
        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(!ZF).op(code::I64_AND);
            b.load(Body::scratch(0)).op(code::I64_EQZ);
            b.op(code::I64_EXTEND_I32_U)
                .constant(ZF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);
        });
        body.store(Body::scratch(2), |b| {
            if from_the_top {
                // L'opérande est déjà masqué, donc les zéros de tête comptent
                // depuis soixante-quatre : l'indice est leur complément.
                b.constant(63);
                b.load(Body::scratch(0)).op(code::I64_CLZ);
                b.op(code::I64_SUB);
            } else {
                b.load(Body::scratch(0)).op(code::I64_CTZ);
            }
        });
        // **Source nulle : rien n'est écrit du tout.** Pas « l'ancienne valeur
        // réécrite » — *rien*. La nuance se voit en trente-deux bits, où toute
        // écriture efface la moitié haute : le silicium a rendu `%rax` entier
        // là où j'écrivais un `%eax` étendu par zéro. Un seul cas sur 8 928,
        // et il énonce une vraie règle.
        //
        // Le choix porte donc sur le **registre entier**, après la règle de
        // largeur, et pas sur la valeur avant.
        let slot = Self::slot(step.dst);
        let mask = width.mask();
        body.store(slot, |b| {
            match width {
                Width::Qword | Width::Dword => {
                    b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                }
                _ => {
                    b.load(slot).constant(!mask).op(code::I64_AND);
                    b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                    b.op(code::I64_OR);
                }
            }
            b.load(slot);
            // `i64.ne` rend **déjà** un `i32` : c'est ce que `select` attend,
            // et le tronquer une seconde fois donne un module que le moteur
            // refuse. Ailleurs — dans `cmov` — le prédicat est un `i64` et la
            // troncature est nécessaire ; les deux ne se ressemblent qu'en
            // surface.
            b.load(Body::scratch(0)).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });
    }

    /// **Compter les bits à un.** Les six drapeaux sont définis, cinq à zéro.
    fn popcount(step: &Decoded, body: &mut Body) {
        body.store(Body::scratch(0), |b| {
            Self::right(step, b);
        });
        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT)
                .constant(!(CF | PF | AF | ZF | SF | OF))
                .op(code::I64_AND);
            b.load(Body::scratch(0)).op(code::I64_EQZ);
            b.op(code::I64_EXTEND_I32_U)
                .constant(ZF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);
        });
        body.store(Body::scratch(2), |b| {
            b.load(Body::scratch(0)).op(code::I64_POPCNT);
        });
        Self::write_back(step, step.width.mask(), body);
    }

    /// **Renverser les octets.** WebAssembly n'a pas d'opérateur pour ça : on
    /// l'écrit octet par octet, ce qui reste du code droit sans branchement.
    fn byte_swap(step: &Decoded, body: &mut Body) {
        let count = step.width as u64;
        body.store(Body::scratch(2), |b| {
            for rank in 0..count {
                b.load(Self::slot(step.dst));
                if rank != 0 {
                    b.constant(rank * 8).op(code::I64_SHR_U);
                }
                b.constant(0xff).op(code::I64_AND);
                let to = (count - 1 - rank) * 8;
                if to != 0 {
                    b.constant(to).op(code::I64_SHL);
                }
                if rank != 0 {
                    b.op(code::I64_OR);
                }
            }
        });
        Self::write_back(step, step.width.mask(), body);
    }

    /// **`lea`, c'est-à-dire une addition qui a l'air d'un accès mémoire.**
    ///
    /// Rien n'est lu ni écrit en mémoire invitée : l'adresse elle-même est le
    /// résultat. L'échelle est une puissance de deux, donc un décalage, et la
    /// somme boucle sur soixante-quatre bits — c'est ainsi que se codent les
    /// index négatifs.
    /// **Le préfixe de segment n'est pas lu ici, et c'est la conduite du
    /// silicium** : `lea` ne touche pas la mémoire, donc ne traverse pas
    /// l'unité de segmentation. Le corpus juge cette absence sur un vrai
    /// processeur.
    fn lea(step: &Decoded, body: &mut Body) -> Option<()> {
        let address = step.memory?;
        body.store(Body::scratch(2), |b| {
            b.constant(address.displacement as u64);
            if let Some(base) = address.base {
                b.load(Self::slot(base)).op(code::I64_ADD);
            }
            if let Some(index) = address.index {
                b.load(Self::slot(index));
                b.constant(u64::from(address.scale.trailing_zeros()))
                    .op(code::I64_SHL);
                b.op(code::I64_ADD);
            }
            b.constant(step.width.mask()).op(code::I64_AND);
        });
        Self::write_back(step, step.width.mask(), body);
        Some(())
    }

    /// **Une rotation, traduite sans branchement.**
    ///
    /// Deux règles la séparent d'un décalage. La première : rien ne se perd,
    /// donc le zéro, le signe et la parité du résultat ne disent rien de plus
    /// que ceux de l'opérande — l'architecture les déclare **non affectés**, et
    /// seuls CF et OF sont réécrits. La seconde : la retenue se lit sur le
    /// **résultat**, pas sur un dernier bit sorti. C'est ce qui rend juste le
    /// cas où le compte n'est pas nul mais le tour est complet : `rolb $8, %al`
    /// laisse l'octet tel quel et pose quand même CF sur son bit bas.
    fn rotate(step: &Decoded, body: &mut Body) {
        let width = step.width;
        let mask = width.mask();
        let sign = width.sign();
        let bits = width.bits();
        let count_mask: u64 = if width == Width::Qword { 63 } else { 31 };

        // scratch 0 : l'opérande. scratch 1 : le compte masqué.
        body.store(Body::scratch(0), |b| {
            Self::left(step, b);
        });
        body.store(Body::scratch(1), |b| {
            if step.count_is_cl {
                b.load(Self::slot(1));
            } else {
                b.constant(step.imm);
            }
            b.constant(count_mask).op(code::I64_AND);
        });
        // scratch 5 : le compte ramené dans la largeur.
        body.store(Body::scratch(5), |b| {
            b.load(Body::scratch(1)).constant(bits).op(code::I64_REM_U);
        });

        // scratch 2 : le résultat. Le décalage complémentaire vaut `bits` quand
        // le tour est complet, et WebAssembly masque tout compte de décalage à
        // six bits : pour une largeur plus courte que soixante-quatre l'opérande
        // masqué rend zéro de ce côté, et pour soixante-quatre le masque ramène
        // à zéro et rend l'opérande. Les deux cas tombent juste sans un test.
        body.store(Body::scratch(2), |b| {
            let (first, second) = match step.op {
                Op::Rol => (code::I64_SHL, code::I64_SHR_U),
                _ => (code::I64_SHR_U, code::I64_SHL),
            };
            b.load(Body::scratch(0)).load(Body::scratch(5)).op(first);
            b.load(Body::scratch(0));
            b.constant(bits).load(Body::scratch(5)).op(code::I64_SUB);
            b.op(second);
            b.op(code::I64_OR).constant(mask).op(code::I64_AND);
        });

        // scratch 3 : la retenue, lue **sur le résultat**.
        body.store(Body::scratch(3), |b| match step.op {
            Op::Rol => {
                b.load(Body::scratch(2)).constant(1).op(code::I64_AND);
            }
            _ => {
                b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
                b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
                b.constant(1).op(code::I64_XOR);
            }
        });

        // scratch 4 : le débordement. Défini pour un cran seulement ; ailleurs
        // le masque de l'oracle l'ignore.
        body.store(Body::scratch(4), |b| {
            // Le bit de tête du résultat, dans les deux cas.
            b.load(Body::scratch(2)).constant(sign).op(code::I64_AND);
            b.op(code::I64_EQZ).op(code::I64_EXTEND_I32_U);
            b.constant(1).op(code::I64_XOR);
            match step.op {
                // À gauche : le désaccord entre ce bit et la retenue.
                Op::Rol => {
                    b.load(Body::scratch(3));
                }
                // À droite : le désaccord entre les deux bits de tête.
                _ => {
                    b.load(Body::scratch(2))
                        .constant(bits - 2)
                        .op(code::I64_SHR_U);
                    b.constant(1).op(code::I64_AND);
                }
            }
            b.op(code::I64_XOR);
        });

        // Les drapeaux : **CF et OF seulement**, et rien si le compte est nul.
        body.store(RFLAGS_SLOT, |b| {
            b.load(RFLAGS_SLOT).constant(!(CF | OF)).op(code::I64_AND);
            b.load(Body::scratch(3))
                .constant(CF.trailing_zeros() as u64);
            b.op(code::I64_SHL).op(code::I64_OR);
            b.load(Body::scratch(4)).constant(1).op(code::I64_AND);
            b.constant(OF.trailing_zeros() as u64)
                .op(code::I64_SHL)
                .op(code::I64_OR);

            b.load(RFLAGS_SLOT);
            b.load(Body::scratch(1)).constant(0).op(code::I64_NE);
            b.op(code::SELECT);
        });

        // Un compte nul n'écrit aucun drapeau mais écrit bien la destination,
        // et c'est l'écriture ci-dessous qui le tient. Pas de `select` sur la
        // valeur : tourner de zéro rend l'opérande, et tourner d'un tour
        // complet aussi.
        if !step.discards {
            Self::write_back(step, mask, body);
        }
    }

    /// **Un transfert : lire à une largeur, écrire à une autre.**
    ///
    /// L'extension de signe se fait sans branchement, par le tour classique :
    /// décaler à gauche pour amener le bit de signe en position 63, puis
    /// décaler à droite **arithmétiquement**. WebAssembly n'a pas d'opérateur
    /// « étendre en signe depuis n bits » pour une largeur quelconque, mais il
    /// a `i64.shr_s`, et deux décalages font le même travail sans test.
    fn transfer(step: &Decoded, body: &mut Body) {
        body.store(Body::scratch(2), |b| {
            match step.memory {
                _ if step.immediate => {
                    b.constant(step.imm & step.src_width.mask());
                }
                Some(address) if step.memory_is_source => {
                    b.load_memory(&address, step.src_width);
                }
                _ => {
                    b.load(Self::slot(step.src));
                    if step.src_high {
                        b.constant(8).op(code::I64_SHR_U);
                    }
                    b.constant(step.src_width.mask()).op(code::I64_AND);
                }
            }
            if step.op == Op::Movsx {
                let spare = 64 - step.src_width.bits();
                if spare != 0 {
                    b.constant(spare).op(code::I64_SHL);
                    b.constant(spare).op(code::I64_SHR_S);
                }
            }
        });
        // La règle d'écriture est celle de tout le monde : une destination de
        // 32 bits efface la moitié haute, une de 8 ou 16 préserve le reste.
        Self::write_back(step, step.width.mask(), body);
    }

    /// **La règle que tout le monde oublie** : une écriture 32 bits efface les
    /// trente-deux bits de poids fort, alors qu'une écriture 8 ou 16 bits
    /// préserve le reste du registre.
    /// **Le seul endroit où une région parle à autre chose qu'à sa mémoire.**
    ///
    /// Les deux fonctions viennent de l'hôte (voir `HOST_OUT`). La largeur leur
    /// est passée **en octets** plutôt que déduite : l'hôte doit savoir si un
    /// `out %ax, %dx` a écrit deux octets ou un, et le lui faire deviner depuis
    /// la valeur donnerait un octet pour tout ce qui tient sur un octet.
    ///
    /// **Le port vient de deux endroits.** L'opcode immédiat le porte ; les
    /// formes `%dx` le prennent dans les seize bits bas de `rdx`. C'est
    /// `immediate` qui les sépare — et non `imm != 0`, qui confondrait
    /// `out $0, %al` avec `out %al, %dx`.
    ///
    /// **La valeur, et le registre, sont toujours l'accumulateur.** Le codage
    /// ne laisse pas le choix : `out` écrit `%al`/`%ax`/`%eax`, `in` les
    /// remplit. `Decoded::nothing` pose déjà `dst: 0`, donc `write_back`
    /// applique la règle de largeur x86 sans rien de particulier ici : un `in`
    /// de quatre octets efface les trente-deux bits hauts, un `in` d'un octet
    /// laisse le reste de `rax` tel quel.
    fn port(step: &Decoded, body: &mut Body) -> Option<()> {
        let mask = step.width.mask();
        let bytes = step.width as u64;
        let push_port = |b: &mut Body| {
            if step.immediate {
                b.constant(step.imm & 0xffff);
            } else {
                b.load(Self::slot(RDX)).constant(0xffff).op(code::I64_AND);
            }
        };
        match step.op {
            Op::PortOut => {
                push_port(body);
                body.load(Self::slot(RAX)).constant(mask).op(code::I64_AND);
                body.constant(bytes).call(HOST_OUT);
            }
            Op::PortIn => {
                body.store(Body::scratch(2), |b| {
                    push_port(b);
                    b.constant(bytes).call(HOST_IN);
                    // L'hôte peut rendre n'importe quoi ; la largeur est notre
                    // affaire, pas la sienne.
                    b.constant(mask).op(code::I64_AND);
                });
                Self::write_back(step, mask, body);
            }
            _ => unreachable!("`port` ne reçoit que des entrées-sorties"),
        }
        Some(())
    }

    fn write_back(step: &Decoded, mask: u64, body: &mut Body) {
        // **Quand la destination est en mémoire, la règle de largeur ne
        // s'applique pas.** Elle décrit ce qu'une écriture de registre fait au
        // reste du registre ; en mémoire, on écrit exactement les octets de la
        // largeur, et l'octet d'à côté n'est pas concerné.
        if let Some(address) = step.memory {
            // **`lea` est l'exception.** Elle porte une adresse et n'écrit pas
            // dedans : l'adresse **est** son résultat, et sa destination est un
            // registre. La faire passer par ici l'écrivait à l'adresse — le
            // moteur l'a dit tout de suite, « Out of bounds memory access »,
            // parce que la première adresse venue sortait de la RAM déclarée.
            if !step.memory_is_source && step.op != Op::Lea {
                body.store_memory(&address, step.width, |b| {
                    b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                });
                return;
            }
        }
        let slot = Self::slot(step.dst);
        body.store(slot, |b| {
            if step.dst_high {
                b.load(slot).constant(!0xff00u64).op(code::I64_AND);
                b.load(Body::scratch(2)).constant(0xff).op(code::I64_AND);
                b.constant(8).op(code::I64_SHL).op(code::I64_OR);
                return;
            }
            match step.width {
                Width::Qword | Width::Dword => {
                    b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                }
                _ => {
                    b.load(slot).constant(!mask).op(code::I64_AND);
                    b.load(Body::scratch(2)).constant(mask).op(code::I64_AND);
                    b.op(code::I64_OR);
                }
            }
        });
    }
}

#[cfg(test)]
mod port_tests {
    use super::*;

    /// **Deux formes que rien ne distinguait doivent produire deux modules.**
    ///
    /// Ce test remplace celui qui tenait le refus de traduire : sa prémisse —
    /// « l'émetteur ne sait pas encore » — n'est plus vraie, et un test dont la
    /// prémisse est morte ne garde plus rien. Le danger qu'il nommait, lui, est
    /// intact et se déplace ici : une entrée-sortie *presque* juste est pire
    /// qu'un refus franc, et « presque juste » a deux formes précises.
    ///
    /// **La largeur.** `out %al, %dx` écrit un octet, `out %ax, %dx` en écrit
    /// deux. L'hôte ne peut pas le deviner depuis la valeur — deux octets dont
    /// le haut est nul ressemblent à un octet. S'ils produisaient le même
    /// module, la largeur ne serait pas passée.
    ///
    /// **La provenance du port.** `out $0, %al` parle au port zéro ;
    /// `out %al, %dx` parle à celui que `rdx` désigne, qui pour une console de
    /// noyau vaut `0x3f8`. Les deux portent `imm: 0` ; s'ils produisaient le
    /// même module, l'invité se tairait sans que rien ne le signale.
    #[test]
    fn the_width_and_the_ports_provenance_both_reach_the_module() {
        let module = |bytes: &[u8]| Module::region_or_why(bytes, 0x1000, 0).expect("se traduit");

        // `out %al, %dx` contre `out %ax, %dx` — le préfixe 0x66 fait la
        // largeur, et `ret` clôt les deux régions.
        let byte_wide = module(&[0xee, 0xc3]);
        let word_wide = module(&[0x66, 0xef, 0xc3]);
        assert_ne!(
            byte_wide, word_wide,
            "la largeur ne parvient pas à l'hôte : un octet et deux donnent le même module"
        );

        // `out $0, %al` contre `out %al, %dx` : même `imm`, deux ports.
        let port_zero = module(&[0xe6, 0x00, 0xc3]);
        let port_in_dx = module(&[0xee, 0xc3]);
        assert_ne!(
            port_zero, port_in_dx,
            "le port zéro et « le port est dans DX » produisent le même module"
        );
    }

    // MARK: - Lire un module émis plutôt que chercher des octets dedans

    /// Les imports du module, dans l'ordre : module, nom, genre.
    ///
    /// Lus en marchant les sections, pas cherchés comme une sous-chaîne. Une
    /// recherche d'octets dirait « `out` est là » d'un module qui le déclare
    /// au mauvais genre, à la mauvaise place, ou dans une chaîne de constante —
    /// et c'est la place qui décide de l'indice de fonction, donc du reste.
    fn imports_of(module: &[u8]) -> Vec<(String, String, u8)> {
        let body = section_of(module, 2).expect("un module a une section d'imports");
        let mut at = 0;
        let count = uleb(body, &mut at);
        let mut found = Vec::new();
        for _ in 0..count {
            let from = name(body, &mut at);
            let field = name(body, &mut at);
            let kind = body[at];
            at += 1;
            match kind {
                // Fonction : un indice de type.
                0x00 => {
                    uleb(body, &mut at);
                }
                // Table : le type d'élément, puis des limites.
                0x01 => {
                    at += 1;
                    limits(body, &mut at);
                }
                // Mémoire : des limites.
                0x02 => limits(body, &mut at),
                // Globale : un type de valeur, puis la mutabilité.
                0x03 => at += 2,
                other => panic!("genre d'import inconnu : {other:#x}"),
            }
            found.push((from, field, kind));
        }
        found
    }

    /// Les indices de fonction que la section des éléments pose dans la table.
    fn elements_of(module: &[u8]) -> Vec<u64> {
        let body = section_of(module, 9).expect("un module a une section d'éléments");
        let mut at = 0;
        assert_eq!(uleb(body, &mut at), 1, "un seul segment");
        uleb(body, &mut at); // la table visée
        while body[at] != code::END {
            at += 1;
        }
        at += 1;
        let count = uleb(body, &mut at);
        (0..count).map(|_| uleb(body, &mut at)).collect()
    }

    /// L'indice de fonction que l'export `run` désigne.
    fn exported_run(module: &[u8]) -> u64 {
        let body = section_of(module, 7).expect("un module a une section d'exports");
        let mut at = 0;
        let count = uleb(body, &mut at);
        for _ in 0..count {
            let field = name(body, &mut at);
            let kind = body[at];
            at += 1;
            let index = uleb(body, &mut at);
            if field == "run" && kind == 0x00 {
                return index;
            }
        }
        panic!("aucun export `run`");
    }

    fn section_of(module: &[u8], want: u8) -> Option<&[u8]> {
        let mut at = 8; // l'en-tête
        while at < module.len() {
            let id = module[at];
            at += 1;
            let length = uleb(module, &mut at) as usize;
            if id == want {
                return Some(&module[at..at + length]);
            }
            at += length;
        }
        None
    }

    fn uleb(bytes: &[u8], at: &mut usize) -> u64 {
        let mut value = 0u64;
        let mut shift = 0;
        loop {
            let byte = bytes[*at];
            *at += 1;
            value |= u64::from(byte & 0x7f) << shift;
            if byte & 0x80 == 0 {
                return value;
            }
            shift += 7;
        }
    }

    fn name(bytes: &[u8], at: &mut usize) -> String {
        let length = uleb(bytes, at) as usize;
        let text = String::from_utf8(bytes[*at..*at + length].to_vec()).expect("un nom UTF-8");
        *at += length;
        text
    }

    fn limits(bytes: &[u8], at: &mut usize) {
        let flag = bytes[*at];
        *at += 1;
        uleb(bytes, at);
        if flag & 0x01 != 0 {
            uleb(bytes, at);
        }
    }

    // MARK: - Ce qu'un noyau qui parle exige du module

    /// **L'invité peut écrire dans un port**, et l'hôte le reçoit par un appel.
    ///
    /// Sortir de la région à chaque octet coûterait un retour de main —
    /// mesuré à environ 190 ns — pour un caractère de console. Un appel importé
    /// coûte des dizaines de nanosecondes, et c'est ce que fait v86.
    #[test]
    fn a_port_write_becomes_a_call_to_the_host() {
        // `out %al, $0x80` puis `ret`.
        let module = Module::region_or_why(&[0xe6, 0x80, 0xc3], 0x1000, 0)
            .expect("une écriture de port se traduit");
        let imports = imports_of(&module);
        assert_eq!(
            imports
                .first()
                .map(|(m, f, k)| (m.as_str(), f.as_str(), *k)),
            Some(("env", "out", 0x00)),
            "le premier import doit être la fonction `env.out` : {imports:?}"
        );
    }

    /// **Et lire dedans**, ce qui demande un second import, qui rend une valeur.
    #[test]
    fn a_port_read_becomes_its_own_call() {
        // `in $0x80, %al` puis `ret`.
        let module = Module::region_or_why(&[0xe4, 0x80, 0xc3], 0x1000, 0)
            .expect("une lecture de port se traduit");
        let imports = imports_of(&module);
        assert_eq!(
            imports.get(1).map(|(m, f, k)| (m.as_str(), f.as_str(), *k)),
            Some(("env", "in", 0x00)),
            "le second import doit être la fonction `env.in` : {imports:?}"
        );
    }

    /// **Un refus qui nomme ce qui manque, au lieu d'un silence.**
    ///
    /// C'est tout le changement observable de cette tranche. Avant, `wrmsr`
    /// faisait rendre `CannotDecode` : « il y a des octets que je ne sais pas
    /// lire », sans dire lesquels ni pourquoi. On ne peut ni suivre ça, ni le
    /// compter, ni savoir si la liste raccourcit.
    ///
    /// Maintenant le décodeur la nomme et l'émetteur la refuse franchement.
    /// L'instruction n'est pas exécutable pour autant — il faudrait un modèle
    /// de registres spécifiques au modèle — et c'est justement ce que le refus
    /// dit.
    #[test]
    fn a_privileged_instruction_is_refused_by_name_not_by_silence() {
        // **Deux instructions ont quitté cette liste, et c'est le test qui l'a
        // dit les deux fois.** `rdtsc` d'abord, `cpuid` ensuite : chaque fois
        // l'assertion a échoué au premier passage de la tranche qui la
        // produisait, ce qui est exactement son rôle. Une liste de refus qu'on
        // ne raccourcit jamais ne mesure plus rien — et une qui raccourcit sans
        // rien casser ne gardait rien.
        // **Cette liste est vide de MSR depuis la tranche de l'aiguillage.**
        // `rdmsr` et `wrmsr` se traduisent maintenant tous les deux ; ce qui
        // refuse est un *numéro*, à l'exécution, et un refus d'exécution ne se
        // mesure pas ici. Ce qui reste sont les écritures qui allumeraient
        // quelque chose qu'on n'a pas.
        // **Lire un registre de contrôle a quitté cette liste ; l'écrire non.**
        // C'est toute l'asymétrie de la tranche : ranger et rendre est fidèle,
        // allumer la pagination serait un mensonge.
        for (bytes, what) in [
            (&[0x0f, 0x22, 0xd8, 0xc3][..], "mov %rax,%cr3"),
            (&[0x0f, 0x22, 0xc1, 0xc3][..], "mov %rcx,%cr0"),
        ] {
            match Module::region_or_why(bytes, 0x1000, 0) {
                Err(Refused::CannotTranslate { at }) => {
                    assert_eq!(at, 0, "à la première instruction, pour {what}")
                }
                other => panic!("{what} doit être refusée en étant nommée, pas {other:?}"),
            }
        }
    }

    /// **Un retour lointain termine son bloc, et proprement.**
    ///
    /// Ce test existe parce que le précédent ne pouvait pas l'attraper : dans la
    /// suite d'entrée du noyau, `wrmsr` refuse à l'octet 35 et **masque** tout
    /// ce qui vient après. Une assertion qui ne peut pas voir le défaut qu'elle
    /// prétend garder n'est pas une garde — un sabotage l'a montré, en
    /// survivant.
    ///
    /// La suite est donc minuscule et sans rien d'intraduisible avant le
    /// `lretq`. Elle tient les deux moitiés :
    ///
    /// - le retour lointain n'est **pas envoyé au traducteur d'instructions** —
    ///   il changerait le bloc, pas l'état, et le traducteur refuserait ;
    /// - il **termine** son bloc — l'octet indécodable qui le suit n'est pas
    ///   atteignable par cette route, et le lire ferait refuser une région
    ///   parfaitement bonne. Un noyau range souvent des données juste après.
    #[test]
    fn a_far_return_ends_its_block_without_reaching_the_instruction_translator() {
        let after_a_far_return: &[u8] = &[
            0x48, 0x89, 0xc3, // mov %rax,%rbx
            0x48, 0xcb, // lretq
            0x62, // un octet que le décodeur ne lit pas — et n'a pas à lire
        ];
        assert!(
            Module::region_or_why(after_a_far_return, 0x1000, 0).is_ok(),
            "la région s'arrête au retour lointain, sans toucher à ce qui suit"
        );
    }

    /// **Un retour d'interruption termine son bloc, comme le lointain.** Il
    /// est écrit dans **neuf** listes, et un `matches!` en oublie une sans
    /// que rien ne change de couleur : l'`iretq` tomberait alors dans le chemin
    /// arithmétique, ou la région continuerait à lire ce qui suit. Ce test
    /// tient la première liste — celle qui décide qu'on ne traduit pas ce qui
    /// vient après.
    #[test]
    fn an_interrupt_return_ends_its_block_without_reaching_the_instruction_translator() {
        let after_an_iretq: &[u8] = &[
            0x48, 0x83, 0xc4, 0x08, // add $8,%rsp — le code d'erreur, jeté
            0x48, 0xcf, // iretq
            0x62, // un octet que le décodeur ne lit pas — et n'a pas à lire
        ];
        assert!(
            Module::region_or_why(after_an_iretq, 0x1000, 0).is_ok(),
            "la région s'arrête au retour d'interruption, sans toucher à ce qui suit"
        );
    }

    /// **`iretd` est refusé en étant nommé.** `cf` sans REX.W se décode — le
    /// décodeur ne fait pas passer un opcode connu pour un octet inconnu — mais
    /// c'est un retour de trente-deux bits, et cette machine n'en pose jamais
    /// le cadre. Le refus est à l'adresse de l'instruction, pas au début de la
    /// région, pour qu'un relevé désigne la bonne ligne.
    #[test]
    fn a_thirty_two_bit_interrupt_return_is_refused_by_name() {
        let narrow: &[u8] = &[
            0x48, 0x89, 0xc3, // mov %rax,%rbx
            0xcf, // iretd
        ];
        match Module::region_or_why(narrow, 0x1000, 0) {
            Err(Refused::CannotTranslate { at }) => assert_eq!(at, 3, "à l'iretd, pas avant"),
            other => panic!("iretd doit être refusé en étant nommé, pas {other:?}"),
        }
    }

    /// **La retpoline, telle que le noyau la porte avant que les alternatives
    /// ne la réécrivent.** `call +1 ; int3 ; mov %rax,(%rsp) ; ret` — le
    /// `call` enjambe l'`int3`, qui n'est là que pour piéger la spéculation.
    /// Il n'est jamais exécuté, et il arrêtait pourtant tout : la région
    /// entière était refusée sur cet octet, à `__x86_indirect_thunk_rax`,
    /// après 122 régions d'un vrai noyau.
    #[test]
    fn the_retpoline_thunk_translates_before_the_alternatives_rewrite_it() {
        let thunk: &[u8] = &[
            0xe8, 0x01, 0x00, 0x00, 0x00, // call +1
            0xcc, // int3 — enjambé
            0x48, 0x89, 0x04, 0x24, // mov %rax,(%rsp)
            0xc3, // ret
        ];
        assert!(
            Module::region_or_why(thunk, 0x1000, 0).is_ok(),
            "le thunk se traduit, int3 compris"
        );
    }

    /// **Les treize instructions du point d'entrée se lisent toutes — et ce qui
    /// reste n'est plus de la lecture.**
    ///
    /// Alpine 6.6.134, jusqu'à son `lretq` compris. Avant, le retour lointain
    /// n'était pas lisible du tout et l'octet 52 était le bout du monde.
    ///
    /// **Ce que ce test refuse de laisser confondre.** Ce qui arrête maintenant
    /// la région est `wrmsr`, à l'octet 35 : le décodeur le **lit**, l'émetteur
    /// ne sait pas le **produire**. `CannotDecode` et `CannotTranslate` ne
    /// demandent pas le même travail — l'un est une table à compléter, l'autre
    /// une sémantique à écrire — et les confondre ferait croire qu'il reste des
    /// octets illisibles là où il reste une décision à prendre.
    ///
    /// Vérifiable sans l'image de 34 Mio, qui ne peut pas vivre dans le dépôt.
    #[test]
    fn the_kernels_entry_reads_whole_and_stops_on_a_semantics_not_a_byte() {
        let entry: &[u8] = &[
            0x49, 0x89, 0xf7, // mov %rsi,%r15
            0x48, 0x8d, 0x25, 0xbe, 0x3e, 0x40, 0x01, // lea …,%rsp
            0x48, 0x8d, 0x3d, 0x5f, 0xff, 0xff, 0xff, // lea …,%rdi
            0xb9, 0x01, 0x01, 0x00, 0xc0, // mov $0xc0000101,%ecx
            0x48, 0x8d, 0x15, 0x53, 0x9f, 0x9e, 0x01, // lea …,%rdx
            0x89, 0xd0, // mov %edx,%eax
            0x48, 0xc1, 0xea, 0x20, // shr $0x20,%rdx
            0x0f, 0x30, // wrmsr
            0xe8, 0xa6, 0x05, 0x00, 0x00, // call …
            0x6a, 0x10, // push $0x10
            0x48, 0x8d, 0x05, 0x03, 0x00, 0x00, 0x00, // lea 3(%rip),%rax
            0x50, // push %rax
            0x48, 0xcb, // lretq
        ];
        assert_eq!(entry.len(), 54, "les treize instructions du point d'entrée");
        // Les treize se lisent, sans trou.
        let (mut at, mut read) = (0usize, 0usize);
        while at < entry.len() {
            let step = crate::x86::decode(&entry[at..])
                .unwrap_or_else(|| panic!("l'octet {at} ne se décode pas"));
            at += step.length.max(1);
            read += 1;
        }
        assert_eq!(read, 13, "treize instructions");
        assert_eq!(at, entry.len(), "et pas un octet de reste");

        // **Et depuis la tranche des MSR, elle se traduit en entier.**
        //
        // Elle butait à l'octet 35 — `wrmsr` — depuis le début de ce travail.
        // Ce n'est plus le cas, et c'est le premier moment où le point d'entrée
        // d'un vrai noyau passe le traducteur d'un bout à l'autre.
        //
        // **Ce que ça ne prouve pas**, et qu'il faut dire ici pour ne pas le
        // relire de travers plus tard : la traduction émet un aiguillage à
        // l'exécution, donc elle réussirait pour **n'importe quel** numéro de
        // MSR. Que celui-ci soit `GS_BASE` — le seul des trois qui change
        // réellement une adresse — est vrai, mais c'est un autre test qui le
        // tient, en mesurant un accès mémoire plutôt qu'une compilation.
        match Module::region_or_why(entry, 0x1000090, 0) {
            Ok(_) => {}
            other => panic!("le point d'entrée doit se traduire en entier, pas {other:?}"),
        }
    }

    /// **Chaque famille privilégiée est refusée pour la bonne raison.**
    ///
    /// C'est tout l'objet de cette tranche, et c'est la seule chose qu'elle
    /// change : `CannotDecode` dit « il y a un octet que je ne sais pas lire »
    /// sans dire lequel ; `CannotTranslate` porte l'adresse d'une instruction
    /// **nommée**. Le nombre de régions refusées, lui, ne bouge pas — mesuré
    /// sur les huit mégaoctets de texte d'Alpine : 183 avant, 183 après.
    ///
    /// La distinction se perdrait en silence : si une de ces formes cessait de
    /// se décoder, la région serait toujours refusée, la couverture toujours
    /// la même, et seul le message changerait. Les deux moitiés sont donc
    /// vérifiées séparément — le décodeur la lit **et** l'émetteur la refuse.
    /// **Les deux moitiés d'une section critique se produisent maintenant.**
    ///
    /// **Ce test disait le contraire, et il avait raison de le dire.**
    /// L'asymétrie était écrite ainsi : lire RFLAGS ne peut rien allumer,
    /// l'écrire peut rallumer le drapeau d'interruption **sans jamais nommer
    /// `sti`** — donc un module qui accepte `popf` accepte un `sti` déguisé.
    ///
    /// L'argument tenait tant que `sti` était refusé. Il est produit depuis la
    /// tranche du `hlt`, et un `popfq` — précédé d'un `push $0` — arrêtait la
    /// quatrième région d'un vrai noyau à l'octet 400. Refuser l'un en
    /// produisant l'autre n'a plus de sens.
    ///
    /// Les deux sont donc vérifiés **ensemble**, comme avant : c'est ensemble
    /// qu'ils ont un sens, et un aller-retour est la seule façon de le dire.
    #[test]
    fn the_flags_make_a_round_trip_through_the_stack() {
        assert!(
            Module::region_or_why(&[0x9c, 0xc3], 0x1000, 0).is_ok(),
            "`pushfq` se produit : il ne fait que lire RFLAGS"
        );
        assert!(
            Module::region_or_why(&[0x9d, 0xc3], 0x1000, 0).is_ok(),
            "`popfq` se produit aussi, avec le masque du cœur Swift : refuser \
             l'écriture en produisant la lecture n'a plus de raison depuis que \
             `sti` existe"
        );
    }

    #[test]
    fn every_privileged_family_is_refused_by_name_and_not_by_silence() {
        for (nom, forme) in [
            // **Les tables de descripteurs ont quitté cette liste en entier** :
            // `lgdt`, `lidt`, `sgdt` et `sidt` sont produits depuis cette
            // tranche. C'est la première famille qui en sort complète — et ce
            // n'est possible que parce que rien ne *lit* ces registres : le
            // jour où un chemin consulte la table, la question se rouvrira.
            // `swapgs` a quitté cette liste : la base du noyau existe depuis
            // la tranche des MSR, donc l'échange est exact. `wrmsr` et `rdmsr`
            // l'ont quittée aussi — ce qui refuse est désormais un **numéro**,
            // à l'exécution, et non l'instruction.
            // **Les sélecteurs ne sont plus refusés en bloc.** Ranger un
            // segment et en charger un dont la base est morte — ES, SS, DS —
            // sont produits depuis cette tranche. Ce qui reste ici est ce qui
            // demanderait une table qu'on n'a pas, et la forme que rien
            // n'exerce.
            // **`mov %ax,%fs` a quitté cette liste, et le refus n'a pas
            // disparu : il a changé d'heure.** Il était rendu à la
            // traduction, donc il emportait la région entière — 237 octets
            // d'un vrai noyau qui n'ont jamais tourné pour une instruction au
            // bout d'un chemin d'erreur. Il est maintenant rendu à
            // l'**exécution**, et seulement quand le sélecteur est non nul :
            // la machine s'arrête en nommant la table qui manque, au lieu de
            // refuser tout ce qui l'entoure. Un sélecteur nul, lui, ne lit
            // aucun descripteur et se produit.
            //
            // Ce qui reste refusé à la traduction est la forme dont la source
            // est en **mémoire** : le sélecteur ne se connaît alors qu'après
            // une lecture, et rien n'exerce cette forme.
            ("mov (%rax),%fs", &[0x8e, 0x20][..]),
            ("mov %ds,(%rax)", &[0x8c, 0x18][..]),
            // Lire est produit depuis cette tranche ; écrire CR4 aussi. Ce qui
            // reste est ce qui allumerait la pagination.
            ("mov %rax,%cr3", &[0x0f, 0x22, 0xd8][..]),
            ("mov %rcx,%cr0", &[0x0f, 0x22, 0xc1][..]),
            // **`cli`, `sti` et `hlt` ont quitté cette liste**, et c'est une
            // mesure qui les a fait partir : ils arrêtaient la quatrième
            // région d'un vrai noyau à l'octet 237, dans le `cli; hlt; jmp -2`
            // que `head_64.S` place au bout d'un chemin d'**erreur**. Une
            // région est refusée en entier, donc les 237 octets d'avant ne
            // tournaient pas non plus, alors que rien ne dit que le noyau
            // irait jusqu'à cet arrêt.
            //
            // `cli` et `sti` posent un bit, ce que fait aussi le silicium.
            // `hlt` n'est pas feint pour autant : il pose son témoin et rend
            // la main, et c'est l'hôte qui **nomme** l'arrêt. Dire « je sais
            // traduire, et rien ne peut réveiller cette machine » est plus
            // vrai que « je ne sais pas traduire ».
            //
            // **`pushfq` et `popfq` ont quitté cette liste tous les deux.**
            // Le premier ne fait que lire ; le second a suivi quand `sti` est
            // devenu produit — refuser l'écriture des drapeaux en produisant
            // l'instruction qui en allume un n'avait plus de sens. `popfq`
            // porte le masque du cœur Swift, et un test compare les deux
            // littéraux pour qu'ils ne divergent pas.
            //
            // **Cette liste n'est plus qu'à deux entrées**, et les deux sont
            // des formes que rien n'exerce : un sélecteur venu de la mémoire,
            // et un segment rangé en mémoire.
        ] {
            // Première moitié : le décodeur la lit, entière.
            let step =
                crate::x86::decode(forme).unwrap_or_else(|| panic!("`{nom}` doit se décoder"));
            assert_eq!(step.length, forme.len(), "`{nom}` : la longueur entière");

            // Seconde moitié : l'émetteur la refuse, et le refus porte son
            // adresse. Le `ret` qui suit ferme le bloc ; sans lui la région
            // serait refusée pour une raison sans rapport.
            let mut region = forme.to_vec();
            region.push(0xc3);
            match Module::region_or_why(&region, 0x1000090, 0) {
                Err(Refused::CannotTranslate { at }) => {
                    assert_eq!(at, 0, "`{nom}` : le refus porte l'adresse de l'instruction")
                }
                other => panic!("`{nom}` : attendu un refus de traduction, pas {other:?}"),
            }
        }
    }

    /// **Le piège de cette tranche, et le seul qui casserait tout en silence.**
    ///
    /// Une fonction *importée* occupe le début de l'espace d'indices : avec deux
    /// imports, le bloc zéro n'est plus la fonction zéro mais la fonction deux.
    /// Oublier ce décalage ne produit pas une erreur de liaison — la table
    /// pointerait les imports eux-mêmes, du bon type, et la boucle appellerait
    /// `out` en croyant exécuter le premier bloc.
    ///
    /// Les deux endroits où l'indice apparaît sont donc lus ici, sur un module
    /// qui ne contient aucune entrée-sortie : le décalage vaut pour tous.
    #[test]
    fn the_two_host_imports_push_every_block_index_along() {
        // `nop` puis `ret` : deux blocs, aucune entrée-sortie.
        let module = Module::region_or_why(&[0x90, 0xc3], 0x1000, 0).expect("une région sans port");
        let blocks = elements_of(&module);
        assert_eq!(
            blocks,
            (2..2 + blocks.len() as u64).collect::<Vec<_>>(),
            "les blocs commencent après les deux imports"
        );
        assert_eq!(
            exported_run(&module),
            2 + blocks.len() as u64,
            "`run` vient après les imports et après les blocs"
        );
    }
}

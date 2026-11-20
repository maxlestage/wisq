// **La boucle hôte du bureau local, celle qui vivra dans la vue.**
//
// La feuille de route l'établit et il faut le relire avant de toucher à ce
// fichier : le bureau local n'est pas « l'application qui pilote un module »,
// c'est **la machine qui vit dans la vue**. La RAM de l'invité *est* la
// mémoire linéaire du module, adresse pour adresse ; cette mémoire vit dans le
// processus de contenu de WebKit, et une application ne la partage pas. Ce qui
// reprend après un retour de main doit la lire — donc ce qui reprend vit ici,
// pas dans l'application.
//
// Ce que l'application fournit : **la traduction**. Elle seule porte
// l'émetteur, en Rust, derrière `wisq_x86_emit_region`. Elle est donc passée
// en paramètre, et elle est **asynchrone** : dans l'application c'est un
// aller-retour par message vers le processus hôte, pas un appel. Écrire la
// boucle avec un traducteur synchrone aurait donné du code à jeter.
//
// Ce fichier est du JavaScript sans dépendance et sans module bundler : il est
// destiné à être évalué tel quel dans un `WKWebView`, et il se teste ici sous
// Bun, qui embarque le même JavaScriptCore.

/// Les emplacements des globales, tels que l'émetteur les numérote. Ils sont
/// **répétés ici** au lieu d'être importés, parce que rien ne traverse la
/// frontière entre Rust et cette vue à part des octets. Le test les compare aux
/// constantes de la bibliothèque, sinon la répétition finirait par mentir.
/// **Pourquoi la machine s'est arrêtée.** Les nombres viennent de
/// `x86_wasm.rs` — `STOP_HALTED`, `STOP_SELECTOR`, `STOP_KERNEL_GS`,
/// `STOP_HYPERVISOR`, `STOP_PCID`, `STOP_LDT`, `STOP_DEBUG` — et un nombre
/// que ce tableau ne connaît pas se dit quand même, plutôt que de passer pour
/// « rien ». `STOP_MSR` n'y est pas : il porte le numéro du registre dans ses
/// trente-deux bits bas, et se lit à part. `STOP_MXCSR` non plus : c'est une
/// `#GP(0)` que la boucle délivre, et son arrêt, sans porte, se dit par la
/// délivrance.
const STOPS = {
  1n: "arrêtée sur hlt",
  2n: "un sélecteur non nul dans FS ou GS, sans table de descripteurs",
  3n: "arrêtée sur lkgs : la base GS du noyau depuis un sélecteur, sans table de descripteurs",
  4n: "arrêtée sur un appel à l'hyperviseur (vmcall ou vmmcall) : cette machine n'en a pas",
  5n: "arrêtée sur invpcid : purger le tampon par identifiant de contexte, et cette machine n'a pas de PCID",
  6n: "arrêtée sur lldt : une table de descripteurs locale non nulle, sans table globale où la trouver",
  7n: "arrêtée sur une écriture dans un registre de débogage : cette machine n'a pas de points d'arrêt matériels",
};
/// **`STOP_HALTED`** : l'invité s'est arrêté sur un `hlt`. Nommé ici parce que
/// la boucle en décide — un `hlt` qu'une interruption peut encore réveiller
/// attend — et pas seulement parce qu'elle le raconte.
const STOP_HALTED = 1n;
/// **L'arrêt d'une machine qui a demandé à redémarrer**, par l'impulsion de
/// l'i8042 de la carte — le nom que le banc du cœur Swift lui donne.
const ARRET_REMISE = "redémarrage demandé (impulsion du 8042)";
/// **`STOP_INTERRUPT | vecteur`** : une interruption logicielle, que l'hôte
/// délivre au lieu de s'arrêter. RIP est déjà après l'instruction.
const STOP_INTERRUPT = 0x100n;
/// **`ud2`** : l'instruction indéfinie, que l'hôte délivre au vecteur 6 au lieu
/// de s'arrêter. RIP est **sur** l'instruction.
const STOP_UNDEFINED = 8n;
/// **`STOP_MSR | numéro`** : un registre spécifique au modèle que le module ne
/// modélise pas. Le numéro vient d'ECX à l'exécution, donc c'est le module qui
/// le pose dans le témoin. RIP est sur l'instruction — et c'est là que l'hôte
/// délivre la `#GP(0)` que le silicium lèverait, au lieu de s'arrêter : c'est
/// au noyau de décider, sa table d'exceptions rattrape ces fautes-là. Sans
/// porte, l'arrêt reste, et nomme le numéro.
const STOP_MSR = 1n << 32n;
/// **`STOP_MXCSR`** : `ldmxcsr` ou `fxrstor` voulaient charger un MXCSR aux
/// bits réservés levés. RIP est sur l'instruction, rien n'a changé, et c'est
/// une `#GP(0)` que l'hôte délivre. `ldmxcsr` est permise en anneau trois :
/// sans cette délivrance, n'importe quel programme arrêtait la machine
/// entière, là où le silicium ne fait fauter que lui.
const STOP_MXCSR = 9n;
/// **Une écriture est tombée sur du code traduit** : `STOP_WRITTEN` côté
/// Rust. Ce n'est pas un arrêt, c'est la région qui rend la main, son
/// instruction finie, pour que l'hôte oublie ce qui a été écrit ;
/// `voirEcritures` l'efface avant de regarder quoi que ce soit d'autre.
const STOP_WRITTEN = 10n;

/// **La délivrance d'une faute, et ce qu'elle suppose.**
///
/// Le vecteur de la faute de page est le seul que cette machine produise :
/// c'est le témoin `FAULT_SLOT` qui le dit, posé par la marche du module quand
/// une page manque. Les dix vecteurs qui portent un code d'erreur sont ceux du
/// manuel ; le noyau compte dessus pour retrouver son cadre, et en oublier un
/// décalerait toute la pile de huit octets.
const PAGE_FAULT = 14;
/// **Le bit 2 du code d'erreur d'une faute de page : l'accès venait de
/// l'espace utilisateur.**
///
/// C'est **le** bit que Linux regarde pour trancher entre « une page manque à
/// un programme, je la lui pose » et « le noyau est parti dans le décor,
/// j'affiche un oops ». Le cœur Swift l'a payé une fois, au lot 7 : premier
/// programme jamais lancé, `Oops: 0010`, puis `Kernel panic — not syncing:
/// Attempted to kill init!`. Le journal le dit en une phrase — « le programme
/// n'avait rien fait de mal, on avait juste oublié de dire qu'il était le
/// programme ».
///
/// Le niveau vient des deux bits du bas de CS, et de rien d'autre.
const USER_FAULT = 0x4n;
/// **Le bit 4 : l'accès était un chargement d'instruction.** Et le manuel le
/// réserve — « set to 0 if CR4.SMEP = 0 and either CR4.PAE = 0 or
/// IA32_EFER.NXE = 0 ». En mode long PAE est toujours posé, donc la condition
/// se réduit à SMEP ou NXE ; cette machine n'arme ni l'un ni l'autre, et son
/// propre noyau le dit au démarrage — « Notice: NX (Execute Disable)
/// protection missing in CPU! ». Le poser d'office serait une infidélité
/// silencieuse : un noyau qui distingue les deux causes agirait sur un bit que
/// le silicium ne lui aurait pas donné.
const FETCH_FAULT = 0x10n;
/// `IA32_EFER.NXE`, et `CR4.SMEP` : les deux qui rendent le bit 4 vivant.
const NX_ENABLE = 1n << 11n;
const SMEP_ENABLE = 1n << 20n;
/// **La faute de protection générale**, vecteur 13, avec un code d'erreur.
/// C'est elle que le silicium lève sur un `wrmsr` ou un `rdmsr` dont le
/// numéro n'existe pas — et le noyau le sait, sa table d'exceptions la
/// rattrape.
const GENERAL_PROTECTION = 13;
/// **L'instruction indéfinie**, vecteur 6, sans code d'erreur. C'est celle que
/// Linux se lève à lui-même : `WARN()` compile en un `ud2`, et son
/// gestionnaire consulte `__bug_table` pour décider s'il reprend — ce qu'il
/// fait des dizaines de fois par démarrage — ou s'il panique.
const INVALID_OPCODE = 6;
const WITH_ERROR_CODE = new Set([8, 10, 11, 12, 13, 14, 17, 21, 29, 30]);
/// Les bits de RFLAGS qu'une entrée de gestionnaire éteint : le pas-à-pas, le
/// drapeau imbriqué et la reprise toujours ; les interruptions seulement par
/// une porte d'interruption (0x0E), une porte de trappe (0x0F) les laisse.
const TRAP_FLAG = 0x100n;
const INTERRUPT_FLAG = 0x200n;
const NESTED_FLAG = 0x4000n;
const RESUME_FLAG = 0x10000n;
const PAGING_BIT = 1n << 31n;

export const SLOTS = {
  /// La case de RFLAGS. Elle ne servait à rien ici tant que personne ne lisait
  /// les drapeaux comme une **valeur** ; `pushf` les empile, donc elle sert.
  rflags: 16,
  rip: 17,
  /// **Le compteur d'horodatage, que l'hôte fait avancer.**
  ///
  /// Le module l'incrémente à chaque `rdtsc`, ce qui suffit à ce qu'une boucle
  /// `while (rdtsc() - début < n)` se termine. Ça ne suffit pas à ce que le
  /// temps reflète le **travail** : sans l'hôte, `t0 = rdtsc() ; travail ;
  /// t1 = rdtsc()` rendrait toujours le même écart, et un noyau qui attend une
  /// durée attendrait pour toujours. Le cœur Swift l'a payé douze secondes de
  /// blocage — voir `Tests/WisqVMTests/X86GuestClockTests.swift`.
  tsc: 19,
  /// Le premier des six sélecteurs de segment — ES, CS, SS, DS, FS, GS, dans
  /// l'ordre de l'énumération du décodeur. Ils partent à zéro, ce qui veut dire
  /// « aucun chargeur n'est passé ici » et non « le segment nul est chargé ».
  segment: 20,
  segmentCount: 6,
  /// Les deux tables de descripteurs, en limite puis base : GDT, puis IDT.
  table: 26,
  tableCount: 4,
  /// Les deux bases que `wrmsr` sait poser en plus de celle de GS : FS, puis
  /// celle que `swapgs` échange avec GS.
  fsBase: 30,
  kernelGs: 31,
  /// Les cinq registres de contrôle que le décodeur lit : CR0, CR2, CR3, CR4,
  /// CR8. Écrire CR0 et CR3 est produit depuis que la traduction existe :
  /// CR0.PG allume la marche, CR3 en donne la racine, CR2 porte l'adresse
  /// fautive.
  control: 32,
  controlCount: 5,
  /// Les trois globales de travail de la traduction — l'adresse invitée, la
  /// valeur qu'une écriture attend de poser, la case du tampon — puis le
  /// témoin de faute.
  translate: 47,
  translateCount: 3,
  fault: 50,
  /// **Le témoin d'arrêt, et sa raison.** Zéro tant que la machine tourne ;
  /// sinon un nombre qui dit **pourquoi** — le module le pose et rend la main,
  /// plutôt que de faire refuser la région entière. Ce commentaire annonçait
  /// « c'est ici que la délivrance d'une interruption viendra effacer le
  /// `hlt` » : elle l'efface.
  stop: 51,
  /// **`IA32_EFER`**, le quatrième MSR que le module modélise. Un vrai noyau le
  /// lit, y pose SCE et NX, et le réécrit ; c'est sur ce `rdmsr` qu'Alpine
  /// s'arrêtait, faute qu'il existe.
  efer: 52,
  /// **Le registre de tâche** : le sélecteur que `ltr` a chargé, seize bits,
  /// zéro tant qu'aucun chargeur n'est passé.
  ///
  /// **La délivrance lit le descripteur derrière**, dans la GDT, depuis #257 :
  /// c'est là que vivent `RSP0` et les piles d'interruption, donc c'est ce qui
  /// permet à une faute prise en anneau trois d'atterrir sur la pile du noyau.
  /// Ce commentaire disait le contraire — « aucun descripteur n'est lu
  /// derrière » — et il l'a dit assez longtemps pour passer pour une garantie
  /// alors que ce n'était qu'une limite de #204.
  ///
  /// **Seize bits, et rien de plus : l'infidélité est ici.** Le silicium lit le
  /// descripteur une fois, à l'instant du `ltr`, et garde base et limite dans
  /// une partie invisible du registre ; nous le relisons à chaque délivrance.
  /// Un noyau qui réécrirait le descripteur sans refaire son `ltr` verrait
  /// donc la nouvelle valeur au lieu de l'ancienne. Linux ne le fait pas — il
  /// modifie `RSP0` *dans* le TSS, ce qui est exactement ce que cette relecture
  /// rend visible. Garder base et limite ici coûterait deux globales de plus,
  /// et #204 a compté ce que coûte une globale : l'hôte, la garde,
  /// `WebKitBench.swift` et trois modules épinglés.
  task: 53,
  /// **Les quatre registres de l'appel système** : STAR, LSTAR, CSTAR,
  /// SYSCALL_MASK, dans l'ordre de leurs numéros. Rangés par `wrmsr`, rendus
  /// par `rdmsr`, et **lus par `syscall` depuis #259** — trois des quatre :
  /// les deux sélecteurs de STAR, la cible de LSTAR, le masque. CSTAR reste
  /// rangé sans être lu, ce cœur ne faisant pas tourner le mode
  /// compatibilité. C'est le module qui les lit, pas l'hôte : l'appel système
  /// ne repasse pas par ici.
  syscall: 54,
  syscallCount: 4,
  /// **Le mot de contrôle du coprocesseur**, et son mot d'état juste après.
  /// `fninit` y pose 0x037F et zéro ; rien d'autre ne les touche encore, aucune
  /// instruction de calcul x87 n'étant produite.
  fpuControl: 58,
  fpuStatus: 59,
  /// **Le mot de contrôle avant que `fninit` passe**, qui n'est pas celui
  /// qu'elle pose : le silicium sort de RESET avec 0x0040. Un noyau lit
  /// rarement le mot sans l'avoir initialisé, donc laisser zéro ici ne se
  /// verrait pas — c'est exactement pour ça que ça se pose.
  fpuControlPowerOn: 0x40,
  /// **Les seize registres XMM**, deux globales chacun — la moitié basse, puis
  /// la haute —, puis **MXCSR**. Le module les lit et les écrit ; l'hôte les
  /// crée, pose MXCSR à sa valeur d'allumage, et ne les touche plus : la
  /// délivrance d'une faute ne sauve aucun registre vectoriel, le silicium
  /// non plus — c'est le noyau qui les range, par `fxsave`.
  xmm: 60,
  xmmCount: 16,
  mxcsr: 92,
  /// Toutes les exceptions masquées, arrondi au plus proche : `MXCSR_RESET`.
  mxcsrReset: 0x1f80,
  globalCount: 93,
  tablePages: 16,
  tableEntry: 16,
  tableSlots: 1 << 16,
  /// **Combien de cases un seau porte.** Une seule case par empreinte faisait
  /// que la seconde adresse installée écrasait la première, qui repassait
  /// ensuite par l'hôte à chaque appel. Deux voies adjacentes par seau, donc :
  /// autant de cases qu'avant, mais une collision ne coûte plus une éviction.
  /// Le pendant exact de `TABLE_WAYS` côté Rust, et un test les compare.
  tableWays: 2,
  /// **Où le contexte de la région est rangé dans une case** — après
  /// l'adresse et l'indice —, et **le bit qui dit qu'une case est prise**.
  /// Les pendants de `TABLE_CONTEXT` et `CONTEXT_PRESENT` côté Rust, et un
  /// test les compare. Voir `contexte` plus bas, et `context_tag` là-bas.
  tableContext: 12,
  contextPresent: 4,
  /// **Le tampon de traduction**, juste au-dessus de la correspondance, donc
  /// encore plus haut que la RAM. Le module le déclare dans son minimum : un
  /// hôte qui ne le pose pas ne démarre pas, au lieu de piéger au premier
  /// défaut de tampon — et un piège WebAssembly est sans retour.
  tlbPages: 1,
  tlbEntry: 16,
  tlbSlots: 4096,
  /// **Combien de numéros de ligne le journal du code traduit tient** — voir
  /// `codePages` et `voirEcritures`. Le pendant de `CODE_LOG_SLOTS` côté
  /// Rust, et un test les compare.
  codeLogSlots: 16383,
  /// **Ce que l'hôte dit à la marche du module qu'il vient faire** — son
  /// second argument, `WALK_MACHINE` et `WALK_FETCH` côté Rust. Le processeur
  /// qui lit une porte, un descripteur ou pose un cadre n'est jugé sur aucun
  /// droit ; un chargement d'instruction veut le bit utilisateur en anneau
  /// trois. Un nombre faux ici ouvrirait le noyau aux programmes, ou ferait
  /// fauter la délivrance d'une faute.
  walkMachine: 0,
  walkFetch: 3,
  mix: 0x9e3779b97f4a7c15n,
};

/// **Combien de pages de 64 Kio allouer pour un module confiné** : la RAM de
/// l'invité, la correspondance, et le tampon de traduction. Le pendant exact de
/// `host_pages` côté Rust, et la seule addition de ce fichier. La carte des
/// pages de code et son journal sont le troisième morceau au-dessus.
///
/// **Pourquoi une fonction pour une addition.** La somme a changé deux fois —
/// la correspondance, puis le tampon — et à chaque fois il a fallu retrouver
/// tous les hôtes qui l'écrivaient à la main. `examples/resolved.rs` a été
/// manqué la seconde fois : il ne s'instanciait plus, imprimait sa panne et
/// sortait avec zéro. Un test refuse maintenant l'addition sur place, ici
/// comme là-bas.
export function hostPages(pages) {
  return pages + SLOTS.tablePages + SLOTS.tlbPages + codePages(pages);
}

/// **Ce que la carte du code traduit et son journal occupent**, au-dessus du
/// tampon : une page de journal — un compte, puis des numéros de ligne —, et
/// la carte, un bit par ligne de soixante-quatre octets de RAM, huit octets
/// par trame. Le pendant exact de `code_pages` côté Rust :
/// `the_view_and_the_emitter_count_the_same_code_pages` (tests/host_loop.rs)
/// les compare, et `hostPages` avec `host_pages`, de part et d'autre de chaque
/// marche de 512 pages.
export function codePages(pages) {
  return 1 + Math.max(1, Math.ceil(pages / 512));
}

/// La case d'une adresse : le même calcul que `table_slot` côté Rust et que
/// celui gravé dans les octets du module. **Les trois doivent tomber d'accord**
/// ou rien n'est jamais trouvé — un défaut muet, qui ne coûte que de la
/// vitesse, et c'est pourquoi un test les compare.
export function tableSlot(address) {
  const bits = 31 - Math.clz32(SLOTS.tableSlots);
  return Number(BigInt.asUintN(64, address * SLOTS.mix) >> BigInt(64 - bits));
}

/// **Le seau d'une adresse** : sa case, dont on efface le bit de poids faible.
/// Les deux voies du seau sont les deux cases qui se suivent, si bien qu'une
/// adresse ne déborde jamais de la table — ce qu'un sondage circulaire ferait
/// au dernier seau, en lisant le tampon de traduction. Le même calcul est gravé
/// dans les octets du module, et un test les compare.
export function tableBucket(address) {
  return tableSlot(address) & ~(SLOTS.tableWays - 1);
}

/// **Ce que le cache de code garde au plus, par défaut** : un nombre de
/// régions et un nombre d'octets de modules compilés. La première borne qui
/// serait franchie fait évincer la région la moins récemment servie.
///
/// **Les deux, et pas l'une ou l'autre.** Le nombre seul laisserait passer
/// des régions de cinquante kibioctets — il y en a, à l'entrée du noyau —, et
/// les octets seuls laisseraient s'accumuler des milliers de petites régions,
/// chacune avec son objet module, son instance et sa fenêtre gardée.
///
/// **Les chiffres sont mesurés** (JOURNAL, 15 novembre 2026, sous le
/// JavaScriptCore de Bun) : un module coûte au moteur **4,4 octets de mémoire
/// résidente par octet de wasm** — le code machine, l'instance —, et une région
/// d'Alpine pèse en moyenne quatorze kibioctets de wasm. Soixante-quatre
/// mébioctets de modules, c'est donc près de trois cents mébioctets de code
/// compilé, à côté de la RAM de l'invité : Alpine jusqu'à son shell de secours
/// et dix commandes y tient en 794 Mio résidents au plus (256 Mio de RAM
/// invitée), contre 1 240 Mio à quatre-vingt-seize mébioctets de modules. Le
/// prix est la retraduction : 47 % des traductions refont une région évincée,
/// contre 34 %. Seize mille régions ne se franchissent qu'avec de toutes
/// petites régions ; c'est la borne du nombre d'objets, pas du poids.
///
/// **Et un haut de table** (`emplacements`), qui n'est pas une borne de la même
/// sorte : tant que le haut de la table des blocs reste sous lui, une région
/// neuve se pose au haut, où tout tient ; au-delà, elle essaie la plus grande
/// des places rendues. Une case de la table est un pointeur : un million de
/// cases, huit mébioctets.
///
/// **Et `oubliees`**, qui ne borne pas le cache mais ce qu'il retient de ce
/// qu'il a jeté : le nombre de clés évincées gardées pour compter les
/// retraductions. Passé ce nombre, l'ensemble repart vide, et le compte des
/// retraductions devient un plancher. Réglable pour qu'un test puisse voir la
/// borne tenir sans évincer un quart de million de régions.
export const CACHE_PAR_DEFAUT = Object.freeze({
  regions: 16384,
  octets: 64 << 20,
  emplacements: 1 << 20,
  oubliees: 1 << 18,
});

/// **Où un module pose ses blocs dans la table, et combien** : l'offset et la
/// longueur de son unique segment d'éléments actif, lus dans ses octets
/// **avant** l'instanciation. `null` pour un module qui n'en a pas.
///
/// **Pourquoi avant.** C'est l'instanciation qui écrit les blocs dans la
/// table commune, à l'emplacement gravé dans le module. Tant que les régions
/// se posaient toujours en queue, il suffisait de lire la table après coup.
/// Depuis que le cache évince et réemploie les places rendues, une région
/// plus longue que le trou où on l'a posée écraserait **en silence** les blocs
/// de sa voisine — qui sauterait ensuite dans le code d'une autre. Il faut
/// donc le savoir avant, et l'émetteur ne l'annonce que dans ses octets.
export function blocsDuModule(bytes) {
  let at = 8;
  const leb = () => {
    let value = 0;
    let shift = 0;
    for (;;) {
      const byte = bytes[at++];
      value += (byte & 0x7f) * 2 ** shift;
      shift += 7;
      if ((byte & 0x80) === 0) return value;
    }
  };
  const signedLeb = () => {
    let value = 0;
    let shift = 0;
    let byte;
    do {
      byte = bytes[at++];
      value += (byte & 0x7f) * 2 ** shift;
      shift += 7;
    } while ((byte & 0x80) !== 0);
    if ((byte & 0x40) !== 0) value -= 2 ** shift;
    return value;
  };
  while (at < bytes.length) {
    const id = bytes[at++];
    const size = leb();
    const end = at + size;
    if (id === 9) {
      const segments = leb();
      // **Une seule forme est lue, celle que l'émetteur écrit** : un segment
      // actif sur la table zéro (drapeau zéro), d'offset `i32.const`. Toute
      // autre forme est refusée plutôt que devinée.
      if (segments !== 1 || bytes[at++] !== 0x00 || bytes[at++] !== 0x41) {
        throw new Error("un segment d'éléments que l'hôte ne sait pas lire");
      }
      const offset = signedLeb();
      if (bytes[at++] !== 0x0b) throw new Error("un offset d'éléments mal terminé");
      return { offset, count: leb() };
    }
    at = end;
  }
  return null;
}

/// **Construire la machine.**
///
/// - `translate(address, slot, code)` rend les octets d'un module pour la
///   région qui commence là, `null` si l'émetteur refuse franchement, ou
///   `"encore"` s'il a manqué d'octets. Elle peut rendre une promesse.
///
///   **`code` est la fenêtre, lue ici et envoyée avec la demande**, et c'est
///   le point le plus important de tout ce fichier. La RAM de l'invité vit
///   dans cette vue ; l'application ne l'a pas. Une demande qui ne porterait
///   que l'adresse obligerait l'application à chercher les octets dans l'image
///   qu'elle a chargée — ce qui marche pour le noyau et **ment en silence**
///   dès que l'invité écrit son propre code, un module chargé par exemple.
///   Elle traduirait alors les mauvais octets, ce qui compile en un module
///   valide qui saute n'importe où.
///
///   **L'emplacement fait partie de la demande**, et ce n'est pas un détail :
///   les blocs d'une région se posent dans la table commune à partir de là, et
///   c'est la vue qui sait où il reste de la place. Une région compilée pour
///   un autre emplacement écraserait les blocs de sa voisine, en silence.
/// - `screen`, s'il est donné, décrit le tampon d'affichage que le chargeur a
///   déclaré au noyau : `{ base, width, height }`. Il doit tenir **entièrement
///   dans la RAM de l'invité** — la correspondance vit juste au-dessus, et un
///   cadre qui déborderait dessus peindrait la table des blocs à l'écran tout
///   en la détruisant.
/// - `pages` est la RAM de l'invité, **en pages de 64 Kio et en puissance de
///   deux** : c'est ce qui permet de replier les adresses invitées et de poser
///   la correspondance au-dessus, hors de portée.
/// - `patience` est le temps, en millisecondes, au-delà duquel une traduction
///   sans réponse est traitée comme une panne. Zéro attend indéfiniment.
///
///   **Pourquoi il en faut une.** `translate` rend une promesse, et rien ne
///   garantit qu'elle soit tenue : l'hôte peut être occupé, avoir planté, ou
///   avoir perdu le message. Sans garde, `await` ne rend jamais la main et
///   l'écran reste tel quel **sans un mot** — le pire mode de panne pour
///   diagnostiquer. Trente secondes est long pour une traduction (elles se
///   comptent en microsecondes) et court pour un humain qui regarde un écran
///   figé.
/// Ce qu'une traduction rend quand elle ne rend rien : l'application n'a pas
/// répondu, ou elle a levé. Deux objets distincts plutôt qu'un `null` partagé
/// avec le refus franc de l'émetteur — les trois se corrigent ailleurs.
const MUTE = Object.freeze({ panne: "sans réponse" });
const BROKEN = Object.freeze({ panne: "en panne" });

/// **« Il m'en faut plus. »** Ni un module ni un refus : l'émetteur s'est
/// arrêté à moins de quinze octets du bord de la fenêtre, donc l'instruction
/// qui l'a bloqué a pu être **coupée** plutôt qu'être inconnue. Une troisième
/// réponse plutôt qu'un `null` déguisé, parce que « refusé » et « redemande »
/// ne se traitent pas pareil : l'un arrête la machine, l'autre coûte un
/// aller-retour.
///
/// Sur le vrai noyau Alpine, une petite minorité de régions tombait là avec
/// une fenêtre de 4 Kio, et **toutes** se traduisaient au second essai. Le
/// compte exact, sa date et ce qu'il vaut aujourd'hui vivent dans la doc de
/// `Module::resolving_or_why` : il était recopié ici avec un chiffre qui ne
/// s'accordait pas avec l'autre copie.
///
/// **Et depuis l'arrêt nommé, ce chemin s'est vidé.** Une instruction coupée
/// par le bord ne fait plus refuser la région : elle rend la main là où le
/// décodeur s'arrête. Le second essai ne sert plus qu'à une fenêtre dont la
/// **première** instruction est coupée.
const MORE = Object.freeze({ manque: "des octets" });

/// **« Il n'y a aucune page derrière cette adresse. »** L'espace d'adressage
/// que la machine porte ne cartographie rien là — la marche s'arrête sur une
/// entrée absente, à n'importe lequel des quatre niveaux.
///
/// **Pourquoi ce n'est pas un refus de l'émetteur, et pourquoi ça ne peut pas
/// être un `null` de plus.** « Refusée » dit que l'émetteur n'a pas su lire un
/// octet ; ici il n'y a pas d'octet du tout. Les deux se corrigent à des
/// kilomètres l'un de l'autre : l'un dans le décodeur, l'autre dans ce que
/// l'invité a fait de ses tables.
///
/// **Et surtout, ça remplace une complaisance.** L'hôte allait chercher les
/// octets à `adresse & (RAM - 1)`, ce qui rend **toujours** quelque chose,
/// parce que toute la RAM est lisible. Au saut dans `/init` du vrai noyau
/// d'Alpine, ce repli désignait 4096 octets **tous nuls** : l'émetteur aurait
/// traduit autant de `add %al,(%rax)`, et la machine serait partie en morceaux
/// très loin de la cause.
const UNMAPPED = Object.freeze({ absent: "aucune page" });

/// **Attendre une traduction, mais pas éternellement.**
///
/// Le réveil est **désarmé** dès que la réponse arrive : une machine qui
/// traduit des milliers de régions laisserait sinon des milliers de minuteries
/// derrière elle. Et une réponse qui arrive *après* la patience ne compte pas
/// — la machine a déjà rendu la main, y revenir la ferait repartir d'un état
/// qu'elle a quitté.
async function answered(ask, patience) {
  let attempt;
  try {
    attempt = Promise.resolve(ask());
  } catch (why) {
    return BROKEN;
  }
  const settled = attempt.then(
    bytes => (bytes === "encore" ? MORE : bytes),
    () => BROKEN,
  );
  if (!(patience > 0)) return settled;
  let alarm;
  const waited = new Promise(settle => {
    alarm = setTimeout(() => settle(MUTE), patience);
  });
  return Promise.race([settled, waited]).then(outcome => {
    clearTimeout(alarm);
    return outcome;
  });
}

/// **Le port série : le 16550 tel que le pilote 8250 le sonde.**
///
/// C'est par là qu'un noyau Linux parle avant d'avoir le moindre pilote : le
/// tout premier `printk` sort en `0x3f8`, un octet à la fois.
///
/// **Ce bloc disait « rien d'autre du composant n'est implémenté, et c'est
/// délibéré ».** Deux registres suffisaient en effet à `printk`, qui prend le
/// port directement : l'émission en `0x3f8`, et l'état de ligne en `0x3fd` où
/// le noyau tourne en boucle jusqu'à voir « l'émetteur est libre » — un zéro
/// rendu là ne perdrait pas un octet, il pendrait la machine pour toujours sur
/// une boucle correcte.
///
/// **Ce n'était pas vrai du tty.** Un `write` de l'espace utilisateur passe par
/// le pilote complet, et le pilote ne croit à un port que s'il le trouve :
/// quatre questions, et une seule sans réponse lui suffit pour conclure « there
/// is nothing here ». #304 a mesuré le bout de cette chaîne — l'espace
/// utilisateur s'exécute, son premier `write` rend −EIO — et a conclu qu'il
/// restait une direction à trancher. **La direction était tranchée** :
/// `Sources/WisqVM/X86SerialPort.swift` modélise la puce entière, onze tests
/// Swift la tiennent, et son propre commentaire raconte la même mesure. Ce qui
/// restait était la troisième forme de #289 — deux copies qui s'accordent, une
/// qui dérive — et la copie qui dérivait était celle que l'application embarque.
///
/// Les huit registres, aux décalages de `0x3f8` :
///
/// | | en écriture | en lecture |
/// | --- | --- | --- |
/// | 0 | l'émission, ou l'octet bas du diviseur derrière `DLAB` | la réception, ou le même octet |
/// | 1 | l'autorisation d'interruption, ou l'octet haut du diviseur | la même chose |
/// | 2 | le contrôle de la FIFO | l'identification de la cause |
/// | 3 | le format, dont `DLAB` au bit sept | la même chose |
/// | 4 | le contrôle du modem, dont la boucle au bit quatre | la même chose |
/// | 5 | — | l'état de la ligne |
/// | 6 | — | l'état du modem |
/// | 7 | le brouillon | le brouillon |
const SERIAL = 0x3f8;
/// **Le dernier des huit.** Tout l'intervalle appartient à la puce : un port de
/// l'intervalle qui tomberait dans le vide se lirait `0xff`, « il n'y a
/// personne », et ferait échouer la sonde sur la seule question qui
/// manquerait.
const SERIAL_LAST = SERIAL + 7;
/// Émetteur vide **et** registre d'émission vide : les deux bits que la boucle
/// d'attente d'un noyau consulte. Le bit zéro, « un octet attend d'être lu »,
/// s'y ajoute quand il y en a un.
const TRANSMITTER_IDLE = 0x60;
/// **Ce que rend un port où il n'y a personne.** Un vrai PC laisse le bus
/// flotter, et le lecteur voit tous les bits à un. Rendre zéro ferait croire à
/// un périphérique présent et muet, ce qui est la pire des deux réponses : un
/// noyau qui sonde `0xff` passe son chemin, un noyau qui sonde `0x00` s'installe.
const NOBODY_THERE = 0xff;

/// **Les deux 8259, et le strict nécessaire pour qu'un noyau les trouve.**
///
/// Un PC en porte deux, en cascade : le maître sur `0x20`/`0x21`, l'esclave sur
/// `0xa0`/`0xa1`. Le port pair est la commande, l'impair les données.
///
/// **Pourquoi ils existent ici.** Le noyau d'Alpine imprimait « Using NULL
/// legacy PIC », et la raison tient en cinq instructions de `probe_8259A` : il
/// écrit un masque sur `0x21` et le relit. Un port sans personne rend `0xff` —
/// le bus qui flotte, la bonne réponse quand il n'y a personne — donc la
/// relecture ne pouvait jamais correspondre, et le noyau concluait, avec
/// raison, qu'aucun contrôleur n'est là. Sans contrôleur, pas de routage
/// d'IRQ0 ; sans IRQ0, pas d'horloge ; sans horloge, `calibrate_delay` tourne
/// sur lui-même. Tout ce mur tenait à huit bits qui se relisent.
///
/// **Ce qui est modélisé depuis que des lignes montent** : le registre de
/// requête, celui de service, la priorité par ordre de bit, la fin
/// d'interruption spécifique et non spécifique, la cascade sur la ligne deux,
/// et le choix par OCW3 du registre que le port de commande rend. Ce
/// paragraphe annonçait « la tranche de la délivrance qui les écrira, avec le
/// test qui les exige » ; cinq tests les exigent.
///
/// **Ce qui ne l'est toujours pas, et c'est nommé** : la rotation des
/// priorités, que Linux ne demande jamais ; le mode de masquage spécial ; et
/// la lecture du registre de masquage par polling. Un noyau qui les
/// emploierait serait servi faux, pas refusé — c'est la limite à lever le jour
/// où elle se verra.
///
/// **Une infidélité assumée, et nommée** : un vrai 8259 efface son masque en
/// recevant ICW1. Celui-ci ne le fait pas. Aucun invité ne peut le voir — Linux
/// écrit `0xff` juste avant l'initialisation et repose son masque juste après —
/// mais l'écrire ici vaut mieux que de laisser croire que la question ne s'est
/// pas posée.
/// **Le 8254, et l'horloge contre laquelle il compte.**
///
/// `quick_pit_calibrate` — lu à `0xffffffff81056382` — ne demande pas l'heure :
/// il compte combien de fois son propre `rdtsc` avance pendant que le compteur
/// du 8254 perd un octet de poids fort, et il en **déduit** la fréquence du
/// compteur d'horodatage. Les deux horloges n'ont donc pas à être justes, elles
/// doivent être **d'accord entre elles** : c'est leur rapport, et lui seul, qui
/// décide de ce que le noyau annoncera.
///
/// Le quartz du PC d'origine, celui que Linux a en dur.
const PIT_HZ = 1193182n;
/// **La fréquence nominale du compteur d'horodatage.** Elle était arbitraire et
/// sans conséquence tant que rien ne s'y comparait — `TSC_STEP` côté émetteur
/// dit d'ailleurs que « seule sa positivité stricte est une propriété ». Elle
/// cesse de l'être ici : c'est ce gigahertz que le noyau mesurera et
/// imprimera. Le choisir rond vaut mieux que le laisser tomber d'un calcul.
const TSC_HZ = 1_000_000_000n;
/// Les ports du 8254 : trois compteurs et un mot de commande.
const PIT_CHANNEL = 0x40;
const PIT_COMMAND = 0x43;
/// **Le port B du contrôleur système**, où vit le portillon du canal deux —
/// celui que l'étalonnage ouvre avant de compter. Bit 0 le portillon, bit 1 le
/// haut-parleur, bit 5 la sortie du canal deux, en lecture seule.
const PIT_GATE = 0x61;
const PIT_GATE_OPEN = 0x01;
const PIT_OUT_TWO = 0x20;

/// Un compteur au repos.
///
/// **Le temps consommé est gardé, pas déduit d'une date de chargement.** Un
/// portillon qui se ferme puis se rouvre doit reprendre là où il en était, et
/// l'écrire ainsi évite l'arithmétique inverse — celle qui retrouverait une
/// date à partir d'un compte — qui n'aurait été juste que par accident.
function counter() {
  return {
    /// Le mode du 8254. Ce noyau en programme trois : le zéro pour
    /// l'étalonnage, le deux pour sa cadence périodique, et le quatre pour
    /// ses échéances une fois l'horloge passée en coup unique.
    mode: 0,
    /// Comment les octets se lisent et s'écrivent : 1 le bas seul, 2 le haut
    /// seul, 3 le bas puis le haut.
    access: 3,
    /// Le diviseur chargé. Zéro vaut soixante-cinq mille cinq cent trente-six,
    /// comme sur la puce.
    reload: 0,
    /// Les pas déjà comptés avant la dernière ouverture du portillon.
    consumed: 0n,
    /// L'horloge de l'invité à cette ouverture.
    openedAt: 0n,
    /// Le portillon. Ceux des canaux zéro et un sont câblés en l'air sur un PC.
    open: true,
    /// L'octet bas déjà écrit, en attente du haut.
    low: 0,
    /// La prochaine lecture rendra-t-elle l'octet haut ?
    readHigh: false,
    /// La prochaine écriture porte-t-elle l'octet haut du diviseur ?
    ///
    /// **Séparé de la lecture, et ce n'est pas une précaution en l'air** : la
    /// puce se souvient des deux indépendamment, et les confondre suffirait à
    /// ce qu'une lecture glissée entre les deux écritures d'un diviseur décale
    /// les octets. Le noyau intercale un délai entre ses deux `out`.
    writeHigh: false,
    /// Le compte figé par une commande de verrou, ou `null`.
    latched: null,
    /// **Combien de tours de roue ont déjà fait monter une ligne.**
    ///
    /// Un seul bit de requête existe dans le 8259 : deux tours passés
    /// pendant qu'une interruption était masquée ou en service n'en font pas
    /// deux, ils en font une. C'est ce que fait la puce, et la garder ici
    /// évite l'arithmétique inverse — compter les tours manqués pour les
    /// rejouer — qui inventerait des interruptions que le silicium perd.
    raised: 0n,
    /// **Un compteur que personne n'a programmé n'a pas de période.** Sans ce
    /// témoin, le mode zéro d'un compteur neuf — `mode: 0`, diviseur nul,
    /// donc soixante-cinq mille cinq cent trente-six — ferait monter IRQ0 tout
    /// seul dès que l'horloge aurait assez avancé, avant qu'aucun noyau
    /// n'ait parlé à la puce.
    loaded: false,
  };
}

const PIC_MASTER = 0x20;
const PIC_SLAVE = 0xa0;
/// Le bit qui, sur le port de commande, dit « ce qui suit est une
/// initialisation » : les trois ou quatre octets d'après ne sont plus un
/// masque mais ICW2, ICW3 et ICW4.
const PIC_INIT = 0x10;
/// Et le bit d'ICW1 qui annonce un quatrième mot.
const PIC_WANTS_ICW4 = 0x01;
/// **Les deux autres mots du port de commande**, distingués par les bits 3 et
/// 4 : OCW2 les a tous les deux à zéro, OCW3 porte le bit 3, ICW1 le bit 4.
const PIC_WORD = 0x18;
const PIC_IS_OCW3 = 0x08;
/// **OCW2 : la fin d'interruption.** Le bit 5 dit « acquitte », le bit 6 dit
/// « celle que je nomme » plutôt que « la plus prioritaire en service ».
///
/// **La rotation des priorités n'est pas modélisée**, et c'est nommé plutôt
/// que tu : les bits 7 d'OCW2 la demandent, Linux ne la demande jamais — il
/// envoie `0x20` sur le maître, et `0x20` sur les deux pour une ligne de
/// l'esclave. Un noyau qui la demanderait serait acquitté sans être tourné.
const PIC_EOI = 0x20;
const PIC_SPECIFIC = 0x40;
/// **OCW3 : lequel des deux registres le port de commande rendra.** `0x0a`
/// pour la requête, `0x0b` pour le service. Linux s'en sert dans sa détection
/// d'interruption fantôme, et lire le mauvais registre lui ferait prendre une
/// vraie interruption pour une fantôme.
const PIC_READ_SERVICE = 0x01;
/// **Le numéro de la ligne où l'esclave est câblé sur le maître.** Deux sur un
/// PC, et ICW3 le dit ; nous le tenons pour acquis plutôt que de lire ICW3,
/// parce qu'aucune machine d'ici n'en câble une autre — et c'est écrit là où
/// ICW3 est reçu.
const PIC_CASCADE = 2;

/// Un contrôleur au repos : tout masqué, aucune base, aucune initialisation en
/// cours. C'est l'état d'un 8259 avant qu'un noyau ne lui parle.
function controller() {
  return {
    /// **Le registre de masque**, celui que la sonde du noyau écrit et relit.
    mask: 0xff,
    /// **La base de vecteur**, posée par ICW2. Ce noyau y met `0x30` pour le
    /// maître et `0x38` pour l'esclave — **pas** `0x20`, la valeur du PC
    /// d'origine que tous les manuels donnent. Lue dans son `init_8259A`
    /// plutôt que supposée : la supposer aurait fait délivrer IRQ0 dans la
    /// mauvaise porte de l'IDT, très loin d'ici.
    base: 0,
    /// Le prochain mot d'initialisation attendu sur le port de données, ou
    /// zéro quand il n'y a pas d'initialisation en cours.
    expects: 0,
    /// ICW1 a-t-il annoncé un ICW4 ?
    wantsFour: false,
    /// **Le registre de requête**, un bit par ligne qui a monté et qui attend.
    /// Une ligne y entre quand un périphérique la lève et en sort quand la
    /// délivrance la prend.
    request: 0,
    /// **Le registre de service**, un bit par ligne délivrée et pas encore
    /// acquittée. C'est lui qui rend un 8259 *imbriqué* : tant qu'une ligne y
    /// est, aucune ligne de priorité inférieure ou égale ne peut être
    /// délivrée. Sans lui, un gestionnaire serait réinterrompu par la même
    /// ligne à son premier `sti`, indéfiniment.
    service: 0,
    /// Lequel des deux le port de commande rend, posé par OCW3. La puce sort
    /// de RESET sur le registre de requête.
    reads: "request",
  };
}

export function machine({
  translate,
  pages,
  screen,
  serial,
  // **La taille de départ de la table des blocs**, pas sa taille : elle
  // grandit devant chaque région qui en a besoin (voir `install`).
  regions = 4096,
  patience = 30000,
  // **Compter les régions qui tournent après que leurs octets ont bougé**, ou
  // non. Éteint, la boucle n'y paie qu'un test de booléen ; allumé, une
  // lecture d'un octet par entrée de région. Voir `surveillees`.
  surveiller = false,
  // **Les bornes du cache de code** : `{ regions, octets, emplacements }`,
  // toutes ou certaines. Ce qui manque prend `CACHE_PAR_DEFAUT`.
  cache = {},
  // **Ce qui collecte, quand un quart de la borne en octets a été évincé** :
  // une fonction, appelée avant la pause de huit millisecondes de
  // `respirerSiBesoin`. Aucune par défaut — une page n'a pas de quoi forcer
  // une collecte ; un pilote sous Bun passe `() => Bun.gc(true)`, ce que fait
  // le gestionnaire de pression mémoire de WebKit sur un appareil.
  ramasser = null,
  // **Vider le cache au premier passage en anneau trois**, ou non. C'était le
  // seul garde-fou contre le texte que le noyau réécrit en démarrant ; les
  // écritures dans les pages de code sont maintenant vues une à une (voir
  // `voirEcritures`), et le vidage reste, allumé par défaut, pour ce que rien
  // ne voit : ce qu'on écrit dans la mémoire **du dehors**, sans passer par
  // `ecrit`. Éteint, la mesure dit ce que la carte tient seule.
  vider = true,
  // **La carte des périphériques** (`web/carte.js`) : l'i8042, l'horloge
  // CMOS, le bus PCI et le disque virtio, tout ce que les puces d'ici ne
  // modélisent pas. Une fonction, `(ram) => carte`, appelée une fois la RAM
  // de l'invité créée : la carte ne peut pas être fabriquée avant, et ce
  // fichier ne peut pas l'importer (la page l'embarque tel quel dans un
  // script, sans le fichier d'à côté). `ram` est la vue de la RAM que la
  // carte doit prendre — `{ lire, ecrire }` par adresse physique —, et ses
  // écritures passent par `ecrit` : ce que le disque dépose par DMA dans une
  // page où du code a été traduit oublie ces traductions. Aucune par défaut :
  // la machine d'avant, ses quatre puces et rien d'autre.
  carte: brancherLaCarte = null,
}) {
  if (!Number.isInteger(pages) || pages <= 0 || (pages & (pages - 1)) !== 0) {
    throw new Error(`la RAM doit être une puissance de deux, pas ${pages}`);
  }
  const memory = new WebAssembly.Memory({ initial: hostPages(pages) });
  // **La carte, branchée sur la RAM de l'invité et rien d'autre.** Les
  // adresses physiques sont les adresses linéaires de `memory`, de zéro à la
  // fin de la RAM : la correspondance et la carte du code, au-dessus, ne sont
  // pas à elle. Une plage qui déborde est refusée entière, sans rien toucher.
  //
  // **L'écriture se dit à `ecrit`**, déclarée plus bas : la carte n'écrit
  // qu'en servant un port ou une réponse du disque, jamais en se fabriquant,
  // donc toujours après que tout ce fichier a été lu.
  const octetsDeRam = pages * 65536;
  const dansLaRam = (adresse, longueur) =>
    Number.isInteger(adresse) && adresse >= 0 && adresse + longueur <= octetsDeRam;
  const ramDeLaCarte = {
    lire(adresse, vers) {
      if (!dansLaRam(adresse, vers.length)) return false;
      vers.set(new Uint8Array(memory.buffer, adresse, vers.length));
      return true;
    },
    ecrire(adresse, depuis) {
      if (!dansLaRam(adresse, depuis.length)) return false;
      new Uint8Array(memory.buffer, adresse, depuis.length).set(depuis);
      ecrit(adresse, depuis.length);
      return true;
    },
  };
  const peripheriques = brancherLaCarte === null ? null : brancherLaCarte(ramDeLaCarte);
  const blocks =new WebAssembly.Table({ element: "anyfunc", initial: regions });
  const globals = [];
  const env = { mem: memory, blocks };
  for (let slot = 0; slot < SLOTS.globalCount; slot++) {
    globals.push(new WebAssembly.Global({ value: "i64", mutable: true }, 0n));
    env["g" + slot] = globals[slot];
  }
  // **Le bit 1 de RFLAGS vaut toujours un sur x86.** Ce n'est pas un drapeau,
  // c'est une constante de l'architecture : l'interpréteur Rust le pose
  // (`Flags::read` rend `… | ALWAYS_ONE`) et l'oracle matériel le porte.
  //
  // Ici, tout partait de zéro. Tant que rien ne lisait RFLAGS comme une
  // valeur, la divergence ne se voyait pas ; le premier `pushf` aurait empilé
  // un RFLAGS qu'aucun processeur ne produit — le genre d'écart qu'un invité
  // ne remarque pas tout de suite et qui rend une trace incomparable à une
  // vraie.
  globals[SLOTS.rflags].value = 0x2n;
  // **EFER part en long mode, et ce n'est pas une commodité.** LME (bit 8) et
  // LMA (bit 10) : le mode 64 bits est demandé et actif, ce qui est vrai de
  // cette machine — elle n'exécute rien d'autre. Le noyau ne lit pas EFER par
  // curiosité : il le lit, y ajoute ses bits et le réécrit. Partir de zéro lui
  // ferait ranger un EFER qui prétend que la machine n'est pas en 64 bits, et
  // c'est ce registre-là qu'il relira pour décider s'il peut poser NX dans ses
  // tables de pages.
  globals[SLOTS.efer].value = 0x500n;
  globals[SLOTS.fpuControl].value = BigInt(SLOTS.fpuControlPowerOn);
  // **MXCSR part à sa valeur d'allumage**, pas à zéro : zéro démasquerait
  // toutes les exceptions flottantes, ce qu'aucun processeur ne fait au
  // démarrage, et `fxsave` la rangerait telle quelle dans l'aire du noyau.
  globals[SLOTS.mxcsr].value = BigInt(SLOTS.mxcsrReset);
  // **Les deux fonctions par lesquelles l'invité touche le monde.**
  //
  // Elles sont *importées* plutôt qu'atteintes en sortant de la région : un
  // retour de main coûte environ 190 ns, mesuré, et une console écrit
  // caractère par caractère. Un appel importé en coûte des dizaines. C'est le
  // choix de v86.
  //
  // Les trois arguments arrivent en `i64`, donc en `BigInt` : le port, la
  // valeur, et **la largeur en octets**. La largeur est passée plutôt que
  // devinée — deux octets dont le haut est nul ressemblent à un octet.
  /// Les trois compteurs du 8254, et le port qui porte le portillon du
  /// troisième. Exposés plus bas en lecture, comme les contrôleurs.
  const pits = [counter(), counter(), counter()];
  /// Ce que l'invité a écrit sur le port du portillon. Les bits hauts sont à
  /// lui ; le bit cinq, lui, vient de la puce et n'est pas rangé ici.
  let gatePort = 0;
  /// L'horloge de l'invité, celle que `rdtsc` avance et que la boucle hôte
  /// avance aussi. **Le 8254 compte contre elle et contre rien d'autre** :
  /// une seconde horloge divergerait, et l'étalonnage mesure justement leur
  /// rapport.
  const now = () => BigInt.asUintN(64, globals[SLOTS.tsc].value);
  /// Les pas du 8254 qu'un compteur a vus depuis son chargement.
  const stepsOf = (chip) =>
    chip.consumed + (chip.open ? ((now() - chip.openedAt) * PIT_HZ) / TSC_HZ : 0n);
  /// Ce qu'un compteur rendrait s'il était lu maintenant.
  ///
  /// **Le mode deux recharge, les autres bouclent.** Ce sont les deux seules
  /// formes que ce noyau programme, et les seules dont la descente est écrite :
  /// un mode qu'il ne demande pas serait deviné, pas modélisé.
  const countOf = (chip) => {
    const reload = chip.reload === 0 ? 0x10000 : chip.reload;
    const steps = stepsOf(chip);
    if (chip.mode === 2 || chip.mode === 6) {
      return reload - Number(steps % BigInt(reload));
    }
    return Number((BigInt(reload) - steps) & 0xffffn);
  };
  /// **Les deux coups uniques**, zéro et quatre : une seule ligne, au bout du
  /// compte, et plus rien jusqu'au prochain chargement.
  const oneShot = (mode) => mode === 0 || mode === 4;
  /// Les modes dont la descente est écrite ici.
  const counted = (mode) => oneShot(mode) || mode === 2 || mode === 6;
  /// Charger un diviseur : le compteur repart de son sommet, maintenant.
  const load = (chip, value) => {
    chip.reload = value & 0xffff;
    chip.consumed = 0n;
    chip.openedAt = now();
    chip.latched = null;
    chip.readHigh = false;
    // La roue repart de zéro avec le diviseur : les tours d'avant
    // appartenaient à une autre période.
    chip.raised = 0n;
    chip.loaded = true;
  };
  /// **La sortie du canal deux**, celle que le port du portillon rend au bit
  /// cinq. En mode zéro elle monte quand le compte atteint zéro, et c'est le
  /// seul mode dont ce noyau la consulte ; ailleurs elle est dite basse plutôt
  /// que devinée.
  const outTwo = () => {
    const chip = pits[2];
    if (chip.mode !== 0) return false;
    return stepsOf(chip) >= BigInt(chip.reload === 0 ? 0x10000 : chip.reload);
  };

  /// Les deux contrôleurs de cette machine. Exposés plus bas en lecture, pour
  /// que le relevé puisse dire ce qu'ils tiennent ; rien ne se décide dessus.
  const pics = { master: controller(), slave: controller() };
  // **Ce que l'hôte a délivré du dehors, et où l'invité était à la première.**
  //
  // Les interruptions synchrones se lisent dans le relevé : le module rend la
  // main, et l'arrêt porte leur nom. Celles du matériel s'injectent entre deux
  // instructions, sans que rien ne rende la main pour elles — donc sans que
  // rien ne les nomme. Sur le vrai noyau il a fallu les déduire d'une ligne de
  // traduction, `irq_entries_start + 256`, et vérifier à la main que ce
  // décalage est bien le stub du vecteur `0x30`. L'hôte le savait.
  //
  // **Les deux nombres sont comparés**, et pas seulement imprimés : `handled`,
  // que l'invité compte dans son gestionnaire, est le témoin d'en face de
  // `delivrees`.
  const materiel = { delivrees: 0n, premiere: null };
  /// **Les régions qui ont *tourné* après que leurs octets ont bougé.**
  ///
  /// #307 a mesuré que 1 397 régions sur 12 249 voient leur fenêtre changer
  /// après leur traduction, et n'a pas pu dire si l'une d'elles a tourné
  /// ensuite. C'est cette limite-là, écrite là-bas, que ceci lève — et c'est
  /// la seule qui sépare « un fil » de « la machine exécute du code faux ».
  ///
  /// **L'octet comparé est celui de l'entrée, et ce n'est pas un compromis** :
  /// entrer dans une région, c'est exécuter l'instruction qui y est. Si cet
  /// octet a changé, la toute première instruction exécutée diffère de celle
  /// qui a été traduite, sans qu'il faille savoir quels blocs la suite
  /// atteint. Comparer la fenêtre entière à chaque entrée coûterait quatre
  /// kibioctets sur le chemin le plus chaud du programme pour une réponse
  /// moins nette.
  ///
  /// **Et c'est un plancher, pas une estimation.** Une région dont le
  /// deuxième bloc a été patché tourne aussi du code périmé et n'est pas
  /// comptée ici. Le compte sous-déclare ; il ne lève jamais de fausse
  /// alerte.
  const surveillees = { entrees: 0n, regions: new Map() };
  /// **Le 16550, celui que le pilote sonde.**
  ///
  /// L'état est celui de `X86SerialPort.swift`, champ pour champ et nom pour
  /// nom : ce qui diverge entre deux cœurs se paie en #289, et un champ qui
  /// n'existe que d'un côté est déjà une divergence.
  const uart = {
    /// IER : réception (bit 0), émission (bit 1), état de ligne (2), modem (3).
    interruptEnable: 0,
    /// FCR : le bit 0 active la FIFO, et c'est lui que l'identification répète
    /// dans ses deux bits hauts — « 16550A ».
    fifoControl: 0,
    /// LCR : le bit 7 (`DLAB`) fait apparaître le diviseur à la place du
    /// tampon d'émission et de l'autorisation.
    lineControl: 0,
    /// MCR : le bit 4 met la puce en boucle sur elle-même.
    modemControl: 0,
    /// SCR : aucun rôle, sinon garder ce qu'on y met. C'est ce qui distingue un
    /// 16450 d'un 8250.
    scratch: 0,
    /// Le diviseur de bauds. Douze pour 115 200.
    divisor: 0,
    /// L'émission a quelque chose à dire : levée quand on l'autorise ou qu'un
    /// octet part — le transmetteur est vide aussitôt, ici —, acquittée par la
    /// lecture du registre d'identification.
    transmitPending: false,
    /// Ce qui est arrivé et que l'invité n'a pas encore lu.
    ///
    /// Deux choses la remplissent : la boucle de test du modem, où l'octet
    /// émis revient par la réception — c'est par elle que passe la deuxième
    /// question de la sonde —, et `send`, ce qu'on tape.
    input: [],
  };
  const dlab = () => (uart.lineControl & 0x80) !== 0;
  const loopback = () => (uart.modemControl & 0x10) !== 0;
  /// **La ligne quatre demande.** Réception avant émission, comme sur la puce.
  const serialInterrupting = () => {
    if ((uart.interruptEnable & 0x01) !== 0 && uart.input.length > 0) return true;
    return (uart.interruptEnable & 0x02) !== 0 && uart.transmitPending;
  };
  const serialWrite = (offset, octet) => {
    switch (offset) {
      case 0:
        if (dlab()) {
          uart.divisor = (uart.divisor & 0xff00) | octet;
          return;
        }
        // Un `out %ax, %dx` vers l'émetteur écrit deux caractères sur un vrai
        // 16550 seulement avec la FIFO ; ici l'octet bas suffit, et le dire est
        // plus honnête que de faire semblant.
        //
        // En boucle, l'octet revient par la réception au lieu de sortir : c'est
        // tout l'objet de la boucle, et un hôte qui le laisserait sortir
        // ferait apparaître la sonde du pilote dans la console.
        if (loopback()) uart.input.push(octet);
        else if (serial) serial(octet);
        uart.transmitPending = true;
        return;
      case 1: {
        if (dlab()) {
          uart.divisor = (uart.divisor & 0x00ff) | (octet << 8);
          return;
        }
        const was = uart.interruptEnable;
        uart.interruptEnable = octet & 0x0f;
        // Autoriser l'émission sur un transmetteur vide la lève : c'est le
        // test que `serial8250_do_startup` fait deux fois, et s'il ne revient
        // rien la seconde fois le pilote installe un minuteur de secours au
        // lieu de compter sur l'interruption.
        if ((octet & 0x02) !== 0 && (was & 0x02) === 0) uart.transmitPending = true;
        return;
      }
      case 2:
        uart.fifoControl = octet;
        return;
      case 3:
        uart.lineControl = octet;
        return;
      case 4:
        uart.modemControl = octet & 0x1f;
        return;
      case 7:
        uart.scratch = octet;
        return;
      default:
        // Cinq et six — l'état de la ligne, l'état du modem — sont en lecture
        // seule sur la puce. Les ranger ferait croire à un invité qu'il peut
        // se répondre à lui-même.
        return;
    }
  };
  const serialRead = (offset) => {
    switch (offset) {
      case 0:
        if (dlab()) return uart.divisor & 0xff;
        return uart.input.length === 0 ? 0 : uart.input.shift();
      case 1:
        if (dlab()) return (uart.divisor >> 8) & 0xff;
        return uart.interruptEnable;
      case 2: {
        // L'identification : la cause la plus prioritaire, bit 0 à zéro quand
        // il y en a une, et la FIFO dans les deux bits hauts.
        const fifo = (uart.fifoControl & 0x01) !== 0 ? 0xc0 : 0;
        if ((uart.interruptEnable & 0x01) !== 0 && uart.input.length > 0) return fifo | 0x04;
        if ((uart.interruptEnable & 0x02) !== 0 && uart.transmitPending) {
          uart.transmitPending = false;
          return fifo | 0x02;
        }
        return fifo | 0x01;
      }
      case 3:
        return uart.lineControl;
      case 4:
        return uart.modemControl;
      case 5:
        return TRANSMITTER_IDLE | (uart.input.length === 0 ? 0 : 1);
      case 6:
        // En boucle, les sorties reviennent sur les entrées : DTR → DSR,
        // RTS → CTS, OUT1 → RI, OUT2 → DCD. Le pilote écrit
        // `LOOP | OUT2 | RTS` et attend `DCD | CTS`. Sinon, un câble branché :
        // porteuse, prêt, libre d'émettre — un terminal ouvert sans `CLOCAL`
        // attendrait la porteuse indéfiniment.
        if (!loopback()) return 0xb0;
        return (
          ((uart.modemControl & 0x01) !== 0 ? 0x20 : 0)
          | ((uart.modemControl & 0x02) !== 0 ? 0x10 : 0)
          | ((uart.modemControl & 0x04) !== 0 ? 0x40 : 0)
          | ((uart.modemControl & 0x08) !== 0 ? 0x80 : 0)
        );
      default:
        // Sept, le brouillon — et rien d'autre : l'appelant borne le décalage à
        // l'intervalle de la puce. Cette branche est là parce qu'un `switch`
        // sans elle rendrait `undefined`, que `BigInt` refuse ; ce n'est pas un
        // modèle de port, c'est la totalité d'une fonction.
        return uart.scratch;
    }
  };
  /// **La ligne quatre, à niveau et non à front** : la demande suit la
  /// condition, dans les deux sens, comme `serviceInterrupts` le fait du côté
  /// Swift. Une demande qui resterait après que le pilote a tout acquitté
  /// serait délivrée pour rien, et le pilote lirait « rien en attente » dans
  /// l'identification.
  ///
  /// **Elle n'entre pas dans `wakeable`, et c'est raisonné plutôt que
  /// recopié.** Du côté Swift, `devicesArmed` compte le port parmi ce qui peut
  /// réveiller une machine arrêtée, et c'est juste là-bas : `serialInput` est
  /// rempli du dehors, par une frappe. Ici la frappe — `send` — n'arrive
  /// qu'**entre** deux `run`, jamais pendant : à l'intérieur d'un `run`, la
  /// condition du port ne change donc que par une écriture de l'invité, et un
  /// invité arrêté n'écrit pas. L'y mettre ferait tourner la boucle d'attente
  /// du `hlt` jusqu'au bout de sa patience, un mébi-tour, sur une ligne qui
  /// ne montera pas avant la fin du `run`. Ce qui a été tapé avant est déjà
  /// dans la file quand le `run` commence, et `pendingIrq` le voit.
  const raiseSerial = () => {
    if (serialInterrupting()) pics.master.request |= 0x10;
    else pics.master.request &= ~0x10;
  };
  /// Le contrôleur qu'un port désigne, et si c'est son port de **données**.
  /// `null` quand le port n'est celui d'aucun des deux.
  const controllerAt = (at) => {
    if (at === PIC_MASTER || at === PIC_MASTER + 1) {
      return { chip: pics.master, data: (at & 1) === 1 };
    }
    if (at === PIC_SLAVE || at === PIC_SLAVE + 1) {
      return { chip: pics.slave, data: (at & 1) === 1 };
    }
    return null;
  };

  /// **Ce que le canal zéro a fait monter depuis le dernier regard.**
  ///
  /// Le canal zéro est le seul des trois câblé sur IRQ0 — le un n'est câblé
  /// nulle part sur un PC et le deux va au haut-parleur. Appelée à chaque
  /// tour de la boucle hôte, avant de regarder s'il y a quelque chose à
  /// délivrer : c'est le temps qui passe qui lève cette ligne, et le temps
  /// n'avance qu'entre deux tours.
  ///
  /// **Les modes sont ceux que `countOf` descend déjà**, et pas un de plus :
  /// deux et six rechargent, donc une ligne par tour de roue ; zéro et
  /// quatre sont des coups uniques, donc une ligne quand le compte atteint
  /// zéro. Les modes un, trois, cinq et sept ne sont descendus nulle part ici
  /// — les faire lever une ligne serait les deviner.
  ///
  /// **Le mode quatre est celui de l'horloge sans tic de Linux.** Dès que le
  /// noyau passe son horloge d'événements en coup unique — `pit_set_oneshot`,
  /// `outb(0x38, 0x43)` —, chaque échéance est un mode quatre rechargé par
  /// `pit_next_event`. Sa sortie descend d'un pas au bout du compte et
  /// remonte : c'est ce front qui lève IRQ0, une fois, comme le mode zéro.
  /// Il n'était pas modélisé, et Alpine s'arrêtait là sans le dire : plus
  /// aucun tic, l'heure figée à 1,121 s, et le premier `sleep` du shell — un
  /// `tcsetattr` qui attend que le port série se vide — ne revenait jamais.
  const raise8254 = () => {
    const chip = pits[0];
    if (!chip.loaded) return;
    if (!counted(chip.mode)) return;
    const reload = BigInt(chip.reload === 0 ? 0x10000 : chip.reload);
    const steps = stepsOf(chip);
    const turns = oneShot(chip.mode) ? (steps >= reload ? 1n : 0n) : steps / reload;
    if (turns > chip.raised) {
      chip.raised = turns;
      pics.master.request |= 1;
    }
  };

  /// Le numéro de la ligne de plus haute priorité parmi celles-ci, ou `-1`.
  /// La priorité d'un 8259 est l'ordre des bits : zéro d'abord.
  const highest = (bits) => {
    for (let at = 0; at < 8; at++) {
      if (bits & (1 << at)) return at;
    }
    return -1;
  };

  /// **Ce qu'une puce est prête à délivrer**, ou `-1`.
  ///
  /// Trois conditions, et il en faut les trois : la ligne a monté, elle n'est
  /// pas masquée, et aucune ligne de priorité supérieure ou égale n'est déjà
  /// en service. La troisième est le mode imbriqué, celui qu'ICW4 demande et
  /// que tout noyau x86 suppose.
  const readyOn = (chip) => {
    const ready = chip.request & ~chip.mask & 0xff;
    if (ready === 0) return -1;
    const at = highest(ready);
    const serving = chip.service === 0 ? 8 : highest(chip.service);
    return at < serving ? at : -1;
  };

  /// **La ligne que la machine doit prendre maintenant**, ou `null`.
  ///
  /// La sortie de l'esclave est câblée sur la ligne deux du maître : elle
  /// monte tant que l'esclave a quelque chose de prêt, et retombe sinon.
  /// L'écrire dans le registre de requête du maître plutôt que de le
  /// contourner est ce qui fait que la priorité et le masque du maître
  /// s'appliquent à l'esclave — ce qu'ils font sur la puce.
  const pendingIrq = () => {
    const below = readyOn(pics.slave);
    if (below >= 0) pics.master.request |= 1 << PIC_CASCADE;
    else pics.master.request &= ~(1 << PIC_CASCADE);
    const above = readyOn(pics.master);
    if (above < 0) return null;
    if (above !== PIC_CASCADE) {
      return { line: above, slave: false, vector: (pics.master.base + above) & 0xff };
    }
    // La ligne deux du maître n'existe que par l'esclave : sans lui, personne
    // ne l'a levée et il n'y a rien à délivrer.
    if (below < 0) return null;
    return { line: below, slave: true, vector: (pics.slave.base + below) & 0xff };
  };

  /// **Une interruption peut-elle encore venir ?**
  ///
  /// La question se pose sur un `hlt` : l'invité ne fera plus rien de
  /// lui-même, donc tout ce qui pourrait le réveiller doit déjà être en
  /// place. Quatre choses peuvent manquer, et chacune suffit à ce qu'un `hlt`
  /// soit définitif — ce qu'un vrai processeur fait aussi, il se fige.
  ///
  /// **Ce n'est pas `pendingIrq`**, qui dit si une ligne est prête *à cet
  /// instant* ; celle-ci dit si une ligne peut le devenir. Les confondre
  /// ferait soit figer une machine que le matériel allait réveiller, soit
  /// tourner jusqu'à épuisement des tours sur une machine que rien ne
  /// réveillera.
  const wakeable = () => {
    const chip = pits[0];
    // Un compteur que personne n'a programmé, ou dans un mode dont la
    // descente n'est pas modélisée, ne fera rien monter.
    if (!chip.loaded) return false;
    if (!counted(chip.mode)) return false;
    // Les modes zéro et quatre sont des coups uniques : tirés, ils ne
    // tireront plus.
    if (oneShot(chip.mode) && chip.raised > 0n) return false;
    // Et la ligne elle-même : masquée, ou en service sans acquittement, elle
    // ne réveillera personne — l'invité arrêté n'ira ni la démasquer ni
    // l'acquitter.
    if (pics.master.mask & 1) return false;
    if (pics.master.service & 1) return false;
    return true;
  };

  /// Prendre la ligne : elle sort de la requête et entre en service.
  ///
  /// **Une ligne de l'esclave en met deux en service**, la sienne et la deux
  /// du maître — et il faudra donc deux acquittements, ce que Linux envoie.
  const takeIrq = (what) => {
    const chip = what.slave ? pics.slave : pics.master;
    chip.request &= ~(1 << what.line);
    chip.service |= 1 << what.line;
    if (what.slave) {
      pics.master.request &= ~(1 << PIC_CASCADE);
      pics.master.service |= 1 << PIC_CASCADE;
    }
  };

  /// **L'invité a tiré la ligne de remise à zéro**, par l'i8042 de la carte.
  let remiseDemandee = false;
  /// **Les lignes de la carte, recopiées dans les deux 8259.** À niveau,
  /// comme le port série : une ligne que la carte lève entre dans le registre
  /// de requête, une ligne qu'elle tient et ne lève plus en sort. Les lignes
  /// qu'elle ne tient pas — la zéro du 8254, la deux de la cascade, la quatre
  /// du 16550 — ne sont jamais touchées, et la carte refuse de les tenir.
  ///
  /// **Le temps d'abord** : `battre` pose les frappes au rythme d'une main, en
  /// tics du 8254 depuis le départ, donc contre la même horloge que lui.
  ///
  /// Appelée à chaque tour avant de regarder ce qui est prêt, et dans
  /// l'attente d'un `hlt` — c'est là que le temps passe sans l'invité, et
  /// qu'une réponse du disque arrive.
  const recopierLignes = () => {
    if (peripheriques === null) return;
    peripheriques.battre((now() * PIT_HZ) / TSC_HZ);
    const l = peripheriques.lignes();
    pics.master.request = (pics.master.request & ~(l.tenuesMaitre & ~l.maitre)) | l.maitre;
    pics.slave.request = (pics.slave.request & ~(l.tenuesEsclave & ~l.esclave)) | l.esclave;
  };

  env.out = (port, value, width) => {
    const at = Number(port);
    if (at >= SERIAL && at <= SERIAL_LAST) {
      serialWrite(at - SERIAL, Number(value & 0xffn));
      return;
    }
    if (at === PIT_GATE) {
      // **Le portillon du canal deux.** Le bit cinq appartient à la puce et
      // n'est pas rangé : l'écrire n'a aucun effet sur un vrai PC non plus.
      const octet = Number(value & 0xffn);
      gatePort = octet & ~PIT_OUT_TWO;
      const wanted = (octet & PIT_GATE_OPEN) !== 0;
      const chip = pits[2];
      if (wanted !== chip.open) {
        // Le temps déjà compté est mis de côté avant la fermeture, et
        // l'ouverture repart de maintenant. Un compteur ne perd donc rien à
        // être suspendu, et ne gagne rien non plus.
        if (!wanted) chip.consumed = stepsOf(chip);
        chip.open = wanted;
        chip.openedAt = now();
      }
      return;
    }
    if (at === PIT_COMMAND) {
      const octet = Number(value & 0xffn);
      const which = octet >> 6;
      // **La commande de relecture** — canal trois — n'est pas modélisée. Ce
      // noyau ne l'emploie pas ; l'ignorer en le disant vaut mieux que de
      // rendre un état inventé.
      if (which === 3) return;
      const chip = pits[which];
      const access = (octet >> 4) & 3;
      if (access === 0) {
        // Le verrou : le compte est figé jusqu'à ce que ses deux octets soient
        // lus. C'est ce qui existe pour qu'un lecteur ne voie pas un octet bas
        // d'avant et un octet haut d'après.
        chip.latched = countOf(chip);
        chip.readHigh = false;
        return;
      }
      chip.mode = (octet >> 1) & 7;
      chip.access = access;
      chip.low = 0;
      chip.readHigh = false;
      chip.writeHigh = false;
      chip.latched = null;
      return;
    }
    if (at >= PIT_CHANNEL && at < PIT_CHANNEL + 3) {
      const chip = pits[at - PIT_CHANNEL];
      const octet = Number(value & 0xffn);
      if (chip.access === 1) load(chip, octet);
      else if (chip.access === 2) load(chip, octet << 8);
      else if (!chip.writeHigh) {
        // Bas puis haut : le premier octet attend le second, et le compteur ne
        // repart qu'une fois les deux écrits — comme la puce.
        chip.low = octet;
        chip.writeHigh = true;
      } else {
        chip.writeHigh = false;
        load(chip, (octet << 8) | chip.low);
      }
      return;
    }
    const chosen = controllerAt(at);
    if (chosen !== null) {
      const octet = Number(value & 0xffn);
      if (!chosen.data) {
        // **Le port de commande porte trois mots**, et les bits 3 et 4 disent
        // lequel. Ce commentaire disait que tout sauf l'initialisation « n'a
        // aucun effet tant qu'aucune ligne ne monte » : c'était vrai, et une
        // ligne monte maintenant.
        if (octet & PIC_INIT) {
          chosen.chip.expects = 2;
          chosen.chip.wantsFour = (octet & PIC_WANTS_ICW4) !== 0;
          return;
        }
        if ((octet & PIC_WORD) === PIC_IS_OCW3) {
          chosen.chip.reads =
            octet & PIC_READ_SERVICE ? "service" : "request";
          return;
        }
        // **OCW2, et la fin d'interruption.** Sans le bit d'acquittement, le
        // mot ne demande qu'une rotation de priorités, qui n'est pas
        // modélisée : il ne fait donc rien, et le dire vaut mieux que de le
        // taire.
        if (octet & PIC_EOI) {
          const line =
            octet & PIC_SPECIFIC ? octet & 0x07 : highest(chosen.chip.service);
          // Un acquittement sans rien en service est ce qu'un noyau envoie
          // pour une interruption fantôme. Il ne doit pas effacer la ligne
          // zéro par accident — d'où le refus de `-1`.
          if (line >= 0) chosen.chip.service &= ~(1 << line);
        }
        return;
      }
      // **Le port de données porte deux choses selon le moment** : les mots
      // d'initialisation tant qu'une séquence est ouverte, le masque sinon.
      // Les confondre rendrait la sonde verte quand même — le noyau repose son
      // masque juste après — et se tromperait de vecteur pour toujours.
      switch (chosen.chip.expects) {
        case 2:
          chosen.chip.base = octet;
          chosen.chip.expects = 3;
          return;
        case 3:
          // **ICW3, le câblage de la cascade.** Tenu pour acquis plutôt que
          // lu : la ligne deux, celle de tous les PC. Ce commentaire disait
          // « rien ici ne le consulte, l'esclave ne lève rien » — la cascade
          // est consultée maintenant, à `PIC_CASCADE`, mais elle vient de la
          // constante et non de ce mot. Un noyau qui câblerait l'esclave
          // ailleurs serait routé de travers, et ce serait silencieux.
          chosen.chip.expects = chosen.chip.wantsFour ? 4 : 0;
          return;
        case 4:
          // ICW4, le mode. Seul le mode 8086 est modélisé, et c'est le seul
          // qu'un noyau x86-64 demande.
          chosen.chip.expects = 0;
          return;
        default:
          chosen.chip.mask = octet;
          return;
      }
    }
    // **Le reste va à la carte, en dernier** : l'i8042, l'horloge, le bus et
    // les fenêtres des disques. Ses ports et ceux des puces d'ici ne se
    // recouvrent pas (la carte refuse les leurs), et l'ordre le garantit
    // quand même : une BAR que le noyau poserait sur `0x40` ne volerait pas
    // le 8254. Un `out` qui notifie le disque fait partir sa requête vers
    // l'arrière, et rend tout de suite.
    //
    // **L'impulsion de remise à zéro** (`0xFE` sur `0x64`) se note ici, au
    // seul endroit où elle peut naître : la boucle s'arrête dessus à la fin
    // de la région, comme le cœur Swift finit sa course sur `X86Core.Reset`.
    //
    // Sans carte, tout le reste tombe dans le vide, comme sur une carte mère
    // sans périphériques : une écriture vers un port absent ne fait rien et
    // ne fait pas planter la machine.
    if (peripheriques !== null && peripheriques.ports.out(port, value, width)) {
      if ((at === 0x64 || at === 0x60) && peripheriques.remise()) remiseDemandee = true;
    }
  };
  env.in = (port, width) => {
    void width;
    const at = Number(port);
    if (at >= SERIAL && at <= SERIAL_LAST) return BigInt(serialRead(at - SERIAL));
    if (at === PIT_GATE) {
      return BigInt(gatePort | (outTwo() ? PIT_OUT_TWO : 0));
    }
    if (at >= PIT_CHANNEL && at < PIT_CHANNEL + 3) {
      const chip = pits[at - PIT_CHANNEL];
      const value = chip.latched !== null ? chip.latched : countOf(chip);
      if (chip.access === 1) return BigInt(value & 0xff);
      if (chip.access === 2) return BigInt((value >> 8) & 0xff);
      if (!chip.readHigh) {
        chip.readHigh = true;
        return BigInt(value & 0xff);
      }
      chip.readHigh = false;
      chip.latched = null;
      return BigInt((value >> 8) & 0xff);
    }
    const chosen = controllerAt(at);
    if (chosen !== null) {
      // Le port de données rend le masque — c'est toute la sonde du noyau. Le
      // port de commande rend celui des deux registres qu'OCW3 a choisi.
      //
      // Ce commentaire disait « les deux sont vides tant qu'aucune ligne ne
      // monte, et zéro est alors la réponse vraie ». Une ligne monte
      // maintenant, donc zéro serait devenu un bouchon — et le plus
      // trompeur des bouchons, puisque Linux lit le registre de service pour
      // trancher entre une vraie interruption et une fantôme.
      if (chosen.data) return BigInt(chosen.chip.mask);
      // La requête est regardée avec la ligne de l'esclave déjà reportée sur
      // la deux du maître, comme la puce la présente.
      pendingIrq();
      return BigInt(
        chosen.chip.reads === "service" ? chosen.chip.service : chosen.chip.request);
    }
    // La carte, en dernier ; `null` quand le port n'est pas à elle non plus.
    if (peripheriques !== null) {
      const valeur = peripheriques.ports.in(port, width);
      if (valeur !== null) return valeur;
    }
    return BigInt(NOBODY_THERE);
  };
  const imports = { env };
  const base = pages * 65536;

  // ---------------------------------------------------------------------
  // **Le cache de code : borné, rangé par contexte, évincé au plus ancien.**
  //
  // Il n'avait aucune borne. Chaque `exec` remet ses bibliothèques à des
  // adresses neuves, chaque programme se retraduit, et le démarrage d'Alpine
  // remplissait les quinze gibioctets de ce conteneur vers cent mille
  // régions (JOURNAL, 14 novembre 2026). Sur un iPhone, le processus de la
  // vue meurt bien avant.
  //
  // **Trois règles, chacune tenue par un test de `host_loop`** :
  //
  // 1. **Une région est rangée sous son contexte** (`contexte`, le pendant de
  //    `context_tag`) : l'anneau, et l'espace d'adressage hors de l'anneau
  //    zéro. Une région du noyau ne se trouve plus depuis l'anneau trois — ni
  //    par l'hôte, ni par la correspondance, qui compare le contexte rangé
  //    dans la case — et un programme ne sert plus celles d'un autre.
  // 2. **Deux bornes, un nombre de régions et un nombre d'octets de modules**
  //    (`limite`) ; franchir l'une fait évincer la région **la moins
  //    récemment servie** par l'hôte (`recentes`). Un processus mort ne sert
  //    plus rien : ses régions vieillissent et partent les premières.
  // 3. **Une région évincée quitte tout** — sa place dans `espaces`, ses cases
  //    de la correspondance, ses blocs dans la table — et sa place dans la
  //    table est rendue (`libres`) pour une région qui y tient. Revenir à son
  //    adresse la retraduit, sur les octets d'alors.
  // ---------------------------------------------------------------------
  const limite = {
    regions: cache.regions ?? CACHE_PAR_DEFAUT.regions,
    octets: cache.octets ?? CACHE_PAR_DEFAUT.octets,
    emplacements: cache.emplacements ?? CACHE_PAR_DEFAUT.emplacements,
    oubliees: cache.oubliees ?? CACHE_PAR_DEFAUT.oubliees,
  };
  for (const [nom, valeur] of Object.entries(limite)) {
    if (!Number.isInteger(valeur) || valeur <= 0) {
      throw new Error(`la borne du cache « ${nom} » doit être un entier positif, pas ${valeur}`);
    }
  }
  /// Les régions, par contexte puis par adresse.
  const espaces = new Map();
  /// **Toutes les régions, de la moins récemment servie à la plus récente.**
  /// Un `Set` garde l'ordre d'insertion ; servir une région la retire et la
  /// remet, donc la première est toujours la prochaine à partir. « Servie »
  /// veut dire **par l'hôte** : un saut de module à module par la
  /// correspondance ne repasse pas par ici, et c'est le prix d'un chemin
  /// chaud qui ne coûte rien — une région que seuls des sauts directs
  /// atteignent vieillit, et se retraduit si elle part.
  const recentes = new Set();
  /// **Les places rendues dans la table des blocs**, sous `next`, triées et
  /// jamais contiguës entre elles : `{ debut, longueur }`.
  const libres = [];
  /// La première place jamais prise de la table : tout ce qui est au-dessus
  /// est libre.
  let next = 0;
  /// **Ce que le cache tient, ce qu'il a tenu au plus, et ce qu'il a jeté.**
  /// Lecture ; rien ne se décide dessus hors de `tenu`.
  ///
  /// - `traduites` : les régions installées ; `retraduites`, celles d'entre
  ///   elles dont la même adresse, sous le même contexte, avait été évincée —
  ///   le taux de retraduction est leur rapport ;
  /// - `replacees` : les traductions refaites parce que la région ne tenait
  ///   pas dans la place choisie (voir `install`) ;
  /// - `emplacements` : le haut de la table des blocs au plus haut.
  const tenu = { regions: 0, octets: 0 };
  const caches = {
    limite,
    tenu,
    pic: { regions: 0, octets: 0, emplacements: 0, espaces: 0 },
    traduites: 0,
    evincees: 0,
    retraduites: 0,
    replacees: 0,
    respirations: 0,
    /// Les clés évincées que le cache retient pour compter les retraductions
    /// (voir `oubliees`), jamais plus que `limite.oubliees`.
    get oubliees() {
      return oubliees.size;
    },
    /// **Les places rendues et le haut de la table**, en copie. Lecture : les
    /// tests y vérifient ce que `libres` promet — triées, jamais vides,
    /// jamais contiguës, toutes sous le haut.
    places: () => libres.map(({ debut, longueur }) => ({ debut, longueur })),
    haut: () => next,
  };
  /// **Ce que la carte des pages de code a vu** : les trames écrites alors
  /// qu'elles portaient du code traduit (`ecritures`), les régions oubliées
  /// pour ça (`invalidees`, à part des évictions : ce n'est pas la borne qui
  /// les chasse), et les relectures de la carte entière quand le journal a
  /// débordé (`debordements`). Lecture.
  caches.ecritures = 0;
  caches.invalidees = 0;
  caches.debordements = 0;
  caches.pic.trames = 0;
  /// **Les octets évincés depuis la dernière respiration du ramasse-miettes**
  /// (voir `respirerSiBesoin`).
  let evincesDepuis = 0;
  /// **Les clés évincées, pour compter les retraductions** — et seulement
  /// pour ça. Bornée par `limite.oubliees` (`1 << 18` par défaut) : passé ce
  /// nombre, elle repart vide, et le compte des retraductions devient un
  /// plancher. C'est dit plutôt que caché.
  const oubliees = new Set();
  const vue = new DataView(memory.buffer);

  /// **Le contexte courant** : le même calcul que `context_tag` côté Rust et
  /// que celui gravé dans les octets du module. Un nombre, jamais négatif :
  /// la racine et les bits bas ne se chevauchent pas, d'où l'addition plutôt
  /// qu'un `|` qui passerait par trente-deux bits signés.
  const racine = BigInt(base - 1) & ~0xfffn;
  const contexte = () => {
    const anneau = Number(BigInt.asUintN(64, globals[SLOTS.segment + 1].value) & 3n);
    if (anneau === 0) return SLOTS.contextPresent;
    return (
      Number(BigInt.asUintN(64, globals[SLOTS.control + 2].value) & racine) +
      SLOTS.contextPresent +
      anneau
    );
  };
  /// La région à cette adresse **sous le contexte courant**, ou rien.
  const trouver = (adresse) => espaces.get(contexte())?.get(adresse);

  /// **Ranger une adresse dans la correspondance**, sous un contexte.
  ///
  /// Une voie libre du seau, sinon la sienne, sinon on évince la première.
  /// Chercher d'abord une voie vide ou déjà à cette adresse **sous ce
  /// contexte**, c'est ce qui fait qu'une collision cesse de coûter une
  /// éviction : deux adresses de même empreinte tiennent ensemble. Une voie
  /// qui porte la même adresse sous un autre contexte n'est pas la sienne :
  /// c'est la région d'un autre programme, ou d'un autre anneau. Quand les
  /// deux voies sont prises par d'autres, il faut bien en sacrifier une — la
  /// première, et le défaut redevient ce qu'il était, muet et seulement plus
  /// lent.
  ///
  /// **Un début de bloc ne chasse jamais une entrée de région.** C'est la
  /// leçon de la première mesure de la tranche qui a rangé les blocs, et elle
  /// est chiffrée : ranger *toutes* les cases sans distinction a fait passer
  /// les retours de main sur `pv_native_irq_disable` de 2938 à 66 340. Dix
  /// fois plus d'adresses pour deux voies par seau, et les entrées les plus
  /// chaudes se faisaient évincer par des blocs qu'on ne visite qu'une fois.
  /// L'entrée d'une région est la seule adresse par laquelle toute la région
  /// reste atteignable ; un début de bloc n'est qu'un raccourci.
  const ranger = (quoi, où, ctx, évincer) => {
    const seau = base + tableBucket(quoi) * SLOTS.tableEntry;
    let libre = -1;
    for (let essai = 0; essai < SLOTS.tableWays; essai += 1) {
      const at = seau + essai * SLOTS.tableEntry;
      const rangee = vue.getBigUint64(at, true);
      const sien = vue.getUint32(at + SLOTS.tableContext, true);
      if ((rangee === quoi && sien === ctx) || sien === 0) {
        libre = essai;
        break;
      }
    }
    if (!évincer && libre === -1) return;
    const at = seau + (libre === -1 ? 0 : libre) * SLOTS.tableEntry;
    vue.setBigUint64(at, quoi, true);
    vue.setInt32(at + 8, où, true);
    vue.setUint32(at + SLOTS.tableContext, ctx, true);
  };
  /// **Effacer de la correspondance la case qui mène à ce bloc**, s'il y en
  /// a une : la même adresse, le même contexte **et** le même indice. Une case
  /// qu'une autre région a reprise depuis n'est pas touchée.
  const effacer = (quoi, où, ctx) => {
    const seau = base + tableBucket(quoi) * SLOTS.tableEntry;
    for (let essai = 0; essai < SLOTS.tableWays; essai += 1) {
      const at = seau + essai * SLOTS.tableEntry;
      if (
        vue.getBigUint64(at, true) === quoi &&
        vue.getUint32(at + SLOTS.tableContext, true) === ctx &&
        vue.getInt32(at + 8, true) === où
      ) {
        vue.setBigUint64(at, 0n, true);
        vue.setInt32(at + 8, 0, true);
        vue.setUint32(at + SLOTS.tableContext, 0, true);
      }
    }
  };

  /// **Rendre une étendue de la table**, en la fusionnant à ses voisines ; si
  /// elle touche le haut, le haut redescend.
  const rendre = (debut, longueur) => {
    let rang = 0;
    while (rang < libres.length && libres[rang].debut < debut) rang += 1;
    libres.splice(rang, 0, { debut, longueur });
    if (rang + 1 < libres.length && debut + longueur === libres[rang + 1].debut) {
      libres[rang].longueur += libres[rang + 1].longueur;
      libres.splice(rang + 1, 1);
    }
    if (rang > 0 && libres[rang - 1].debut + libres[rang - 1].longueur === debut) {
      libres[rang - 1].longueur += libres[rang].longueur;
      libres.splice(rang, 1);
      rang -= 1;
    }
    const dernier = libres[libres.length - 1];
    if (dernier !== undefined && dernier.debut + dernier.longueur === next) {
      next = dernier.debut;
      libres.pop();
    }
  };
  /// **Prendre `[debut, debut + longueur)` dans la table**, si c'est libre :
  /// dans une étendue rendue, ou au-dessus du haut. Rend faux sans rien
  /// prendre si une région vivante y est.
  const prendre = (debut, longueur) => {
    if (debut >= next) {
      // Le haut monte d'abord : le trou laissé entre l'ancien haut et
      // `debut`, s'il y en a un, est alors rendu sous le haut, pas au haut.
      const haut = next;
      next = debut + longueur;
      if (debut > haut) rendre(haut, debut - haut);
      return true;
    }
    for (let rang = 0; rang < libres.length; rang += 1) {
      const etendue = libres[rang];
      if (etendue.debut > debut) return false;
      const fin = etendue.debut + etendue.longueur;
      if (debut + longueur > fin) continue;
      // Ce qui reste devant et derrière la région.
      const apres = { debut: debut + longueur, longueur: fin - debut - longueur };
      const avant = { debut: etendue.debut, longueur: debut - etendue.debut };
      const morceaux = [avant, apres].filter((m) => m.longueur > 0);
      libres.splice(rang, 1, ...morceaux);
      return true;
    }
    return false;
  };
  /// **La place où essayer une région d'environ `voulu` blocs.**
  ///
  /// Le haut de la table tant qu'il reste sous `limite.emplacements` : tout y
  /// tient, et rien n'est jamais retraduit pour sa place. Au-delà, la plus
  /// **grande** des places rendues, si elle a `voulu` blocs ; sinon le haut
  /// quand même, et la table grandit. La plus grande et pas la première : la
  /// première venue était mesurée sur Alpine, et une région sur quatorze n'y
  /// tenait pas — 8 906 traductions refaites sur 123 134.
  const choisir = (voulu) => {
    if (next + voulu <= limite.emplacements) return next;
    let grande = null;
    for (const etendue of libres) {
      if (grande === null || etendue.longueur > grande.longueur) grande = etendue;
    }
    return grande !== null && grande.longueur >= voulu ? grande.debut : next;
  };

  // ---------------------------------------------------------------------
  // **La carte du code traduit : voir les écritures au lieu de vider.**
  //
  // Chaque ligne de soixante-quatre octets d'où vient le code d'une région
  // vivante a son bit levé dans la carte (`code_pages` côté Rust), et l'hôte
  // sait quelles régions chaque trame porte, et sur quelles lignes
  // (`trames`). Toute écriture sur une ligne marquée oublie ses régions avant
  // la prochaine entrée :
  //
  // - **celles du module** : le tampon ne dit jamais inscriptible une trame
  //   qui porte une ligne marquée, l'accès lent baisse le bit et inscrit la
  //   ligne au journal, et l'instruction finie, la région rend la main
  //   (`Body::written`). La boucle lit le journal au retour de chaque région
  //   (`voirEcritures`) ;
  // - **celles de l'hôte** — le cadre d'une délivrance, et demain le disque —
  //   passent par `ecrit`, qui oublie les régions sur place ;
  // - **celles du dehors**, `memory.buffer` écrit sans rien dire, ne sont vues
  //   par rien. `ecrit` est exporté pour elles.
  //
  // **Et la racine des tables d'un programme porte toutes ses régions.** Un
  // processus neuf dont les tables tombent sur la page de celles d'un mort
  // hérite de son contexte, et une région du mort à la même adresse le
  // servirait. Mais une racine neuve s'écrit avant de servir — Linux la met à
  // zéro et y recopie la moitié du noyau —, et cette écriture-là oublie toutes
  // les régions de l'ancien contexte : chacune marque la page entière de sa
  // racine.
  // ---------------------------------------------------------------------
  const journalBase = base + (SLOTS.tablePages + SLOTS.tlbPages) * 65536;
  const journal = new Uint32Array(memory.buffer, journalBase, 65536 / 4);
  /// La carte : deux mots de trente-deux bits par trame, les lignes 0 à 31
  /// puis 32 à 63.
  const carte = new Uint32Array(memory.buffer, journalBase + 65536, (pages * 65536) / 2048);
  const tampon = new Uint32Array(
    memory.buffer, base + SLOTS.tablePages * 65536, (SLOTS.tlbSlots * SLOTS.tlbEntry) / 4);
  /// Les régions de chaque trame marquée, par numéro de trame.
  const trames = new Map();
  /// **Les lignes qu'une région lit dans une trame**, en deux mots.
  const lignesDe = (region, trame) => region.morceaux.find((m) => m.trame === trame);
  /// **Recalculer les bits d'une trame** depuis les régions qu'elle porte
  /// encore. Une trame qui n'en porte plus aucune est démarquée, et ses
  /// écritures reprennent le chemin rapide dès que la marche remplit sa case.
  const recompter = (trame) => {
    let bas = 0;
    let haut = 0;
    const ici = trames.get(trame);
    if (ici !== undefined) {
      for (const region of ici) {
        const m = lignesDe(region, trame);
        bas |= m.bas;
        haut |= m.haut;
      }
    }
    carte[trame * 2] = bas;
    carte[trame * 2 + 1] = haut;
  };
  /// **Marquer les lignes d'une région.** Une trame qui n'en avait aucune
  /// fait aussi oublier `TLB_WRITABLE` aux cases du tampon qui la portent
  /// déjà : remplies avant, elles laisseraient une écriture passer par le
  /// chemin rapide, sans que rien ne la voie.
  const marquer = (region) => {
    for (const m of region.morceaux) {
      let ici = trames.get(m.trame);
      if (ici === undefined) {
        ici = new Set();
        trames.set(m.trame, ici);
      }
      ici.add(region);
      const vierge = (carte[m.trame * 2] | carte[m.trame * 2 + 1]) === 0;
      carte[m.trame * 2] |= m.bas;
      carte[m.trame * 2 + 1] |= m.haut;
      if (!vierge) continue;
      const physique = m.trame * 4096;
      for (let at = 0; at < tampon.length; at += SLOTS.tlbEntry / 4) {
        if (tampon[at + 2] === physique && (tampon[at] & 2) !== 0) tampon[at] &= ~2;
      }
    }
  };
  /// **Une région quitte ses trames**, et leurs bits sont recalculés.
  const demarquer = (region) => {
    for (const m of region.morceaux) {
      const ici = trames.get(m.trame);
      if (ici === undefined) continue;
      ici.delete(region);
      if (ici.size === 0) trames.delete(m.trame);
      recompter(m.trame);
    }
  };
  /// **Oublier les régions qui lisent une ligne écrite.** Rend combien.
  const invaliderLigne = (ligne) => {
    caches.ecritures += 1;
    const trame = Math.floor(ligne / 64);
    const ici = trames.get(trame);
    if (ici === undefined) return 0;
    const rang = ligne % 64;
    const regions = [...ici].filter((region) => {
      const m = lignesDe(region, trame);
      return ((rang < 32 ? m.bas >>> rang : m.haut >>> (rang - 32)) & 1) !== 0;
    });
    for (const region of regions) evincer(region, true);
    return regions.length;
  };
  /// **Ce que le module a inscrit au journal depuis la dernière fois**, et
  /// les régions oubliées pour ça. Rend vrai s'il y avait quelque chose : la
  /// région qui vient de tourner peut être du nombre.
  ///
  /// **Quand le journal a débordé** — une instruction qui écrit plus de seize
  /// mille lignes de code —, les numéros manquent, mais la carte les dit : le
  /// module a baissé le bit de chaque ligne écrite, et une région dont une
  /// ligne n'est plus marquée est une région dont le code a été écrit.
  const voirEcritures = () => {
    if (globals[SLOTS.stop].value === STOP_WRITTEN) globals[SLOTS.stop].value = 0n;
    const compte = journal[0];
    if (compte === 0) return false;
    journal[0] = 0;
    if (compte <= SLOTS.codeLogSlots) {
      for (const ligne of Array.from(journal.subarray(1, 1 + compte))) invaliderLigne(ligne);
      return true;
    }
    caches.debordements += 1;
    const touchees = new Set();
    for (const [trame, ici] of trames) {
      for (const region of ici) {
        const m = lignesDe(region, trame);
        if ((m.bas & ~carte[trame * 2]) !== 0 || (m.haut & ~carte[trame * 2 + 1]) !== 0) {
          touchees.add(region);
        }
      }
    }
    caches.ecritures += touchees.size;
    for (const region of touchees) evincer(region, true);
    return true;
  };
  /// **Une écriture de l'hôte dans la mémoire de l'invité** : `longueur`
  /// octets à l'adresse **physique** `physique`, déjà écrits. Les régions
  /// des lignes marquées qu'elle touche sont oubliées sur-le-champ. Rend
  /// combien.
  const ecrit = (physique, longueur) => {
    let oubliees = 0;
    if (!(longueur > 0)) return oubliees;
    const premiere = Math.floor(physique / 64);
    const derniere = Math.floor((physique + longueur - 1) / 64);
    for (let ligne = premiere; ligne <= derniere; ligne += 1) {
      const mot = Math.floor(ligne / 32);
      const bit = 1 << (ligne % 32);
      if ((carte[mot] & bit) === 0) continue;
      carte[mot] &= ~bit;
      oubliees += invaliderLigne(ligne);
    }
    return oubliees;
  };

  /// **Évincer une région** : elle quitte son contexte, l'ordre des
  /// récentes, la correspondance et la table, et sa place est rendue.
  ///
  /// **Invalidée, ce n'est pas la borne qui la chasse** : comptée dans
  /// `invalidees` et non `evincees`, et sa clé n'entre pas dans `oubliees` —
  /// la retraduire n'est pas le prix de la borne.
  const evincer = (region, invalidee = false) => {
    const ici = espaces.get(region.contexte);
    ici.delete(region.adresse);
    if (ici.size === 0) espaces.delete(region.contexte);
    recentes.delete(region);
    for (let rang = 0; rang < region.debuts.length; rang += 1) {
      effacer(region.debuts[rang], region.slot + rang, region.contexte);
      blocks.set(region.slot + rang, null);
    }
    rendre(region.slot, region.debuts.length);
    demarquer(region);
    tenu.regions -= 1;
    tenu.octets -= region.octets;
    evincesDepuis += region.octets;
    if (invalidee) {
      caches.invalidees += 1;
      return;
    }
    caches.evincees += 1;
    if (oubliees.size >= limite.oubliees) oubliees.clear();
    oubliees.add(`${region.contexte}:${region.adresse}`);
  };
  /// **Faire de la place pour une région de `octets` octets**, en évinçant
  /// les moins récemment servies jusqu'à tenir sous les deux bornes.
  const faireDeLaPlace = (octets) => {
    for (const region of recentes) {
      if (tenu.regions + 1 <= limite.regions && tenu.octets + octets <= limite.octets) return;
      evincer(region);
    }
  };
  /// **Laisser le moteur rendre ce qu'on a évincé**, une fois qu'un quart de
  /// la borne en octets est parti depuis la dernière fois.
  ///
  /// **Évincer ne rend rien tout seul, et c'est mesuré** (JOURNAL, 15
  /// novembre 2026, sous le JavaScriptCore de Bun) : trois mille modules
  /// d'Alpine, 72,6 Mio de wasm, coûtent 320 Mio de mémoire résidente —
  /// 4,4 octets par octet de wasm, 108 Kio par région —, et une fois lâchés
  /// ils restent là. Le code compilé d'un module ne pèse rien sur le tas de
  /// JavaScript, donc rien ne déclenche de collecte pour lui ; quatre tours
  /// lâchés sans pause montent à 1,4 Gio. Un `setTimeout(…, 0)` ne suffit
  /// pas ; **huit millisecondes de repos**, oui : le moteur collecte quand il
  /// a la main, et la mémoire redescend au niveau d'un seul tour. La boucle
  /// respire déjà toutes les huit millisecondes, mais d'un `setTimeout(…, 0)`
  /// — juste assez pour la page, pas pour le ramasse-miettes.
  ///
  /// Le prix : huit millisecondes par quart de borne évincé — sur Alpine, une
  /// fois toutes les quelques centaines de régions traduites, qui coûtent
  /// chacune plus que ça.
  ///
  /// **Et la pause ne suffit pas toujours, mesuré aussi.** Dans la vraie
  /// boucle, les modules évincés ont survécu à bien des collectes jeunes avant
  /// de partir : seule une collecte **pleine** les rend. Sous Bun, une sonde
  /// Alpine aux bornes de 2 000 régions et 16 Mio monte à 1,9 Gio résidents
  /// avec la pause seule, et reste à 273 Mio avec `Bun.gc(true)` à chaque
  /// respiration — d'où `ramasser`. Rien dans une page ne force une collecte
  /// pleine ; sur un appareil, c'est le gestionnaire de pression mémoire de
  /// WebKit qui la fait, et ce n'est **pas mesuré ici**.
  const respirerSiBesoin = async () => {
    if (evincesDepuis < limite.octets / 4) return;
    evincesDepuis = 0;
    caches.respirations += 1;
    if (ramasser !== null) ramasser();
    await new Promise((settle) => setTimeout(settle, 8));
  };
  /// **Servir une région connue** : elle devient la plus récente, et son
  /// entrée reprend sa case dans la correspondance si une autre la lui a
  /// prise — une collision, ou l'autre contexte à la même adresse. Sans ça,
  /// deux programmes qui se relaient à la même adresse (un `fork`)
  /// repasseraient par l'hôte à chaque saut.
  const servir = (region) => {
    recentes.delete(region);
    recentes.add(region);
    ranger(region.adresse, region.slot, region.contexte, true);
  };

  /// **La vue des régions que le relevé et les tests lisent** : leur nombre,
  /// celle d'une adresse sous le contexte courant, et toutes, de la moins
  /// récemment servie à la plus récente.
  const known = {
    get size() {
      return recentes.size;
    },
    get: trouver,
    values: () => recentes.values(),
    *[Symbol.iterator]() {
      for (const region of recentes) yield [region.adresse, region];
    },
  };

  // **Le cadre doit tenir dans la RAM invitée.** Sinon il chevaucherait la
  // correspondance : l'invité peindrait la table des blocs à l'écran, et la
  // détruirait du même geste. Refuser ici plutôt qu'à la première image.
  if (screen !== undefined) {
    const at = Number(BigInt(screen.base) & BigInt(base - 1));
    const octets = screen.width * screen.height * 4;
    if (!(screen.width > 0) || !(screen.height > 0) || at + octets > base) {
      throw new Error(
        `le cadre ${screen.width}×${screen.height} à ${at} déborde de la RAM invitée`,
      );
    }
  }

  const rip = () => BigInt.asUintN(64, globals[SLOTS.rip].value);
  let walk = null;
  /// Ce que la marche a rendu sur la première page de la dernière fenêtre
  /// que `read` n'a pas pu lire du tout : le code d'erreur plus un, ou zéro.
  let unread = 0n;
  /// **Où la dernière lecture s'est arrêtée sur une page illisible après en
  /// avoir lu d'autres**, et ce que la marche y a dit (le code plus un) ;
  /// `null` quand elle s'est arrêtée ailleurs — au bout de la fenêtre ou de
  /// la RAM. C'est ce que demande une instruction coupée par une page
  /// absente : voir `CUT`.
  let stopped = null;
  /// **Les trames que la dernière lecture a traversées**, la page de chaque
  /// morceau dans l'ordre : `install` y prend celles de sa fenêtre.
  let luesTrames = [];

  /// **Une adresse invitée, rendue en adresse de mémoire linéaire — par la
  /// marche du module.** Pagination éteinte, c'est le repli, comme dans
  /// `Body::peek` et `Body::poke`. Allumée, c'est `walk`, qui pose le témoin
  /// et CR2 quand la page manque : `null` alors, et c'est à l'appelant de
  /// nommer ce qui vient de fauter pendant qu'il faisait autre chose.
  ///
  /// **`kind` dit ce que l'hôte vient faire**, et c'est la marche qui juge :
  /// `SLOTS.walkMachine` pour le processeur qui travaille pour lui-même — la
  /// porte, le descripteur, le segment de tâche, le cadre —, qu'aucun droit
  /// n'arrête ; `SLOTS.walkFetch` pour la fenêtre d'une région, qu'un
  /// programme ne lit que dans ses propres pages.
  function physical(address, kind = SLOTS.walkMachine) {
    const paging = (BigInt.asUintN(64, globals[SLOTS.control].value) & PAGING_BIT) !== 0n;
    if (!paging || walk === null) return Number(address & BigInt(base - 1));
    const frame = walk(BigInt.asIntN(64, address), kind);
    if (globals[SLOTS.fault].value !== 0n) return null;
    const page = Number(BigInt.asUintN(32, BigInt(frame)));
    return (page + Number(address & 0xfffn)) & (base - 1);
  }

  /// **Huit octets lus à une adresse invitée, chacun dans la page qui le
  /// porte.** `physical` traduit **une** adresse ; lire ensuite huit octets
  /// contigus en mémoire linéaire, ce que faisaient la délivrance et la
  /// lecture du segment de tâche, prend la fin d'un mot à cheval dans la
  /// trame physiquement voisine — pas dans la page virtuelle d'après. Le
  /// défaut exact que `far_load_body` corrige côté module. Linux aligne son
  /// IDT, sa GDT et son TSS sur une page, et ne le voit pas ; un mot à cheval
  /// reste un mot, et le silicium le lit dans ses deux pages.
  ///
  /// Rend `null` quand l'une des deux pages manque, le témoin et CR2 posés
  /// par la marche — CR2 sur le premier octet de la seconde.
  function peekWord(address) {
    const start = physical(address);
    if (start === null) return null;
    const vue = new DataView(memory.buffer);
    const head = 4096 - Number(address & 0xfffn);
    if (head >= 8) return vue.getBigUint64(start, true);
    const next = physical(address + BigInt(head));
    if (next === null) return null;
    let value = 0n;
    for (let i = 7; i >= 0; i--) {
      const at = i < head ? start + i : next + (i - head);
      value = (value << 8n) | BigInt(vue.getUint8(at));
    }
    return value;
  }

  /// **Délivrer une exception à l'invité**, comme le processeur le ferait :
  /// la porte lue dans l'IDT, le cadre du mode long posé sur la pile — SS,
  /// RSP, RFLAGS, CS, RIP, puis le code d'erreur pour les vecteurs qui en
  /// portent un —, et RIP sur le gestionnaire. Rend `null` quand c'est fait,
  /// sinon la raison pour laquelle ça ne l'a pas été.
  ///
  /// **La pile change quand elle doit changer**, depuis #257 : une porte qui
  /// nomme une pile d'interruption l'impose toujours, et sinon on en change dès
  /// que le niveau de privilège baisse. Les deux nombres viennent du segment
  /// d'état de tâche, lu derrière le sélecteur du registre de tâche — voir
  /// `kernelStack`. Ce paragraphe disait « aucun segment de tâche n'est
  /// modélisé, donc ni pile d'interruption ni changement d'anneau » ; c'était
  /// vrai, et c'est précisément ce qui arrêtait la machine au saut dans
  /// `/init`, où #256 a mesuré `CS = 0x33` et `TR = 0x40`.
  ///
  /// **L'ordre est celui du cœur Swift**, qui a payé pour l'apprendre : la
  /// pile d'avant est lue avant tout changement, le cadre s'écrit à
  /// l'alignement de seize, et le sélecteur de code n'est remplacé qu'une fois
  /// l'ancien empilé. Une faute *pendant* l'écriture du cadre est rendue
  /// comme telle — c'est une double faute, et la cacher ferait s'arrêter un
  /// noyau « sur place » sans un mot.
  /// **Le code d'erreur d'une faute de page, complété par ce que seul l'hôte
  /// sait.**
  ///
  /// Le module pose le bit de présence et celui d'écriture — il est le seul à
  /// savoir ce que l'accès tentait. Ce commentaire le disait déjà quand c'était
  /// faux : le module posait toujours zéro. Il les pose depuis que sa marche
  /// juge les droits des pages. Il ne dit pas l'anneau : il range le témoin et
  /// rend la main, et c'est ici que CS est lu. Et le chargement d'instruction,
  /// il ne le voit pas du tout : c'est l'hôte qui va chercher les octets d'une
  /// région — et qui lui demande le bit de présence, par `read`.
  function pageFaultCode(base, fetch) {
    const code = BigInt.asUintN(64, globals[SLOTS.segment + 1].value) & 0xffffn;
    let out = base;
    if ((code & 3n) === 3n) out |= USER_FAULT;
    if (fetch) {
      const efer = BigInt.asUintN(64, globals[SLOTS.efer].value);
      const cr4 = BigInt.asUintN(64, globals[SLOTS.control + 3].value);
      if ((efer & NX_ENABLE) !== 0n || (cr4 & SMEP_ENABLE) !== 0n) out |= FETCH_FAULT;
    }
    return out;
  }

  /// **Le dernier octet qu'une lecture de pile peut toucher dans le TSS** : la
  /// fin d'`IST7`, à `0x24 + 6 * 8 + 7`. Un segment plus court ne peut pas
  /// porter les sept piles d'interruption, et rendrait des octets qui ne sont
  /// pas des piles. Le cœur Swift refuse sur la même borne, et c'est de lui
  /// qu'elle vient.
  const TASK_LAST_BYTE = 0x5bn;

  /// **La pile sur laquelle le cadre doit être posé**, lue dans le segment
  /// d'état de tâche que le registre de tâche désigne. Rend un nombre, ou la
  /// chaîne qui dit pourquoi ça n'a pas pu être fait.
  ///
  /// **Le descripteur est relu ici, pas gardé depuis le `ltr`.** L'hôte ne voit
  /// jamais passer un `ltr` : c'est le module qui l'exécute, et il ne laisse
  /// derrière lui que les seize bits du sélecteur. Ce que cette relecture rend
  /// et ce que le silicium aurait gardé ne diffèrent que pour un noyau qui
  /// réécrirait le descripteur sans refaire son `ltr` ; la doc du créneau
  /// `task` porte l'infidélité et ce qu'elle coûterait à corriger.
  ///
  /// **Chaque refus nomme ce qui manque**, parce que le suivant sera diagnostiqué
  /// depuis un relevé de noyau et pas depuis un débogueur. Un segment de tâche
  /// absent, hors de la GDT, du mauvais type, trop court ou non cartographié ne
  /// donnent pas la même correction.
  function kernelStack(level, interruptStack, what) {
    const selector = BigInt.asUintN(64, globals[SLOTS.task].value) & 0xffffn;
    if (selector === 0n) {
      return `${what} avec un changement de pile, et aucun registre de tâche chargé : aucun \`ltr\` n'est passé`;
    }
    const limit = BigInt.asUintN(64, globals[SLOTS.table].value);
    const gdt = BigInt.asUintN(64, globals[SLOTS.table + 1].value);
    // Les trois bits du bas d'un sélecteur ne font pas partie de l'indice.
    const position = selector & ~0x7n;
    if (position + 15n > limit) {
      return `${what} avec un changement de pile : le sélecteur de tâche 0x${selector.toString(16)} est hors de la GDT`;
    }
    const low = peekWord(gdt + position);
    const high = low === null ? null : peekWord(gdt + position + 8n);
    if (high === null) {
      return `une faute pendant la délivrance d'${what} : la GDT n'est pas cartographiée`;
    }
    // Neuf c'est « TSS long disponible », onze « TSS long occupé ». Rien
    // d'autre ne porte de pile, et un descripteur de code lu comme un TSS
    // rendrait une base plausible.
    const kind = (low >> 40n) & 0x1fn;
    if (kind !== 9n && kind !== 11n) {
      return `${what} avec un changement de pile : le descripteur 0x${selector.toString(16)} n'est pas un segment de tâche`;
    }
    // La base en quatre morceaux, la limite en deux : l'héritage du 386, que le
    // mode long n'a pas rangé.
    const taskBase = ((low >> 16n) & 0xff_ffffn) |
      (((low >> 56n) & 0xffn) << 24n) |
      ((high & 0xffff_ffffn) << 32n);
    let taskLimit = (low & 0xffffn) | (((low >> 48n) & 0x0fn) << 16n);
    // Le bit de granularité : posé, la limite compte des pages de quatre
    // kibioctets, et le dernier octet valide est celui du haut de la dernière.
    if ((low & (1n << 55n)) !== 0n) taskLimit = (taskLimit << 12n) | 0xfffn;
    if (taskLimit < TASK_LAST_BYTE) {
      return `${what} avec un changement de pile : le segment de tâche ne porte que ${taskLimit + 1n} octets, il en faut ${TASK_LAST_BYTE + 1n}`;
    }
    // `RSP0` est à quatre et les suivantes de huit en huit ; `IST1` est à 0x24,
    // et les six autres de huit en huit. Ce n'est pas un choix, c'est le format.
    const offset = interruptStack !== 0n
      ? 0x24n + (interruptStack - 1n) * 8n
      : 4n + BigInt(level) * 8n;
    const pile = peekWord(taskBase + offset);
    if (pile === null) {
      return `une faute pendant la délivrance d'${what} : le segment de tâche n'est pas cartographié`;
    }
    return pile;
  }

  function deliver(vector, errorCode, what) {
    const limit = BigInt.asUintN(64, globals[SLOTS.table + 2].value);
    const idt = BigInt.asUintN(64, globals[SLOTS.table + 3].value);
    const at = BigInt(vector) * 16n;
    if (at + 15n > limit) {
      return `${what} sans porte : aucune IDT ne porte le vecteur ${vector}`;
    }
    const low = peekWord(idt + at);
    const high = low === null ? null : peekWord(idt + at + 8n);
    if (high === null) {
      return `une faute pendant la délivrance d'${what} : l'IDT n'est pas cartographiée`;
    }
    if ((low & (1n << 47n)) === 0n) {
      return `${what} sans porte : la porte du vecteur ${vector} n'est pas présente`;
    }
    // Le décalage est en trois morceaux, dispersés par l'héritage du 386.
    const offset = (low & 0xffffn) | ((low >> 32n) & 0xffff0000n) | ((high & 0xffffffffn) << 32n);
    const selector = (low >> 16n) & 0xffffn;
    const kind = (low >> 40n) & 0xfn;
    const interruptStack = (low >> 32n) & 0x7n;
    const code = BigInt.asUintN(64, globals[SLOTS.segment + 1].value) & 0xffffn;
    // **Ce qu'on empile, c'est la pile d'avant**, lue ici avant tout
    // changement : c'est elle que l'`iretq` rendra au programme.
    const stack = BigInt.asUintN(64, globals[4].value);
    const stackSelector = BigInt.asUintN(64, globals[SLOTS.segment + 2].value) & 0xffffn;
    const flags = BigInt.asUintN(64, globals[SLOTS.rflags].value);
    // **Deux raisons d'en changer, et elles ne se recouvrent pas.** Une porte
    // qui nomme une pile d'interruption l'impose toujours ; sinon, on change
    // seulement si le niveau de privilège baisse.
    const target = selector & 3n;
    let top = stack;
    if (interruptStack !== 0n || target < (code & 3n)) {
      const switched = kernelStack(Number(target), interruptStack, what);
      if (typeof switched === "string") return switched;
      top = switched;
      // **Le sélecteur de pile devient nul en même temps**, comme le fait le
      // processeur : en mode long il n'a plus de base ni de limite, et le
      // garder ferait croire au noyau qu'il vient de l'anneau d'où il venait.
      globals[SLOTS.segment + 2].value = 0n;
    }
    const words = [stackSelector, stack, flags, code, rip()];
    if (WITH_ERROR_CODE.has(vector)) words.push(BigInt.asUintN(64, errorCode));
    // **Et l'anneau change avant les empilements, pas après.** Le cadre s'écrit
    // sur la pile du noyau, interdite aux programmes ; le processeur y écrit
    // parce qu'il est déjà passé en anneau zéro à ce moment-là. Le CS d'avant
    // est dans `words` — c'est lui que l'`iretq` rendra.
    globals[SLOTS.segment + 1].value = BigInt.asIntN(64, selector);
    // **Les mots du cadre ne sont jamais à cheval** : le sommet est aligné
    // sur seize, et chaque mot descend de huit. Une seule traduction par mot
    // suffit donc, et c'est la seule écriture de l'hôte.
    let pointer = top & ~0xfn;
    for (const word of words) {
      pointer -= 8n;
      const where = physical(pointer);
      if (where === null) {
        return `une faute pendant la délivrance d'${what} : la pile où le cadre s'écrit n'est pas cartographiée`;
      }
      new DataView(memory.buffer).setBigUint64(where, word, true);
      // Le cadre est une écriture de l'hôte : sur une trame de code, ses
      // régions s'en vont.
      ecrit(where, 8);
    }
    globals[4].value = BigInt.asIntN(64, pointer);
    globals[SLOTS.rip].value = BigInt.asIntN(64, offset);
    let entering = flags & ~(TRAP_FLAG | NESTED_FLAG | RESUME_FLAG);
    if (kind === 0x0en) entering &= ~INTERRUPT_FLAG;
    globals[SLOTS.rflags].value = BigInt.asIntN(64, entering);
    return null;
  }

  // **Poser une région, et l'annoncer dans la correspondance.**
  //
  // **Chaque début de bloc y entre, pas seulement l'entrée.** Ce commentaire a
  // dit le contraire pendant une tranche entière après que le code eut cessé
  // d'être vrai : « seule l'adresse d'entrée y est rangée, l'émetteur ne dit
  // pas où commencent ses blocs ». L'émetteur le dit depuis qu'il exporte
  // `starts`, et la boucle plus bas range une case par bloc. Un commentaire
  // qui décrit l'inverse du code est pire qu'un commentaire absent — celui
  // qui le lit ne va pas vérifier.
  //
  // **La fenêtre d'octets, et pourquoi ces deux tailles.** Le chiffrage vit
  // dans la doc de `Module::resolving_or_why` côté Rust, avec sa date et ce
  // qu'il vaut aujourd'hui. Il était recopié ici, et les deux copies avaient
  // déjà divergé — 89 régions coupées d'un côté, 91 de l'autre, pour la même
  // mesure. Une seule source, donc, et un renvoi.
  //
  // Ce qui ne bouge pas, et qui suffit à lire le code : le rendement décroît
  // vite avec la taille de fenêtre, donc petite d'abord, grande sur demande.
  const WINDOW = 4096;
  const WIDER = 16384;
  // **Combien de blocs une place d'essai doit pouvoir tenir.** Le nombre de
  // blocs d'une région ne se sait qu'une fois son module rendu ; la place où
  // la traduire se choisit avant (`choisir`). Une place rendue d'au moins
  // `PROBABLE` blocs, sinon le haut de la table — où tout tient. Une région
  // plus longue que le trou essayé est retraduite ailleurs
  // (`caches.replacees`).
  //
  // Le noyau Alpine a rencontré le mur de la taille à sa 155ᵉ région, sur son
  // premier `printk` : l'emplacement 4049 d'une table de 4096 créée une fois
  // pour toutes. La plus grande région relevée y posait 203 blocs ; la table
  // grandit maintenant devant chaque région, de ce qu'elle annonce.
  const PROBABLE = 64;

  /// **Lire la fenêtre là où la machine lirait**, et nulle part ailleurs.
  ///
  /// **C'est `physical` qui décide, la même fonction que la délivrance
  /// emploie pour trouver l'IDT.** Elle replie par le masque de la RAM quand
  /// la pagination est éteinte, et marche les quatre niveaux quand elle est
  /// allumée — c'est-à-dire exactement ce que fait le module pour ses propres
  /// accès. Cette lecture-ci repliait *toujours*, et le dépôt l'avait écrit
  /// plutôt que corrigé : « la lecture des instructions n'est pas paginée,
  /// donc RIP est traité comme physique ». Deux façons de traduire la même
  /// adresse, dont une seule consulte les tables.
  ///
  /// Le repli ne tombait juste que parce qu'un noyau est chargé bas dans une
  /// RAM dont la taille divise l'écart entre ses deux formes d'adresse —
  /// `Module::fold` le dit déjà. L'espace utilisateur, lui, vit ailleurs : au
  /// saut dans `/init`, le repli désignait 4096 octets tous nuls.
  ///
  /// **Page par page, parce que deux pages virtuelles voisines n'ont aucune
  /// raison d'avoir des trames voisines.** Une fenêtre qui commence en cours
  /// de page traverse la frontière ; la lire d'un trait rendrait les octets de
  /// la trame *physiquement* suivante, qui appartient à quelqu'un d'autre.
  ///
  /// **Une fenêtre courte n'est pas une erreur** : elle s'arrête à la
  /// première page absente, et le décodeur s'arrêtera là où elle s'arrête.
  /// Rend `null` quand il n'y a rien du tout — pas un tableau vide, que
  /// l'émetteur prendrait pour une région sans instruction.
  ///
  /// **Le témoin de faute et CR2 sont rendus tels qu'ils ont été trouvés.** La
  /// marche les pose quand une entrée manque ; les laisser ferait prendre à
  /// l'invité, plus tard, une faute que *l'hôte* a causée en lisant — et rien
  /// ne la relierait à cette lecture-là.
  ///
  /// Et c'est une **copie**, pas une vue. Une vue sur `memory.buffer` se
  /// détache si la mémoire grandit, et l'invité peut la réécrire pendant
  /// l'aller-retour vers l'application — qui traduirait alors des octets qui
  /// ont bougé sous son nez.
  ///
  /// **C'est un chargement d'instruction**, et la marche le juge comme tel :
  /// en anneau trois, une page du superviseur ne se lit pas plus qu'une page
  /// absente. Ce que la marche a dit de la **première** page reste dans
  /// `unread` — le code d'erreur plus un, comme le témoin —, parce que c'est
  /// lui que la faute de chargement délivre : P quand la page est là et que
  /// le programme n'y a pas droit.
  ///
  /// **Sauf quand l'hôte ne vient pas charger, mais regarder.** `kind` vaut
  /// `SLOTS.walkFetch` pour la fenêtre qu'on va traduire, et c'est le cas par
  /// défaut ; les mesures — `revoir`, la sonde de `surveiller` — passent
  /// `SLOTS.walkMachine`. Elles demandent « quels octets la page porte-t-elle
  /// maintenant ? », pas « l'anneau courant a-t-il le droit d'y prendre une
  /// instruction ? ». Jugées comme un chargement, elles dépendraient de
  /// l'anneau où la machine s'est arrêtée : en anneau trois, une page du
  /// noyau que les tables en service portent bien passerait illisible.
  ///
  /// **Ça ne rend lisible que ce que les tables en service portent.** Un
  /// noyau à isolation des tables — celui d'Alpine — arrêté en anneau trois
  /// tient les tables du programme, où son texte n'est pas cartographié du
  /// tout : là, aucun `kind` n'y change rien. Mesuré sur Alpine à cet arrêt,
  /// 11 030 fenêtres sur 11 080 restent illisibles avec `walkMachine` (11 044
  /// avec `walkFetch`) ; seul `nopti` en rend presque toutes — 9 illisibles.
  function read(address, window, kind = SLOTS.walkFetch) {
    const temoin = globals[SLOTS.fault].value;
    const cr2 = globals[SLOTS.control + 1].value;
    const out = new Uint8Array(window);
    let filled = 0;
    unread = 0n;
    stopped = null;
    luesTrames = [];
    while (filled < window) {
      globals[SLOTS.fault].value = 0n;
      const at = physical(address + BigInt(filled), kind);
      if (at === null) {
        if (filled === 0) unread = globals[SLOTS.fault].value;
        else stopped = { at: address + BigInt(filled), witness: globals[SLOTS.fault].value };
        break;
      }
      // **Le bout de la RAM est une borne dure** : la correspondance des
      // blocs et le tampon de traduction vivent juste au-dessus, et lire plus
      // loin les enverrait à l'application, qui les prendrait pour du code.
      const edge = base - at;
      const take = Math.min(4096 - (at & 0xfff), window - filled, edge);
      if (take <= 0) break;
      luesTrames.push(Math.floor(at / 4096));
      out.set(new Uint8Array(memory.buffer, at, take), filled);
      filled += take;
      if (take === edge) break;
    }
    globals[SLOTS.fault].value = temoin;
    globals[SLOTS.control + 1].value = cr2;
    return filled === 0 ? null : out.slice(0, filled);
  }

  async function install(address) {
    // **Le contexte de la région est celui de l'instant** — l'anneau et
    // l'espace d'adressage où la machine va l'exécuter —, et c'est sous lui
    // que sa fenêtre est lue : `read` juge le chargement avec l'anneau
    // courant.
    const ctx = contexte();
    // **Une place d'essai** (`choisir`) : le haut de la table tant qu'une
    // région ordinaire y tient sous `emplacements`, sinon la plus grande des
    // places rendues si elle a `PROBABLE` blocs, sinon le haut quand même. Le
    // nombre de blocs ne se sait qu'une fois le module rendu ; s'il ne tient
    // pas, la région est retraduite ailleurs, plus bas.
    let slot = choisir(PROBABLE);
    // **Rien à traduire est une réponse, pas un incident.** Elle remonte
    // jusqu'au relevé sous son nom au lieu de se confondre avec un refus de
    // l'émetteur.
    const window = read(address, WINDOW);
    if (window === null) return UNMAPPED;
    let lues = luesTrames;
    // **La fenêtre telle que le traducteur l'a vue**, gardée pour `revoir`.
    // Ce n'est pas celle du fichier ELF : sur le noyau Alpine, 15 761 des
    // 16 189 fenêtres traduites en diffèrent, parce que le noyau a déjà
    // réécrit son propre texte. Comparer à l'image répondrait donc à une
    // autre question que celle qui se pose.
    let lu = window;
    let bytes = await answered(
      () => translate(address, slot, window),
      patience,
    );
    // **Un seul second essai, et seulement sur « il m'en faut plus ».** À
    // l'aveugle, il coûterait un aller-retour sur chaque refus franc ; ici il
    // ne coûte que sur les 0,9 % qui le demandent. Et il n'y en a qu'un : une
    // région qui manque encore de place à seize kibioctets ne se traduira pas
    // en redemandant sans fin.
    if (bytes === MORE) {
      const wider = read(address, WIDER);
      if (wider === null) return UNMAPPED;
      // **Ce qui a arrêté cette lecture-là**, gardé avant que la traduction
      // ne relise quoi que ce soit.
      const cut = stopped;
      lues = luesTrames;
      lu = wider;
      bytes = await answered(
        () => translate(address, slot, wider),
        patience,
      );
      if (bytes === MORE) {
        // **La première instruction est coupée par une page qu'on ne peut
        // pas lire.** Plus d'octets ne viendront pas : la page d'après est
        // absente (ou interdite à l'anneau courant). Sur le silicium, c'est
        // une faute de page sur le chargement de la **suite** de
        // l'instruction — CR2 sur le premier octet de la page qui manque, RIP
        // sur l'instruction — et le noyau pose la page. Alpine s'arrêtait
        // là, « refusée » sur un `48` seul au dernier octet d'une page de
        // busybox. Une coupe sans page qui manque — la fenêtre large lue en
        // entier, ou le bout de la RAM — reste un refus.
        if (cut !== null) return { coupe: cut.at, temoin: cut.witness };
        return null;
      }
    }
    if (bytes === MUTE || bytes === BROKEN) return bytes;
    if (!bytes) return null;
    // **Combien de blocs, et où.** Lu dans les octets avant l'instanciation
    // (`blocsDuModule`) : c'est elle qui écrit les blocs dans la table, à la
    // place gravée dans le module. Une place gravée qui n'est pas celle
    // demandée est une panne de l'application, pas une région.
    let pose = blocsDuModule(bytes);
    if (pose === null || pose.offset !== slot || pose.count <= 0) {
      throw new Error(
        `la région à ${address} ne pose pas ses blocs à l'emplacement ${slot} demandé`,
      );
    }
    // **Faire de la place d'abord** : évincer peut rendre la place essayée
    // plus longue, jamais plus courte.
    faireDeLaPlace(bytes.length);
    await respirerSiBesoin();
    if (!prendre(slot, pose.count)) {
      // **La région ne tient pas dans le trou essayé.** Sa longueur est
      // connue maintenant : `choisir` la reprend avec elle — la plus grande
      // place rendue si elle la tient, sinon le haut —, et une seconde
      // traduction des mêmes octets suit, sur la fenêtre gardée, pas une
      // relecture. Seulement une fois le haut de la table passé, et rare
      // alors : la place d'essai était déjà la plus grande des rendues.
      slot = choisir(pose.count);
      caches.replacees += 1;
      const encore = await answered(() => translate(address, slot, lu), patience);
      if (encore === MUTE || encore === BROKEN) return encore;
      if (!encore || encore === MORE) return null;
      bytes = encore;
      // **Et la place se refait pour sa longueur à elle.** Retraduite pour
      // un autre emplacement, la région n'a pas forcément la même longueur :
      // ses indices de bloc sont des LEB, plus larges au-delà de 63. La place
      // faite pour la première traduction laissait passer la seconde, et le
      // cache tenait au-dessus de sa borne en octets.
      faireDeLaPlace(bytes.length);
      await respirerSiBesoin();
      pose = blocsDuModule(bytes);
      if (pose === null || pose.offset !== slot || !prendre(slot, pose.count)) {
        throw new Error(
          `la région à ${address} ne tient pas à l'emplacement ${slot} qu'on lui a choisi`,
        );
      }
    }
    // **La table grandit devant la région, avant qu'elle ne s'instancie.**
    // C'est l'instanciation qui compare le minimum déclaré à la longueur de
    // la table ; après, il est trop tard. Elle grandit par quarts au moins,
    // pour ne pas payer une croissance par région.
    const wanted = slot + pose.count;
    if (blocks.length < wanted) {
      blocks.grow(Math.max(wanted - blocks.length, blocks.length >> 2));
    }
    let exports;
    try {
      exports = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports).exports;
    } catch (why) {
      // La place prise est rendue : une région qui ne s'instancie pas n'en
      // occupe aucune.
      rendre(slot, pose.count);
      throw why;
    }
    const run = exports.run;
    // **La marche du module, gardée pour la délivrance.** Chaque région
    // paginée exporte la sienne, et elles sont toutes le même code sur la
    // même mémoire et les mêmes globales : la première suffit. L'hôte ne
    // traduit *jamais* par un autre chemin — une seconde marche, écrite ici,
    // finirait par diverger de celle du module sur une grande page ou un bit.
    if (walk === null && exports.walk !== undefined) walk = exports.walk;
    // **Les blocs sont-ils bien là où le module l'a annoncé ?** Le dernier
    // doit être posé : sinon la lecture des octets et l'instanciation ne
    // s'accordent pas, et la place prise ne serait pas la bonne.
    if (blocks.get(slot + pose.count - 1) === null) {
      throw new Error(`la région à ${address} n'a posé aucun bloc à l'emplacement ${slot}`);
    }
    // **Chaque bloc de la région entre dans la correspondance, pas seulement
    // son entrée.**
    //
    // Une cible indirecte qui retombe au milieu d'une région déjà traduite
    // n'y était pas trouvée : le module rendait la main, et cette fonction
    // fabriquait une seconde région qui **recouvre** la première. Correct, et
    // du gaspillage — 1559 des 5514 régions demandées par le noyau Alpine,
    // 28 %, sont à moins de seize octets après une région déjà demandée. Ce
    // sont les octets qui suivent un `call` : les adresses où les `ret`
    // retombent.
    //
    // **Les adresses viennent du module, pas d'un calcul refait ici.** Il
    // exporte `starts(i)`, l'adresse invitée de son bloc numéro `i` — le
    // même vecteur que sa section d'éléments a posé dans la table, donc les
    // deux ne peuvent pas diverger. Les recalculer en JavaScript demanderait
    // un décodeur x86 de ce côté-ci, et une divergence enverrait l'invité
    // dans le mauvais bloc.
    //
    // L'entrée passe **en dernier**, et c'est délibéré : deux blocs de la
    // même région peuvent tomber dans le même seau, et le seau n'a que
    // `tableWays` voies. Celui qui écrit en dernier gagne, et l'entrée est
    // l'adresse qu'on préfère ne jamais perdre — c'est la seule par laquelle
    // toute la région reste atteignable.
    // **Un module sans accesseur ne démarre pas**, au lieu de tourner plus
    // lentement en silence. Tolérer son absence créerait une branche que rien
    // n'exercerait jamais — tous les modules que cet hôte voit sortent du même
    // émetteur, y compris les trois figés de la sonde de l'appareil — et une
    // branche jamais prise est l'endroit exact où un défaut s'installe. C'est
    // le même contrat que la table des blocs et le tampon de traduction :
    // manquer à l'appel se dit franchement.
    if (typeof exports.starts !== "function") {
      throw new Error(
        `le module à ${address} n'exporte pas ses débuts de blocs`,
      );
    }
    // **Les débuts de blocs sont gardés** : l'éviction doit effacer chacune
    // de leurs cases, et seulement les leurs.
    const debuts = new BigUint64Array(pose.count);
    debuts[0] = address;
    for (let rang = 1; rang < pose.count; rang += 1) {
      debuts[rang] = BigInt.asUintN(64, exports.starts(rang));
      ranger(debuts[rang], slot + rang, ctx, false);
    }
    ranger(address, slot, ctx, true);
    // **Les trames d'où vient son code**, celles que la carte marque : les
    // pages de la fenêtre jusqu'au bout de ce que le module a traduit
    // (`extent`), pas la fenêtre entière — la page d'après, souvent des
    // données, ferait retraduire la région à chaque écriture. Hors de
    // l'anneau zéro, la racine des tables en est aussi : la réécrire, c'est
    // changer d'espace d'adressage sous le même contexte.
    if (typeof exports.extent !== "function") {
      throw new Error(`le module à ${address} n'exporte pas son étendue`);
    }
    // Une trame par page de la fenêtre lue, et dans chacune les lignes de
    // `[address, address + extent)`.
    const morceaux = [];
    const debutDansPage = Number(address & 0xfffn);
    const fin = debutDansPage + Math.max(exports.extent(), 1);
    for (let page = 0; page * 4096 < fin && page < lues.length; page += 1) {
      const de = Math.max(debutDansPage, page * 4096) - page * 4096;
      const a = Math.min(fin, (page + 1) * 4096) - page * 4096;
      let bas = 0;
      let haut = 0;
      for (let ligne = Math.floor(de / 64); ligne <= Math.floor((a - 1) / 64); ligne += 1) {
        if (ligne < 32) bas |= 1 << ligne;
        else haut |= 1 << (ligne - 32);
      }
      const deja = morceaux.find((m) => m.trame === lues[page]);
      if (deja !== undefined) {
        deja.bas |= bas;
        deja.haut |= haut;
      } else {
        morceaux.push({ trame: lues[page], bas, haut });
      }
    }
    if (ctx !== SLOTS.contextPresent) {
      const racineDe = Number(BigInt.asUintN(64, globals[SLOTS.control + 2].value) & racine) / 4096;
      const deja = morceaux.find((m) => m.trame === racineDe);
      if (deja !== undefined) {
        deja.bas = -1;
        deja.haut = -1;
      } else {
        morceaux.push({ trame: racineDe, bas: -1, haut: -1 });
      }
    }
    const region = {
      run,
      slot,
      lu,
      adresse: address,
      contexte: ctx,
      debuts,
      octets: bytes.length,
      morceaux,
    };
    marquer(region);
    let ici = espaces.get(ctx);
    if (ici === undefined) {
      ici = new Map();
      espaces.set(ctx, ici);
    }
    ici.set(address, region);
    recentes.add(region);
    tenu.regions += 1;
    tenu.octets += bytes.length;
    caches.traduites += 1;
    const clef = `${ctx}:${address}`;
    if (oubliees.delete(clef)) caches.retraduites += 1;
    caches.pic.regions = Math.max(caches.pic.regions, tenu.regions);
    caches.pic.octets = Math.max(caches.pic.octets, tenu.octets);
    caches.pic.emplacements = Math.max(caches.pic.emplacements, next);
    caches.pic.espaces = Math.max(caches.pic.espaces, espaces.size);
    caches.pic.trames = Math.max(caches.pic.trames, trames.size);
    return region;
  }

  /// L'anneau trois a-t-il déjà été atteint ? C'est l'événement qui vide le
  /// cache de code, une fois. Voir `oublierTout`.
  let sawUser = false;
  /// **Ce que les vidages ont jeté** : combien de vidages, et combien de
  /// régions au total. Lecture ; rien ne se décide dessus.
  const vidages = { fois: 0, regions: 0 };

  /// **Oublier toutes les régions traduites**, une fois, au premier passage en
  /// anneau trois.
  ///
  /// Le noyau réécrit son propre texte pendant qu'il démarre :
  /// `apply_alternatives`, `apply_returns`, les sauts et appels statiques.
  /// Une région traduite **avant** garde l'ancien code, et c'est ce qui
  /// tourne — mesuré sur Alpine 6.18 : 2 001 régions dont la fenêtre a changé
  /// (`revoir`, sous `nopti`). La plupart sont sans effet ici, l'ancien code
  /// étant la forme générique. Une ne l'est pas : dans `error_entry`, la
  /// bascule vers les tables du noyau (`SWITCH_TO_KERNEL_CR3`) est un `jmp`
  /// par-dessus, que le noyau remplace par des `nop` quand l'isolation des
  /// tables est en service. La région d'`asm_common_interrupt` est traduite à
  /// la première interruption d'horloge, **avant** ce remplacement : une
  /// interruption prise en anneau trois gardait les tables du programme, et
  /// `sync_regs` fautait sur la pile du noyau — faute dans la faute, jusqu'à
  /// ce que la pile descende dans l'IDT. Tant que l'horloge était figée, aucune
  /// interruption ne tombait en anneau trois et rien ne le montrait.
  ///
  /// **Tout, et pas seulement ce qui a changé.** Un premier essai relisait
  /// chaque région au moment d'y entrer et n'oubliait que celles dont les
  /// octets avaient bougé : le cache devenait un mélange de code réécrit et de
  /// code d'avant, et ce mélange est pire que l'un ou l'autre — une région
  /// fraîche de `__x86_return_thunk` (devenu `jmp warn_thunk_thunk`) appelée
  /// par une région ancienne qui n'avait pas été réécrite en `ret` :
  /// « Unpatched return thunk in use », puis une oops. Et sous isolation des
  /// tables, à ce moment-là, le texte du noyau ne se relit pas du tout.
  ///
  /// **Pourquoi à ce moment-là** : les réécritures du démarrage
  /// (`alternative_instructions`) sont faites avant que le moindre programme
  /// ne tourne, et rien ne passe en anneau trois avant elles. Le prix est une
  /// seconde traduction de ce qui sert encore — quelques milliers de régions,
  /// une fois.
  ///
  /// **Ce que ça ne couvrait pas** : une réécriture **après** — un saut
  /// statique basculé plus tard, `text_poke`. La carte du code traduit la
  /// voit maintenant (voir `voirEcritures`), comme celles d'avant : Alpine
  /// 6.18 va jusqu'à son shell et ses dix commandes avec `vider: false`
  /// (JOURNAL, 16 novembre 2026), et sans l'avertissement « Unpatched return
  /// thunk in use » que le vidage seul laissait passer. Le vidage reste, par
  /// défaut, pour ce qui s'écrit du dehors sans passer par `ecrit`.
  ///
  /// La carte est remise à zéro avec le reste : plus aucune ligne ne porte de
  /// code traduit, et une écriture sur l'ancien code d'une région oubliée ne
  /// désigne plus rien.
  const oublierTout = () => {
    vidages.fois += 1;
    vidages.regions += known.size;
    // Ce qui est oublié ici est rendu au moteur comme ce qui est évincé :
    // 4 008 régions sur Alpine aux bornes par défaut, 11 074 sur la sonde
    // 6.18 aux bornes d'un million de régions et de quatre gigaoctets. Sans
    // respiration après le vidage, leur code restait résident comme celui
    // d'une région évincée qu'aucune collecte pleine ne rend.
    //
    // **Et la table entière redevient libre** : le haut à zéro, et plus
    // aucun trou. Une place rendue avant le vidage, gardée, serait réemployée
    // par-dessus une région posée depuis au même endroit — qui exécuterait
    // ensuite le code d'une autre.
    evincesDepuis += tenu.octets;
    espaces.clear();
    recentes.clear();
    tenu.regions = 0;
    tenu.octets = 0;
    // La correspondance entière : plus aucune adresse ne mène à un ancien
    // bloc, et le premier saut de module à module rend la main à l'hôte.
    new Uint8Array(memory.buffer, base, SLOTS.tableSlots * SLOTS.tableEntry).fill(0);
    // Les anciens blocs quittent la table, et leurs modules peuvent être
    // rendus à la mémoire : rien ne les désigne plus. Toute la table est
    // libre de nouveau, depuis le bas.
    for (let at = 0; at < next; at += 1) blocks.set(at, null);
    libres.length = 0;
    next = 0;
    // Et plus aucune trame ne porte de code traduit.
    trames.clear();
    carte.fill(0);
    journal[0] = 0;
  };

  /// **Le premier passage en anneau trois, vu une fois.** Rend vrai si le
  /// cache vient d'être vidé : la région en main n'est plus dans `known`, et
  /// l'appelant ne doit plus la faire tourner.
  ///
  /// Le passage a lieu dans une région (`sysretq`, `iretq`) : l'adresse où il
  /// mène, du code de programme, n'a jamais été traduite, donc la région rend
  /// la main en anneau trois. C'est pourquoi la boucle regarde **au retour de
  /// chaque région**, et pas seulement en tête de tour.
  const voirAnneauTrois = () => {
    if (sawUser || !vider) return false;
    if ((BigInt.asUintN(64, globals[SLOTS.segment + 1].value) & 3n) !== 3n) return false;
    sawUser = true;
    oublierTout();
    return true;
  };

  /// **Rendre la main à la page.**
  ///
  /// Une machine qui tourne occupe le seul fil de la page. Tant qu'elle ne
  /// cède pas, **rien d'autre ne peut arriver** : ni un
  /// `requestAnimationFrame` — donc aucun repeint —, ni un toucher, ni un
  /// timer. Un `await` ne suffit pas : attendre une promesse déjà tenue ne
  /// cède qu'aux **micro-tâches**, et un timer n'en est pas une.
  ///
  /// **Un timer, et c'est une correction.** Le premier jet passait par un
  /// `MessageChannel`, sur l'argument que la spécification HTML borne un timer
  /// réarmé à quatre millisecondes alors qu'un message n'est pas borné. Le
  /// raisonnement portait sur la *granularité*, pas sur ce qu'on cherche ici.
  /// Mesuré sous le JavaScriptCore de Bun, à un souffle toutes les huit
  /// millisecondes pendant trois cents :
  ///
  /// | forme                 | souffles | tours de page obtenus |
  /// | --------------------- | -------: | --------------------: |
  /// | `setTimeout(…, 0)`    |       32 |                **32** |
  /// | `MessageChannel`      |       37 |                 **0** |
  /// | `Promise.resolve()`   |       37 |                 **0** |
  ///
  /// Un message est livré **sans laisser passer un timer déjà dû** : il cède
  /// aussi peu qu'une micro-tâche. Il aurait donné une boucle qui a l'air de
  /// respirer et une page toujours gelée — la pire des deux issues.
  ///
  /// **Ce que le timer coûte, et comment le refaire.** Le test
  /// `the_machine_lets_the_page_breathe_while_it_runs` fait tourner le même
  /// travail deux fois — une fois en respirant toutes les huit millisecondes,
  /// une fois jamais — et prouve par RDX que c'est le même. Il imprime
  /// désormais ce qu'il mesurait déjà :
  ///
  ///     cargo test -p wisq-vm --release --test host_loop \
  ///         the_machine_lets_the_page_breathe_while_it_runs -- --nocapture
  ///
  /// Cinq passages le 15 septembre 2026 : **13 à 14 % du débit**, pour 32 à 38
  /// battements de page obtenus contre zéro en apnée. C'est le prix d'une vue
  /// qui répond.
  ///
  /// **Ce paragraphe disait « dix-neuf pour cent », et ce n'est pas une
  /// correction d'erreur.** Ce chiffre-là venait d'un montage décrit ici
  /// — 2 991 417 tours contre 3 679 889 — qu'aucune commande ne refait. Les
  /// deux ne se départagent pas : ce pourcentage dépend de la quantité de
  /// travail qui tient entre deux souffles, et les deux montages n'en portent
  /// pas la même. Ce qui change est qu'il y en a maintenant un qui se relance,
  /// et que **l'instrument tournait déjà à chaque commit en jetant son
  /// nombre**.
  function souffler() {
    return new Promise((settle) => setTimeout(settle, 0));
  }


  return {
    memory,
    globals,
    blocks,
    known,
    /// **Écrire dans la mémoire de l'invité sans passer par lui, et le
    /// dire** : `longueur` octets à l'adresse **physique** `physique`, déjà
    /// écrits. Les régions traduites depuis ces trames sont oubliées ; rend
    /// combien. C'est ce que doit appeler tout ce qui écrit la RAM du dehors
    /// — un chargeur, un test, et demain le disque, dont le DMA écrit des
    /// pages où un programme a pu tourner. Sans cet appel, rien ne le voit.
    ecrit,
    /// **Taper sur le port série** : les octets entrent dans la file de
    /// réception, dans l'ordre, et la ligne quatre monte si l'invité a
    /// autorisé l'interruption de réception. Le shell d'un initramfs lit là.
    ///
    /// **À appeler entre deux `run`**, quand la machine a rendu la main — sur
    /// un `hlt` sans rien pour la réveiller, typiquement : un shell qui
    /// attend une ligne. Le prochain `run` délivre l'interruption avant de
    /// regarder le `hlt`, et l'invité repart.
    send(octets) {
      for (const octet of octets) uart.input.push(octet & 0xff);
      raiseSerial();
    },
    /// **Lire la mémoire de l'invité à une adresse invitée**, à travers les
    /// tables de pages quand elles sont en service — le même lecteur que la
    /// traduction emploie pour aller chercher ses fenêtres d'octets, et pas un
    /// second qui pourrait en différer.
    ///
    /// **Il refuse plutôt que de rendre des zéros.** Une page absente donne
    /// `null`, et un appelant qui prendrait un `null` pour un zéro dirait
    /// « le compteur vaut 0 » là où la vérité est « je n'ai pas pu regarder ».
    /// Le témoin de faute et CR2 sont remis comme ils étaient : regarder ne
    /// doit rien changer à ce que la machine croit.
    ///
    /// Elle existe parce que le pilote de mesure ne savait dire **aucune**
    /// valeur de la mémoire invitée pendant qu'il tournait. #264 a cherché
    /// pourquoi `preempt_count` dérive à `inet_init` sans jamais pouvoir lire
    /// `preempt_count`.
    read,
    /// **Peindre l'image de l'invité dans un tampon que le dessinateur accepte.**
    ///
    /// **Ce n'est pas une recopie, c'est une conversion**, et c'est tout
    /// l'intérêt de cette fonction. Le noyau écrit en **XRGB8888** — les octets
    /// en mémoire sont `B, G, R, X` — parce que c'est ce que `simpledrm` prend
    /// sans rien convertir. Une `ImageData` veut `R, G, B, A`. Passer la
    /// mémoire telle quelle donnerait le rouge et le bleu échangés, et surtout
    /// **un alpha à zéro** : un écran entièrement transparent, c'est-à-dire
    /// rien. La pire panne à diagnostiquer, parce qu'elle ressemble à une
    /// machine qui n'a pas démarré.
    ///
    /// L'opacité est donc **forcée**, et les deux composantes échangées, un mot
    /// de trente-deux bits à la fois plutôt qu'octet par octet.
    ///
    /// **Rien ne traverse vers l'application** : le cadre vit dans cette
    /// mémoire-ci, le dessinateur aussi. C'est ce qui rend l'affichage possible
    /// — trois mégaoctets par image ne passeraient jamais un pont de messages.
    paint(into) {
      if (screen === undefined) throw new Error("aucun cadre n'a été déclaré");
      const at = Number(BigInt(screen.base) & BigInt(base - 1));
      const pixels = screen.width * screen.height;
      if (into.length < pixels * 4) {
        throw new Error(`le tampon reçoit ${into.length} octets pour ${pixels * 4}`);
      }
      const source = new Uint32Array(memory.buffer, at, pixels);
      const cible = new Uint32Array(into.buffer, into.byteOffset, pixels);
      for (let index = 0; index < pixels; index++) {
        const pixel = source[index];
        cible[index] =
          0xff000000 | ((pixel & 0xff) << 16) | (pixel & 0xff00) | ((pixel >> 16) & 0xff);
      }
      return pixels;
    },
    /// **Faire tourner la machine.** Rend pourquoi elle s'est arrêtée, jamais
    /// « rien » : un arrêt sans raison est ce qui rend une panne d'émulateur
    /// impossible à diagnostiquer.
    ///
    /// `breath` est la **respiration**, en millisecondes : au-delà de ce
    /// temps passé sans rendre la main, la boucle cède un tour à la page.
    /// C'est le cadran entre débit et réactivité, et il se règle sur le
    /// **temps** et non sur les tours — une région qui rend la main après un
    /// seul bloc ferait autrement payer une tâche par bloc. Huit
    /// millisecondes tiennent dans une image à soixante hertz.
    ///
    /// **Ce que la respiration ne peut pas découper** : un `region.run(budget)`
    /// est indivisible. Le budget est donc le vrai plancher du gel, et à
    /// 2²⁰ blocs il vaut bien plus que huit millisecondes. Ce que coûte
    /// vraiment un gros budget ne se mesure que sur un appareil.
    /// La case de la correspondance pour cette adresse, et où la table
    /// commence : le relevé peut alors lire ce que la case tient vraiment
    /// (`known`, la région installée à une adresse, est déjà exposée plus
    /// haut). Lecture seule ; rien ne se décide dessus.
    tableSlot,
    tableBase: base,
    /// **Le cache de code** : ses bornes, ce qu'il tient, ses pics, ce qu'il a
    /// évincé et retraduit. Lecture ; rien ne se décide dessus.
    cache: caches,
    /// **Le contexte courant**, celui sous lequel une région serait cherchée
    /// et rangée maintenant (voir `context_tag` côté Rust).
    contexte,
    /// Les deux contrôleurs d'interruptions, pour que le relevé puisse dire ce
    /// qu'ils tiennent — le masque, et la base de vecteur qu'ICW2 a posée.
    /// Lecture ; rien ne se décide dessus.
    pics,
    /// Les trois compteurs du 8254, au même titre et pour la même raison.
    pits,
    /// **Combien d'interruptions de matériel l'hôte a délivrées, et où l'invité
    /// était à la première.** Lecture ; rien ne se décide dessus.
    materiel,
    surveillees,
    vidages,
    uart,
    /// **La carte des périphériques**, telle que `carte` l'a rendue, ou
    /// `null`. C'est par elle que l'application tape, et que le relevé dit
    /// ce que le disque a servi.
    carte: peripheriques,
    /// **Les régions dont les octets ont bougé sous elles.**
    ///
    /// Une région traduite reste dans la table aussi longtemps que la machine
    /// vit. Si l'invité réécrit les octets d'où elle vient — et un noyau le
    /// fait sans arrêt : `text_poke_early`, `apply_alternatives`,
    /// `apply_returns` —, le module en table ne correspond plus à la mémoire,
    /// et c'est l'ancien code qui tourne. Rien ici ne le remarquait, et
    /// personne ne savait si le cas se produit.
    ///
    /// **Et ça ne coûte rien pendant la course.** L'hôte garde la fenêtre
    /// qu'il a lue pour chaque région — une copie qu'il faisait déjà — et
    /// cette fonction la relit à la fin, **par le même chemin** : `read`, donc
    /// les tables de pages quand elles sont en service. Aucun test sur le
    /// chemin d'une écriture, qui est le plus chaud du programme.
    ///
    /// **Ce qu'elle sur-déclare, et c'est dit plutôt que caché** : la fenêtre
    /// fait quatre kibioctets et une région s'arrête souvent avant. Un octet
    /// changé après la dernière instruction compte ici et n'invalide rien.
    /// C'est pourquoi le rapport donne le **décalage** et les deux octets, et
    /// pas seulement l'adresse : sans eux, « trois mille régions périmées »
    /// serait un nombre dont on ne pourrait rien faire.
    ///
    /// **Illisible n'est pas périmé.** Une région que les tables ne portent
    /// plus à la fin — un CR3 qui a changé, une page rendue — ne dit rien sur
    /// ses octets. La confondre avec un changement inventerait des défauts.
    ///
    /// **Et l'anneau de l'arrêt n'y est pour rien.** La relecture se fait en
    /// `SLOTS.walkMachine`, sans juger aucun droit : une page du noyau que
    /// les tables en service portent encore reste comparée quand la machine
    /// s'arrête dans un programme. Lue comme un chargement, elle passait
    /// illisible. Sur Alpine **lancé avec `nopti`**, arrêté en anneau trois :
    /// 11 048 illisibles et 0 périmée avant, 9 et 2 001 après.
    ///
    /// **Mais sous isolation des tables, le texte du noyau n'est pas dans les
    /// tables du programme**, et il reste illisible pour de bon : Alpine tel
    /// quel, au même arrêt, rend 11 030 illisibles et 7 périmées — toutes
    /// dans `.entry.text`, que l'isolation laisse cartographié. Ce zéro-là ne
    /// dit rien du noyau ; `kernel-entry` écrit donc l'anneau et CR3 de la
    /// relecture, et l'arrêt en anneau zéro compte 373 périmées.
    revoir() {
      const changees = [];
      const illisibles = [];
      // **Les régions d'un autre programme ne se relisent pas ici** : les
      // tables en service sont celles d'un autre espace d'adressage, et ce
      // qu'elles portent à cette adresse n'a rien à voir avec la fenêtre
      // traduite. Les compter comme changées inventerait des défauts ; elles
      // sont nommées à part. Celles du noyau (anneau zéro, un seul contexte)
      // et celles de l'espace en service se relisent.
      const ailleurs = [];
      const ici = BigInt.asUintN(64, globals[SLOTS.control + 2].value) & racine;
      for (const [adresse, region] of known) {
        const avant = region.lu;
        if (avant === undefined) continue;
        if (region.contexte !== SLOTS.contextPresent && (BigInt(region.contexte) & racine) !== ici) {
          ailleurs.push(adresse.toString());
          continue;
        }
        const maintenant = read(adresse, avant.length, SLOTS.walkMachine);
        if (maintenant === null || maintenant.length < avant.length) {
          illisibles.push(adresse.toString());
          continue;
        }
        let decalage = -1;
        for (let at = 0; at < avant.length; at += 1) {
          if (avant[at] !== maintenant[at]) {
            decalage = at;
            break;
          }
        }
        if (decalage < 0) continue;
        changees.push({
          adresse: adresse.toString(),
          decalage: String(decalage),
          lu: String(avant[decalage]),
          maintenant: String(maintenant[decalage]),
        });
      }
      return { changees, illisibles, ailleurs };
    },
    async run({ budget = 1n << 20n, rounds = 1 << 16, breath = 8 } = {}) {
      let dernier = performance.now();
      // **Combien de chargements d'instruction ont fauté d'affilée**, sans
      // qu'une seule région s'installe entre les deux. Un noyau qui
      // cartographie à la demande en enchaîne autant qu'il veut — mais entre
      // chacun une région s'installe, et ce compteur retombe. Deux d'affilée
      // veut dire que le gestionnaire est lui-même hors de la carte.
      let unfetchable = 0;
      for (let round = 0; round < rounds; round++) {
        if (performance.now() - dernier >= breath) {
          await souffler();
          dernier = performance.now();
        }
        const here = rip();
        // Une machine posée en anneau trois avant le premier tour (une reprise,
        // un pilote) : le passage n'est passé par aucune région.
        voirAnneauTrois();
        let region = trouver(here);
        if (region !== undefined) {
          servir(region);
        } else {
          region = await install(here);
          // **Trois pannes, trois noms.** « Ça ne marche pas » n'aide
          // personne à chercher : une région que l'émetteur refuse, une
          // application muette et une application qui lève ne se corrigent
          // pas au même endroit.
          if (region === MUTE) {
            return { stopped: "traduction sans réponse", at: here };
          }
          if (region === BROKEN) {
            return { stopped: "traduction en panne", at: here };
          }
          if (region === UNMAPPED) {
            // **Ce n'est pas une panne de l'hôte, c'est l'événement que le
            // noyau attend.** Le texte d'un programme est cartographié à la
            // demande : la première page arrive parce que le processeur faute
            // dessus. S'arrêter ici — ce que faisait #257 — laissait `/init`
            // sur son point d'entrée, `0x401000`, sans que rien ne faute.
            //
            // **CR2 porte l'adresse qu'on n'a pas su lire**, et RIP est
            // déjà dessus : c'est elle que le cadre empile, donc celle que
            // l'`iretq` rejouera, une fois la page posée.
            unfetchable += 1;
            if (unfetchable > 1) {
              // **Deux d'affilée sans qu'une région s'installe entre les
              // deux : c'est le gestionnaire lui-même qui manque.** Sur le
              // silicium c'est une double faute ; ici la délivrance
              // boucherait, et la boucle rendrait « tours épuisés » — un
              // relevé qui ne dit pas ce qui manque.
              return {
                stopped:
                  "une faute pendant la délivrance d'une faute de page sur un " +
                  "chargement d'instruction : le gestionnaire lui-même n'est pas " +
                  "cartographié",
                at: here,
              };
            }
            globals[SLOTS.control + 1].value = BigInt.asIntN(64, here);
            // **Le code d'erreur vient de la marche**, par `read` : P quand
            // la page est là mais réservée au noyau. Il valait toujours zéro,
            // ce qui était juste tant que rien d'autre qu'une page absente
            // ne pouvait arrêter un chargement.
            const why = deliver(
              PAGE_FAULT,
              pageFaultCode(unread === 0n ? 0n : unread - 1n, true),
              "une faute de page sur un chargement d'instruction",
            );
            if (why !== null) return { stopped: why, at: here };
            continue;
          }
          if (region !== null && region.coupe !== undefined) {
            // **La même faute que la précédente, sur la page d'après** : la
            // suite de l'instruction. Le même garde-fou contre une
            // délivrance qui ne mènerait nulle part.
            unfetchable += 1;
            if (unfetchable > 1) {
              return {
                stopped:
                  "une faute pendant la délivrance d'une faute de page sur un " +
                  "chargement d'instruction : le gestionnaire lui-même n'est pas " +
                  "cartographié",
                at: here,
              };
            }
            globals[SLOTS.control + 1].value = BigInt.asIntN(64, region.coupe);
            const why = deliver(
              PAGE_FAULT,
              pageFaultCode(region.temoin === 0n ? 0n : region.temoin - 1n, true),
              "une faute de page sur la suite d'une instruction coupée",
            );
            if (why !== null) return { stopped: why, at: here };
            continue;
          }
          if (region === null) {
            return { stopped: "refusée", at: here };
          }
          unfetchable = 0;
        }
        // **Ce que la région a laissé du budget**, donc ce qu'elle en a
        // consommé. La répartition le décrémente d'un par bloc appelé ; elle
        // le rend depuis la tranche de la famine d'horloge.
        // **Un octet, et seulement si on surveille.** `read` est employé plutôt
        // qu'une lecture directe parce qu'il remet le témoin de faute et CR2
        // comme il les a trouvés : une sonde qui laisserait une faute
        // derrière elle ferait prendre à l'invité, plus tard, une faute que
        // *l'hôte* a causée en mesurant. Et il lit en `SLOTS.walkMachine`,
        // comme `revoir`, parce que la sonde compte ce qui **va tourner**.
        //
        // **Ce choix n'a plus d'effet.** En anneau zéro, le chargement ne
        // juge pas la lecture ; en anneau trois sur une page utilisateur, il
        // réussit. Le seul cas où les deux lectures différaient était un
        // programme qui saute dans une région du noyau déjà traduite : elle
        // était gardée par sa seule adresse et tournait en anneau trois. Elle
        // l'est maintenant sous son contexte (`contexte`), l'anneau compris :
        // depuis l'anneau trois, elle n'est pas trouvée, et c'est le
        // chargement qui faute, comme sur le silicium.
        if (surveiller && region.lu !== undefined) {
          const octet = read(here, 1, SLOTS.walkMachine);
          if (octet !== null && octet[0] !== region.lu[0]) {
            surveillees.entrees += 1n;
            // **Les deux octets, pas seulement le compte.** « Cent vingt mille
            // entrées périmées » ne dit pas si la machine s'en tire ou non ;
            // `f3` contre `66` — un `endbr64` contre un `nop` — le dit. Les
            // garder coûte une entrée de table par région, pas par entrée.
            const vu = surveillees.regions.get(here);
            if (vu === undefined) {
              surveillees.regions.set(here, {
                entrees: 1,
                lu: region.lu[0],
                maintenant: octet[0],
              });
            } else {
              vu.entrees += 1;
              vu.maintenant = octet[0];
            }
          }
        }
        const left = BigInt.asUintN(64, BigInt(region.run(budget)));
        // **Ce que la région a écrit dans des pages de code**, oublié avant
        // toute autre chose : la délivrance qui suit peut entrer dans une
        // région de ces trames. Si c'est elle-même qu'elle a réécrite, elle
        // ne tournera plus.
        if (voirEcritures() && !recentes.has(region)) region = null;
        // **Le passage en anneau trois se voit ici, dès que la région rend la
        // main, et avant toute délivrance.** Le regarder seulement en tête de
        // tour le manquait dès qu'une interruption attendait : la région qui
        // fait le `sysretq` rend la main en anneau trois, la boucle délivre
        // l'IRQ — CS repasse en anneau zéro — et revient en tête de tour sans
        // avoir rien vu. Le gestionnaire tournait alors sur ses traductions
        // d'avant les réécritures, ce que le vidage existe pour empêcher, et
        // le vidage n'avait jamais lieu. Une délivrance de faute ou d'`int`
        // juste après le `sysretq` passe par le même chemin.
        if (voirAnneauTrois()) region = null;
        // **Le temps de l'invité avance ici, et pas dans le module.**
        //
        // Le faire dans le module coûterait un ajout par bloc, payé partout et
        // pour toujours, au bénéfice d'une instruction que le noyau Alpine
        // exécute vingt-huit fois. Cette boucle, elle, vient d'accorder un
        // budget : elle sait ce qu'elle a laissé passer, et l'ajouter est
        // gratuit pour l'invité. C'est l'endroit que la sonde
        // `--example deliver-probe` a désigné pour la délivrance des
        // interruptions, et c'est le même raisonnement.
        //
        // **Le budget entier est ajouté, même quand la région rend la main
        // avant de l'épuiser.** L'horloge avance donc trop vite quand les
        // régions s'enchaînent souvent. Les deux propriétés qui comptaient
        // tiennent toujours — elle ne recule jamais, elle ne stagne jamais —
        // et savoir ce qui a vraiment été consommé demanderait au module de
        // l'écrire, donc un coût par bloc : ce qu'on cherche à éviter.
        //
        // **Et c'est pour cela que l'horloge avance du travail fait.** Le
        // budget entier était ajouté, même quand la région rendait la main
        // après trois blocs. Tant que rien ne délivrait d'interruption, le
        // seul symptôme était une horloge trop rapide, assumée par écrit.
        // Depuis que le 8254 lève IRQ0, cette horloge décide **quand l'invité
        // est interrompu** — et un vrai noyau n'en sortait plus : il entre
        // dans son gestionnaire d'horloge, y traverse des dizaines de régions,
        // chacune un tour, chacune une milliseconde, et à sa sortie plusieurs
        // tics sont dus. Mesuré sur Alpine : 217 lignes de console sans la
        // ligne IRQ0, **77** avec, et 950 000 retours de main sur
        // `irq_entries_start + 256`.
        //
        // **C'est un compte de blocs, pas d'instructions**, et l'horloge de
        // l'invité tourne donc plus lentement qu'un gigahertz annoncé. C'est
        // le bon sens de l'erreur : une horloge lente laisse l'invité
        // travailler, une horloge rapide l'affame. Et l'étalonnage n'en
        // souffre pas — il mesure le **rapport** entre le 8254 et cette
        // horloge, et le 8254 compte contre elle.
        globals[SLOTS.tsc].value = BigInt.asIntN(
          64, globals[SLOTS.tsc].value + (budget - left));
        // **Un redémarrage demandé finit la course**, à la fin de la région
        // qui a tiré la ligne : la machine ne se relance pas d'elle-même, et
        // c'est à qui la conduit d'en refaire une. L'arrêt reste : un `run`
        // de plus le redit.
        if (remiseDemandee) return { stopped: ARRET_REMISE, at: rip() };
        // **Une faute de page est délivrée à l'invité, ici.** La région a posé
        // le témoin, CR2, et rendu la main avec RIP sur l'instruction fautive
        // — qui n'a rien fait, donc qui se rejoue. Le témoin porte le code
        // d'erreur **plus un** (voir `FAULT_SLOT` côté Rust), et il est effacé
        // avant la délivrance : la marche qu'elle emploie peut en poser un
        // autre, et ce serait alors une double faute, nommée. Si la
        // délivrance ne peut pas avoir lieu, le témoin est remis pour que le
        // relevé montre la faute qui l'a arrêtée.
        const fault = globals[SLOTS.fault].value;
        if (fault !== 0n) {
          globals[SLOTS.fault].value = 0n;
          const why = deliver(
            PAGE_FAULT, pageFaultCode(fault - 1n, false), "une faute de page");
          if (why !== null) {
            globals[SLOTS.fault].value = fault;
            return { stopped: why, at: rip() };
          }
          continue;
        }
        // **Un `hlt` attend, ou s'arrête, et l'arrêt se nomme.** Ce
        // commentaire disait que continuer la boucle ferait tourner l'invité
        // « dans le `jmp -2` qui suit toujours un `hlt` », faute d'une
        // interruption que rien ne produisait. Quelque chose en produit : le
        // témoin est effacé par la délivrance, plus bas, au même endroit que
        // celui de la faute. Ce qui reste nommé est le `hlt` que personne ne
        // peut plus réveiller.
        const stop = globals[SLOTS.stop].value;
        // **Une interruption logicielle n'arrête pas la machine : elle est
        // délivrée.** Le module a posé RIP après l'`int`, c'est l'adresse qui
        // s'empile, et c'est là que l'`iretq` du gestionnaire reprend. Sans
        // porte, le témoin est remis et l'arrêt le nomme.
        if (stop !== 0n && (stop & ~0xffn) === STOP_INTERRUPT) {
          globals[SLOTS.stop].value = 0n;
          const why = deliver(Number(stop & 0xffn), 0n, "une interruption logicielle");
          if (why !== null) {
            globals[SLOTS.stop].value = stop;
            return { stopped: why, at: rip() };
          }
          continue;
        }
        // **Un MSR inconnu est une `#GP(0)`, délivrée.** Le module a posé
        // RIP sur l'instruction — une faute, pas un piège — et le numéro dans
        // le témoin. Le noyau Linux rattrape ces fautes par sa table
        // d'exceptions : `-EIO` pour `wrmsr_safe`, un « unchecked MSR access
        // error » sur le port série pour l'autre, et il continue. Sans porte,
        // le témoin est remis et l'arrêt nomme le numéro et le vecteur.
        if (stop !== 0n && (stop >> 32n) === (STOP_MSR >> 32n)) {
          const number = (stop & 0xffffffffn).toString(16);
          globals[SLOTS.stop].value = 0n;
          const why = deliver(
            GENERAL_PROTECTION, 0n,
            `un registre spécifique au modèle que cette machine ne modélise pas (0x${number})`);
          if (why !== null) {
            globals[SLOTS.stop].value = stop;
            return { stopped: why, at: rip() };
          }
          continue;
        }
        // **Un MXCSR aux bits réservés est une `#GP(0)`, délivrée** — à un
        // programme d'anneau trois comme au noyau. RIP est sur l'instruction,
        // rien n'a changé. Sans porte, le témoin est remis et l'arrêt dit
        // pourquoi et quel vecteur manquait.
        if (stop === STOP_MXCSR) {
          globals[SLOTS.stop].value = 0n;
          const why = deliver(
            GENERAL_PROTECTION, 0n,
            "un MXCSR aux bits réservés levés, que ldmxcsr ou fxrstor voulaient charger");
          if (why !== null) {
            globals[SLOTS.stop].value = stop;
            return { stopped: why, at: rip() };
          }
          continue;
        }
        // **Une instruction indéfinie est délivrée, pas un arrêt.** Le module a
        // posé RIP **sur** le `ud2` — une faute, pas un piège : c'est le
        // gestionnaire qui décide d'avancer, et Linux y ajoute lui-même la
        // longueur de l'instruction quand sa table dit « avertissement ».
        // Sans porte, le témoin est remis et l'arrêt le nomme.
        if (stop === STOP_UNDEFINED) {
          globals[SLOTS.stop].value = 0n;
          const why = deliver(INVALID_OPCODE, 0n, "une instruction indéfinie (ud2)");
          if (why !== null) {
            globals[SLOTS.stop].value = stop;
            return { stopped: why, at: rip() };
          }
          continue;
        }
        // **Et voici l'interruption qui vient du dehors.**
        //
        // Les délivrances au-dessus sont toutes synchrones : l'instruction que
        // l'invité vient d'exécuter les a causées, et le module les signale en
        // rendant la main. Celle-ci n'a causé personne. Le temps a passé, le
        // canal zéro du 8254 a fini un tour, le 8259 a routé la ligne, et
        // l'invité est interrompu entre deux instructions.
        //
        // **Trois choses doivent être vraies, et elles sont vérifiées dans cet
        // ordre** : le temps a avancé (il l'a fait juste au-dessus), une ligne
        // est prête, et l'invité accepte d'être interrompu. La troisième est
        // `IF` dans RFLAGS : un noyau l'éteint pour ses sections critiques, et
        // le forcer serait précisément le défaut qu'un `cli` existe pour
        // empêcher.
        //
        // **Le `hlt` s'efface.** C'est écrit depuis #204 à la case du témoin :
        // « c'est ici que la délivrance d'une interruption viendra effacer le
        // hlt ». Un `hlt` dont RIP est déjà après l'instruction reprend donc
        // là où il s'était arrêté, ce qui est exactement ce qu'un noyau
        // attend de sa boucle d'oisiveté.
        //
        // **Rien n'est pris avant que la porte ne soit trouvée.** `takeIrq`
        // met la ligne en service, et une ligne en service qu'aucun
        // gestionnaire n'a vue ne serait jamais acquittée : la ligne serait
        // morte pour le reste de la vie de la machine. L'ordre est donc
        // délivrer d'abord, prendre ensuite.
        raise8254();
        raiseSerial();
        recopierLignes();
        const open =
          (BigInt.asUintN(64, globals[SLOTS.rflags].value) & INTERRUPT_FLAG) !== 0n;
        // **Un `hlt` qui attend le disque cède le fil.** La réponse de
        // l'arrière est une promesse, et une promesse ne se résout que quand
        // la boucle rend la main au moteur : l'attente plus bas, qui avance
        // l'horloge sans céder, aurait sauté de tic en tic sans jamais
        // laisser le disque répondre — et le noyau aurait vu ses lectures
        // expirer. La boucle attend donc la réponse ici, **sans avancer
        // l'horloge** : vu de l'invité, le disque répond sur-le-champ. Ce qui
        // est déjà prêt passe d'abord, sans attendre.
        if (
          stop === STOP_HALTED && open && peripheriques !== null
          && pendingIrq() === null && peripheriques.disque.enVol() > 0
        ) {
          await peripheriques.disque.attendre();
          recopierLignes();
          dernier = performance.now();
        }
        // **Un `hlt` que le matériel peut encore réveiller attend.**
        //
        // Sans ça, le réveil dépendrait du **budget** et non du temps : avec
        // un budget d'un mébi-cycle un tic est déjà là quand l'invité
        // s'arrête, avec mille cycles il faut quatre-vingt-trois tours de
        // roue pour l'atteindre, et la machine se figerait entre les deux.
        // L'horloge avance donc ici, sans qu'aucune région ne tourne — c'est
        // exactement ce que fait un processeur arrêté.
        //
        // **Bornée, et c'est une borne et non une estimation.** `pendingIrq`
        // ne peut rendre `null` indéfiniment que si `wakeable` a menti ;
        // l'attente s'arrête quand même, et le `hlt` se nomme comme avant.
        //
        // **La carte réveille aussi** (`reveil`) : des frappes qui attendent
        // leur tour, une ligne qu'elle tient. Ses lignes sont alors recopiées
        // à chaque pas, le temps passé d'abord ; sinon, pas un appel de plus
        // dans la boucle la plus serrée de la machine.
        const parLaCarte = peripheriques !== null && peripheriques.reveil();
        if (stop === STOP_HALTED && open && (wakeable() || parLaCarte)) {
          const step = budget === 0n ? 1n : budget;
          let patience = 1 << 20;
          while (pendingIrq() === null && patience-- > 0) {
            globals[SLOTS.tsc].value = BigInt.asIntN(
              64, globals[SLOTS.tsc].value + step);
            raise8254();
            if (parLaCarte) recopierLignes();
          }
        }
        const waiting = pendingIrq();
        if (waiting !== null && open) {
          const was = globals[SLOTS.stop].value;
          // **Lue avant la délivrance**, parce que c'est elle qui compte : le
          // cadre empilé la porte, et `deliver` met RIP sur la porte. Lue
          // après, elle dirait l'adresse du gestionnaire — vraie, et sans
          // intérêt, puisque l'IDT la donne déjà.
          const from = rip();
          globals[SLOTS.stop].value = 0n;
          const why = deliver(waiting.vector, 0n, "une interruption de matériel");
          if (why !== null) {
            globals[SLOTS.stop].value = was;
            return { stopped: why, at: rip() };
          }
          takeIrq(waiting);
          // **Comptée après, pas avant.** Une délivrance refusée — pas d'IDT,
          // pas de porte, pas de pile — n'est pas une délivrance, et la
          // compter ferait dire au relevé qu'une interruption est passée là
          // où la machine s'est arrêtée de ne pas pouvoir la passer.
          materiel.delivrees += 1n;
          if (materiel.premiere === null) materiel.premiere = from;
          continue;
        }
        if (stop !== 0n) {
          return { stopped: STOPS[stop] ?? `arrêt de raison inconnue (${stop})`, at: rip() };
        }
        // **RIP inchangé ne veut pas dire bloqué**, et c'est une correction :
        // un anneau dont le budget s'épuise pile sur son point de départ
        // revient à l'adresse d'où il est parti après avoir tourné trois cents
        // fois. Le confondre avec une machine bloquée arrêterait un noyau en
        // pleine boucle.
        //
        // Ce qui distingue les deux est un **bloc de plus** : si un seul bloc
        // ne fait pas bouger RIP, plus rien ne le fera. C'est `ud2`, ou une
        // instruction que l'émetteur ne traduit pas. Le bloc supplémentaire
        // est du vrai travail dans le cas bénin, et il n'est payé que quand
        // RIP retombe sur son point de départ. Une région que le vidage vient
        // d'oublier ne tourne plus : le tour suivant la retraduira.
        if (region !== null && rip() === here) {
          region.run(1n);
          voirEcritures();
          if (rip() === here) {
            return { stopped: "sur place", at: here };
          }
        }
      }
      return { stopped: "tours épuisés", at: rip() };
    },
  };
}

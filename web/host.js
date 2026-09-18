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
/// `STOP_HYPERVISOR`, `STOP_PCID`, `STOP_LDT`, `STOP_DEBUG` — et un nombre que ce tableau ne connaît pas se dit quand
/// même, plutôt que de passer pour « rien ». `STOP_MSR` n'y est pas : il porte
/// le numéro du registre dans ses trente-deux bits bas, et se lit à part.
const STOPS = {
  1n: "arrêtée sur hlt",
  2n: "un sélecteur non nul dans FS ou GS, sans table de descripteurs",
  3n: "arrêtée sur lkgs : la base GS du noyau depuis un sélecteur, sans table de descripteurs",
  4n: "arrêtée sur un appel à l'hyperviseur (vmcall ou vmmcall) : cette machine n'en a pas",
  5n: "arrêtée sur invpcid : purger le tampon par identifiant de contexte, et cette machine n'a pas de PCID",
  6n: "arrêtée sur lldt : une table de descripteurs locale non nulle, sans table globale où la trouver",
  7n: "arrêtée sur une écriture dans un registre de débogage : cette machine n'a pas de points d'arrêt matériels",
};
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

/// **La délivrance d'une faute, et ce qu'elle suppose.**
///
/// Le vecteur de la faute de page est le seul que cette machine produise :
/// c'est le témoin `FAULT_SLOT` qui le dit, posé par la marche du module quand
/// une page manque. Les dix vecteurs qui portent un code d'erreur sont ceux du
/// manuel ; le noyau compte dessus pour retrouver son cadre, et en oublier un
/// décalerait toute la pile de huit octets.
const PAGE_FAULT = 14;
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
  /// Les trois globales de travail de la traduction — l'adresse invitée, son
  /// numéro de page, la case du tampon — puis le témoin de faute.
  translate: 47,
  translateCount: 3,
  fault: 50,
  /// **Le témoin d'arrêt, et sa raison.** Zéro tant que la machine tourne ;
  /// sinon un nombre qui dit **pourquoi** — le module le pose et rend la main,
  /// plutôt que de faire refuser la région entière. C'est ici que la délivrance
  /// d'une interruption viendra effacer le `hlt`.
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
  /// par `rdmsr`, lus par rien : `syscall` n'est pas produite.
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
  globalCount: 60,
  tablePages: 16,
  tableEntry: 16,
  tableSlots: 1 << 16,
  /// **Combien de cases un seau porte.** Une seule case par empreinte faisait
  /// que la seconde adresse installée écrasait la première, qui repassait
  /// ensuite par l'hôte à chaque appel. Deux voies adjacentes par seau, donc :
  /// autant de cases qu'avant, mais une collision ne coûte plus une éviction.
  /// Le pendant exact de `TABLE_WAYS` côté Rust, et un test les compare.
  tableWays: 2,
  /// **Le tampon de traduction**, juste au-dessus de la correspondance, donc
  /// encore plus haut que la RAM. Le module le déclare dans son minimum : un
  /// hôte qui ne le pose pas ne démarre pas, au lieu de piéger au premier
  /// défaut de tampon — et un piège WebAssembly est sans retour.
  tlbPages: 1,
  tlbEntry: 16,
  tlbSlots: 4096,
  mix: 0x9e3779b97f4a7c15n,
};

/// **Combien de pages de 64 Kio allouer pour un module confiné** : la RAM de
/// l'invité, la correspondance, et le tampon de traduction. Le pendant exact de
/// `host_pages` côté Rust, et la seule addition de ce fichier.
///
/// **Pourquoi une fonction pour une addition.** La somme a changé deux fois —
/// la correspondance, puis le tampon — et à chaque fois il a fallu retrouver
/// tous les hôtes qui l'écrivaient à la main. `examples/resolved.rs` a été
/// manqué la seconde fois : il ne s'instanciait plus, imprimait sa panne et
/// sortait avec zéro. Un test refuse maintenant l'addition sur place, ici
/// comme là-bas.
export function hostPages(pages) {
  return pages + SLOTS.tablePages + SLOTS.tlbPages;
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

/// **Le port série, et le strict nécessaire d'un 16550.**
///
/// C'est par là qu'un noyau Linux parle avant d'avoir le moindre pilote : le
/// tout premier `printk` sort en `0x3f8`, un octet à la fois. Rien d'autre du
/// composant n'est implémenté, et c'est délibéré — mais deux registres ne
/// peuvent pas manquer, parce qu'un noyau *attend* sur eux :
///
/// - `0x3f8` en écriture est le registre d'émission. L'octet part.
/// - `0x3fd` en lecture est le registre d'état de ligne. Le noyau y tourne en
///   boucle jusqu'à voir « l'émetteur est libre » avant chaque caractère. Un
///   zéro rendu là ne perdrait pas un octet : il pendrait la machine pour
///   toujours, sur une boucle correcte.
const SERIAL = 0x3f8;
const SERIAL_STATUS = SERIAL + 5;
/// Émetteur vide **et** registre d'émission vide : les deux bits que la boucle
/// d'attente d'un noyau consulte.
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
/// **Ce qui n'est pas modélisé, et qui se verra le jour où ça manquera** : les
/// registres de requête et de service, la priorité, la fin d'interruption.
/// Rien n'en a besoin tant qu'aucune ligne ne monte — et le jour où une ligne
/// montera, c'est la tranche de la délivrance qui les écrira, avec le test qui
/// les exige.
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
    /// Le mode du 8254. Ce noyau n'en programme que deux : le zéro pour
    /// l'étalonnage, le deux pour sa cadence périodique.
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
  };
}

export function machine({
  translate,
  pages,
  screen,
  serial,
  // **La taille de départ de la table des blocs**, pas sa taille : elle
  // grandit devant chaque région qui en a besoin (voir `HEADROOM`).
  regions = 4096,
  patience = 30000,
}) {
  if (!Number.isInteger(pages) || pages <= 0 || (pages & (pages - 1)) !== 0) {
    throw new Error(`la RAM doit être une puissance de deux, pas ${pages}`);
  }
  const memory = new WebAssembly.Memory({ initial: hostPages(pages) });
  const blocks = new WebAssembly.Table({ element: "anyfunc", initial: regions });
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
  /// Charger un diviseur : le compteur repart de son sommet, maintenant.
  const load = (chip, value) => {
    chip.reload = value & 0xffff;
    chip.consumed = 0n;
    chip.openedAt = now();
    chip.latched = null;
    chip.readHigh = false;
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
  env.out = (port, value, width) => {
    const at = Number(port);
    if (at === SERIAL) {
      // Un `out %ax, %dx` vers l'émetteur écrit deux caractères sur un vrai
      // 16550 seulement avec la FIFO ; ici l'octet bas suffit, et le dire est
      // plus honnête que de faire semblant.
      if (serial) serial(Number(value & 0xffn));
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
        // **Le port de commande.** Le bit d'initialisation ouvre la séquence ;
        // tout le reste — fin d'interruption, choix du registre à lire — n'a
        // aucun effet tant qu'aucune ligne ne monte, et est ignoré en le
        // disant plutôt qu'en le taisant.
        if (octet & PIC_INIT) {
          chosen.chip.expects = 2;
          chosen.chip.wantsFour = (octet & PIC_WANTS_ICW4) !== 0;
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
          // ICW3, le câblage de la cascade. Rien ici ne le consulte : il n'y a
          // qu'une machine, et l'esclave ne lève rien.
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
    // Tout le reste tombe dans le vide, comme sur une carte mère sans la
    // carte : une écriture vers un port absent ne fait rien et ne fait pas
    // planter la machine.
    void width;
  };
  env.in = (port, width) => {
    void width;
    const at = Number(port);
    if (at === SERIAL_STATUS) return BigInt(TRANSMITTER_IDLE);
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
      // port de commande rendrait le registre de requête ou celui de service ;
      // les deux sont vides tant qu'aucune ligne ne monte, et zéro est alors
      // la réponse vraie, pas un bouchon.
      return BigInt(chosen.data ? chosen.chip.mask : 0);
    }
    return BigInt(NOBODY_THERE);
  };
  const imports = { env };
  const base = pages * 65536;
  const known = new Map();
  let next = 0;

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

  /// **Une adresse invitée, rendue en adresse de mémoire linéaire — par la
  /// marche du module.** Pagination éteinte, c'est le repli, comme dans
  /// `guest()`. Allumée, c'est `walk`, qui pose le témoin et CR2 quand la page
  /// manque : `null` alors, et c'est à l'appelant de nommer ce qui vient de
  /// fauter pendant qu'il faisait autre chose.
  function physical(address) {
    const paging = (BigInt.asUintN(64, globals[SLOTS.control].value) & PAGING_BIT) !== 0n;
    if (!paging || walk === null) return Number(address & BigInt(base - 1));
    const frame = walk(BigInt.asIntN(64, address));
    if (globals[SLOTS.fault].value !== 0n) return null;
    const page = Number(BigInt.asUintN(32, BigInt(frame)));
    return (page + Number(address & 0xfffn)) & (base - 1);
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
    const entry = physical(gdt + position);
    if (entry === null) {
      return `une faute pendant la délivrance d'${what} : la GDT n'est pas cartographiée`;
    }
    const vue = new DataView(memory.buffer);
    const low = vue.getBigUint64(entry, true);
    const high = vue.getBigUint64(entry + 8, true);
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
    const where = physical(taskBase + offset);
    if (where === null) {
      return `une faute pendant la délivrance d'${what} : le segment de tâche n'est pas cartographié`;
    }
    return vue.getBigUint64(where, true);
  }

  function deliver(vector, errorCode, what) {
    const limit = BigInt.asUintN(64, globals[SLOTS.table + 2].value);
    const idt = BigInt.asUintN(64, globals[SLOTS.table + 3].value);
    const at = BigInt(vector) * 16n;
    if (at + 15n > limit) {
      return `${what} sans porte : aucune IDT ne porte le vecteur ${vector}`;
    }
    const gate = physical(idt + at);
    if (gate === null) {
      return `une faute pendant la délivrance d'${what} : l'IDT n'est pas cartographiée`;
    }
    const vue = new DataView(memory.buffer);
    const low = vue.getBigUint64(gate, true);
    const high = vue.getBigUint64(gate + 8, true);
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
    let pointer = top & ~0xfn;
    for (const word of words) {
      pointer -= 8n;
      const where = physical(pointer);
      if (where === null) {
        return `une faute pendant la délivrance d'${what} : la pile où le cadre s'écrit n'est pas cartographiée`;
      }
      new DataView(memory.buffer).setBigUint64(where, word, true);
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
  // **La marge que la table garde devant la prochaine région**, et pourquoi
  // c'est une borne et non une estimation. Le module déclare pour minimum
  // `emplacement + blocs` sur la table qu'il importe ; une table plus courte
  // ne le laisse pas s'instancier — `LinkError`, sans retour. Or chaque bloc
  // commence à une adresse distincte de la fenêtre, et la fenêtre fait au plus
  // `WIDER` octets : aucune région ne peut poser plus de `WIDER` blocs. Une
  // table qui a toujours `WIDER` entrées libres devant l'emplacement ne refuse
  // donc **jamais** une région pour sa taille. Une entrée est un pointeur :
  // la marge coûte 128 Kio, une fois.
  //
  // Le noyau Alpine a rencontré ce mur à sa 155ᵉ région, sur son premier
  // `printk` : l'emplacement 4049 d'une table de 4096 créée une fois pour
  // toutes. La plus grande région relevée y posait 203 blocs.
  const HEADROOM = WIDER;

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
  function read(address, window) {
    const temoin = globals[SLOTS.fault].value;
    const cr2 = globals[SLOTS.control + 1].value;
    const out = new Uint8Array(window);
    let filled = 0;
    while (filled < window) {
      globals[SLOTS.fault].value = 0n;
      const at = physical(address + BigInt(filled));
      if (at === null) break;
      // **Le bout de la RAM est une borne dure** : la correspondance des
      // blocs et le tampon de traduction vivent juste au-dessus, et lire plus
      // loin les enverrait à l'application, qui les prendrait pour du code.
      const edge = base - at;
      const take = Math.min(4096 - (at & 0xfff), window - filled, edge);
      if (take <= 0) break;
      out.set(new Uint8Array(memory.buffer, at, take), filled);
      filled += take;
      if (take === edge) break;
    }
    globals[SLOTS.fault].value = temoin;
    globals[SLOTS.control + 1].value = cr2;
    return filled === 0 ? null : out.slice(0, filled);
  }

  async function install(address) {
    const slot = next;
    // **Rien à traduire est une réponse, pas un incident.** Elle remonte
    // jusqu'au relevé sous son nom au lieu de se confondre avec un refus de
    // l'émetteur.
    const window = read(address, WINDOW);
    if (window === null) return UNMAPPED;
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
      bytes = await answered(
        () => translate(address, slot, wider),
        patience,
      );
      if (bytes === MORE) return null;
    }
    if (bytes === MUTE || bytes === BROKEN) return bytes;
    if (!bytes) return null;
    // **La table grandit devant la région, avant qu'elle ne s'instancie.**
    // C'est l'instanciation qui compare le minimum déclaré à la longueur de
    // la table ; après, il est trop tard.
    const wanted = slot + HEADROOM;
    if (blocks.length < wanted) blocks.grow(wanted - blocks.length);
    // **Combien de blocs le module pose, on ne le sait qu'après.** L'émetteur
    // ne l'annonce pas, et l'instanciation est ce qui les met dans la table.
    // L'emplacement suivant se lit donc dans la table elle-même.
    const exports = new WebAssembly.Instance(new WebAssembly.Module(bytes), imports).exports;
    const run = exports.run;
    // **La marche du module, gardée pour la délivrance.** Chaque région
    // paginée exporte la sienne, et elles sont toutes le même code sur la
    // même mémoire et les mêmes globales : la première suffit. L'hôte ne
    // traduit *jamais* par un autre chemin — une seconde marche, écrite ici,
    // finirait par diverger de celle du module sur une grande page ou un bit.
    if (walk === null && exports.walk !== undefined) walk = exports.walk;
    next = occupied(slot) + 1;
    if (next <= slot) {
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
    const ranger = (quoi, où, évincer) => {
      // **Une voie libre du seau, sinon la sienne, sinon on évince la
      // première.** Chercher d'abord une voie vide ou déjà à cette adresse,
      // c'est ce qui fait qu'une collision cesse de coûter une éviction :
      // deux adresses de même empreinte tiennent ensemble. Quand les deux
      // voies sont prises par d'autres, il faut bien en sacrifier une — la
      // première, et le défaut redevient ce qu'il était, muet et seulement
      // plus lent.
      const seau = base + tableBucket(quoi) * SLOTS.tableEntry;
      let libre = -1;
      for (let essai = 0; essai < SLOTS.tableWays; essai += 1) {
        const rangee = new BigUint64Array(
          memory.buffer,
          seau + essai * SLOTS.tableEntry,
          1,
        )[0];
        if (rangee === quoi || rangee === 0n) {
          libre = essai;
          break;
        }
      }
      // **Un début de bloc ne chasse jamais une entrée de région.**
      //
      // C'est la leçon de la première mesure de cette tranche, et elle est
      // chiffrée : ranger *toutes* les cases sans distinction a fait passer
      // les retours de main sur `pv_native_irq_disable` de 2938 à 66 340. Dix
      // fois plus d'adresses pour deux voies par seau, et les entrées les plus
      // chaudes se faisaient évincer par des blocs qu'on ne visite qu'une
      // fois. Le noyau allait **moins** loin qu'avant la correction.
      //
      // L'entrée d'une région est la seule adresse par laquelle toute la
      // région reste atteignable ; un début de bloc n'est qu'un raccourci. Une
      // optimisation qui évince une nécessité n'est pas une optimisation.
      if (!évincer && libre === -1) return;
      const at = seau + (libre === -1 ? 0 : libre) * SLOTS.tableEntry;
      new BigUint64Array(memory.buffer, at, 1)[0] = quoi;
      new Int32Array(memory.buffer, at + 8, 1)[0] = où;
    };
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
    for (let bloc = slot + 1; bloc < next; bloc += 1) {
      ranger(BigInt.asUintN(64, exports.starts(bloc - slot)), bloc, false);
    }
    ranger(address, slot, true);
    const region = { run, slot };
    known.set(address, region);
    return region;
  }

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

  // Jusqu'où la table est occupée à partir de `from` : les blocs d'un module
  // s'y posent à l'instanciation, et c'est le seul moyen de savoir combien il
  // en a mis.
  function occupied(from) {
    let last = from - 1;
    for (let index = from; index < blocks.length; index++) {
      if (blocks.get(index) === null) break;
      last = index;
    }
    return last;
  }

  return {
    memory,
    globals,
    blocks,
    known,
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
    /// Les deux contrôleurs d'interruptions, pour que le relevé puisse dire ce
    /// qu'ils tiennent — le masque, et la base de vecteur qu'ICW2 a posée.
    /// Lecture ; rien ne se décide dessus.
    pics,
    /// Les trois compteurs du 8254, au même titre et pour la même raison.
    pits,
    async run({ budget = 1n << 20n, rounds = 1 << 16, breath = 8 } = {}) {
      let dernier = performance.now();
      for (let round = 0; round < rounds; round++) {
        if (performance.now() - dernier >= breath) {
          await souffler();
          dernier = performance.now();
        }
        const here = rip();
        let region = known.get(here);
        if (region === undefined) {
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
            return { stopped: "aucune page derrière l'adresse", at: here };
          }
          if (region === null) {
            return { stopped: "refusée", at: here };
          }
        }
        region.run(budget);
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
        // régions s'enchaînent souvent. C'est assumé : elle n'est calibrée
        // contre rien — cette machine n'a ni PIT ni HPET à quoi se comparer —
        // et les deux propriétés qui comptent tiennent, elle ne recule jamais
        // et elle ne stagne jamais. Savoir ce qui a vraiment été consommé
        // demanderait au module de l'écrire, donc un coût par bloc : ce qu'on
        // cherche justement à éviter.
        globals[SLOTS.tsc].value = BigInt.asIntN(
          64, globals[SLOTS.tsc].value + budget);
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
          const why = deliver(PAGE_FAULT, fault - 1n, "une faute de page");
          if (why !== null) {
            globals[SLOTS.fault].value = fault;
            return { stopped: why, at: rip() };
          }
          continue;
        }
        // **Un `hlt` s'arrête, et l'arrêt se nomme.** Continuer la boucle
        // ferait tourner l'invité dans le `jmp -2` qui suit toujours un `hlt`,
        // et l'écran dirait « ça tourne » d'une machine qui attend une
        // interruption que rien ne produit. La délivrance d'une **interruption**
        // viendra effacer ce témoin-là, au même endroit que celle de la faute.
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
        // RIP retombe sur son point de départ.
        if (rip() === here) {
          region.run(1n);
          if (rip() === here) {
            return { stopped: "sur place", at: here };
          }
        }
      }
      return { stopped: "tours épuisés", at: rip() };
    },
  };
}

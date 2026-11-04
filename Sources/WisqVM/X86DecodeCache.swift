import Foundation

/// Les instructions déjà décodées, par leur place en mémoire physique.
///
/// **Le décodeur était le premier poste du démarrage.** Échantillonné avec
/// `gdb` pendant un vrai démarrage d'Alpine, il occupait à peu près deux
/// échantillons sur cinq : un noyau et ses programmes repassent sans cesse sur
/// les mêmes boucles, et chaque passage relisait préfixes, ModRM et immédiat
/// d'une instruction déjà lue mille fois.
///
/// **Rien à invalider, par construction.** Une entrée garde les octets
/// qu'elle a décodés, et elle ne sert que s'ils sont encore là, comparés à
/// chaque lecture — deux chargements de huit octets et un masque. Un
/// programme qui réécrit son code, un module chargé à la place d'un autre, une
/// page rendue à quelqu'un d'autre : l'entrée ne correspond plus, et
/// l'instruction est décodée à nouveau. Il n'y a ni écriture à surveiller ni
/// moment à choisir pour vider.
///
/// **La case est choisie par l'adresse physique**, pas virtuelle : deux
/// espaces d'adressage qui montrent le même code partagent l'entrée. Et il n'y
/// a pas de clé à comparer : le décodage ne dépend que des octets, si bien que
/// deux adresses qui tombent dans la même case avec les mêmes octets ont la
/// même instruction. Ce sont les octets qui font foi, eux seuls.
///
/// Une classe, et pas une valeur : `X86Core` est une structure que l'on
/// copie, et un cache recopié à chaque copie coûterait plus qu'il ne rend. Le
/// partager entre deux copies est sans risque, puisque chacune vérifie les
/// octets de sa propre mémoire.
final class X86DecodeCache: @unchecked Sendable {
    /// **65 536 cases.** Avec 8192, le premier milliard d'instructions (le
    /// noyau) manquait 3 % de ses lectures, mais le démarrage complet en
    /// manquait 21 % : les programmes de l'espace utilisateur, `apk` et
    /// OpenRC, s'ajoutent au noyau et ne tiennent plus. Avec 65 536, il ne
    /// manque plus que 4,3 % des lectures, et le démarrage complet passe de
    /// 615 s à 590 s.
    ///
    /// **Puis 131 072.** Fedora a plus de code chaud qu'Alpine : sur
    /// 100 millions d'instructions reprises à 18 milliards de son démarrage,
    /// 5,2 millions de décodages — un sur vingt — étaient des collisions. En
    /// doublant les cases, 600 millions d'instructions passent de 36,5 s à
    /// 33,8 s (médiane de quatre) ; en les quadruplant, 33,8 s aussi. Le
    /// double, donc : 131 072 cases de soixante-quatre octets, une ligne de
    /// cache chacune depuis que les masques se déduisent de la longueur
    /// (voir `Entry`), soit 8,0 Mio. `footprint` le borne, et un test relit
    /// ce chiffre-ci.
    static let slots = 1 << 17

    /// Ce que le cache occupe.
    static var footprint: Int { slots * MemoryLayout<Entry>.stride }

    /// **Une case d'un seul tenant.** Les octets, leurs masques et
    /// l'instruction ont d'abord été rangés dans cinq tableaux séparés : une
    /// lecture touchait alors jusqu'à cinq lignes de cache du processeur
    /// hôte, loin les unes des autres dès que le cache a grandi à 6 Mio.
    /// Côte à côte, une case tient en 96 octets, soit deux lignes au plus.
    ///
    /// **Une seule ligne, désormais.** Les deux masques se déduisent de la
    /// longueur de l'instruction : la case perd seize octets et tient en 64,
    /// alignée sur 64 — une ligne de cache de l'hôte par lecture, au lieu
    /// de deux pour une case de 72 octets à cheval. Le profil du démarrage
    /// de Void plaçait la première lecture de la case en tête de `run`.
    struct Entry {
        var low: UInt64
        var high: UInt64
        var instruction: X86Instruction
        /// Le bourrage jusqu'à 64 octets : sans lui, une case de 56 octets
        /// sur huit en enjamberait deux lignes.
        var padding: UInt64 = 0
    }

    /// Les masques d'une instruction de `length` octets sur les deux mots de
    /// seize octets lus : ce qui compte de chacun. Seize octets ou plus (la
    /// case vide) : tout compte, et c'est la garde de longueur qui la refuse.
    @inline(__always)
    static func masks(length: Int) -> (low: UInt64, high: UInt64) {
        let low: UInt64 = length >= 8 ? .max : (1 &<< UInt64(8 &* length)) &- 1
        let high: UInt64 = length <= 8 ? 0
            : (length >= 16 ? .max : (1 &<< UInt64(8 &* (length &- 8))) &- 1)
        return (low, high)
    }

    private let entries: UnsafeMutablePointer<Entry>

    /// **Ce que porte une case vide** : une instruction d'un octet de plus que
    /// la plus longue qui existe. Ses octets nuls ne passent que devant seize
    /// octets nuls, et sa longueur ne tient de toute façon jamais dans ce qui reste
    /// lisible — `available` ne dépasse pas `maximumLength` —, et c'est la
    /// garde de longueur, déjà là, qui la refuse.
    ///
    /// Une case vide se reconnaissait à son masque nul, par un test à chaque
    /// lecture du cache : trois instructions de l'hôte par instruction de
    /// l'invité, pour un cas qui n'arrive qu'au tout début.
    static let emptySlot = X86Instruction(
        prefixMask: 0, rex: nil, vexBytes: (0, 0, 0), vexCount: 0, map: .oneByte, opcode: 0x90,
        modrm: nil, sib: nil, displacementBytes: 0, displacement: 0, immediateBytes: 0,
        immediate: 0, length: X86Instruction.maximumLength + 1)

    /// Combien de lectures ont dû décoder leur instruction : ce qui dit si le
    /// cache sert, plutôt que de le supposer. Celles qui l'ont trouvée ne se
    /// comptent plus ici — voir `X86Core.decodeCacheHits`.
    ///
    /// **Le compte des trouvailles est sorti du chemin chaud.** C'était une
    /// écriture en mémoire à chaque instruction de l'invité, deux instructions
    /// de l'hôte sur la vingtaine que coûte une lecture du cache, pour un
    /// chiffre qui ne sert qu'à un rapport. Les échecs, eux, se comptent sur le
    /// chemin froid, qui décode de toute façon.
    var misses: UInt64 { counts[1] }

    /// **Les compteurs derrière un pointeur**, et pas en `var` de la
    /// classe. Une propriété modifiable d'une classe fait vérifier chaque
    /// accès par le contrôle d'exclusivité de Swift, un appel à
    /// `swift_beginAccess` à chaque instruction. Sur le premier milliard
    /// d'instructions du démarrage d'Alpine : 96,8 s avec ces deux `var`,
    /// 93,5 s derrière le pointeur.
    private let counts: UnsafeMutablePointer<UInt64>

    init() {
        counts = .allocate(capacity: 2)
        counts.initialize(repeating: 0, count: 2)
        // Alignées sur 64 : une case, une ligne.
        entries = UnsafeMutableRawPointer
            .allocate(byteCount: Self.slots * MemoryLayout<Entry>.stride, alignment: 64)
            .bindMemory(to: Entry.self, capacity: Self.slots)
        entries.initialize(repeating: Entry(low: 0, high: 0, instruction: Self.emptySlot),
                           count: Self.slots)
    }

    deinit {
        counts.deallocate()
        entries.deinitialize(count: Self.slots)
        UnsafeMutableRawPointer(entries).deallocate()
    }

    /// L'instruction qui commence à `start`, si la case en tient une, si ses
    /// octets sont ceux qui sont là, et si elle tient dans les `available`
    /// octets que la lecture s'autorise. Seize octets doivent tenir dans la
    /// mémoire : au bord, on décode comme avant.
    ///
    /// **La borne n'est pas redondante.** Sans pagination, une instruction se
    /// lit sur quinze octets contigus, au travers d'une limite de page ; avec,
    /// elle s'arrête à la page et sa suite vient de la page *virtuellement*
    /// voisine. Une entrée remplie avant que le noyau n'active la pagination
    /// serait sinon rendue telle quelle, avec ses octets d'une autre trame.
    @inline(__always)
    func lookup(_ bytes: UnsafeMutablePointer<UInt8>, at start: Int, size: Int,
                available: Int) -> X86Instruction? {
        lookupEntry(bytes, at: start, size: size, available: available)?.pointee.instruction
    }

    /// La même recherche, qui rend **l'entrée** plutôt qu'une copie de son
    /// instruction. `run` passe `entry.pointee.instruction` tel quel à
    /// l'exécution : une instruction décodée pèse près de cent octets, et la
    /// rendre par valeur la recopiait deux fois à chaque instruction, dans un
    /// optionnel puis dans la variable de `run`. L'entrée ne bouge pas pendant
    /// l'exécution : seul `run` range, et seulement avant d'exécuter.
    @inline(__always)
    func lookupEntry(_ bytes: UnsafeMutablePointer<UInt8>, at start: Int, size: Int,
                     available: Int) -> UnsafeMutablePointer<Entry>? {
        // `&-` : la taille de la mémoire n'est jamais négative, et une
        // soustraction vérifiée coûtait une branche à chaque instruction.
        guard start <= size &- 16 else { return nil }
        let slot = start & (Self.slots - 1)
        let entry = entries + slot
        // Pas de test de la case vide : voir `emptySlot`.
        let raw = UnsafeRawPointer(bytes + start)
        let first = raw.loadUnaligned(as: UInt64.self)
        let second = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
        let mask = Self.masks(length: entry.pointee.instruction.length)
        guard (first ^ entry.pointee.low) & mask.low == 0,
              (second ^ entry.pointee.high) & mask.high == 0
        else {
            counts[1] &+= 1
            return nil
        }
        guard entry.pointee.instruction.length <= available else {
            counts[1] &+= 1
            return nil
        }
        return entry
    }

    /// Range une instruction tout juste décodée à `start`.
    @inline(__always)
    func store(_ instruction: X86Instruction, _ bytes: UnsafeMutablePointer<UInt8>,
               at start: Int, size: Int) {
        guard start <= size &- 16 else { return }
        let slot = start & (Self.slots - 1)
        let raw = UnsafeRawPointer(bytes + start)
        let mask = Self.masks(length: instruction.length)
        entries[slot] = Entry(
            low: raw.loadUnaligned(as: UInt64.self) & mask.low,
            high: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self) & mask.high,
            instruction: instruction)
    }
}

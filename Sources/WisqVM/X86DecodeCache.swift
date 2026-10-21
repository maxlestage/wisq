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
    /// double, donc, pour 9,0 Mio : 131 072 cases de soixante-douze octets,
    /// depuis que l'instruction tient en quarante. C'est la moitié de plus
    /// que les 6 Mio qu'en prenaient 65 536 cases quand elle en pesait
    /// soixante-quatre, et pas le même prix. `footprint` le borne, et un
    /// test relit ce chiffre-ci.
    static let slots = 1 << 17

    /// Ce que le cache occupe.
    static var footprint: Int { slots * MemoryLayout<Entry>.stride }

    /// **Une case d'un seul tenant.** Les octets, leurs masques et
    /// l'instruction ont d'abord été rangés dans cinq tableaux séparés : une
    /// lecture touchait alors jusqu'à cinq lignes de cache du processeur
    /// hôte, loin les unes des autres dès que le cache a grandi à 6 Mio.
    /// Côte à côte, une case tient en 96 octets, soit deux lignes au plus.
    struct Entry {
        var low: UInt64
        var high: UInt64
        var lowMask: UInt64
        var highMask: UInt64
        var instruction: X86Instruction
    }

    private let entries: UnsafeMutablePointer<Entry>

    /// Combien de lectures ont trouvé leur instruction, et combien ont dû la
    /// décoder : ce qui dit si le cache sert, plutôt que de le supposer.
    var hits: UInt64 { counts[0] }
    var misses: UInt64 { counts[1] }

    /// **Les deux compteurs derrière un pointeur**, et pas en `var` de la
    /// classe. Une propriété modifiable d'une classe fait vérifier chaque
    /// accès par le contrôle d'exclusivité de Swift, un appel à
    /// `swift_beginAccess` à chaque instruction. Sur le premier milliard
    /// d'instructions du démarrage d'Alpine : 96,8 s avec ces deux `var`,
    /// 93,5 s derrière le pointeur.
    private let counts: UnsafeMutablePointer<UInt64>

    init() {
        counts = .allocate(capacity: 2)
        counts.initialize(repeating: 0, count: 2)
        // Une instruction quelconque, jamais rendue : un masque nul dit que
        // la case est vide — toute instruction a au moins un octet.
        let filler = try? X86Decoder.decode([0x90])
        entries = .allocate(capacity: Self.slots)
        entries.initialize(repeating: Entry(low: 0, high: 0, lowMask: 0, highMask: 0,
                                            instruction: filler!),
                           count: Self.slots)
    }

    deinit {
        counts.deallocate()
        entries.deinitialize(count: Self.slots)
        entries.deallocate()
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
        guard entry.pointee.lowMask != 0 else {
            counts[1] &+= 1
            return nil
        }
        let raw = UnsafeRawPointer(bytes + start)
        let first = raw.loadUnaligned(as: UInt64.self)
        let second = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
        guard (first ^ entry.pointee.low) & entry.pointee.lowMask == 0,
              (second ^ entry.pointee.high) & entry.pointee.highMask == 0
        else {
            counts[1] &+= 1
            return nil
        }
        guard entry.pointee.instruction.length <= available else {
            counts[1] &+= 1
            return nil
        }
        counts[0] &+= 1
        return entry
    }

    /// Range une instruction tout juste décodée à `start`.
    @inline(__always)
    func store(_ instruction: X86Instruction, _ bytes: UnsafeMutablePointer<UInt8>,
               at start: Int, size: Int) {
        guard start <= size &- 16 else { return }
        let slot = start & (Self.slots - 1)
        let length = instruction.length
        let raw = UnsafeRawPointer(bytes + start)
        let maskLow: UInt64 = length >= 8 ? .max : (1 << UInt64(8 * length)) - 1
        let maskHigh: UInt64 = length <= 8 ? 0
            : (length >= 16 ? .max : (1 << UInt64(8 * (length - 8))) - 1)
        entries[slot] = Entry(
            low: raw.loadUnaligned(as: UInt64.self) & maskLow,
            high: raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self) & maskHigh,
            lowMask: maskLow, highMask: maskHigh, instruction: instruction)
    }
}

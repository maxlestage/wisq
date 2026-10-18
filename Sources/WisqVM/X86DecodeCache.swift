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
    static let slots = 1 << 16

    private let low: UnsafeMutablePointer<UInt64>
    private let high: UnsafeMutablePointer<UInt64>
    private let lowMask: UnsafeMutablePointer<UInt64>
    private let highMask: UnsafeMutablePointer<UInt64>
    private let instructions: UnsafeMutablePointer<X86Instruction>

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
        let count = Self.slots
        counts = .allocate(capacity: 2)
        counts.initialize(repeating: 0, count: 2)
        low = .allocate(capacity: count)
        low.initialize(repeating: 0, count: count)
        high = .allocate(capacity: count)
        high.initialize(repeating: 0, count: count)
        lowMask = .allocate(capacity: count)
        lowMask.initialize(repeating: 0, count: count)
        highMask = .allocate(capacity: count)
        highMask.initialize(repeating: 0, count: count)
        instructions = .allocate(capacity: count)
        // Une instruction quelconque, jamais rendue : un masque nul dit que
        // la case est vide — toute instruction a au moins un octet.
        let filler = try? X86Decoder.decode([0x90])
        instructions.initialize(repeating: filler!, count: count)
    }

    deinit {
        low.deallocate()
        high.deallocate()
        lowMask.deallocate()
        highMask.deallocate()
        counts.deallocate()
        instructions.deinitialize(count: Self.slots)
        instructions.deallocate()
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
        guard start <= size - 16 else { return nil }
        let slot = start & (Self.slots - 1)
        guard lowMask[slot] != 0 else {
            counts[1] &+= 1
            return nil
        }
        let raw = UnsafeRawPointer(bytes + start)
        let first = raw.loadUnaligned(as: UInt64.self)
        let second = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
        guard (first ^ low[slot]) & lowMask[slot] == 0,
              (second ^ high[slot]) & highMask[slot] == 0
        else {
            counts[1] &+= 1
            return nil
        }
        let instruction = instructions[slot]
        guard instruction.length <= available else {
            counts[1] &+= 1
            return nil
        }
        counts[0] &+= 1
        return instruction
    }

    /// Range une instruction tout juste décodée à `start`.
    @inline(__always)
    func store(_ instruction: X86Instruction, _ bytes: UnsafeMutablePointer<UInt8>,
               at start: Int, size: Int) {
        guard start <= size - 16 else { return }
        let slot = start & (Self.slots - 1)
        let length = instruction.length
        let raw = UnsafeRawPointer(bytes + start)
        let maskLow: UInt64 = length >= 8 ? .max : (1 << UInt64(8 * length)) - 1
        let maskHigh: UInt64 = length <= 8 ? 0
            : (length >= 16 ? .max : (1 << UInt64(8 * (length - 8))) - 1)
        low[slot] = raw.loadUnaligned(as: UInt64.self) & maskLow
        high[slot] = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self) & maskHigh
        lowMask[slot] = maskLow
        highMask[slot] = maskHigh
        instructions[slot] = instruction
    }
}

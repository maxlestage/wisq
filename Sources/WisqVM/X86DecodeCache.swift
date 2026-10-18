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
/// **La clé est physique**, pas l'adresse virtuelle : deux espaces d'adressage
/// qui montrent le même code partagent l'entrée, et deux qui montrent des
/// codes différents à la même adresse virtuelle ne se confondent pas. La
/// place dans la page est la même des deux côtés, donc la borne de page que le
/// décodeur a respectée en remplissant l'entrée vaut aussi en la relisant.
///
/// Une classe, et pas une valeur : `X86Core` est une structure que l'on
/// copie, et un cache recopié à chaque copie coûterait plus qu'il ne rend. Le
/// partager entre deux copies est sans risque, puisque chacune vérifie les
/// octets de sa propre mémoire.
final class X86DecodeCache: @unchecked Sendable {
    static let slots = 1 << 13

    private let keys: UnsafeMutablePointer<Int>
    private let low: UnsafeMutablePointer<UInt64>
    private let high: UnsafeMutablePointer<UInt64>
    private let lowMask: UnsafeMutablePointer<UInt64>
    private let highMask: UnsafeMutablePointer<UInt64>
    private let instructions: UnsafeMutablePointer<X86Instruction>

    /// Combien de lectures ont trouvé leur instruction, et combien ont dû la
    /// décoder : ce qui dit si le cache sert, plutôt que de le supposer.
    private(set) var hits: UInt64 = 0
    private(set) var misses: UInt64 = 0

    init() {
        let count = Self.slots
        keys = .allocate(capacity: count)
        keys.initialize(repeating: 0, count: count)
        low = .allocate(capacity: count)
        low.initialize(repeating: 0, count: count)
        high = .allocate(capacity: count)
        high.initialize(repeating: 0, count: count)
        lowMask = .allocate(capacity: count)
        lowMask.initialize(repeating: 0, count: count)
        highMask = .allocate(capacity: count)
        highMask.initialize(repeating: 0, count: count)
        instructions = .allocate(capacity: count)
        // Une instruction quelconque, jamais rendue : la clé à zéro dit que
        // la case est vide.
        let filler = try? X86Decoder.decode([0x90])
        instructions.initialize(repeating: filler!, count: count)
    }

    deinit {
        keys.deallocate()
        low.deallocate()
        high.deallocate()
        lowMask.deallocate()
        highMask.deallocate()
        instructions.deinitialize(count: Self.slots)
        instructions.deallocate()
    }

    /// L'instruction qui commence à `start`, si la case la connaît, si ses
    /// octets sont encore ceux-là, et si elle tient dans les `available`
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
        guard keys[slot] == start &+ 1 else {
            misses &+= 1
            return nil
        }
        let raw = UnsafeRawPointer(bytes + start)
        let first = raw.loadUnaligned(as: UInt64.self)
        let second = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
        guard (first ^ low[slot]) & lowMask[slot] == 0,
              (second ^ high[slot]) & highMask[slot] == 0
        else {
            misses &+= 1
            return nil
        }
        let instruction = instructions[slot]
        guard instruction.length <= available else {
            misses &+= 1
            return nil
        }
        hits &+= 1
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
        keys[slot] = start &+ 1
        low[slot] = raw.loadUnaligned(as: UInt64.self) & maskLow
        high[slot] = raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self) & maskHigh
        lowMask[slot] = maskLow
        highMask[slot] = maskHigh
        instructions[slot] = instruction
    }
}

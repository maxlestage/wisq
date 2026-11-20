import Foundation

/// **Des blocs de formes courtes, décodés d'un tenant.**
///
/// Le cache de décodage range une instruction par case, à l'adresse où elle
/// commence : deux instructions qui se suivent sont à deux endroits d'une
/// table de neuf mébioctets, et `run` refait pour chacune la page, la case,
/// la comparaison de ses octets et la garde de sa longueur — environ quatre-
/// vingts instructions de l'hôte avant d'exécuter quoi que ce soit, et une
/// ligne de cache à faire venir à chaque fois.
///
/// Un bloc, c'est une suite de **formes courtes** qui se suivent dans une
/// même page — huit au plus, sur trente-deux octets au plus —, rangées côte à
/// côte. `run` le trouve une fois, compare une fois ses trente-deux octets à
/// ceux de la mémoire, et exécute ses instructions l'une après l'autre.
///
/// **Ce qui garde le cœur exact.**
///
/// - *Les octets sont comparés à l'entrée*, comme le fait le cache de
///   décodage : un code réécrit — par l'invité, par un périphérique, par une
///   reprise — ne retrouve pas son bloc. Trente-deux octets sont comparés
///   depuis le début, même si le bloc en occupe moins : ce qui suit a pu
///   changer sans que le bloc soit faux, et il est alors refait pour rien,
///   jamais exécuté à tort.
/// - *Après une écriture en mémoire dans le bloc* (`mov` vers la mémoire,
///   `push`), les octets sont recomparés avant l'instruction suivante : un
///   bloc qui se réécrit lui-même s'arrête là, et la suite se relit.
/// - *Rien qu'en mode 64 bits* : une forme courte n'existe pas ailleurs, et
///   les mêmes octets ne se lisent pas pareil en mode compatibilité.
/// - *Rien au-delà de la page* : une instruction à cheval sur deux pages
///   n'entre dans aucun bloc.
///
/// Un bloc s'arrête avant la première instruction qui n'est pas une forme
/// courte, et après un saut sans condition, un appel ou un retour. Un saut
/// conditionnel reste dedans : pris, on sort ; non pris, on continue.
final class X86BlockCache: @unchecked Sendable {
    /// 16 384 blocs de 384 octets : 6 Mio d'adresses, dont seules les pages
    /// touchées deviennent résidentes (`calloc`).
    static let slots = 1 << 15
    static var stride: Int { 384 }
    static var capacity: Int { 8 }
    /// Ce qu'un bloc couvre au plus, et ce qui est comparé à chaque entrée.
    static var span: Int { 32 }

    // La forme d'une case : la clef (le début, plus un — zéro est la case
    // vide), le nombre d'instructions, les drapeaux, les quatre mots
    // d'origine, puis les instructions.
    static var countOffset: Int { 8 }
    static var flagsOffset: Int { 9 }
    static var wordsOffset: Int { 16 }
    static var instructionsOffset: Int { 48 }

    /// Le bloc s'est arrêté devant une instruction qui n'est pas une forme
    /// courte : inutile de chercher un bloc à cet endroit.
    static var endsBeforeGeneral: UInt8 { 1 }

    static var footprint: Int { slots * stride }

    /// **`run` tient ce pointeur, pas l'objet.** Une référence à la classe
    /// gardée dans une variable de la boucle se payait d'un compte de
    /// références à chaque bloc ; mesuré, le démarrage d'Alpine passait de
    /// 30 s à 37 s. Les fonctions qui cherchent, comparent et rangent sont
    /// donc statiques, sur ce pointeur.
    let storage: UnsafeMutableRawPointer
    /// Les blocs construits : ce qui dit si le cache sert ou s'il tourne.
    /// Le compte vit au bout de la table, où `build` le trouve.
    var builds: UInt64 { (storage + Self.slots * Self.stride).load(as: UInt64.self) }

    init() {
        precondition(MemoryLayout<X86Instruction>.stride == 40)
        precondition(Self.instructionsOffset + Self.capacity * 40 <= Self.stride)
        // Une case de plus : le compte des blocs rangés, au bout.
        guard let memory = calloc(Self.slots + 1, Self.stride) else { fatalError("mémoire épuisée") }
        storage = memory
    }

    deinit {
        free(storage)
    }

    @inline(__always)
    private static func slot(_ storage: UnsafeMutableRawPointer, _ start: Int) -> UnsafeMutableRawPointer {
        let hashed = UInt64(truncatingIfNeeded: start) &* 0x9E37_79B9_7F4A_7C15
        return storage + Int(truncatingIfNeeded: hashed &>> 49) &* Self.stride
    }

    /// Les trente-deux octets à `start` sont-ils ceux du bloc ?
    @inline(__always)
    static func matches(_ block: UnsafeMutableRawPointer, _ bytes: UnsafeMutablePointer<UInt8>,
                        at start: Int) -> Bool {
        let now = UnsafeRawPointer(bytes + start)
        let then = UnsafeRawPointer(block + Self.wordsOffset)
        let first = now.loadUnaligned(as: UInt64.self) ^ then.load(as: UInt64.self)
        let second = now.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
            ^ then.load(fromByteOffset: 8, as: UInt64.self)
        let third = now.loadUnaligned(fromByteOffset: 16, as: UInt64.self)
            ^ then.load(fromByteOffset: 16, as: UInt64.self)
        let fourth = now.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            ^ then.load(fromByteOffset: 24, as: UInt64.self)
        return first | second | third | fourth == 0
    }

    /// Le bloc qui commence à `start`, si la case en tient un et que ses
    /// octets sont ceux qui sont là.
    @inline(__always)
    static func find(_ storage: UnsafeMutableRawPointer, _ bytes: UnsafeMutablePointer<UInt8>,
                     at start: Int, size: Int) -> UnsafeMutableRawPointer? {
        guard start <= size &- Self.span else { return nil }
        let block = slot(storage, start)
        guard block.load(as: Int.self) == start &+ 1, matches(block, bytes, at: start) else { return nil }
        return block
    }

    /// Une instruction générale après laquelle rien ne s'exécute à la suite :
    /// un saut indirect, un retour, un appel système. Ce n'est qu'une
    /// économie — décoder plus loin serait décoder pour rien —, et `hlt` n'y
    /// est pas : l'arrêt se vérifie dans le bloc, comme en tête de boucle.
    static func neverFallsThrough(_ instruction: X86Instruction) -> Bool {
        switch (instruction.mapCode, instruction.opcode) {
        case (0, 0xFF): return (instruction.regField & 7) == 4 || (instruction.regField & 7) == 5
        case (0, 0xC2), (0, 0xCA), (0, 0xCB), (0, 0xCF): return true
        case (1, 0x05), (1, 0x07): return true
        default: return false
        }
    }

    /// Décode les instructions qui se suivent depuis `start` et les range.
    /// `room` est ce qui reste de la page. Rend un bloc **vide** si la
    /// première ne se lit pas dans la page — à cheval sur deux, ou illisible :
    /// la case le retient, et `run` ne redécode pas à chaque passage. Rend
    /// `nil` si la mémoire finit avant trente-deux octets.
    @inline(never)
    static func build(_ storage: UnsafeMutableRawPointer, _ bytes: UnsafeMutablePointer<UInt8>,
                      at start: Int, size: Int, room: Int) -> UnsafeMutableRawPointer? {
        guard start <= size &- Self.span else { return nil }
        let block = slot(storage, start)
        let instructions = (block + Self.instructionsOffset).assumingMemoryBound(to: X86Instruction.self)
        typealias Form = X86Instruction.FastForm
        var position = 0
        var count = 0
        // La case change de bloc : vide tant qu'elle n'est pas finie.
        block.storeBytes(of: 0, as: Int.self)
        while count < Self.capacity {
            let available = min(X86Instruction.maximumLength, room - position)
            guard available > 0,
                  let instruction = try? X86Decoder.decode(bytes + start + position, available: available),
                  position + instruction.length <= Self.span
            else { break }
            (instructions + count).initialize(to: instruction)
            count += 1
            position += instruction.length
            let code = instruction.dispatchCode
            if code == Form.jump || code == Form.call || code == Form.ret
                || (code < Form.base && Self.neverFallsThrough(instruction)) {
                break
            }
        }
        block.storeBytes(of: UInt8(count), toByteOffset: Self.countOffset, as: UInt8.self)
        (block + Self.wordsOffset).copyMemory(from: bytes + start, byteCount: Self.span)
        block.storeBytes(of: start &+ 1, as: Int.self)
        let built = storage + slots * stride
        built.storeBytes(of: built.load(as: UInt64.self) &+ 1, as: UInt64.self)
        return block
    }
}

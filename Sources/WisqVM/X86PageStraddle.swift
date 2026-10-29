import Foundation

/// Les accès mémoire du cœur, **frontière de page comprise**.
///
/// **Le défaut que ce fichier ferme.** Un accès traduisait l'adresse de son
/// premier octet, puis demandait à la mémoire *n* octets contigus — contigus
/// **physiquement**. Deux pages virtuelles voisines ne sont voisines en
/// physique que par accident : dans la carte d'identité du démarrage et dans
/// le direct map de Linux, elles le sont, et le défaut ne se voyait pas. Dans
/// l'espace des modules, où `vmalloc` prend ses trames n'importe où, un mot de
/// huit octets posé à `…FFC` s'écrivait moitié chez lui, moitié chez le voisin
/// physique — et se relisait de même.
///
/// L'instruction, elle, avait déjà été corrigée (voir
/// `X86PageStraddlingFetchTests`) ; la donnée prenait toujours l'ancien
/// chemin.
///
/// **Le chemin chaud ne change pas.** La quasi-totalité des accès tiennent
/// dans leur page, et pour ceux-là c'est exactement le code d'avant : un test
/// de plus, une addition et une comparaison.
extension X86Core {
    /// Vrai quand l'accès dépasse la fin de sa page.
    @inline(__always)
    static func crosses(_ virtual: UInt64, _ size: Int) -> Bool {
        Int(virtual & 0xFFF) + size > 0x1000
    }

    /// Lire `size` octets à une adresse **virtuelle**.
    @inline(__always)
    mutating func readMemory(_ virtual: UInt64, _ size: Int,
                             _ access: Access = .read) throws -> UInt64 {
        guard let reference = memoryReference else { throw Fault.unsupported("une lecture sans mémoire") }
        guard Self.crosses(virtual, size) else {
            if let at = hostAddress(virtual, access) {
                switch size {
                case 8: return UInt64(littleEndian: at.loadUnaligned(as: UInt64.self))
                case 4: return UInt64(UInt32(littleEndian: at.loadUnaligned(as: UInt32.self)))
                case 2: return UInt64(UInt16(littleEndian: at.loadUnaligned(as: UInt16.self)))
                case 1: return UInt64(at.load(as: UInt8.self))
                default: break
                }
            }
            let physical = try translate(virtual, access)
            return try reference._withUnsafeGuaranteedRef { try $0.read(physical, size) }
        }
        return try readAcross(virtual, size, access, reference.takeUnretainedValue())
    }

    /// Le chemin froid de la lecture : deux traductions, deux moitiés,
    /// recollées dans l'ordre petit-boutien qui est celui de la machine.
    mutating func readAcross(_ virtual: UInt64, _ size: Int,
                             _ access: Access, _ memory: X86Memory) throws -> UInt64 {
        let head = 0x1000 - Int(virtual & 0xFFF)
        let low = try memory.read(try translate(virtual, access), head)
        let high = try memory.read(try translate(virtual &+ UInt64(head), access), size - head)
        return low | (high << (8 * UInt64(head)))
    }

    /// Écrire `size` octets à une adresse **virtuelle**.
    @inline(__always)
    mutating func writeMemory(_ virtual: UInt64, _ size: Int, _ value: UInt64) throws {
        guard let reference = memoryReference else { throw Fault.unsupported("une écriture sans mémoire") }
        guard Self.crosses(virtual, size) else {
            if let at = hostAddress(virtual, .write) {
                switch size {
                case 8: at.storeBytes(of: value.littleEndian, as: UInt64.self); return
                case 4: at.storeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian, as: UInt32.self); return
                case 2: at.storeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian, as: UInt16.self); return
                case 1: at.storeBytes(of: UInt8(truncatingIfNeeded: value), as: UInt8.self); return
                default: break
                }
            }
            let physical = try translate(virtual, .write)
            try reference._withUnsafeGuaranteedRef { try $0.write(physical, size, value) }
            return
        }
        try writeAcross(virtual, size, value, reference.takeUnretainedValue())
    }

    /// **Les deux traductions d'abord, les deux écritures ensuite.** C'est la
    /// même règle que le `push` qui traduit avant de descendre RSP : une
    /// instruction qui faute ne laisse aucune trace, donc la moitié basse ne
    /// doit pas être posée quand la page haute manque encore.
    mutating func writeAcross(_ virtual: UInt64, _ size: Int, _ value: UInt64,
                              _ memory: X86Memory) throws {
        let head = 0x1000 - Int(virtual & 0xFFF)
        let lowPlace = try translate(virtual, .write)
        let highPlace = try translate(virtual &+ UInt64(head), .write)
        try memory.write(lowPlace, head, value)
        try memory.write(highPlace, size - head, value >> (8 * UInt64(head)))
    }

    /// Vérifier qu'une écriture passera — **des deux côtés de la frontière**
    /// quand elle la traverse — sans rien écrire.
    @inline(__always)
    mutating func probeWrite(_ virtual: UInt64, _ size: Int) throws {
        _ = try translate(virtual, .write)
        guard Self.crosses(virtual, size) else { return }
        _ = try translate(virtual &+ UInt64(0x1000 - Int(virtual & 0xFFF)), .write)
    }
}

import Foundation

/// La mémoire de l'invité : un bloc plat, adressé physiquement.
///
/// Une classe, et non une structure, parce qu'un cœur qui la copierait à
/// chaque instruction ne mesurerait plus rien. C'est aussi pour ça que les
/// accès passent par un pointeur brut plutôt que par un tableau Swift : le
/// premier chiffre de vitesse de cette plate-forme sortira d'ici, et il doit
/// mesurer l'interprète, pas les vérifications de bornes de la bibliothèque
/// standard.
///
/// Les bornes sont vérifiées **une fois**, à l'entrée, et un accès hors de la
/// mémoire est une faute nommée plutôt qu'un plantage.
public final class X86Memory: @unchecked Sendable {
    /// La taille de la mémoire, en octets.
    public let size: Int
    /// Où elle commence dans l'espace d'adressage de l'invité.
    public let base: UInt64
    let bytes: UnsafeMutablePointer<UInt8>

    public init(size: Int, base: UInt64 = 0) {
        self.size = size
        self.base = base
        bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        bytes.initialize(repeating: 0, count: size)
    }

    deinit { bytes.deallocate() }

    /// L'octet à cette adresse, ou nil si elle est ailleurs.
    func offset(_ address: UInt64, _ width: Int) -> Int? {
        guard address >= base else { return nil }
        let index = address &- base
        guard index <= UInt64(size - width) else { return nil }
        return Int(index)
    }

    /// Le disque, quand il y en a un. **Il vit derrière la mémoire, pas
    /// dedans** : ses registres répondent à des adresses qu'aucune RAM ne
    /// couvre, et c'est exactement le chemin qui levait « hors mémoire »
    /// jusqu'ici. Le brancher là ne coûte donc rien au chemin chaud — une
    /// adresse ordinaire ne le rencontre jamais.
    public var storage: VirtioBlock?

    /// Le bus PCI, quand il y en a un. Il vit ici parce que c'est le seul
    /// objet que le cœur et les ports ont tous les deux sous la main.
    public var bus: X86PCIHost?

    /// Vrai quand l'adresse tombe dans la fenêtre du périphérique.
    @inline(__always)
    func storageOffset(_ address: UInt64) -> UInt64? {
        guard storage != nil, VirtioBlock.pc.contains(address) else { return nil }
        return address &- VirtioBlock.pc.base
    }

    public func read(_ address: UInt64, _ width: Int) throws -> UInt64 {
        guard let start = offset(address, width) else {
            if let device = storage, let at = storageOffset(address) {
                return device.read(at, width)
            }
            throw X86Core.Fault.outsideMemory(address)
        }
        var value: UInt64 = 0
        for byte in 0..<width { value |= UInt64(bytes[start + byte]) << (8 * UInt64(byte)) }
        return value
    }

    public func write(_ address: UInt64, _ width: Int, _ value: UInt64) throws {
        guard let start = offset(address, width) else {
            if let device = storage, let at = storageOffset(address) {
                device.write(at, width, value, self)
                return
            }
            throw X86Core.Fault.outsideMemory(address)
        }
        for byte in 0..<width { bytes[start + byte] = UInt8((value >> (8 * UInt64(byte))) & 0xFF) }
    }

    /// Charger un bloc à une adresse — ce que fait un chargeur de noyau.
    public func load(_ block: [UInt8], at address: UInt64) throws {
        guard let start = offset(address, max(block.count, 1)) else {
            throw X86Core.Fault.outsideMemory(address)
        }
        block.withUnsafeBufferPointer { source in
            guard let origin = source.baseAddress else { return }
            (bytes + start).update(from: origin, count: block.count)
        }
    }

    /// Relire un bloc, pour un test ou un instantané.
    public func dump(_ address: UInt64, _ count: Int) -> [UInt8] {
        guard let start = offset(address, max(count, 1)) else { return [] }
        return Array(UnsafeBufferPointer(start: bytes + start, count: count))
    }
}

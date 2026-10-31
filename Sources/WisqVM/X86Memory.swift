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
    /// L'étendue du bloc, en octets : la RAM, plus le trou quand il y en a un
    /// (voir `pc(ram:)`). La RAM seule est `ram`.
    public let size: Int
    /// Où elle commence dans l'espace d'adressage de l'invité.
    public let base: UInt64
    let bytes: UnsafeMutablePointer<UInt8>

    public convenience init(size: Int, base: UInt64 = 0) {
        self.init(size: size, base: base, hole: 0)
    }

    /// **Le trou sous quatre gibioctets**, comme sur un vrai PC et chez QEMU :
    /// la RAM s'arrête à `holeBase`, les périphériques occupent la suite, et
    /// ce qui reste de RAM reprend à quatre gibioctets.
    ///
    /// Sans lui, une machine de plus de trois gibioctets étalait sa RAM sur
    /// les adresses du disque (0xD000_0000) et de l'écran (0xE000_0000), et
    /// Linux ne trouvait plus où poser les fenêtres de ses périphériques :
    /// « Cannot find an available gap in the 32-bit address range », puis un
    /// processeur bloqué. Mesuré avec Chimera, à six gibioctets.
    public static let holeBase: UInt64 = 0xC000_0000
    public static let holeEnd: UInt64 = 1 << 32

    /// La mémoire d'une machine PC de `ram` octets : un bloc plat jusqu'à
    /// trois gibioctets, le trou au-delà. Le bloc de l'hôte couvre le trou —
    /// `calloc` ne rend résident que ce qu'on touche, et personne ne le
    /// touche —, si bien qu'une adresse physique reste un décalage dans le
    /// bloc, sans calcul.
    public static func pc(ram: Int) -> X86Memory {
        guard UInt64(ram) > holeBase else { return X86Memory(size: ram) }
        let hole = holeEnd - holeBase
        return X86Memory(size: ram + Int(hole), base: 0, hole: hole)
    }

    /// La RAM que l'invité reçoit : la taille, moins le trou.
    public var ram: Int { size - Int(holeSpan) }

    /// Les plages de RAM, dans l'ordre : une sans trou, deux avec.
    public var ramRanges: [Range<UInt64>] {
        guard holeSpan != 0 else { return [base..<(base &+ extent)] }
        return [base..<(base &+ holeLow), (base &+ holeLow &+ holeSpan)..<(base &+ extent)]
    }

    private init(size: Int, base: UInt64, hole: UInt64) {
        self.size = size
        self.base = base
        extent = UInt64(max(size, 0))
        holeSpan = hole
        holeLow = hole == 0 ? extent : Self.holeBase
        // **`calloc`, pas une allocation suivie d'un remplissage.** Pour un
        // bloc de cette taille, le système rend des pages qu'il promet nulles
        // et ne fournit qu'au premier accès : rien à écrire au départ, et la
        // mémoire que l'invité ne touche jamais ne pèse rien dans l'hôte. Le
        // remplissage écrivait les 512 Mio d'une machine PC avant sa première
        // instruction, et les rendait résidents pour toute sa vie — ce que
        // l'iPhone fait payer en tuant l'application.
        guard let zeroed = calloc(max(size, 1), 1) else {
            fatalError("la mémoire de l'invité : \(size) octets refusés par l'hôte")
        }
        bytes = zeroed.assumingMemoryBound(to: UInt8.self)
    }

    deinit { free(bytes) }

    /// La taille, en `UInt64` une fois pour toutes : la borne du chemin chaud.
    let extent: UInt64
    /// Le début du trou et sa longueur ; zéro de longueur sans trou.
    let holeLow: UInt64
    let holeSpan: UInt64

    /// L'octet à cette adresse, ou nil si elle est ailleurs.
    ///
    /// **Sans piège, et sans test de `base` à part** : c'est la ligne la plus
    /// chère de la mémoire, passée à chaque lecture d'instruction et à chaque
    /// accès. `size - width` vérifiait son débordement, sa conversion en
    /// `UInt64` son signe. Une adresse sous `base` donne, après la
    /// soustraction circulaire, un indice immense que le premier test écarte ;
    /// l'indice étant alors sous la taille, et la largeur petite (de 1 à
    /// quelques milliers), la somme du second ne déborde pas.
    @inline(__always)
    func offset(_ address: UInt64, _ width: Int) -> Int? {
        let index = address &- base
        let end = index &+ UInt64(truncatingIfNeeded: width)
        guard index < extent, end <= extent else { return nil }
        // Le trou n'est pas de la RAM : ses adresses vont au disque et à
        // l'écran. Le premier test suffit sans trou, et le chemin chaud n'y
        // passe guère : la traduction garde un pointeur vers la page.
        if holeSpan != 0, end > holeLow, index < holeLow &+ holeSpan { return nil }
        return Int(truncatingIfNeeded: index)
    }

    /// Le disque, quand il y en a un. **Il vit derrière la mémoire, pas
    /// dedans** : ses registres répondent à des adresses qu'aucune RAM ne
    /// couvre, et c'est exactement le chemin qui levait « hors mémoire »
    /// jusqu'ici. Le brancher là ne coûte donc rien au chemin chaud — une
    /// adresse ordinaire ne le rencontre jamais.
    @exclusivity(unchecked)
    public var storage: VirtioBlock?

    /// L'écran, quand il y en a un. Même logement que le disque, et pour la
    /// même raison : ses adresses ne sont pas de la RAM.
    public var screen: X86Framebuffer?

    /// Le bus PCI, quand il y en a un. Il vit ici parce que c'est le seul
    /// objet que le cœur et les ports ont tous les deux sous la main.
    @exclusivity(unchecked)
    public var bus: X86PCIHost?

    /// **Les octets de l'hôte derrière `length` octets à cette adresse
    /// physique**, s'ils tiennent d'un seul tenant dans la RAM ou dans le
    /// cadre ; nil sinon — le disque, le trou, ou rien du tout.
    ///
    /// `screen` est le cadre quand c'est lui : qui y écrit directement doit le
    /// dire (`X86Framebuffer.touch`), pour que la vue repeigne.
    @inline(__always)
    func block(_ address: UInt64, _ length: Int) -> (bytes: UnsafeMutablePointer<UInt8>, screen: X86Framebuffer?)? {
        if let start = offset(address, length) { return (bytes + start, nil) }
        if let frame = screen, let at = frame.offset(address, length) { return (frame.bytes + at, frame) }
        return nil
    }

    /// Vrai quand l'adresse tombe dans la fenêtre du périphérique.
    @inline(__always)
    func storageOffset(_ address: UInt64) -> UInt64? {
        guard storage != nil, VirtioBlock.pc.contains(address) else { return nil }
        return address &- VirtioBlock.pc.base
    }

    /// **Le cas courant en ligne, le reste à part.** Presque tous les accès
    /// sont de la RAM, sur un, deux, quatre ou huit octets ; chacun passait
    /// pourtant par un appel de fonction, et la fonction portait aussi le
    /// disque, l'écran et les largeurs impaires. Sous callgrind, `read` et
    /// `write` coûtaient à eux deux 6,3 % des instructions de l'hôte.
    /// `fastRead` et `fastWrite` rendent nil ou faux pour tout ce qui n'est
    /// pas ce cas-là, et le chemin d'avant le prend tel quel.
    @inline(__always)
    public func read(_ address: UInt64, _ width: Int) throws -> UInt64 {
        if let value = fastRead(address, width) { return value }
        return try readSlowly(address, width)
    }

    @inline(__always)
    func fastRead(_ address: UInt64, _ width: Int) -> UInt64? {
        guard let start = offset(address, width) else { return nil }
        let at = UnsafeRawPointer(bytes + start)
        switch width {
        case 8: return UInt64(littleEndian: at.loadUnaligned(as: UInt64.self))
        case 4: return UInt64(UInt32(littleEndian: at.loadUnaligned(as: UInt32.self)))
        case 2: return UInt64(UInt16(littleEndian: at.loadUnaligned(as: UInt16.self)))
        case 1: return UInt64(bytes[start])
        default: return nil
        }
    }

    @inline(never)
    func readSlowly(_ address: UInt64, _ width: Int) throws -> UInt64 {
        guard let start = offset(address, width) else {
            if let device = storage, let at = storageOffset(address) {
                return device.read(at, width)
            }
            if let frame = screen, let at = frame.offset(address, width) {
                return frame.read(at, width)
            }
            throw X86Core.Fault.outsideMemory(address)
        }
        // **Un chargement, pas une boucle.** La mémoire de l'invité est
        // petit-boutienne, comme l'hôte ; `littleEndian` le dit et coûte zéro
        // là où c'est vrai. La boucle d'octets reste pour les largeurs
        // impaires, que seuls les accès à cheval sur une page demandent.
        let at = UnsafeRawPointer(bytes + start)
        switch width {
        case 8: return UInt64(littleEndian: at.loadUnaligned(as: UInt64.self))
        case 4: return UInt64(UInt32(littleEndian: at.loadUnaligned(as: UInt32.self)))
        case 2: return UInt64(UInt16(littleEndian: at.loadUnaligned(as: UInt16.self)))
        case 1: return UInt64(bytes[start])
        default:
            var value: UInt64 = 0
            for byte in 0..<width { value |= UInt64(bytes[start + byte]) << (8 * UInt64(byte)) }
            return value
        }
    }

    @inline(__always)
    public func write(_ address: UInt64, _ width: Int, _ value: UInt64) throws {
        if fastWrite(address, width, value) { return }
        try writeSlowly(address, width, value)
    }

    @inline(__always)
    func fastWrite(_ address: UInt64, _ width: Int, _ value: UInt64) -> Bool {
        guard let start = offset(address, width) else { return false }
        let at = UnsafeMutableRawPointer(bytes + start)
        switch width {
        case 8: at.storeBytes(of: value.littleEndian, as: UInt64.self)
        case 4: at.storeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian, as: UInt32.self)
        case 2: at.storeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian, as: UInt16.self)
        case 1: bytes[start] = UInt8(truncatingIfNeeded: value)
        default: return false
        }
        return true
    }

    @inline(never)
    func writeSlowly(_ address: UInt64, _ width: Int, _ value: UInt64) throws {
        guard let start = offset(address, width) else {
            if let device = storage, let at = storageOffset(address) {
                device.write(at, width, value, self)
                return
            }
            if let frame = screen, let at = frame.offset(address, width) {
                frame.write(at, width, value)
                return
            }
            throw X86Core.Fault.outsideMemory(address)
        }
        let at = UnsafeMutableRawPointer(bytes + start)
        switch width {
        case 8: at.storeBytes(of: value.littleEndian, as: UInt64.self)
        case 4: at.storeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian, as: UInt32.self)
        case 2: at.storeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian, as: UInt16.self)
        case 1: bytes[start] = UInt8(truncatingIfNeeded: value)
        default:
            for byte in 0..<width { bytes[start + byte] = UInt8((value >> (8 * UInt64(byte))) & 0xFF) }
        }
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

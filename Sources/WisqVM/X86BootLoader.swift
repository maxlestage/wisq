import Foundation

/// Mettre un noyau Linux là où il s'attend à être, et lui dire ce qu'il doit
/// savoir.
///
/// La tranche 1 a appris à **lire** l'en-tête de démarrage ; celle-ci s'en sert.
/// Un noyau x86-64 ne se contente pas d'être copié quelque part : il exige une
/// adresse compatible avec son alignement, une zone réservée plus grande que ce
/// qu'il pèse, et une structure — la « page zéro » — où le chargeur écrit ce
/// qu'il a fait. Le registre RSI la lui désigne au moment du saut.
///
/// **Ce que ce chargeur ne fait pas encore** : les tables de pages. Le point
/// d'entrée 64 bits suppose le mode long déjà actif, ce qui suppose la
/// pagination. C'est la tranche suivante, et c'est pour ça que
/// `entryPoint` est rendu sans être sauté.
public struct X86BootLoader {
    /// Ce que le chargement a produit.
    public struct Placement: Equatable, Sendable {
        /// Où le noyau en mode protégé a été mis.
        public let kernelAddress: UInt64
        /// Combien d'octets lui sont réservés à partir de là — bien plus que
        /// ce qu'il pèse, parce qu'il se décompresse chez lui.
        public let reservedBytes: Int
        /// Où la page zéro a été écrite. C'est ce que RSI portera.
        public let bootParametersAddress: UInt64
        /// Où la ligne de commande a été écrite.
        public let commandLineAddress: UInt64
        /// Le point d'entrée 64 bits : le début du noyau, plus 0x200.
        public let entryPoint: UInt64
    }

    public enum LoadError: Error, Equatable {
        /// Le fichier n'est pas un noyau Linux pour PC.
        case notAKernel
        /// Le noyau n'offre pas de point d'entrée 64 bits.
        case noSixtyFourBitEntry
        /// Le protocole est trop ancien pour que ce chargeur sache quoi écrire.
        case protocolTooOld(UInt16)
        /// La mémoire de l'invité ne suffit pas.
        case notEnoughMemory(needed: Int, available: Int)
        /// Le fichier est plus court que ce que son en-tête annonce.
        case truncated
    }

    /// La page zéro fait exactement quatre kibioctets, et le noyau la lit
    /// jusqu'au bout.
    public static let bootParametersSize = 4096
    /// Où on la met : sous le mégaoctet, là où un chargeur classique la met, et
    /// hors du chemin du noyau.
    public static let bootParametersAddress: UInt64 = 0x1_0000
    public static let commandLineAddress: UInt64 = 0x2_0000
    /// Le protocole 2.06 est le premier où `cmdline_size` existe ; en dessous,
    /// ce chargeur ne saurait pas quelle longueur de ligne de commande est
    /// permise.
    public static let oldestProtocol: UInt16 = 0x0206

    /// Charge le noyau dans la mémoire de l'invité et rend où tout a atterri.
    public static func load(
        kernel: [UInt8], into memory: X86Memory, commandLine: String = "console=ttyS0"
    ) throws -> Placement {
        guard let header = LinuxBootProtocol.read(from: kernel, totalBytes: kernel.count) else {
            throw LoadError.notAKernel
        }
        guard header.version >= oldestProtocol else {
            throw LoadError.protocolTooOld(header.version)
        }
        guard header.hasSixtyFourBitEntry else { throw LoadError.noSixtyFourBitEntry }
        guard kernel.count >= header.setupBytes + header.protectedModeBytes else {
            throw LoadError.truncated
        }

        // Où le noyau va. Un noyau déplaçable accepte n'importe quelle adresse
        // alignée ; les autres exigent la leur. On prend l'adresse préférée
        // dans les deux cas, ce qui est toujours valable.
        let kernelAddress = header.preferredAddress
        let reserved = Int(header.initSize)
        let top = Int(kernelAddress &- memory.base) + reserved
        guard top <= memory.size else {
            throw LoadError.notEnoughMemory(needed: top, available: memory.size)
        }

        let protectedMode = Array(
            kernel[header.setupBytes..<(header.setupBytes + header.protectedModeBytes)])
        try memory.load(protectedMode, at: kernelAddress)

        // La page zéro : quatre kibioctets de zéros, dans lesquels on recopie
        // l'en-tête de setup **à ses propres décalages**. Le noyau relit ses
        // champs là où il les a écrits, pas ailleurs.
        var page = [UInt8](repeating: 0, count: bootParametersSize)
        let headerStart = LinuxBootProtocol.setupSectorsOffset
        let headerEnd = LinuxBootProtocol.headerBytes
        page.replaceSubrange(headerStart..<headerEnd, with: kernel[headerStart..<headerEnd])

        // Ce que le chargeur, lui, doit écrire.
        //
        // `type_of_loader` à 0xFF veut dire « un chargeur non enregistré » :
        // c'est la valeur prévue pour qui n'a pas demandé de numéro, et la
        // laisser à zéro ferait croire au noyau qu'il a été lancé par LILO.
        page[0x210] = 0xFF
        // LOADED_HIGH : le noyau en mode protégé est au-dessus du mégaoctet.
        // CAN_USE_HEAP : le tas de setup est utilisable. On garde le reste tel
        // que le noyau l'a écrit.
        page[0x211] = (page[0x211] & ~0x80) | 0x01 | 0x80
        write32(&page, 0x214, UInt32(truncatingIfNeeded: kernelAddress))
        write32(&page, 0x218, 0)  // ramdisk_image : il n'y en a pas
        write32(&page, 0x21C, 0)  // ramdisk_size
        write32(&page, 0x228, UInt32(truncatingIfNeeded: commandLineAddress))

        try memory.load(page, at: bootParametersAddress)

        // La ligne de commande, terminée par un zéro, et pas plus longue que ce
        // que le noyau accepte : au-delà, il la tronquerait sans le dire.
        var line = Array(commandLine.utf8)
        let limit = Int(header.commandLineLimit)
        if line.count > limit { line = Array(line.prefix(limit)) }
        try memory.load(line + [0], at: commandLineAddress)

        return Placement(
            kernelAddress: kernelAddress, reservedBytes: reserved,
            bootParametersAddress: bootParametersAddress,
            commandLineAddress: commandLineAddress,
            // L'entrée 64 bits est à 0x200 du début du noyau en mode protégé.
            entryPoint: kernelAddress &+ 0x200)
    }

    static func write32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) {
        for byte in 0..<4 { bytes[offset + byte] = UInt8((value >> (8 * UInt32(byte))) & 0xFF) }
    }
}

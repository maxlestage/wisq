import Foundation

/// Un noyau Linux reconnu : pour quelle architecture, dans quel emballage.
public struct KernelImage: Equatable, Sendable {
    public let architecture: GuestArchitecture
    /// Comment il est livré : « bzImage », « Image ARM64 », « uImage »…
    /// C'est le format qui a permis de le reconnaître, et le nommer dit à
    /// quelqu'un **pourquoi** on affirme ce qu'on affirme.
    public let format: String
    /// L'en-tête de démarrage, quand le format en porte un.
    public let bootProtocol: LinuxBootProtocol?

    public init(_ architecture: GuestArchitecture, format: String,
                bootProtocol: LinuxBootProtocol? = nil) {
        self.architecture = architecture
        self.format = format
        self.bootProtocol = bootProtocol
    }
}

/// What a file someone picked actually is, as far as its first bytes say.
///
/// This exists because of a real conversation. Someone imported
/// `omarchy-4.0.2.iso` — a full Arch Linux installer for PC — and the app
/// answered « fait 5939.2 Mo. La machine émulée n'a que 64.0 Mo de mémoire en
/// tout ». Every word true, and the whole message misleading: it says the
/// problem is a number, so the reader reaches for the memory setting. **No
/// amount of memory will ever boot that file here.**
///
/// So the size is the wrong thing to say first. What the file *is* comes
/// first, and the size only matters once the kind is plausible.
///
/// **Toutes les architectures, et le cœur choisi tout seul.** Ce fichier
/// reconnaît les architectures pour lesquelles Linux existe — voir
/// `GuestArchitecture` —, dans les emballages sous lesquels un noyau est
/// vraiment livré : ELF, `bzImage`, l'`Image` d'ARM64, celle de RISC-V, le
/// `zImage` d'ARM, l'`uImage` d'U-Boot. Une fois l'architecture connue,
/// `GuestArchitecture.core` dit quel cœur la fait tourner, et il n'y a
/// personne à qui demander.
///
/// **Reconnaître n'est pas exécuter, et les deux ne se confondent pas ici.**
/// wisq reconnaît vingt et une familles ; il en exécute deux. Pour les
/// autres, le refus **nomme** l'architecture au lieu de dire « non » : c'est
/// la différence entre un mur et une carte.
///
/// **The asymmetry is deliberate.** Recognising a boot image is a positive
/// fact; *not* recognising one is not. Someone may hold a raw image with no
/// header at all, and refusing it because this code did not know it would be
/// worse than letting it try and fail. So `unknown` is a permission, not a
/// doubt — only what is positively identifiable as something else is refused.
public enum KernelImageKind: Equatable, Sendable {
    /// Un noyau Linux, nommé.
    case linuxKernel(KernelImage)
    /// A bootable disc image — an installer, a live CD. Named by its format.
    case discImage(String)
    /// An executable for some other architecture, named.
    case executable(GuestArchitecture)
    /// Un fichier compressé et rien d'autre : très probablement un noyau, mais
    /// son architecture est **dans** la compression. Le dire vaut mieux que de
    /// deviner, et mieux que de se taire.
    case compressedKernel(String)
    /// Nothing this code recognises. Tried anyway; see the type's doc.
    case unknown

    /// L'architecture, quand le fichier la dit.
    public var architecture: GuestArchitecture? {
        switch self {
        case .linuxKernel(let image): return image.architecture
        case .executable(let architecture): return architecture
        case .discImage, .compressedKernel, .unknown: return nil
        }
    }

    /// **Le cœur que wisq démarrera pour ce fichier**, choisi tout seul.
    ///
    /// `nil` ne veut pas dire « refusé » : un fichier que personne n'a
    /// reconnu n'a pas d'architecture et passe quand même, sur le cœur par
    /// défaut. C'est `couldBootHere` qui tranche.
    public var core: GuestArchitecture.Core? { architecture?.core }

    /// Whether the local machine could conceivably boot it.
    public var couldBootHere: Bool {
        switch self {
        case .unknown: return true
        case .linuxKernel(let image): return image.architecture.core?.availableInTheApp == true
        case .executable, .discImage, .compressedKernel: return false
        }
    }

    /// How many bytes are needed to decide. The ISO 9660 volume descriptor
    /// lives at sector 16, so the answer is a little past 32 KiB — and *only*
    /// that: reading six gigabytes to learn what a file is would be the same
    /// mistake as reading it to find out it is too large.
    public static let bytesNeeded = 40 * 1024

    /// What a file is, from its first `bytesNeeded` bytes.
    public static func identify(fileAt url: URL) -> KernelImageKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: bytesNeeded) else { return .unknown }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.size] as? NSNumber }
            .map(\.intValue)
        return identify(prefix: prefix, totalBytes: size)
    }

    /// The same decision, on bytes already in hand — which is what the tests
    /// can reach, and what keeps the rule out of the file system.
    /// `totalBytes` is the real size of the file when the caller knows it —
    /// only the bzImage check uses it, and only to reject a file that carries
    /// the magic without being shaped like one.
    public static func identify(prefix: Data, totalBytes: Int? = nil) -> KernelImageKind {
        let bytes = [UInt8](prefix)

        // ISO 9660: a volume descriptor at sector 16, and its identifier is
        // the five bytes « CD001 ». The standard allows the descriptor set to
        // start later, so the next two sectors are checked as well.
        for sector in [0x8000, 0x8800, 0x9000] where bytes.count >= sector + 6 {
            if Array(bytes[(sector + 1)...(sector + 5)]) == Array("CD001".utf8) {
                return .discImage("ISO 9660")
            }
        }

        // L'en-tête d'U-Boot en premier, parce que c'est le **seul** format
        // qui nomme son architecture au lieu de la laisser deviner : un octet,
        // à l'offset 29. Un uImage enveloppe souvent une image qui porterait
        // son propre magic plus loin, donc le lire d'abord évite de conclure
        // sur l'emballé au lieu de l'emballage.
        if bytes.count >= 32, be32(bytes, 0) == 0x2705_1956 {
            if let architecture = GuestArchitecture.fromUBoot(bytes[29]) {
                return .linuxKernel(KernelImage(architecture, format: "uImage (U-Boot)"))
            }
            return .compressedKernel("uImage (U-Boot)")
        }

        // A Linux kernel for PC. Checked after the disc image on purpose: a
        // hybrid ISO carries an MBR boot sector, whose last two bytes are the
        // same 0xAA55, and a disc image is what such a file *is*.
        if let header = LinuxBootProtocol.read(from: bytes, totalBytes: totalBytes) {
            return .linuxKernel(KernelImage(
                GuestArchitecture(.x86, bits: header.hasSixtyFourBitEntry ? 64 : 32),
                format: "bzImage", bootProtocol: header))
        }

        // L'image brute d'ARM64 : soixante-quatre octets d'en-tête, et le
        // nombre magique « ARM\u{64} » au cinquante-sixième. C'est le fichier
        // que toute distribution pour ARM64 livre sous le nom `Image`.
        // Les quatre octets sont « A », « R », « M » et 0x64 — le manuel les
        // écrit `"ARM\x64"`, ce qui se lit « ARMd » et n'est pas ce qu'on
        // croit lire. Écrits en clair ici pour que personne ne s'y trompe.
        if bytes.count >= 0x3C, Array(bytes[0x38...0x3B]) == [0x41, 0x52, 0x4D, 0x64] {
            return .linuxKernel(KernelImage(
                GuestArchitecture(.arm, bits: 64), format: "Image ARM64"))
        }

        // L'image brute de RISC-V : « RISCV » à 0x30, et le second magique
        // « RSC\u{05} » à 0x38. Lu octet par octet sur le vrai noyau que ce
        // projet démarre dans ses tests, plutôt que dans un document.
        //
        // **La largeur n'y est pas.** Aucun champ de cet en-tête ne dit 32 ou
        // 64 bits : un noyau rv32 et un rv64 sont ici indiscernables. Alors on
        // ne dit rien, et `GuestArchitecture.core` choisit le seul cœur
        // RISC-V qui existe plutôt que de refuser sur ce qu'on n'a pas lu.
        if bytes.count >= 0x3C,
           Array(bytes[0x30...0x34]) == Array("RISCV".utf8),
           Array(bytes[0x38...0x3A]) == Array("RSC".utf8), bytes[0x3B] == 0x05 {
            return .linuxKernel(KernelImage(GuestArchitecture(.riscv), format: "Image RISC-V"))
        }

        // Le `zImage` d'ARM 32 bits : huit instructions de saut, puis le
        // nombre magique à 0x24. C'est ce que livrent Raspbian et à peu près
        // tout ce qui tourne sur ARM depuis vingt ans.
        if bytes.count >= 0x28, le32(bytes, 0x24) == 0x016F_2818 {
            return .linuxKernel(KernelImage(
                GuestArchitecture(.arm, bits: 32), format: "zImage ARM"))
        }

        // ELF : le magique, la classe au cinquième octet, le boutisme au
        // sixième, la machine à 0x12. C'est la forme sous laquelle arrivent
        // les noyaux de PowerPC, de MIPS, de s390 et de tout ce qui n'a pas
        // inventé son propre emballage.
        if bytes.count >= 0x14, Array(bytes[0...3]) == [0x7F, 0x45, 0x4C, 0x46] {
            let sixtyFour = bytes[4] == 2
            let big = bytes[5] == 2
            let machine = big
                ? UInt16(bytes[0x12]) << 8 | UInt16(bytes[0x13])
                : UInt16(bytes[0x12]) | UInt16(bytes[0x13]) << 8
            guard let architecture = GuestArchitecture.fromELF(
                machine: machine, sixtyFour: sixtyFour, big: big)
            else { return .unknown }
            // Un ELF pour l'architecture que la machine locale fait tourner
            // n'est pas refusé : un `vmlinux` arrive sous cette forme, ce
            // n'est pas l'image brute attendue, et le dire serait une
            // supposition sur ce que quelqu'un voulait. `unknown` le laisse
            // déjà essayer. Pour les autres, le nom vaut mieux que le
            // silence.
            return architecture.core?.availableInTheApp == true
                ? .unknown : .executable(architecture)
        }

        // Les enveloppes. Un `vmlinuz` compressé sans en-tête de démarrage est
        // presque sûrement un noyau — mais son architecture est **dans** la
        // compression, et la lire demanderait de tout décompresser. Nommer
        // l'enveloppe, c'est dire à la fois ce qu'on sait et ce qu'on ignore.
        for (magic, format) in [
            ([0x1F, 0x8B] as [UInt8], "gzip"),
            ([0xFD, 0x37, 0x7A, 0x58, 0x5A], "xz"),
            ([0x28, 0xB5, 0x2F, 0xFD], "zstd"),
            ([0x42, 0x5A, 0x68], "bzip2"),
            ([0x04, 0x22, 0x4D, 0x18], "lz4"),
            ([0x89, 0x4C, 0x5A, 0x4F], "lzop"),
        ] where bytes.count >= magic.count && Array(bytes[0..<magic.count]) == magic {
            return .compressedKernel(format)
        }

        return .unknown
    }

    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16
            | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
            | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    /// Why this file cannot run here, said to the person who picked it.
    ///
    /// Returns nil for anything that could boot: a refusal is only written
    /// when there is one.
    ///
    /// Il nomme le fichier, ce qu'il est, et **quelle architecture** — puis où
    /// vit la chose que la personne voulait vraiment. Quelqu'un qui arrive
    /// avec une image d'installation veut faire tourner cette distribution ;
    /// la réponse utile n'est pas « non », c'est « pas ici, et voilà où ».
    public static func cannotRunHereExplanation(_ kind: KernelImageKind, name: String) -> String? {
        let what: String
        switch kind {
        case .unknown: return nil
        case .linuxKernel(let image)
            where image.architecture.core?.availableInTheApp == true: return nil
        case .linuxKernel(let image):
            let protocolNote = image.bootProtocol
                .map { " (protocole de démarrage \($0.versionDescription))" } ?? ""
            let what = """
                \(name) est un noyau Linux pour \(image.architecture.name), \
                au format \(image.format)\(protocolNote).

                C'est le bon genre de fichier — un noyau, pas une image de \
                disque —
                """
            // **Deux refus différents, parce que ce sont deux situations
            // différentes.** Dire « pas de cœur » d'une architecture dont le
            // cœur existe et démarre un vrai noyau serait faux, et enverrait
            // quelqu'un attendre une chose déjà écrite.
            if let core = image.architecture.core {
                return """
                    \(what) et wisq a bien un cœur \(core.name), qui démarre \
                    un vrai noyau Linux. Il n'est pas encore branché dans \
                    l'application : la machine locale ne sait lancer que \
                    \(GuestArchitecture.runnableInTheApp.map(\.name)
                        .joined(separator: " et ")).

                    Ce n'est pas une question de mémoire. En attendant, pour \
                    faire tourner cette distribution : installez-la sur un \
                    hôte (un PC, un Mac, un serveur), et connectez-vous dessus \
                    depuis wisq.
                    """
            }
            return """
                \(what) mais wisq n'a pas de cœur pour cette architecture. Il \
                en a deux : \
                \(GuestArchitecture.runnable.map(\.name).joined(separator: " et ")).

                Ce n'est pas une question de mémoire, et aucun réglage ne \
                changera ça. Pour faire tourner cette distribution \
                aujourd'hui : installez-la sur un hôte (un PC, un Mac, un \
                serveur), et connectez-vous dessus depuis wisq.
                """
        case .discImage(let format):
            what = "une image de disque amorçable (\(format))"
        case .executable(let architecture):
            what = "un exécutable pour \(architecture.name)"
        case .compressedKernel(let format):
            return """
                \(name) est un fichier compressé (\(format)) — probablement un \
                noyau, mais son architecture est à l'intérieur, et la lire \
                demanderait de tout décompresser.

                wisq démarre un noyau **non compressé** : l'`Image` de RISC-V, \
                ou le `bzImage` d'un PC, qui porte son propre en-tête. Si vous \
                avez ce fichier-là, prenez-le plutôt.
                """
        }
        return """
            \(name) est \(what).

            La machine locale de wisq démarre un noyau Linux pour \
            \(GuestArchitecture.runnableInTheApp.map(\.name)
                .joined(separator: " et ")), et rien d'autre. Ce n'est pas une \
            question de mémoire — aucun réglage ne changera ça.

            Pour faire tourner cette distribution, installez-la sur un hôte \
            (un PC, un Mac, un serveur), et connectez-vous dessus depuis wisq : \
            c'est exactement ce pour quoi le reste de l'application existe.
            """
    }
}

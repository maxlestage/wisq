import Foundation

/// What a file someone picked actually is, as far as its first bytes say.
///
/// This exists because of a real conversation. Someone imported
/// `omarchy-4.0.2.iso` — a full Arch Linux installer for PC — and the app
/// answered « fait 5939.2 Mo. La machine émulée n'a que 64.0 Mo de mémoire en
/// tout ». Every word true, and the whole message misleading: it says the
/// problem is a number, so the reader reaches for the memory setting. **No
/// amount of memory will ever boot that file here.** It is x86-64, it is a
/// disc image, and this machine is a 32-bit RISC-V with no disk at all.
///
/// So the size is the wrong thing to say first. What the file *is* comes
/// first, and the size only matters once the kind is plausible.
///
/// **The asymmetry is deliberate.** Recognising a RISC-V boot image is a
/// positive fact; *not* recognising one is not. Someone may hold a raw image
/// with no header at all, and refusing it because this code did not know it
/// would be worse than letting it try and fail. So `unknown` is a permission,
/// not a doubt — only what is positively identifiable as something else is
/// refused.
public enum KernelImageKind: Equatable, Sendable {
    /// A Linux boot image for RISC-V: exactly what this machine runs.
    case riscvLinuxImage
    /// A Linux kernel for PC — a `bzImage` — carrying its boot protocol
    /// header. This is *the right kind of file*, only for an architecture the
    /// local machine does not run yet; see `LinuxBootProtocol`.
    case pcLinuxKernel(LinuxBootProtocol)
    /// A bootable disc image — an installer, a live CD. Named by its format.
    case discImage(String)
    /// An executable for some other architecture, named.
    case executable(String)
    /// Nothing this code recognises. Tried anyway; see the type's doc.
    case unknown

    /// Whether the local machine could conceivably boot it.
    public var couldBootHere: Bool {
        switch self {
        case .riscvLinuxImage, .unknown: return true
        case .pcLinuxKernel, .discImage, .executable: return false
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

        // A Linux kernel for PC. Checked after the disc image on purpose: a
        // hybrid ISO carries an MBR boot sector, whose last two bytes are the
        // same 0xAA55, and a disc image is what such a file *is*.
        if let header = LinuxBootProtocol.read(from: bytes, totalBytes: totalBytes) {
            return .pcLinuxKernel(header)
        }

        // The RISC-V Linux boot image header: « RISCV » at 0x30 and the second
        // magic « RSC\u{05} » at 0x38. Read off the real kernel this project
        // boots in its tests, byte for byte, rather than from a document.
        if bytes.count >= 0x3C,
           Array(bytes[0x30...0x34]) == Array("RISCV".utf8),
           Array(bytes[0x38...0x3A]) == Array("RSC".utf8), bytes[0x3B] == 0x05 {
            return .riscvLinuxImage
        }

        // ELF: the magic, then the machine at offset 0x12. A RISC-V ELF is not
        // refused — it is not the raw image this machine wants, but saying so
        // is a guess about what someone meant, and `unknown` already lets it
        // try.
        if bytes.count >= 0x14, Array(bytes[0...3]) == [0x7F, 0x45, 0x4C, 0x46] {
            let machine = UInt16(bytes[0x12]) | (UInt16(bytes[0x13]) << 8)
            switch machine {
            case 0xF3: return .unknown          // RISC-V
            case 0x3E: return .executable("x86-64")
            case 0x03: return .executable("x86")
            case 0xB7: return .executable("ARM64")
            case 0x28: return .executable("ARM")
            default: return .executable("une autre architecture")
            }
        }

        return .unknown
    }

    /// Why this file cannot run here, said to the person who picked it.
    ///
    /// Returns nil for anything that could boot: a refusal is only written
    /// when there is one.
    ///
    /// It names the file, what it is, and what this machine is — and then
    /// where the thing they actually want lives. Someone who arrives with an
    /// installer image wants to run that distribution; the useful answer is
    /// not "no", it is "not here, and here is where".
    public static func cannotRunHereExplanation(_ kind: KernelImageKind, name: String) -> String? {
        let what: String
        switch kind {
        case .riscvLinuxImage, .unknown: return nil
        case .pcLinuxKernel(let header):
            return """
                \(name) est un noyau Linux pour PC (\(header.architecture), \
                protocole de démarrage \(header.versionDescription)).

                C'est le bon genre de fichier — un noyau, pas une image de \
                disque — mais pas encore pour cette machine : la machine \
                locale de wisq est aujourd'hui un RISC-V 32 bits. Le cœur \
                x86-64 est en cours d'écriture (lot 7 dans docs/ROADMAP.md), \
                et c'est exactement ce fichier-là qu'il démarrera. Ce n'est \
                pas une question de mémoire.

                En attendant, pour faire tourner cette distribution : \
                installez-la sur un hôte (un PC, un Mac, un serveur), et \
                connectez-vous dessus depuis wisq.
                """
        case .discImage(let format):
            what = "une image de disque amorçable pour PC (\(format))"
        case .executable(let architecture):
            what = "un exécutable pour \(architecture)"
        }
        return """
            \(name) est \(what).

            La machine locale de wisq est un RISC-V 32 bits « nommu », sans \
            disque : elle démarre un noyau Linux compilé pour cette \
            architecture, et rien d'autre. Ce n'est pas une question de \
            mémoire — aucun réglage ne changera ça.

            Pour faire tourner cette distribution, installez-la sur un hôte \
            (un PC, un Mac, un serveur), et connectez-vous dessus depuis wisq : \
            c'est exactement ce pour quoi le reste de l'application existe.
            """
    }
}

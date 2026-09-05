import Foundation

/// L'initramfs d'un noyau : ce qui peut en être un, et auquel il va.
///
/// **Pourquoi ce type existe.** Un noyau de distribution n'a aucun pilote de
/// disque compilé dedans — ce sont des modules, et ils vivent dans
/// l'initramfs. Sans lui, le noyau démarre entièrement puis panique :
/// « VFS: Unable to mount root fs on unknown-block(0,0) ». C'est exactement
/// ce que l'application faisait vivre à qui importait un noyau de PC.
///
/// **Les octets ne peuvent pas trancher**, et ce fait commande tout le reste.
/// Un noyau compressé et un initramfs compressé sont l'un et l'autre un flux
/// gzip ; l'en-tête gzip peut porter le nom du fichier d'origine, et celui
/// d'Alpine ne le porte pas — son octet de drapeaux vaut zéro. Il n'y a donc
/// pas de règle sur le contenu qui les sépare, et prétendre le contraire
/// reviendrait à deviner. C'est à la personne de dire lequel elle apporte ;
/// ce type-ci vérifie seulement que le fichier *pourrait* en être un, et
/// refuse ceux qui n'en sont sûrement pas.
public enum BootMedia {
    /// Ce qu'on a trouvé pour un noyau donné.
    ///
    /// Les deux réussites sont **distinctes** parce qu'elles ne méritent pas
    /// la même phrase : l'une est sûre, l'autre est un choix par défaut que
    /// l'application doit pouvoir nommer.
    public enum Pairing: Equatable {
        /// Les noms se répondent.
        case named(URL)
        /// Rien ne correspond, mais il n'y a qu'un candidat.
        case theOnlyOne(URL)
        /// Rien. Nommé `nothing` et pas `none` : `.none` d'un type énuméré se
        /// confond avec celui d'`Optional` dès qu'on l'écrit sans le préfixer,
        /// et le compilateur choisit l'autre sans rien dire.
        case nothing

        public var url: URL? {
            switch self {
            case .named(let url), .theOnlyOne(let url): return url
            case .nothing: return nil
            }
        }
    }

    // MARK: - Ce qu'on accepte

    /// Les enveloppes qu'un `mkinitfs` produit, selon la distribution.
    static let envelopes: [(magic: [UInt8], format: String)] = [
        ([0x1F, 0x8B], "gzip"),
        ([0xFD, 0x37, 0x7A, 0x58, 0x5A], "xz"),
        ([0x28, 0xB5, 0x2F, 0xFD], "zstd"),
        ([0x42, 0x5A, 0x68], "bzip2"),
        ([0x04, 0x22, 0x4D, 0x18], "lz4"),
        ([0x89, 0x4C, 0x5A, 0x4F], "lzop"),
        // Un cpio nu : ce que produit `cpio -o -H newc` sans compression, et
        // ce qu'un noyau déballe tout aussi bien.
        (Array("070701".utf8), "cpio"),
    ]

    /// Pourquoi ce fichier ne peut pas être un initramfs — ou `nil` s'il
    /// pourrait en être un.
    ///
    /// Le refus **nomme le fichier et ce qu'il est**. Quelqu'un qui s'est
    /// trompé de bouton doit lire « c'est un noyau », pas « fichier non
    /// reconnu » : la première phrase dit quoi faire, la seconde envoie
    /// chercher.
    public static func refusal(for prefix: Data, name: String) -> String? {
        let bytes = [UInt8](prefix)
        for envelope in envelopes
        where bytes.count >= envelope.magic.count
            && Array(bytes[0..<envelope.magic.count]) == envelope.magic {
            return nil
        }
        switch KernelImageKind.identify(prefix: prefix) {
        case .linuxKernel(let image):
            return """
                \(name) est un noyau Linux pour \(image.architecture.name), \
                au format \(image.format) — pas un initramfs.

                C'est le fichier de l'autre bouton : importez-le comme noyau. \
                L'initramfs est celui que votre distribution appelle \
                `initramfs-…` ou `initrd.img-…`, et il est compressé.
                """
        case .discImage(let format):
            return """
                \(name) est une image de disque amorçable (\(format)).

                wisq ne démarre pas une image d'installation : il lui faut le \
                noyau et l'initramfs, qui sont **dedans**, sous `/boot`. \
                Montez l'image sur un ordinateur et prenez ces deux \
                fichiers-là.
                """
        case .executable(let architecture):
            return "\(name) est un exécutable pour \(architecture.name), pas un initramfs."
        case .compressedKernel, .unknown:
            // Une enveloppe reconnue est déjà partie plus haut : ce qui arrive
            // ici ne commence par aucun magic connu.
            return """
                \(name) ne ressemble à aucun initramfs.

                Un initramfs est une archive `cpio`, presque toujours \
                compressée — gzip, xz, zstd, lz4. Celui-ci ne commence par \
                aucune de ces marques.
                """
        }
    }

    /// La même décision, sur un fichier.
    ///
    /// Les premiers octets suffisent — la marque d'une enveloppe tient dans
    /// cinq — mais on en lit autant que `KernelImageKind`, parce que le refus
    /// s'appuie sur lui pour nommer ce que le fichier est **vraiment**, et que
    /// reconnaître une image de disque demande d'aller jusqu'au secteur seize.
    public static func refusal(forFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return "\(url.lastPathComponent) n'a pas pu être lu."
        }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: KernelImageKind.bytesNeeded) else {
            return "\(url.lastPathComponent) n'a pas pu être lu."
        }
        return refusal(for: prefix, name: url.lastPathComponent)
    }

    /// Ce fichier peut-il être un initramfs ?
    public static func couldBeMedia(fileAt url: URL) -> Bool { refusal(forFileAt: url) == nil }

    // MARK: - À quel noyau il va

    /// Ce qu'on retire du début d'un nom de noyau, et d'un nom d'initramfs.
    ///
    /// L'ordre compte pour `initrd.img` avant `initrd` : le plus long d'abord,
    /// sinon le second mange le début du premier et laisse `.img-6.8…`.
    static let kernelPrefixes = ["vmlinuz", "vmlinux", "bzimage", "image", "kernel"]
    static let mediaPrefixes = ["initramfs", "initrd.img", "initrd"]

    /// Ce qui reste d'un nom une fois son préfixe et son `.img` final retirés,
    /// et ses séparateurs de tête avec.
    ///
    /// C'est cette part-là que deux fichiers d'une même distribution
    /// partagent : `lts` chez Alpine, `6.8.0-31-generic` chez Debian,
    /// `linux` chez Arch.
    static func remainder(of name: String, after prefixes: [String]) -> String {
        var rest = name.lowercased()
        for prefix in prefixes where rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
            break
        }
        if rest.hasSuffix(".img") { rest = String(rest.dropLast(4)) }
        while let first = rest.first, first == "-" || first == "_" || first == "." {
            rest = String(rest.dropFirst())
        }
        return rest
    }

    /// L'initramfs d'un noyau, parmi ceux qu'on a.
    public static func pair(kernel: String, among media: [URL]) -> Pairing {
        let wanted = remainder(of: kernel, after: kernelPrefixes)
        let matching = media.filter {
            remainder(of: $0.lastPathComponent, after: mediaPrefixes) == wanted
        }
        // Un nom qui répond l'emporte sur le compte : deux candidats dont un
        // seul correspond, et c'est lui.
        if let only = matching.first, matching.count == 1 { return .named(only) }
        // Rien ne répond. Un seul candidat reste le bon choix — c'est le cas
        // courant, un noyau et un initramfs importés ensemble — mais deux n'en
        // désignent aucun : en tirer un au hasard fabriquerait un échec.
        if matching.isEmpty, media.count == 1, let only = media.first { return .theOnlyOne(only) }
        return .nothing
    }
}

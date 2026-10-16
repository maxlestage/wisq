import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Un disque vierge, créé dans l'application, pour une machine installée.
///
/// **Pourquoi.** Une machine ne pouvait recevoir comme disque qu'un fichier
/// importé : une image ext4 préparée ailleurs, ou l'ISO elle-même. Installer
/// une distribution demande l'inverse — un disque **vide**, que l'invité
/// partitionne et formate lui-même (`mkfs.ext4 /dev/vda`) et sur lequel il
/// écrit son système. Personne n'a ce fichier sous la main sur un téléphone.
///
/// **Le fichier ne contient rien, et ne doit rien coûter.** C'est une base de
/// zéros que `FileDiskStore` ouvre en lecture seule, comme toute base ; ce que
/// l'invité y écrit va dans la couche tassée de la machine, à 512 octets par
/// secteur touché. La base est donc créée par `ftruncate`, sans un octet écrit.
///
/// **Ce qu'on ne sait pas, et ce que le code fait de ce qu'on ne sait pas.**
/// Ce dépôt a mesuré qu'APFS alloue les trous d'un fichier épars dans lequel
/// on *écrit* — c'est ce qui a fait tasser la couche d'écriture. Qu'un
/// fichier seulement *agrandi* reste épars sur un iPhone n'a pas été mesuré
/// depuis ce conteneur Linux. Plutôt que de le supposer, la création **relève
/// les blocs alloués** juste après et refuse — fichier effacé — si le disque a
/// coûté plus qu'un plafond tenu bas. Dans le pire cas, la personne reçoit une
/// phrase au lieu d'un téléphone plein.
public enum BlankDisk {
    /// Les tailles proposées. Des puissances de deux, comme la mémoire : une
    /// distribution minimale tient dans un gibioctet, une de bureau dans huit.
    public static let sizes: [UInt64] = [1, 2, 4, 8, 16, 32].map { UInt64($0) << 30 }

    /// Ce qu'une base vierge a le droit d'occuper réellement après création.
    ///
    /// Un mébioctet : bien au-dessus des quelques blocs de métadonnées qu'un
    /// système de fichiers peut compter pour un fichier vide, et mille fois
    /// sous le plus petit disque proposé. Un système qui aurait écrit les
    /// zéros dépasse ce plafond dès le premier gibioctet.
    public static let allocationCeiling = 1 << 20

    /// Pourquoi la création n'a pas eu lieu.
    public enum Refusal: Error, Equatable, LocalizedError {
        /// Une taille que la liste ne propose pas : un appel de l'interface
        /// mal câblé, pas un choix à honorer.
        case unsupportedSize(UInt64)
        /// Un fichier de ce nom existe déjà. Rien n'est écrasé.
        case alreadyExists(String)
        /// Le fichier n'a pas pu être créé ou agrandi.
        case cannotCreate(String)
        /// Le système de fichiers a réellement alloué le disque : il aurait
        /// pris sa taille entière sur le téléphone. Le fichier a été effacé.
        case notSparse(allocated: Int, size: UInt64)

        public var errorDescription: String? {
            switch self {
            case .unsupportedSize(let size):
                return "\(KernelMemory.describe(size)) n'est pas une taille de disque proposée."
            case .alreadyExists(let name):
                return "Un fichier nommé \(name) existe déjà ; wisq ne l'écrase pas."
            case .cannotCreate(let name):
                return "Le disque \(name) n'a pas pu être créé."
            case .notSparse(let allocated, let size):
                return """
                    Ce stockage a réservé \(LocalStorage.describe(bytes: allocated)) \
                    pour un disque vierge de \(KernelMemory.describe(size)) : il \
                    l'aurait occupé en entier avant que la machine n'y écrive \
                    quoi que ce soit. wisq l'a effacé plutôt que de remplir le \
                    téléphone.
                    """
            }
        }
    }

    /// Le nom du disque vierge d'une machine, libre dans la bibliothèque.
    ///
    /// Le nom de la machine, réduit à ce qu'un nom de fichier porte sans
    /// surprise, puis « -disque.img » ; un numéro s'il est déjà pris. Le nom
    /// suffit à le reconnaître dans la bibliothèque, où il apparaît comme
    /// n'importe quel disque.
    public static func fileName(forMachine name: String, among taken: [String]) -> String {
        let cleaned = String(name.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" || character == "."
                ? character : "-"
        }.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let stem = (cleaned.isEmpty ? "machine" : cleaned) + "-disque"
        let lowered = Set(taken.map { $0.lowercased() })
        var candidate = stem + ".img"
        var number = 2
        while lowered.contains(candidate.lowercased()) {
            candidate = "\(stem)-\(number).img"
            number += 1
        }
        return candidate
    }

    /// Crée la base d'un disque vierge de cette taille, sans en écrire un octet.
    public static func create(at url: URL, bytes size: UInt64) throws {
        guard sizes.contains(size) else { throw Refusal.unsupportedSize(size) }
        let name = url.lastPathComponent
        // `O_EXCL` : la vérification et la création en un seul appel. Un
        // `fileExists` suivi d'une création laisserait passer un fichier
        // arrivé entre les deux, et l'écraserait.
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else {
            throw errno == EEXIST ? Refusal.alreadyExists(name) : Refusal.cannotCreate(name)
        }
        let grown = ftruncate(descriptor, off_t(size)) == 0
        close(descriptor)
        guard grown else {
            try? FileManager.default.removeItem(at: url)
            throw Refusal.cannotCreate(name)
        }
        let allocated = allocatedBytes(atPath: url.path)
        guard allocated <= allocationCeiling else {
            try? FileManager.default.removeItem(at: url)
            throw Refusal.notSparse(allocated: allocated, size: size)
        }
    }

    /// Ce que le fichier occupe vraiment : ses blocs, pas sa taille apparente.
    ///
    /// `st_blocks` compte en unités de 512 octets sur Linux comme sur les
    /// systèmes d'Apple, quelle que soit la taille de bloc du volume.
    public static func allocatedBytes(atPath path: String) -> Int {
        var info = stat()
        guard stat(path, &info) == 0 else { return 0 }
        return Int(info.st_blocks) * 512
    }
}

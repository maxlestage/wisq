import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Quel disque va avec quel noyau, retenu d'un lancement à l'autre.
///
/// **Pourquoi un réglage et pas une détection.** Le disque de la machine PC
/// est un fichier que la personne apporte, exactement comme le noyau et
/// l'initramfs. Rien dans les octets ne dit « celui-ci est le disque de
/// celui-là » : c'est la même impossibilité que `BootMedia` décrit pour
/// l'initramfs, en pire, puisqu'un disque n'a même pas de convention de nom.
/// Alors on demande, une fois, et on s'en souvient.
///
/// **Il vit dans `WisqVM` et pas dans l'application**, pour la raison que
/// `KernelMemory` donne : l'application ne se construit que sur Apple, donc
/// ce qui vit là ne peut pas être tenu par le coureur qui ne coûte rien. Et
/// « écrire un choix, le relire, survivre à un premier lancement sans rien »
/// mérite un test plutôt qu'un raisonnement.
///
/// **Rangé sous le nom du fichier du noyau**, comme la mémoire et pour la
/// même raison : le chemin de démarrage doit savoir quel disque prendre
/// **avant** de lire l'image, et l'empreinte n'existe qu'après.
///
/// **Et le disque est lu sur place.** `VirtioBlock` lisait son image dans
/// un `[UInt8]`, entière ; c'était le fait qui commandait tout le reste ici —
/// un plafond, un refus, et la phrase que la vue affichait. Il lit maintenant
/// le fichier importé là où il est, en lecture seule, et range ce que
/// l'invité écrit dans une **couche à part** (`FileDiskStore`) qui survit à
/// une suspension, à un redémarrage de l'application et à sa mort. Il n'y a
/// donc plus de plafond : une image d'installation de six gigaoctets se
/// branche comme une ext4 de seize mébioctets. Ce qui reste, c'est le
/// plancher — un secteur.
public enum LocalDisk {
    // MARK: - Ce qui est un disque

    /// Le plus petit qui ait un sens : un secteur.
    ///
    /// `VirtioBlock.sectors` divise par 512 ; en dessous, le noyau voit un
    /// disque de zéro secteur, ce qui n'est pas un disque mais un piège.
    public static let minimumBytes = 512

    /// Pourquoi ce fichier ne peut pas être le disque de cette machine — ou
    /// `nil` s'il peut.
    ///
    /// Il n'y a plus qu'un refus, et il **nomme le nombre qui bloque**. Le
    /// second — « trop gros pour la mémoire » — est parti avec la raison
    /// qu'il avait : le disque n'est plus tenu en mémoire.
    public static func refusal(size: Int, name: String) -> String? {
        refusal(size: size, subject: name)
    }

    /// Le même refus, précédé de **ce que le fichier est**.
    ///
    /// C'est l'ordre qui compte, et il a été payé une fois déjà : une image
    /// d'installation de 5,8 Gio a été refusée avec un chiffre et une phrase
    /// sur la mémoire de l'appareil. Les deux étaient exacts. Le lecteur y
    /// apprenait qu'il lui manque de la place, alors qu'il lui manque un
    /// noyau — et il est reparti chercher un réglage qui n'existe pas.
    ///
    /// Un fichier que rien n'a reconnu garde le refus qu'il avait : composer
    /// avec une identité qu'on n'a pas reviendrait à mettre une phrase vide
    /// devant la seule qui dit quelque chose.
    public static func refusal(size: Int, name: String, kind: KernelImageKind) -> String? {
        guard let identity = KernelImageKind.whatItIs(kind, name: name) else {
            return refusal(size: size, name: name)
        }
        // « Elle », parce que les deux genres que `whatItIs` nomme sont des
        // images : reprendre le nom du fichier une seconde fois se lit comme
        // deux refus collés plutôt que comme un seul.
        guard let why = refusal(size: size, subject: "Elle") else { return nil }
        return identity + "\n\n" + why
    }

    private static func refusal(size: Int, subject: String) -> String? {
        guard size < minimumBytes else { return nil }
        return """
            \(subject) fait \(size) octet\(size == 1 ? "" : "s") — moins \
            d'un secteur.

            Un disque se lit par blocs de 512 octets ; celui-ci n'en \
            contient pas un seul, et l'invité verrait un disque vide.
            """
    }

    /// La même décision, sur un fichier de la bibliothèque.
    public static func refusal(forFileAt url: URL) -> String? {
        guard let size = try? FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int else {
            return "\(url.lastPathComponent) n'a pas pu être lu."
        }
        // Le fichier est là : on peut lire ce qu'il est, donc on le dit.
        return refusal(size: size, name: url.lastPathComponent,
                       kind: KernelImageKind.identify(fileAt: url))
    }

    // MARK: - La couche d'écriture

    /// Le dossier des couches d'écriture, à côté des machines sauvegardées.
    public static func writesDirectory(in directory: URL? = nil) throws -> URL {
        let folder = try (directory ?? Self.directory())
            .appendingPathComponent("disk-writes", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Où vont les écritures de l'invité sur un disque de la bibliothèque.
    ///
    /// **Rangé sous le nom du disque, pas sous celui du noyau.** C'est le
    /// disque qui porte les octets ; deux noyaux qui partagent une image
    /// partagent ce qu'ils y ont écrit, exactement comme deux ordinateurs qui
    /// démarreraient sur le même disque. La carte (`.map`) est posée à côté
    /// par `FileDiskStore`.
    public static func writesURL(for disk: String, in directory: URL? = nil) throws -> URL {
        try writesDirectory(in: directory).appendingPathComponent(disk + ".writes")
    }

    /// Jette la couche d'un disque — quand le fichier de base s'en va. Une
    /// couche sans sa base ne veut plus rien dire, et garder ses secteurs
    /// serait garder des octets que personne ne pourra plus relire.
    public static func discardWrites(for disk: String, in directory: URL? = nil) {
        guard let url = try? writesURL(for: disk, in: directory) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + ".map"))
    }

    /// Ce que la couche d'un disque occupe **réellement** : les blocs
    /// alloués, pas la taille apparente. Le fichier des écritures est épars
    /// et de la taille de la base ; sa taille dirait « six gigaoctets » pour
    /// trois secteurs écrits.
    public static func overlayBytes(for disk: String, in directory: URL? = nil) -> Int {
        guard let folder = try? writesDirectory(in: directory) else { return 0 }
        return overlayBytes(for: disk, inWritesDirectory: folder)
    }

    /// La même mesure, le dossier des couches déjà connu — ce que le rapport
    /// de stockage a sous la main.
    public static func overlayBytes(for disk: String, inWritesDirectory folder: URL) -> Int {
        let path = folder.appendingPathComponent(disk + ".writes").path
        return allocatedBytes(atPath: path) + allocatedBytes(atPath: path + ".map")
    }

    static func allocatedBytes(atPath path: String) -> Int {
        var info = stat()
        guard stat(path, &info) == 0 else { return 0 }
        return Int(info.st_blocks) * 512
    }

    // MARK: - Ce que le disque a vu

    /// Ce qu'il y a à dire quand un disque était branché et que l'invité ne
    /// l'a jamais touché — ou `nil` quand il n'y a rien à dire.
    ///
    /// **C'est la seule limite qui ne bougera pas.** wisq peut émuler le
    /// périphérique ; il ne peut pas mettre le pilote bloc dans le noyau que
    /// quelqu'un apporte. Un noyau qui n'en a pas ne sonde jamais la fenêtre,
    /// et le symptôme est alors un disque parfaitement muet — indiscernable
    /// d'un disque cassé, ou d'un réglage qui n'aurait pas pris.
    ///
    /// Le périphérique compte ses requêtes, donc on peut le dire au lieu de
    /// laisser chercher. Une seule requête, même refusée, prouve que le pilote
    /// est là et que le silence vient d'ailleurs : la phrase se tait alors.
    public static func silenceNote(activity: (served: UInt64, refused: UInt64)?,
                                   disk name: String) -> String? {
        guard let activity, activity.served == 0, activity.refused == 0 else { return nil }
        return """
            L'invité n'a jamais touché \(name) : son noyau n'a pas de pilote \
            bloc, ou ne l'a pas chargé. Le disque était là, sur /dev/vda, et \
            personne n'est venu.
            """
    }

    // MARK: - Ce qu'on peut proposer

    /// Ce fichier peut-il être un disque ?
    ///
    /// **Positivement un système de fichiers, ou rien de connu.** Un noyau
    /// reconnu n'en est pas un — le brancher serait une faute de frappe, pas
    /// un choix —, ni un exécutable, ni une enveloppe compressée : l'invité ne
    /// sait pas décompresser un disque, et un fichier gzip dans cette
    /// bibliothèque est presque toujours l'initramfs d'à côté.
    ///
    /// `unknown` passe, et c'est la même permission qu'ailleurs : quelqu'un
    /// peut tenir une image brute — un ext4 d'un noyau plus vieux, un btrfs
    /// dont la marque est hors de portée — et refuser faute d'avoir su lire
    /// serait pire que de laisser essayer.
    public static func couldBeDisk(_ kind: KernelImageKind) -> Bool {
        isDiskImage(kind) || kind == .unknown
    }

    /// Ce fichier **est** un disque, positivement.
    ///
    /// La distinction avec `couldBeDisk` porte tout son poids sur `unknown`,
    /// et elle décide de quel refus quelqu'un reçoit quand son fichier est
    /// trop gros. Un ext4 de deux gigaoctets est refusé comme disque, avec le
    /// plafond des disques ; un fichier que personne n'a reconnu reste jugé
    /// comme un noyau, parce que c'est ce que quelqu'un apporte quand il ne
    /// dit rien — et parce que ce refus-là est celui qui a été écrit le jour
    /// où l'application a disparu sans un mot devant une image de deux
    /// gigaoctets.
    public static func isDiskImage(_ kind: KernelImageKind) -> Bool {
        switch kind {
        case .filesystemImage, .discImage: return true
        case .unknown, .linuxKernel, .executable, .compressedKernel: return false
        }
    }

    /// Les fichiers de la bibliothèque qu'on peut offrir comme disque de ce
    /// noyau — lui-même exclu, puisqu'un noyau ne se branche pas sur lui-même.
    public static func candidates(among library: [URL], kernel: String) -> [URL] {
        library.filter {
            $0.lastPathComponent != kernel
                && couldBeDisk(KernelImageKind.identify(fileAt: $0))
        }
    }

    // MARK: - Ce dont on se souvient

    /// Le disque choisi pour ce noyau, ou `nil`.
    ///
    /// Un nom qui ne désigne plus rien se lit comme « pas de disque » : le
    /// fichier a pu être supprimé depuis, et démarrer sans disque vaut mieux
    /// que de refuser de démarrer pour un réglage que personne n'a retouché.
    /// C'est à `attached(kernel:among:)` de trancher, parce que lui seul sait
    /// ce que la bibliothèque contient.
    public static func recordedName(forKernel kernel: String, in directory: URL? = nil) -> String? {
        recorded(in: directory)[kernel]
    }

    /// Tous les choix d'un coup, sous le nom du noyau.
    ///
    /// La liste en a besoin : demander noyau par noyau relirait le fichier une
    /// fois par ligne, à chaque redessin.
    public static func allRecorded(in directory: URL? = nil) -> [String: String] {
        recorded(in: directory)
    }

    /// Le disque de ce noyau, tel qu'il existe vraiment.
    public static func attached(kernel: String, among library: [URL],
                                in directory: URL? = nil) -> URL? {
        guard let name = recordedName(forKernel: kernel, in: directory) else { return nil }
        return library.first { $0.lastPathComponent == name }
    }

    /// Retient un choix. `nil` l'efface.
    public static func attach(_ disk: String?, forKernel kernel: String,
                              in directory: URL? = nil) {
        var all = recorded(in: directory)
        if let disk {
            all[kernel] = disk
        } else {
            all.removeValue(forKey: kernel)
        }
        write(all, in: directory)
    }

    /// Oublie le choix d'un noyau — pour un noyau supprimé.
    public static func forget(kernel: String, in directory: URL? = nil) {
        var all = recorded(in: directory)
        guard all.removeValue(forKey: kernel) != nil else { return }
        write(all, in: directory)
    }

    /// Oublie ce fichier partout où il servait de disque — pour un disque
    /// supprimé.
    ///
    /// Sans ça, supprimer une image laisserait derrière elle des noyaux réglés
    /// sur un fichier absent : ils démarreraient sans disque, sans que rien
    /// n'explique pourquoi le réglage a disparu de l'écran.
    @discardableResult
    public static func forgetDisk(named disk: String, in directory: URL? = nil) -> Int {
        var all = recorded(in: directory)
        let kernels = all.filter { $0.value == disk }.map(\.key)
        guard !kernels.isEmpty else { return 0 }
        for kernel in kernels { all.removeValue(forKey: kernel) }
        write(all, in: directory)
        return kernels.count
    }

    // MARK: - Où les choix vivent

    static let fileName = "kernel-disk.json"

    /// À côté de la mémoire et des machines sauvegardées : un seul endroit
    /// tient tout ce que la VM locale retient, et un test peut lui en donner
    /// un autre.
    public static func directory() throws -> URL { try SuspendedMachine.directory() }

    private static func url(in directory: URL?) -> URL? {
        (directory ?? (try? Self.directory()))?.appendingPathComponent(fileName)
    }

    /// Un fichier illisible se lit comme « aucun disque choisi », pour la
    /// raison que `KernelMemory` donne : le pire qui puisse arriver est une
    /// machine sans disque, ce qu'elle était avant que ce réglage existe.
    private static func recorded(in directory: URL?) -> [String: String] {
        guard let url = url(in: directory),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func write(_ all: [String: String], in directory: URL?) {
        guard let url = url(in: directory) else { return }
        if all.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

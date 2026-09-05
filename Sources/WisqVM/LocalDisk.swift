import Foundation

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
/// **Et le disque est en mémoire, entier.** `X86VirtioBlock` tient son image
/// dans un `[UInt8]`, parce que l'invité écrit dedans et que ces écritures
/// doivent survivre à une suspension — l'instantané les emporte avec lui. Ce
/// n'est donc pas un fichier qu'on lit par morceaux : brancher un disque de
/// deux cents mébioctets prend deux cents mébioctets, à côté de la RAM de
/// l'invité et du reste de l'application. C'est le fait qui commande tout le
/// reste ici : le plafond, le refus, et la phrase que la vue affiche.
public enum LocalDisk {
    // MARK: - Ce que la place permet

    /// Le plus gros disque que cet appareil autorise.
    ///
    /// Ce que le téléphone laisse, **moins la machine la plus petite qui
    /// puisse le lire** : un disque qui ne laisse pas la place d'une machine
    /// PC n'est pas un disque, c'est un refus au démarrage écrit d'avance.
    public static func maximumBytes(ceiling limit: UInt32 = KernelMemory.ceiling) -> Int {
        max(Int(limit) - X86Machine.minimumRAMSize, 0)
    }

    /// Le plus petit qui ait un sens : un secteur.
    ///
    /// `X86VirtioBlock.sectors` divise par 512 ; en dessous, le noyau voit un
    /// disque de zéro secteur, ce qui n'est pas un disque mais un piège.
    public static let minimumBytes = 512

    /// Pourquoi ce fichier ne peut pas être le disque de cette machine — ou
    /// `nil` s'il peut.
    ///
    /// Les deux refus **nomment le nombre qui bloque**, parce que « trop
    /// gros » sans chiffre ne dit pas s'il faut changer de fichier ou changer
    /// de téléphone.
    public static func refusal(size: Int, name: String,
                               ceiling limit: UInt32 = KernelMemory.ceiling) -> String? {
        if size < minimumBytes {
            return """
                \(name) fait \(size) octet\(size == 1 ? "" : "s") — moins d'un \
                secteur.

                Un disque se lit par blocs de 512 octets ; celui-ci n'en \
                contient pas un seul, et l'invité verrait un disque vide.
                """
        }
        let maximum = maximumBytes(ceiling: limit)
        guard size > maximum else { return nil }
        return """
            \(name) fait \(LocalStorage.describe(bytes: size)), et wisq ne peut \
            pas en brancher plus de \(LocalStorage.describe(bytes: maximum)) sur \
            ce téléphone en ce moment.

            Le disque est tenu **en mémoire**, entier : c'est ce qui permet à \
            l'invité d'écrire dedans et à ces écritures de survivre à une \
            suspension. Il partage donc la place avec la machine elle-même.
            """
    }

    /// La même décision, sur un fichier de la bibliothèque.
    public static func refusal(forFileAt url: URL,
                               ceiling limit: UInt32 = KernelMemory.ceiling) -> String? {
        guard let size = try? FileManager.default.attributesOfItem(
            atPath: url.path)[.size] as? Int else {
            return "\(url.lastPathComponent) n'a pas pu être lu."
        }
        return refusal(size: size, name: url.lastPathComponent, ceiling: limit)
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

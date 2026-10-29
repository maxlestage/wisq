import Foundation

/// Ce qu'il faut pour démarrer une image de cloud telle qu'elle a été
/// téléchargée : son noyau, son initramfs et sa ligne de commande, trouvés
/// **dans** l'image.
///
/// **Ce qu'on lit, et dans quel ordre.** Le chargeur de la distribution a déjà
/// écrit ce qu'il démarre : `grub.cfg` pour Debian et Ubuntu, les entrées BLS
/// (`/boot/loader/entries/*.conf`) pour Fedora. On reprend sa première entrée
/// telle quelle, ligne de commande comprise, plutôt que de la deviner : un
/// `root=PARTUUID=…` ou un `rootflags=subvol=root` qu'on aurait oubliés, et le
/// système ne trouverait pas sa racine. Faute de configuration, on prend les
/// liens `/vmlinuz` et `/initrd.img` que Debian posait, ou le noyau le plus
/// récent de `/boot`, et une ligne de commande minimale qui désigne la
/// partition par son PARTUUID.
///
/// **La console.** wisq montre le port série de la machine. Une ligne de
/// commande qui ne l'envoie pas vers `ttyS0` laisserait un écran vide : on
/// ajoute alors `console=ttyS0`, et rien d'autre.
public struct CloudBoot: Equatable, Sendable {
    public let kernel: [UInt8]
    public let initrd: [UInt8]?
    public let commandLine: String
    /// D'où viennent ces trois choses, pour le dire : « grub.cfg de vda1 ».
    public let origin: String

    public enum Failure: Error, Equatable, LocalizedError {
        /// Aucune partition Linux lisible.
        case noLinuxPartition
        /// Des partitions lisibles, mais aucun noyau dedans.
        case noKernel
        /// Un mot de passe que la ligne de commande ne peut pas porter.
        case unusablePassword

        public var errorDescription: String? {
            switch self {
            case .noLinuxPartition:
                return "l'image n'a aucune partition Linux que wisq sache lire (ext2, ext3, ext4 ou btrfs)."
            case .noKernel:
                return "aucun noyau n'a été trouvé dans l'image : ni grub.cfg, ni entrée de démarrage, ni /boot/vmlinuz."
            case .unusablePassword:
                return "le mot de passe de root ne doit être ni vide, ni contenir de caractère de contrôle."
            }
        }
    }

    /// Une entrée de chargeur : chemins tels qu'il les écrit, et ses options.
    struct Entry: Equatable {
        let kernel: String
        let initrds: [String]
        let options: [String]
    }

    /// Les endroits où les distributions rangent leur configuration, vus
    /// depuis la racine de la partition qui la porte. Les deux premiers quand
    /// `/boot` est dans la racine, les deux suivants quand il est séparé.
    static let grubPaths = ["/boot/grub/grub.cfg", "/boot/grub2/grub.cfg", "/grub/grub.cfg", "/grub2/grub.cfg"]
    static let blsDirectories = ["/boot/loader/entries", "/loader/entries"]

    /// Cherche de quoi démarrer dans une image : sa table, puis chacune de
    /// ses partitions Linux dans l'ordre de `linuxCandidates`.
    /// `rootPassword`, s'il est donné, devient celui de `root` à la première
    /// mise en route d'un système systemd (voir `firstbootOptions`).
    public static func find(in image: any VirtualDiskImage, rootPassword: String? = nil) throws -> CloudBoot {
        try find(in: image, rootHash: try hash(rootPassword))
    }

    /// La même, avec le mot de passe déjà en empreinte `$6$` : ce que
    /// l'application garde (`RootPassword`), puisqu'elle ne garde jamais le
    /// mot de passe lui-même.
    public static func find(in image: any VirtualDiskImage, rootHash: String?) throws -> CloudBoot {
        let table = try PartitionTable.read(image)
        return try find(in: table, rootHash: rootHash) { try linuxVolume($0, in: image) }
    }

    static func find(in table: PartitionTable, rootPassword: String? = nil,
                     open: (PartitionTable.Partition) throws -> any LinuxVolume) throws -> CloudBoot {
        try find(in: table, rootHash: try hash(rootPassword), open: open)
    }

    /// L'empreinte d'un mot de passe donné en clair, sur un sel neuf, ou le
    /// refus de ce qui ne peut pas en être un.
    static func hash(_ rootPassword: String?) throws -> String? {
        guard let rootPassword else { return nil }
        guard acceptsAsRootPassword(rootPassword) else { throw Failure.unusablePassword }
        return SHA512Crypt.hash(rootPassword, salt: randomSalt())
    }

    static func find(in table: PartitionTable, rootHash: String?,
                     open: (PartitionTable.Partition) throws -> any LinuxVolume) throws -> CloudBoot {
        if let rootHash, !RootPassword.isHash(rootHash) { throw Failure.unusablePassword }
        var readable = false
        // **Puis les partitions EFI**, et seulement pour une entrée
        // configurée : Gentoo monte la sienne sur `/boot`, et son
        // `grub/grub.cfg` y nomme un noyau rangé à côté. Après les
        // partitions Linux, pour qu'une image qui a son `/boot` ailleurs
        // n'aille pas chercher le `grub.cfg` d'amorce de sa partition EFI.
        let efi = table.partitions.filter { $0.kind == .efiSystem }
        for partition in table.linuxCandidates + efi {
            // Une partition qu'on ne sait pas lire (xfs, LVM) n'arrête pas la
            // recherche : une autre, un `/boot` séparé, peut porter le noyau.
            guard let volume = try? open(partition) else { continue }
            // Une partition EFI lisible ne fait pas une partition Linux : le
            // refus d'une image en LVM reste celui qui le dit.
            if partition.kind != .efiSystem { readable = true }
            let name = "vda\(partition.number)"
            if let (entry, origin) = configuredEntry(in: volume) {
                let legacy = usesLegacyConsole(table, open)
                let kernel = try volume.contents(of: entry.kernel)
                // Plusieurs initramfs (le microcode, puis le système) se
                // donnent au noyau mis bout à bout : il lit les archives cpio
                // à la suite, et c'est ce que fait GRUB.
                let initrd = entry.initrds.isEmpty ? nil
                    : try entry.initrds.flatMap { try volume.contents(of: $0) }
                return CloudBoot(kernel: kernel, initrd: initrd,
                                 commandLine: commandLine(entry.options, rootHash: rootHash, legacyConsole: legacy),
                                 origin: "\(origin) de \(name)")
            }
            if partition.kind != .efiSystem, let (kernel, initrd) = unconfiguredKernel(in: volume) {
                let root = partition.uniqueID.isEmpty ? "/dev/\(name)" : "PARTUUID=\(partition.uniqueID)"
                return CloudBoot(kernel: try volume.contents(of: kernel),
                                 initrd: try initrd.map { try volume.contents(of: $0) },
                                 commandLine: commandLine(["root=\(root)", "ro"], rootHash: rootHash,
                                                          legacyConsole: usesLegacyConsole(table, open)),
                                 origin: "\(kernel) de \(name)")
            }
        }
        throw readable ? Failure.noKernel : Failure.noLinuxPartition
    }

    // MARK: - Sur le disque de l'application

    /// **La mémoire d'une image de cloud**, au moins. Le noyau de Debian 13
    /// décompressé fait 35 Mio, son initramfs se déballe en mémoire, et
    /// systemd démarre ensuite une vingtaine de services : la machine de
    /// référence (64 Mio) panique avant la racine. 512 Mio est ce que le banc
    /// a démarré jusqu'au shell de `root`. Un réglage plus haut est gardé.
    public static let minimumRAMSize = 512 << 20

    /// Le nom du noyau sorti d'une image, dans le dossier de déballage. Posé
    /// ici, jamais pris dans l'image : un chemin écrit par qui a fait l'image
    /// ne décide pas où les octets atterrissent.
    public static let kernelName = "vmlinuz"
    /// Celui de l'initramfs, pour la même raison.
    public static let initrdName = "initramfs"

    /// Ce qu'une image de cloud laisse sur le disque pour démarrer.
    public struct Unpacked: Equatable, Sendable {
        public let kernel: URL
        public let initrd: URL?
        public let commandLine: String
        public let origin: String
    }

    /// Pourquoi une image de cloud ne démarre pas, une fois qu'on sait que
    /// c'en est une.
    public enum Refusal: Error, Equatable, Sendable {
        /// L'image est là, mais ce qu'on cherche n'y est pas.
        case notBootable(Failure)
        /// Le disque ou ses tables ne se lisent pas.
        case unreadable(String)
        /// Le noyau ou l'initramfs dépasse ce que l'appelant accepte d'écrire.
        case tooLarge
        /// Le dossier de déballage n'a pas pu être écrit.
        case cannotPrepare
    }

    /// **Une image de cloud, déballée pour démarrer** : son noyau et son
    /// initramfs écrits dans `folder`, sous des noms fixes, et la ligne de
    /// commande qui va avec. L'image elle-même reste où elle est : c'est le
    /// disque de la machine.
    ///
    /// `nil` quand le fichier n'est **pas** une image de cloud — pas de table
    /// de partitions, ou une table vide —, et rien n'est alors écrit : c'est un noyau, ou autre
    /// chose, et l'appelant continue comme avant. Une table présente fait de
    /// l'image un disque, jamais un noyau, et ce qui manque ensuite est un
    /// refus qui le dit.
    ///
    /// Le dossier est refait à neuf, pour que l'initramfs d'une image ne
    /// démarre jamais avec le noyau d'une autre ; et un refus n'y laisse rien.
    public static func unpack(_ url: URL, into folder: URL, rootHash: String? = nil,
                              ceiling: UInt64 = .max) -> Result<Unpacked, Refusal>? {
        let found: CloudBoot
        do {
            guard let image = try VirtualDiskImages.disk(fileAt: url) else { return nil }
            // **Un fichier brut n'est un disque que si sa table se lit**, et
            // porte au moins une partition : le premier secteur de bien des
            // fichiers finit par 0x55AA, avec n'importe quoi devant. Un qcow2,
            // lui, est un disque de toute façon, et sa table abîmée un refus.
            let table: PartitionTable
            do {
                table = try PartitionTable.read(image)
            } catch PartitionTable.Failure.noTable {
                return nil
            } catch where image is RawDiskImage {
                return nil
            }
            guard !table.partitions.isEmpty else { return nil }
            found = try find(in: table, rootHash: rootHash) { try linuxVolume($0, in: image) }
        } catch let failure as Failure {
            return .failure(.notBootable(failure))
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        guard UInt64(found.kernel.count) <= ceiling, UInt64(found.initrd?.count ?? 0) <= ceiling else {
            return .failure(.tooLarge)
        }
        let files = FileManager.default
        try? files.removeItem(at: folder)
        let kernel = folder.appendingPathComponent(kernelName)
        let initrd = found.initrd.map { _ in folder.appendingPathComponent(initrdName) }
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(found.kernel).write(to: kernel)
            if let initrd, let bytes = found.initrd { try Data(bytes).write(to: initrd) }
        } catch {
            try? files.removeItem(at: folder)
            return .failure(.cannotPrepare)
        }
        return .success(Unpacked(kernel: kernel, initrd: initrd, commandLine: found.commandLine,
                                 origin: found.origin))
    }

    /// **Ce fichier est-il une image de cloud ?** Lu sans rien en sortir :
    /// la table de partitions, et au moins une partition où un noyau Linux
    /// peut vivre. De quoi décider, avant de démarrer, s'il faut demander le
    /// mot de passe de `root` ; c'est `unpack` qui dira ensuite si un noyau
    /// s'y trouve vraiment.
    public static func isCloudImage(fileAt url: URL) -> Bool {
        guard let image = try? VirtualDiskImages.disk(fileAt: url),
              let table = try? PartitionTable.read(image)
        else { return false }
        return !table.linuxCandidates.isEmpty
    }

    /// Le refus, en français et sans balisage, pour la console.
    public static func explanation(_ refusal: Refusal, name: String) -> String {
        switch refusal {
        case .notBootable(let failure):
            return "\(name) est une image de disque, mais wisq ne peut pas la démarrer : "
                + (failure.errorDescription ?? "")
        case .unreadable(let why):
            return "\(name) n'a pas pu être lue : \(why)"
        case .tooLarge:
            return "Le noyau ou l'initramfs de \(name) dépasse ce que cette machine peut charger."
        case .cannotPrepare:
            return """
                wisq n'a pas pu préparer de place pour déballer \(name).

                Il reste peut-être trop peu d'espace sur cet appareil.
                """
        }
    }

    // MARK: - Les configurations

    private static func configuredEntry(in volume: any LinuxVolume) -> (Entry, String)? {
        for path in grubPaths {
            guard let bytes = try? volume.contents(of: path),
                  let entry = grubEntry(String(decoding: bytes, as: UTF8.self)),
                  volume.exists(entry.kernel)
            else { continue }
            return (entry, (path as NSString).lastPathComponent)
        }
        for directory in blsDirectories {
            guard let names = try? volume.listing(directory).map(\.name).filter({ $0.hasSuffix(".conf") }) else {
                continue
            }
            // La plus récente d'abord : BLS nomme ses entrées par version, et
            // un tri qui lit les nombres comme des nombres met 6.10 après 6.9.
            for name in names.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                guard let bytes = try? volume.contents(of: "\(directory)/\(name)"),
                      let entry = blsEntry(String(decoding: bytes, as: UTF8.self)),
                      volume.exists(entry.kernel)
                else { continue }
                return (entry, name)
            }
        }
        return nil
    }

    /// La première entrée de premier niveau d'un `grub.cfg` : celle que GRUB
    /// démarre quand `default` vaut 0, ce que les images de cloud écrivent.
    /// Les sous-menus (« Advanced options », le mode de secours) sont
    /// sautés. Dans l'entrée, `linux` et `initrd` sont lus où qu'ils soient,
    /// même dans un `if` ; quand il y en a deux, dans un `if` et son `else`,
    /// c'est le premier, celui de la branche qu'on ne peut pas évaluer mais
    /// que GRUB prend d'ordinaire.
    static func grubEntry(_ text: String) -> Entry? {
        var depth = 0
        var inside = false
        var kernel: String?
        var options: [String] = []
        var initrds: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { continue }
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if !inside && depth == 0 && words.first == "menuentry" { inside = true }
            if inside {
                switch words.first {
                case "linux", "linuxefi", "linux16":
                    if kernel == nil, words.count >= 2 {
                        kernel = path(words[1])
                        options = Array(words.dropFirst(2))
                    }
                case "initrd", "initrdefi", "initrd16":
                    if initrds.isEmpty { initrds = initrdPaths(words.dropFirst()) }
                default:
                    break
                }
            }
            depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if inside && depth <= 0 {
                guard let kernel else {
                    inside = false
                    depth = 0
                    continue
                }
                return Entry(kernel: kernel, initrds: initrds, options: options)
            }
        }
        return nil
    }

    /// Une entrée BLS : des lignes « clé valeur ». `options` peut se répéter,
    /// et ses valeurs s'ajoutent.
    static func blsEntry(_ text: String) -> Entry? {
        var kernel: String?
        var initrds: [String] = []
        var options: [String] = []
        for raw in text.split(separator: "\n") {
            let words = raw.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            switch words.first {
            case "linux": kernel = words.count >= 2 ? path(words[1]) : nil
            case "initrd": initrds += initrdPaths(words.dropFirst())
            case "options": options += words.dropFirst()
            default: break
            }
        }
        return kernel.map { Entry(kernel: $0, initrds: initrds, options: options) }
    }

    /// Les fichiers d'une ligne `initrd`, **sans ses variables de GRUB**.
    /// `tuned`, installé par défaut chez CentOS Stream 10 et les RHEL,
    /// écrit `initrd /boot/initramfs-….img $tuned_initrd` : une variable
    /// que GRUB remplace par rien quand elle n'est pas posée. Prise pour un
    /// fichier, elle faisait refuser toute l'image (« $tuned_initrd
    /// introuvable »). Les options, elles, les laissaient déjà tomber.
    static func initrdPaths(_ words: ArraySlice<String>) -> [String] {
        words.filter { !$0.hasPrefix("$") }.map(path)
    }

    /// Un chemin de GRUB : un éventuel disque en tête, `(hd0,gpt1)/boot/…`,
    /// ne désigne rien qu'on puisse suivre ici, et le reste est relatif à la
    /// racine de la partition.
    static func path(_ word: String) -> String {
        guard word.hasPrefix("("), let close = word.firstIndex(of: ")") else { return word }
        return String(word[word.index(after: close)...])
    }

    /// Ce qu'une machine sans JIT demande à systemd, et pourquoi.
    ///
    /// L'horloge de l'invité avance avec les instructions exécutées, et wisq en
    /// exécute une quinzaine de millions par seconde. Les délais que systemd
    /// prévoit pour une vraie machine n'y suffisent pas. L'image de cloud de
    /// Debian 13 l'a montré :
    /// - le périphérique de `/boot/efi` n'est pas apparu dans les 90 s qu'un
    ///   périphérique reçoit, et systemd est passé en mode de secours ;
    /// - journald a dépassé ses 90 s de démarrage et son chien de garde.
    ///
    /// Ces options ne changent rien pour un système qui n'est pas systemd :
    /// OpenRC ou BusyBox les ignorent.
    static let slowMachineOptions = [
        "systemd.default_device_timeout_sec=600", "systemd.default_timeout_start_sec=600",
        "systemd.service_watchdogs=0",
    ]

    /// **La console série ouverte en `root`, comme une console physique.**
    /// Le délai de `login` (soixante secondes, `LOGIN_TIMEOUT`) couvre
    /// l'authentification **et** l'ouverture de la session ; chez Debian,
    /// `pam_systemd` y attend le gestionnaire `systemd --user` de `root`, et
    /// l'ensemble ne tenait pas dans soixante secondes de temps invité. Le
    /// message d'accueil s'affichait, puis « login: timed out ». Donc :
    /// - `agetty.autologin:root` : `serial-getty` importe les credentials
    ///   `agetty.*` et ouvre la session sans invite ;
    /// - `login.noauth:yes` : `login`, sur cette console seulement, ne
    ///   redemande pas le mot de passe ;
    /// - `systemd.mask=user@0.service` : aucun gestionnaire utilisateur à
    ///   attendre pour `root`.
    ///
    /// **Et, depuis systemd 256, pas de `login` du tout.** Chez Ubuntu 26.04,
    /// `pam_motd` lance les scripts du message d'accueil dans les mêmes
    /// soixante secondes, et `login` a expiré dix-neuf fois avant de passer.
    /// Le credential `systemd.unit-dropin.serial-getty@ttyS0.service` donne
    /// au service de la console série un `ExecStart` qui ouvre `bash` en
    /// shell de connexion, directement sur `ttyS0` (voir `shellOnSerial`).
    /// Un systemd plus ancien l'ignore, et les trois options d'avant
    /// suffisent alors.
    ///
    /// **Et pas d'assistant d'openSUSE.** Sa première mise en route n'est pas
    /// `systemd-firstboot` mais `jeos-firstboot`, une boîte de dialogue qui
    /// prend la console avant le shell et attend qu'on la remplisse — langue,
    /// clavier, licence, mot de passe. Masqué, le shell vient directement ;
    /// ailleurs, l'unité n'existe pas et le masque ne fait rien.
    static let consoleOptions = [
        "systemd.set_credential=agetty.autologin:root", "systemd.set_credential=login.noauth:yes",
        "systemd.set_credential_binary=systemd.unit-dropin.serial-getty@ttyS0.service:"
            + Data(shellOnSerial.utf8).base64EncodedString(),
        "systemd.mask=user@0.service", "systemd.mask=jeos-firstboot.service",
    ]

    /// **La console d'un systemd plus ancien que 256.** AlmaLinux 9, Rocky 9
    /// et CentOS Stream 9 ont systemd 252 : il ignore les deux credentials
    /// qui ouvrent ailleurs le shell sans `login` — `agetty.autologin` et le
    /// drop-in de `serial-getty@ttyS0`, venus avec 256 —, `root` y est
    /// verrouillé, et la console s'arrêtait sur `localhost login:`. Le mot de
    /// passe de première mise en route n'y fait rien non plus : `root` existe
    /// déjà, et systemd 252 ne le touche pas (« Login incorrect », essayé).
    ///
    /// **Le mode de secours, donc**, rien qu'avec la ligne de commande :
    /// `rescue.target` comme cible, et `SYSTEMD_SULOGIN_FORCE=1` pour que
    /// `sulogin` ouvre le shell de `root` même verrouillé — « Press Enter for
    /// maintenance », puis le shell. Essayé sur AlmaLinux 9.8.
    ///
    /// **Pas à côté du système entier**, et ce n'était pas faute d'essayer :
    /// `systemd.wants=rescue.service` avec la cible ordinaire ne démarre
    /// jamais le service, parce que `multi-user.target` le déclare en
    /// conflit. Le prix est dit tel quel : en secours, le réseau et `sshd` ne
    /// démarrent pas d'eux-mêmes — `systemctl start NetworkManager` les
    /// lance, sans quitter le shell. `systemctl default` ou `exit` rendent le
    /// système entier, et la console s'arrête alors sur `login`.
    ///
    /// **Sans reconstruire la base matérielle de udev** : au premier
    /// démarrage de Rocky Linux 9, `systemd-hwdb-update` la recompile, si
    /// lentement sur ce cœur que le périphérique de `/boot` n'apparaît pas à
    /// temps — mode d'urgence. Masqué, udev garde la base livrée dans
    /// l'image, et Rocky ouvre le shell avec `/boot` et `/boot/efi` montés.
    static let legacyConsoleOptions = [
        "systemd.unit=rescue.target", "systemd.setenv=SYSTEMD_SULOGIN_FORCE=1",
        "systemd.mask=jeos-firstboot.service", "systemd.mask=systemd-hwdb-update.service",
    ]

    /// Les dossiers où vit `libsystemd-shared-NNN.so`, selon la famille : la
    /// version est dans son nom, et c'est la seule façon de la lire sans
    /// exécuter quoi que ce soit.
    static let systemdFolders = [
        "/usr/lib/systemd", "/usr/lib64/systemd", "/usr/lib/x86_64-linux-gnu/systemd",
    ]

    /// La version de systemd d'une image, lue sur la première de ses
    /// partitions qui en porte un — pas forcément celle du noyau : AlmaLinux
    /// a son `/boot` à part. `nil` quand rien ne la dit.
    static func systemdVersion(
        in table: PartitionTable, _ open: (PartitionTable.Partition) throws -> any LinuxVolume
    ) -> Int? {
        for partition in table.linuxCandidates {
            guard let volume = try? open(partition) else { continue }
            for folder in systemdFolders {
                guard let entries = try? volume.listing(folder) else { continue }
                let prefix = "libsystemd-shared-"
                let versions = entries.compactMap { entry -> Int? in
                    guard entry.name.hasPrefix(prefix), entry.name.hasSuffix(".so") else { return nil }
                    return Int(entry.name.dropFirst(prefix.count).prefix { $0.isNumber })
                }
                if let version = versions.max() { return version }
            }
        }
        return nil
    }

    /// Vrai seulement quand la version est lue **et** plus ancienne que 256.
    /// Une version qu'on ne lit pas garde la console d'aujourd'hui, celle que
    /// Debian, Ubuntu, Fedora, Arch et openSUSE ont démarrée.
    static func usesLegacyConsole(
        _ table: PartitionTable, _ open: (PartitionTable.Partition) throws -> any LinuxVolume
    ) -> Bool {
        guard let version = systemdVersion(in: table, open) else { return false }
        return version < 256
    }

    /// Le drop-in de la console série. Passé en base64, parce qu'une ligne de
    /// commande du noyau ne porte ni retour à la ligne ni espace dans une
    /// valeur. `-` devant le programme : un shell qui sort ne met pas le
    /// service en échec, et `Restart=always` en ouvre un autre.
    static let shellOnSerial = """
        [Service]
        ExecStart=
        ExecStart=-/bin/bash --login
        StandardInput=tty
        StandardOutput=tty
        WorkingDirectory=/root
        Environment=HOME=/root TERM=vt220

        """

    /// **La première mise en route, sans question.** L'image de Debian 13
    /// arrive avec `root` verrouillé (`!unprovisioned` dans `/etc/shadow`) :
    /// c'est `systemd-firstboot` qui doit lui donner un mot de passe, en le
    /// demandant sur la console (« Press any key to proceed »), et le banc
    /// restait devant cet écran. systemd accepte les réponses d'avance, en
    /// « credentials » passés sur la ligne de commande : la locale, le clavier,
    /// le fuseau et le mot de passe. Il n'a alors rien à demander.
    ///
    /// **Le mot de passe passe en empreinte `$6$`**, calculée ici. Donné en
    /// clair, il se lisait dans `/proc/cmdline`, et `systemd-firstboot` le
    /// chiffrait en yescrypt, si coûteux à vérifier à cette vitesse que
    /// `login` expirait avant la fin. Sans mot de passe, il n'y a rien à
    /// répondre : `systemd-firstboot` est coupé, `root` reste verrouillé
    /// ailleurs que sur la console série.
    static func firstbootOptions(rootHash: String?) -> [String] {
        guard let rootHash else { return ["systemd.firstboot=off"] }
        return [
            "systemd.set_credential=firstboot.locale:C.UTF-8",
            "systemd.set_credential=firstboot.keymap:us",
            "systemd.set_credential=firstboot.timezone:UTC",
            "systemd.set_credential=passwd.hashed-password.root:" + rootHash,
        ]
    }

    /// Un sel de seize caractères de l'alphabet de `crypt`, tiré au hasard.
    static func randomSalt() -> String {
        String(decoding: (0..<16).map { _ in SHA512Crypt.alphabet.randomElement() ?? UInt8(ascii: ".") },
               as: UTF8.self)
    }

    /// Un mot de passe que `login` peut recevoir d'un clavier : non vide, et
    /// sans caractère de contrôle. Il n'a plus à tenir dans la ligne de
    /// commande, où ne passe que son empreinte.
    public static func acceptsAsRootPassword(_ password: String) -> Bool {
        !password.isEmpty && !password.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// La ligne de commande : les options de l'entrée, sans les variables de
    /// GRUB qu'on ne peut pas évaluer (`$vt_handoff`), avec la console série
    /// si elles ne l'y mettent pas, et les délais d'une machine lente, sauf
    /// ceux que l'entrée fixe déjà elle-même.
    static func commandLine(_ options: [String], rootPassword: String?, salt: String) -> String {
        commandLine(options, rootHash: rootPassword.map { SHA512Crypt.hash($0, salt: salt) })
    }

    static func commandLine(_ options: [String], rootHash: String? = nil, legacyConsole: Bool = false) -> String {
        var kept = options.filter { !$0.hasPrefix("$") }
        if !kept.contains(where: { $0 == "console=ttyS0" || $0.hasPrefix("console=ttyS0,") }) {
            kept.append("console=ttyS0")
        }
        for option in slowMachineOptions {
            let key = option.prefix { $0 != "=" }
            if !kept.contains(where: { $0.prefix { $0 != "=" } == key }) { kept.append(option) }
        }
        // Une entrée qui passe déjà des credentials le fait à sa façon, et
        // on n'y ajoute rien.
        guard !kept.contains(where: { $0.hasPrefix("systemd.set_credential") }) else {
            return kept.joined(separator: " ")
        }
        // La console série, toujours : Fedora écrit `systemd.firstboot=off`
        // dans son entrée, et sans ce shell sa console resterait sur
        // `login`, devant un `root` verrouillé. Sa première mise en route,
        // elle, reste celle que l'entrée a choisie.
        kept += legacyConsole ? legacyConsoleOptions : consoleOptions
        if !kept.contains(where: { $0.hasPrefix("systemd.firstboot") }) {
            kept += firstbootOptions(rootHash: rootHash)
        }
        return kept.joined(separator: " ")
    }

    // MARK: - Sans configuration

    /// Le `vmlinuz-*` de la version la plus haute, les nombres lus comme des
    /// nombres : 6.10 vient après 6.9.
    static func newestKernel(_ names: [String]) -> String? {
        names.filter { $0.hasPrefix("vmlinuz-") }
            .max { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    private static func unconfiguredKernel(in volume: any LinuxVolume) -> (String, String?)? {
        if volume.exists("/vmlinuz") {
            return ("/vmlinuz", volume.exists("/initrd.img") ? "/initrd.img" : nil)
        }
        for directory in ["/boot", "/"] {
            guard let names = try? volume.listing(directory).filter({ $0.kind == .file }).map(\.name) else { continue }
            guard let kernel = newestKernel(names) else { continue }
            let version = kernel.dropFirst("vmlinuz-".count)
            let base = directory == "/" ? "" : directory
            let initrd = ["initrd.img-\(version)", "initramfs-\(version).img", "initrd-\(version)"]
                .first { names.contains($0) }
            return ("\(base)/\(kernel)", initrd.map { "\(base)/\($0)" })
        }
        return nil
    }
}

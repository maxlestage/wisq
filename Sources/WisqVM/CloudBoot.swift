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
                return "l'image n'a aucune partition Linux que wisq sache lire (ext2, ext3 ou ext4)."
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
        let table = try PartitionTable.read(image)
        return try find(in: table, rootPassword: rootPassword) { try Ext4Volume($0, in: image) }
    }

    static func find(in table: PartitionTable, rootPassword: String? = nil,
                     open: (PartitionTable.Partition) throws -> Ext4Volume) throws -> CloudBoot {
        if let rootPassword, !acceptsAsRootPassword(rootPassword) { throw Failure.unusablePassword }
        var readable = false
        for partition in table.linuxCandidates {
            // Une partition qui n'est pas un ext (btrfs, xfs) n'arrête pas la
            // recherche : chez Fedora, la racine est en btrfs, et c'est le
            // `/boot` séparé qu'on lit.
            guard let volume = try? open(partition) else { continue }
            readable = true
            let name = "vda\(partition.number)"
            if let (entry, origin) = configuredEntry(in: volume) {
                let kernel = try volume.contents(of: entry.kernel)
                // Plusieurs initramfs (le microcode, puis le système) se
                // donnent au noyau mis bout à bout : il lit les archives cpio
                // à la suite, et c'est ce que fait GRUB.
                let initrd = entry.initrds.isEmpty ? nil
                    : try entry.initrds.flatMap { try volume.contents(of: $0) }
                return CloudBoot(kernel: kernel, initrd: initrd,
                                 commandLine: commandLine(entry.options, rootPassword: rootPassword),
                                 origin: "\(origin) de \(name)")
            }
            if let (kernel, initrd) = unconfiguredKernel(in: volume) {
                let root = partition.uniqueID.isEmpty ? "/dev/\(name)" : "PARTUUID=\(partition.uniqueID)"
                return CloudBoot(kernel: try volume.contents(of: kernel),
                                 initrd: try initrd.map { try volume.contents(of: $0) },
                                 commandLine: commandLine(["root=\(root)", "ro"], rootPassword: rootPassword),
                                 origin: "\(kernel) de \(name)")
            }
        }
        throw readable ? Failure.noKernel : Failure.noLinuxPartition
    }

    // MARK: - Sur le disque de l'application

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
    public static func unpack(_ url: URL, into folder: URL, rootPassword: String? = nil,
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
            found = try find(in: table, rootPassword: rootPassword) { try Ext4Volume($0, in: image) }
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

    private static func configuredEntry(in volume: Ext4Volume) -> (Entry, String)? {
        for path in grubPaths {
            guard let bytes = try? volume.contents(of: path),
                  let entry = grubEntry(String(decoding: bytes, as: UTF8.self)),
                  volume.exists(entry.kernel)
            else { continue }
            return (entry, (path as NSString).lastPathComponent)
        }
        for directory in blsDirectories {
            guard let names = try? volume.list(directory).map(\.name).filter({ $0.hasSuffix(".conf") }) else {
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
                    if initrds.isEmpty { initrds = words.dropFirst().map(path) }
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
            case "initrd": initrds += words.dropFirst().map(path)
            case "options": options += words.dropFirst()
            default: break
            }
        }
        return kernel.map { Entry(kernel: $0, initrds: initrds, options: options) }
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
    static let consoleOptions = [
        "systemd.set_credential=agetty.autologin:root", "systemd.set_credential=login.noauth:yes",
        "systemd.mask=user@0.service",
    ]

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
    static func firstbootOptions(rootPassword: String?, salt: String) -> [String] {
        guard let rootPassword else { return ["systemd.firstboot=off"] }
        return [
            "systemd.set_credential=firstboot.locale:C.UTF-8",
            "systemd.set_credential=firstboot.keymap:us",
            "systemd.set_credential=firstboot.timezone:UTC",
            "systemd.set_credential=passwd.hashed-password.root:" + SHA512Crypt.hash(rootPassword, salt: salt),
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
    static func commandLine(_ options: [String], rootPassword: String? = nil,
                            salt: String = randomSalt()) -> String {
        var kept = options.filter { !$0.hasPrefix("$") }
        if !kept.contains(where: { $0 == "console=ttyS0" || $0.hasPrefix("console=ttyS0,") }) {
            kept.append("console=ttyS0")
        }
        for option in slowMachineOptions {
            let key = option.prefix { $0 != "=" }
            if !kept.contains(where: { $0.prefix { $0 != "=" } == key }) { kept.append(option) }
        }
        // Une entrée qui règle déjà la première mise en route le fait à sa
        // façon, et on n'y ajoute rien.
        if !kept.contains(where: { $0.hasPrefix("systemd.firstboot") || $0.hasPrefix("systemd.set_credential") }) {
            kept += consoleOptions + firstbootOptions(rootPassword: rootPassword, salt: salt)
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

    private static func unconfiguredKernel(in volume: Ext4Volume) -> (String, String?)? {
        if volume.exists("/vmlinuz") {
            return ("/vmlinuz", volume.exists("/initrd.img") ? "/initrd.img" : nil)
        }
        for directory in ["/boot", "/"] {
            guard let names = try? volume.list(directory).filter({ $0.kind == .file }).map(\.name) else { continue }
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

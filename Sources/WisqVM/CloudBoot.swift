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

        public var errorDescription: String? {
            switch self {
            case .noLinuxPartition:
                return "l'image n'a aucune partition Linux que wisq sache lire (ext2, ext3 ou ext4)."
            case .noKernel:
                return "aucun noyau n'a été trouvé dans l'image : ni grub.cfg, ni entrée de démarrage, ni /boot/vmlinuz."
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
    public static func find(in image: any VirtualDiskImage) throws -> CloudBoot {
        let table = try PartitionTable.read(image)
        return try find(in: table) { try Ext4Volume($0, in: image) }
    }

    static func find(in table: PartitionTable,
                     open: (PartitionTable.Partition) throws -> Ext4Volume) throws -> CloudBoot {
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
                                 commandLine: commandLine(entry.options), origin: "\(origin) de \(name)")
            }
            if let (kernel, initrd) = unconfiguredKernel(in: volume) {
                let root = partition.uniqueID.isEmpty ? "/dev/\(name)" : "PARTUUID=\(partition.uniqueID)"
                return CloudBoot(kernel: try volume.contents(of: kernel),
                                 initrd: try initrd.map { try volume.contents(of: $0) },
                                 commandLine: commandLine(["root=\(root)", "ro"]),
                                 origin: "\(kernel) de \(name)")
            }
        }
        throw readable ? Failure.noKernel : Failure.noLinuxPartition
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
    /// Debian 13 l'a montré en trois démarrages :
    /// - le périphérique de `/boot/efi` n'est pas apparu dans les 90 s qu'un
    ///   périphérique reçoit, et systemd est passé en mode de secours ;
    /// - journald a dépassé ses 90 s de démarrage et son chien de garde ;
    /// - `systemd-firstboot` attendait une touche sur la console, avec « Press
    ///   any key to proceed », pour une installation qui n'en a pas besoin.
    ///
    /// Les quatre options ne changent rien pour un système qui n'est pas
    /// systemd : OpenRC ou BusyBox les ignorent.
    static let slowMachineOptions = [
        "systemd.default_device_timeout_sec=600", "systemd.default_timeout_start_sec=600",
        "systemd.service_watchdogs=0", "systemd.firstboot=off",
    ]

    /// La ligne de commande : les options de l'entrée, sans les variables de
    /// GRUB qu'on ne peut pas évaluer (`$vt_handoff`), avec la console série
    /// si elles ne l'y mettent pas, et les délais d'une machine lente, sauf
    /// ceux que l'entrée fixe déjà elle-même.
    static func commandLine(_ options: [String]) -> String {
        var kept = options.filter { !$0.hasPrefix("$") }
        if !kept.contains(where: { $0 == "console=ttyS0" || $0.hasPrefix("console=ttyS0,") }) {
            kept.append("console=ttyS0")
        }
        for option in slowMachineOptions {
            let key = option.prefix { $0 != "=" }
            if !kept.contains(where: { $0.prefix { $0 != "=" } == key }) { kept.append(option) }
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

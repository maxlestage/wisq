import Foundation

/// **Fabriquer un bureau prêt** : démarrer une image jusqu'à son bureau, une
/// fois, sous Linux, et l'emporter dans une archive `.wisqmachine` que
/// l'application importe et reprend en quelques secondes — au lieu de la
/// demi-heure que le bureau Xfce met à venir sous l'interprète.
///
/// Ce qui vit ici est tout ce qui se juge sans l'image : la machine, le
/// déroulé, la vérification de l'instantané, l'assemblage de l'archive et sa
/// fiche. L'outil `wisq-fabrique` ne fait que les enchaîner, avec le noyau
/// sorti de l'image par `IsoBoot` — **le même code que sur le téléphone** :
/// c'est l'empreinte de ce noyau qui nomme la session, et un noyau extrait
/// autrement, à un octet près, serait une session que l'application ne
/// trouverait jamais.
public enum ReadyDesktopBuild {
    /// **Le bureau Void Xfce**, de l'invite de connexion jusqu'à la
    /// sauvegarde. Les comptes sont ceux de l'image (`root`, `voidlinux`).
    ///
    /// L'invite d'abord, puis la commande : ce qui est tapé pendant que
    /// `login` vérifie le mot de passe est jeté. Le panneau, puis le temps
    /// qu'il se pose, puis l'écran dessiné — pas un temps fixé : sous
    /// l'interprète, `xfdesktop` met longtemps à charger son fond.
    ///
    /// **Avant de sauver**, la préparation (`prepare`), puis l'écran encore
    /// une fois : on n'emporte pas un écran noir.
    public static let voidXfce: [GuestScript.Step] = [
        .expect("login:"),
        .type("root\n"),
        .expect("Password:"),
        .type("voidlinux\n"),
        .expect("# "),
        .type("until pgrep -x xfce4-panel >/dev/null; do sleep 5; done; sleep 30; echo BUREAU_$((1+1))\n"),
        .expect("BUREAU_2"),
        .screenLit,
        .type(prepare),
        .expect("PRET_2"),
        .screenLit,
    ]

    /// **Ce qu'on tape avant de sauver.**
    ///
    /// - Les clés d'hôte SSH, s'il y en a : l'instantané est le même pour
    ///   tous ceux qui le téléchargent, et une clé d'hôte partagée n'en est
    ///   plus une. `sshd` les refait à son prochain départ.
    /// - `sync`, puis `drop_caches` : Linux remplit la mémoire libre de
    ///   cache, et l'instantané écrit tout ce qui n'est pas nul. Le bureau
    ///   sauvé sans ça portait 936 Mio de pages non nulles pour 1 Gio.
    ///   Vider le cache ne suffit pas à lui seul : une page libérée garde son
    ///   contenu. C'est `init_on_free=1` (`commandLine`) qui la met à zéro.
    public static let prepare =
        "rm -f /etc/ssh/ssh_host_*; sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2; echo PRET_$((1+1))\n"

    /// **La mise à zéro des pages libérées**, que la fabrication ajoute à la
    /// ligne de l'image. Le noyau de Void met les pages à zéro à
    /// l'allocation, pas à la libération : sans ce mot, `drop_caches` rend
    /// des pages libres pleines de leur ancien contenu.
    ///
    /// La ligne de la fabrication n'a pas à être celle de l'application :
    /// une machine reprise ne la relit pas.
    public static let zeroOnFree = "init_on_free=1"

    /// La ligne de l'image (`IsoBoot.commandLine`), plus `zeroOnFree`.
    /// Placé avant la console de wisq, qui doit rester la dernière : Linux
    /// retient le dernier `console=` comme `/dev/console`.
    public static func commandLine(_ line: String, zeroingFreedPages: Bool = true) -> String {
        guard zeroingFreedPages, !line.split(separator: " ").contains(Substring(zeroOnFree)) else {
            return line
        }
        return ([zeroOnFree] + line.split(separator: " ").map(String.init)).joined(separator: " ")
    }

    /// **La machine de l'application**, pour fabriquer : celle que
    /// `GuestMachineFactory.make` construit pour un noyau de PC — la carte
    /// réseau branchée —, l'écran de l'application et sa tablette.
    ///
    /// Une machine qui n'est pas celle de l'application fabrique un bureau
    /// que l'application reprend mal : sans carte réseau, la reprise
    /// remplace celle du téléphone par rien, et le bureau n'a plus de réseau ;
    /// sur un autre écran, le noyau a réglé un mode que la reprise n'applique
    /// pas, et l'écran reste noir.
    ///
    /// Deux écarts, et seulement pour que deux fabrications donnent le même
    /// bureau : le réseau **isolé** (le bail est servi, rien ne sort) et
    /// l'heure **figée** à `frozenAt`. L'aléa reste la suite fixée : le
    /// téléphone prend celui du système à la reprise (`X86Entropy`).
    public static func machine(
        ramSize: Int, frozenAt: Date?, onOutput: @escaping @Sendable (Data) -> Void
    ) throws -> X86Machine {
        guard let machine = GuestMachineFactory.make(
            for: .x86_64, ramSizeBytes: ramSize, onOutput: onOutput,
            network: { UserNetwork.isolated() }) as? X86Machine
        else { throw Refusal.notAPC }
        machine.entropy = .seeded(X86Entropy.reproducibleSeed)
        machine.frozenHostTime = frozenAt
        try GuestMachineFactory.attachScreen(to: machine)
        return machine
    }

    /// Pourquoi un instantané n'est pas un bureau prêt.
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        case notAPC
        /// L'instantané ne se reprend pas du tout.
        case unreadable(String)
        /// Pris sans carte réseau : repris, le bureau n'aurait pas de réseau.
        case noNetwork
        /// L'écran repris est noir : pris sur un écran d'une autre taille, ou
        /// avant que le bureau soit dessiné.
        case darkScreen(lit: Double)
        /// Pas de tablette : le toucher ne pointerait plus.
        case noTablet
        /// La mémoire sauvée n'est pas celle qu'annonce la fiche.
        case memory(saved: Int?, expected: Int)
        /// Le niveau de machine sauvé n'est pas celui de cette version.
        case level(saved: UInt64?, expected: UInt64)

        public var description: String {
            switch self {
            case .notAPC: return "la fabrique n'a pas reçu une machine PC"
            case .unreadable(let why): return "l'instantané ne se reprend pas : \(why)"
            case .noNetwork: return "l'instantané n'a pas de carte réseau"
            case .darkScreen(let lit):
                return "l'écran repris est noir (\(Int(lit * 100)) % allumé)"
            case .noTablet: return "l'instantané n'a pas de tablette"
            case .memory(let saved, let expected):
                return "mémoire sauvée \(saved.map(String.init) ?? "illisible"), attendue \(expected)"
            case .level(let saved, let expected):
                return "niveau sauvé \(saved.map(String.init) ?? "illisible"), attendu \(expected)"
            }
        }
    }

    /// **Reprendre l'instantané dans une machine de l'application neuve**,
    /// comme le fera le téléphone, et vérifier ce qu'il en reviendra : la
    /// carte réseau, l'écran dessiné, la tablette, la mémoire, le niveau.
    /// Rend la part de l'écran repris qui est allumée.
    @discardableResult
    public static func check(_ snapshot: Data, ramSize: Int) throws -> Double {
        let level = X86Machine.savedLevel(in: snapshot)
        guard level == X86Machine.snapshotLevel else {
            throw Refusal.level(saved: level, expected: X86Machine.snapshotLevel)
        }
        let saved = X86Machine.savedRAMSize(in: snapshot)
        guard saved == ramSize else { throw Refusal.memory(saved: saved, expected: ramSize) }
        let machine = try Self.machine(ramSize: ramSize, frozenAt: nil, onOutput: { _ in })
        do {
            try machine.restore(snapshot)
        } catch {
            throw Refusal.unreadable(String(describing: error))
        }
        guard machine.network != nil else { throw Refusal.noNetwork }
        guard machine.tablet?.isReady == true else { throw Refusal.noTablet }
        let lit = GuestScript.litFraction(machine.screenPixels ?? [])
        guard lit > 0.5 else { throw Refusal.darkScreen(lit: lit) }
        return lit
    }

    // MARK: - L'assemblage

    /// **La machine installée qu'on emportera**, dans un dossier à part qui
    /// tient lieu de stockage de l'application, et la couche d'écriture que la
    /// fabrication doit donner au disque : celle que l'application lui
    /// donnerait, sous la clé de cette machine (`MachineKeys.overlay`).
    ///
    /// `image` est le **nom** de l'image dans la bibliothèque du téléphone —
    /// celui que la feuille « Télécharger » lui donne —, pas celui du fichier
    /// qu'on a sous la main : l'import cherche l'image par son nom.
    public static func install(
        image: String, name: String, in work: URL, now: Date = Date()
    ) throws -> (machine: InstalledMachine, writes: URL) {
        let machine = try InstalledMachines.install(image: image, name: name, in: work, now: now)
        let writes = try LocalDisk.writesURL(for: machine.keys.overlay(forDisk: image), in: work)
        for suffix in ["", ".map"] { try? FileManager.default.removeItem(atPath: writes.path + suffix) }
        return (machine, writes)
    }

    /// **La session rangée là où l'application la cherchera**, la mémoire
    /// réglée, puis l'archive écrite par `MachineArchive.export`.
    ///
    /// La session est nommée par l'empreinte de `kernel` — les octets du
    /// noyau que le téléphone sortira de l'image, pas ceux de l'image. Rend
    /// cette identité.
    @discardableResult
    public static func assemble(
        _ machine: InstalledMachine, snapshot: Data, kernel: Data, ramSize: UInt64,
        kernels: URL, in work: URL, to archive: URL
    ) throws -> String {
        KernelMemory.setSize(ramSize, forKernel: machine.key, in: work)
        let identity = SuspendedMachine.identity(of: kernel, named: machine.key)
        try SuspendedMachine.savePacked(SnapshotFile.pack(snapshot), kernel: identity, in: work)
        try MachineArchive.export(machine, kernels: kernels, in: work, to: archive)
        return identity
    }

    /// L'empreinte d'un noyau, telle qu'elle nomme sa session.
    public static func kernelDigest(_ kernel: Data) -> String {
        String(SuspendedMachine.digest(kernel), radix: 16)
    }

    // MARK: - La fiche

    /// **Ce qu'on publie à côté de l'archive** : de quoi vérifier ce qu'on
    /// télécharge, et de quoi décider si une application peut le reprendre.
    public struct Sheet: Codable, Equatable, Sendable {
        /// Un fichier, par son nom, sa taille et sa somme.
        public struct File: Codable, Equatable, Sendable {
            public var name: String
            public var bytes: UInt64
            public var sha256: String

            public init(name: String, bytes: UInt64, sha256: String) {
                self.name = name
                self.bytes = bytes
                self.sha256 = sha256
            }

            /// Mesuré sur le fichier.
            public static func measure(_ url: URL, name: String? = nil) throws -> File {
                File(name: name ?? url.lastPathComponent, bytes: try MachineArchive.size(of: url),
                     sha256: try SHA256Stream.hex(ofFileAt: url))
            }
        }

        public var title: String
        /// `X86Machine.snapshotLevel` de la machine qui a fabriqué.
        public var level: UInt64
        /// L'image, sous le nom que l'archive lui donne.
        public var image: File
        public var archive: File
        /// L'empreinte du noyau sorti de l'image : la session porte ce nom.
        public var kernelDigest: String
        public var ramBytes: UInt64
        public var screen: [Int]
        /// La ligne de la fabrication (celle de l'image, plus `zeroOnFree`).
        public var commandLine: String
        public var madeAt: Date
        /// L'heure que l'horloge CMOS a donnée, figée, pendant la fabrication.
        public var guestClock: Date?
        public var instructions: UInt64
        /// L'instantané brut, et tel qu'il est rangé dans l'archive.
        public var snapshotBytes: UInt64
        public var packedBytes: UInt64
        public var commit: String?

        public init(title: String, level: UInt64, image: File, archive: File, kernelDigest: String,
                    ramBytes: UInt64, screen: [Int], commandLine: String, madeAt: Date,
                    guestClock: Date?, instructions: UInt64, snapshotBytes: UInt64,
                    packedBytes: UInt64, commit: String?) {
            self.title = title
            self.level = level
            self.image = image
            self.archive = archive
            self.kernelDigest = kernelDigest
            self.ramBytes = ramBytes
            self.screen = screen
            self.commandLine = commandLine
            self.madeAt = madeAt
            self.guestClock = guestClock
            self.instructions = instructions
            self.snapshotBytes = snapshotBytes
            self.packedBytes = packedBytes
            self.commit = commit
        }

        /// En JSON lisible, clés triées : deux fiches se comparent ligne à
        /// ligne.
        public func encoded() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(self)
        }

        public static func decode(_ data: Data) throws -> Sheet {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Sheet.self, from: data)
        }
    }
}

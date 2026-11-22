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
    /// une fois : on n'emporte pas un écran noir. Une préparation qui n'a pas
    /// tenu (`sshd` encore là, pas d'horloge à guetter) arrête la
    /// fabrication tout de suite, au lieu d'emporter une clé partagée.
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
        .expectUnless("PRET_2", refused: preparationRefused),
        .screenLit,
    ]

    /// **Ce qu'on tape avant de sauver.**
    ///
    /// - **`sshd` arrêté, puis ses clés d'hôte effacées.** L'instantané est
    ///   le même pour tous ceux qui le téléchargent, et une clé d'hôte
    ///   partagée n'en est plus une. Effacer les fichiers ne suffisait pas :
    ///   depuis OpenSSH 9.8, l'écouteur (`sshd -D [listener]`, 9.9p1 dans
    ///   le bureau Void) charge les clés **en mémoire** au départ et les
    ///   passe à chaque `sshd-session`. Il tournait dans l'instantané, et
    ///   toutes les copies auraient présenté la clé de la fabrication tant
    ///   qu'il ne redémarrait pas — et rien ne le redémarrait. Arrêté
    ///   (`sv down`, que `runsv` respecte), sa mémoire est rendue, et
    ///   `init_on_free=1` la met à zéro.
    /// - **Le guetteur** (`keyWatcher`), lancé à part, qui refait les clés et
    ///   relance `sshd` une fois la machine reprise.
    /// - `sync`, puis `drop_caches` : Linux remplit la mémoire libre de
    ///   cache, et l'instantané écrit tout ce qui n'est pas nul. Le bureau
    ///   sauvé sans ça portait 936 Mio de pages non nulles pour 1 Gio.
    ///   Vider le cache ne suffit pas à lui seul : une page libérée garde son
    ///   contenu. C'est `init_on_free=1` (`commandLine`) qui la met à zéro.
    /// - **La preuve, avant la marque** : `PRET_2` ne vient que si aucun
    ///   `sshd` ne tourne plus et que l'horloge à guetter existe ; sinon
    ///   `REFUS_4` (`preparationRefused`).
    public static let prepare = "sv down sshd; rm -f /etc/ssh/ssh_host_*; "
        + "setsid sh -c '\(keyWatcher)' </dev/null >/dev/null 2>&1 & "
        + "sync; echo 3 > /proc/sys/vm/drop_caches; sleep 2; "
        + "if pgrep -x sshd >/dev/null || ! test -r \(rtcSeconds); then echo REFUS_$((2+2)); "
        + "else echo PRET_$((1+1)); fi\n"

    /// La marque d'une préparation qui n'a pas tenu.
    public static let preparationRefused = "REFUS_4"

    /// L'horloge CMOS telle que l'invité la lit, **à chaque lecture** : le
    /// pilote `rtc_cmos` relit les registres, il ne garde pas l'heure du
    /// démarrage.
    public static let rtcSeconds = "/sys/class/rtc/rtc0/since_epoch"

    /// **Le guetteur des clés**, un `sh` qui dort dans l'instantané.
    ///
    /// *Quand* : l'horloge CMOS de la fabrication est figée
    /// (`X86Machine.frozenHostTime`), celle du téléphone avance. Tant que
    /// `rtcSeconds` ne bouge pas, on est encore à la fabrique ; dès qu'il
    /// bouge, la machine a été reprise ailleurs.
    ///
    /// *Pourquoi attendre encore soixante-cinq secondes* : l'état du
    /// générateur du noyau (le CRNG) est dans l'instantané, le même pour
    /// toutes les copies. Des clés tirées tout de suite pourraient sortir de
    /// cet état-là, donc être les mêmes partout. Le noyau ne le réensemence
    /// qu'au plus toutes les soixante secondes, et c'est ce réensemencement
    /// qui mêle `RDSEED` et `RDRAND` — l'aléa du téléphone (`X86Entropy`).
    /// Après soixante-cinq secondes, le premier tirage le provoque.
    ///
    /// Puis `ssh-keygen -A` (les clés qui manquent) et `sv up sshd`.
    public static let keyWatcher = watcher(clock: rtcSeconds, poll: "5", settle: "\(reseedWait)")

    /// L'attente, en secondes de l'invité, entre l'horloge qui bouge et les
    /// clés : plus que l'intervalle de réensemencement du noyau
    /// (`CRNG_RESEED_INTERVAL`, soixante secondes), avec de la marge.
    static let reseedWait = 65

    /// Le guetteur sur une autre horloge et d'autres attentes : celui de
    /// l'invité, en secondes, ou celui d'un test, en fractions.
    static func watcher(clock: String, poll: String, settle: String) -> String {
        "r=\(clock); t=$(cat $r); while [ \"$(cat $r)\" = \"$t\" ]; do sleep \(poll); done; "
            + "sleep \(settle); ssh-keygen -A; sv up sshd"
    }

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
    /// Deux écarts, pour que rien du dehors n'entre dans la fabrication : le
    /// réseau **isolé** (le bail est servi, rien ne sort) et l'heure
    /// **figée** à `frozenAt`, pour l'horloge CMOS **et** pour le NTP de la
    /// passerelle (`UserNetwork.hostClock`). L'aléa reste la suite fixée : le
    /// téléphone prend celui du système à la reprise (`X86Entropy`). Que
    /// deux fabrications donnent alors le même bureau se mesure (voir le
    /// journal), cela ne se suppose pas.
    public static func machine(
        ramSize: Int, frozenAt: Date?, onOutput: @escaping @Sendable (Data) -> Void
    ) throws -> X86Machine {
        let hostClock: @Sendable () -> Date
        if let frozenAt { hostClock = { frozenAt } } else { hostClock = { Date() } }
        guard let machine = GuestMachineFactory.make(
            for: .x86_64, ramSizeBytes: ramSize, onOutput: onOutput,
            network: { UserNetwork.isolated(hostClock: hostClock) }) as? X86Machine
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
        /// La mémoire sauvée n'est pas une taille que l'application règle.
        case unrecordableMemory(Int)
        /// Une option de la fabrication qui ne se lit pas.
        case unreadableOption(String, value: String)
        /// Moins de mémoire que l'image n'en demande.
        case memoryBelowMinimum(requested: Int, minimum: Int)

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
            case .unrecordableMemory(let bytes):
                return "la mémoire (\(bytes >> 20) Mio) n'est pas un réglage de l'application"
            case .unreadableOption(let option, let value):
                return "\(option) illisible : « \(value) »"
            case .memoryBelowMinimum(let requested, let minimum):
                return "\(requested >> 20) Mio demandés, l'image en veut au moins \(minimum >> 20)"
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

    // MARK: - Les réglages, jugés avant de démarrer

    /// **La mémoire de la fabrication**, décidée avant la demi-heure de
    /// démarrage et pas après : `--ram 1500` tournait jusqu'au bout, puis
    /// `assemble` refusait une taille que l'application ne règle pas.
    ///
    /// Sans `--ram` (`requestedMiB` nil), le plancher de l'image. Une valeur
    /// illisible, sous le plancher, ou hors des réglages de l'application est
    /// refusée en le disant.
    public static func memory(requestedMiB text: String?, minimum: Int) throws -> Int {
        let floor = max(X86Machine.minimumRAMSize, minimum)
        var ram = floor
        if let text {
            guard let mebibytes = Int(text), mebibytes > 0, mebibytes <= Int.max >> 21 else {
                throw Refusal.unreadableOption("--ram", value: text)
            }
            ram = mebibytes << 20
            guard ram >= floor else { throw Refusal.memoryBelowMinimum(requested: ram, minimum: floor) }
        }
        guard isRecordable(ram) else { throw Refusal.unrecordableMemory(ram) }
        return ram
    }

    /// Le budget de chaque attente, en instructions : deux mille milliards
    /// sans `--budget`. Un budget illisible ou nul est refusé — il était
    /// remplacé sans un mot par celui par défaut.
    public static func budget(_ text: String?) throws -> UInt64 {
        guard let text else { return defaultBudget }
        guard let budget = UInt64(text), budget > 0 else { throw Refusal.unreadableOption("--budget", value: text) }
        return budget
    }

    public static let defaultBudget: UInt64 = 2_000_000_000_000

    /// **Le cœur de la fabrication** (`--coeur`) : `swift` sans l'option,
    /// comme avant elle ; `rust` pour la machine PC en Rust
    /// (`RustReadyDesktopBuild`). Toute autre valeur est refusée en le
    /// disant, avant le démarrage.
    public static func core(_ text: String?) throws -> ReadyDesktop.Core {
        guard let text else { return .swift }
        guard let core = ReadyDesktop.Core(rawValue: text) else {
            throw Refusal.unreadableOption("--coeur", value: text)
        }
        return core
    }

    /// **Une taille que l'application sait régler**, ou rien : `setSize`
    /// ignore sans rien dire une taille hors de ses choix, et l'archive
    /// annoncerait alors la mémoire par défaut à côté d'une session qui en
    /// veut une autre.
    static func isRecordable(_ ram: Int) -> Bool {
        ram > 0 && (KernelMemory.isRecordable(UInt64(ram)) || UInt64(ram) == KernelMemory.defaultSize)
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
    /// noyau que le téléphone sortira de l'image, pas ceux de l'image. La
    /// mémoire réglée est celle que l'instantané porte : la session l'impose
    /// de toute façon à la reprise (`SessionMemory`), et deux nombres pour la
    /// même chose finiraient par différer. Rend l'identité de la session.
    ///
    /// Les images de la bibliothèque, dont `export` ne se sert que pour
    /// mesurer un disque propre à la machine, sont cherchées dans `work` :
    /// une machine de fabrication n'en a pas.
    @discardableResult
    public static func assemble(
        _ machine: InstalledMachine, snapshot: Data, kernel: Data, in work: URL, to archive: URL
    ) throws -> String {
        // Lue par le cœur qui a écrit l'instantané, comme l'application la
        // lira (`SessionMemory`) : l'en-tête `WISQPC\r\n` pour le cœur Rust,
        // la section de la mémoire pour `X86Machine`.
        guard let ram = SessionMemory.savedRAMSize(snapshot, core: .x86_64) else {
            throw Refusal.unreadable("la taille de la mémoire ne se lit pas")
        }
        // Jugée au départ aussi (`memory`), mais c'est la mémoire de
        // l'instantané qui part dans l'archive : voir `isRecordable`.
        guard isRecordable(ram) else { throw Refusal.unrecordableMemory(ram) }
        KernelMemory.setSize(UInt64(ram), forKernel: machine.key, in: work)
        let identity = SuspendedMachine.identity(of: kernel, named: machine.key)
        try SuspendedMachine.savePacked(SnapshotFile.pack(snapshot), kernel: identity, in: work)
        try MachineArchive.export(machine, kernels: work, in: work, to: archive)
        return identity
    }

    /// **Le nom commun des fichiers d'une fabrication** (archive, fiche,
    /// capture, console) : l'image, puis le niveau de machine —
    /// `void-live-x86_64-20250202-xfce-pret-niveau1`. Le niveau est dans le
    /// nom parce que l'archive d'un niveau neuf, attachée à la même release,
    /// remplaçait celle du niveau d'avant sous le même nom, et l'entrée gardée
    /// pour les applications d'avant (`Index.merged`) promettait une somme que
    /// l'asset n'avait plus.
    ///
    /// **Le cœur Rust y met son nom** : `…-xfce-pret-rust-niveau2`. Son
    /// archive et celle du cœur Swift vivent dans la même release ; sous le
    /// même nom, l'une remplacerait l'autre, et les applications qui ne
    /// reprennent que le cœur Swift perdraient la leur.
    public static func outputStem(image: String, level: UInt64, core: ReadyDesktop.Core = .swift) -> String {
        let base = image.hasSuffix(".iso") ? String(image.dropLast(4)) : image
        switch core {
        case .swift: return "\(base)-pret-niveau\(level)"
        case .rust: return "\(base)-pret-rust-niveau\(level)"
        }
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
        /// Le cœur qui a fabriqué, et qui reprendra ; absent des fiches
        /// d'avant, qui sont du cœur Swift.
        public var core: ReadyDesktop.Core?
        /// `X86Machine.snapshotLevel` de la machine qui a fabriqué, ou la
        /// version de l'instantané du cœur Rust (`RustPCSnapshot.version`).
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
        /// La somme de l'instantané brut : deux fabrications se comparent
        /// par elle, même quand on n'a gardé ni l'une ni l'autre. Absente des
        /// fiches d'avant.
        public var snapshotSHA256: String?
        public var commit: String?

        public init(title: String, level: UInt64, image: File, archive: File, kernelDigest: String,
                    ramBytes: UInt64, screen: [Int], commandLine: String, madeAt: Date,
                    guestClock: Date?, instructions: UInt64, snapshotBytes: UInt64,
                    packedBytes: UInt64, snapshotSHA256: String? = nil, commit: String?,
                    core: ReadyDesktop.Core? = nil) {
            self.title = title
            self.core = core
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
            self.snapshotSHA256 = snapshotSHA256
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

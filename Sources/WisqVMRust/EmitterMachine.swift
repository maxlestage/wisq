import CWisqVM
import Foundation
import WisqVM

/// **La machine de l'émetteur, telle que l'application l'ouvre.**
///
/// L'application a deux machines PC. Le cœur Swift (`X86Machine`) est celle
/// de tous les jours. Celle-ci est l'autre : la boucle hôte de `web/host.js`,
/// la carte de `crates/wisq-page` et l'émetteur x86-64 → WebAssembly, dans un
/// `WKWebView` que JavaScriptCore compile — la machine que `kernel-entry`
/// démarre sous Bun, Alpine jusqu'à son shell depuis son ISO, Void Xfce
/// jusqu'à son espace utilisateur. **Elle est derrière un réglage éteint par
/// défaut** (`EmitterSetting`), et l'application ne bascule pas dessus.
///
/// Ce type fait tout ce qui n'a pas besoin de WebKit, et c'est presque tout :
///
/// - **le noyau** : un `bzImage` est décompressé (`KernelPayload`), et ses
///   segments ELF sont posés à leurs adresses physiques ;
/// - **la RAM** est jugée comme `kernel-entry` la juge (le repli de
///   l'émetteur doit ramener le texte virtuel sur lui-même) ;
/// - **l'archive** est posée juste au-dessus du noyau ;
/// - **la page zéro** vient du Rust (`wisq_emitter_boot_page`) : la ligne du
///   montage puis celle de l'image, l'écran de la carte, l'archive ;
/// - **le plan** que la page lit (`plan.json`) et **le magasin** qui sert le
///   tout (`EmitterStore`), l'ISO comprise, par plages.
///
/// Ce qui reste à WebKit — la vue, le gestionnaire de schéma, les messages —
/// est `EmitterDesktop`, et rien n'y décide.
public enum EmitterMachine {
    /// Le schéma sous lequel la page vit, et son hôte. Pas `wisq://`, que
    /// l'application prend déjà pour ses liens d'appairage.
    public static let scheme = "wisq-machine"
    public static let pageURL = URL(string: "wisq-machine://machine/machine.html")!

    /// **Un fichier de la page, par son nom**, tel que la bibliothèque le
    /// porte — les scripts toujours, le module quand la construction l'a
    /// embarqué.
    public static func asset(_ name: String) -> Data? {
        name.withCString { cName -> Data? in
            var bytes: UnsafePointer<UInt8>?
            var length = 0
            guard wisq_emitter_asset(cName, &bytes, &length) == 0, let bytes else { return nil }
            return Data(bytes: bytes, count: length)
        }
    }

    /// Les fichiers de la page que le magasin sert, module mis à part.
    public static let pageFiles = ["machine.html", "machine.js", "host.js", "carte.js", "page-emitter.js"]
    /// Le nom du module, dans la page et dans la bibliothèque.
    public static let moduleName = "wisq_page.wasm"

    /// **Le module embarqué**, ou `nil` : une construction de tous les jours
    /// ne le porte pas, et la machine de l'émetteur n'y est pas. L'application
    /// le dit au lieu d'ouvrir une page qui n'aurait ni traducteur ni carte.
    public static var embeddedModule: Data? { asset(moduleName) }

    /// **La construction porte-t-elle le module ?** Sans le recopier : une
    /// vue le demande à chaque rendu.
    public static var isInThisBuild: Bool {
        moduleName.withCString { name in
            var bytes: UnsafePointer<UInt8>?
            var length = 0
            return wisq_emitter_asset(name, &bytes, &length) == 0 && length > 0
        }
    }

    /// L'écran de la carte de Bochs, `1280x800` comme l'application.
    public struct Screen: Equatable, Sendable {
        public let width: UInt32
        public let height: UInt32
        public init(width: UInt32, height: UInt32) {
            self.width = width
            self.height = height
        }
        public static let standard = Screen(width: 1280, height: 800)
    }

    /// **Ce qu'on demande** : ce que `IsoBoot.decide` a tiré de l'image (le
    /// noyau, l'archive, le disque, la ligne), la RAM et l'écran.
    public struct Setup: Equatable, Sendable {
        public var kernel: URL
        public var initrd: URL?
        public var disk: URL?
        /// La ligne de l'image, ajoutée telle quelle à celle du montage.
        public var commandLine: String?
        public var ramBytes: Int
        public var screen: Screen?
        /// L'horloge CMOS figée, en millisecondes depuis 1970, ou `nil` pour
        /// l'heure du mur : un test rejouable la fige.
        public var clock: Int64?

        public init(
            kernel: URL, initrd: URL? = nil, disk: URL? = nil, commandLine: String? = nil,
            ramBytes: Int = 1 << 30, screen: Screen? = .standard, clock: Int64? = nil
        ) {
            self.kernel = kernel
            self.initrd = initrd
            self.disk = disk
            self.commandLine = commandLine
            self.ramBytes = ramBytes
            self.screen = screen
            self.clock = clock
        }

        /// **Ce qu'`IsoBoot` a décidé**, monté sur l'émetteur. La RAM est au
        /// moins celle que l'image demande (un système vivant en veut un
        /// gibioctet), et un gibioctet par défaut : c'est la taille des
        /// courses de Void sous `kernel-entry`. La ligne est celle de l'image,
        /// avec la console de l'émetteur au bout (`emitterLine`).
        public init(boot: IsoBoot.Boot, ramBytes: Int = 1 << 30, screen: Screen? = .standard) {
            self.init(
                kernel: boot.kernel, initrd: boot.initrd, disk: boot.disk,
                commandLine: EmitterMachine.emitterLine(boot.commandLine),
                ramBytes: max(ramBytes, boot.minimumRAM), screen: screen)
        }
    }

    /// Pourquoi la machine ne peut pas être montée. Chaque cause a son nom,
    /// parce qu'elles ne se corrigent pas au même endroit.
    public enum Refusal: Error, Equatable, Sendable {
        /// Un fichier qui ne se lit pas : le noyau, l'archive ou le disque.
        case unreadable(String)
        /// Le noyau n'est ni un ELF ni un `bzImage` qui en porte un.
        case kernel(KernelPayload.Refusal)
        /// Un ELF sans segment chargeable lisible.
        case noLoadableSegment
        /// Aucun segment ne porte le point d'entrée.
        case noSegmentCarriesTheEntry(UInt64)
        /// La RAM n'est pas une puissance de deux de pages de 64 Kio.
        case ramIsNotAPowerOfTwo(Int)
        /// Le noyau, BSS compris, ne tient pas dans la RAM.
        case ramTooSmall(needed: UInt64)
        /// Le repli de l'émetteur amène le texte virtuel ailleurs que sur
        /// lui-même : sous 4 Gio seulement.
        case foldMisses(folded: UInt64)
        /// La ligne de commande **entière** — celle du montage, puis celle
        /// de l'image — est plus longue que la place que la page zéro lui
        /// laisse ; `bytes` est sa longueur, que le Rust a comptée.
        case commandLineTooLong(bytes: Int)
        /// La ligne de commande porte un octet nul, où le noyau la couperait.
        case commandLineCarriesNul
        /// L'écran ne peut pas être décrit au noyau.
        case screen
        /// L'archive ne tient pas entre le noyau et le bout de la RAM.
        case archiveDoesNotFit(bytes: UInt64)
        /// Le disque fait moins d'un secteur.
        case diskTooSmall(UInt64)
        /// L'image ne s'ouvre pas : la phrase d'`IsoBoot`, telle quelle.
        case image(String)
        /// L'appareil ne laisse pas assez de mémoire pour ce que l'image demande.
        case notEnoughRoom(ceiling: UInt64, minimum: Int)
        /// Un code que cette version ne connaît pas.
        case unknown(Int32)
    }

    /// **La machine montée** : de quoi écrire le plan et remplir le magasin.
    public struct Prepared: Equatable, Sendable {
        /// Un morceau à poser dans la RAM : son nom dans le magasin, son
        /// adresse physique, ses octets.
        public struct Piece: Equatable, Sendable {
            public let name: String
            public let at: UInt64
            public let source: EmitterStore.Source
        }

        public let pages: UInt32
        public let entry: UInt64
        public let pieces: [Piece]
        public let screen: Screen?
        public let disk: URL?
        public let diskBytes: UInt64
        public let clock: Int64?
        /// La ligne que le noyau lira, telle que la page zéro la porte.
        public let commandLine: String
        /// Le sommet du noyau, BSS compris, et où l'archive commence.
        public let kernelTop: UInt64
        public let initrdAt: UInt64?

        /// **Le plan que la page lit**, en JSON. Les adresses de 64 bits
        /// partent en texte : un `Number` JavaScript perd ses bits au-delà de
        /// deux puissance cinquante-trois.
        public func plan() -> Data {
            var plan: [String: Any] = [
                "pages": Int(pages),
                "entree": String(entry),
                "pageZero": Int(DesktopTranslator.bootPageAddress),
                "segments": pieces.map { piece -> [String: Any] in
                    ["chemin": piece.name, "a": Int(piece.at), "octets": Int(piece.source.length)]
                },
                "heure": clock.map { $0 as Any } ?? NSNull(),
            ]
            plan["ecran"] = screen.map { screen -> Any in
                [
                    "largeur": Int(screen.width), "hauteur": Int(screen.height),
                    "base": String(wisq_emitter_screen_base()),
                ] as [String: Any]
            } ?? NSNull()
            plan["disque"] = disk.map { _ -> Any in
                ["chemin": EmitterStore.diskName, "octets": Int(diskBytes)] as [String: Any]
            } ?? NSNull()
            // Les clés triées : le même montage écrit le même plan.
            return (try? JSONSerialization.data(withJSONObject: plan, options: [.sortedKeys])) ?? Data()
        }

        /// **Le magasin de cette machine**, avec le module donné — celui que
        /// la bibliothèque embarque, dans l'application.
        public func store(module: Data) -> EmitterStore {
            var files: [String: EmitterStore.Source] = [:]
            for name in EmitterMachine.pageFiles {
                if let bytes = EmitterMachine.asset(name) { files[name] = .bytes(bytes) }
            }
            files[EmitterMachine.moduleName] = .bytes(module)
            files["plan.json"] = .bytes(plan())
            for piece in pieces { files[piece.name] = piece.source }
            return EmitterStore(files: files, disk: disk.map { (url: $0, bytes: diskBytes) })
        }
    }

    /// **La RAM d'une machine de l'émetteur**, pour un appareil qui en laisse
    /// `ceiling` et une image qui en demande `minimum` : une puissance de deux,
    /// un gibioctet si l'on peut (la taille des courses de Void), jamais plus
    /// de deux (au-delà, le repli de l'émetteur ne ramène plus le texte du
    /// noyau sur lui-même), jamais moins de ce que l'image demande ni de
    /// soixante-quatre mébioctets. `nil` quand rien ne tient.
    public static func chooseRAM(ceiling: UInt64, minimum: Int) -> Int? {
        let floor = max(minimum, 64 << 20)
        let wanted = UInt64(max(floor, 1 << 30))
        let room = min(ceiling, wanted, 2 << 30)
        guard room > 0 else { return nil }
        var ram: UInt64 = 1 << 63
        while ram > room { ram >>= 1 }
        guard ram >= UInt64(floor) else { return nil }
        return Int(ram)
    }

    /// **La console de la machine de l'émetteur**, au bout de la ligne de
    /// l'image : celle que Linux retient pour `/dev/console`, le dernier
    /// `console=` l'emportant.
    public static let console = "console=ttyS0,115200"

    /// **La place de la ligne entière** — celle du montage, puis celle de
    /// l'image —, terminée par un zéro dans la page zéro : 2 047 octets, la
    /// limite du noyau lui-même (`MONTAGE_COMMAND_LINE_ROOM`, côté Rust).
    public static let commandLineRoom = 2047

    /// **La ligne d'`IsoBoot`, pour l'émetteur** : la part de l'image telle
    /// quelle, et la console de l'émetteur à la place de celle du cœur Swift.
    ///
    /// `IsoBoot.commandLine` finit par `X86BootLoader.defaultCommandLine`, qui
    /// est écrite pour le cœur Swift : sa machine n'a pas de console précoce
    /// à elle, et `earlyprintk=serial,…,keep` lui en donne une, **gardée pour
    /// toujours** (`keep`). Celle de l'émetteur en a déjà une, `earlycon`, que
    /// le montage pose et que le noyau rend quand `ttyS0` arrive. Les deux
    /// ensemble font trois consoles sur le même port : sous `kernel-entry`,
    /// Void jusqu'à `pid_max` rend **205 lignes dont 100 doublées** avec la
    /// ligne d'`IsoBoot`, **96 dont 2** avec celle-ci — les deux de la
    /// passation, que le noyau écrit sur les deux consoles (JOURNAL, 21
    /// novembre). Alpine n'a pas `earlyprintk` (« Unknown kernel command
    /// line parameters ») et ne doublait que par `keep_bootcon` (121 lignes
    /// dont 19, contre 104 dont 2).
    ///
    /// Une ligne qui ne finit pas par celle du cœur — celle d'une image de
    /// cloud, d'un système installé — passe telle quelle.
    public static func emitterLine(_ isoLine: String?) -> String? {
        guard let isoLine else { return nil }
        let core = X86BootLoader.defaultCommandLine
        if isoLine == core { return console }
        guard isoLine.hasSuffix(" " + core) else { return isoLine }
        return String(isoLine.dropLast(core.count)) + console
    }

    /// **Ouvrir une image comme l'application l'ouvre** : `IsoBoot` décide (le
    /// noyau et l'archive déballés de l'ISO dans `folder`, l'ISO elle-même en
    /// disque, la ligne de l'image), la RAM est choisie pour l'appareil, et la
    /// machine est montée.
    public static func open(
        _ image: URL, unpackingInto folder: URL, ceiling: UInt64, screen: Screen? = .standard
    ) throws -> Prepared {
        let boot: IsoBoot.Boot
        switch IsoBoot.decide(image, into: folder, ceiling: ceiling) {
        case .success(let decided): boot = decided
        case .failure(let refusal):
            throw Refusal.image(IsoBoot.explanation(refusal, name: image.lastPathComponent))
        }
        guard let ram = chooseRAM(ceiling: ceiling, minimum: boot.minimumRAM) else {
            throw Refusal.notEnoughRoom(ceiling: ceiling, minimum: boot.minimumRAM)
        }
        return try prepare(
            Setup(boot: boot, ramBytes: ram, screen: screen),
            scratch: folder.appendingPathComponent("emetteur"))
    }

    /// **Monter la machine.** `scratch` reçoit le `vmlinux` décompressé d'un
    /// `bzImage` — servi de là plutôt que gardé en mémoire.
    ///
    /// **Le pic de mémoire n'est pas la taille du `vmlinux`** : le fichier
    /// lu, la charge utile et le flux deflate que `KernelPayload` recopie,
    /// l'ELF décompressé, puis la `Data` que l'écriture et la lecture des
    /// segments partagent. Mesuré sur Void (un `bzImage` de 13,2 Mio, un
    /// `vmlinux` de 55 Mio, construction de débogage), le pic résident monte
    /// de **151 Mio** quand le fichier lu vivait jusqu'au bout, et de
    /// **137 Mio** depuis que chaque tampon part dès qu'il ne sert plus :
    /// deux fois et demie le `vmlinux` (JOURNAL, 21 novembre).
    public static func prepare(_ setup: Setup, scratch: URL) throws -> Prepared {
        var original: [UInt8]
        do {
            original = [UInt8](try Data(contentsOf: setup.kernel))
        } catch {
            throw Refusal.unreadable(setup.kernel.lastPathComponent)
        }
        var elf: [UInt8]
        do {
            elf = try KernelPayload.elf(from: original)
        } catch let refusal as KernelPayload.Refusal {
            throw Refusal.kernel(refusal)
        } catch {
            throw Refusal.kernel(.notAKernel)
        }
        let inflated = !(elf.count == original.count && elf == original)
        // Chaque tampon part dès qu'il ne sert plus : le fichier lu, puis
        // l'ELF une fois recopié dans la seule `Data` qui reste.
        original = []
        let image = Data(elf)
        elf = []
        // **Le noyau servi depuis un fichier** : l'original s'il est déjà un
        // ELF, sinon celui qu'on vient de décompresser.
        let kernelFile: URL
        if !inflated {
            kernelFile = setup.kernel
        } else {
            try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            kernelFile = scratch.appendingPathComponent("vmlinux")
            do {
                try image.write(to: kernelFile, options: .atomic)
            } catch {
                throw Refusal.unreadable(kernelFile.lastPathComponent)
            }
        }
        guard let loadable = RustKernelImage.loads(image) else { throw Refusal.noLoadableSegment }
        let entry = loadable.entry
        guard loadable.segments.contains(where: {
            $0.physicalAddress <= entry && entry < $0.physicalAddress &+ $0.memorySize
        }) else {
            throw Refusal.noSegmentCarriesTheEntry(entry)
        }
        let top = loadable.segments.map { $0.physicalAddress &+ $0.memorySize }.max() ?? 0

        guard setup.ramBytes > 0, setup.ramBytes % 65536 == 0,
              let pages = UInt32(exactly: setup.ramBytes / 65536)
        else {
            throw Refusal.ramIsNotAPowerOfTwo(setup.ramBytes)
        }
        var folded: UInt64 = 0
        switch wisq_emitter_usable_ram(pages, entry, top, &folded) {
        case 0: break
        case 1, 2: throw Refusal.ramIsNotAPowerOfTwo(setup.ramBytes)
        case 3: throw Refusal.ramTooSmall(needed: top)
        case 4: throw Refusal.foldMisses(folded: folded)
        case let code: throw Refusal.unknown(code)
        }

        var pieces: [Prepared.Piece] = []
        for (index, segment) in loadable.segments.enumerated() where segment.fileSize > 0 {
            pieces.append(Prepared.Piece(
                name: "noyau-\(index)", at: segment.physicalAddress,
                source: .file(kernelFile, offset: segment.offset, length: segment.fileSize)))
        }

        // **L'archive, juste au-dessus du noyau**, alignée sur une page : le
        // noyau la réserve dès qu'il la connaît, et la libère une fois
        // déballée.
        var initrdAt: UInt64?
        var initrdBytes: UInt64 = 0
        if let initrd = setup.initrd {
            guard let size = fileSize(initrd), size > 0 else {
                throw Refusal.unreadable(initrd.lastPathComponent)
            }
            let at = (top + 0xFFF) & ~UInt64(0xFFF)
            initrdAt = at
            initrdBytes = size
            pieces.append(Prepared.Piece(
                name: "initramfs", at: at, source: .file(initrd, offset: 0, length: size)))
        }

        var diskBytes: UInt64 = 0
        if let disk = setup.disk {
            guard let size = fileSize(disk) else { throw Refusal.unreadable(disk.lastPathComponent) }
            guard size >= UInt64(EmitterStore.sector) else { throw Refusal.diskTooSmall(size) }
            diskBytes = size
        }

        let zero = try bootPage(
            pages: pages, commandLine: setup.commandLine, screen: setup.screen,
            initrd: (initrdAt ?? 0, initrdBytes), floor: top)
        pieces.append(Prepared.Piece(
            name: "page-zero", at: DesktopTranslator.bootPageAddress, source: .bytes(zero)))
        return Prepared(
            pages: pages, entry: entry, pieces: pieces, screen: setup.screen,
            disk: setup.disk, diskBytes: diskBytes, clock: setup.clock,
            commandLine: lineInPage(zero), kernelTop: top, initrdAt: initrdAt)
    }

    /// **Ce que l'écran dit d'un refus**, en une phrase : la cause, et ce qui
    /// la lève quand quelque chose le peut.
    public static func explanation(_ refusal: Refusal) -> String {
        func mio(_ bytes: UInt64) -> String { "\(bytes >> 20) Mio" }
        switch refusal {
        case .unreadable(let name): return "\(name) ne se lit pas."
        case .kernel(.unsupportedCompression(let how)):
            return "Le noyau est compressé en \(how), que la machine de l'émetteur ne sait pas défaire."
        case .kernel(let why): return "Le noyau ne se lit pas : \(why)."
        case .noLoadableSegment, .noSegmentCarriesTheEntry:
            return "Le noyau n'a pas de point d'entrée que la machine de l'émetteur sache poser."
        case .ramIsNotAPowerOfTwo, .foldMisses:
            return "Cette taille de mémoire ne convient pas à l'émetteur : une puissance de deux, deux gibioctets au plus."
        case .ramTooSmall(let needed): return "Le noyau demande \(mio(needed)), plus que la mémoire choisie."
        // **La ligne entière**, pas celle de l'image : la borne juge les deux
        // ensemble, et une ligne d'image de 2 008 octets est refusée bien
        // qu'elle ne dépasse pas, seule, les 2 047.
        case .commandLineTooLong(let bytes):
            return "La ligne de commande, celle de l'émetteur comprise, fait \(bytes) octets : "
                + "plus que les \(commandLineRoom) que le noyau lit."
        case .commandLineCarriesNul:
            return "La ligne de commande de l'image porte un caractère nul, où le noyau la couperait."
        case .screen: return "L'écran demandé ne peut pas être décrit au noyau."
        case .archiveDoesNotFit(let bytes):
            return "L'archive de démarrage (\(mio(bytes))) ne tient pas dans la mémoire, au-dessus du noyau."
        case .diskTooSmall: return "Le disque fait moins d'un secteur."
        case .image(let sentence): return sentence
        case .notEnoughRoom(let ceiling, let minimum):
            return "L'appareil laisse \(mio(ceiling)) à la machine, et l'image en demande au moins \(mio(UInt64(max(minimum, 64 << 20))))."
        case .unknown(let code): return "Un refus que cette version ne connaît pas (\(code))."
        }
    }

    /// La page zéro, du Rust, ou son refus sous son nom.
    static func bootPage(
        pages: UInt32, commandLine: String?, screen: Screen?,
        initrd: (at: UInt64, bytes: UInt64), floor: UInt64
    ) throws -> Data {
        let (initrdAt, initrdBytes) = initrd
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        let width = screen?.width ?? 0
        let height = screen?.height ?? 0
        let code: Int32
        // **Un nul dans la ligne est refusé ici** : `withCString` la couperait
        // à cet octet, et le Rust recevrait une ligne plus courte sans rien
        // pouvoir en dire.
        if let commandLine, commandLine.utf8.contains(0) { throw Refusal.commandLineCarriesNul }
        if let commandLine {
            code = commandLine.withCString { line in
                wisq_emitter_boot_page(
                    pages, line, width, height, initrdAt, initrdBytes, floor, &out, &length)
            }
        } else {
            code = wisq_emitter_boot_page(
                pages, nil, width, height, initrdAt, initrdBytes, floor, &out, &length)
        }
        switch code {
        case 0:
            guard let out else { throw Refusal.unknown(0) }
            defer { wisq_x86_free_module(out, length) }
            return Data(UnsafeBufferPointer(start: out, count: length))
        case 1: throw Refusal.ramIsNotAPowerOfTwo(Int(pages) * 65536)
        // Au refus 2, `length` porte la longueur de la ligne entière.
        case 2: throw Refusal.commandLineTooLong(bytes: length)
        case 3: throw Refusal.screen
        case 4: throw Refusal.archiveDoesNotFit(bytes: initrdBytes)
        default: throw Refusal.unknown(code)
        }
    }

    /// La ligne de commande telle que la page la porte, à `0x800`.
    static func lineInPage(_ page: Data) -> String {
        let start = page.startIndex + 0x800
        guard start < page.endIndex else { return "" }
        let tail = page[start...]
        let end = tail.firstIndex(of: 0) ?? page.endIndex
        return String(decoding: page[start..<end], as: UTF8.self)
    }

    static func fileSize(_ url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { UInt64($0) }
    }
}

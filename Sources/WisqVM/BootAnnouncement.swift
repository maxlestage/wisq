import Foundation

/// **Ce que wisq dit avant de démarrer quoi que ce soit** : la plateforme de
/// l'image, celle du téléphone, et ce que le rapport des deux veut dire.
///
/// Elle est née d'une capture : `omarchy-4.5.0-x86.iso`, touchée, et la
/// console qui s'ouvre sur un refus de trois lignes, sans que rien n'ait dit
/// avant pour quelle machine était ce fichier ni ce que wisq allait en faire.
/// Maxime : « je veux être informé de la plateforme avant de démarrer quoi que
/// ce soit ». L'annonce passe donc **avant** la console, à chaque démarrage,
/// et elle dit trois choses :
///
/// 1. **la plateforme de l'image** — x86-64, ARM64, RISC-V — et *d'où on le
///    sait* : l'en-tête du noyau, le noyau sorti de l'image, ou seulement son
///    nom. Un indice lu dans un nom n'est pas une preuve, et il ne se présente
///    pas comme telle ;
/// 2. **la plateforme du téléphone** — `HostPlatform` ;
/// 3. **ce qui va se passer** : la machine qui la prend, ou pourquoi aucune.
///
/// La décision vit ici, typée et testée par la CI Linux à chaque commit ; la
/// feuille de l'application (`WisqUI`) ne fait que la dessiner.
public struct BootAnnouncement: Equatable, Sendable {
    /// D'où vient ce qu'on affirme de l'architecture.
    public enum Evidence: Equatable, Sendable {
        /// Lu dans l'en-tête du fichier lui-même (« bzImage », « Image ARM64 »).
        case header(format: String)
        /// Le noyau a été sorti de l'image et lu : `container` est le format
        /// de l'image, `format` celui du noyau.
        case insideImage(container: String, format: String)
        /// Seulement un mot du nom du fichier ou du chemin du noyau.
        case nameHint(String)
        /// Rien ne le dit.
        case none
    }

    /// Ce qui va se passer quand on touche « Démarrer ».
    public enum Outcome: Equatable, Sendable {
        /// Ce cœur prend la machine.
        case runs(GuestArchitecture.Core)
        /// Personne n'a reconnu le fichier : il est tenté sur ce cœur, comme
        /// le veut `KernelImageKind.unknown`.
        case tries(GuestArchitecture.Core)
        /// Aucun cœur de wisq ne le démarrera ; `reason` dit pourquoi.
        case refused(reason: String)

        public var startsSomething: Bool {
            if case .refused = self { return false }
            return true
        }
    }

    public let fileName: String
    /// L'architecture de l'image, quand quelque chose la dit.
    public let guest: GuestArchitecture?
    public let evidence: Evidence
    public let host: HostPlatform
    public let outcome: Outcome

    public init(fileName: String, guest: GuestArchitecture?, evidence: Evidence,
                host: HostPlatform, outcome: Outcome) {
        self.fileName = fileName
        self.guest = guest
        self.evidence = evidence
        self.host = host
        self.outcome = outcome
    }

    /// **L'annonce d'un fichier de la bibliothèque.**
    ///
    /// - `kind` : ce que le fichier est (`KernelImageKind.identify`).
    /// - `inner` : pour une image de disque, ce qu'est le noyau qu'elle
    ///   porte, quand il a pu être sorti et lu ; `innerPath` est son chemin
    ///   dans l'image, qui sert d'indice quand le noyau, lui, ne dit rien
    ///   (compressé).
    /// - `cloudImage` : la bibliothèque l'a reconnue comme image de cloud
    ///   (`InstalledMachines.cloudImages`) — elle démarre sur la machine PC.
    public static func make(
        fileName: String, kind: KernelImageKind, inner: KernelImageKind? = nil,
        innerPath: String? = nil, cloudImage: Bool = false, host: HostPlatform = .current
    ) -> BootAnnouncement {
        // **Une image de cloud démarre sur la machine PC**, son disque et sa
        // racine compris (`CloudBoot`) ; son nom dit parfois qu'elle est pour
        // une autre machine, et c'est alors un refus qui la nomme.
        if cloudImage {
            let hinted = hint(nil, fileName)
            if let (architecture, word) = hinted, architecture.core != .x86_64 {
                return BootAnnouncement(
                    fileName: fileName, guest: architecture, evidence: .nameHint(word), host: host,
                    outcome: outcome(for: architecture, kind: kind, name: fileName))
            }
            return BootAnnouncement(
                fileName: fileName, guest: hinted?.0 ?? GuestArchitecture(.x86, bits: 64),
                evidence: hinted.map { .nameHint($0.1) } ?? .none, host: host,
                outcome: .runs(.x86_64))
        }
        switch kind {
        case .linuxKernel(let image):
            return BootAnnouncement(
                fileName: fileName, guest: image.architecture,
                evidence: .header(format: image.format), host: host,
                outcome: outcome(for: image.architecture, kind: kind, name: fileName))

        case .discImage(let container):
            if case .linuxKernel(let image)? = inner {
                return BootAnnouncement(
                    fileName: fileName, guest: image.architecture,
                    evidence: .insideImage(container: container, format: image.format), host: host,
                    outcome: outcome(for: image.architecture, kind: inner ?? kind, name: fileName))
            }
            // Le noyau n'a pas été lu (compressé, ou image sans recette) :
            // le chemin du noyau, puis le nom du fichier, en disent parfois
            // assez. Sans rien, l'image est tentée sur la machine PC — c'est
            // là que `IsoBoot` l'emmène, et c'est le démarrage qui tranchera.
            if let (architecture, word) = hint(innerPath, fileName) {
                return BootAnnouncement(
                    fileName: fileName, guest: architecture, evidence: .nameHint(word), host: host,
                    outcome: outcome(for: architecture, kind: kind, name: fileName))
            }
            return BootAnnouncement(fileName: fileName, guest: nil, evidence: .none, host: host,
                                    outcome: .tries(.x86_64))

        case .unknown:
            return BootAnnouncement(fileName: fileName, guest: nil, evidence: .none, host: host,
                                    outcome: .tries(.riscv32))

        case .executable(let architecture):
            return BootAnnouncement(
                fileName: fileName, guest: architecture, evidence: .header(format: "ELF"), host: host,
                outcome: .refused(reason: KernelImageKind.cannotRunHereExplanation(kind, name: fileName)
                    ?? "Ce n'est pas un noyau Linux."))

        case .filesystemImage, .compressedKernel, .virtualDisk:
            let hinted = hint(nil, fileName)
            return BootAnnouncement(
                fileName: fileName, guest: hinted?.0, evidence: hinted.map { .nameHint($0.1) } ?? .none,
                host: host,
                outcome: .refused(reason: KernelImageKind.cannotRunHereExplanation(kind, name: fileName)
                    ?? "Ce fichier ne démarre pas seul."))
        }
    }

    /// Le cœur d'une architecture, ou le refus qui la nomme.
    static func outcome(for architecture: GuestArchitecture, kind: KernelImageKind,
                        name: String) -> Outcome {
        if let core = architecture.core { return .runs(core) }
        if architecture.family == .arm {
            return .refused(reason: """
                \(name) est pour \(architecture.name). Ce téléphone est lui-même \
                ARM64, mais iOS ne laisse pas une application exécuter \
                directement le code d'un autre système : il faut un interprète, \
                comme pour x86-64 et RISC-V. wisq n'a pas encore de cœur ARM sur \
                le téléphone.

                Pour la faire tourner aujourd'hui : démarrez-la sur un \
                ordinateur ARM (un Mac Apple Silicon, un Raspberry Pi, un \
                serveur), et ouvrez-la depuis wisq par une connexion à distance.
                """)
        }
        return .refused(reason: KernelImageKind.cannotRunHereExplanation(
            .linuxKernel(KernelImage(architecture, format: "noyau")), name: name)
            ?? "wisq n'a pas de cœur pour \(architecture.name).")
    }

    /// Le premier indice d'architecture trouvé dans le chemin du noyau puis
    /// dans le nom du fichier, avec le mot qui l'a donné.
    static func hint(_ innerPath: String?, _ fileName: String) -> (GuestArchitecture, String)? {
        for text in [innerPath, fileName].compactMap({ $0 }) {
            if let found = GuestArchitecture.hinted(by: text) { return found }
        }
        return nil
    }

    // MARK: - Ce que la feuille écrit

    /// « x86-64 », « ARM64 », ou « inconnue ».
    public var guestName: String { guest?.name ?? "inconnue" }

    /// D'où vient l'architecture, en une phrase.
    public var evidenceText: String {
        switch evidence {
        case .header(let format):
            return "Lue dans l'en-tête du fichier (\(format))."
        case .insideImage(let container, let format):
            return "Lue sur le noyau que porte l'image (\(container), noyau \(format))."
        case .nameHint(let word):
            return "Déduite du mot « \(word) » dans son nom : le noyau lui-même n'a pas été lu."
        case .none:
            return "Rien dans le fichier ne la dit."
        }
    }

    /// Ce qui va se passer.
    public var executionText: String {
        switch outcome {
        case .runs(let core):
            return "La machine \(core.name) de wisq la démarre sur ce téléphone. " + translation(core)
        case .tries(let core):
            return "wisq ne reconnaît pas ce fichier : il le tentera sur la machine \(core.name), " +
                "et la console dira ce qu'il en est. " + translation(core)
        case .refused(let reason):
            return reason
        }
    }

    /// Une image pour une autre machine que le téléphone est **interprétée** :
    /// le dire, c'est expliquer d'avance la vitesse.
    private func translation(_ core: GuestArchitecture.Core) -> String {
        let guest = GuestArchitecture.runnable.first { $0.core == core } ?? GuestArchitecture(.x86, bits: 64)
        guard guest.family != host.architecture.family || guest.bits != host.architecture.bits else {
            return "Même famille de processeur que l'hôte, mais exécutée par l'interprète de wisq."
        }
        return "Chaque instruction \(guest.name) est interprétée par le processeur \(host.architecture.name) " +
            "du téléphone, sans JIT : c'est plus lent qu'un vrai \(guest.family == .x86 ? "PC" : "processeur"), " +
            "et c'est ce qui la garde dans les règles de l'App Store."
    }

    /// Le titre de la feuille : « x86-64 sur ARM64 ».
    public var title: String {
        "\(guestName) sur \(host.architecture.name)"
    }
}

extension GuestArchitecture {
    /// **L'architecture qu'un nom laisse deviner**, et le mot qui l'a dit.
    ///
    /// Les distributions nomment leurs images et leurs noyaux par leur cible
    /// — `alpine-standard-3.20-aarch64.iso`, `/arch/boot/x86_64/vmlinuz-linux`,
    /// `omarchy-4.5.0-x86.iso`. Ce n'est qu'un indice : `BootAnnouncement` le
    /// présente comme tel. Les mots les plus précis passent d'abord —
    /// `x86_64` avant `x86`, `arm64` avant `arm`.
    public static func hinted(by text: String) -> (GuestArchitecture, String)? {
        let lowered = text.lowercased()
        let words: [(String, GuestArchitecture)] = [
            ("x86_64", GuestArchitecture(.x86, bits: 64)),
            ("x86-64", GuestArchitecture(.x86, bits: 64)),
            ("amd64", GuestArchitecture(.x86, bits: 64)),
            ("aarch64", GuestArchitecture(.arm, bits: 64)),
            ("arm64", GuestArchitecture(.arm, bits: 64)),
            ("riscv64", GuestArchitecture(.riscv, bits: 64)),
            ("riscv32", GuestArchitecture(.riscv, bits: 32)),
            ("armhf", GuestArchitecture(.arm, bits: 32)),
            ("armv7", GuestArchitecture(.arm, bits: 32)),
            ("i686", GuestArchitecture(.x86, bits: 32)),
            ("i586", GuestArchitecture(.x86, bits: 32)),
            ("i386", GuestArchitecture(.x86, bits: 32)),
            ("x86", GuestArchitecture(.x86)),
        ]
        for (word, architecture) in words where lowered.contains(word) {
            return (architecture, word)
        }
        return nil
    }
}

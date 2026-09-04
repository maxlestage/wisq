import Foundation

/// Toutes les architectures pour lesquelles Linux existe, et lesquelles wisq
/// sait exécuter.
///
/// **Pourquoi une famille et une largeur séparées.** Un fichier ne dit pas
/// toujours les deux. Un ELF porte sa classe — 32 ou 64 bits — dans son
/// cinquième octet, donc on sait. L'image brute que Linux produit pour RISC-V
/// n'a **aucun champ** qui porte la largeur : son en-tête donne un décalage,
/// une taille, des drapeaux dont le bit zéro est le boutisme, une version et
/// deux nombres magiques, et c'est tout. Un noyau rv32 et un noyau rv64 y sont
/// impossibles à distinguer.
///
/// Alors la largeur est **optionnelle**, et `nil` veut dire « le fichier ne le
/// dit pas » — pas « 32 par défaut ». Deviner ici serait la même faute que
/// d'annoncer une taille pour expliquer un refus : une phrase vraie en
/// apparence qui envoie chercher au mauvais endroit.
public struct GuestArchitecture: Hashable, Sendable {
    public let family: Family
    /// 32 ou 64, ou `nil` quand le fichier ne le dit pas.
    public let bits: Int?
    /// Vrai pour gros-boutiste, `nil` quand ça ne se lit pas. Sur les
    /// architectures qui existent dans les deux sens — MIPS, PowerPC, ARM —
    /// c'est une vraie différence, pas une nuance.
    public let bigEndian: Bool?

    public init(_ family: Family, bits: Int? = nil, bigEndian: Bool? = nil) {
        self.family = family
        self.bits = bits
        self.bigEndian = bigEndian
    }

    /// Les familles pour lesquelles le noyau Linux a un répertoire dans
    /// `arch/`, plus celles qu'il a portées assez longtemps pour que des
    /// images traînent encore.
    public enum Family: String, Sendable, CaseIterable {
        case x86, arm, riscv, mips, powerpc, s390, sparc, loongarch
        case alpha, arc, csky, hexagon, ia64, m68k, microblaze
        case nios2, openrisc, parisc, superh, xtensa

        /// Le nom qu'on écrit à quelqu'un.
        public var name: String {
            switch self {
            case .x86: return "x86"
            case .arm: return "ARM"
            case .riscv: return "RISC-V"
            case .mips: return "MIPS"
            case .powerpc: return "PowerPC"
            case .s390: return "IBM Z"
            case .sparc: return "SPARC"
            case .loongarch: return "LoongArch"
            case .alpha: return "Alpha"
            case .arc: return "ARC"
            case .csky: return "C-SKY"
            case .hexagon: return "Hexagon"
            case .ia64: return "Itanium"
            case .m68k: return "68000"
            case .microblaze: return "MicroBlaze"
            case .nios2: return "Nios II"
            case .openrisc: return "OpenRISC"
            case .parisc: return "PA-RISC"
            case .superh: return "SuperH"
            case .xtensa: return "Xtensa"
            }
        }
    }

    /// Le nom complet, largeur comprise quand on la connaît. ARM 64 bits
    /// s'appelle « ARM64 » et pas « ARM 64 bits », parce que c'est le nom que
    /// tout le monde emploie ; les autres suivent la règle générale.
    public var name: String {
        switch (family, bits) {
        case (.x86, 64): return "x86-64"
        case (.x86, 32): return "x86 32 bits"
        case (.arm, 64): return "ARM64"
        // ARM 32 bits s'appelle « ARM » et rien d'autre — personne n'écrit
        // « ARM 32 bits », de la même façon que personne n'écrit « ARM64
        // 64 bits ». Le nom qu'on donne doit être celui qu'on lit ailleurs.
        case (.arm, 32): return "ARM"
        case (.s390, _): return "IBM Z (s390x)"
        case (let family, .some(let bits)): return "\(family.name) \(bits) bits"
        case (let family, nil): return family.name
        }
    }

    // MARK: - Ce que wisq sait exécuter

    /// Les deux cœurs qui existent dans wisq aujourd'hui.
    public enum Core: String, Sendable {
        /// L'interprète rv32ima, écrit deux fois — en Swift et en Rust — pour
        /// que chacun serve de témoin à l'autre.
        case riscv32
        /// L'interprète x86-64, prouvé instruction par instruction contre le
        /// vrai processeur.
        case x86_64  // swiftlint:disable:this identifier_name

        public var name: String {
            switch self {
            case .riscv32: return "RISC-V 32 bits (rv32ima)"
            case .x86_64: return "x86-64"
            }
        }

        /// **Est-ce que la machine locale de l'application sait le piloter ?**
        ///
        /// Ce n'est pas la même question que « le cœur existe ». Le cœur
        /// x86-64 existe, il démarre un vrai noyau d'Alpine jusqu'à son espace
        /// utilisateur, et `X86BootAttemptTests` l'exige à chaque exécution —
        /// mais `LinuxMachine` est encore câblée sur le RISC-V, et personne
        /// dans l'application ne sait encore lancer l'autre.
        ///
        /// Les deux notions sont séparées ici pour que le refus dise la
        /// vérité. « wisq n'a pas de cœur pour cette architecture » serait
        /// faux ; « le cœur existe, il n'est pas encore branché » est ce qui
        /// est, et ça n'envoie pas chercher au mauvais endroit.
        public var availableInTheApp: Bool {
            switch self {
            case .riscv32: return true
            case .x86_64: return false
            }
        }
    }

    /// **Le cœur que wisq choisira pour cette architecture**, ou `nil` s'il
    /// n'en a pas.
    ///
    /// C'est la sélection automatique : personne n'a à dire quelle machine
    /// démarrer, le fichier le dit déjà.
    ///
    /// **Une largeur inconnue ne bloque pas.** Quand le fichier ne dit pas
    /// s'il est en 32 ou en 64 bits et qu'un seul cœur existe pour la famille,
    /// c'est celui-là qui est choisi : le laisser essayer et échouer en dit
    /// plus long qu'un refus fondé sur ce qu'on n'a pas lu. C'est la même
    /// règle que `KernelImageKind.unknown`, qui est une permission et non un
    /// doute.
    public var core: Core? {
        switch family {
        case .x86: return bits == 32 ? nil : .x86_64
        case .riscv: return bits == 64 ? nil : .riscv32
        default: return nil
        }
    }

    /// Toutes les architectures pour lesquelles un cœur **existe**, pour qu'un
    /// texte n'ait jamais à les énumérer à la main et se trompe le jour où la
    /// liste change.
    public static let runnable: [GuestArchitecture] = [
        GuestArchitecture(.riscv, bits: 32), GuestArchitecture(.x86, bits: 64),
    ]

    /// Celles que l'**application** sait lancer aujourd'hui. Sous-ensemble du
    /// dessus, et c'est volontaire — voir `Core.availableInTheApp`.
    public static var runnableInTheApp: [GuestArchitecture] {
        runnable.filter { $0.core?.availableInTheApp == true }
    }

    // MARK: - Ce qu'un ELF en dit

    /// La famille et la largeur d'un ELF, depuis `e_machine` et la classe.
    ///
    /// Les numéros viennent de `elf.h` ; ceux qui portent plusieurs
    /// architectures — MIPS, PowerPC, RISC-V — sont départagés par la classe,
    /// qui est le cinquième octet du fichier.
    public static func fromELF(machine: UInt16, sixtyFour: Bool, big: Bool) -> GuestArchitecture? {
        let width = sixtyFour ? 64 : 32
        let family: Family
        switch machine {
        case 3: return GuestArchitecture(.x86, bits: 32, bigEndian: big)
        case 62: return GuestArchitecture(.x86, bits: 64, bigEndian: big)
        case 40: return GuestArchitecture(.arm, bits: 32, bigEndian: big)
        case 183: return GuestArchitecture(.arm, bits: 64, bigEndian: big)
        case 20: return GuestArchitecture(.powerpc, bits: 32, bigEndian: big)
        case 21: return GuestArchitecture(.powerpc, bits: 64, bigEndian: big)
        case 22: return GuestArchitecture(.s390, bits: width, bigEndian: big)
        case 2, 18: return GuestArchitecture(.sparc, bits: 32, bigEndian: big)
        case 43: return GuestArchitecture(.sparc, bits: 64, bigEndian: big)
        case 50: return GuestArchitecture(.ia64, bits: 64, bigEndian: big)
        case 8, 10: family = .mips
        case 243: family = .riscv
        case 258: family = .loongarch
        case 41, 0x9026: return GuestArchitecture(.alpha, bits: 64, bigEndian: big)
        case 93, 195: family = .arc
        case 252: family = .csky
        case 164: family = .hexagon
        case 4: family = .m68k
        case 189: family = .microblaze
        case 113: family = .nios2
        case 92: family = .openrisc
        case 15: family = .parisc
        case 42: family = .superh
        case 94: family = .xtensa
        default: return nil
        }
        return GuestArchitecture(family, bits: width, bigEndian: big)
    }

    /// Ce qu'un en-tête U-Boot dit de lui-même.
    ///
    /// C'est le seul format d'image qui **nomme** son architecture au lieu de
    /// la laisser deviner — un octet, à l'offset 29. Les numéros viennent de
    /// `include/image.h` de U-Boot.
    public static func fromUBoot(_ code: UInt8) -> GuestArchitecture? {
        switch code {
        case 1: return GuestArchitecture(.alpha, bits: 64)
        case 2: return GuestArchitecture(.arm, bits: 32)
        case 3: return GuestArchitecture(.x86, bits: 32)
        case 4: return GuestArchitecture(.ia64, bits: 64)
        case 5: return GuestArchitecture(.mips, bits: 32)
        case 6: return GuestArchitecture(.mips, bits: 64)
        case 7: return GuestArchitecture(.powerpc, bits: 32)
        case 8: return GuestArchitecture(.s390)
        case 9: return GuestArchitecture(.superh, bits: 32)
        case 10: return GuestArchitecture(.sparc, bits: 32)
        case 11: return GuestArchitecture(.sparc, bits: 64)
        case 12: return GuestArchitecture(.m68k, bits: 32)
        case 14: return GuestArchitecture(.microblaze, bits: 32)
        case 15: return GuestArchitecture(.nios2, bits: 32)
        case 21: return GuestArchitecture(.openrisc, bits: 32)
        case 22: return GuestArchitecture(.arm, bits: 64)
        case 23: return GuestArchitecture(.arc, bits: 32)
        case 24: return GuestArchitecture(.x86, bits: 64)
        case 25: return GuestArchitecture(.xtensa, bits: 32)
        case 26: return GuestArchitecture(.riscv)
        default: return nil
        }
    }
}

import Foundation

/// **La carte graphique de QEMU** (« std VGA », la carte Bochs) : ce qui donne
/// à tous les Linux un vrai `/dev/dri/card0`.
///
/// **Pourquoi elle.** L'écran n'était jusqu'ici qu'un cadre déclaré au noyau
/// par le chargeur (`screen_info`). Selon le noyau, `simpledrm` en fait un
/// périphérique DRM, ou bien `vesafb` en fait un `fb0` et rien d'autre. Void
/// Linux Xfce est dans le second cas (`CONFIG_SYSFB_SIMPLEFB` absent) : pas de
/// `/dev/dri`, et `logind` ne donne de siège graphique à un `fb0` qu'avec
/// `nomodeset` — que l'image live de Void lit comme « pas de bureau » et à
/// quoi elle répond en arrêtant `lightdm`, `sddm` et `gdm`. Le bureau ne
/// démarrait donc jamais.
///
/// `bochs-drm` est dans presque tous les noyaux (Void, Debian, Fedora, Arch,
/// Alpine, openSUSE…), puisque c'est la carte qu'un QEMU montre par défaut.
/// Il prend la main sur le cadre du démarrage, change de résolution quand
/// l'invité le demande, et fait de l'écran un périphérique DRM ordinaire : un
/// siège pour `logind`, de quoi pour Xorg, Weston ou GNOME.
///
/// **Ce qu'elle est, vue du noyau** (`drivers/gpu/drm/tiny/bochs.c`) :
/// - sur le bus PCI, en 00:02.0, fabricant 0x1234, modèle 0x1111, classe
///   « contrôleur VGA », révision 2 (celle qui porte les registres étendus de
///   QEMU) ;
/// - BAR0 : la mémoire vidéo, 16 Mio, là où était déjà le cadre du démarrage
///   — le pilote n'a qu'à continuer de peindre au même endroit ;
/// - BAR2 : quatre kibioctets de registres : l'EDID (absent ici, donc des
///   modes par défaut, 1024 × 768 en tête), les ports VGA à 0x400, les
///   registres « DISPI » de Bochs à 0x500, seize bits chacun, et les deux
///   registres étendus de QEMU à 0x600 ;
/// - et les mêmes registres DISPI par les ports 0x1CE (index) et 0x1CF
///   (donnée), pour un pilote qui n'aurait pas la BAR2.
///
/// **Ce qu'elle fait** : rien d'autre que dire au cadre ce qu'il faut montrer.
/// Le pilote écrit la résolution, la profondeur (32 bits), la largeur
/// virtuelle et les décalages ; l'écran de l'application affiche ce rectangle
/// de la mémoire vidéo (`X86Framebuffer.Mode`). Changer de page, pour un
/// bureau qui alterne deux tampons, n'est qu'un décalage.
public final class X86BochsDisplay: @unchecked Sendable {
    /// L'emplacement sur le bus : celui où QEMU met sa carte.
    public static let slot: UInt32 = 2
    /// La taille de la mémoire vidéo : celle de QEMU. `bochs-drm` refuse les
    /// modes dont deux images ne tiennent pas dedans ; seize mébioctets
    /// laissent passer le 1920 × 1080.
    public static let memoryBytes = 16 << 20
    /// La fenêtre des registres (BAR2).
    public static let registersBytes: UInt64 = 0x1000

    /// Les registres DISPI, dans l'ordre de leurs index.
    enum Register: Int {
        case id = 0, xres, yres, bpp, enable, bank, virtualWidth, virtualHeight, xOffset, yOffset
        case videoMemory64K
    }

    /// Les bits de `ENABLE`.
    static let enabled: UInt16 = 0x01
    static let getCapabilities: UInt16 = 0x02
    static let linearFramebuffer: UInt16 = 0x40
    static let noClearMemory: UInt16 = 0x80

    /// La version annoncée : la dernière, celle de QEMU.
    static let latestID: UInt16 = 0xB0C5
    /// Les plus grandes valeurs, rendues sous `GETCAPS`.
    static let maximumWidth: UInt16 = 2560
    static let maximumHeight: UInt16 = 1600
    static let maximumDepth: UInt16 = 32

    /// L'écran que la carte pilote.
    public let screen: X86Framebuffer

    /// Les onze registres DISPI.
    private(set) var registers: [UInt16]
    /// L'index choisi par le port 0x1CE.
    private(set) var index: UInt16 = 0

    /// Où sont les registres (BAR2).
    public private(set) var registersBase: UInt64
    /// Le registre de commande PCI. Les BAR sont décodées quoi qu'il dise :
    /// le noyau ne coupe le décodage que le temps de mesurer leur taille, et
    /// la mesure est déjà prise à part (`sizing`).
    private(set) var command: UInt16 = 0x0003
    /// Le noyau mesure la taille d'une BAR en y écrivant des uns : vrai
    /// jusqu'à ce qu'il y remette une adresse.
    private var sizingMemory = false
    private var sizingRegisters = false

    /// Les deux registres étendus de QEMU : leur taille (huit octets), et
    /// l'ordre des octets que le pilote demande.
    static let extendedSize: UInt32 = 8
    private(set) var byteOrder: UInt32 = 0x1E1E_1E1E

    public init(screen: X86Framebuffer, registersBase: UInt64) {
        self.screen = screen
        self.registersBase = registersBase
        var registers = [UInt16](repeating: 0, count: 11)
        registers[Register.id.rawValue] = Self.latestID
        registers[Register.videoMemory64K.rawValue] = UInt16(truncatingIfNeeded: screen.memorySize >> 16)
        self.registers = registers
    }

    // MARK: - Les registres DISPI

    /// Lit un registre DISPI.
    func readRegister(_ register: UInt16) -> UInt16 {
        guard Int(register) < registers.count else { return 0 }
        let enable = registers[Register.enable.rawValue]
        if enable & Self.getCapabilities != 0 {
            switch Register(rawValue: Int(register)) {
            case .xres: return Self.maximumWidth
            case .yres: return Self.maximumHeight
            case .bpp: return Self.maximumDepth
            default: break
            }
        }
        return registers[Int(register)]
    }

    /// Écrit un registre DISPI, comme QEMU (`vbe_ioport_write_data`) : la
    /// mise en marche remet la largeur virtuelle et les décalages à leur
    /// valeur de départ, et efface ce que l'écran va montrer.
    func writeRegister(_ register: UInt16, _ value: UInt16) {
        guard let which = Register(rawValue: Int(register)) else { return }
        switch which {
        case .id:
            if (0xB0C0...Self.latestID).contains(value) { registers[which.rawValue] = value }
        case .videoMemory64K:
            break  // en lecture seule
        case .bpp:
            registers[which.rawValue] = value == 0 ? 8 : value
        case .enable:
            let wasEnabled = registers[which.rawValue] & Self.enabled != 0
            registers[which.rawValue] = value
            if value & Self.enabled != 0 && !wasEnabled {
                registers[Register.virtualWidth.rawValue] = registers[Register.xres.rawValue]
                registers[Register.virtualHeight.rawValue] = registers[Register.yres.rawValue]
                registers[Register.xOffset.rawValue] = 0
                registers[Register.yOffset.rawValue] = 0
                if value & Self.noClearMemory == 0 { screen.clear(bytes: visibleBytes) }
            }
        default:
            registers[which.rawValue] = value
        }
        showMode()
    }

    /// Ce que le mode demandé montre, en octets depuis son premier pixel.
    private var visibleBytes: Int {
        Int(registers[Register.virtualWidth.rawValue]) * 4 * Int(registers[Register.yres.rawValue])
    }

    /// **Le mode que l'écran affiche**, d'après les registres. Allumée, en
    /// trente-deux bits et en cadre linéaire, la carte montre le rectangle
    /// qu'elle décrit ; éteinte, l'écran revient au cadre du démarrage. Une
    /// autre profondeur ne se montre pas : aucun des pilotes qui comptent ne
    /// la demande, et une image mal lue serait pire qu'une image figée.
    private func showMode() {
        let enable = registers[Register.enable.rawValue]
        guard enable & Self.enabled != 0 else {
            screen.setMode(screen.bootMode)
            return
        }
        guard enable & Self.linearFramebuffer != 0, registers[Register.bpp.rawValue] == 32 else { return }
        let width = Int(registers[Register.xres.rawValue])
        let height = Int(registers[Register.yres.rawValue])
        let virtualWidth = max(Int(registers[Register.virtualWidth.rawValue]), width)
        let start = (Int(registers[Register.yOffset.rawValue]) * virtualWidth
            + Int(registers[Register.xOffset.rawValue])) * 4
        screen.setMode(X86Framebuffer.Mode(width: width, height: height, bytesPerRow: virtualWidth * 4,
                                           start: start))
    }

    // MARK: - Les ports

    public static let indexPort: UInt16 = 0x1CE
    public static let dataPort: UInt16 = 0x1CF

    public func writePort(_ port: UInt16, _ value: UInt16) {
        if port == Self.indexPort {
            index = value
        } else if port == Self.dataPort {
            writeRegister(index, value)
        }
    }

    public func readPort(_ port: UInt16) -> UInt16 {
        port == Self.indexPort ? index : (port == Self.dataPort ? readRegister(index) : 0xFFFF)
    }

    // MARK: - La BAR2

    /// Le décalage dans la fenêtre des registres, ou nil si l'adresse est
    /// ailleurs.
    @inline(__always)
    func registerOffset(_ address: UInt64, _ width: Int) -> UInt64? {
        guard address >= registersBase else { return nil }
        let offset = address &- registersBase
        guard offset &+ UInt64(width) <= Self.registersBytes else { return nil }
        return offset
    }

    /// Lit dans la fenêtre des registres. L'EDID est absent — des zéros, que
    /// `bochs-drm` reconnaît comme « pas d'EDID » —, et les ports VGA ne
    /// disent rien.
    func readRegisters(_ offset: UInt64, _ width: Int) -> UInt64 {
        switch offset {
        case 0x500..<0x516:
            let register = UInt16((offset - 0x500) / 2)
            var value = UInt64(readRegister(register))
            if width > 2, register + 1 < UInt16(registers.count) {
                value |= UInt64(readRegister(register + 1)) << 16
            }
            return value
        case 0x600: return UInt64(Self.extendedSize)
        case 0x604: return UInt64(byteOrder)
        default: return 0
        }
    }

    func writeRegisters(_ offset: UInt64, _ width: Int, _ value: UInt64) {
        switch offset {
        case 0x500..<0x516:
            let register = UInt16((offset - 0x500) / 2)
            writeRegister(register, UInt16(truncatingIfNeeded: value))
            if width > 2 { writeRegister(register + 1, UInt16(truncatingIfNeeded: value >> 16)) }
        case 0x604:
            byteOrder = UInt32(truncatingIfNeeded: value)
        default:
            break  // l'EDID est en lecture seule, les ports VGA sans effet
        }
    }

    // MARK: - L'espace de configuration PCI

    /// Le mot de configuration à `register`.
    func configuration(_ register: UInt32) -> UInt32 {
        switch register {
        case 0x00: return 0x1111_1234                // Bochs / QEMU std VGA
        case 0x04: return UInt32(command)
        case 0x08: return 0x0300_0002                // contrôleur VGA, révision 2
        case 0x0C: return 0                          // en-tête de type zéro
        case 0x10:                                    // BAR0 : la mémoire vidéo, préchargeable
            if sizingMemory { return ~UInt32(truncatingIfNeeded: screen.memorySize - 1) | 0x08 }
            return UInt32(truncatingIfNeeded: screen.base) | 0x08
        case 0x18:                                    // BAR2 : les registres
            if sizingRegisters { return ~UInt32(truncatingIfNeeded: Self.registersBytes - 1) }
            return UInt32(truncatingIfNeeded: registersBase)
        case 0x2C: return 0x1100_1AF4                // sous-système : QEMU
        default: return 0
        }
    }

    /// Une écriture de configuration, déjà recomposée en un mot entier.
    func writeConfiguration(_ register: UInt32, _ value: UInt32) {
        switch register {
        case 0x04:
            command = UInt16(truncatingIfNeeded: value)
        case 0x10:
            if value == 0xFFFF_FFFF {
                sizingMemory = true
            } else {
                sizingMemory = false
                // Les bits bas disent le type ; l'adresse est alignée sur la
                // taille.
                screen.move(to: UInt64(value) & ~UInt64(screen.memorySize - 1))
            }
        case 0x18:
            if value == 0xFFFF_FFFF {
                sizingRegisters = true
            } else {
                sizingRegisters = false
                registersBase = UInt64(value) & ~(Self.registersBytes - 1)
            }
        default:
            break
        }
    }

    // MARK: - Ce qu'on sauve

    /// Ce qu'un instantané porte de la carte : lu et validé d'abord,
    /// appliqué à la fin, comme le reste de la reprise.
    struct State: Equatable {
        var registers: [UInt16]
        var index: UInt16
        var registersBase: UInt64
        var command: UInt16
        var byteOrder: UInt32
    }

    var state: State {
        State(registers: registers, index: index, registersBase: registersBase, command: command,
              byteOrder: byteOrder)
    }

    func save(into writer: inout Snapshot.Writer) {
        for value in registers { writer.u32(UInt32(value)) }
        writer.u32(UInt32(index))
        writer.u64(registersBase)
        writer.u32(UInt32(command))
        writer.u32(byteOrder)
    }

    static func readState(from reader: inout Snapshot.Reader) throws -> State {
        var registers = [UInt16](repeating: 0, count: 11)
        for position in registers.indices { registers[position] = UInt16(truncatingIfNeeded: try reader.u32()) }
        let index = UInt16(truncatingIfNeeded: try reader.u32())
        let base = try reader.u64()
        let command = UInt16(truncatingIfNeeded: try reader.u32())
        let order = try reader.u32()
        guard base & (registersBytes - 1) == 0, base < 1 << 32 else { throw Snapshot.Failure.corrupt }
        return State(registers: registers, index: index, registersBase: base, command: command,
                     byteOrder: order)
    }

    /// L'état repris, et l'écran qui le suit. La taille de la mémoire vidéo
    /// ne se reprend pas : c'est la machine qui la fixe, pas l'instantané.
    func apply(_ restored: State) {
        var values = restored.registers
        values[Register.videoMemory64K.rawValue] = registers[Register.videoMemory64K.rawValue]
        registers = values
        index = restored.index
        registersBase = restored.registersBase
        command = restored.command
        byteOrder = restored.byteOrder
        showMode()
    }
}

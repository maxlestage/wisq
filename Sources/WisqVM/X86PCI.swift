import Foundation

/// Le pont PCI : de quoi qu'un noyau trouve un disque.
///
/// **Pourquoi PCI après tout.** Le transport MMIO de virtio se passe de bus,
/// et c'est par là qu'on a commencé — mais le noyau d'Alpine le refuse : son
/// pilote `virtio_mmio` est compilé sans `CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES`,
/// et répond « unknown parameter 'device' ignored » à la ligne de commande qui
/// devait lui dire où regarder. Mesuré, pas supposé. Sans bus à énumérer et
/// sans table ACPI, il ne reste plus rien à quoi accrocher un périphérique.
///
/// PCI, lui, s'énumère tout seul : le noyau écrit une adresse dans le port
/// 0xCF8, lit le port 0xCFC, et découvre ce qui répond. C'est ce qu'il essaie
/// déjà à chaque démarrage, et ce qu'il conclut aujourd'hui :
///
///     PCI: Fatal: No config space access function found
///     PCI: System does not support PCI
///
/// Il suffit donc de répondre. Et il y a un second gain : un périphérique PCI
/// porte un `modalias`, l'init d'Alpine charge les modules par alias au
/// démarrage, et le pilote arrive tout seul.
///
/// **Un seul périphérique, une seule fenêtre.** Bus zéro, emplacement trois,
/// fonction zéro, et l'espace de configuration est synthétisé plutôt que
/// stocké : ce qui est en dur ne peut pas dériver.
public final class X86PCIHost: @unchecked Sendable {
    public static let addressPort: UInt16 = 0xCF8
    public static let dataPort: UInt16 = 0xCFC
    /// L'emplacement du disque sur le bus.
    public static let slot: UInt32 = 3
    /// **Et un pont hôte à l'emplacement zéro, sans lequel rien n'existe.**
    /// Linux ne se contente pas de voir répondre le port de configuration :
    /// il parcourt les trente-deux emplacements et exige d'y trouver au moins
    /// un pont hôte, une carte VGA, ou un fabricant Intel ou Compaq
    /// (`pci_sanity_check`). Sans ça il conclut « PCI: System does not support
    /// PCI » et n'énumère rien — c'est exactement ce qu'il disait de wisq une
    /// fois les deux ports branchés. Le pont annoncé est celui de QEMU, un
    /// 440FX, parce qu'un noyau le connaît par cœur et ne lui demande rien.
    public static let bridgeSlot: UInt32 = 0
    /// La taille de la fenêtre de ports que le périphérique demande.
    public static let windowSize: UInt32 = 0x40

    /// Ce que le noyau a écrit dans le port d'adresse.
    public private(set) var address: UInt32 = 0
    /// Le disque, ou rien. Sans lui le bus existe mais reste vide, ce qui est
    /// une réponse honnête : le noyau énumère, ne trouve rien, et continue.
    public var storage: X86VirtioBlock?

    /// Ce que le noyau a activé — bit 0 les ports, bit 2 la maîtrise du bus.
    public private(set) var command: UInt16 = 0
    /// Où le noyau a placé la fenêtre de ports du périphérique.
    public private(set) var window: UInt32 = 0
    /// La ligne d'interruption, telle que le noyau la lit **et l'écrit**.
    public private(set) var interruptLine: UInt8 = X86VirtioBlock.interruptLine
    /// Vrai entre l'écriture de tous les uns dans le registre de fenêtre et la
    /// lecture qui suit : c'est ainsi qu'un noyau demande la **taille**.
    var sizing = false

    public init(storage: X86VirtioBlock? = nil) {
        self.storage = storage
    }

    /// Vrai quand les ports du périphérique sont activés et placés.
    public var windowOpen: Bool {
        storage != nil && window != 0 && command & 0x01 != 0
    }

    /// Le décalage dans la fenêtre du périphérique, ou rien.
    @inline(__always)
    public func windowOffset(_ port: UInt16) -> UInt16? {
        guard windowOpen, UInt32(port) >= window,
              UInt32(port) &- window < Self.windowSize else { return nil }
        return port &- UInt16(truncatingIfNeeded: window)
    }

    // MARK: - L'espace de configuration

    /// L'adresse décodée : le bit d'activation, le bus, l'emplacement, la
    /// fonction et le registre.
    var selected: (enabled: Bool, bus: UInt32, slot: UInt32, function: UInt32, register: UInt32) {
        (address & 0x8000_0000 != 0, (address >> 16) & 0xFF,
         (address >> 11) & 0x1F, (address >> 8) & 0x07, address & 0xFC)
    }

    /// Vrai quand l'adresse désigne le périphérique qu'on a.
    var addressesTheDevice: Bool {
        let it = selected
        return it.enabled && it.bus == 0 && it.slot == Self.slot && it.function == 0
            && storage != nil
    }

    /// Vrai quand l'adresse désigne le pont hôte.
    var addressesTheBridge: Bool {
        let it = selected
        return it.enabled && it.bus == 0 && it.slot == Self.bridgeSlot && it.function == 0
    }

    /// Le pont : quatre registres, et rien d'autre. Il n'a ni fenêtre ni
    /// interruption — il est là pour être reconnu.
    func bridgeConfiguration() -> UInt32 {
        switch selected.register {
        case 0x00: return 0x1237_8086       // Intel 440FX, comme chez QEMU
        case 0x04: return 0x0000_0006       // mémoire et maîtrise du bus
        case 0x08: return 0x0600_0002       // pont hôte, révision deux
        case 0x0C: return 0                 // en-tête de type zéro
        default: return 0
        }
    }

    /// Les trente-deux bits du registre désigné.
    ///
    /// **Un emplacement vide rend tous les uns**, et c'est ce qui dit au noyau
    /// qu'il n'y a personne : rendre des zéros lui ferait croire à un
    /// périphérique de fabricant zéro.
    public func configuration() -> UInt32 {
        if addressesTheBridge { return bridgeConfiguration() }
        guard addressesTheDevice else { return 0xFFFF_FFFF }
        switch selected.register {
        case 0x00: return 0x1001_1AF4          // virtio-blk, en version ancienne
        case 0x04: return UInt32(command)      // aucun bit d'état à annoncer
        case 0x08: return 0x0100_0000          // stockage de masse, révision zéro
        case 0x0C: return 0                    // en-tête de type zéro
        case 0x10:
            // La fenêtre de ports. Pendant la mesure de taille, le noyau lit
            // le masque : les bits qu'il ne peut pas changer disent la taille.
            if sizing { return ~(Self.windowSize &- 1) | 1 }
            return window | 1
        case 0x2C: return 0x0002_1AF4          // sous-système : un disque
        case 0x3C: return UInt32(interruptLine) | (1 << 8)  // ligne, puis broche A
        default: return 0
        }
    }

    public func writeConfiguration(_ value: UInt32, _ width: Int, _ byte: UInt32) {
        guard addressesTheDevice else { return }
        switch selected.register {
        case 0x04:
            command = UInt16(truncatingIfNeeded: value)
        case 0x10:
            if value == 0xFFFF_FFFF {
                sizing = true
            } else {
                sizing = false
                // Les bits bas ne sont pas au noyau : ils disent le type et
                // l'alignement, et les garder placerait la fenêtre de travers.
                window = value & ~(Self.windowSize &- 1)
            }
        case 0x3C where width == 1 && byte == 0:
            interruptLine = UInt8(truncatingIfNeeded: value)
        case 0x3C where width >= 2:
            interruptLine = UInt8(truncatingIfNeeded: value)
        default:
            break
        }
    }

    // MARK: - Les deux ports

    public func writeAddress(_ value: UInt32) { address = value }

    // MARK: - Ce qu'on sauve

    /// **Le bus garde trois choses qu'aucune valeur par défaut ne retrouve.**
    /// L'adresse est celle du dernier `0xCF8` écrit, et une reprise au milieu
    /// d'un couple adresse-donnée lirait sinon le mauvais registre. La
    /// commande dit si les ports sont ouverts — refermés, le pilote croit
    /// parler au périphérique et parle à personne. Et la fenêtre est là où le
    /// noyau a placé le BAR : la reperdre déplacerait le disque sous un pilote
    /// qui n'a aucune raison de le rechercher.
    func save(into writer: inout Snapshot.Writer) {
        writer.u32(address)
        writer.u32(UInt32(command))
        writer.u32(window)
        writer.u32(UInt32(interruptLine))
        writer.u32(sizing ? 1 : 0)
    }

    func restore(from reader: inout Snapshot.Reader) throws {
        address = try reader.u32()
        command = UInt16(truncatingIfNeeded: try reader.u32())
        window = try reader.u32()
        interruptLine = UInt8(truncatingIfNeeded: try reader.u32())
        sizing = try reader.u32() != 0
    }
}

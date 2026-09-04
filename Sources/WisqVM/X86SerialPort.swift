import Foundation

/// Le 16550 : le port série tel que le pilote 8250 de Linux le sonde, et pas
/// seulement tel que `printk` l'écrit.
///
/// **Pourquoi il a fallu plus qu'un tampon de sortie.** Le noyau écrivait ses
/// lignes depuis le premier jour — `printk` prend le port directement, sans
/// rien lui demander. Mais sous QEMU il écrit aussi « ttyS0 at I/O 0x3f8
/// (irq = 4, base_baud = 115200) is a 16550A », et sous wisq cette ligne
/// manquait : le pilote avait sondé le port, ne l'avait pas trouvé, et ne
/// l'avait donc jamais **enregistré** comme terminal. `/dev/console`
/// n'existait pour personne en espace utilisateur ; l'init d'Alpine parlait
/// dans le vide, et son « Mounting boot media: failed. » n'avait nulle part
/// où aller.
///
/// La sonde (`autoconfig` dans `8250_port.c`) demande quatre choses dans
/// l'ordre : que le registre d'autorisation se relise, que la boucle de test
/// du modem renvoie `DCD | CTS`, que le registre de brouillon garde ce qu'on
/// y met, et que le registre d'identification dise s'il y a une FIFO. Puis,
/// pour que l'espace utilisateur écrive, l'interruption d'émission doit
/// arriver : le pilote pose les octets dans un tampon et attend qu'elle
/// vienne les chercher, seize par seize.
extension X86LegacyDevices {
    public struct SerialPort: Sendable, Equatable {
        /// IER : réception (bit 0), émission (bit 1), état de ligne (2), modem (3).
        public var interruptEnable: UInt8 = 0
        /// FCR : le bit 0 active la FIFO, et c'est lui que l'identification
        /// répète dans ses deux bits hauts — « 16550A ».
        public var fifoControl: UInt8 = 0
        /// LCR : le bit 7 (`DLAB`) fait apparaître le diviseur à la place du
        /// tampon et de l'autorisation.
        public var lineControl: UInt8 = 0
        /// MCR : le bit 4 met la puce en boucle sur elle-même.
        public var modemControl: UInt8 = 0
        /// SCR : aucun rôle, sinon garder ce qu'on y met.
        public var scratch: UInt8 = 0
        /// Le diviseur de bauds. Douze pour 115 200.
        public var divisor: UInt16 = 0
        /// L'émission a quelque chose à dire : levée quand on l'autorise ou
        /// qu'un octet part — le transmetteur est vide aussitôt, ici —,
        /// acquittée par la lecture du registre d'identification.
        public var transmitPending = false

        public init() {}

        var dlab: Bool { lineControl & 0x80 != 0 }
        var loopback: Bool { modemControl & 0x10 != 0 }
    }
}

extension X86Core {
    static let serialBase: UInt16 = 0x3F8

    /// La ligne quatre demande. Réception avant émission, comme sur la puce.
    var serialInterrupting: Bool {
        let port = devices.serial
        if port.interruptEnable & 0x01 != 0 && !serialInput.isEmpty { return true }
        return port.interruptEnable & 0x02 != 0 && port.transmitPending
    }

    mutating func serialWrite(_ offset: UInt16, _ byte: UInt8) {
        switch offset {
        case 0 where devices.serial.dlab:
            devices.serial.divisor = (devices.serial.divisor & 0xFF00) | UInt16(byte)
        case 1 where devices.serial.dlab:
            devices.serial.divisor = (devices.serial.divisor & 0x00FF) | (UInt16(byte) << 8)
        case 0:
            // En boucle, l'octet revient par la réception ; sinon il sort.
            if devices.serial.loopback { serialInput.append(byte) } else { serialOutput.append(byte) }
            devices.serial.transmitPending = true
        case 1:
            let was = devices.serial.interruptEnable
            devices.serial.interruptEnable = byte & 0x0F
            if byte & 0x02 != 0 && was & 0x02 == 0 { devices.serial.transmitPending = true }
        case 2:
            devices.serial.fifoControl = byte
        case 3:
            devices.serial.lineControl = byte
        case 4:
            devices.serial.modemControl = byte & 0x1F
        case 7:
            devices.serial.scratch = byte
        default:
            break
        }
    }

    mutating func serialRead(_ offset: UInt16) -> UInt8 {
        let port = devices.serial
        switch offset {
        case 0 where port.dlab: return UInt8(truncatingIfNeeded: port.divisor)
        case 1 where port.dlab: return UInt8(truncatingIfNeeded: port.divisor >> 8)
        case 0: return serialInput.isEmpty ? 0 : serialInput.removeFirst()
        case 1: return port.interruptEnable
        case 2:
            // L'identification : la cause la plus prioritaire, bit 0 à zéro
            // quand il y en a une, et la FIFO dans les deux bits hauts.
            let fifo: UInt8 = port.fifoControl & 0x01 != 0 ? 0xC0 : 0
            if port.interruptEnable & 0x01 != 0 && !serialInput.isEmpty { return fifo | 0x04 }
            if port.interruptEnable & 0x02 != 0 && port.transmitPending {
                devices.serial.transmitPending = false
                return fifo | 0x02
            }
            return fifo | 0x01
        case 3: return port.lineControl
        case 4: return port.modemControl
        case 5:
            // L'état de la ligne : « le transmetteur est vide ». Sans ça, un
            // noyau attend indéfiniment de pouvoir écrire.
            return 0x60 | (serialInput.isEmpty ? 0 : 1)
        case 6:
            // En boucle, les sorties reviennent sur les entrées : DTR → DSR,
            // RTS → CTS, OUT1 → RI, OUT2 → DCD. Sinon, un câble branché.
            guard port.loopback else { return 0xB0 }
            let control = port.modemControl
            return (control & 0x01 != 0 ? 0x20 : 0) | (control & 0x02 != 0 ? 0x10 : 0)
                | (control & 0x04 != 0 ? 0x40 : 0) | (control & 0x08 != 0 ? 0x80 : 0)
        case 7: return port.scratch
        default: return 0
        }
    }
}

import Foundation

/// **L'horloge du PC** : le MC146818 et sa petite mémoire CMOS, aux ports
/// 0x70 (l'index) et 0x71 (la donnée).
///
/// **Le défaut que ce fichier ferme.** Les deux ports tombaient dans le cas
/// par défaut et rendaient zéro. Chaque noyau le disait au démarrage —
/// `PM: RTC time: 00:00:00, date: 2000-00-00` — et chaque invité se croyait
/// le premier janvier 2000 : les journaux de Guix sont datés de 1999, les
/// fichiers créés aussi, et surtout **aucun certificat TLS n'est valide** à
/// cette date. Un `apt update` en HTTPS, un `curl`, un gestionnaire de paquets
/// qui vérifie ses signatures dans le temps : tous refusaient.
///
/// **L'heure est celle de l'hôte, en UTC**, lue au moment où l'invité la
/// demande. C'est le `-rtc base=utc` de QEMU, ce que Linux attend par défaut
/// (`hwclock` en UTC). Elle n'est pas tenue dans l'instantané : une machine
/// reprise lit l'heure du moment de sa reprise, comme un vrai PC sorti de
/// veille lit celle de sa pile.
///
/// **Ce qui est rendu, registre par registre** :
/// - 0x00, 0x02, 0x04 : secondes, minutes, heures ; 0x06 le jour de la
///   semaine (1 pour dimanche), 0x07 le jour, 0x08 le mois, 0x09 l'année sur
///   deux chiffres et 0x32 le siècle ;
/// - 0x0A : ni mise à jour en cours (le bit UIP est toujours bas), ni rien à
///   attendre ;
/// - 0x0B : ce que le noyau y a écrit — BCD et 24 heures au départ, ce que
///   rend un BIOS de PC. Le format des réponses suit ses bits 1 et 2 ;
/// - 0x0C : aucune interruption en attente ;
/// - 0x0D : la pile est bonne (bit VRT). Sans lui, Linux tient l'heure pour
///   invalide ;
/// - le reste : une mémoire de cent vingt-huit octets, inscriptible, comme
///   celle d'un vrai CMOS.
public struct X86RealTimeClock: Sendable, Equatable {
    public static let indexPort: UInt16 = 0x70
    public static let dataPort: UInt16 = 0x71

    /// Le registre que le prochain accès au port de donnée vise. Le bit 7 de
    /// l'octet écrit masque la NMI sur un vrai PC ; il n'est pas gardé.
    public var index: UInt8 = 0

    /// La mémoire CMOS, hors des registres d'horloge.
    public var memory = [UInt8](repeating: 0, count: 128)

    /// Le registre B : bit 1, 24 heures ; bit 2, binaire plutôt que BCD.
    public var statusB: UInt8 = 0x02

    /// **L'instant à rendre, figé**, en secondes depuis 1970 — pour un test.
    /// Nil : l'horloge de l'hôte.
    public var frozenAt: Int64?

    public init() {}

    mutating func write(_ port: UInt16, _ value: UInt8) {
        if port == Self.indexPort {
            index = value & 0x7F
            return
        }
        switch index {
        // Les registres de l'heure : l'hôte la tient, une écriture ne la
        // change pas. `hwclock --systohc` n'a donc pas d'effet durable, comme
        // sur une machine virtuelle dont l'hôte est la référence.
        case 0x00, 0x02, 0x04, 0x06, 0x07, 0x08, 0x09, 0x32, 0x0A, 0x0C, 0x0D: break
        case 0x0B: statusB = value
        default: memory[Int(index)] = value
        }
    }

    func read(_ port: UInt16) -> UInt8 {
        if port == Self.indexPort { return index }
        let now = Self.calendar(at: frozenAt ?? Int64(Date().timeIntervalSince1970))
        switch index {
        case 0x00: return encode(now.second)
        case 0x02: return encode(now.minute)
        case 0x04: return encodeHour(now.hour)
        case 0x06: return encode(now.weekday)
        case 0x07: return encode(now.day)
        case 0x08: return encode(now.month)
        case 0x09: return encode(now.year % 100)
        case 0x32: return encode(now.year / 100)
        case 0x0A: return 0x26
        case 0x0B: return statusB
        case 0x0C: return 0
        case 0x0D: return 0x80
        case 0x01, 0x03, 0x05: return 0
        default: return memory[Int(index)]
        }
    }

    /// Un nombre de 0 à 99, en BCD ou en binaire selon le registre B.
    func encode(_ value: Int) -> UInt8 {
        statusB & 0x04 != 0 ? UInt8(value) : UInt8((value / 10) << 4 | value % 10)
    }

    /// L'heure, sur 24 heures, ou sur 12 avec le bit 7 pour l'après-midi.
    func encodeHour(_ hour: Int) -> UInt8 {
        guard statusB & 0x02 == 0 else { return encode(hour) }
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return encode(twelve) | (hour >= 12 ? 0x80 : 0)
    }

    struct Calendar: Equatable {
        var year, month, day, hour, minute, second, weekday: Int
    }

    /// Le calendrier grégorien en UTC, sans `Calendar` ni fuseau : les jours
    /// depuis 1970 donnent la date par l'algorithme civil de Howard Hinnant,
    /// et le jour de la semaine (1 pour dimanche, comme le MC146818) par le
    /// jeudi du premier janvier 1970.
    static func calendar(at seconds: Int64) -> Calendar {
        let days = Int(seconds >= 0 ? seconds / 86_400 : (seconds - 86_399) / 86_400)
        let inDay = Int(seconds - Int64(days) * 86_400)
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        let weekday = ((days % 7 + 7 + 4) % 7) + 1
        return Calendar(year: year, month: month, day: day, hour: inDay / 3600,
                        minute: inDay / 60 % 60, second: inDay % 60, weekday: weekday)
    }
}

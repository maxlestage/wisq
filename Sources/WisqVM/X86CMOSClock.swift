import Foundation

/// **L'horloge du PC** : le MC146818 et sa mémoire CMOS, par les ports 0x70
/// (l'index) et 0x71 (la donnée).
///
/// **Pourquoi elle compte.** Sans elle, l'invité n'a aucune idée de la date :
/// Debian 13 démarrait au 13 avril 2026, la date de son image, et `apt`
/// refusait toutes les signatures de ses dépôts, datées de l'avenir. TLS
/// tombe de la même façon sur des certificats « pas encore valides ».
///
/// **L'heure est celle de l'hôte**, en UTC, lue à chaque accès : une session
/// reprise, un téléphone resté en veille, retrouvent l'heure juste sans rien
/// rattraper. Un invité qui règle l'horloge (`hwclock --systohc`) ne change
/// que l'écart qu'il garde avec l'hôte.
///
/// **Ce qu'elle ne fait pas** : ni alarme ni interruption périodique (la
/// ligne huit reste muette), et l'écart réglé par l'invité ne passe pas dans
/// l'instantané — à la reprise, l'heure redevient celle de l'hôte.
struct X86CMOSClock {
    /// Le registre que le prochain accès à 0x71 lit ou écrit.
    var index: UInt8 = 0
    /// Ce que l'invité a réglé, moins l'heure de l'hôte au moment du réglage.
    var offset: TimeInterval = 0
    /// Le registre B : 24 heures, en BCD, comme le laisse un BIOS. Linux le
    /// lit et s'y plie ; il ne le change pas.
    var statusB: UInt8 = Self.twentyFourHours
    /// Les registres de date pendant un réglage (le bit SET du registre B) :
    /// l'heure ne change qu'à la fin, d'un coup.
    var setting: [UInt8]?
    /// Le reste de la mémoire CMOS, sans signification ici, mais relue telle
    /// qu'écrite.
    var memory = [UInt8](repeating: 0, count: 128)
    /// L'heure de l'hôte, pour les tests ; `nil` lit l'horloge du système.
    var fixedHostTime: Date?

    static let seconds: UInt8 = 0x00
    static let minutes: UInt8 = 0x02
    static let hours: UInt8 = 0x04
    static let weekday: UInt8 = 0x06
    static let day: UInt8 = 0x07
    static let month: UInt8 = 0x08
    static let year: UInt8 = 0x09
    static let statusA: UInt8 = 0x0A
    static let statusBRegister: UInt8 = 0x0B
    static let statusC: UInt8 = 0x0C
    static let statusD: UInt8 = 0x0D
    /// Le siècle, là où le place l'ACPI des PC : Linux, sans ACPI, ne le lit
    /// pas et déduit le siècle de l'année.
    static let century: UInt8 = 0x32

    static let binary: UInt8 = 0x04
    static let twentyFourHours: UInt8 = 0x02
    static let set: UInt8 = 0x80

    /// Les registres de la date, dans l'ordre où on les rend.
    static let dateRegisters: [UInt8] = [seconds, minutes, hours, weekday, day, month, year, century]

    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    /// L'heure que voit l'invité.
    var guestTime: Date { (fixedHostTime ?? Date()).addingTimeInterval(offset) }

    mutating func select(_ byte: UInt8) {
        // Le bit 7 coupe les NMI sur un vrai PC ; il n'est pas de l'index.
        index = byte & 0x7F
    }

    mutating func read() -> UInt8 {
        switch index {
        // Le bit 7 (« mise à jour en cours ») toujours à zéro : la date se lit
        // d'un coup, et Linux n'attend pas. 0x26 : le diviseur et la cadence
        // d'un BIOS.
        case Self.statusA: return 0x26
        case Self.statusBRegister: return statusB
        // Aucune interruption en attente.
        case Self.statusC: return 0
        // Le bit 7 : la pile tient, l'heure est bonne.
        case Self.statusD: return 0x80
        case let register where Self.dateRegisters.contains(register):
            if let setting, let at = Self.dateRegisters.firstIndex(of: register) { return setting[at] }
            return encoded(Self.fields(of: guestTime)[register] ?? 0, register: register)
        default:
            return memory[Int(index)]
        }
    }

    mutating func write(_ byte: UInt8) {
        switch index {
        case Self.statusBRegister:
            let starting = byte & Self.set != 0 && statusB & Self.set == 0
            let ending = byte & Self.set == 0 && statusB & Self.set != 0
            if starting { setting = Self.dateRegisters.map { read(register: $0) } }
            statusB = byte
            if ending, let setting { finishSetting(setting) }
        case Self.statusA, Self.statusC, Self.statusD:
            return
        case let register where Self.dateRegisters.contains(register):
            guard let at = Self.dateRegisters.firstIndex(of: register) else { return }
            if setting != nil {
                setting?[at] = byte
            } else {
                // Un registre écrit sans SET : comme le vrai, il prend effet
                // tout de suite.
                var now = Self.dateRegisters.map { read(register: $0) }
                now[at] = byte
                finishSetting(now)
            }
        default:
            memory[Int(index)] = byte
        }
    }

    private mutating func read(register: UInt8) -> UInt8 {
        let saved = index
        index = register
        defer { index = saved }
        return read()
    }

    /// La nouvelle heure de l'invité, lue dans les registres tels qu'il les a
    /// écrits, devient un écart avec l'hôte.
    private mutating func finishSetting(_ registers: [UInt8]) {
        setting = nil
        var values: [UInt8: Int] = [:]
        for (register, byte) in zip(Self.dateRegisters, registers) {
            values[register] = decoded(byte, register: register)
        }
        var parts = DateComponents()
        let century = values[Self.century].flatMap { $0 > 0 ? $0 : nil } ?? 20
        parts.year = century * 100 + (values[Self.year] ?? 0)
        parts.month = values[Self.month]
        parts.day = values[Self.day]
        parts.hour = values[Self.hours]
        parts.minute = values[Self.minutes]
        parts.second = values[Self.seconds]
        guard let date = Self.utc.date(from: parts) else { return }
        offset = date.timeIntervalSince(fixedHostTime ?? Date())
    }

    /// Les champs d'une date, par registre, en nombres.
    static func fields(of date: Date) -> [UInt8: Int] {
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let fullYear = parts.year ?? 2000
        return [
            seconds: parts.second ?? 0, minutes: parts.minute ?? 0, hours: parts.hour ?? 0,
            // Le dimanche vaut un, comme pour `Calendar`.
            weekday: parts.weekday ?? 1, day: parts.day ?? 1, month: parts.month ?? 1,
            year: fullYear % 100, century: fullYear / 100,
        ]
    }

    /// En BCD ou en binaire selon le registre B, et l'heure en douze heures
    /// s'il le demande : le bit 7 dit l'après-midi.
    func encoded(_ value: Int, register: UInt8) -> UInt8 {
        var number = value
        var afternoon = false
        if register == Self.hours, statusB & Self.twentyFourHours == 0 {
            afternoon = number >= 12
            number = number % 12 == 0 ? 12 : number % 12
        }
        let byte = statusB & Self.binary != 0 ? UInt8(number) : UInt8((number / 10) << 4 | number % 10)
        return afternoon ? byte | 0x80 : byte
    }

    func decoded(_ byte: UInt8, register: UInt8) -> Int {
        var raw = byte
        var afternoon = false
        if register == Self.hours, statusB & Self.twentyFourHours == 0 {
            afternoon = raw & 0x80 != 0
            raw &= 0x7F
        }
        var number = statusB & Self.binary != 0 ? Int(raw) : Int(raw >> 4) * 10 + Int(raw & 0x0F)
        if register == Self.hours, statusB & Self.twentyFourHours == 0 {
            number = number % 12 + (afternoon ? 12 : 0)
        }
        return number
    }
}

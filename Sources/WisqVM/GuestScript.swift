import Foundation

/// **Ce que la console série a écrit**, retenu pour qu'on le lise depuis un
/// autre fil que celui de la machine.
///
/// Les octets, pas du texte : une marque se cherche dans les octets, et une
/// position dans la console est un nombre d'octets. Compter en caractères
/// obligeait à redécoder toute la console à chaque tranche, et un octet
/// UTF-8 coupé entre deux morceaux décalait le compte.
public final class GuestConsole: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()

    public init() {}

    /// Ce que la machine vient d'écrire. Appelé depuis son fil.
    public func append(_ data: Data) {
        lock.lock()
        bytes += data
        lock.unlock()
    }

    /// Combien d'octets la console a reçus : c'est la « marque » d'un pilote.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return bytes.count
    }

    /// Toute la console, en texte : pour un journal, pas pour une recherche.
    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `marker` est-il apparu **après** l'octet `offset` ? Cherché dans tout
    /// ce qui suit, et pas dans le dernier morceau seulement : une marque
    /// coupée entre deux écritures de la machine est une marque quand même.
    public func contains(_ marker: String, after offset: Int) -> Bool {
        let wanted = Data(marker.utf8)
        lock.lock()
        defer { lock.unlock() }
        let start = bytes.startIndex + min(max(0, offset), bytes.count)
        return bytes.range(of: wanted, in: start..<bytes.endIndex) != nil
    }
}

/// **Ce qu'un pilote demande à une machine** : tourner un peu, recevoir des
/// frappes sur sa console, un doigt sur son écran, et montrer ses pixels.
///
/// Un protocole plutôt que `X86Machine` en dur : le pilotage se juge contre
/// une fausse machine, en millisecondes, et pas contre un bureau qui met une
/// demi-heure à venir.
public protocol ScriptableMachine: AnyObject {
    /// Fait tourner au plus `instructions`. Rend la fin de l'invité s'il a
    /// fini — éteint, redémarré, en faute —, `nil` s'il tourne encore.
    func advance(_ instructions: UInt64) -> String?
    /// Taper sur la console série.
    func send(_ data: Data)
    /// Poser un doigt sans appuyer : voir `GuestScript.nudgeEvery`.
    func nudge(x: Double, y: Double)
    /// Les pixels de l'écran (quatre octets par point, le bleu d'abord), ou
    /// `nil` sans écran.
    var screenPixels: [UInt8]? { get }
}

extension X86Machine: ScriptableMachine {
    public func advance(_ instructions: UInt64) -> String? {
        switch run(instructionBudget: instructions) {
        case .stopped: return nil
        case .powerOff: return "l'invité s'est éteint"
        case .reboot: return "l'invité a redémarré"
        case .faulted(let reason): return "le cœur a refusé : \(reason)"
        }
    }

    public func nudge(x: Double, y: Double) { _ = touch(x: x, y: y, buttons: 0) }

    public var screenPixels: [UInt8]? { display?.snapshot() }
}

/// **Conduire un invité par sa console**, comme une personne devant un
/// terminal : attendre une invite, taper, attendre la réponse, regarder
/// l'écran.
///
/// Vivait dans le banc du bureau (`X86DesktopResumeTests`) ; il est ici pour
/// que l'outil qui fabrique le bureau prêt (`wisq-fabrique`) et le banc qui
/// le reprend conduisent l'invité par **le même code**. Deux copies du même
/// pilote finiraient par attendre deux choses différentes.
///
/// **La règle des marques** : chaque frappe note où en est la console, et
/// l'attente qui suit ne regarde qu'après. La ligne tapée, que la console
/// répète, ne doit donc pas contenir la marque telle quelle : les scripts
/// l'écrivent par calcul (`echo FIN_$((1+1))` rend `FIN_2`).
public final class GuestScript {
    /// Un pas d'un déroulé : des données, pas du code, pour qu'un déroulé se
    /// lise d'un coup d'œil et se compare d'une version à l'autre.
    public enum Step: Equatable, Sendable {
        /// Attendre que la console montre ce texte après la dernière frappe.
        case expect(String)
        /// La même attente, mais **arrêtée dès que `refused` paraît** : une
        /// commande qui sait qu'elle a échoué le dit, et le déroulé s'arrête
        /// là au lieu d'user tout son budget à attendre ce qui ne viendra pas.
        case expectUnless(String, refused: String)
        /// Taper ceci sur la console série.
        case type(String)
        /// Attendre que plus de la moitié de l'écran soit allumée.
        case screenLit
    }

    /// Pourquoi un déroulé s'est arrêté avant la fin.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        /// La marque n'est pas venue dans le budget.
        case markerNeverCame(String, budget: UInt64)
        /// L'écran est resté noir dans le budget.
        case screenStayedDark(budget: UInt64)
        /// L'invité a fini en route : plus rien ne viendra.
        case guestEnded(String)
        /// La console a montré la marque de l'échec.
        case refused(String)

        public var description: String {
            switch self {
            case .markerNeverCame(let marker, let budget):
                return "« \(marker) » n'est pas venu en \(budget) instructions"
            case .screenStayedDark(let budget):
                return "l'écran est resté noir pendant \(budget) instructions"
            case .guestEnded(let why):
                return why
            case .refused(let marker):
                return "l'invité a répondu « \(marker) »"
            }
        }
    }

    /// Une tranche entre deux regards sur la console : un peu plus d'une
    /// seconde de l'invité, et autant de l'hôte sous l'interprète.
    public static let defaultSlice: UInt64 = 50_000_000

    /// **Un doigt qui bouge de temps en temps**, toutes les trente-quatre
    /// tranches (cinq secondes de l'invité) : sans rien en entrée, Xorg
    /// éteint l'écran au bout de dix minutes, et le bureau ne se voit plus.
    public static let nudgeEvery = 34

    public let machine: ScriptableMachine
    public let console: GuestConsole
    public let slice: UInt64
    /// Où en était la console à la dernière frappe : les attentes ne
    /// regardent qu'après.
    public private(set) var mark = 0
    /// Les tranches tournées depuis le début, toutes attentes confondues :
    /// c'est elles que compte le doigt.
    public private(set) var turns = 0
    /// Ce qui s'est passé, pas à pas, pour qui suit une longue fabrication.
    public var log: (String) -> Void = { _ in }

    public init(machine: ScriptableMachine, console: GuestConsole, slice: UInt64 = GuestScript.defaultSlice) {
        self.machine = machine
        self.console = console
        self.slice = max(1, slice)
    }

    /// Dérouler `steps`, chaque attente dans `budget` instructions au plus.
    /// S'arrête au premier pas qui n'aboutit pas, en disant lequel.
    public func run(_ steps: [Step], budget: UInt64) throws {
        for (index, step) in steps.enumerated() {
            log("pas \(index + 1)/\(steps.count) : \(Self.describe(step))")
            switch step {
            case .type(let text):
                type(text)
            case .expect(let marker):
                try expect(marker, budget: budget)
            case .expectUnless(let marker, let refused):
                try expect(marker, unless: refused, budget: budget)
            case .screenLit:
                try waitUntilLit(budget: budget)
            }
        }
    }

    /// Taper, et noter où en est la console : l'attente suivante regarde
    /// après.
    public func type(_ text: String) {
        mark = console.count
        machine.send(Data(text.utf8))
    }

    /// Faire tourner jusqu'à ce que la console montre `marker` après la
    /// dernière frappe. **Le budget compte l'attente** : un invité qui dort
    /// l'use aussi, et une marque qui ne vient jamais finit par rendre la
    /// main.
    ///
    /// Avec `refused`, l'attente s'arrête aussi dès que cette marque-là
    /// paraît, et le dit (`Failure.refused`).
    public func expect(_ marker: String, unless refused: String? = nil, budget: UInt64) throws {
        func settled() throws -> Bool {
            if let refused, console.contains(refused, after: mark) { throw Failure.refused(refused) }
            return console.contains(marker, after: mark)
        }
        if try settled() { return }
        for _ in 0..<turnsIn(budget) {
            try step()
            if try settled() { return }
        }
        throw Failure.markerNeverCame(marker, budget: budget)
    }

    /// Faire tourner jusqu'à ce que plus de la moitié de l'écran soit
    /// allumée. **Le bureau dessiné, pas un temps fixé** : sous
    /// l'interprète, `xfdesktop` met longtemps à charger son fond, et deux
    /// sauvegardes ont pris un écran encore noir, `xfdesktop` bien vivant.
    public func waitUntilLit(budget: UInt64) throws {
        for _ in 0..<turnsIn(budget) {
            if Self.litFraction(machine.screenPixels ?? []) > 0.5 { return }
            try step()
        }
        if Self.litFraction(machine.screenPixels ?? []) > 0.5 { return }
        throw Failure.screenStayedDark(budget: budget)
    }

    /// Une tranche, et le doigt quand c'est son tour.
    private func step() throws {
        if let ended = machine.advance(slice) { throw Failure.guestEnded(ended) }
        if turns % Self.nudgeEvery == 0 {
            machine.nudge(x: turns % (2 * Self.nudgeEvery) == 0 ? 0.25 : 0.5, y: 0.75)
        }
        turns += 1
    }

    private func turnsIn(_ budget: UInt64) -> Int { Int(clamping: budget / slice) }

    static func describe(_ step: Step) -> String {
        switch step {
        case .expect(let marker): return "attendre « \(marker) »"
        case .expectUnless(let marker, let refused): return "attendre « \(marker) », pas « \(refused) »"
        case .type(let text): return "taper « \(text.trimmingCharacters(in: .newlines)) »"
        case .screenLit: return "attendre l'écran dessiné"
        }
    }

    /// La part de l'écran qui n'est pas noire, de 0 à 1.
    public static func litFraction(_ pixels: [UInt8]) -> Double {
        var lit = 0
        for index in stride(from: 0, to: pixels.count - 3, by: 4)
        where pixels[index] | pixels[index + 1] | pixels[index + 2] != 0 { lit += 1 }
        return Double(lit) / Double(max(1, pixels.count / 4))
    }

    /// L'écran en PPM : une image que tout outil ouvre, pour voir ce qui a
    /// été sauvé.
    public static func ppm(_ display: X86Framebuffer) -> Data {
        ppm(pixels: display.snapshot(), width: display.width, height: display.height)
    }

    /// La même image, depuis des pixels de quatre octets (le bleu d'abord) :
    /// l'écran de la machine PC en Rust les rend ainsi (`RustPCScreen`).
    public static func ppm(pixels: [UInt8], width: Int, height: Int) -> Data {
        var ppm = Data("P6\n\(width) \(height)\n255\n".utf8)
        ppm.reserveCapacity(ppm.count + pixels.count / 4 * 3)
        for index in stride(from: 0, to: pixels.count - 3, by: 4) {
            ppm += [pixels[index + 2], pixels[index + 1], pixels[index]]
        }
        return ppm
    }
}

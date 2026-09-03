import Foundation

/// What the host agent reports about one VM.
///
/// Decoded tolerantly, because the two halves of wisq are installed and updated
/// **separately**: the daemon comes from Homebrew or a `curl` script, the app
/// from a sideload. A `brew upgrade` that teaches the agent a new VM state, on a
/// phone that has not been updated, used to lose the entire list — `listVMs`
/// decodes `[AgentVM]` in one call, so one machine this build could not read
/// took every other one with it.
///
/// The `State` enum already had `.unknown` for exactly that case; the decoder
/// simply never reached for it. It does now, and so does `guestOS`.
///
/// **`consoleProtocol` is deliberately not tolerated the same way.** An
/// unrecognised protocol becomes `nil` — "no console I know how to open" —
/// rather than falling back to `.vnc`, because a default there would open a VNC
/// session against a port the agent published for something else. Same
/// asymmetry as `Machine.security`: presentation may fall back, the thing that
/// decides what wisq connects to may not.
public struct AgentVM: Codable, Identifiable, Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case running, paused, stopped, starting, unknown

        public var displayName: String {
            switch self {
            case .running: return "En marche"
            case .paused: return "En pause"
            case .stopped: return "Arrêtée"
            case .starting: return "Démarrage…"
            case .unknown: return "Inconnu"
            }
        }
    }

    public var id: String
    public var name: String
    public var state: State
    /// Protocol and port the agent exposes for this VM's console, when it is up.
    public var consoleProtocol: RemoteProtocol?
    public var consolePort: Int?
    public var guestOS: GuestOS?
    /// What the VM is set to use, and what it was built with, in kibibytes.
    ///
    /// Two numbers because libvirt keeps two and they answer different
    /// questions: the maximum cannot change while the domain runs, the current
    /// is what it is allowed to use right now. On a stopped domain both come
    /// from its definition.
    ///
    /// Both optional: an agent that cannot say sends nothing, and nothing is
    /// what the app then shows. A zero would read as "no memory".
    public var memoryKiB: Int?
    public var maximumMemoryKiB: Int?

    public init(
        id: String,
        name: String,
        state: State,
        consoleProtocol: RemoteProtocol? = nil,
        consolePort: Int? = nil,
        guestOS: GuestOS? = nil,
        memoryKiB: Int? = nil,
        maximumMemoryKiB: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.consoleProtocol = consoleProtocol
        self.consolePort = consolePort
        self.guestOS = guestOS
        self.memoryKiB = memoryKiB
        self.maximumMemoryKiB = maximumMemoryKiB
    }

    /// Whether a console can actually be opened on this VM.
    ///
    /// **Both halves, and the second is the one that is easy to drop.** A
    /// running VM with no console port is a normal state, not a contradiction:
    /// libvirt reports a domain as `running` the moment it exists, while the
    /// guest is still bringing up its display, and `virsh vncdisplay` has
    /// nothing to say until it has. Treating `running` alone as ready opens a
    /// console on a port that is not listening yet.
    ///
    /// The rule used to live inside `AgentClient.waitUntilRunning`'s polling
    /// loop, where no test could reach it — the end-to-end suite drives the
    /// demo backend, which never produces the running-without-a-port state that
    /// a real libvirt produces on every boot. Here it is a property of the
    /// model, and both of its edges are held.
    public var isReadyForConsole: Bool {
        state == .running && consolePort != nil
    }

    /// The VM's memory as someone reads it, or nil when the agent said nothing.
    ///
    /// **One line, and two numbers only when they differ.** libvirt keeps a
    /// maximum and a current allocation, and on almost every domain they are
    /// the same — printing "256 Mio sur un maximum de 256 Mio" everywhere would
    /// train the reader to skip the line on the one machine where it matters.
    ///
    /// Mebibytes, and the abbreviation says so, because the rest of wisq counts
    /// memory in powers of two and two figures that counted differently could
    /// not be compared.
    public var memoryDescription: String? {
        guard let maximum = maximumMemoryKiB ?? memoryKiB else { return nil }
        let current = memoryKiB ?? maximum
        guard current != maximum else { return Self.describe(kibibytes: maximum) }
        return "\(Self.describe(kibibytes: current)) sur un maximum de "
            + Self.describe(kibibytes: maximum)
    }

    /// Kibibytes as a size, in the unit that keeps the number under a thousand.
    public static func describe(kibibytes: Int) -> String {
        let units = ["Kio", "Mio", "Gio", "Tio"]
        var value = Double(max(0, kibibytes))
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        // A whole number of kibibytes or mebibytes reads better without a
        // decimal that is always zero; libvirt hands out round numbers.
        let rounded = (value * 10).rounded() / 10
        let format = rounded == rounded.rounded() ? "%.0f %@" : "%.1f %@"
        return String(format: format, rounded, units[unit])
            .replacingOccurrences(of: ".", with: ",")
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.consolePort = try container.decodeIfPresent(Int.self, forKey: .consolePort)

        // A state this build has never heard of, or none at all, is `.unknown`.
        // Conservative on purpose: a VM is only ready when `isReadyForConsole`
        // says so, and that needs `.running`, so an unreadable state waits
        // rather than assumes.
        self.state = SettingCase.decode(container, .state, or: .unknown)
        self.guestOS = SettingCase.decode(container, .guestOS, or: GuestOS.unknown)

        // And this one refuses instead of falling back. See the type's doc.
        self.consoleProtocol = try container.decodeIfPresent(String.self, forKey: .consoleProtocol)
            .flatMap(RemoteProtocol.init(rawValue:))

        // `try?` on purpose, and it is the tolerant half of the same rule as
        // the state: memory is shown, never acted on. An agent that sent it as
        // a string — or in a shape a later version invents — must cost this VM
        // a line of text, not the whole list it arrived in.
        self.memoryKiB = try? container.decodeIfPresent(Int.self, forKey: .memoryKiB)
        self.maximumMemoryKiB = try? container.decodeIfPresent(
            Int.self, forKey: .maximumMemoryKiB)
    }
}

extension SettingCase {
    /// `AgentVM`'s fields are optional in the JSON as well as unknown-tolerant,
    /// so an absent key and an unrecognised name land on the same default. The
    /// `Settings` version distinguishes them because a settings blob that is
    /// the wrong *shape* is a damaged file; here the shape is a string or
    /// nothing, and both are things a differently-versioned agent really sends.
    static func decode<K: CodingKey, T: RawRepresentable>(
        _ container: KeyedDecodingContainer<K>, _ key: K, or fallback: T
    ) -> T where T.RawValue == String {
        // `try?` flattens here: an absent key and a value of the wrong shape
        // both arrive as nil, and both mean the fallback.
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            return fallback
        }
        return T(rawValue: raw) ?? fallback
    }
}

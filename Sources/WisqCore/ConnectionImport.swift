import Foundation

/// Turns a connection file into a machine the user can keep.
///
/// The two readers next door — `VirtViewerFile` and `RemoteDesktopFile` — stop
/// at what the file says. This is where that becomes something the app owns: a
/// `Machine` with a name, a protocol and a port, and a password put where
/// passwords go rather than carried along in the open.
///
/// Both files are written by other people's tools for other people's clients,
/// so everything here is a decision about what wisq does with a value it did
/// not choose. That is why it is its own type rather than an initialiser on
/// `Machine`: the rules below are worth reading, and worth testing, on their
/// own.
public enum ConnectionImport {
    /// A machine, and the secret that must not travel inside it.
    ///
    /// Returned as a pair rather than folded into `Machine` on purpose.
    /// `Machine` is `Codable` and gets written to disk; a password reaching it
    /// would be persisted in the clear next to the host it opens. The caller
    /// puts the secret in the `CredentialStore` and keeps only the reference.
    public struct Imported: Equatable, Sendable {
        public var machine: Machine
        public var password: String?
    }

    /// A name for a machine the file did not name.
    ///
    /// These files carry titles sometimes, but the ones that do carry things
    /// like `fedora:%d` — a printf template meant for a window title, not for a
    /// person. The host is what the user recognises, so the host is the name.
    static func name(forHost host: String) -> String {
        // An IPv6 literal is not a name anyone reads, but it is still better
        // than an empty row in a list.
        host.isEmpty ? "Machine importée" : host
    }

    /// The host check every other way of making a machine already applies.
    ///
    /// The editor runs `Validation.normalizedHost` on what the user typed,
    /// `AgentPairing` on what a QR carried, `AgentImportView` on a typed
    /// address. This path did not — the one whose input is the least
    /// trustworthy of the four, since these files arrive from Mail, from
    /// AirDrop, from a share sheet, chosen by whoever sent them.
    ///
    /// The effect was not a hole so much as a check in the wrong place: an
    /// `.rdp` naming `exemple.net/../autre` imported cleanly, was saved, and
    /// failed at connect time inside `NetworkByteStream`, far from the screen
    /// where the person could still have done something about it. A file is
    /// refused where it is opened.
    ///
    /// It belongs here and not in the two readers next door: they stop at what
    /// the file says, and this is the layer that decides what wisq does with a
    /// value it did not choose.
    static func validatedHost(_ raw: String) throws -> String {
        try Validation.normalizedHost(raw)
    }

    public static func machine(from connection: VirtViewerFile.Connection) throws -> Imported {
        let host = try validatedHost(connection.host)
        return Imported(
            machine: Machine(
                name: name(forHost: host),
                host: host,
                port: connection.port,
                proto: connection.proto,
                security: connection.security,
                // The reference is left nil: it is the caller's to mint once it
                // has actually stored the secret. A machine pointing at a
                // credential that was never written is worse than one with no
                // credential at all — it fails at connect time instead of
                // asking.
                credentialRef: nil,
                tags: ["importé"]
            ),
            password: connection.password
        )
    }

    /// The file's geometry is deliberately not carried.
    ///
    /// `desktopwidth` and `desktopheight` describe the monitor of whoever
    /// saved the file. On a phone that is not a preference, it is somebody
    /// else's screen — and `DisplaySettings` has no field for it because
    /// `followDeviceResolution` is the answer this app already has. Adding one
    /// would be growing the model to satisfy a file rather than a user.
    /// `RemoteDesktopFile` still reports the values: reading what the file says
    /// and deciding what to do with it are different jobs.
    public static func machine(from connection: RemoteDesktopFile.Connection) throws -> Imported {
        let host = try validatedHost(connection.host)
        return Imported(
            machine: Machine(
                name: name(forHost: host),
                host: host,
                port: connection.port,
                proto: .rdp,
                // `.rdp` files do not describe their transport: RDP negotiates
                // its own TLS inside the connection, so there is nothing here
                // to map onto `TransportSecurity` and claiming otherwise would
                // be inventing a fact the file does not state.
                security: .none,
                credentialRef: nil,
                username: connection.username,
                tags: ["importé"]
            ),
            // Never carried. The blob in the file is encrypted to the machine
            // that wrote it and is not read at all — see `RemoteDesktopFile`.
            password: nil
        )
    }

    /// Which of the two readers a file's *contents* call for.
    ///
    /// Deliberately not decided by the file's name. These files arrive from
    /// Mail, from AirDrop, from a share sheet — anywhere a name is chosen by
    /// whoever sent the file rather than by the person opening it. Letting the
    /// extension pick the parser would let the sender pick it, and the two
    /// parsers disagree about what a line means. The contents are the one part
    /// of a file that has to be true for the file to work at all.
    public enum Kind: Equatable, Sendable {
        case virtViewer
        case remoteDesktop
    }

    public enum Failure: Error, Equatable {
        /// Neither reader recognises this. Named rather than guessed at: the
        /// alternative is handing arbitrary text to a parser and connecting to
        /// whatever falls out.
        case unrecognisedFile
        /// The bytes are not text in any encoding this reads. Distinct from
        /// `unrecognisedFile`, because it points at a different problem: the
        /// file may well be a connection file, just not one that survived
        /// however it got here.
        case unreadableEncoding
    }

    /// The `[virt-viewer]` section is a header no `.rdp` file has — its lines
    /// are `key:type:value` triples, and that one has no colons at all. So the
    /// section is checked first and settles it on its own.
    static func kind(of text: String) -> Kind? {
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased() == "[virt-viewer]" { return .virtViewer }
        }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let parts = rawLine.trimmingCharacters(in: .whitespaces)
                .split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, !parts[0].isEmpty else { continue }
            if ["s", "i", "b"].contains(parts[1].lowercased()) { return .remoteDesktop }
        }
        return nil
    }

    /// Reads a connection file of either kind.
    ///
    /// A parse failure from the reader that was chosen is passed through rather
    /// than flattened into `unrecognisedFile`: once the contents say which kind
    /// of file this is, "the port is not a number" is a far more useful thing
    /// to show someone than "unrecognised".
    public static func machine(fromContentsOf text: String) throws -> Imported {
        switch kind(of: text) {
        case .virtViewer:
            return try machine(from: try VirtViewerFile.parse(text))
        case .remoteDesktop:
            return try machine(from: try RemoteDesktopFile.parse(text))
        case nil:
            throw Failure.unrecognisedFile
        }
    }

    // MARK: - Bytes

    /// Decodes a connection file's bytes into text.
    ///
    /// Not a call to `String(data:encoding: .utf8)`, because the commonest
    /// `.rdp` file in existence is not UTF-8: Windows' own Remote Desktop
    /// client saves them as UTF-16 little-endian with a byte order mark. Read
    /// as UTF-8 those bytes either fail outright or come back as text with a
    /// NUL between every character, and every line fails to parse. A reader
    /// that cannot open the files the dominant tool writes is not a reader.
    ///
    /// The byte order mark is what decides, when there is one, because it is
    /// the file stating its own encoding. Without one, UTF-8 is assumed —
    /// which is right for the `.vv` files, and for the `.rdp` files written by
    /// everything that is not Windows.
    static func text(from data: Data) -> String? {
        let bytes = [UInt8](data)

        if bytes.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        // No branch for the UTF-8 mark, which Notepad writes and which would
        // otherwise become an invisible first character of the first key. One
        // was written here, and it turned out to be dead code: Foundation
        // strips a leading UTF-8 mark itself while decoding. The branch was
        // removed rather than kept "just in case", because a line no test can
        // tell the presence of is a line whose comment nobody can check. The
        // behaviour it was there for is still asserted — see the tests, on
        // Linux and again in the simulator, since this rests on Foundation
        // doing the same thing on both.
        return String(data: data, encoding: .utf8)
    }

    /// Reads a connection file as it arrives — bytes from a document picker, a
    /// mail attachment, a share sheet.
    public static func machine(fromContentsOf data: Data) throws -> Imported {
        guard let text = text(from: data) else { throw Failure.unreadableEncoding }
        return try machine(fromContentsOf: text)
    }

    // MARK: - Saying what went wrong

    /// A sentence for the person holding the phone.
    ///
    /// Here rather than in the view, because these sentences are the readers'
    /// errors put into words, and the readers are here. A view that wrote them
    /// would have to know which failures exist — and would silently stop
    /// covering them the day a new one is added.
    ///
    /// Every message names the file, not the app: the user did not do anything
    /// wrong by opening it, and there is usually nothing they can fix. What
    /// they need is enough to tell whether to look for a different file or ask
    /// whoever sent it for a new one.
    public static func message(for error: Error) -> String {
        switch error {
        case Failure.unrecognisedFile:
            return "Ce fichier n'est ni un fichier .vv ni un fichier .rdp."
        case Failure.unreadableEncoding:
            return "Ce fichier n'est pas du texte lisible."

        case VirtViewerFile.Failure.notAVirtViewerFile:
            return "Ce fichier .vv n'a pas de section [virt-viewer]."
        case VirtViewerFile.Failure.missingHost:
            return "Ce fichier ne dit pas à quelle machine se connecter."
        case VirtViewerFile.Failure.missingPort:
            return "Ce fichier ne dit pas sur quel port se connecter."
        case let VirtViewerFile.Failure.badPort(value):
            return "« \(value) » n'est pas un port."
        case let VirtViewerFile.Failure.unsupportedProtocol(name):
            return "wisq ne parle pas le protocole « \(name) »."

        case RemoteDesktopFile.Failure.notARemoteDesktopFile:
            return "Ce fichier .rdp ne contient aucun réglage lisible."
        case RemoteDesktopFile.Failure.missingAddress:
            return "Ce fichier ne dit pas à quelle machine se connecter."
        case let RemoteDesktopFile.Failure.badPort(value):
            return "« \(value) » n'est pas un port."
        case let RemoteDesktopFile.Failure.badInteger(key, value):
            return "Le réglage « \(key) » attend un nombre, et vaut « \(value) »."

        default:
            // A file-system error from reading the file itself, most often.
            // Its own text is better than anything invented here.
            return error.localizedDescription
        }
    }
}

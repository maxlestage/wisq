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

    public static func machine(from connection: VirtViewerFile.Connection) -> Imported {
        Imported(
            machine: Machine(
                name: name(forHost: connection.host),
                host: connection.host,
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
    public static func machine(from connection: RemoteDesktopFile.Connection) -> Imported {
        Imported(
            machine: Machine(
                name: name(forHost: connection.host),
                host: connection.host,
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

}

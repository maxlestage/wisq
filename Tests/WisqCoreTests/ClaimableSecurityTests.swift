import XCTest

@testable import WisqCore

/// A machine must not claim a protection it does not have.
///
/// A `.vv` naming both a `tls-port` and a `host-subject` asks for a pinned
/// connection, and `VirtViewerFile` faithfully reports `.tlsPinned`. The
/// subject is the whole of the pin — and `Machine` has nowhere to put it. The
/// import used to record `.tlsPinned` anyway, so the machine list showed
/// "TLS épinglé" for a connection that `ResolvedTransportSecurity` resolves to
/// ordinary system-validated TLS.
final class ClaimableSecurityTests: XCTestCase {
    private func vv(_ lines: String) throws -> VirtViewerFile.Connection {
        try VirtViewerFile.parse("[virt-viewer]\ntype=spice\nhost=console.exemple.net\n" + lines)
    }

    // MARK: - What is recorded

    func testAPinnedFileIsSavedAsPlainTLSBecauseTheSubjectCannotBeCarried() throws {
        let parsed = try vv("tls-port=5901\nhost-subject=O=Exemple,CN=console.exemple.net")
        XCTAssertEqual(parsed.security, .tlsPinned, "le lecteur rapporte fidèlement ce que dit le fichier")
        XCTAssertNotNil(parsed.hostSubject)

        let machine = try ConnectionImport.machine(from: parsed).machine
        XCTAssertEqual(
            machine.security, .tls,
            "enregistrer .tlsPinned serait promettre un épinglage que rien ne tient")
    }

    /// The other edge, twice over: the two modes wisq *can* honour go through
    /// untouched. A rule that flattened everything to `.tls` would silently
    /// encrypt a connection the file said was plain, and one that flattened to
    /// `.none` would do worse.
    func testATLSFileIsStillTLS() throws {
        XCTAssertEqual(try ConnectionImport.machine(from: try vv("tls-port=5901")).machine.security, .tls)
    }

    func testAPlainFileIsStillPlain() throws {
        XCTAssertEqual(try ConnectionImport.machine(from: try vv("port=5900")).machine.security, .none)
    }

    func testClaimableSecurityLeavesTheHonourableModesAlone() {
        XCTAssertEqual(ConnectionImport.claimableSecurity(.none), TransportSecurity.none)
        XCTAssertEqual(ConnectionImport.claimableSecurity(.tls), .tls)
        XCTAssertEqual(ConnectionImport.claimableSecurity(.tlsPinned), .tls)
    }

    // MARK: - What is shown

    /// The picker names the mode; what a machine *gets* from the mode is
    /// `Machine.transportDescription`, and that one must not promise a pin
    /// the machine has nothing to pin to. `MachineFingerprintTests` holds the
    /// per-machine words; this holds the import's half: a `.vv` that asked
    /// for a pin lands as a machine that says "TLS" and nothing more.
    func testTheImportedMachineDoesNotPromiseAPinThatIsNotThere() throws {
        let parsed = try vv("tls-port=5901\nhost-subject=O=Exemple,CN=console.exemple.net")
        let machine = try ConnectionImport.machine(from: parsed).machine
        XCTAssertNil(machine.certificateFingerprint, "un sujet n'est pas une empreinte")
        XCTAssertFalse(machine.pinsCertificate)
        XCTAssertEqual(machine.transportDescription, "TLS")
        XCTAssertTrue(TransportSecurity.tlsPinned.displayName.contains("TLS"))
    }

    /// And the two labels stay distinguishable, or the picker offers two rows
    /// nobody can tell apart.
    func testTheThreeModesStillReadDifferently() {
        let names = Set(TransportSecurity.allCases.map(\.displayName))
        XCTAssertEqual(names.count, TransportSecurity.allCases.count)
    }
}

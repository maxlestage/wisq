import XCTest
@testable import WisqCore

/// `proxy=` and `ca=` in a `.vv` file, and what the import does with a
/// Proxmox ticket: see `VirtViewerFile.Proxy` and
/// `ConnectionImport.requiresItsProxy`.
final class VirtViewerProxyTests: XCTestCase {
    /// The shape Proxmox VE hands out, ticket and signature shortened.
    static let proxmox = """
        [virt-viewer]
        secure-attention=Ctrl+Alt+Ins
        type=spice
        delete-this-file=1
        proxy=http://192.168.1.2:3128
        tls-port=61000
        host-subject=OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve.local
        password=ticket
        host=pvespiceproxy:6536a1b2:100:pve::0123abcd
        ca=-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----\\n
        title=VM 100 - debian
        """

    func testTheProxyAndTheAuthorityAreRead() throws {
        let connection = try VirtViewerFile.parse(Self.proxmox)
        XCTAssertEqual(connection.proxy, VirtViewerFile.Proxy(host: "192.168.1.2", port: 3128))
        XCTAssertEqual(connection.certificateAuthority,
                       "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n")
        XCTAssertFalse(connection.description.contains("ticket"), "the password stays out of descriptions")
        XCTAssertTrue(connection.description.contains("proxy: 192.168.1.2:3128"))
    }

    func testProxyForms() throws {
        XCTAssertEqual(try VirtViewerFile.Proxy.parse("http://pve:3128"), .init(host: "pve", port: 3128))
        XCTAssertEqual(try VirtViewerFile.Proxy.parse("HTTP://pve:8080/"), .init(host: "pve", port: 8080))
        XCTAssertEqual(try VirtViewerFile.Proxy.parse("pve:3128"), .init(host: "pve", port: 3128))
        XCTAssertEqual(try VirtViewerFile.Proxy.parse("http://pve"), .init(host: "pve", port: 3128))
        XCTAssertThrowsError(try VirtViewerFile.Proxy.parse("socks5://pve:1080")) {
            XCTAssertEqual($0 as? VirtViewerFile.Failure, .unsupportedProxy("socks5://pve:1080"))
        }
        XCTAssertThrowsError(try VirtViewerFile.Proxy.parse("http://pve:99999")) {
            XCTAssertEqual($0 as? VirtViewerFile.Failure, .badPort("99999"))
        }
        XCTAssertThrowsError(try VirtViewerFile.Proxy.parse("http://:3128"))
        XCTAssertThrowsError(try VirtViewerFile.Proxy.parse("http://pve:3128/path"))
    }

    /// **A Proxmox ticket is refused at import**, with a sentence that names
    /// the proxy, rather than becoming a machine that fails later on a name
    /// nothing resolves.
    func testAProxmoxTicketIsRefusedWithItsReason() throws {
        let connection = try VirtViewerFile.parse(Self.proxmox)
        XCTAssertThrowsError(try ConnectionImport.machine(from: connection)) { error in
            XCTAssertEqual(error as? ConnectionImport.Failure,
                           .needsSpiceProxy(.init(host: "192.168.1.2", port: 3128)))
            let message = ConnectionImport.message(for: error)
            XCTAssertTrue(message.contains("Proxmox"), message)
            XCTAssertTrue(message.contains("192.168.1.2"), message)
            XCTAssertTrue(message.contains("3128"), message)
        }
    }

    /// An oVirt file names a proxy beside a host that is reachable directly:
    /// it imports as before.
    func testAProxyBesideARealHostStillImports() throws {
        let ovirt = """
            [virt-viewer]
            type=spice
            host=10.0.0.20
            port=5900
            proxy=http://ovirt-engine:3128
            """
        let imported = try ConnectionImport.machine(from: try VirtViewerFile.parse(ovirt))
        XCTAssertEqual(imported.machine.host, "10.0.0.20")
        XCTAssertEqual(imported.machine.port, 5900)
    }

    /// A malformed proxy is a refusal, never a silent direct connection.
    func testAMalformedProxyRefusesTheFile() {
        let text = "[virt-viewer]\ntype=spice\nhost=10.0.0.20\nport=5900\nproxy=ftp://x:21\n"
        XCTAssertThrowsError(try VirtViewerFile.parse(text)) {
            XCTAssertEqual($0 as? VirtViewerFile.Failure, .unsupportedProxy("ftp://x:21"))
            XCTAssertEqual(ConnectionImport.message(for: $0), "« ftp://x:21 » n'est pas un proxy HTTP.")
        }
    }
}

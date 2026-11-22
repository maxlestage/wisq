import Foundation
import WisqVM
@testable import WisqVMRust
import XCTest

/// **La plateforme d'une image d'installation, dite avant de la démarrer.**
///
/// Le fichier ISO ne la dit nulle part : c'est le noyau qu'il porte qui la
/// dit. `IsoBoot.announcedKernel` le sort, le lit et l'efface ; l'annonce
/// (`BootAnnouncement`) en fait la phrase que la feuille montre.
final class IsoAnnouncementTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-annonce-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Un noyau `Image` d'ARM64 : soixante-quatre octets d'en-tête, « ARMd »
    /// au cinquante-sixième.
    private static var arm64Kernel: Data {
        var bytes = [UInt8](repeating: 0, count: 3000)
        bytes.replaceSubrange(0x38..<0x3C, with: [0x41, 0x52, 0x4D, 0x64])
        return Data(bytes)
    }

    func testAnArm64ImageIsNamedAndRefusedBeforeAnythingStarts() throws {
        var gravure = IsoGravure()
        gravure.kernel = Self.arm64Kernel
        gravure.recipeKernel = "/boot/vmlinuz-virt"
        let image = try gravure.write()
        defer { try? FileManager.default.removeItem(at: image) }

        let inner = try XCTUnwrap(IsoBoot.announcedKernel(of: image, scratch: scratch, ceiling: 1 << 20))
        XCTAssertEqual(inner.kind.architecture, GuestArchitecture(.arm, bits: 64))
        XCTAssertEqual(inner.path, "/boot/vmlinuz-virt")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [],
                       "le noyau sorti pour l'annonce est resté")

        let said = BootAnnouncement.make(
            fileName: "alpine-standard-aarch64.iso", kind: KernelImageKind.identify(fileAt: image),
            inner: inner.kind, innerPath: inner.path,
            host: HostPlatform(architecture: GuestArchitecture(.arm, bits: 64), system: "iOS 18.2", model: nil))
        XCTAssertEqual(said.guestName, "ARM64")
        XCTAssertEqual(said.evidence, .insideImage(container: "ISO 9660", format: "Image ARM64"))
        XCTAssertFalse(said.outcome.startsSomething)
        XCTAssertEqual(said.title, "ARM64 sur ARM64")
    }

    /// Un noyau que rien ne reconnaît laisse l'annonce aux noms : celui de
    /// l'image, ici, dit x86.
    func testAnUnreadableKernelFallsBackToTheName() throws {
        let image = try IsoGravure().write()
        defer { try? FileManager.default.removeItem(at: image) }
        let inner = IsoBoot.announcedKernel(of: image, scratch: scratch, ceiling: 1 << 20)
        let said = BootAnnouncement.make(
            fileName: "omarchy-4.5.0-x86.iso", kind: .discImage("ISO 9660"),
            inner: inner?.kind, innerPath: inner?.path)
        XCTAssertEqual(said.evidence, .nameHint("x86"))
        XCTAssertEqual(said.outcome, .runs(.x86_64))

        XCTAssertNil(IsoBoot.announcedKernel(
            of: image, scratch: scratch, ceiling: UInt64(IsoGravure.kernel.count - 1)),
            "un noyau plus gros que le plafond ne s'annonce pas")
    }
}

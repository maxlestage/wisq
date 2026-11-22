import Foundation
@testable import WisqVM
import XCTest

/// **L'annonce d'avant le démarrage** : la plateforme de l'image, celle du
/// téléphone, et ce qui va se passer — pour chaque genre de fichier.
final class BootAnnouncementTests: XCTestCase {
    private let phone = HostPlatform(
        architecture: GuestArchitecture(.arm, bits: 64), system: "iOS 18.2", model: "iPhone16,2")

    private func kernel(_ architecture: GuestArchitecture, _ format: String) -> KernelImageKind {
        .linuxKernel(KernelImage(architecture, format: format))
    }

    func testAPCKernelIsInterpretedOnTheArmPhone() {
        let said = BootAnnouncement.make(
            fileName: "bzImage", kind: kernel(GuestArchitecture(.x86, bits: 64), "bzImage"), host: phone)
        XCTAssertEqual(said.title, "x86-64 sur ARM64")
        XCTAssertEqual(said.outcome, .runs(.x86_64))
        XCTAssertEqual(said.evidence, .header(format: "bzImage"))
        XCTAssertTrue(said.executionText.contains("interprétée"), said.executionText)
        XCTAssertTrue(said.executionText.contains("ARM64"), said.executionText)
    }

    func testARiscVKernelRunsOnItsCore() {
        let said = BootAnnouncement.make(
            fileName: "Image", kind: kernel(GuestArchitecture(.riscv), "Image RISC-V"), host: phone)
        XCTAssertEqual(said.outcome, .runs(.riscv32))
    }

    /// **ARM est nommé, et le refus dit quoi faire** — avant qu'une console
    /// s'ouvre, et sans parler de mémoire.
    func testArmKernelsAreNamedAndRefusedWithAWayForward() {
        for (architecture, format) in [(GuestArchitecture(.arm, bits: 64), "Image ARM64"),
                                       (GuestArchitecture(.arm, bits: 32), "zImage ARM")] {
            let said = BootAnnouncement.make(fileName: "noyau", kind: kernel(architecture, format), host: phone)
            XCTAssertEqual(said.guest, architecture)
            guard case .refused(let reason) = said.outcome else { return XCTFail("\(format) démarrerait") }
            XCTAssertTrue(reason.contains("connexion à distance"), reason)
            XCTAssertFalse(reason.contains("mémoire"), reason)
        }
    }

    /// Une image d'installation dont le noyau n'a pas été lu : le chemin du
    /// noyau, puis le nom, donnent un **indice**, présenté comme tel.
    func testADiscImageFallsBackToNameHints() {
        let arm = BootAnnouncement.make(
            fileName: "debian.iso", kind: .discImage("ISO 9660"),
            innerPath: "/install.a64/aarch64/vmlinuz", host: phone)
        XCTAssertEqual(arm.evidence, .nameHint("aarch64"))
        XCTAssertFalse(arm.outcome.startsSomething)
        XCTAssertTrue(arm.evidenceText.contains("n'a pas été lu"))

        let omarchy = BootAnnouncement.make(
            fileName: "omarchy-4.5.0-x86.iso", kind: .discImage("ISO 9660"),
            innerPath: "/arch/boot/x86_64/vmlinuz-linux-omarchy", host: phone)
        XCTAssertEqual(omarchy.evidence, .nameHint("x86_64"))
        XCTAssertEqual(omarchy.guest, GuestArchitecture(.x86, bits: 64))
        XCTAssertEqual(omarchy.outcome, .runs(.x86_64))

        let silent = BootAnnouncement.make(fileName: "image.iso", kind: .discImage("ISO 9660"), host: phone)
        XCTAssertEqual(silent.guestName, "inconnue")
        XCTAssertEqual(silent.outcome, .tries(.x86_64))
    }

    func testCloudImagesRunOnThePCUnlessTheirNameSaysOtherwise() {
        let debian = BootAnnouncement.make(
            fileName: "debian-12-genericcloud-amd64.qcow2", kind: .virtualDisk("qcow2"), cloudImage: true,
            host: phone)
        XCTAssertEqual(debian.outcome, .runs(.x86_64))
        XCTAssertEqual(debian.evidence, .nameHint("amd64"))

        let arm = BootAnnouncement.make(
            fileName: "debian-12-genericcloud-arm64.qcow2", kind: .virtualDisk("qcow2"), cloudImage: true,
            host: phone)
        XCTAssertFalse(arm.outcome.startsSomething)
        XCTAssertEqual(arm.guestName, "ARM64")
    }

    func testUnknownFilesAreTriedAndDiskImagesExplained() {
        let unknown = BootAnnouncement.make(fileName: "truc", kind: .unknown, host: phone)
        XCTAssertEqual(unknown.outcome, .tries(.riscv32))
        let disk = BootAnnouncement.make(fileName: "rootfs.ext4", kind: .filesystemImage("ext4"), host: phone)
        XCTAssertFalse(disk.outcome.startsSomething)
    }

    func testNameHintsPreferThePreciseWord() {
        XCTAssertEqual(GuestArchitecture.hinted(by: "/boot/x86_64/vmlinuz")?.1, "x86_64")
        XCTAssertEqual(GuestArchitecture.hinted(by: "ARM64.iso")?.0, GuestArchitecture(.arm, bits: 64))
        XCTAssertEqual(GuestArchitecture.hinted(by: "slackware-i686.iso")?.0, GuestArchitecture(.x86, bits: 32))
        XCTAssertNil(GuestArchitecture.hinted(by: "alpine.iso"))
    }

    func testTheHostIsTheCompiledProcessor() {
        XCTAssertEqual(HostPlatform.current.architecture, HostPlatform.compiledArchitecture)
        XCTAssertEqual(phone.summary, "ARM64 · iOS 18.2 · iPhone16,2")
    }
}

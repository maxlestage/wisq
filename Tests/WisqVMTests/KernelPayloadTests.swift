import Foundation
import WisqVM
import XCTest

/// **Le `vmlinux` qu'un `bzImage` porte**, tel que la machine de l'émetteur le
/// pose. Des `bzImage` fabriqués ici, à l'en-tête près, autour d'un ELF de
/// quelques octets : gzip (un bloc stocké, la somme et la taille au bout) et
/// zstd (un bloc brut, la taille du noyau après), et ce qui doit être refusé.
/// Un vrai noyau, quand on en donne un (`WISQ_EMITTER_VMLINUZ`), comparé à sa
/// charge décompressée par Python (`WISQ_EMITTER_VMLINUX`).
final class KernelPayloadTests: XCTestCase {
    /// Un ELF d'un en-tête et de quelques octets : assez pour être reconnu.
    static let elf: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0] + [UInt8](repeating: 0xAB, count: 300)

    /// Un membre gzip d'un seul bloc stocké.
    static func gzip(_ data: [UInt8], crc: UInt32? = nil, size: UInt32? = nil, name: String? = nil) -> [UInt8] {
        var out: [UInt8] = [0x1F, 0x8B, 8, name == nil ? 0 : 0x08, 0, 0, 0, 0, 0, 3]
        if let name { out += Array(name.utf8) + [0] }
        let length = UInt16(data.count)
        out += [1, UInt8(length & 0xFF), UInt8(length >> 8), UInt8(~length & 0xFF), UInt8(~length >> 8)]
        out += data
        out += le32(crc ?? CRC32.checksum(data))
        out += le32(size ?? UInt32(data.count))
        return out
    }

    /// Une trame zstd d'un seul bloc brut, et la taille que le noyau ajoute.
    /// La taille du contenu sur deux octets (`FCS_flag` à 1, moins 256), en
    /// un seul segment.
    static func zstd(_ data: [UInt8]) -> [UInt8] {
        precondition(data.count >= 256 && data.count < 65536 + 256)
        let fcs = data.count - 256
        var out: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD, 0x60, UInt8(fcs & 0xFF), UInt8(fcs >> 8)]
        let header = UInt32(1) | UInt32(data.count) << 3
        out += [UInt8(header & 0xFF), UInt8((header >> 8) & 0xFF), UInt8((header >> 16) & 0xFF)]
        out += data
        return out + le32(UInt32(data.count))
    }

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)]
    }

    /// **Un `bzImage`** : un secteur d'amorçage et un de setup, puis le code
    /// en mode protégé — seize octets de talon, puis la charge utile.
    static func bzImage(_ payload: [UInt8], version: UInt16 = 0x020F, offset: Int? = nil, length: Int? = nil) -> [UInt8] {
        var setup = [UInt8](repeating: 0, count: 1024)
        setup[0x1F1] = 1
        let protected = 16 + payload.count
        let paragraphs = UInt32((protected + 15) / 16)
        setup.replaceSubrange(0x1F4..<0x1F8, with: le32(paragraphs))
        setup[0x1FE] = 0x55
        setup[0x1FF] = 0xAA
        setup.replaceSubrange(0x202..<0x206, with: Array("HdrS".utf8))
        setup[0x206] = UInt8(version & 0xFF)
        setup[0x207] = UInt8(version >> 8)
        setup.replaceSubrange(0x248..<0x24C, with: le32(UInt32(offset ?? 16)))
        setup.replaceSubrange(0x24C..<0x250, with: le32(UInt32(length ?? payload.count)))
        var image = setup + [UInt8](repeating: 0x90, count: 16) + payload
        image += [UInt8](repeating: 0, count: Int(paragraphs) * 16 - protected)
        return image
    }

    func testAnELFIsReturnedAsIs() throws {
        XCTAssertEqual(try KernelPayload.elf(from: Self.elf), Self.elf)
    }

    func testAGzipPayloadIsInflatedToItsELF() throws {
        XCTAssertEqual(try KernelPayload.elf(from: Self.bzImage(Self.gzip(Self.elf))), Self.elf)
        // Un nom de fichier dans l'en-tête, que le lecteur doit sauter.
        XCTAssertEqual(
            try KernelPayload.elf(from: Self.bzImage(Self.gzip(Self.elf, name: "vmlinux.bin"))), Self.elf)
    }

    func testAZstdPayloadLosesTheSizeTheKernelAppends() throws {
        XCTAssertEqual(try KernelPayload.elf(from: Self.bzImage(Self.zstd(Self.elf))), Self.elf)
    }

    func testADamagedGzipIsRefusedNotGuessed() {
        XCTAssertThrowsError(try KernelPayload.elf(from: Self.bzImage(Self.gzip(Self.elf, crc: 1)))) {
            XCTAssertEqual($0 as? KernelPayload.Refusal, .corrupt("gzip : la somme ne tombe pas juste"))
        }
        XCTAssertThrowsError(try KernelPayload.elf(from: Self.bzImage(Self.gzip(Self.elf, size: 400)))) {
            guard case .corrupt? = $0 as? KernelPayload.Refusal else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(
            try KernelPayload.elf(from: Self.bzImage(Self.gzip(Self.elf, size: 1 << 30)), limit: 1 << 20)
        ) {
            XCTAssertEqual($0 as? KernelPayload.Refusal, .tooLarge(1 << 30))
        }
    }

    func testWhatIsNotReadIsRefusedByName() {
        let refusals: [([UInt8], KernelPayload.Refusal)] = [
            ([UInt8](repeating: 0, count: 4096), .notAKernel),
            (Self.bzImage(Self.gzip(Self.elf), version: 0x0206), .protocolTooOld(0x0206)),
            (Self.bzImage(Self.gzip(Self.elf), length: 1 << 20), .payloadOutsideTheFile),
            (Self.bzImage([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00, 1, 2]), .unsupportedCompression("xz")),
            (Self.bzImage([1, 2, 3, 4, 5, 6]), .unsupportedCompression("inconnue")),
            (Self.bzImage(Self.gzip([UInt8](repeating: 7, count: 64))), .notAnELF),
        ]
        for (image, expected) in refusals {
            XCTAssertThrowsError(try KernelPayload.elf(from: image)) {
                XCTAssertEqual($0 as? KernelPayload.Refusal, expected)
            }
        }
    }

    /// **Un vrai noyau**, quand on en donne un : le `vmlinuz-virt` d'Alpine,
    /// et sa charge décompressée par Python (`docs/JOURNAL.md`, 21 novembre).
    func testARealKernelInflatesToThePayloadPythonFound() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let vmlinuz = environment["WISQ_EMITTER_VMLINUZ"],
              let vmlinux = environment["WISQ_EMITTER_VMLINUX"]
        else {
            throw XCTSkip("WISQ_EMITTER_VMLINUZ et WISQ_EMITTER_VMLINUX absents : pas de vrai noyau à décompresser")
        }
        let image = [UInt8](try Data(contentsOf: URL(fileURLWithPath: vmlinuz)))
        let expected = [UInt8](try Data(contentsOf: URL(fileURLWithPath: vmlinux)))
        let start = Date()
        let elf = try KernelPayload.elf(from: image)
        print("KernelPayload : \(image.count) → \(elf.count) octets en \(Date().timeIntervalSince(start)) s")
        XCTAssertEqual(elf.count, expected.count)
        XCTAssertTrue(elf == expected, "octet pour octet")
    }
}

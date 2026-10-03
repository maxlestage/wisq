import Foundation
import WisqVMRust
import XCTest

/// **Ce que le pont Swift lit d'un noyau ELF.**
///
/// `kernel_image::loads` existe depuis #304 et le montage de mesure s'en sert
/// pour démarrer un vrai noyau Alpine. **Rien ne l'exposait au-delà de la
/// frontière C**, donc l'application n'avait aucun moyen d'apprendre où poser
/// une image ni par où l'exécution commence — et `LocalDesktop(entry:)` comme
/// `place(_:at:)` exigent que l'appelant le sache déjà. C'est la même famille
/// que #310, #311 et #313 : le montage l'a, le bureau ne l'a pas.
///
/// **Ce que ces tests ne jugent pas** : le lecteur lui-même, qui est tenu par
/// `crates/wisq-vm/tests/kernel_elf.rs` sur un vrai vmlinux. Ici c'est la
/// **traversée** — deux appels, un tableau alloué entre les deux, et cinq
/// champs dans le bon ordre.
final class RustKernelImageTests: XCTestCase {
    /// Un ELF64 forgé à la main. Trois en-têtes, dont une `PT_NOTE` qu'un
    /// lecteur naïf compterait comme chargeable, et un second segment qui porte
    /// du **BSS** : quatre cents octets qui existent en mémoire et pas dans le
    /// fichier.
    ///
    /// Le fichier est rempli jusqu'à ce que ses en-têtes annoncent, parce que
    /// le lecteur refuse un ELF qui promet plus d'octets qu'il n'en porte.
    private func forge() -> Data {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0...3] = [0x7F, 0x45, 0x4C, 0x46]
        bytes[4] = 2 // ELFCLASS64
        bytes[5] = 1 // petit-boutien
        func write16(_ value: UInt16, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { raw in
                for (index, byte) in raw.enumerated() { bytes[offset + index] = byte }
            }
        }
        func write64(_ value: UInt64, into target: inout [UInt8], at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { raw in
                for (index, byte) in raw.enumerated() { target[offset + index] = byte }
            }
        }
        write16(2, at: 16) // ET_EXEC
        write16(62, at: 18) // EM_X86_64
        write64(0x0100_0090, into: &bytes, at: 24) // e_entry
        write64(64, into: &bytes, at: 32) // e_phoff
        write16(64, at: 52) // e_ehsize
        write16(56, at: 54) // e_phentsize
        write16(3, at: 56) // e_phnum

        let headers: [(UInt32, UInt64, UInt64, UInt64, UInt64, UInt64)] = [
            (1, 0x1000, 0xFFFF_FFFF_8100_0000, 0x0100_0000, 1000, 1000),
            (4, 0x2000, 0, 0, 32, 32), // PT_NOTE
            (1, 0x3000, 0xFFFF_FFFF_8240_0000, 0x0240_0000, 500, 900),
        ]
        for (kind, offset, virtual, physical, file, memory) in headers {
            var header = [UInt8](repeating: 0, count: 56)
            withUnsafeBytes(of: kind.littleEndian) { raw in
                for (index, byte) in raw.enumerated() { header[index] = byte }
            }
            write64(offset, into: &header, at: 8)
            write64(virtual, into: &header, at: 16)
            write64(physical, into: &header, at: 24)
            write64(file, into: &header, at: 32)
            write64(memory, into: &header, at: 40)
            bytes.append(contentsOf: header)
        }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 0x3000 + 500 - bytes.count))
        return Data(bytes)
    }

    func testTheBridgeReadsAnELFsEntryPointAndItsLoadableSegments() throws {
        let read = try XCTUnwrap(RustKernelImage.loads(forge()))
        XCTAssertEqual(read.entry, 0x0100_0090, "le point d'entrée traverse")
        XCTAssertEqual(
            read.segments.count, 2,
            "deux segments chargeables : la PT_NOTE n'en est pas un"
        )

        // **Les cinq champs, pas trois.** Une transposition de `virtualAddress`
        // et `physicalAddress` passerait toute assertion qui ne regarde que
        // l'un des deux — et un chargeur poserait le noyau à l'adresse à
        // laquelle il a été *lié* au lieu de celle où on le *pose*. Pour un
        // x86-64 les deux diffèrent de `__START_KERNEL_map` : rien ne
        // démarrerait.
        XCTAssertEqual(read.segments[0].offset, 0x1000)
        XCTAssertEqual(read.segments[0].virtualAddress, 0xFFFF_FFFF_8100_0000)
        XCTAssertEqual(read.segments[0].physicalAddress, 0x0100_0000)
        XCTAssertEqual(read.segments[0].fileSize, 1000)
        XCTAssertEqual(read.segments[0].memorySize, 1000)

        // **Et le BSS**, qui est la distinction qui coûte cher : quatre cents
        // octets qui existent en mémoire et pas dans le fichier. Confondre les
        // deux tailles fait lire hors du fichier, ou laisser un trou là où le
        // noyau attend des zéros.
        XCTAssertEqual(read.segments[1].fileSize, 500)
        XCTAssertEqual(read.segments[1].memorySize, 900)
        XCTAssertEqual(
            read.segments[1].memorySize - read.segments[1].fileSize, 400,
            "quatre cents octets de BSS, que le chargeur doit mettre à zéro"
        )
    }

    /// **Ce qui n'est pas un ELF64 est refusé, pas deviné.** Un chargeur qui
    /// accepterait un `bzImage` ici lirait ses en-têtes de programme dans du
    /// code 16 bits, et poserait le noyau n'importe où.
    func testSomethingThatIsNotAnELFIsRefused() {
        XCTAssertNil(RustKernelImage.loads(Data("MZ\u{90}\u{0}".utf8)))
        XCTAssertNil(RustKernelImage.loads(Data()))
        XCTAssertNil(RustKernelImage.loads(Data(repeating: 0, count: 64)))
    }

    /// **Un ELF sans aucun segment chargeable n'est pas un noyau.**
    ///
    /// Il se lit sans erreur — le magique est bon, la classe est bonne — et il
    /// ne porte rien à poser. Le rendre comme un succès ferait démarrer une
    /// machine sur de la mémoire vide, et le symptôme serait un arrêt très loin
    /// de sa cause. C'est le `count > 0` du pont, et sans ce test il serait une
    /// garde que rien n'exerce.
    func testAnELFWithNothingToLoadIsNotAKernel() {
        // Le même ELF, mais dont la seule en-tête est une PT_NOTE.
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes[0...3] = [0x7F, 0x45, 0x4C, 0x46]
        bytes[4] = 2
        bytes[5] = 1
        func write16(_ value: UInt16, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { raw in
                for (index, byte) in raw.enumerated() { bytes[offset + index] = byte }
            }
        }
        write16(2, at: 16)
        write16(62, at: 18)
        write16(64, at: 52)
        write16(56, at: 54)
        write16(1, at: 56)
        bytes[32] = 64 // e_phoff
        var header = [UInt8](repeating: 0, count: 56)
        header[0] = 4 // PT_NOTE
        bytes.append(contentsOf: header)
        XCTAssertNil(
            RustKernelImage.loads(Data(bytes)),
            "un ELF sans segment chargeable n'a rien à démarrer"
        )
    }

    /// **Un ELF qui promet plus d'octets qu'il n'en porte est refusé.**
    ///
    /// C'est le cas réel d'un téléchargement coupé : les en-têtes sont intacts,
    /// le fichier ne l'est pas. L'accepter ferait poser des octets lus hors du
    /// fichier — en Rust, un panic ; pire, un chargeur plus naïf poserait de la
    /// mémoire voisine et la machine démarrerait sur autre chose.
    func testAnELFThatPromisesMoreBytesThanItCarriesIsRefused() {
        var truncated = forge()
        truncated = truncated.prefix(0x3000 + 100)
        XCTAssertNil(
            RustKernelImage.loads(truncated),
            "un ELF coupé après ses en-têtes n'est pas chargeable"
        )
    }
}

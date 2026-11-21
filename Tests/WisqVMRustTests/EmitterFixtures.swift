import Foundation

/// **Le petit noyau des tests de la machine de l'émetteur**, celui de
/// `crates/wisq-vm/tests/kernel_entry.rs` : un ELF d'un segment chargé à
/// seize mébioctets, qui dit « W » sur le port série, relève CS et DS, lit
/// l'horloge CMOS et l'identifiant PCI de 00:03.0 (le disque), pagine pour atteindre la mémoire vidéo de la carte (une
/// page de 1 Gio sur `0xC000_0000`), y peint un pixel rouge et un bleu,
/// attend une touche par l'i8042, et s'arrête sur `hlt`.
enum EmitterFixtures {
    static let physical: UInt64 = 0x0100_0000

    static func le16(_ value: UInt16) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
    static func le32(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
    static func le64(_ value: UInt64) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }

    /// Un ELF64 d'un seul segment chargeable, à `physical`, le point d'entrée
    /// à son premier octet ; `bss` octets de plus en mémoire qu'en fichier.
    static func elf(_ code: [UInt8], at physical: UInt64 = physical, bss: UInt64 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 64)
        bytes.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
        bytes[4] = 2
        bytes[5] = 1
        bytes.replaceSubrange(16..<18, with: le16(2))
        bytes.replaceSubrange(18..<20, with: le16(62))
        bytes.replaceSubrange(24..<32, with: le64(physical))
        bytes.replaceSubrange(32..<40, with: le64(64))
        bytes.replaceSubrange(52..<54, with: le16(64))
        bytes.replaceSubrange(54..<56, with: le16(56))
        bytes.replaceSubrange(56..<58, with: le16(1))
        var header = [UInt8](repeating: 0, count: 56)
        header.replaceSubrange(0..<4, with: le32(1))
        header.replaceSubrange(8..<16, with: le64(0x1000))
        header.replaceSubrange(16..<24, with: le64(physical &+ 0xFFFF_FFFF_8000_0000))
        header.replaceSubrange(24..<32, with: le64(physical))
        header.replaceSubrange(32..<40, with: le64(UInt64(code.count)))
        header.replaceSubrange(40..<48, with: le64(UInt64(code.count) + bss))
        bytes += header
        bytes += [UInt8](repeating: 0, count: 0x1000 - bytes.count)
        return bytes + code
    }

    private static func rax(_ code: inout [UInt8], _ value: UInt64) {
        code += [0x48, 0xB8] + le64(value)
    }

    private static func put(_ code: inout [UInt8], _ address: UInt64, _ value: UInt64) {
        rax(&code, value)
        code += [0x48, 0xBF] + le64(address)
        code += [0x48, 0x89, 0x07]
    }

    /// Le petit noyau lui-même.
    static func kernel() -> [UInt8] {
        let pml4: UInt64 = 0x10_0000
        let pdpt: UInt64 = 0x10_1000
        var code: [UInt8] = [
            0x66, 0xBA, 0xF8, 0x03, 0xB0, 0x57, 0xEE, // « W » sur le port série
            0x8C, 0xCB, // mov %cs,%ebx
            0x41, 0x8C, 0xD8, // mov %ds,%r8d
            0xB0, 0x00, 0xE6, 0x70, // les secondes
            0xE4, 0x71,
            0x44, 0x0F, 0xB6, 0xE8, // movzbl %al,%r13d
            0xB0, 0x02, 0xE6, 0x70, // les minutes
            0xE4, 0x71,
            0x44, 0x0F, 0xB6, 0xF0, // movzbl %al,%r14d
            // L'identifiant PCI de 00:03.0, le disque quand il y en a un.
            0xB8, 0x00, 0x18, 0x00, 0x80, // mov $0x80001800,%eax
            0x66, 0xBA, 0xF8, 0x0C, 0xEF, // mov $0xcf8,%dx ; out %eax,%dx
            0x66, 0xBA, 0xFC, 0x0C, 0xED, // mov $0xcfc,%dx ; in %dx,%eax
            0x41, 0x89, 0xC1, // mov %eax,%r9d
        ]
        put(&code, pml4, pdpt | 3)
        put(&code, pdpt, 0x83)
        put(&code, pdpt + 3 * 8, 0xC000_0000 | 0x83)
        rax(&code, pml4)
        code += [0x0F, 0x22, 0xD8] // mov %rax,%cr3
        rax(&code, 1 << 31)
        code += [0x0F, 0x22, 0xC0] // mov %rax,%cr0
        rax(&code, 0xE000_0000)
        code += [0xC7, 0x00, 0x00, 0x00, 0xFF, 0x00] // rouge
        code += [0xC7, 0x40, 0x04, 0xFF, 0x00, 0x00, 0x00] // bleu
        code += [
            0xE4, 0x64, // attendre : in $0x64,%al
            0xA8, 0x01, // test $1,%al
            0x74, 0xFA, // jz attendre
            0xE4, 0x60, // in $0x60,%al
            0x44, 0x0F, 0xB6, 0xF8, // movzbl %al,%r15d
            0xFA, 0xF4, // cli ; hlt
        ]
        return code
    }

    /// Un dossier neuf, effacé par l'appelant.
    static func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-emetteur-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

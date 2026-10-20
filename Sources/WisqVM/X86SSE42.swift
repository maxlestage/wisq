import Foundation

// **SSE4.2, et ce que x86-64-v2 demande encore.** La troisième tranche (voir
// `X86SSSE3.swift`) : ce que les binaires d'AlmaLinux 9.8 emploient de
// SSE4.2 — `pcmpistri` (404 fois), `pcmpgtq` (64) ; `crc32`, `pcmpestri` et
// les formes `…m` n'y figurent pas — avec `lahf` et `sahf` en mode long, et
// `cmpxchg16b`.
extension X86Core {
    /// **`PCMPISTRI`**, le comparateur de chaînes de la glibc (`strcspn`,
    /// `strspn`, `strpbrk`, `strcasecmp`…). Chaque opérande s'arrête à son
    /// premier élément nul ; l'immédiat dit le reste :
    /// - bits 1-0 : octets ou mots, sans ou avec signe ;
    /// - bits 3-2 : l'agrégation — égal à l'un des, intervalles, égal un à
    ///   un, sous-chaîne ;
    /// - bits 5-4 : la polarité — telle quelle, niée, ou niée sur les seuls
    ///   éléments valides de la seconde ;
    /// - bit 6 : l'indice compté du bas ou du haut.
    ///
    /// ECX reçoit l'indice du premier bit levé, ou le nombre d'éléments
    /// quand il n'y en a aucun. CF : un bit levé ; ZF : la seconde chaîne
    /// finit dans le registre ; SF : la première aussi ; OF : le bit zéro ;
    /// AF et PF à zéro.
    ///
    /// **Ses trois frères** ne diffèrent que par deux choix : la longueur de
    /// chaque chaîne est donnée dans EAX et EDX (RAX et RDX avec REX.W) au
    /// lieu de s'arrêter au premier nul (`PCMPESTRI`, `PCMPESTRM`), et le
    /// résultat est le masque entier, rangé dans xmm0, au lieu d'un indice
    /// dans ECX (`PCMPISTRM`, `PCMPESTRM`). Le bit 6 de l'immédiat choisit
    /// alors entre les bits seuls, en bas de xmm0, et un élément entier à un
    /// par bit levé. La glibc d'AlmaLinux n'emploie que `PCMPISTRI` ; celle
    /// d'openSUSE emploie `PCMPISTRM`, et s'y arrêtait.
    mutating func compareStrings(
        _ instruction: X86Instruction, _ fields: Fields, _ control: UInt8, explicit: Bool, mask: Bool
    ) throws {
        let read = try readVectorRM(fields, 16)
        let words = control & 1 != 0
        let isSigned = control & 2 != 0
        let count = words ? 8 : 16
        func elements(_ value: (low: UInt64, high: UInt64)) -> [Int] {
            let bytes = Self.bytes(value)
            return (0..<count).map { index in
                if words {
                    let raw = UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8
                    return isSigned ? Int(Int16(bitPattern: raw)) : Int(raw)
                }
                return isSigned ? Int(Int8(bitPattern: bytes[index])) : Int(bytes[index])
            }
        }
        let first = elements(vector(fields.reg)), second = elements((low: read.0, high: read.1))
        let firstLength: Int, secondLength: Int
        if explicit {
            // La valeur absolue, saturée au nombre d'éléments.
            let wide = (instruction.rex ?? 0) & 0x08 != 0
            func length(_ register: Int) -> Int {
                let raw = registers.read(register)
                let value = wide ? Int64(bitPattern: raw) : Int64(Int32(truncatingIfNeeded: raw))
                return value.magnitude >= UInt64(count) ? count : Int(value.magnitude)
            }
            firstLength = length(0)
            secondLength = length(2)
        } else {
            firstLength = first.firstIndex(of: 0) ?? count
            secondLength = second.firstIndex(of: 0) ?? count
        }

        var result = 0
        for j in 0..<count {
            let secondValid = j < secondLength
            var bit: Bool
            switch control >> 2 & 3 {
            case 0:  // égal à l'un des
                bit = secondValid && (0..<firstLength).contains { first[$0] == second[j] }
            case 1:  // intervalles, par paires du premier opérande
                bit = secondValid && stride(from: 0, to: firstLength - 1, by: 2).contains {
                    second[j] >= first[$0] && second[j] <= first[$0 + 1]
                }
            case 2:  // égal un à un ; deux éléments invalides sont égaux
                let firstValid = j < firstLength
                bit = firstValid && secondValid ? first[j] == second[j] : firstValid == secondValid
            default:  // sous-chaîne : le premier opérande commence-t-il ici ?
                bit = true
                for k in 0..<(count - j) {
                    guard k < firstLength else { break }
                    guard j + k < secondLength, first[k] == second[j + k] else {
                        bit = false
                        break
                    }
                }
            }
            if bit { result |= 1 << j }
        }
        let all = (1 << count) - 1
        switch control >> 4 & 3 {
        case 1: result ^= all
        case 3: result ^= (1 << secondLength) - 1
        default: break
        }
        if mask {
            if control & 0x40 == 0 {
                setVector(0, UInt64(result), 0)
            } else {
                var bytes = [UInt8](repeating: 0, count: 16)
                let width = words ? 2 : 1
                for element in 0..<count where result >> element & 1 != 0 {
                    for offset in 0..<width { bytes[element * width + offset] = 0xFF }
                }
                let expanded = Self.pack(bytes)
                setVector(0, expanded.0, expanded.1)
            }
        } else {
            let index: Int
            if result == 0 {
                index = count
            } else if control & 0x40 != 0 {
                index = Int.bitWidth - 1 - result.leadingZeroBitCount
            } else {
                index = result.trailingZeroBitCount
            }
            registers[1] = UInt64(index)
        }
        flags &= ~Flag.arithmetic
        if result != 0 { flags |= Flag.carry }
        if secondLength < count { flags |= Flag.zero }
        if firstLength < count { flags |= Flag.sign }
        if result & 1 != 0 { flags |= Flag.overflow }
    }

    /// **`CRC32`** : la somme de contrôle CRC-32C (polynôme de Castagnoli,
    /// 0x1EDC6F41, bits renversés), sur un, deux, quatre ou huit octets de la
    /// source, accumulée dans les trente-deux bits bas de la destination — le
    /// haut d'un registre de soixante-quatre bits est effacé. Ce n'est pas la
    /// glibc qui l'emploie : c'est le noyau, pour les sommes des métadonnées
    /// d'ext4 et de btrfs, dès que SSE4.2 est annoncé. Debian et Arch
    /// s'arrêtaient dessus.
    mutating func crc32(_ instruction: X86Instruction, _ fields: Fields, byteForm: Bool) throws {
        let size = Self.operandSize(instruction, byteForm: byteForm)
        let data = try readRM(fields, size)
        var crc = UInt32(truncatingIfNeeded: registers.read(fields.reg))
        for index in 0..<size {
            crc ^= UInt32(UInt8(truncatingIfNeeded: data >> (8 * UInt64(index))))
            for _ in 0..<8 { crc = crc & 1 != 0 ? crc >> 1 ^ 0x82F6_3B78 : crc >> 1 }
        }
        registers[fields.reg] = UInt64(crc)
    }

    /// **`CMPXCHG16B`** : RDX:RAX comparé aux seize octets. Égaux, RCX:RBX y
    /// sont rangés et ZF levé ; sinon ce qui s'y trouve est relu dans
    /// RDX:RAX. La case est **écrite dans les deux cas** sur la machine — la
    /// valeur lue y retourne — donc vérifiée inscriptible avant tout.
    mutating func compareExchange16(_ fields: Fields) throws {
        try probeWrite(fields, 16)
        let low = try readMemory(lastAddress, 8), high = try readMemory(lastAddress &+ 8, 8)
        if low == registers.read(0), high == registers.read(2) {
            try writeMemory(lastAddress, 8, registers.read(3))
            try writeMemory(lastAddress &+ 8, 8, registers.read(1))
            flags |= Flag.zero
        } else {
            registers[0] = low
            registers[2] = high
            flags &= ~Flag.zero
        }
    }
}

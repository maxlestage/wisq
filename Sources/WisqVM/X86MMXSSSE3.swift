import Foundation

// **SSSE3 sur les registres MMX** : `0F 38 00` à `0B`, `0F 38 1C` à `1E` et
// `0F 3A 0F` sans préfixe — `PSHUFB`, les horizontales, `PMADDUBSW`,
// `PSIGNB/W/D`, `PMULHRSW`, `PABSB/W/D` et `PALIGNR` sur huit octets.
//
// Sous `66`, ce sont des instructions XMM, écrites dans `X86SSSE3.swift`
// depuis qu'AlmaLinux 9 les demandait. Sans préfixe, ce cœur les refusait :
// depuis #664 le programme mourait d'un « Illegal instruction », et depuis
// que le MMX existe (#665), elles étaient les dernières formes MMX du jeu
// que CPUID annonce.
//
// **Trois ne se déduisent pas de leur forme XMM**, et c'est ce que l'oracle a
// d'abord à dire :
// - `PSHUFB` ne lit que trois bits d'index, pas quatre : sur huit octets,
//   l'index 9 désigne l'octet 1, pas un octet nul d'une moitié haute ;
// - les horizontales rangent les résultats de la destination puis ceux de la
//   source dans **un** registre de huit octets ;
// - `PALIGNR` décale seize octets, pas trente-deux.
//
// Les autres travaillent élément par élément : leur forme XMM, avec une
// moitié haute nulle, dont on garde le bas.
//
// La référence est `Tests/Fixtures/x86-mmx-oracle.tsv`.
extension X86Core {
    /// Exécute la forme MMX de l'opcode, et dit si c'en était une.
    /// `aligning` : la table `0F 3A`, dont seul `PALIGNR` existe en MMX.
    mutating func ssse3OnMMX(_ instruction: X86Instruction, _ opcode: UInt8, aligning: Bool) throws -> Bool {
        guard instruction.vexCount == 0, !instruction.hasPrefix(0xF2), !instruction.hasPrefix(0xF3) else {
            return false
        }
        if aligning {
            guard opcode == 0x0F else { return false }
        } else {
            guard opcode <= 0x0B || (0x1C...0x1E).contains(opcode) else { return false }
        }
        let fields = try decodeFields(instruction)
        let source = try readMMXRM(fields)
        enterMMX()
        let destination = mmx(fields.reg)
        let result = aligning
            ? Self.mmxAlign(destination, source, by: UInt8(truncatingIfNeeded: instruction.immediate))
            : Self.mmxSSSE3(opcode, destination, source)
        setMMX(fields.reg, result)
        return true
    }

    /// Le résultat sur huit octets.
    static func mmxSSSE3(_ opcode: UInt8, _ destination: UInt64, _ source: UInt64) -> UInt64 {
        switch opcode {
        // `PSHUFB` : trois bits d'index, et le bit 7 qui met à zéro.
        case 0x00:
            var result: UInt64 = 0
            for index in 0..<8 {
                let selector = (source >> UInt64(8 * index)) & 0xFF
                guard selector & 0x80 == 0 else { continue }
                result |= ((destination >> (8 * (selector & 7))) & 0xFF) << UInt64(8 * index)
            }
            return result
        // Les horizontales : la forme XMM, destination en bas et source en
        // haut d'un seul opérande, rend exactement l'ordre voulu dans sa
        // moitié basse.
        case 0x01, 0x02, 0x03, 0x05, 0x06, 0x07:
            return horizontal(opcode, (low: destination, high: source), (low: 0, high: 0)).0
        default:
            return ssse3Elementwise(opcode, (low: destination, high: 0), (low: source, high: 0))?.0 ?? 0
        }
    }

    /// **`PALIGNR` sur huit octets** : la destination en haut, la source en
    /// bas, seize octets décalés à droite de `count` octets, les huit du bas
    /// gardés. Au-delà de seize, rien.
    static func mmxAlign(_ destination: UInt64, _ source: UInt64, by count: UInt8) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<8 {
            let from = index + Int(count)
            guard from < 16 else { continue }
            let byte = from < 8 ? (source >> UInt64(8 * from)) & 0xFF : (destination >> UInt64(8 * (from - 8))) & 0xFF
            result |= byte << UInt64(8 * index)
        }
        return result
    }
}

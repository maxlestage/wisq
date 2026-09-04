import Foundation

// **Le décodage x87 : sept octets, et deux tables sous chacun.**
//
// `D8` à `DF` se lisent de deux façons selon le ModRM. Quand il désigne la
// mémoire, le champ `reg` choisit l'opération et la largeur vient de l'octet
// d'opcode ; quand il vaut `11`, l'octet entier — opcode et ModRM — nomme une
// instruction à part, et le bas du ModRM désigne un registre de la pile. Deux
// jeux d'instructions distincts partagent les mêmes octets, et les confondre
// donnerait une valeur plausible et fausse.
extension X86Core {
    mutating func x87Instruction(_ instruction: X86Instruction, _ opcode: UInt8) throws {
        let modrm = instruction.modrm ?? 0
        let field = Int((modrm >> 3) & 0x07)
        let index = Int(modrm & 0x07)
        let rounding = x87Rounding

        // La forme registre : l'octet entier nomme l'instruction.
        if modrm >= 0xC0 {
            switch (opcode, field) {
            case (0xD9, 4) where modrm == 0xE0:  // FCHS
                setStack(0, X86Extended(significand: stack(0).significand,
                                        signExponent: stack(0).signExponent ^ 0x8000))
            case (0xD9, 4) where modrm == 0xE1:  // FABS
                setStack(0, X86Extended(significand: stack(0).significand,
                                        signExponent: stack(0).signExponent & 0x7FFF))
            case (0xD9, 5):  // Les constantes : FLD1 et FLDZ, employées par musl
                switch modrm {
                case 0xE8: push(X86Extended(1.0))
                case 0xEE: push(.zero)
                default: throw Fault.unsupported("une constante x87 : \(hex(modrm))")
                }
            case (0xD9, 0): push(stack(index))                       // FLD ST(i)
            case (0xD9, 1):                                          // FXCH
                let top = stack(0)
                let other = stackOrIndefinite(index)
                setStack(0, other)
                setStack(index, top)
            case (0xDD, 2): setStack(index, stack(0))                // FST ST(i)
            case (0xDD, 3): setStack(index, stack(0)); pop()         // FSTP ST(i)
            case (0xDB, 4) where modrm == 0xE3:                      // FNINIT
                x87Status = 0
                x87Control = 0x037F
                x87Tags = 0xFFFF
            // L'arithmétique sur la pile. `D8` écrit dans ST(0), `DC` dans
            // ST(i), et `DE` dans ST(i) **puis dépile** — trois octets pour
            // trois destinations, ce que le mnémonique seul ne dit pas.
            case (0xD8, 2), (0xD8, 3), (0xDD, 4), (0xDD, 5):        // FCOM / FUCOM
                noteComparison(stack(0), stack(index), quietIsInvalid: opcode == 0xD8)
                setCondition(X86Extended.compare(stack(0), stack(index)))
                if opcode == 0xD8 && field == 3 { pop() }
            case (0xD8, _): try arithmeticOnStack(field, 0, index, pop: false, rounding)
            case (0xDC, _): try arithmeticOnStack(reversed(field), index, 0,
                                                  pop: false, rounding)
            case (0xDE, _): try arithmeticOnStack(reversed(field), index, 0,
                                                  pop: true, rounding)
            case (0xDB, 6), (0xDB, 5), (0xDF, 6), (0xDF, 5):         // FCOMI / FUCOMI
                // Le champ 6 est la forme ordinaire, le 5 la « non ordonnée ».
                noteComparison(stack(0), stack(index), quietIsInvalid: field == 6)
                setComparisonFlags(X86Extended.compare(stack(0), stack(index)))
                if opcode == 0xDF { pop() }
            case (0xDF, 4) where modrm == 0xE0:                      // FNSTSW %ax
                registers[0] = (registers[0] & ~0xFFFF) | UInt64(x87Status)
            default:
                throw Fault.unsupported("une instruction x87 : \(hex(opcode)) \(hex(modrm))")
            }
            return
        }

        // La forme mémoire : le champ `reg` choisit, l'opcode donne la largeur.
        let fields = try decodeFields(instruction)
        let address = lastAddress
        switch opcode {
        case 0xD9 where field == 0:  // FLD m32
            push(X86Extended(Double(Float(bitPattern:
                UInt32(truncatingIfNeeded: try readRM(fields, 4))))))
        case 0xDD where field == 0:  // FLD m64
            push(X86Extended(Double(bitPattern: try readRM(fields, 8))))
        case 0xDB where field == 5:  // FLD m80
            push(try readExtended(address))
        case 0xDF where field == 0: push(X86Extended(Int64(Int16(truncatingIfNeeded:
            try readRM(fields, 2)))))                                 // FILD m16
        case 0xDB where field == 0: push(X86Extended(Int64(Int32(truncatingIfNeeded:
            try readRM(fields, 4)))))                                 // FILD m32
        case 0xDF where field == 5: push(X86Extended(Int64(bitPattern:
            try readRM(fields, 8))))                                  // FILD m64

        case 0xD9 where field == 2 || field == 3:  // FST / FSTP m32
            let single = stack(0).narrowed(fractionBits: 23, exponentBits: 8,
                                           rounding: rounding)
            try writeRM(fields, 4, single.bits)
            note(single.report)
            if field == 3 { pop() }
        case 0xDD where field == 2 || field == 3:  // FST / FSTP m64
            let wide = stack(0).narrowed(fractionBits: 52, exponentBits: 11,
                                         rounding: rounding)
            try writeRM(fields, 8, wide.bits)
            note(wide.report)
            if field == 3 { pop() }
        case 0xDB where field == 7:                // FSTP m80
            try writeExtended(address, stack(0))
            pop()

        case 0xDF where field == 2 || field == 3:  // FIST / FISTP m16
            try writeRM(fields, 2, integer(stack(0), bits: 16, rounding))
            if field == 3 { pop() }
        case 0xDB where field == 2 || field == 3:  // FIST / FISTP m32
            try writeRM(fields, 4, integer(stack(0), bits: 32, rounding))
            if field == 3 { pop() }
        case 0xDF where field == 7:                // FISTP m64
            try writeRM(fields, 8, integer(stack(0), bits: 64, rounding))
            pop()
        case 0xDD where field == 1, 0xDB where field == 1, 0xDF where field == 1:
            // FISTTP : la troncature, quel que soit le mode d'arrondi.
            let bits = opcode == 0xDF ? 16 : (opcode == 0xDB ? 32 : 64)
            try writeRM(fields, bits / 8, integer(stack(0), bits: bits, .towardZero))
            pop()

        case 0xD8:  // L'arithmétique avec un opérande simple en mémoire
            let value = X86Extended(Double(Float(bitPattern:
                UInt32(truncatingIfNeeded: try readRM(fields, 4)))))
            let (result, report) = try combine(field, stack(0), value, rounding)
            setStack(0, result)
            note(report)
        case 0xDC:  // La même, en double
            let value = X86Extended(Double(bitPattern: try readRM(fields, 8)))
            let (result, report) = try combine(field, stack(0), value, rounding)
            setStack(0, result)
            note(report)

        case 0xD9 where field == 5:  // FLDCW
            x87Control = UInt16(truncatingIfNeeded: try readRM(fields, 2))
        case 0xD9 where field == 7:  // FNSTCW
            try writeRM(fields, 2, UInt64(x87Control))
        case 0xDD where field == 7:  // FNSTSW
            try writeRM(fields, 2, UInt64(x87Status))
        default:
            throw Fault.unsupported("une instruction x87 : \(hex(opcode)) /\(field)")
        }
    }

    private func hex(_ value: UInt8) -> String { String(format: "%02X", value) }

    /// `DC` et `DE` **échangent** la soustraction et la division avec leurs
    /// formes renversées par rapport à `D8` : le champ 4 est `FSUB` sur l'un
    /// et `FSUBR` sur l'autre. Ce n'est pas une symétrie, c'est une
    /// irrégularité du jeu, et la manquer donne le bon calcul à l'envers.
    private func reversed(_ field: Int) -> Int {
        switch field {
        case 4: return 5
        case 5: return 4
        case 6: return 7
        case 7: return 6
        default: return field
        }
    }

    private mutating func arithmeticOnStack(_ field: Int, _ destination: Int,
                                            _ source: Int, pop popping: Bool,
                                            _ rounding: X86Extended.Rounding) throws {
        let (result, report) = try combine(field, stack(destination), stack(source), rounding)
        setStack(destination, result)
        note(report)
        if popping { pop() }
    }

    /// **Ce que le calcul a rencontré s'écrit dans le mot d'état.** Les six
    /// drapeaux d'exception s'accumulent — le processeur ne les efface pas
    /// tout seul — et C1 dit si l'arrondi est monté, ce qui permet à un
    /// programme de savoir dans quel sens il a perdu.
    mutating func note(_ report: X86Extended.Report) {
        x87Status |= report.flags
        x87Status = report.roundedUp ? (x87Status | 0x0200) : (x87Status & ~0x0200)
    }

    private func combine(_ field: Int, _ left: X86Extended, _ right: X86Extended,
                         _ rounding: X86Extended.Rounding) throws
        -> (X86Extended, X86Extended.Report) {
        switch field {
        case 0: return X86Extended.add(left, right, rounding: rounding)
        case 1: return X86Extended.multiply(left, right, rounding: rounding)
        case 4: return X86Extended.subtract(left, right, rounding: rounding)
        case 5: return X86Extended.subtract(right, left, rounding: rounding)
        case 6: return X86Extended.divide(left, right, rounding: rounding)
        case 7: return X86Extended.divide(right, left, rounding: rounding)
        default: throw Fault.unsupported("une opération x87 : /\(field)")
        }
    }

    /// L'entier que rend un rangement, ou « l'entier indéfini » quand la
    /// valeur ne tient pas. Comme en SSE, ce n'est pas une faute : le
    /// processeur range une valeur et continue.
    private mutating func integer(_ value: X86Extended, bits: Int,
                                  _ rounding: X86Extended.Rounding) -> UInt64 {
        guard let whole = value.asInteger(bits: bits, rounding: rounding) else {
            note(X86Extended.Report(X86Extended.Report.invalid))
            return bits == 64 ? 0x8000_0000_0000_0000 : (UInt64(1) << (bits - 1))
        }
        var report = X86Extended.Report()
        // **Ce qui coûte, c'est la partie fractionnaire**, pas l'écart avec
        // l'entier rendu. Comparer le résultat à la troncature manquait le cas
        // le plus courant : 2,5 arrondi au pair rend 2, ce qui est bien la
        // troncature — et pourtant une demie s'est perdue en chemin.
        if value != value.rounded { report.note(X86Extended.Report.inexact) }
        note(report)
        return UInt64(bitPattern: whole)
    }
}

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
            // **Ce que la libc et la libstdc++ de Fedora 44 demandent en
            // plus**, trouvé par la sonde qui passe au cœur chaque forme des
            // binaires de l'image : `FXAM` (38 fichiers, le `isnan` des
            // `long double`), `FCMOVcc` (36), `FNSTENV`/`FLDENV` (39, les
            // fonctions de `fenv.h`), les comparaisons qui dépilent deux fois,
            // `FFREEP` et `FRNDINT`.
            case (0xD9, 4) where modrm == 0xE5:  // FXAM
                x87Status = (x87Status & ~0x4700) | examined(0)
            case (0xD9, 7) where modrm == 0xFC:  // FRNDINT
                let (result, report) = X86Extended.integral(stackOrIndefinite(0), rounding: rounding)
                setStack(0, result)
                note(report)
            // Les copies conditionnelles : `DA` sur CF, ZF, CF ou ZF, et PF ;
            // `DB` sur leurs négations. La copie a lieu ou non, la pile ne
            // bouge pas.
            case (0xDA, 0...3), (0xDB, 0...3):
                let holds: Bool
                switch field {
                case 0: holds = flags & Flag.carry != 0
                case 1: holds = flags & Flag.zero != 0
                case 2: holds = flags & (Flag.carry | Flag.zero) != 0
                default: holds = flags & Flag.parity != 0
                }
                if holds != (opcode == 0xDB) { setStack(0, stackOrIndefinite(index)) }
            case (0xDE, 3) where modrm == 0xD9, (0xDA, 5) where modrm == 0xE9:  // FCOMPP / FUCOMPP
                noteComparison(stack(0), stack(1), quietIsInvalid: opcode == 0xDE)
                setCondition(X86Extended.compare(stack(0), stack(1)))
                pop()
                pop()
            case (0xDD, 0): markTag((x87TopIndex + index) & 7, 0b11)  // FFREE
            case (0xDF, 0):                                          // FFREEP
                markTag((x87TopIndex + index) & 7, 0b11)
                pop()
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
            // FNCLEX : les drapeaux d'exception, le résumé ES et le bit B
            // effacés ; le sommet de pile et les codes de condition restent.
            // Linux l'exécute à chaque restauration de l'état flottant sur un
            // processeur AMD (le contournement de « FXSAVE leak »), ce que le
            // cœur annonce depuis qu'il se présente comme le `qemu64` de QEMU.
            case (0xDB, 4) where modrm == 0xE2:
                x87Status &= 0x7F00
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

        // L'environnement : vingt-huit octets dans le format protégé de
        // trente-deux bits, celui de `fegetenv` et `fesetenv`. Le préfixe 66
        // demanderait le format de quatorze octets, que rien n'emploie.
        case 0xD9 where field == 6 || field == 4:
            guard !instruction.hasPrefix(0x66) else {
                throw Fault.unsupported("FNSTENV/FLDENV sur quatorze octets")
            }
            if field == 6 { try storeEnvironment(address) } else { try loadEnvironment(address) }

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

    /// Ce que `FXAM` dit de `ST(i)` : C3, C2 et C0 nomment la classe, C1 le
    /// signe. Un registre vide se dit à part, quoi qu'il contienne.
    func examined(_ index: Int) -> UInt16 {
        let value = stack(index)
        let sign: UInt16 = value.negative ? 0x0200 : 0
        if isEmpty(index) { return 0x4100 | sign }                     // vide : C3 C0
        let integer = value.significand & 0x8000_0000_0000_0000 != 0
        if value.isSpecial {
            guard integer else { return sign }                         // non pris en charge
            return (value.isInfinite ? 0x0500 : 0x0100) | sign         // infini : C2 C0 ; NaN : C0
        }
        if value.biased == 0 {
            return (value.significand == 0 ? 0x4000 : 0x4400) | sign   // zéro : C3 ; dénormal : C3 C2
        }
        return (integer ? 0x0400 : 0) | sign                           // normal : C2
    }

    /// `FNSTENV` : le mot de contrôle, le mot d'état et le mot d'étiquettes
    /// complet, chacun sur quatre octets, puis les pointeurs de la dernière
    /// instruction et de sa donnée, que ce cœur ne suit pas et range à zéro.
    /// Ensuite, comme le processeur, toutes les exceptions sont masquées.
    private mutating func storeEnvironment(_ address: UInt64) throws {
        let words = [UInt64(x87Control) | 0xFFFF_0000, UInt64(x87Status) | 0xFFFF_0000,
                     UInt64(x87Tags) | 0xFFFF_0000, 0, 0, 0, 0xFFFF_0000]
        for (index, word) in words.enumerated() {
            try writeMemory(address &+ UInt64(4 * index), 4, word)
        }
        x87Control |= 0x3F
    }

    /// `FLDENV` : l'inverse. Comme pour `FXRSTOR`, le bit 6 du mot de
    /// contrôle revient levé, ES et B se recalculent, et une étiquette
    /// non vide se relit dans la valeur du registre.
    private mutating func loadEnvironment(_ address: UInt64) throws {
        x87Control = UInt16(truncatingIfNeeded: try readMemory(address, 2)) | 0x40
        x87Status = UInt16(truncatingIfNeeded: try readMemory(address &+ 4, 2))
        let pending = (x87Status & 0x3F) & ~(x87Control & 0x3F)
        x87Status = pending != 0 ? (x87Status | 0x8080) : (x87Status & ~0x8080)
        let tags = UInt16(truncatingIfNeeded: try readMemory(address &+ 8, 2))
        for physical in 0..<8 {
            let empty = (tags >> UInt16(2 * physical)) & 0b11 == 0b11
            markTag(physical, empty ? 0b11 : Self.tag(for: x87[physical]))
        }
    }

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
        // **Ce qui coûte, c'est la partie fractionnaire**, pas l'écart avec
        // l'entier rendu. Comparer le résultat à la troncature manquait le cas
        // le plus courant : 2,5 arrondi au pair rend 2, ce qui est bien la
        // troncature — et pourtant une demie s'est perdue en chemin.
        //
        // Et C1 dit si l'arrondi est monté : 1,75 rangé en 2. Le cœur ne le
        // levait pas ; l'oracle l'a montré dès qu'il a porté une valeur qui
        // monte. Le dénormal, lui, ne se signale pas ici.
        let rounded = X86Extended.integral(value, rounding: rounding).1
        note(X86Extended.Report(rounded.flags & X86Extended.Report.inexact, roundedUp: rounded.roundedUp))
        return UInt64(bitPattern: whole)
    }
}

import Foundation

// **La pile x87.**
//
// C'est la machine qui a nommé cette tranche, comme les sept d'avant. Une fois
// le flottant scalaire posé, la course s'arrête sur `DB /0` — `FILD` — à trois
// milliards d'instructions, dans le binaire d'Alpine.
//
// **Ce que l'invité en fait**, établi en comptant ses propres binaires : le
// `long double` de musl dans `printf`. 627 des 647 `fldt` sont dans `ld-musl`,
// dans la famille `vasprintf`/`vdprintf`, avec `fstpt` 349 fois, `fxch` 285,
// `fmul` 260, `faddp` 210, `fld1` 89, `fldz` 78, `fchs` 77, `fldcw` 49,
// `fucomip` 49, `fcomip` 49.
//
// **Ce n'est pas un banc de registres, c'est une pile**, et c'est ce qui la
// rend particulière : `ST(0)` n'est pas un registre mais le sommet. Chaque
// chargement décrémente le sommet, chaque rangement qui dépile l'incrémente,
// et le mot d'étiquettes suit. Deux conventions cohabitent, et la mesure les a
// établies plutôt qu'une lecture : l'image de sauvegarde range les registres
// dans l'ordre de la **pile**, tandis que le mot d'étiquettes est indexé par
// registre **physique**.
//
// La référence est `Tests/Fixtures/x86-x87-oracle.tsv` : 67 formes, 3 618 cas.
extension X86Core {
    /// Le sommet, tel que le mot d'état le porte.
    public var x87TopIndex: Int {
        get { Int((x87Status >> 11) & 0x07) }
        set { x87Status = (x87Status & ~0x3800) | UInt16((newValue & 0x07) << 11) }
    }

    /// `ST(i)`, c'est-à-dire le registre physique `(sommet + i) mod 8`.
    public func stack(_ index: Int) -> X86Extended { x87[(x87TopIndex + index) & 7] }

    public mutating func setStack(_ index: Int, _ value: X86Extended) {
        let physical = (x87TopIndex + index) & 7
        x87[physical] = value
        markTag(physical, Self.tag(for: value))
    }

    /// **Le mot d'étiquettes a quatre états, pas deux.** Zéro, infini, NaN et
    /// dénormal ne sont pas « une valeur ordinaire » : le processeur les
    /// distingue à deux bits, et un test qui ne regarde que « plein ou vide »
    /// passerait à côté de la moitié de ce que `FLDZ` fait.
    ///
    /// 00 valide, 01 zéro, 10 particulier, 11 vide.
    static func tag(for value: X86Extended) -> UInt16 {
        if value.isZero { return 0b01 }
        if value.isSpecial { return 0b10 }
        // Un dénormal — exposant nul, mantisse non nulle — et un « non-nombre
        // non pris en charge » — bit de tête absent alors que l'exposant ne
        // l'est pas — comptent aussi comme particuliers.
        if value.biased == 0 { return 0b10 }
        if value.significand & 0x8000_0000_0000_0000 == 0 { return 0b10 }
        return 0b00
    }

    mutating func markTag(_ physical: Int, _ tag: UInt16) {
        let shift = UInt16(2 * physical)
        x87Tags = (x87Tags & ~(0b11 << shift)) | (tag << shift)
    }

    /// Empiler : le sommet descend d'un cran, puis la valeur s'y pose.
    public mutating func push(_ value: X86Extended) {
        x87TopIndex = (x87TopIndex - 1) & 7
        setStack(0, value)
    }

    /// Dépiler : le sommet remonte, et le registre quitté est marqué vide.
    public mutating func pop() {
        markTag(x87TopIndex, 0b11)
        x87TopIndex = (x87TopIndex + 1) & 7
    }

    /// Le registre `ST(i)` est-il vide ? Son étiquette le dit — 0b11.
    public func isEmpty(_ index: Int) -> Bool {
        let physical = (x87TopIndex + index) & 7
        return (x87Tags >> UInt16(2 * physical)) & 0b11 == 0b11
    }

    /// **Lire un registre vide est un débordement de pile par le bas.**
    ///
    /// Le processeur ne rend alors pas la valeur qui traîne dans le registre —
    /// il rend « l'indéfini réel », pose le drapeau d'opération invalide et
    /// celui de faute de pile. C'est ce que l'oracle a montré sur `FXCH` : la
    /// valeur du sommet part bien dans le registre vide, mais le sommet, lui,
    /// reçoit l'indéfini et non ce que le registre contenait.
    ///
    /// Seul `FXCH` atteint ce chemin dans le corpus ; les autres formes le
    /// prendront le jour où la machine les y mènera.
    public mutating func stackOrIndefinite(_ index: Int) -> X86Extended {
        guard isEmpty(index) else { return stack(index) }
        x87Status |= 0x0041     // opération invalide, et faute de pile
        return .indefinite
    }

    var x87Rounding: X86Extended.Rounding { X86Extended.Rounding(control: x87Control) }

    /// Lire dix octets de mémoire comme un étendu.
    mutating func readExtended(_ address: UInt64) throws -> X86Extended {
        guard let memory else { throw Fault.unsupported("un x87 sans mémoire") }
        var bytes = [UInt8]()
        for offset in 0..<10 {
            bytes.append(UInt8(truncatingIfNeeded:
                try memory.read(try translate(address &+ UInt64(offset)), 1)))
        }
        return X86Extended(bytes: bytes)
    }

    mutating func writeExtended(_ address: UInt64, _ value: X86Extended) throws {
        guard let memory else { throw Fault.unsupported("un x87 sans mémoire") }
        for (offset, byte) in value.bytes.enumerated() {
            try memory.write(try translate(address &+ UInt64(offset), .write), 1, UInt64(byte))
        }
    }

    /// Les trois drapeaux de condition du mot d'état, qu'une comparaison
    /// écrit. C0 est le bit 8, C1 le 9, C2 le 10, C3 le 14 — un ordre qui
    /// n'est pas le leur, hérité du 8087.
    mutating func setCondition(_ order: X86Extended.Order) {
        x87Status &= ~0x4700
        x87Status &= ~0x0200        // C1 tombe : aucune comparaison n'arrondit
        switch order {
        case .greater: break
        case .less: x87Status |= 0x0100          // C0
        case .equal: x87Status |= 0x4000         // C3
        case .unordered: x87Status |= 0x4500     // C0, C2, C3
        }
    }

    /// Et la même comparaison écrite dans les drapeaux du processeur, ce que
    /// font `FCOMI` et ses variantes. La correspondance n'est pas la même :
    /// ici c'est ZF, PF et CF, exactement comme `UCOMISD`.
    /// **`FCOM` et `FUCOM` ne diffèrent que sur un point**, et c'est celui-là :
    /// la forme ordinaire signale une opération invalide devant **n'importe
    /// quel** NaN, tandis que la forme « non ordonnée » ne le fait que devant
    /// un NaN signalant. Un NaN silencieux est une valeur qu'on a le droit de
    /// comparer sans se plaindre — c'est même à ça qu'il sert.
    mutating func noteComparison(_ left: X86Extended, _ right: X86Extended,
                                 quietIsInvalid: Bool) {
        let signaling = left.isSignalingNaN || right.isSignalingNaN
        let anyNaN = left.isNaN || right.isNaN
        if signaling || (quietIsInvalid && anyNaN) {
            x87Status |= 0x0001
            return
        }
        // Comparer met aussi la main sur les opérandes : un dénormal se
        // signale, même quand la comparaison aboutit sans se plaindre.
        if X86Extended.isDenormalOperand(left) || X86Extended.isDenormalOperand(right) {
            x87Status |= 0x0002
        }
    }

    mutating func setComparisonFlags(_ order: X86Extended.Order) {
        x87Status &= ~0x0200
        flags &= ~(Flag.zero | Flag.parity | Flag.carry
                   | Flag.overflow | Flag.sign | Flag.auxiliary)
        switch order {
        case .greater: break
        case .less: flags |= Flag.carry
        case .equal: flags |= Flag.zero
        case .unordered: flags |= Flag.zero | Flag.parity | Flag.carry
        }
    }
}

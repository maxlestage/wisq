import Foundation

// **L'état étendu : XCR0, `XSAVE`, `XRSTOR`, et le haut des registres YMM.**
//
// `FXSAVE` range x87 et SSE dans 512 octets, et rien d'autre : AVX double les
// registres vectoriels, et leur moitié haute n'a pas de place là. `XSAVE`
// ajoute un en-tête et des composants — ici trois, x87 (bit 0), SSE (bit 1)
// et le haut des YMM (bit 2) —, choisis par un masque : ceux que le noyau a
// activés dans XCR0 (`XSETBV`), croisés avec ceux qu'EDX:EAX demande.
//
// C'est la condition d'AVX, pas AVX lui-même. Linux n'active un composant que
// si CPUID l'annonce **et** annonce l'extension qui s'en sert : tant qu'AVX
// n'est pas annoncé, il garde XCR0 à x87|SSE et range son état par `XSAVE`
// comme il le rangeait par `FXSAVE`. La glibc lit OSXSAVE (CPUID.1:ECX.27,
// le reflet de CR4.OSXSAVE) avant de croire un seul bit d'AVX.
//
// **La forme standard seulement.** `XSAVEOPT`, `XSAVEC` et `XSAVES` ne sont
// pas annoncés (CPUID.0xD.1:EAX à zéro) : un en-tête compacté est refusé.
//
// **Aucune exception n'est livrée** — ce cœur n'a ni #GP ni #UD : ce que le
// processeur refuserait, il le refuse en s'arrêtant sur son nom, plutôt que
// de charger un état qui n'existe pas.
extension X86Core {
    /// Les composants que ce cœur sait ranger : x87, SSE, le haut des YMM.
    static let supportedExtendedState: UInt64 = 0b111
    /// 66, F3 et F2 dans le masque des préfixes : ceux qui changent ce que
    /// désigne un opcode de la table `0F`.
    static var mandatoryPrefixes: UInt16 { 1 << 9 | 1 << 2 | 1 << 1 }

    /// Où vivent l'en-tête et le haut des YMM dans la zone standard.
    enum ExtendedStateArea {
        static let header = 512
        static let headerSize = 64
        static let upperVectors = 576
        static let upperVectorsSize = 256
        static let size = upperVectors + upperVectorsSize
    }

    /// CR4.OSXSAVE (bit 18) : le système dit qu'il range l'état étendu.
    static let osxsave: UInt64 = 1 << 18

    var extendedStateEnabled: Bool { system.control[4] & Self.osxsave != 0 }

    /// La taille de la zone pour les composants qu'XCR0 active : ce que
    /// CPUID.0xD.0:EBX annonce, et ce que Linux réserve par tâche.
    static func extendedStateSize(_ xcr0: UInt64) -> UInt32 {
        UInt32(xcr0 & 0b100 != 0 ? ExtendedStateArea.size : ExtendedStateArea.upperVectors)
    }

    /// Le haut d'un registre YMM remis à zéro — ce que fait toute forme VEX.128
    /// qui écrit ce registre.
    mutating func clearUpperVector(_ index: Int) {
        upperVectors[2 * index] = 0
        upperVectors[2 * index + 1] = 0
    }

    /// `XGETBV` (0F 01 D0) et `XSETBV` (0F 01 D1).
    mutating func extendedControlInstruction(_ rm: Int) throws {
        guard extendedStateEnabled else { throw Fault.unsupported("XGETBV/XSETBV sans CR4.OSXSAVE") }
        // Seul XCR0 existe : XCR1 demanderait XGETBV1, qui n'est pas annoncé.
        guard registers.read(1) & 0xFFFF_FFFF == 0 else {
            throw Fault.unsupported("XCR\(registers.read(1) & 0xFFFF_FFFF)")
        }
        if rm == 0 {
            write(0, 4, highByte: false, xcr0 & 0xFFFF_FFFF)
            write(2, 4, highByte: false, xcr0 >> 32)
            return
        }
        guard currentPrivilege == 0 else { throw Fault.unsupported("XSETBV hors de l'anneau zéro") }
        let value = (registers.read(2) & 0xFFFF_FFFF) << 32 | registers.read(0) & 0xFFFF_FFFF
        // x87 toujours, le haut des YMM jamais sans SSE, rien d'inconnu.
        guard value & 1 != 0, value & ~Self.supportedExtendedState == 0, value & 0b110 != 0b100 else {
            throw Fault.unsupported("XCR0 \(String(value, radix: 16)) refusé")
        }
        xcr0 = value
    }

    /// Le masque d'un `XSAVE` ou d'un `XRSTOR` : XCR0 croisé avec EDX:EAX.
    private mutating func requestedFeatures() -> UInt64 {
        xcr0 & ((registers.read(2) & 0xFFFF_FFFF) << 32 | registers.read(0) & 0xFFFF_FFFF)
    }

    /// La zone doit être alignée sur soixante-quatre octets.
    private mutating func extendedStateBase(_ name: String) throws -> UInt64 {
        guard extendedStateEnabled else { throw Fault.unsupported("\(name) sans CR4.OSXSAVE") }
        guard memory != nil else { throw Fault.unsupported("\(name) sans mémoire") }
        let base = lastAddress
        guard base & 63 == 0 else { throw Fault.unsupported("\(name) sur une zone mal alignée") }
        return base
    }

    /// `XSAVE` (0F AE /4) : les composants demandés, et leurs bits dans
    /// XSTATE_BV — les autres bits de l'en-tête ne bougent pas.
    ///
    /// **Chaque composant demandé est dit « en usage »**, même à son état
    /// initial. Le manuel le permet (XINUSE peut valoir un sans que l'état
    /// ait quitté sa configuration initiale), et `XRSTOR` relira alors la
    /// zone plutôt que de remettre à zéro : le même état dans les deux cas.
    mutating func saveExtendedState() throws {
        let base = try extendedStateBase("XSAVE")
        let features = requestedFeatures()
        if features & 0b001 != 0 { try saveX87Image(at: base) }
        if features & 0b110 != 0 { try saveMXCSR(at: base) }
        if features & 0b010 != 0 { try saveVectorImage(at: base) }
        if features & 0b100 != 0 {
            for index in 0..<32 {
                try writeMemory(base &+ UInt64(ExtendedStateArea.upperVectors + 8 * index), 8, upperVectors[index])
            }
        }
        let header = base &+ UInt64(ExtendedStateArea.header)
        let inUse = try readMemory(header, 8)
        try writeMemory(header, 8, inUse & ~features | features)
    }

    /// `XRSTOR` (0F AE /5) : chaque composant demandé est relu si XSTATE_BV
    /// le dit en usage, remis à son état initial sinon.
    mutating func restoreExtendedState() throws {
        let base = try extendedStateBase("XRSTOR")
        let features = requestedFeatures()
        let header = base &+ UInt64(ExtendedStateArea.header)
        let inUse = try readMemory(header, 8)
        let compaction = try readMemory(header &+ 8, 8)
        // L'en-tête d'une zone standard : XCOMP_BV à zéro, les quarante-huit
        // octets réservés à zéro, rien en usage qu'XCR0 n'active pas.
        guard compaction == 0 else { throw Fault.unsupported("XRSTOR d'une zone compactée") }
        for offset in stride(from: 16, to: ExtendedStateArea.headerSize, by: 8) {
            guard try readMemory(header &+ UInt64(offset), 8) == 0 else {
                throw Fault.unsupported("XRSTOR : l'en-tête porte des octets réservés")
            }
        }
        guard inUse & ~xcr0 == 0 else { throw Fault.unsupported("XRSTOR : un composant qu'XCR0 n'active pas") }
        // MXCSR d'abord, seul refus possible : se lit dès que SSE ou AVX est
        // demandé, quoi que dise XSTATE_BV — la règle de la forme standard.
        if features & 0b110 != 0 { try restoreMXCSR(at: base) }
        if features & 0b001 != 0 {
            if inUse & 0b001 != 0 {
                try restoreX87Image(at: base)
            } else {
                x87Control = 0x037F
                x87Status = 0
                x87Tags = 0xFFFF
                for index in 0..<8 { x87[index] = .zero }
            }
        }
        if features & 0b010 != 0 {
            if inUse & 0b010 != 0 {
                try restoreVectorImage(at: base)
            } else {
                for index in 0..<32 { vectors[index] = 0 }
            }
        }
        if features & 0b100 != 0 {
            for index in 0..<32 {
                upperVectors[index] = inUse & 0b100 != 0
                    ? try readMemory(base &+ UInt64(ExtendedStateArea.upperVectors + 8 * index), 8) : 0
            }
        }
    }
}

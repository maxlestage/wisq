import Foundation

// La traduction d'adresses : quatre niveaux de tables, et un cache pour ne pas
// les reparcourir à chaque accès.
extension X86Core {
    /// Une entrée de table de pages présente porte ce bit ; sans lui, tout le
    /// reste de l'entrée appartient au système d'exploitation et ne veut rien
    /// dire pour le processeur.
    static let present: UInt64 = 1 << 0
    /// Le bit qui dit « cette entrée est une grande page et le parcours
    /// s'arrête ici » : deux mébioctets au troisième niveau, un gibioctet au
    /// deuxième.
    static let hugePage: UInt64 = 1 << 7
    /// Les bits d'adresse d'une entrée : de 12 à 51.
    static let frameMask: UInt64 = 0x000F_FFFF_FFFF_F000

    /// L'adresse physique correspondant à une adresse virtuelle.
    ///
    /// Sans pagination, les deux sont la même chose — et c'est le cas au
    /// démarrage, avant que le noyau n'ait posé ses tables. Avec, il faut
    /// parcourir quatre niveaux, ce qui **quadruple** le nombre d'accès
    /// mémoire par instruction si on le refait à chaque fois. D'où le cache
    /// juste en dessous.
    @inline(__always)
    mutating func translate(_ virtual: UInt64, _ access: Access = .read) throws -> UInt64 {
        guard pagingActive else { return virtual }
        let page = virtual & ~UInt64(0xFFF)
        let slot = Int((page >> 12) & UInt64(Self.translationSlots - 1))
        if translationTags[slot] == page &+ 1 { return translationFrames[slot] | (virtual & 0xFFF) }
        return try fill(virtual, page, slot, access)
    }

    /// Ce que l'accès venait faire. Un gestionnaire de faute de page le lit
    /// dans le code d'erreur, et le décompresseur de Linux refuse ceux qu'il
    /// ne reconnaît pas — donc le poser au hasard l'arrêterait net.
    public enum Access {
        case read
        case write
        /// La lecture de l'instruction elle-même.
        case fetch

        /// Le code d'erreur d'une faute de page pour cet accès. Le bit de
        /// présence reste à zéro : ce cœur ne faute que sur une entrée
        /// absente, jamais sur une protection.
        var errorCode: UInt64 {
            switch self {
            case .read: return 0
            case .write: return 1 << 1
            case .fetch: return 1 << 4
            }
        }
    }

    /// Le chemin lent : parcourir les tables, ranger le résultat dans le
    /// cache. Séparé de `translate` pour que le cas courant — une étiquette
    /// qui correspond — tienne dans quelques instructions.
    mutating func fill(_ at: UInt64, _ page: UInt64, _ slot: Int, _ how: Access) throws -> UInt64 {
        let frame: UInt64
        do {
            frame = try walk(page)
        } catch Fault.pageFault {
            // CR2 porte l'adresse **entière**, pas la page : c'est ce qu'un
            // gestionnaire y lit, et l'arrondir lui cacherait l'octet visé.
            // **Le bit qui dit d'où vient l'accès.** Linux s'en sert pour
            // trancher entre « une page manque à un programme, je la lui
            // pose » et « le noyau est parti dans le décor, j'affiche un
            // oops ». Sans lui, la toute première page manquante de `/init` a
            // été prise pour un défaut du noyau lui-même : `Oops: 0010`, un
            // vidage de registres, et « Attempted to kill init ». Le
            // programme n'avait rien fait de mal ; on avait juste oublié de
            // dire qu'il était le programme.
            pageFaultErrorCode = how.errorCode | (privilege == 3 ? 1 << 2 : 0)
            throw Fault.pageFault(at)
        }
        translationTags[slot] = page &+ 1
        translationFrames[slot] = frame
        return frame | (at & 0xFFF)
    }

    /// Le parcours lui-même. Quatre index de neuf bits, pris du haut vers le
    /// bas, et une grande page peut l'arrêter en chemin.
    mutating func walk(_ page: UInt64) throws -> UInt64 {
        guard let memory else { throw Fault.unsupported("une traduction sans mémoire") }
        var table = system.control[3] & Self.frameMask
        for level in stride(from: 39, through: 12, by: -9) {
            let index = (page >> UInt64(level)) & 0x1FF
            let entry = try memory.read(table &+ index * 8, 8)
            guard entry & Self.present != 0 else { throw Fault.pageFault(page) }
            if level > 12 && entry & Self.hugePage != 0 {
                // Une grande page : le reste de l'adresse virtuelle sert de
                // décalage dedans, et le parcours s'arrête.
                let size = UInt64(1) << UInt64(level)
                return (entry & Self.frameMask & ~(size &- 1)) | (page & (size &- 1))
            }
            table = entry & Self.frameMask
        }
        return table
    }

    /// Le cache de traduction, direct et minuscule. Un vrai processeur en a
    /// plusieurs, associatifs ; celui-ci suffit à ne pas reparcourir quatre
    /// tables pour deux accès consécutifs à la même page, qui est le cas
    /// courant.
    ///
    /// L'étiquette est l'adresse de page **plus un**, pour que zéro veuille
    /// dire « vide » : sans ça, la page zéro serait vue comme déjà là.
    static let translationSlots = 1024

    /// Écrire CR3 vide le cache — c'est ce que fait un vrai processeur, et
    /// c'est ainsi qu'un noyau change d'espace d'adressage.
    mutating func flushTranslations() {
        for slot in 0..<Self.translationSlots { translationTags[slot] = 0 }
    }

    // MARK: - Les instructions système

    mutating func systemInstruction(_ instruction: X86Instruction, _ opcode: UInt8) throws -> Bool {
        switch opcode {
        case 0x20:  // MOV r64, CRn
            let fields = try Self.fields(instruction)
            registers[fields.rm] = system.control[fields.reg]
            return true
        case 0x22:  // MOV CRn, r64
            let fields = try Self.fields(instruction)
            let value = registers[fields.rm]
            let previous = system.control[fields.reg]
            system.control[fields.reg] = value
            // Poser CR3 change l'espace d'adressage ; allumer ou éteindre la
            // pagination aussi. Dans les deux cas le cache ment désormais.
            if fields.reg == 3 || (fields.reg == 0 && (previous ^ value) & Self.pagingBit != 0) {
                flushTranslations()
            }
            if fields.reg == 0 {
                system.refreshLongMode()
                pagingActive = system.pagingOn
            }
            return true
        case 0x21:  // MOV r64, DRn
            let fields = try Self.fields(instruction)
            registers[fields.rm] = system.debug[fields.reg]
            return true
        case 0x23:  // MOV DRn, r64
            let fields = try Self.fields(instruction)
            system.debug[fields.reg] = registers[fields.rm]
            return true
        case 0x30:  // WRMSR : EDX:EAX vers le registre nommé par ECX
            let value = (registers[2] & 0xFFFF_FFFF) << 32 | (registers[0] & 0xFFFF_FFFF)
            system.modelSpecific[UInt32(truncatingIfNeeded: registers[1])] = value
            system.refreshLongMode()
            return true
        case 0x32:  // RDMSR
            let value = system.modelSpecific[UInt32(truncatingIfNeeded: registers[1])] ?? 0
            write(0, 4, highByte: false, value & 0xFFFF_FFFF)
            write(2, 4, highByte: false, value >> 32)
            return true
        case 0x31:  // RDTSC : le compteur d'instructions fait l'affaire.
            write(0, 4, highByte: false, retired & 0xFFFF_FFFF)
            write(2, 4, highByte: false, (retired >> 32) & 0xFFFF_FFFF)
            return true
        case 0xA2:  // CPUID
            let (a, b, c, d) = X86CPUID.answer(
                leaf: UInt32(truncatingIfNeeded: registers[0]),
                subleaf: UInt32(truncatingIfNeeded: registers[1]))
            write(0, 4, highByte: false, UInt64(a))
            write(3, 4, highByte: false, UInt64(b))
            write(1, 4, highByte: false, UInt64(c))
            write(2, 4, highByte: false, UInt64(d))
            return true
        default:
            return false
        }
    }

    static let pagingBit: UInt64 = X86SystemState.paging
}

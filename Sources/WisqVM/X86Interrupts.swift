import Foundation

// La livraison d'exception : rendre au noyau la faute qu'il a dit savoir
// traiter.
//
// **Pourquoi c'est là.** Le décompresseur 64 bits de Linux ne cartographie pas
// toute la mémoire d'avance : il pose une IDT dont **un seul** vecteur est
// rempli — le quatorze, la faute de page — et se sert de ce gestionnaire pour
// étendre l'identité à la demande, page par page, à mesure qu'il écrit le
// noyau décompressé. Un cœur qui n'a pas de livraison d'exception s'arrête donc
// sur la première adresse que le noyau n'a pas encore cartographiée, et
// l'arrêt ressemble à une divergence alors que c'est le fonctionnement normal.
//
// C'est exactement ce que la tentative de démarrage mesurait : 538 976
// instructions, puis une faute de page à 0x0D000000 sous les tables du noyau —
// et l'IDT posée à ce moment-là porte le vecteur 14 et lui seul, ciblant du
// code qui commence par la séquence d'empilement de `boot_idt_handler`.
extension X86Core {
    /// Ce qu'une porte d'interruption dit : où aller, sous quel sélecteur, et
    /// de quel genre. Les seuls genres qui existent en mode long sont la porte
    /// d'interruption (0xE, qui masque les interruptions en entrant) et la
    /// porte de trappe (0xF, qui ne les masque pas).
    struct Gate {
        let offset: UInt64
        let selector: UInt16
        let kind: UInt8
    }

    /// Les vecteurs qui portent un code d'erreur empilé par le processeur.
    /// Le gestionnaire compte dessus pour retrouver son cadre : en oublier un
    /// décale toute la pile.
    static let vectorsWithErrorCode: Set<UInt8> = [8, 10, 11, 12, 13, 14, 17, 21, 29, 30]

    /// Le vecteur d'une faute, quand ce cœur sait la livrer. Une forme non
    /// implémentée n'en a pas : la livrer comme #UD ferait croire au noyau que
    /// son propre code est invalide, ce qui est un mensonge plus coûteux que
    /// l'arrêt.
    static func vector(of fault: Fault) -> UInt8? {
        switch fault {
        case .divideError: return 0
        case .pageFault: return 14
        case .unsupported, .outsideMemory: return nil
        }
    }

    /// La porte du vecteur, lue dans l'IDT que le noyau a chargée. `nil` quand
    /// il n'y en a pas : pas d'IDT, une limite trop courte, ou une porte dont
    /// le bit de présence est à zéro.
    mutating func gate(_ vector: UInt8) throws -> Gate? {
        guard let memory, descriptorLimits[1] >= 15 else { return nil }
        let position = UInt64(vector) * 16
        // La limite est le dernier octet valide : une porte doit tenir
        // **entièrement** dedans.
        guard position &+ 15 <= descriptorLimits[1] else { return nil }
        let entry = descriptorBases[1] &+ position
        let low = try memory.read(try translate(entry), 8)
        let high = try memory.read(try translate(entry &+ 8), 8)
        guard low & (1 << 47) != 0 else { return nil }
        // Le décalage est en trois morceaux, dispersés par l'héritage du 386 :
        // les seize bits du bas, les seize du milieu tout en haut du mot bas,
        // et les trente-deux du haut dans le mot suivant.
        let offset = (low & 0xFFFF) | ((low >> 32) & 0xFFFF_0000) | ((high & 0xFFFF_FFFF) << 32)
        return Gate(offset: offset, selector: UInt16((low >> 16) & 0xFFFF),
                    kind: UInt8((low >> 40) & 0x0F))
    }

    /// Livrer la faute au noyau, et dire si ça a été fait.
    ///
    /// **RIP pointe encore sur l'instruction fautive** — c'est ce que le
    /// `execute` garantit en n'avançant qu'après coup — donc l'adresse empilée
    /// est celle qu'il faut reprendre après `IRETQ`. Ce qui n'est **pas**
    /// garanti, c'est qu'une instruction fautive n'ait rien laissé derrière
    /// elle : celles qui écrivent un registre avant de toucher la mémoire ne
    /// sont pas rejouables ici. Le décompresseur ne faute que sur des accès
    /// simples, donc ça tient ; l'écrire ailleurs que dans ce commentaire
    /// serait prématuré.
    mutating func deliver(_ fault: Fault) throws -> Bool {
        guard let vector = Self.vector(of: fault), let gate = try gate(vector) else { return false }
        if case .pageFault(let address) = fault { system.control[2] = address }

        // Le cadre du mode long : toujours SS et RSP, même sans changement de
        // privilège — c'est ce qui distingue le 64 bits du 32, où ils ne
        // partaient que si le niveau changeait.
        let stack = registers[4]
        var pointer = stack & ~UInt64(0xF)
        func push(_ value: UInt64) throws {
            pointer &-= 8
            try memory?.write(try translate(pointer, .write), 8, value)
        }
        try push(UInt64(segments[2]))
        try push(stack)
        try push(flags | Flag.reserved)
        try push(UInt64(segments[1]))
        try push(rip)
        if Self.vectorsWithErrorCode.contains(vector) {
            try push(vector == 14 ? pageFaultErrorCode : 0)
        }
        registers[4] = pointer

        segments[1] = gate.selector
        rip = gate.offset
        // Une porte d'interruption masque les interruptions en entrant ; une
        // porte de trappe les laisse. Le pas-à-pas et la reprise s'éteignent
        // dans les deux cas.
        flags &= ~(Flag.trap | Flag.nested | Flag.resume)
        if gate.kind == 0x0E { flags &= ~Flag.interrupt }
        // **Pas de `jumped` ici.** Un branchement le pose pour dire à
        // `execute` de ne pas avancer RIP ; mais la livraison a lieu *après*
        // que `execute` a levé, donc personne ne le lira — sauf la première
        // instruction du gestionnaire, qui le trouverait encore posé et ne
        // ferait pas avancer RIP. Elle s'exécutait alors deux fois : un
        // `push %rdi` de trop, huit octets de décalage, et l'`IRETQ` du
        // gestionnaire repartait sur le code d'erreur au lieu de l'adresse de
        // reprise. Le noyau sautait à 0x2.
        jumped = false
        return true
    }

    /// `IRETQ` : défaire le cadre et repartir où on en était.
    ///
    /// Le code d'erreur, lui, n'est **pas** dépilé par le processeur : c'est au
    /// gestionnaire de le faire, et Linux ajoute bien huit à RSP avant son
    /// `iretq`. Le dépiler ici ferait sauter deux fois la même case.
    mutating func returnFromInterrupt() throws {
        guard let memory else { throw Fault.unsupported("un IRETQ sans mémoire") }
        var pointer = registers[4]
        func pop() throws -> UInt64 {
            let value = try memory.read(try translate(pointer), 8)
            pointer &+= 8
            return value
        }
        let target = try pop()
        let code = try pop()
        let restored = try pop()
        let stack = try pop()
        let stackSelector = try pop()
        rip = target
        segments[1] = UInt16(truncatingIfNeeded: code)
        flags = restored | Flag.reserved
        registers[4] = stack
        segments[2] = UInt16(truncatingIfNeeded: stackSelector)
        jumped = true
    }
}

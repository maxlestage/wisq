import Foundation

// **`SYSCALL` et `SYSRET` : la porte étroite entre un programme et son noyau.**
//
// C'est le noyau qui a nommé cette tranche. Après les registres XMM, le
// chargeur dynamique de musl franchit ses fonctions de chaîne et s'arrête dix
// instructions plus loin sur `0F 05`, à RIP `0x7f0f12ae386d` : il demande son
// premier service.
//
// **Pourquoi ce n'est pas une interruption.** L'ancienne façon d'appeler le
// noyau — `INT 0x80` — passait par l'IDT, le TSS et un cadre de pile complet.
// `SYSCALL` ne fait rien de tout ça : il range l'adresse de retour dans RCX,
// les drapeaux dans R11, prend son segment et son adresse dans des MSR, et
// saute. **Il ne change pas de pile** : RSP reste celui du programme, et c'est
// au noyau de le remplacer — d'où le `SWAPGS` en tête de son gestionnaire, qui
// lui rend d'abord sa zone par processeur pour qu'il puisse y lire la sienne.
// Un cœur qui changerait la pile ici ferait travailler le noyau sur une pile
// qu'il croit encore devoir aller chercher.
//
// **Ce que l'oracle matériel ne peut pas dire.** Un `SYSCALL` dans le harnais
// entrerait dans le noyau de l'hôte au lieu de répondre, et un `SYSRET`
// partirait en anneau trois avec des sélecteurs qui n'existent pas. C'est donc
// le second endroit du cœur qui ne soit pas prouvé contre la machine, après la
// division par zéro — et il faut le dire plutôt que le laisser croire. Les
// tests sont écrits à la main, contre le manuel, et chacun nomme ce qu'il
// tient.
extension X86Core {
    /// Vrai quand le noyau a ouvert la porte, c'est-à-dire quand EFER.SCE est
    /// posé.
    var systemCallsEnabled: Bool {
        (system.modelSpecific[X86SystemState.efer] ?? 0)
            & X86SystemState.systemCallEnable != 0
    }

    /// Les deux sélecteurs que `STAR` porte : celui de l'entrée et celui du
    /// retour. Les segments de pile s'en déduisent en ajoutant huit.
    var systemCallSelectors: (entry: UInt16, exit: UInt16) {
        let star = system.modelSpecific[X86SystemState.star] ?? 0
        return (UInt16(truncatingIfNeeded: star >> 32), UInt16(truncatingIfNeeded: star >> 48))
    }

    /// `SYSCALL` : entrer dans le noyau sans passer par l'IDT.
    ///
    /// La longueur est passée plutôt que relue : `execute` n'avance RIP
    /// qu'après, et cette instruction-ci a besoin de l'adresse *suivante*
    /// avant que ça arrive.
    mutating func systemCall(length: Int) throws {
        guard systemCallsEnabled else {
            throw Fault.unsupported("un SYSCALL sans EFER.SCE")
        }
        // **RCX porte l'adresse de la suite, pas celle du `SYSCALL`.** RIP
        // pointe encore sur l'instruction — `execute` ne l'avance qu'après —
        // donc il faut ajouter sa longueur ici. La confondre avec l'adresse
        // courante ferait boucler le programme sur son propre appel, à
        // l'infini et sans rien signaler.
        registers[1] = rip &+ UInt64(length)
        registers[11] = flags | Flag.reserved
        // Les drapeaux que le noyau a demandé d'effacer. Le masque est à lui :
        // il y met au moins le bit d'interruption, pour ne pas être interrompu
        // avant d'avoir sa propre pile.
        let mask = system.modelSpecific[X86SystemState.systemCallFlagMask] ?? 0
        flags = (flags & ~mask) | Flag.reserved
        flags &= ~Flag.resume

        // Les sélecteurs sont **forcés** à l'anneau zéro, quel que soit ce que
        // le noyau a écrit dans STAR. C'est le processeur qui le fait, et le
        // laisser au noyau reviendrait à laisser un programme choisir son
        // privilège en écrivant un MSR — ce qu'il ne peut pas faire, mais un
        // cœur qui recopie sans masquer ne le saurait pas.
        let selectors = systemCallSelectors
        segments[1] = selectors.entry & ~UInt16(3)
        segments[2] = (selectors.entry &+ 8) & ~UInt16(3)
        rip = system.modelSpecific[X86SystemState.longSystemCallTarget] ?? 0
        jumped = true
    }

    /// `SYSRET` : rendre la main au programme.
    ///
    /// **Le retour ne repasse pas par où l'entrée est venue.** `STAR` porte un
    /// second sélecteur pour ça, et le processeur y ajoute seize pour le code
    /// et huit pour la pile — parce qu'un noyau range, dans cet ordre, le code
    /// 32 bits puis le code 64 bits de l'espace utilisateur. Se tromper de
    /// décalage rendrait la main sous un segment 32 bits, et le programme
    /// exécuterait ses propres octets comme s'ils voulaient dire autre chose.
    mutating func systemReturn(wide: Bool) throws {
        guard systemCallsEnabled else {
            throw Fault.unsupported("un SYSRET sans EFER.SCE")
        }
        guard wide else {
            throw Fault.unsupported("un SYSRET vers le mode compatibilité")
        }
        rip = registers[1]
        // R11 rend les drapeaux tels que `SYSCALL` les avait pris. Les bits
        // réservés sont remis d'office : ils ne sont pas au programme.
        flags = (registers[11] & ~(Flag.resume | Flag.nested)) | Flag.reserved
        let selectors = systemCallSelectors
        segments[1] = (selectors.exit &+ 16) | 3
        segments[2] = (selectors.exit &+ 8) | 3
        jumped = true
    }
}

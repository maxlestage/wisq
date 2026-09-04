import Foundation

// Ce que le programme trouve dans sa table des globales.
//
// **Pourquoi ce fichier existe, et ce qu'il a fallu écarter avant.** Cinq
// corpus matériels ont épuisé le jeu d'instructions ; le vecteur auxiliaire
// que le noyau pose est juste ; et la pile d'ombre a montré que sur six
// milliards d'instructions, **aucun `ret` ne trahit son `call`** — personne
// n'écrase une adresse de retour.
//
// Reste une chose que la pile d'ombre ne peut pas voir : **où le `call`
// allait**. Un appel qui passe par la table des globales — `call *m`, ou le
// `jmp *m` d'un tremplin de liaison — lit son adresse en mémoire. Si cette
// case porte la mauvaise fonction, l'appel y va, en revient proprement, et
// rend à l'appelant une valeur du mauvais genre. La pile est intacte du début
// à la fin, et le programme meurt quand même.
//
// C'est exactement ce qu'on observe : `/init` reçoit un nombre là où son code
// attend une adresse. Ce témoin note donc, pour chaque appel indirect par la
// mémoire, **d'où l'adresse a été lue et où elle menait** — de quoi comparer
// ensuite avec la table des symboles de la bibliothèque, qu'on a sur disque.
//
// **Il ne juge rien.** Un appel indirect par la mémoire est parfaitement
// ordinaire — c'est ainsi que toute liaison dynamique fonctionne. Le témoin
// rend la liste ; c'est à la comparaison de dire laquelle des cibles n'est le
// début d'aucune fonction.
extension X86Core {
    /// Un appel qui a pris son adresse en mémoire.
    public struct IndirectCall: Sendable, Equatable, Hashable {
        /// L'instruction qui appelle.
        public let at: UInt64
        /// La case lue — dans une liaison dynamique, une entrée de la table
        /// des globales.
        public let slot: UInt64
        /// Ce qu'on y a trouvé, et où l'on est donc allé.
        public let target: UInt64
        /// Vrai quand c'est un saut et non un appel : le tremplin de liaison
        /// est un `jmp *m`, et il compte autant.
        public let jumped: Bool

        public var description: String {
            String(format: "%@ à %llx par la case %llx vers %llx",
                   jumped ? "jmp" : "call", at, slot, target)
        }
    }

    /// Combien on en retient. Un démarrage en fait des milliers, mais ils se
    /// répètent : c'est la liste des **couples distincts** qui apprend quelque
    /// chose, pas leur nombre.
    public static let indirectCallLimit = 256

    /// À appeler juste après un `call *m` ou un `jmp *m` d'anneau trois.
    mutating func rememberIndirectCall(at: UInt64, slot: UInt64, jumped: Bool) {
        guard indirectCalls.count < Self.indirectCallLimit else { return }
        let seen = IndirectCall(at: at, slot: slot, target: rip, jumped: jumped)
        guard !indirectCalls.contains(seen) else { return }
        indirectCalls.append(seen)
    }

    /// Cette instruction prend-elle son adresse en mémoire, et pour aller où ?
    ///
    /// Seul le groupe 5 le fait : `/2` appelle, `/3` appelle au loin, `/4`
    /// saute, `/5` saute au loin. Les formes de registre (`mod == 3`) ne lisent
    /// rien en mémoire et ne nous apprennent rien sur une table.
    static func indirectThroughMemory(_ instruction: X86Instruction) -> Bool? {
        guard instruction.map == .oneByte, instruction.opcode == 0xFF,
              let modrm = instruction.modrm, (modrm >> 6) != 0b11
        else { return nil }
        switch (modrm >> 3) & 0x07 {
        case 2, 3: return false  // un appel
        case 4, 5: return true   // un saut
        default: return nil
        }
    }
}

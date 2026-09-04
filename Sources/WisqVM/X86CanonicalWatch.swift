import Foundation

// La surveillance des adresses non canoniques.
//
// **Pourquoi ce fichier existe.** Le vrai noyau d'Alpine démarre dans wisq
// jusqu'à l'espace utilisateur, et `/init` y meurt d'une faute de segment que
// la même image, sous QEMU, ne produit pas. La valeur fautive est toujours de
// la même forme : les quarante-huit bits du bas ressemblent à un pointeur
// parfaitement ordinaire, et des bits sont posés au-dessus.
//
//     RDI: 00037cde165f7280   ← ce qui a fait mourir feof
//     RDX: 00007f89e85118a0   ← à quoi ressemble un pointeur de la musl
//
// Un processeur ne dit rien quand un registre porte une telle valeur : ce
// n'est une faute qu'au moment où on s'en sert comme adresse. C'est bien le
// problème — au moment où la faute se voit, l'instruction qui a fabriqué la
// valeur est loin derrière, et le noyau n'imprime que la fin de l'histoire.
//
// **Ce fichier ne change donc rien à l'architecture.** Il ajoute un témoin :
// quand on le lui demande, le cœur regarde après chaque instruction d'anneau
// trois si un registre vient d'acquérir une valeur non canonique, et retient
// laquelle, où, et avec quels octets. C'est un instrument de mesure, pas une
// règle du processeur, et il est éteint par défaut.
extension X86Core {
    /// Une adresse est canonique quand les bits 63 à 48 répètent le bit 47.
    ///
    /// C'est la règle qui fait qu'un espace d'adressage de soixante-quatre
    /// bits n'en utilise que quarante-huit : les adresses licites sont les
    /// deux moitiés extrêmes, celle des programmes en bas et celle du noyau en
    /// haut, avec un trou immense entre les deux. Une valeur qui tombe dans le
    /// trou n'est l'adresse de rien.
    @inline(__always)
    public static func isCanonical(_ value: UInt64) -> Bool {
        let top = value >> 47
        return top == 0 || top == 0x1FFFF
    }

    /// Ce qu'on retient d'une valeur non canonique apparue en anneau trois.
    public struct NonCanonical: Sendable, Equatable {
        /// L'adresse de l'instruction qui vient de s'exécuter — la coupable.
        public let rip: UInt64
        /// Ses octets, pour qu'on puisse la désassembler sans la relire dans
        /// une mémoire qui aura changé.
        public let bytes: [UInt8]
        /// Lequel des seize registres, dans l'ordre de l'encodage.
        public let register: Int
        public let before: UInt64
        public let after: UInt64
        /// Combien d'instructions avaient été retirées, pour situer.
        public let retired: UInt64

        public static let names = [
            "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
            "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
        ]

        public var description: String {
            String(format: "%@ : %@ %llx devenu %llx, à rip=%llx après %llu instructions",
                   Self.names[register], "non canonique", before, after, rip, retired)
        }
    }

    /// Ce que le témoin a vu, dans l'ordre, jusqu'à `nonCanonicalLimit`.
    ///
    /// Une borne, parce qu'une fois la première valeur fabriquée elle se
    /// recopie de registre en registre : sans plafond, le rapport ferait des
    /// milliers de lignes qui disent toutes la même chose, et la première —
    /// la seule qui compte — serait noyée.
    public static let nonCanonicalLimit = 32

    /// À appeler juste après une instruction, avec les registres d'avant.
    ///
    /// Rien n'est signalé quand la valeur d'avant était **déjà** non
    /// canonique : ce registre-là ne fait que transporter une corruption
    /// venue d'ailleurs, et c'est l'endroit où elle naît qu'on cherche.
    mutating func noteNonCanonical(before: [UInt64], rip entry: UInt64, _ bytes: [UInt8]) {
        guard nonCanonicalSeen.count < Self.nonCanonicalLimit else { return }
        for index in 0..<16 where !Self.isCanonical(registers[index]) {
            guard Self.isCanonical(before[index]) else { continue }
            nonCanonicalSeen.append(NonCanonical(
                rip: entry, bytes: bytes, register: index,
                before: before[index], after: registers[index], retired: retired))
            if nonCanonicalSeen.count >= Self.nonCanonicalLimit { return }
        }
    }
}

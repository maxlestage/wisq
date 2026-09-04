import Foundation

// La surveillance des adresses non canoniques.
//
// **Pourquoi ce fichier existe.** Le vrai noyau d'Alpine démarre dans wisq
// jusqu'à l'espace utilisateur, et `/init` y meurt d'une faute de segment que
// la même image, sous QEMU, ne produit pas. La valeur fautive a toujours la
// même forme : les quarante-huit bits du bas ressemblent à un pointeur
// ordinaire, et des bits sont posés au-dessus.
//
//     RDI: 00037cde165f7280   ← ce qui a fait mourir feof
//     RDX: 00007f89e85118a0   ← à quoi ressemble un pointeur de la musl
//
// Le noyau n'imprime que la fin de l'histoire : les registres au moment de
// mourir, jamais l'instruction qui a fabriqué la valeur.
//
// **La première version de ce témoin signalait tout registre qui acquérait une
// valeur non canonique en anneau trois. Elle était inutilisable**, et la
// mesure l'a dit tout de suite : elle a rempli son rapport en trente-deux
// lignes avec le filtre de Bloom du chargeur dynamique — un `shl %cl, %r12`
// qui fabrique `1 << 61`, un `mov 0x10(%rsi,%rax,8), %rax` qui lit un mot de
// hachage. Ce sont des masques de bits, pas des adresses, et rien dans un
// registre ne dit lequel des deux il est.
//
// **Ce qui distingue les deux, c'est l'usage.** Une valeur n'est une adresse
// qu'au moment où on s'en sert comme telle. Le témoin ne regarde donc plus les
// registres : il attend qu'une adresse non canonique soit **employée** en
// anneau trois — ce qui n'arrive qu'une fois, à la mort — et rend alors, pour
// chaque registre qui en porte une, l'adresse de l'instruction qui l'y a mise.
// Il remonte de la mort à la naissance, en une ligne, sans bruit.
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

    /// L'acte de naissance d'une valeur : le registre, ce qu'il porte, et
    /// l'adresse de l'instruction qui l'y a mise.
    public struct Birth: Sendable, Equatable {
        public let register: Int
        public let value: UInt64
        /// Zéro quand aucune instruction d'anneau trois ne l'a écrit depuis
        /// que le témoin est armé — la valeur vient d'avant, ou du noyau.
        public let bornAt: UInt64
    }

    /// Ce qu'on retient du moment où une adresse non canonique est employée.
    public struct NonCanonical: Sendable, Equatable {
        /// L'adresse que l'instruction a essayé d'atteindre.
        public let address: UInt64
        /// L'instruction qui s'en est servie.
        public let rip: UInt64
        /// Combien d'instructions avaient été retirées, pour situer.
        public let retired: UInt64
        /// Tous les registres qui portent une valeur non canonique à cet
        /// instant, avec l'endroit où chacune est née.
        public let carrying: [Birth]

        public static let names = [
            "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
            "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
        ]

        public var description: String {
            let born = carrying.map {
                String(format: "%@=%llx né à %llx", Self.names[$0.register],
                       $0.value, $0.bornAt)
            }.joined(separator: ", ")
            return String(format: "adresse %llx employée par rip=%llx après %llu instructions",
                          address, rip, retired)
                + (born.isEmpty ? "" : " — " + born)
        }
    }

    /// Le plafond du rapport. L'événement est censé n'arriver qu'une fois ;
    /// quelques lignes suffisent si le programme insiste.
    public static let nonCanonicalLimit = 8

    /// À appeler juste après une instruction d'anneau trois, avec les
    /// registres d'avant : chaque registre qui a changé note ici l'adresse de
    /// l'instruction qui l'a écrit.
    mutating func rememberBirths(before: [UInt64], rip entry: UInt64) {
        for index in 0..<16 where registers[index] != before[index] {
            registerBornAt[index] = entry
        }
    }

    /// À appeler quand une traduction d'anneau trois porte sur une adresse
    /// non canonique. C'est le seul déclencheur : une valeur n'est une adresse
    /// qu'au moment où on s'en sert comme telle.
    mutating func noteNonCanonical(address: UInt64) {
        guard nonCanonicalSeen.count < Self.nonCanonicalLimit else { return }
        let carrying = (0..<16).compactMap { index -> Birth? in
            guard !Self.isCanonical(registers[index]) else { return nil }
            return Birth(register: index, value: registers[index],
                         bornAt: registerBornAt[index])
        }
        nonCanonicalSeen.append(NonCanonical(
            address: address, rip: rip, retired: retired, carrying: carrying))
    }
}

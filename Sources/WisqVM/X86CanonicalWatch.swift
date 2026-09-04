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

    /// La première page n'est **jamais** cartographiée pour un programme.
    ///
    /// Linux l'interdit même explicitement (`mmap_min_addr`), et c'est ce qui
    /// fait qu'un pointeur nul se plaint au lieu de lire n'importe quoi. Un
    /// programme qui déréférence une adresse là-dedans a lu un pointeur qui
    /// n'a jamais été écrit, ou qui a été effacé.
    public static let firstPage: UInt64 = 0x1000

    /// Une adresse qu'un programme peut avoir voulu atteindre.
    ///
    /// **C'est le prédicat, et il a grandi une fois.** Il ne demandait d'abord
    /// que la forme canonique, parce que la corruption d'alors posait des bits
    /// au-dessus du bit 47. Une fois celle-là corrigée, `/init` mourait encore
    /// — mais sur `segfault at 0`, `at 1`, `at 199`. Zéro est parfaitement
    /// canonique ; le témoin ne pouvait rien en dire, et il fallait le lui
    /// apprendre.
    @inline(__always)
    public static func isAddressable(_ value: UInt64) -> Bool {
        isCanonical(value) && value >= firstPage
    }

    /// L'acte de naissance d'une valeur : le registre, ce qu'il porte, et
    /// l'adresse de l'instruction qui l'y a mise.
    public struct Birth: Sendable, Equatable {
        public let register: Int
        public let value: UInt64
        /// Zéro quand aucune instruction d'anneau trois ne l'a écrit depuis
        /// que le témoin est armé — la valeur vient d'avant, ou du noyau.
        public let bornAt: UInt64
        /// Les octets qui sont à cette adresse, pour qu'on puisse la
        /// désassembler. Vide quand elle n'est plus lisible.
        public let bornBytes: [UInt8]
    }

    /// Ce qu'on retient du moment où une adresse non canonique est employée.
    public struct NonCanonical: Sendable, Equatable {
        /// L'adresse que l'instruction a essayé d'atteindre.
        public let address: UInt64
        /// L'instruction qui s'en est servie.
        public let rip: UInt64
        /// La dernière instruction d'anneau trois qui a abouti avant celle-là,
        /// et ses octets. Quand l'adresse fautive **est** RIP, c'est un saut
        /// parti dans le décor, et c'est cette instruction-là qui a sauté.
        public let cameFrom: UInt64
        public let cameFromBytes: [UInt8]
        /// Combien d'instructions avaient été retirées, pour situer.
        public let retired: UInt64
        /// Tous les registres qui portent une valeur non canonique à cet
        /// instant, avec l'endroit où chacune est née.
        public let carrying: [Birth]

        static func hex(_ bytes: [UInt8]) -> String {
            bytes.map { String(format: "%02x", $0) }.joined()
        }

        public static let names = [
            "rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi",
            "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
        ]

        public var description: String {
            let born = carrying.map {
                String(format: "%@=%llx né à %llx [%@]", Self.names[$0.register],
                       $0.value, $0.bornAt, Self.hex($0.bornBytes))
            }.joined(separator: ", ")
            let previous = String(format: " ; venue de %llx [%@]", cameFrom, Self.hex(cameFromBytes))
            return String(format: "adresse %llx employée par rip=%llx après %llu instructions",
                          address, rip, retired)
                + (born.isEmpty ? "" : " — " + born) + previous
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
        // **Le témoin s'éteint pendant qu'il écrit son rapport.** Relire les
        // octets d'une adresse passe par la traduction, donc par l'endroit
        // même d'où l'on vient : sans ça, un rapport en déclencherait un autre.
        canonicalWatchArmed = false
        defer { canonicalWatchArmed = true }
        // **Le registre doit avoir servi à former l'adresse**, pas seulement
        // porter une valeur impossible. Une adresse se calcule comme
        // « registre plus déplacement », et un déplacement de structure tient
        // dans une page : on ne retient donc que les registres dont la valeur
        // est à moins de quatre kibioctets en dessous de l'adresse employée.
        //
        // Sans cette condition, élargir le prédicat aux pointeurs nuls faisait
        // accuser les seize registres d'un coup, puisque zéro n'est pas une
        // adresse et que la moitié d'un fichier de registres vaut zéro à tout
        // instant. C'est la deuxième fois que ce témoin apprend la même
        // leçon : ce qui compte n'est pas la valeur, c'est son emploi.
        let carrying = (0..<16).compactMap { index -> Birth? in
            let value = registers[index]
            guard !Self.isAddressable(value), address &- value < Self.firstPage else {
                return nil
            }
            return Birth(register: index, value: value,
                         bornAt: registerBornAt[index],
                         bornBytes: peek(registerBornAt[index]))
        }
        nonCanonicalSeen.append(NonCanonical(
            address: address, rip: rip, cameFrom: previousRip,
            cameFromBytes: peek(previousRip), retired: retired, carrying: carrying))
    }

    /// Les octets d'une adresse de l'invité, ou rien du tout si elle n'est
    /// plus lisible. Un témoin qui lèverait en rendant compte serait pire que
    /// pas de témoin.
    mutating func peek(_ address: UInt64, _ count: Int = 12) -> [UInt8] {
        guard address != 0, let memory else { return [] }
        guard let physical = try? translate(address),
              let start = memory.offset(physical, 1)
        else { return [] }
        let available = min(count, memory.size - start)
        guard available > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: memory.bytes + start, count: available))
    }
}

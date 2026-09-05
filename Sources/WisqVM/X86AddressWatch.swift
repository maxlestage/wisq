import Foundation

// **Qui a touché cette adresse ?**
//
// Le témoin des adresses impossibles nomme désormais l'endroit d'où un
// pointeur nul a été *lu* : `mov 0x28(%r12),%rdi`, depuis `7ffce0ef1e08`. Une
// adresse de **pile**, donc une variable locale, et non un objet du tas comme
// je l'avais supposé.
//
// **Et la comparaison avec la référence a tranché ce qui restait ambigu.** Le
// même noyau et le même initramfs, sous QEMU, sans média de démarrage : «
// Mounting boot media: failed » aussi — c'est donc attendu, cette machine n'a
// pas de média — mais **zéro segfault**, et un shell de secours qui s'ouvre.
// Le plantage est bien le nôtre, et il n'est pas la conséquence d'une machine
// mal équipée.
//
// Reste à savoir qui a mis ce zéro là, ou qui aurait dû y mettre autre chose.
// Ce témoin le dit : armé sur une adresse, il note chaque lecture et chaque
// écriture d'anneau trois qui la touche, avec l'instruction et le compteur.
//
// **Il ne s'arme que par l'environnement**, parce que l'adresse n'est connue
// qu'après une première mesure : `WISQ_PC_WATCH_ADDRESS`. C'est la même
// méthode en deux passes qui a servi pour la pile — une mesure nomme la
// cible, la suivante la surveille.
//
// **Et il surveille une plage, pas une case.** La première version n'en
// gardait qu'une, et la mesure a montré la limite : le zéro fautif est le
// champ `wpos` d'une structure, mais la question devenue décisive — « d'où
// vient ce zéro ? » — porte sur `buf` et `buf_size`, deux champs *voisins*
// qu'il faut lire ensemble. Surveiller l'un puis l'autre demanderait deux
// démarrages de six milliards d'instructions, et les deux histoires ne
// seraient pas apparieables. La plage les met sur la même ligne du temps.
//
// La longueur se donne après un `+` : `WISQ_PC_WATCH_ADDRESS=7ffc1234+10`
// surveille seize octets. Sans elle, c'est huit — le comportement d'avant.
extension X86Core {
    /// Ce qu'on retient d'un passage sur l'adresse surveillée.
    public struct AddressTouch: Sendable, Equatable {
        public let at: UInt64
        public let writing: Bool
        public let retired: UInt64
        /// Où dans la plage, depuis son début. Zéro quand on ne surveille
        /// qu'une case, et le déplacement du champ quand c'est une structure.
        public let offset: UInt64
        /// La valeur qui s'y trouvait **avant** l'accès. Pour une écriture,
        /// c'est ce qu'on écrase ; pour une lecture, c'est ce qu'on obtient.
        public let before: UInt64

        static let none = AddressTouch(at: 0, writing: false, retired: 0,
                                       offset: 0, before: 0)

        public var description: String {
            String(format: "%@ %+llx à %llx — valeur avant %llx,"
                   + " après %llu instructions",
                   writing ? "écrit" : "lit", offset, at, before, retired)
        }
    }

    /// Combien de passages on garde, **et ce sont les derniers**.
    ///
    /// Le premier jet gardait les premiers, et la mesure l'a démoli en une
    /// exécution : la case surveillée est une variable locale réutilisée à
    /// chaque appel, et les soixante-quatre premiers passages tombaient dix-neuf
    /// millions d'instructions avant la faute. C'est la même leçon que le
    /// registre des mouvements de pile a déjà enseignée — ce qui compte est ce
    /// qui précède l'événement, pas ce qui ouvre la course.
    /// La profondeur **par défaut**. Elle se change en redimensionnant
    /// `addressTouches` avant de lancer : soixante-quatre suffisait tant qu'on
    /// surveillait une seule case, et ne suffit plus pour une structure.
    ///
    /// **Ce n'est pas un détail de confort.** Deux mesures d'un même
    /// démarrage, l'une sur `wpos` et l'autre sur `buf`, se sont contredites —
    /// et les deux tampons étaient pleins. Chacune ne voyait qu'une fenêtre de
    /// quelques milliers d'instructions, et les deux fenêtres ne se
    /// recouvraient pas. Deux fenêtres disjointes ne se recollent pas : il
    /// faut tout voir d'un coup, ou l'on raconte.
    public static let addressTouchLimit = 64

    /// Les passages gardés, du plus ancien au plus récent.
    public var addressTouched: [AddressTouch] {
        Array(addressTouches[addressTouchNext...]) + Array(addressTouches[..<addressTouchNext])
    }

    mutating func noteAddressTouch(_ virtual: UInt64, writing: Bool) {
        let start = watchedAddress ?? virtual
        // Le témoin s'éteint pendant qu'il lit : relire passe par la
        // traduction, donc par l'endroit d'où l'on vient.
        let watched = watchedAddress
        watchedAddress = nil
        defer { watchedAddress = watched }
        // `try?` aplatit déjà l'option de `memory?` : un `?? nil` de plus ne
        // dirait rien, et SwiftLint le refuse.
        let before = try? readMemory(virtual, 8)
        addressTouches[addressTouchNext] = AddressTouch(
            at: rip, writing: writing, retired: retired,
            offset: virtual &- start, before: before ?? 0)
        addressTouchNext = (addressTouchNext + 1) % addressTouches.count
    }
}

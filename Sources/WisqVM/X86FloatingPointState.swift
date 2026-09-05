import Foundation

// **La zone de 512 octets que le noyau croit lui rendre son état.**
//
// `FXSAVE` et `FXRSTOR` sont le seul endroit où l'état de la virgule flottante
// traverse un changement de contexte. Ce cœur les avait, et ils écrivaient les
// trois mots de contrôle en mettant **le reste à zéro** — les huit registres
// x87 et les seize XMM. Le commentaire disait pourquoi c'était acceptable :
// « rien ici ne calcule en virgule flottante ».
//
// **Cette prémisse a cessé d'être vraie, et c'est ce qui tuait `/init`.** Le
// SSE2 entier, le flottant scalaire et la pile x87 sont arrivés dans ce cœur ;
// l'invité s'en sert. La mesure l'a nommé sans ambiguïté, dans `__towrite` de
// musl :
//
//     4eef3: movq %rax,%xmm1          ; xmm1 = f->buf
//     4eef8: mov  %rax,0x38(%rdi)     ; ← retirée à 3 014 972 293
//     4eefe: movq %rcx,%xmm0          ; xmm0 = buf + buf_size
//     4ef03: punpcklqdq %xmm1,%xmm0
//     4ef07: movups %xmm0,0x20(%rdi)  ; ← retirée à 3 015 131 175
//
// Quinze octets en ligne droite, et **158 882 instructions** entre les deux :
// le noyau est passé par là. Au retour, `wend` — la moitié basse, venue d'un
// registre reposé *après* la coupure — est juste, et `wpos` — la moitié haute,
// venue de `xmm1`, posé *avant* — vaut zéro. Le noyau partage le banc de
// registres, il a écrasé `xmm1`, et `FXRSTOR` ne le rendait pas.
//
// Ce zéro-là part ensuite en destination d'un `memcpy` dans `__fwritex`, et
// c'est le `rep movsq` vers l'adresse zéro qui tue `nlplug-findfs`.
//
// **Deux pièges de format, écrits ici pour ne pas les redécouvrir.** Les huit
// registres x87 sont rangés dans **l'ordre de la pile** — ST(0) d'abord —
// alors que le mot d'étiquettes abrégé est dans **l'ordre physique**. Et ce
// mot n'a qu'un bit par registre là où le processeur en tient deux : `FXRSTOR`
// doit donc reconstruire les quatre états depuis « vide ou pas » **et la
// valeur** relue.
extension X86Core {
    /// Où chaque chose vit dans les 512 octets.
    enum FloatingPointArea {
        static let control = 0
        static let status = 2
        static let abridgedTags = 4
        static let mxcsr = 24
        static let mxcsrMask = 28
        static let stack = 32
        static let vectors = 160
        /// **Ce que `FXSAVE` écrit vraiment.** La zone fait 512 octets, mais
        /// l'instruction n'en touche que 416 : les quatre-vingt-seize derniers
        /// sont laissés tels quels. Mesuré, pas lu — un programme qui remplit
        /// la zone de `0xCC` avant l'instruction les retrouve intacts.
        static let written = 416
        static let size = 512
        /// Un registre, x87 comme XMM, occupe seize octets dans la zone.
        static let slot = 16
    }

    /// Le mot d'étiquettes tel que `FXSAVE` l'écrit : un bit par registre
    /// **physique**, levé quand le registre n'est pas vide.
    ///
    /// L'ordre est mesuré et non lu : avec le sommet à trois et le seul bit
    /// zéro levé, `FXAM` rend « vide » sur `ST(0)` — qui est le registre
    /// physique trois. Les emplacements, eux, sont en ordre de **pile**.
    /// Deux conventions dans la même zone de 512 octets.
    var abridgedTagWord: UInt8 {
        var word: UInt8 = 0
        for physical in 0..<8 where (x87Tags >> UInt16(2 * physical)) & 0b11 != 0b11 {
            word |= UInt8(1 << physical)
        }
        return word
    }

    mutating func saveFloatingPointState() throws {
        guard memory != nil else { throw Fault.unsupported("FXSAVE sans mémoire") }
        let base = lastAddress
        // Les octets réservés doivent partir à zéro : un noyau qui relit la
        // zone avec `XRSTOR` refuse un état qu'il ne reconnaît pas.
        for offset in stride(from: 0, to: FloatingPointArea.written, by: 8) {
            try writeMemory(base &+ UInt64(offset), 8, 0)
        }
        func put(_ offset: Int, _ width: Int, _ value: UInt64) throws {
            try writeMemory(base &+ UInt64(offset), width, value)
        }
        // Le sommet de pile vit dans les bits 11 à 13 du mot d'état : l'écrire
        // tel quel suffit à le porter.
        try put(FloatingPointArea.control, 2, UInt64(x87Control))
        try put(FloatingPointArea.status, 2, UInt64(x87Status))
        try put(FloatingPointArea.abridgedTags, 1, UInt64(abridgedTagWord))
        try put(FloatingPointArea.mxcsr, 4, UInt64(mxcsr))
        // Le masque des bits de MXCSR qu'un processeur accepte. Zéro voudrait
        // dire « aucun », et Linux le prend au mot.
        try put(FloatingPointArea.mxcsrMask, 4, 0xFFFF)

        for index in 0..<8 {
            let value = stack(index)  // ST(index), et non le registre physique
            let at = FloatingPointArea.stack + FloatingPointArea.slot * index
            try put(at, 8, value.significand)
            try put(at + 8, 2, UInt64(value.signExponent))
        }
        for index in 0..<16 {
            let at = FloatingPointArea.vectors + FloatingPointArea.slot * index
            try put(at, 8, vectors[2 * index])
            try put(at + 8, 8, vectors[2 * index + 1])
        }
    }

    mutating func restoreFloatingPointState() throws {
        guard memory != nil else { throw Fault.unsupported("FXRSTOR sans mémoire") }
        let base = lastAddress
        func get(_ offset: Int, _ width: Int) throws -> UInt64 {
            try readMemory(base &+ UInt64(offset), width)
        }
        // **Le bit 6 du mot de contrôle revient toujours levé.** Le manuel le
        // dit « réservé » et n'en promet rien ; le processeur, lui, le force,
        // et le corpus l'a montré sur 208 cas d'un coup. Un état réservé qu'on
        // laisse à zéro est un état que la machine n'aurait jamais rendu.
        //
        // Le corpus ne peut pas dire *où* le processeur le lève — au
        // chargement ou à l'écriture — parce qu'un aller-retour ne sépare pas
        // les deux. On le lève ici, à l'entrée, parce que c'est là que la
        // valeur devient l'état de la machine.
        x87Control = UInt16(truncatingIfNeeded: try get(FloatingPointArea.control, 2)) | 0x40
        // Le mot d'état porte le sommet : il faut donc le poser **avant** de
        // ranger les registres, sans quoi `ST(0)` ne désigne pas le bon.
        x87Status = UInt16(truncatingIfNeeded: try get(FloatingPointArea.status, 2))
        // **Deux bits du mot d'état ne se chargent pas : ils se calculent.**
        // ES — le résumé d'erreur, bit 7 — vaut « une exception en attente
        // n'est pas masquée », et B — bit 15 — le recopie. Le corpus l'a
        // montré dans les deux sens : un ES posé dans l'image que le
        // processeur efface, et un B absent qu'il lève.
        //
        // C'est pour ça que les charger tels quels était faux : ils ne
        // décrivent pas un état, ils **résument** l'état voisin, et un résumé
        // qui ne suit pas ce qu'il résume est un mensonge que le noyau croit.
        let pending = (x87Status & 0x3F) & ~(x87Control & 0x3F)
        x87Status = pending != 0 ? (x87Status | 0x8080) : (x87Status & ~0x8080)
        let abridged = UInt8(truncatingIfNeeded: try get(FloatingPointArea.abridgedTags, 1))
        mxcsr = UInt32(truncatingIfNeeded: try get(FloatingPointArea.mxcsr, 4))

        for index in 0..<8 {
            let at = FloatingPointArea.stack + FloatingPointArea.slot * index
            let value = X86Extended(
                significand: try get(at, 8),
                signExponent: UInt16(truncatingIfNeeded: try get(at + 8, 2)))
            x87[(x87TopIndex + index) & 7] = value
        }
        // Puis les étiquettes, reconstruites : un bit éteint veut dire vide, et
        // un bit allumé demande de relire la valeur pour savoir *lequel* des
        // trois autres états elle porte.
        for physical in 0..<8 {
            let occupied = abridged & UInt8(1 << physical) != 0
            markTag(physical, occupied ? Self.tag(for: x87[physical]) : 0b11)
        }
        for index in 0..<16 {
            let at = FloatingPointArea.vectors + FloatingPointArea.slot * index
            vectors[2 * index] = try get(at, 8)
            vectors[2 * index + 1] = try get(at + 8, 8)
        }
    }
}

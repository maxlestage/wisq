/// **La mémoire derrière l'écran que le chargeur a déclaré.**
///
/// `X86BootLoader.Framebuffer` dit au noyau *où* peindre ; ce fichier tient
/// l'endroit. Il vit **derrière** la RAM, comme le disque : une fenêtre qu'une
/// adresse ordinaire ne rencontre jamais, donc rien à payer sur le chemin
/// chaud. Une adresse hors RAM tombe dans le repli, et c'est là qu'on regarde
/// si elle est à nous.
///
/// **Pourquoi pas de la RAM ordinaire.** On pourrait tailler le cadre dans le
/// haut de la mémoire invitée et laisser les écritures suivre le chemin
/// normal. Ce serait plus rapide d'une comparaison, et ça coûterait deux
/// choses : l'hôte devrait connaître la carte mémoire pour retrouver ses
/// pixels, et rien ne saurait dire *quand* l'image a changé. Le compteur de
/// révision ci-dessous n'existe que parce que le cadre est un objet, et il
/// évite à une vue de repeindre soixante fois par seconde une image
/// identique — sur un téléphone, ça se paie en batterie.
public final class X86Framebuffer: @unchecked Sendable {
    /// L'adresse physique invitée du premier pixel.
    public let base: UInt64
    public let width: Int
    public let height: Int

    /// XRGB8888 : quatre octets par pixel, pas de remplissage en fin de ligne.
    /// C'est le format que `simpledrm` prend sans conversion côté invité, et
    /// que Core Graphics et Metal prennent sans conversion côté hôte.
    public var bytesPerRow: Int { width * 4 }
    public var byteCount: Int { bytesPerRow * height }

    /// **Combien de fois l'image a changé.** Une vue compare ce nombre au
    /// sien : égal, elle ne redessine rien.
    public private(set) var revision: UInt64 = 0

    private let pixels: UnsafeMutablePointer<UInt8>

    public init(base: UInt64, width: Int, height: Int) {
        self.base = base
        self.width = max(width, 1)
        self.height = max(height, 1)
        let count = self.width * self.height * 4
        pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        pixels.initialize(repeating: 0, count: count)
    }

    deinit { pixels.deallocate() }

    /// Le décalage dans le cadre, ou nil si l'adresse est ailleurs.
    ///
    /// **La fenêtre s'arrête exactement à la fin du cadre.** Un octet de trop
    /// et une écriture perdue deviendrait silencieuse, au lieu de lever la
    /// faute qui la ferait remarquer.
    @inline(__always)
    func offset(_ address: UInt64, _ width: Int) -> Int? {
        guard address >= base else { return nil }
        let index = address &- base
        guard index <= UInt64(byteCount - width) else { return nil }
        return Int(index)
    }

    @inline(__always)
    func read(_ at: Int, _ width: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in 0..<width { value |= UInt64(pixels[at + byte]) << (8 * UInt64(byte)) }
        return value
    }

    @inline(__always)
    func write(_ at: Int, _ width: Int, _ value: UInt64) {
        for byte in 0..<width {
            pixels[at + byte] = UInt8((value >> (8 * UInt64(byte))) & 0xFF)
        }
        revision &+= 1
    }

    /// L'image telle qu'elle est, copiée. C'est ce qu'une vue affiche.
    public func snapshot() -> [UInt8] {
        Array(UnsafeBufferPointer(start: pixels, count: byteCount))
    }
}

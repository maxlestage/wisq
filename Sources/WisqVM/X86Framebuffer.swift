import Foundation

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
    ///
    /// **Une largeur plus grande que le cadre n'y tient pas**, et le dit : la
    /// copie d'un bloc (`X86Core.bulkString`) demande jusqu'à une page entière,
    /// et un cadre minuscule — un pixel, dans un test — rendait `byteCount -
    /// width` négatif, une conversion qui arrête le programme.
    @inline(__always)
    func offset(_ address: UInt64, _ width: Int) -> Int? {
        guard address >= base, width <= byteCount else { return nil }
        let index = address &- base
        guard index <= UInt64(byteCount - width) else { return nil }
        return Int(index)
    }

    /// **Un chargement, pas une boucle d'octets**, comme la RAM : le cadre est
    /// petit-boutien comme l'invité et l'hôte. La boucle reste pour les
    /// largeurs impaires, que seuls les accès à cheval sur une page demandent.
    @inline(__always)
    func read(_ at: Int, _ width: Int) -> UInt64 {
        let place = UnsafeRawPointer(pixels + at)
        switch width {
        case 4: return UInt64(UInt32(littleEndian: place.loadUnaligned(as: UInt32.self)))
        case 8: return UInt64(littleEndian: place.loadUnaligned(as: UInt64.self))
        case 2: return UInt64(UInt16(littleEndian: place.loadUnaligned(as: UInt16.self)))
        case 1: return UInt64(pixels[at])
        default:
            var value: UInt64 = 0
            for byte in 0..<width { value |= UInt64(pixels[at + byte]) << (8 * UInt64(byte)) }
            return value
        }
    }

    @inline(__always)
    func write(_ at: Int, _ width: Int, _ value: UInt64) {
        let place = UnsafeMutableRawPointer(pixels + at)
        switch width {
        case 4: place.storeBytes(of: UInt32(truncatingIfNeeded: value).littleEndian, as: UInt32.self)
        case 8: place.storeBytes(of: value.littleEndian, as: UInt64.self)
        case 2: place.storeBytes(of: UInt16(truncatingIfNeeded: value).littleEndian, as: UInt16.self)
        case 1: pixels[at] = UInt8(truncatingIfNeeded: value)
        default:
            for byte in 0..<width {
                pixels[at + byte] = UInt8((value >> (8 * UInt64(byte))) & 0xFF)
            }
        }
        revision &+= 1
    }

    /// **Les pixels eux-mêmes, pour une copie d'un bloc** : `X86Core.bulkString`
    /// y copie une ligne entière d'un coup, et dit ensuite qu'il l'a fait
    /// (`touch`), puisque `write` n'y est pas passé.
    var bytes: UnsafeMutablePointer<UInt8> { pixels }

    /// Une écriture faite directement dans `bytes` : la vue doit repeindre.
    func touch() { revision &+= 1 }

    /// L'image telle qu'elle est, copiée. C'est ce qu'une vue affiche.
    public func snapshot() -> [UInt8] {
        Array(UnsafeBufferPointer(start: pixels, count: byteCount))
    }

    /// **La même image, en une seule copie.** La vue en fait un `CGImage`
    /// trente fois par seconde : `Data(snapshot())` copiait les trois mégaoctets
    /// d'un écran 1024 × 768 deux fois, sur le fil principal, à chaque image.
    public func pixelData() -> Data {
        Data(bytes: pixels, count: byteCount)
    }

    /// Les pixels en lecture, sans copie : pour l'instantané de la machine.
    func withPixels<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeRawBufferPointer(start: pixels, count: byteCount))
    }

    /// Les pixels remplacés d'un coup, à la reprise. La révision avance : une
    /// vue qui regardait l'écran d'avant repeint.
    func replacePixels(_ body: (UnsafeMutableRawBufferPointer) throws -> Void) rethrows {
        try body(UnsafeMutableRawBufferPointer(start: pixels, count: byteCount))
        revision &+= 1
    }
}

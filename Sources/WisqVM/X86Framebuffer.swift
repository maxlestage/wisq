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
    /// L'adresse physique invitée du premier octet de la mémoire vidéo. Elle
    /// bouge si le noyau déplace la BAR0 de la carte (`X86BochsDisplay`).
    public private(set) var base: UInt64

    /// **Ce que l'écran montre** : un rectangle de la mémoire vidéo. Au
    /// démarrage, le cadre déclaré au noyau (`bootMode`), à l'adresse zéro et
    /// sans remplissage ; ensuite, ce que le pilote de la carte choisit.
    ///
    /// XRGB8888 : quatre octets par pixel. C'est le format que `simpledrm` et
    /// `bochs-drm` prennent sans conversion côté invité, et que Core Graphics
    /// et Metal prennent sans conversion côté hôte.
    public struct Mode: Equatable, Sendable {
        public let width: Int
        public let height: Int
        /// La longueur d'une ligne en mémoire : la largeur virtuelle, qui
        /// peut dépasser la largeur montrée.
        public let bytesPerRow: Int
        /// Le premier pixel montré, en octets depuis le début de la mémoire
        /// vidéo : c'est ce qui change quand un bureau passe d'un tampon à
        /// l'autre.
        public let start: Int

        public init(width: Int, height: Int, bytesPerRow: Int, start: Int) {
            self.width = width
            self.height = height
            self.bytesPerRow = bytesPerRow
            self.start = start
        }

        /// Ce que le mode lit de la mémoire, du premier pixel au dernier.
        var span: Int { bytesPerRow * (height - 1) + width * 4 }
    }

    /// Le cadre déclaré au noyau par le chargeur.
    public let bootMode: Mode

    /// La taille de la mémoire vidéo. Au moins celle du cadre du démarrage.
    public let memorySize: Int

    /// Le mode, sous son verrou : la vue le lit depuis le fil principal
    /// pendant que la carte le change sur le fil d'émulation, et une largeur
    /// lue avant le changement avec une hauteur lue après ferait une image de
    /// travers.
    private var currentMode: Mode
    private let modeLock = NSLock()

    /// Le mode affiché en ce moment.
    public var mode: Mode {
        modeLock.lock()
        defer { modeLock.unlock() }
        return currentMode
    }

    public var width: Int { mode.width }
    public var height: Int { mode.height }
    public var bytesPerRow: Int { mode.bytesPerRow }
    /// Les octets de l'image montrée, quatre par pixel, sans remplissage.
    public var byteCount: Int {
        let mode = mode
        return mode.width * mode.height * 4
    }

    /// **Combien de fois l'image a changé.** Une vue compare ce nombre au
    /// sien : égal, elle ne redessine rien.
    public private(set) var revision: UInt64 = 0

    private let pixels: UnsafeMutablePointer<UInt8>

    /// `memory` : la taille de la mémoire vidéo, celle du cadre du démarrage
    /// si elle n'est pas donnée (un écran sans carte).
    public init(base: UInt64, width: Int, height: Int, memory: Int? = nil) {
        self.base = base
        let boot = Mode(width: max(width, 1), height: max(height, 1), bytesPerRow: max(width, 1) * 4, start: 0)
        bootMode = boot
        currentMode = boot
        memorySize = max(memory ?? 0, boot.width * boot.height * 4)
        pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: memorySize)
        pixels.initialize(repeating: 0, count: memorySize)
    }

    deinit { pixels.deallocate() }

    /// **Un autre mode**, s'il tient dans la mémoire vidéo ; sinon rien ne
    /// change, et la réponse le dit. Un pilote qui demande plus qu'il n'y a
    /// ne doit pas faire lire à la vue au-delà des pixels.
    @discardableResult
    func setMode(_ mode: Mode) -> Bool {
        guard mode.width >= 1, mode.height >= 1, mode.bytesPerRow >= mode.width * 4, mode.start >= 0,
              mode.start + mode.span <= memorySize else { return false }
        modeLock.lock()
        let changed = currentMode != mode
        currentMode = mode
        modeLock.unlock()
        if changed { revision &+= 1 }
        return true
    }

    /// La mémoire vidéo déplacée : le noyau a reprogrammé la BAR0.
    func move(to base: UInt64) {
        self.base = base
    }

    /// Efface les `bytes` premiers octets de la mémoire vidéo : ce que fait
    /// la carte en changeant de mode.
    func clear(bytes: Int) {
        let count = min(max(bytes, 0), memorySize)
        pixels.update(repeating: 0, count: count)
        revision &+= 1
    }

    /// Le décalage dans la mémoire vidéo, ou nil si l'adresse est ailleurs.
    ///
    /// **La fenêtre s'arrête exactement à la fin de la mémoire vidéo.** Un octet de trop
    /// et une écriture perdue deviendrait silencieuse, au lieu de lever la
    /// faute qui la ferait remarquer.
    ///
    /// **Une largeur plus grande que le cadre n'y tient pas**, et le dit : la
    /// copie d'un bloc (`X86Core.bulkString`) demande jusqu'à une page entière,
    /// et un cadre minuscule — un pixel, dans un test — rendait `memorySize -
    /// width` négatif, une conversion qui arrête le programme.
    ///
    /// **La fenêtre est la mémoire vidéo entière**, pas l'image montrée : un
    /// bureau peint dans le tampon qu'il montrera ensuite.
    @inline(__always)
    func offset(_ address: UInt64, _ width: Int) -> Int? {
        guard address >= base, width <= memorySize else { return nil }
        let index = address &- base
        guard index <= UInt64(memorySize - width) else { return nil }
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

    /// L'image telle qu'elle est, copiée : le mode courant, ligne à ligne,
    /// sans remplissage. C'est ce qu'une vue affiche.
    public func snapshot() -> [UInt8] {
        [UInt8](frame().data)
    }

    /// **La même image, en une seule copie.** La vue en fait un `CGImage`
    /// trente fois par seconde : `Data(snapshot())` copiait les trois mégaoctets
    /// d'un écran 1024 × 768 deux fois, sur le fil principal, à chaque image.
    public func pixelData() -> Data {
        frame().data
    }

    /// **Le mode et son image, pris ensemble**, sous le verrou du mode : une
    /// vue qui lirait la taille puis les pixels pourrait tomber entre les
    /// deux sur un changement de résolution.
    public func frame() -> (mode: Mode, data: Data) {
        modeLock.lock()
        defer { modeLock.unlock() }
        let mode = currentMode
        let row = mode.width * 4
        if mode.bytesPerRow == row {
            return (mode, Data(bytes: pixels + mode.start, count: row * mode.height))
        }
        var data = Data(count: row * mode.height)
        data.withUnsafeMutableBytes { target in
            guard let destination = target.baseAddress else { return }
            for line in 0..<mode.height {
                (destination + line * row).copyMemory(from: pixels + mode.start + line * mode.bytesPerRow,
                                                      byteCount: row)
            }
        }
        return (mode, data)
    }

    /// La mémoire vidéo entière en lecture, sans copie : pour l'instantané de
    /// la machine.
    func withPixels<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) rethrows -> Result {
        try body(UnsafeRawBufferPointer(start: pixels, count: memorySize))
    }

    /// La mémoire vidéo remplacée d'un coup, à la reprise — ou seulement son
    /// début, pour un instantané d'avant la carte, qui ne portait que le
    /// cadre. La révision avance : une vue qui regardait l'écran d'avant
    /// repeint.
    func replacePixels(count: Int? = nil, _ body: (UnsafeMutableRawBufferPointer) throws -> Void) rethrows {
        try body(UnsafeMutableRawBufferPointer(start: pixels, count: min(count ?? memorySize, memorySize)))
        revision &+= 1
    }
}

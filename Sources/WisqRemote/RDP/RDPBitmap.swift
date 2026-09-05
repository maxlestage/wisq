import Foundation
import WisqCore

/// Les mises à jour d'écran : les rectangles que le serveur peint, et le codec
/// entrelacé qui les comprime.
public enum RDPBitmapUpdate {
    /// Le genre d'une mise à jour, dans les deux premiers octets.
    public enum Kind: UInt16, Sendable {
        case orders = 0
        case bitmap = 1
        case palette = 2
        case synchronise = 3
    }

    /// Un rectangle tel que le serveur l'annonce.
    public struct Rectangle: Equatable, Sendable {
        public var left: Int
        public var top: Int
        public var right: Int
        public var bottom: Int
        /// La largeur du bloc de pixels, qui n'est pas `right - left + 1` : le
        /// serveur arrondit la largeur au multiple qui l'arrange et laisse le
        /// rectangle de destination plus petit. Peindre le bloc entier ferait
        /// déborder de quelques pixels sur la droite.
        public var width: Int
        public var height: Int
        public var bitsPerPixel: Int
        public var compressed: Bool
        /// Les octets de pixels, en-tête de compression déjà retiré.
        public var data: Data
    }

    /// Combien de rectangles une mise à jour peut porter. Le champ en compte
    /// seize bits ; chaque rectangle coûte au moins dix-huit octets d'en-tête,
    /// donc soixante mille rectangles seraient un message d'un mégaoctet
    /// annoncé par quatre.
    static let rectangleLimit = 4096

    /// Lire le corps d'un PDU de mise à jour.
    public static func kind(of body: Data) throws -> Kind {
        let bytes = [UInt8](body)
        guard bytes.count >= 2 else {
            throw WisqError.malformedMessage("mise à jour tronquée")
        }
        let raw = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        guard let kind = Kind(rawValue: raw) else {
            throw WisqError.malformedMessage("mise à jour de genre \(raw)")
        }
        return kind
    }

    /// Les rectangles d'une mise à jour bitmap.
    ///
    /// **Chaque rectangle annonce la longueur de ses pixels, et c'est elle qui
    /// borne la lecture.** Un serveur qui en annonce plus qu'il n'envoie ferait
    /// lire le rectangle d'après, puis la mémoire d'après lui.
    public static func rectangles(_ body: Data) throws -> [Rectangle] {
        let bytes = [UInt8](body)
        guard try kind(of: body) == .bitmap else {
            throw WisqError.malformedMessage("cette mise à jour ne porte pas de bitmap")
        }
        guard bytes.count >= 4 else {
            throw WisqError.malformedMessage("mise à jour bitmap sans son compte")
        }
        let count = Int(bytes[2]) | Int(bytes[3]) << 8
        guard count <= rectangleLimit else {
            throw WisqError.malformedMessage("\(count) rectangles dans une seule mise à jour")
        }
        var out: [Rectangle] = []
        out.reserveCapacity(count)
        var at = 4
        for _ in 0..<count {
            guard at + 18 <= bytes.count else {
                throw WisqError.malformedMessage("rectangle sans son en-tête")
            }
            // **L'en-tête se lit depuis son propre début, pas depuis le
            // curseur.** Le curseur avance de dix-huit octets puis de la
            // longueur des pixels ; relire un champ après coup irait chercher
            // dans le rectangle suivant, ou hors du message.
            let start = at
            func field(_ offset: Int) -> Int {
                Int(bytes[start + offset]) | Int(bytes[start + offset + 1]) << 8
            }
            let flags = field(14)
            let length = field(16)
            at += 18
            guard at + length <= bytes.count else {
                throw WisqError.malformedMessage(
                    "rectangle qui annonce \(length) octets de pixels pour \(bytes.count - at) reçus")
            }
            var pixels = Data(bytes[at..<(at + length)])
            let compressed = flags & 0x0001 != 0
            // **L'en-tête de compression n'est pas toujours là.** Le drapeau
            // 0x0400 dit qu'il a été omis ; le lire quand même mangerait huit
            // octets de pixels, et l'image serait décalée sans erreur.
            if compressed, flags & 0x0400 == 0 {
                guard length >= 8 else {
                    throw WisqError.malformedMessage("en-tête de compression tronqué")
                }
                let main = Int(pixels[pixels.startIndex + 2]) | Int(pixels[pixels.startIndex + 3]) << 8
                guard main <= length - 8 else {
                    throw WisqError.malformedMessage(
                        "corps comprimé de \(main) octets dans \(length - 8) reçus")
                }
                pixels = pixels.dropFirst(8).prefix(main)
            }
            at += length
            out.append(Rectangle(left: field(0), top: field(2), right: field(4),
                                 bottom: field(6), width: field(8), height: field(10),
                                 bitsPerPixel: field(12), compressed: compressed,
                                 data: Data(pixels)))
        }
        return out
    }
}

/// Le codec entrelacé de RDP, celui que MS-RDPEGDI appelle « RLE ».
///
/// **Ce n'est pas un RLE ordinaire.** Deux tiers de ses codes ne décrivent pas
/// des pixels mais des différences avec la ligne du dessus : un « fond » recopie
/// la ligne précédente, une « forme » la recopie en inversant une couleur, et un
/// masque d'un bit par pixel choisit entre les deux. Un décodeur qui traiterait
/// tout comme des couleurs littérales produirait une image plausible sur la
/// première ligne et du bruit sur les suivantes.
public enum RDPInterleavedRLE {
    /// Les octets par pixel que ce codec sait produire.
    ///
    /// **Deux profondeurs manquent, et pour deux raisons différentes.** Le 32
    /// bits emploie un autre codec — planaire — et le confondre donnerait des
    /// couleurs fausses plutôt qu'une erreur. Le 8 bits, lui, ne porte pas des
    /// couleurs mais des index dans une palette que wisq ne tient pas : le
    /// décodage marcherait, et chaque pixel serait d'une couleur quelconque.
    /// Refuser en le disant vaut mieux qu'un écran de fausses couleurs.
    static func bytesPerPixel(_ bitsPerPixel: Int) -> Int? {
        switch bitsPerPixel {
        case 15, 16: return 2
        case 24: return 3
        default: return nil
        }
    }

    /// Décomprimer un rectangle. Le résultat est de haut en bas, `width` pixels
    /// par ligne, chaque pixel sur `bytesPerPixel` octets tels qu'ils voyagent.
    public static func decompress(_ data: Data, width: Int, height: Int,
                                  bitsPerPixel: Int) throws -> [UInt8] {
        guard let unit = bytesPerPixel(bitsPerPixel) else {
            throw WisqError.unsupportedEncoding(Int32(bitsPerPixel))
        }
        guard width > 0, height > 0, width <= Framebuffer.maximumPixels,
              height <= Framebuffer.maximumPixels,
              width * height <= Framebuffer.maximumPixels else {
            throw WisqError.malformedMessage("rectangle de \(width)×\(height)")
        }
        var decoder = Decoder(data: [UInt8](data), width: width, height: height, unit: unit)
        try decoder.run()
        return decoder.out
    }

    /// L'état d'un décodage. Une structure plutôt qu'une suite de variables
    /// libres : le masque de premier plan, la ligne courante et la position y
    /// changent ensemble, et les séparer est la façon dont on décale une image
    /// d'un pixel sans s'en apercevoir.
    struct Decoder {
        let data: [UInt8]
        let width: Int
        let height: Int
        let unit: Int
        var out: [UInt8]
        var at = 0
        var x = 0
        var y = 0
        /// La couleur de premier plan courante. Elle commence à blanc, et une
        /// « forme » l'inverse dans la ligne du dessus.
        var foreground: UInt32
        /// Vrai quand la course précédente était un fond : deux fonds de suite
        /// veulent dire qu'un pixel de premier plan les sépare.
        var lastWasBackground = false
        /// **Vrai tant qu'une course commence encore sur la première ligne.**
        /// Ce n'est pas « y vaut zéro » : le drapeau ne change qu'entre deux
        /// courses. Une course qui commence sur la première ligne et déborde
        /// sur la suivante traite tout son débordement comme s'il n'y avait
        /// pas de ligne au-dessus — ce qui n'a l'air de rien et décale une
        /// image entière dès qu'un dessin commence par une longue course.
        var firstLine = true

        init(data: [UInt8], width: Int, height: Int, unit: Int) {
            self.data = data
            self.width = width
            self.height = height
            self.unit = unit
            self.out = [UInt8](repeating: 0, count: width * height * unit)
            self.foreground = unit == 2 ? 0xFFFF : 0x00FF_FFFF
        }

        mutating func byte() throws -> UInt8 {
            guard at < data.count else {
                throw WisqError.malformedMessage("flux comprimé tronqué")
            }
            defer { at += 1 }
            return data[at]
        }

        mutating func colour() throws -> UInt32 {
            var value: UInt32 = 0
            for shift in 0..<unit { value |= UInt32(try byte()) << (8 * shift) }
            return value
        }

        /// **Les lignes arrivent de bas en haut.** La première ligne du flux
        /// est la dernière du rectangle : écrire dans l'ordre où elles arrivent
        /// donnerait une image retournée, ce qui se voit tout de suite sur du
        /// texte et pas du tout sur un aplat.
        func base(ofLine line: Int) -> Int { (height - 1 - line) * width * unit }

        /// Le pixel de la ligne précédente du flux — celle du dessous à l'écran
        /// — ou noir tant que la course courante a commencé sur la première.
        func above() -> UInt32 {
            guard !firstLine else { return 0 }
            let index = base(ofLine: y - 1) + x * unit
            var value: UInt32 = 0
            for shift in 0..<unit { value |= UInt32(out[index + shift]) << (8 * shift) }
            return value
        }

        // MARK: - Les vingt codes

        /// Ce qu'une course fait, une fois sa longueur lue.
        enum Order {
            case background, foreground, formOrMask, colourRun, colourImage
            case setForegroundRun, setForegroundMask, dithered
            case specialMask(UInt8), white, black
        }

        /// Lire un code, et rendre ce qu'il ordonne avec sa longueur.
        ///
        /// **Trois familles se partagent le même octet.** Les codes ordinaires
        /// tiennent l'ordre sur trois bits et la longueur sur cinq ; les codes
        /// « légers » l'ordre sur quatre bits et la longueur sur quatre ; et
        /// `0xF*` ouvre les codes longs, dont la longueur suit sur deux octets.
        /// Les confondre ne donne pas d'erreur : cela donne une longueur lue au
        /// mauvais endroit, et tout le reste du flux décalé.
        mutating func order() throws -> (Order, Int) {
            let code = try byte()
            switch code {
            case 0x00...0x9F:
                var count = Int(code & 0x1F)
                let kind = code >> 5
                if count == 0 {
                    // **Pour une image forme-fond, la longueur est en octets de
                    // masque**, et la forme étendue compte à partir de un.
                    count = kind == 2 ? Int(try byte()) + 1 : Int(try byte()) + 32
                }
                switch kind {
                case 0: return (.background, count)
                case 1: return (.foreground, count)
                case 2: return (.formOrMask, count * 8)
                case 3: return (.colourRun, count)
                default: return (.colourImage, count)
                }
            case 0xC0...0xEF:
                var count = Int(code & 0x0F)
                let kind = code >> 4
                if count == 0 { count = kind == 0xD ? Int(try byte()) + 1 : Int(try byte()) + 16 }
                switch kind {
                case 0xC: return (.setForegroundRun, count)
                case 0xD: return (.setForegroundMask, count * 8)
                default: return (.dithered, count)
                }
            case 0xF0...0xF8:
                let count = Int(try byte()) | Int(try byte()) << 8
                switch code {
                case 0xF0: return (.background, count)
                case 0xF1: return (.foreground, count)
                case 0xF2: return (.formOrMask, count)
                case 0xF3: return (.colourRun, count)
                case 0xF4: return (.colourImage, count)
                case 0xF6: return (.setForegroundRun, count)
                case 0xF7: return (.setForegroundMask, count)
                case 0xF8: return (.dithered, count)
                default:
                    throw WisqError.malformedMessage("code comprimé 0x\(String(code, radix: 16))")
                }
            // **Les deux masques spéciaux sont huit pixels chacun**, avec un
            // motif fixe qu'aucun octet ne porte : 0b11 et 0b101.
            case 0xF9: return (.specialMask(0x03), 8)
            case 0xFA: return (.specialMask(0x05), 8)
            case 0xFD: return (.white, 1)
            case 0xFE: return (.black, 1)
            default:
                throw WisqError.malformedMessage("code comprimé 0x\(String(code, radix: 16))")
            }
        }

        mutating func run() throws {
            while at < data.count {
                // **Le drapeau ne bouge qu'ici, entre deux courses.** Et il
                // efface au passage la dette de fond : un fond qui finit pile
                // au bout de la première ligne n'est pas suivi d'un pixel de
                // premier plan, parce que le compresseur, lui, n'avait pas
                // encore de ligne au-dessus quand il l'a écrit.
                if firstLine, y > 0 {
                    firstLine = false
                    lastWasBackground = false
                }
                let (order, count) = try self.order()
                let isBackground: Bool
                if case .background = order { isBackground = true } else { isBackground = false }
                switch order {
                case .background:
                    // **Deux fonds de suite sont séparés par un pixel de premier
                    // plan.** Le compresseur ne peut pas coder un fond plus long
                    // que sa longueur maximale ; il en écrit donc deux, et cette
                    // règle est le seul moyen de distinguer « la suite du même
                    // fond » de « un vrai second fond ».
                    var remaining = count
                    if lastWasBackground {
                        try put(above() ^ foreground)
                        remaining -= 1
                    }
                    for _ in 0..<max(remaining, 0) { try put(above()) }
                case .foreground:
                    for _ in 0..<count { try put(above() ^ foreground) }
                case .setForegroundRun:
                    foreground = try colour()
                    for _ in 0..<count { try put(above() ^ foreground) }
                case .formOrMask:
                    try mask(count)
                case .setForegroundMask:
                    foreground = try colour()
                    try mask(count)
                case .specialMask(let fixed):
                    try mask(8, fixed: fixed)
                case .colourRun:
                    let value = try colour()
                    for _ in 0..<count { try put(value) }
                case .colourImage:
                    for _ in 0..<count { try put(try colour()) }
                case .dithered:
                    // La longueur compte des **paires**, pas des pixels.
                    let first = try colour(), second = try colour()
                    for _ in 0..<count { try put(first); try put(second) }
                case .white:
                    try put(unit == 2 ? 0xFFFF : 0x00FF_FFFF)
                case .black:
                    try put(0)
                }
                lastWasBackground = isBackground
            }
        }

        /// Une image forme-fond : un bit par pixel, le plus faible d'abord.
        /// Un bit à un prend la forme — la ligne du dessus inversée par la
        /// couleur de premier plan ; un bit à zéro prend le fond.
        mutating func mask(_ pixels: Int, fixed: UInt8? = nil) throws {
            var done = 0
            while done < pixels {
                let bits = try fixed ?? byte()
                for bit in 0..<8 where done + bit < pixels {
                    try put(bits & (1 << bit) != 0 ? above() ^ foreground : above())
                }
                done += 8
            }
        }

        /// Écrire un pixel et avancer, en passant à la ligne suivante au bord.
        mutating func put(_ value: UInt32) throws {
            guard y < height else {
                throw WisqError.malformedMessage("le flux comprimé déborde du rectangle")
            }
            let index = base(ofLine: y) + x * unit
            for shift in 0..<unit { out[index + shift] = UInt8((value >> (8 * shift)) & 0xFF) }
            x += 1
            if x == width { x = 0; y += 1 }
        }
    }
}

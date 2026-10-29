import Foundation

/// Une appliance OVA, dont le disque est lu **dans l'archive**, sans
/// l'extraire.
///
/// **Pourquoi en place.** Un OVA n'est qu'une archive tar : le descripteur
/// OVF en tête, puis le disque, un VMDK « streamOptimized », stocké tel quel.
/// Le tar ne compresse rien et range chaque membre d'un seul tenant ; le
/// disque est donc une plage d'octets du fichier, que `VmdkImage` lit à son
/// décalage. L'extraire coûterait la taille de l'appliance une seconde fois,
/// sur un téléphone.
///
/// **Ce qu'il lit des en-têtes tar** : ustar (nom et préfixe), les noms
/// longs de GNU (`L`) et les en-têtes étendus pax (`x`, pour `path` et
/// `size`), la taille en octal ou en base 256. Chaque en-tête est contrôlé
/// par sa somme : un tar abîmé est refusé, pas parcouru au hasard.
///
/// **Quel disque.** Celui sur lequel le descripteur OVF démarre
/// (`OvfDescriptor`) ; si le descripteur ne le dit pas, le premier VMDK de
/// l'archive. Un membre `.vmdk` qui ne commence pas comme un VMDK (OVF permet
/// de compresser chaque fichier en gzip) est refusé en le disant.
public enum OvaArchive {
    public enum Refusal: Error, Equatable, LocalizedError {
        case notOva
        /// L'archive ne contient aucun VMDK.
        case noDisk
        /// Le membre `.vmdk` n'est pas un VMDK lisible en place.
        case diskNotReadableInPlace(String)
        /// Le descripteur nomme un disque de démarrage que l'archive n'a pas.
        case missingDisk(String)
        /// Un en-tête tar qui ne tient pas debout.
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .notOva: return "ce fichier n'est pas une archive OVA."
            case .noDisk: return "l'archive OVA ne contient aucun disque VMDK."
            case .diskNotReadableInPlace(let name):
                return "le disque \(name) de l'archive OVA est compressé ; "
                    + "wisq lit les disques que l'archive stocke tels quels."
            case .missingDisk(let name):
                return "le descripteur de l'appliance démarre sur \(name), absent de l'archive OVA."
            case .malformed(let what): return "l'archive OVA est mal formée : \(what)."
            }
        }
    }

    /// Un membre de l'archive : son nom, et où sont ses octets.
    public struct Member: Equatable, Sendable {
        public let name: String
        public let offset: UInt64
        public let length: UInt64
    }

    /// Au-delà, ce n'est plus une appliance mais un tar quelconque : la borne
    /// arrête un fichier hostile fait d'en-têtes vides.
    static let memberLimit = 4096

    /// Le fichier est-il un tar dont le premier membre est un descripteur
    /// OVF ? C'est ce que la norme impose à un OVA, et ce qui le distingue de
    /// n'importe quelle archive.
    public static func looksLikeOne(_ header: [UInt8]) -> Bool {
        guard header.count >= 512, Array(header[257..<262]) == Array("ustar".utf8),
              checksumMatches(header)
        else { return false }
        return name(header).lowercased().hasSuffix(".ovf")
    }

    public static func looksLikeOne(fd: Int32) -> Bool {
        var header = [UInt8](repeating: 0, count: 512)
        return VirtualDiskImages.readAll(fd, into: &header, at: 0) && looksLikeOne(header)
    }

    /// Les membres ordinaires de l'archive, dans l'ordre.
    public static func members(of fd: Int32) throws -> [Member] {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Refusal.malformed("taille illisible") }
        let fileSize = UInt64(info.st_size)
        var members: [Member] = []
        var at: UInt64 = 0
        var pendingName: String?
        var pendingSize: UInt64?
        var first = true
        while members.count < memberLimit {
            guard at <= fileSize, fileSize - at >= 512 else {
                throw Refusal.malformed("archive tronquée")
            }
            var header = [UInt8](repeating: 0, count: 512)
            guard VirtualDiskImages.readAll(fd, into: &header, at: off_t(at)) else {
                throw Refusal.malformed("en-tête illisible")
            }
            // Deux blocs nuls finissent l'archive ; un seul suffit à dire
            // qu'il n'y a plus de membre.
            if header.allSatisfy({ $0 == 0 }) { return members }
            guard checksumMatches(header) else { throw Refusal.malformed("somme d'en-tête fausse") }
            if first, !looksLikeOne(header) { throw Refusal.notOva }
            first = false
            let type = header[156]
            let declared = try size(header)
            // La taille d'un en-tête pax vaut pour le membre qui le suit :
            // c'est ainsi que s'écrit un disque de plus de 8 Gio, que l'octal
            // de l'en-tête ne sait pas dire.
            let size = pendingSize ?? declared
            let data = at + 512
            guard size <= fileSize - data else { throw Refusal.malformed("membre hors du fichier") }
            switch type {
            case UInt8(ascii: "x"), UInt8(ascii: "L"):
                // Il décrit le membre **suivant** ; il n'en est pas un.
                guard declared <= 64 * 1024 else { throw Refusal.malformed("en-tête étendu démesuré") }
                var payload = [UInt8](repeating: 0, count: Int(declared))
                guard VirtualDiskImages.readAll(fd, into: &payload, at: off_t(data)) else {
                    throw Refusal.malformed("en-tête étendu illisible")
                }
                if type == UInt8(ascii: "L") {
                    let end = payload.firstIndex(of: 0) ?? payload.count
                    pendingName = String(decoding: payload[0..<end], as: UTF8.self)
                } else {
                    let fields = pax(payload)
                    if let path = fields["path"] { pendingName = path }
                    if let text = fields["size"] {
                        guard let value = UInt64(text) else { throw Refusal.malformed("taille pax illisible") }
                        pendingSize = value
                    }
                }
                at = data + rounded(declared)
                continue
            case 0, UInt8(ascii: "0"), UInt8(ascii: "7"):
                members.append(Member(name: pendingName ?? name(header), offset: data, length: size))
            default:
                // Répertoires, liens, en-têtes globaux : rien à lire.
                break
            }
            pendingName = nil
            pendingSize = nil
            at = data + rounded(size)
        }
        throw Refusal.malformed("plus de \(memberLimit) membres")
    }

    /// Au-delà, ce n'est plus un descripteur mais autre chose : il n'est pas
    /// lu, et le premier VMDK reste le choix.
    static let descriptorLimit = 1 << 20

    /// Le disque de l'appliance : celui que le descripteur fait démarrer, ou
    /// à défaut le premier membre `.vmdk` — s'il commence comme un VMDK.
    public static func disk(in fd: Int32) throws -> Member {
        let all = try members(of: fd)
        let chosen: Member?
        if let href = bootDiskHref(all.first, fd: fd) {
            // Le `href` est relatif au descripteur, qui est à la racine de
            // l'archive ; un tar peut préfixer ses membres de `./`.
            func plain(_ name: String) -> String { name.hasPrefix("./") ? String(name.dropFirst(2)) : name }
            guard let named = all.first(where: { plain($0.name) == plain(href) }) else {
                throw Refusal.missingDisk(href)
            }
            chosen = named
        } else {
            chosen = all.first(where: { $0.name.lowercased().hasSuffix(".vmdk") })
        }
        guard let disk = chosen else { throw Refusal.noDisk }
        var magic = [UInt8](repeating: 0, count: 4)
        guard disk.length >= 512,
              VirtualDiskImages.readAll(fd, into: &magic, at: off_t(disk.offset)),
              magic == VmdkImage.magic
        else { throw Refusal.diskNotReadableInPlace(disk.name) }
        return disk
    }

    /// Le `href` du disque de démarrage selon le descripteur — le premier
    /// membre, que `members(of:)` a déjà vérifié être un `.ovf`.
    private static func bootDiskHref(_ descriptor: Member?, fd: Int32) -> String? {
        guard let descriptor, descriptor.length <= UInt64(descriptorLimit) else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(descriptor.length))
        guard VirtualDiskImages.readAll(fd, into: &bytes, at: off_t(descriptor.offset)) else { return nil }
        return OvfDescriptor.bootDiskHref(String(decoding: bytes, as: UTF8.self))
    }

    // MARK: - En-têtes tar

    static func name(_ header: [UInt8]) -> String {
        func field(_ range: Range<Int>) -> String {
            let slice = header[range]
            let end = slice.firstIndex(of: 0) ?? range.upperBound
            return String(decoding: header[range.lowerBound..<end], as: UTF8.self)
        }
        let name = field(0..<100)
        // Le préfixe n'existe qu'en ustar POSIX (« ustar\0 ») : à la même
        // place, l'ancien format de GNU (« ustar  ») range des dates.
        let posix = Array(header[257..<263]) == Array("ustar\0".utf8)
        let prefix = posix ? field(345..<500) : ""
        return prefix.isEmpty ? name : prefix + "/" + name
    }

    /// La taille, en octal ASCII — ou, bit de poids fort levé, en base 256
    /// gros-boutiste, ce que GNU écrit au-delà de 8 Gio.
    static func size(_ header: [UInt8]) throws -> UInt64 {
        let field = header[124..<136]
        if field.first! & 0x80 != 0 {
            let rest = field.dropFirst()
            guard rest.prefix(3).allSatisfy({ $0 == 0 }), field.first! == 0x80 else {
                throw Refusal.malformed("taille hors de portée")
            }
            return rest.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }
        var value: UInt64 = 0
        var seen = false
        for byte in field {
            if byte == 0 || byte == 0x20 { if seen { break } else { continue } }
            guard (0x30...0x37).contains(byte), value <= UInt64.max >> 3 else {
                throw Refusal.malformed("taille illisible")
            }
            value = value << 3 | UInt64(byte - 0x30)
            seen = true
        }
        return value
    }

    /// La somme de l'en-tête, son propre champ compté comme huit espaces.
    static func checksumMatches(_ header: [UInt8]) -> Bool {
        var sum = 0
        for (index, byte) in header[0..<512].enumerated() {
            sum += (148..<156).contains(index) ? 0x20 : Int(byte)
        }
        var stored = 0
        var seen = false
        for byte in header[148..<156] {
            if byte == 0 || byte == 0x20 { if seen { break } else { continue } }
            guard (0x30...0x37).contains(byte) else { return false }
            stored = stored << 3 | Int(byte - 0x30)
            seen = true
        }
        return seen && stored == sum
    }

    /// Les enregistrements « longueur clé=valeur\n » d'un en-tête pax.
    static func pax(_ payload: [UInt8]) -> [String: String] {
        var fields: [String: String] = [:]
        var at = 0
        while at < payload.count {
            guard let space = payload[at...].firstIndex(of: 0x20),
                  let length = Int(String(decoding: payload[at..<space], as: UTF8.self)),
                  length > space - at + 1, length <= payload.count - at
            else { break }
            let record = payload[(space + 1)..<(at + length - 1)]
            if let equal = record.firstIndex(of: UInt8(ascii: "=")) {
                fields[String(decoding: record[..<equal], as: UTF8.self)] =
                    String(decoding: record[(equal + 1)...], as: UTF8.self)
            }
            at += length
        }
        return fields
    }

    private static func rounded(_ size: UInt64) -> UInt64 { (size + 511) / 512 * 512 }
}

import Foundation

/// **Le noyau qu'un `bzImage` porte, décompressé.**
///
/// Le cœur Swift n'en a pas besoin : il pose le `bzImage` et laisse son
/// décompresseur tourner dans l'invité (`X86BootLoader`). La machine de
/// l'émetteur, elle, entre dans le `vmlinux` lui-même, à `startup_64`, ses
/// segments posés à leurs adresses physiques — comme `--example kernel-entry`,
/// qui démarre Alpine et Void ainsi. Le `vmlinux` est la **charge utile** du
/// `bzImage` : un flux compressé, que l'en-tête de démarrage situe exactement
/// (`payload_offset` à `0x248`, `payload_length` à `0x24C`, protocole 2.08 et
/// plus), compté depuis le début du code en mode protégé.
///
/// **Deux compressions sont lues**, celles des distributions mesurées et des
/// plus courantes : gzip (Alpine, Void) et zstd (Ubuntu, Arch, Fedora). Les
/// autres sont refusées sous leur nom plutôt que devinées. Le résultat doit
/// être un ELF : un flux qui se décompresse en autre chose est refusé aussi.
public enum KernelPayload {
    public enum Refusal: Error, Equatable, Sendable {
        /// Ni un `bzImage` lisible, ni un ELF.
        case notAKernel
        /// L'en-tête ne situe pas sa charge utile : avant 2.08, il faudrait la
        /// chercher au jugé.
        case protocolTooOld(UInt16)
        /// La charge utile déborde du fichier.
        case payloadOutsideTheFile
        /// Une compression que ce lecteur ne sait pas défaire, nommée.
        case unsupportedCompression(String)
        /// Le flux est abîmé : il ne se décompresse pas, ou pas à la taille
        /// qu'il annonce, ou sa somme ne tombe pas juste.
        case corrupt(String)
        /// Il se décompresse en autre chose qu'un ELF.
        case notAnELF
        /// Il dépasse ce qu'on accepte de décompresser : un flux qui annonce
        /// plus que la borne ne se décompresse pas pour voir.
        case tooLarge(Int)
    }

    /// Où l'en-tête situe la charge utile.
    static let payloadOffsetField = 0x248
    static let payloadLengthField = 0x24C
    /// Le premier protocole qui porte ces deux champs.
    static let payloadProtocol: UInt16 = 0x0208

    /// **Le `vmlinux` d'un fichier de noyau** : rendu tel quel s'il est déjà
    /// un ELF, décompressé s'il est un `bzImage`. `limit` borne ce qu'une
    /// décompression peut produire.
    public static func elf(from bytes: [UInt8], limit: Int = 512 << 20) throws -> [UInt8] {
        if isELF(bytes) { return bytes }
        guard let header = LinuxBootProtocol.read(from: bytes, totalBytes: bytes.count) else {
            throw Refusal.notAKernel
        }
        guard header.version >= payloadProtocol else {
            throw Refusal.protocolTooOld(header.version)
        }
        let offset = Int(u32(bytes, payloadOffsetField))
        let length = Int(u32(bytes, payloadLengthField))
        let start = header.setupBytes + offset
        guard length > 0, start >= header.setupBytes, start + length <= bytes.count else {
            throw Refusal.payloadOutsideTheFile
        }
        let payload = Array(bytes[start..<(start + length)])
        let inflated = try decompress(payload, limit: limit)
        guard isELF(inflated) else { throw Refusal.notAnELF }
        return inflated
    }

    /// Le nom d'une charge utile, d'après son nombre magique — de quoi refuser
    /// sous le bon nom.
    static func compression(of payload: [UInt8]) -> String? {
        let magics: [(String, [UInt8])] = [
            ("gzip", [0x1F, 0x8B]),
            ("zstd", [0x28, 0xB5, 0x2F, 0xFD]),
            ("xz", [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),
            ("bzip2", [0x42, 0x5A, 0x68]),
            ("lz4", [0x02, 0x21, 0x4C, 0x18]),
            ("lzo", [0x89, 0x4C, 0x5A, 0x4F]),
            ("lzma", [0x5D, 0x00, 0x00]),
        ]
        return magics.first { payload.starts(with: $0.1) }?.0
    }

    static func decompress(_ payload: [UInt8], limit: Int) throws -> [UInt8] {
        switch compression(of: payload) {
        case "gzip": return try gunzip(payload, limit: limit)
        case "zstd":
            // **Le noyau ajoute la taille après la trame** (`zstd22_with_size`
            // dans `arch/x86/boot/compressed/Makefile`) : quatre octets que
            // le lecteur prendrait pour une trame inconnue.
            guard payload.count > 4 else { throw Refusal.corrupt("zstd : une trame vide") }
            let declared = Int(u32(payload, payload.count - 4))
            guard declared <= limit else { throw Refusal.tooLarge(declared) }
            do {
                let out = try Zstd.decompress(Array(payload[..<(payload.count - 4)]))
                guard out.count == declared else {
                    throw Refusal.corrupt("zstd : \(out.count) octets pour \(declared) annoncés")
                }
                return out
            } catch let refusal as Refusal {
                throw refusal
            } catch {
                throw Refusal.corrupt("zstd : \(error)")
            }
        case let other?: throw Refusal.unsupportedCompression(other)
        case nil: throw Refusal.unsupportedCompression("inconnue")
        }
    }

    /// **Un membre gzip** (RFC 1952) : l'en-tête et ses champs facultatifs,
    /// le flux deflate, puis la somme et la taille, vérifiées toutes les deux.
    static func gunzip(_ member: [UInt8], limit: Int) throws -> [UInt8] {
        guard member.count >= 18, member[0] == 0x1F, member[1] == 0x8B, member[2] == 8 else {
            throw Refusal.corrupt("gzip : pas un membre deflate")
        }
        let flags = member[3]
        var at = 10
        func need(_ count: Int) throws {
            guard at + count <= member.count - 8 else { throw Refusal.corrupt("gzip : en-tête tronqué") }
        }
        if flags & 0x04 != 0 {
            try need(2)
            let extra = Int(member[at]) | Int(member[at + 1]) << 8
            at += 2
            try need(extra)
            at += extra
        }
        for flag in [UInt8(0x08), 0x10] where flags & flag != 0 {
            while true {
                try need(1)
                at += 1
                if member[at - 1] == 0 { break }
            }
        }
        if flags & 0x02 != 0 {
            try need(2)
            at += 2
        }
        let size = Int(u32(member, member.count - 4))
        let sum = u32(member, member.count - 8)
        guard size <= limit else { throw Refusal.tooLarge(size) }
        guard let out = Inflate.raw(Array(member[at..<(member.count - 8)]), limit: size, exact: true) else {
            throw Refusal.corrupt("gzip : le flux deflate ne rend pas ses \(size) octets")
        }
        guard CRC32.checksum(out) == sum else { throw Refusal.corrupt("gzip : la somme ne tombe pas juste") }
        return out
    }

    static func isELF(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 4 && bytes[0] == 0x7F && bytes[1] == 0x45 && bytes[2] == 0x4C && bytes[3] == 0x46
    }

    private static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(into: UInt32(0)) { $0 |= UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }
}

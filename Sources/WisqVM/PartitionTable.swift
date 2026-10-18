import Foundation

/// La table de partitions d'un disque : MBR ou GPT, lue sans rien écrire.
///
/// **Pourquoi elle est là.** Une image de cloud (Debian, Ubuntu, Fedora) ne
/// vient pas avec son noyau à côté : il est **dans** l'image, dans `/boot`,
/// sur une de ses partitions. Pour démarrer une telle image telle qu'elle est
/// téléchargée, il faut d'abord savoir où sont ses partitions, puis lire le
/// système de fichiers de l'une d'elles. Ce type-ci fait la première moitié.
///
/// **Il lit à travers une fonction**, pas un fichier : la même table se lit
/// dans une image brute, dans un qcow2 ou dans le VMDK d'un OVA, et c'est à
/// l'appelant de dire comment obtenir des octets du disque *virtuel*.
///
/// **Ce qu'il vérifie.** La GPT porte deux sommes CRC-32, une sur son en-tête
/// et une sur ses entrées, et une copie de secours à la fin du disque. Une
/// en-tête principale abîmée se rattrape par la copie ; deux copies abîmées
/// sont refusées en le disant, plutôt que de démarrer sur des partitions
/// inventées. Le MBR n'a pas de somme : on vérifie seulement sa signature et
/// que chaque partition tient dans le disque.
public struct PartitionTable: Equatable, Sendable {
    public enum Scheme: Equatable, Sendable {
        case mbr
        case gpt
    }

    /// Ce que le type d'une partition dit d'elle. Les cas nommés sont ceux qui
    /// décident où chercher un noyau ; les autres gardent leur type brut.
    public enum Kind: Equatable, Sendable {
        /// Un système de fichiers Linux quelconque (GPT `0FC63DAF-…`, MBR 0x83).
        case linuxFilesystem
        /// La racine d'un système x86-64, selon la spécification des
        /// partitions découvrables (`4F68BCE3-…`) : c'est celle de Debian.
        case linuxRoot
        /// `/boot` séparé (`BC13C2FF-…`, dit XBOOTLDR).
        case linuxBoot
        case efiSystem
        /// La petite partition où GRUB se loge sur un disque GPT démarré par
        /// le BIOS. Elle ne contient pas de système de fichiers.
        case biosBoot
        case swap
        /// Un type GPT que ce lecteur ne nomme pas, en clair.
        case otherGUID(String)
        /// Un type MBR que ce lecteur ne nomme pas.
        case otherMBR(UInt8)
    }

    public struct Partition: Equatable, Sendable {
        /// Le numéro que lui donnerait Linux : `vda1`, `vda14`… Pour une GPT,
        /// la place de l'entrée ; pour un MBR, 1 à 4 pour les primaires, 5 et
        /// au-delà pour les logiques.
        public let number: Int
        public let kind: Kind
        /// Le premier octet, dans le disque virtuel.
        public let start: UInt64
        public let length: UInt64
        /// Le nom GPT, souvent vide.
        public let name: String
    }

    public enum Failure: Error, Equatable, LocalizedError {
        /// Ni signature MBR ni en-tête GPT : un disque vierge, ou un système de
        /// fichiers posé sur le disque entier.
        case noTable
        /// Une table présente mais qu'on ne peut pas croire.
        case corrupt(String)

        public var errorDescription: String? {
            switch self {
            case .noTable: return "le disque n'a pas de table de partitions."
            case .corrupt(let why): return "la table de partitions est abîmée : \(why)"
            }
        }
    }

    public let scheme: Scheme
    public let partitions: [Partition]

    static let sector: UInt64 = 512

    /// Lit la table d'un disque de `size` octets. `read(offset, count)` rend
    /// `count` octets du disque à partir de `offset`, ou `nil` s'il ne peut
    /// pas.
    public static func read(size: UInt64, _ read: (UInt64, Int) -> [UInt8]?) throws -> PartitionTable {
        guard size >= 2 * sector, let mbr = read(0, Int(sector)) else { throw Failure.noTable }
        let signed = mbr[510] == 0x55 && mbr[511] == 0xAA
        // Une GPT se reconnaît à son en-tête, au deuxième secteur. Elle est
        // cherchée même sans MBR protecteur : certains outils l'omettent.
        if let header = read(sector, Int(sector)), header.starts(with: Array("EFI PART".utf8)) {
            return try readGPT(size: size, read)
        }
        guard signed else { throw Failure.noTable }
        let records = (0..<4).map { mbrRecord(mbr, at: 446 + 16 * $0) }
        if records.contains(where: { $0.type == 0xEE }) {
            // Un MBR protecteur sans GPT derrière : la GPT a été effacée, ou
            // n'est que dans sa copie de secours.
            return try readGPT(size: size, read)
        }
        return try readMBR(records, size: size, read)
    }

    /// Le même, pour une image dans un des formats lus par wisq.
    public static func read(_ image: any VirtualDiskImage) throws -> PartitionTable {
        try read(size: image.virtualSize) { offset, count in
            var buffer = [UInt8](repeating: 0, count: count)
            return image.read(into: &buffer, at: offset) ? buffer : nil
        }
    }

    /// Les partitions où un noyau peut se trouver, dans l'ordre où les
    /// essayer : un `/boot` séparé d'abord, puis la racine, puis les autres
    /// systèmes de fichiers Linux. Ni l'EFI (du FAT, où Debian ne met pas son
    /// noyau), ni la partition BIOS, ni le swap.
    public var linuxCandidates: [Partition] {
        func rank(_ kind: Kind) -> Int? {
            switch kind {
            case .linuxBoot: return 0
            case .linuxRoot: return 1
            case .linuxFilesystem: return 2
            default: return nil
            }
        }
        return partitions.filter { rank($0.kind) != nil }
            .sorted { (rank($0.kind)!, $0.number) < (rank($1.kind)!, $1.number) }
    }

    // MARK: - MBR

    struct MBRRecord {
        let type: UInt8
        let firstSector: UInt64
        let sectors: UInt64
    }

    static func mbrRecord(_ bytes: [UInt8], at offset: Int) -> MBRRecord {
        MBRRecord(type: bytes[offset + 4],
                  firstSector: UInt64(le32(bytes, offset + 8)),
                  sectors: UInt64(le32(bytes, offset + 12)))
    }

    static func isExtended(_ type: UInt8) -> Bool { type == 0x05 || type == 0x0F || type == 0x85 }

    static func mbrKind(_ type: UInt8) -> Kind {
        switch type {
        case 0x83: return .linuxFilesystem
        case 0x82: return .swap
        case 0xEF: return .efiSystem
        default: return .otherMBR(type)
        }
    }

    static func readMBR(_ records: [MBRRecord], size: UInt64,
                        _ read: (UInt64, Int) -> [UInt8]?) throws -> PartitionTable {
        var partitions: [Partition] = []
        for (index, record) in records.enumerated() where record.type != 0 && record.sectors != 0 {
            let start = record.firstSector * sector
            let length = record.sectors * sector
            guard start >= sector, start <= size, length <= size - start else {
                throw Failure.corrupt("la partition \(index + 1) déborde du disque.")
            }
            if isExtended(record.type) {
                partitions += try logicalPartitions(in: record, size: size, read)
            } else {
                partitions.append(Partition(number: index + 1, kind: mbrKind(record.type),
                                            start: start, length: length, name: ""))
            }
        }
        return PartitionTable(scheme: .mbr, partitions: partitions.sorted { $0.number < $1.number })
    }

    /// Les partitions logiques : une chaîne de MBR étendus, chacun décrivant
    /// une partition (relative à lui) et le maillon suivant (relatif au début
    /// de la partition étendue). La chaîne est bornée à 128 maillons : un
    /// maillon qui renverrait en arrière ferait tourner la lecture sans fin.
    static func logicalPartitions(in extended: MBRRecord, size: UInt64,
                                  _ read: (UInt64, Int) -> [UInt8]?) throws -> [Partition] {
        var partitions: [Partition] = []
        var link = extended.firstSector
        var links = 0
        while link != 0 {
            // Les maillons sont comptés, pas les partitions : un maillon vide
            // qui renverrait sur lui-même n'en ajouterait aucune.
            links += 1
            guard links <= 128 else {
                throw Failure.corrupt("la chaîne des partitions logiques boucle.")
            }
            guard link * sector < size, let ebr = read(link * sector, Int(sector)),
                  ebr[510] == 0x55, ebr[511] == 0xAA
            else { throw Failure.corrupt("un maillon des partitions logiques est illisible.") }
            let entry = mbrRecord(ebr, at: 446)
            let next = mbrRecord(ebr, at: 462)
            if entry.type != 0 && entry.sectors != 0 {
                let start = (link + entry.firstSector) * sector
                let length = entry.sectors * sector
                guard start < size, length <= size - start else {
                    throw Failure.corrupt("la partition \(5 + partitions.count) déborde du disque.")
                }
                partitions.append(Partition(number: 5 + partitions.count, kind: mbrKind(entry.type),
                                            start: start, length: length, name: ""))
            }
            link = isExtended(next.type) && next.sectors != 0 ? extended.firstSector + next.firstSector : 0
        }
        return partitions
    }

    // MARK: - GPT

    static func readGPT(size: UInt64, _ read: (UInt64, Int) -> [UInt8]?) throws -> PartitionTable {
        let lastSector = size / sector - 1
        var why = "l'en-tête principal est illisible."
        do {
            return try gpt(headerAt: 1, size: size, read)
        } catch Failure.corrupt(let reason) {
            why = reason
        }
        // La copie de secours, au dernier secteur. Elle décrit les mêmes
        // partitions ; c'est ce que fait Linux quand la principale est abîmée.
        do {
            return try gpt(headerAt: lastSector, size: size, read)
        } catch Failure.corrupt(let reason) {
            throw Failure.corrupt("\(why) Et la copie de secours : \(reason)")
        }
    }

    static func gpt(headerAt lba: UInt64, size: UInt64,
                    _ read: (UInt64, Int) -> [UInt8]?) throws -> PartitionTable {
        guard let header = read(lba * sector, Int(sector)) else {
            throw Failure.corrupt("son en-tête est illisible.")
        }
        guard header.starts(with: Array("EFI PART".utf8)) else {
            throw Failure.corrupt("il n'y a pas d'en-tête GPT au secteur \(lba).")
        }
        let headerSize = Int(le32(header, 12))
        guard headerSize >= 92, headerSize <= Int(sector) else {
            throw Failure.corrupt("son en-tête annonce \(headerSize) octets.")
        }
        var summed = Array(header[0..<headerSize])
        summed.replaceSubrange(16..<20, with: [0, 0, 0, 0])
        guard CRC32.checksum(summed) == le32(header, 16) else {
            throw Failure.corrupt("la somme de son en-tête ne correspond pas.")
        }
        let firstUsable = le64(header, 40)
        let lastUsable = le64(header, 48)
        let entriesLBA = le64(header, 72)
        let count = Int(le32(header, 80))
        let entrySize = Int(le32(header, 84))
        let sectors = size / sector
        guard firstUsable <= lastUsable, lastUsable < sectors else {
            throw Failure.corrupt("sa zone utilisable sort du disque.")
        }
        // 128 entrées de 128 octets est l'usage ; la borne empêche une table
        // abîmée de demander des mégaoctets.
        guard count <= 1024, entrySize >= 128, entrySize <= 1024, entrySize % 8 == 0 else {
            throw Failure.corrupt("elle annonce \(count) entrées de \(entrySize) octets.")
        }
        let bytes = count * entrySize
        guard entriesLBA < sectors, UInt64(bytes) <= (sectors - entriesLBA) * sector,
              let entries = read(entriesLBA * sector, bytes)
        else { throw Failure.corrupt("ses entrées sont hors du disque.") }
        guard CRC32.checksum(entries) == le32(header, 88) else {
            throw Failure.corrupt("la somme de ses entrées ne correspond pas.")
        }
        var partitions: [Partition] = []
        for index in 0..<count {
            let base = index * entrySize
            let type = Array(entries[base..<(base + 16)])
            guard type.contains(where: { $0 != 0 }) else { continue }
            let first = le64(entries, base + 32)
            let last = le64(entries, base + 40)
            guard first >= firstUsable, first <= last, last <= lastUsable else {
                throw Failure.corrupt("la partition \(index + 1) sort de la zone utilisable.")
            }
            let name = String(decoding: stride(from: base + 56, to: base + 128, by: 2)
                .map { UInt16(entries[$0]) | UInt16(entries[$0 + 1]) << 8 }
                .prefix { $0 != 0 }, as: UTF16.self)
            partitions.append(Partition(number: index + 1, kind: gptKind(guid(type)),
                                        start: first * sector, length: (last - first + 1) * sector,
                                        name: name))
        }
        return PartitionTable(scheme: .gpt, partitions: partitions)
    }

    static func gptKind(_ guid: String) -> Kind {
        switch guid {
        case "0FC63DAF-8483-4772-8E79-3D69D8477DE4": return .linuxFilesystem
        case "4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709": return .linuxRoot
        case "BC13C2FF-59E6-4262-A352-B275FD6F7172": return .linuxBoot
        case "C12A7328-F81F-11D2-BA4B-00A0C93EC93B": return .efiSystem
        case "21686148-6449-6E6F-744E-656564454649": return .biosBoot
        case "0657FD6D-A4AB-43C4-84E5-0933C84B4F4F": return .swap
        default: return .otherGUID(guid)
        }
    }

    /// Un GUID tel que la GPT l'écrit — les trois premiers champs en petit-
    /// boutien, les deux derniers dans l'ordre — et tel qu'on le lit partout
    /// ailleurs.
    static func guid(_ bytes: [UInt8]) -> String {
        func hex(_ slice: [UInt8]) -> String { slice.map { String(format: "%02X", $0) }.joined() }
        return [hex(bytes[0..<4].reversed()), hex(bytes[4..<6].reversed()), hex(bytes[6..<8].reversed()),
                hex(Array(bytes[8..<10])), hex(Array(bytes[10..<16]))].joined(separator: "-")
    }

    static func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    static func le64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << (8 * UInt64($1)) }
    }
}

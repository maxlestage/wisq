import Foundation

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Là où vivent les octets d'un disque.
///
/// **Pourquoi une interface, et pas un tableau.** `VirtioBlock` tenait son
/// image dans un `[UInt8]`, entier. C'était le fait qui commandait tout le
/// reste : le plafond de taille, le refus à l'import, la phrase de l'écran —
/// et ce que quelqu'un pouvait brancher, c'est-à-dire jamais l'image
/// d'installation de plusieurs gigaoctets qu'il avait apportée.
///
/// Le périphérique ne fait que deux choses avec ses octets : en lire un
/// morceau, en écrire un morceau. C'est tout ce que cette interface offre,
/// en octets et pas en secteurs, parce que c'est ce que les descripteurs
/// virtio décrivent ; c'est au store de savoir que le disque est fait de
/// secteurs.
public protocol DiskStore: AnyObject {
    /// La taille, en secteurs de 512 octets.
    var sectors: UInt64 { get }
    /// `count` octets à partir d'un décalage en octets, ou `nil` au-delà de la
    /// fin : le périphérique répond alors une erreur de statut, comme un vrai
    /// disque à qui l'on demande un secteur qu'il n'a pas.
    func read(at offset: UInt64, count: Int) -> [UInt8]?
    /// Écrit des octets. Faux au-delà de la fin, et rien n'est écrit alors.
    @discardableResult
    func write(at offset: UInt64, _ bytes: [UInt8]) -> Bool
    /// Pousse ce qui a été écrit jusqu'au stockage durable.
    func flush()
    /// Combien d'octets l'invité a changés — ce que le rapport de stockage
    /// montre. Un store en mémoire répond la taille de son image : c'est bien
    /// ce que l'instantané emporte.
    var bytesWritten: Int { get }
}

/// L'image entière en mémoire — ce que le périphérique a toujours eu.
///
/// Elle reste la forme des tests et des petits disques, et c'est elle que
/// l'instantané embarque : les machines déjà sauvées sur les téléphones en
/// portent une, et doivent se relire.
public final class MemoryDiskStore: DiskStore, @unchecked Sendable {
    public var image: [UInt8]

    public init(image: [UInt8]) {
        self.image = image
    }

    public var sectors: UInt64 { UInt64(image.count / 512) }

    public func read(at offset: UInt64, count: Int) -> [UInt8]? {
        guard let range = range(at: offset, count: count) else { return nil }
        return Array(image[range])
    }

    public func write(at offset: UInt64, _ bytes: [UInt8]) -> Bool {
        guard let range = range(at: offset, count: bytes.count) else { return false }
        image.replaceSubrange(range, with: bytes)
        return true
    }

    public func flush() {}

    public var bytesWritten: Int { image.count }

    private func range(at offset: UInt64, count: Int) -> Range<Int>? {
        guard count >= 0, offset <= UInt64(image.count),
              let start = Int(exactly: offset),
              start + count <= image.count else { return nil }
        return start..<(start + count)
    }
}

/// Un disque lu depuis un fichier, dont les écritures vont dans une couche à
/// part — et y restent.
///
/// **La base ne change jamais.** Elle est ouverte en lecture seule, et c'est
/// le fichier que la personne a importé : une image ext4, une ISO de six
/// gigaoctets. Rien n'en est copié en mémoire ; chaque lecture est un `pread`
/// à l'endroit demandé.
///
/// **La couche est faite de deux fichiers, et elle est tassée.** `writes`
/// range les secteurs écrits **les uns derrière les autres, dans l'ordre où
/// ils ont été écrits** : le n-ième secteur touché occupe le n-ième
/// emplacement, quel que soit son numéro sur le disque. `writes.map` dit quel
/// secteur occupe quel emplacement — un en-tête, puis un numéro de secteur de
/// huit octets par emplacement.
///
/// **Le premier jet rangeait chaque secteur à son propre décalage**, dans un
/// fichier épars de la taille de la base, en comptant sur le système de
/// fichiers pour ne rien allouer entre les trous. **Sur APFS il alloue.**
/// Mesuré sur macOS : un seul secteur écrit à deux mébioctets du début coûte
/// 2 052 096 octets. APFS est aussi le système de fichiers de l'iPhone, donc
/// la seule mesure qui compte disait que l'idée ne tenait pas : une image de
/// six gigaoctets dont l'invité écrit le dernier secteur aurait rempli le
/// téléphone. La couche tassée coûte 512 octets par secteur touché, sur
/// n'importe quel système de fichiers, parce qu'elle ne demande plus rien à
/// personne.
///
/// **Chaque écriture est durable au moment où elle est faite.** Le secteur
/// part dans `writes`, puis son numéro dans `writes.map`, avant que le
/// périphérique ne réponde à l'invité. **Dans cet ordre**, et l'ordre est ce
/// qui rend une mort brutale inoffensive : un emplacement écrit mais pas
/// encore nommé n'appartient à personne, il est ignoré à la réouverture et le
/// prochain secteur le reprend. L'inverse rendrait un secteur nommé dont le
/// contenu n'existe pas — le disque rendrait des zéros pour des octets qu'il
/// prétend avoir. `flush` ajoute `fsync`, pour le passage en arrière-plan.
///
/// **Le même format des deux côtés.** Le cœur Rust écrit exactement ces deux
/// fichiers ; un test différentiel les compare octet pour octet.
public final class FileDiskStore: DiskStore, @unchecked Sendable {
    public enum Failure: Error, Equatable, LocalizedError {
        /// La base n'a pas pu être ouverte.
        case cannotOpenBase
        /// Moins d'un secteur : l'invité verrait un disque de zéro secteur.
        case notADisk
        /// La couche n'a pas pu être créée ou ouverte.
        case cannotOpenOverlay
        /// L'en-tête de la carte ne décrit pas cette base : cette couche vient
        /// d'un autre disque, et la lire donnerait les secteurs d'un autre
        /// fichier.
        case overlayBelongsToAnotherDisk
        /// La carte nomme des emplacements que le fichier des écritures n'a
        /// pas : il a été tronqué, et les octets que l'invité croit avoir
        /// écrits ne sont plus là.
        case overlayIsTruncated

        public var errorDescription: String? {
            switch self {
            case .cannotOpenBase: return "le disque n'a pas pu être ouvert."
            case .notADisk: return "le disque fait moins d'un secteur."
            case .cannotOpenOverlay:
                return "la couche d'écriture du disque n'a pas pu être créée."
            case .overlayBelongsToAnotherDisk:
                return "la couche d'écriture trouvée appartient à un autre disque."
            case .overlayIsTruncated:
                return "la couche d'écriture du disque est incomplète."
            }
        }
    }

    public static let sectorSize = 512
    /// Huit octets qui disent à quoi sert ce fichier, suivis du nombre de
    /// secteurs de la base : c'est **lui** qui rattache une couche à son
    /// disque. La taille ne le pouvait plus une fois la couche tassée, et
    /// s'en remettre à la taille aurait laissé passer deux disques du même
    /// nombre de secteurs.
    static let magic = Array("wisqdisk".utf8)
    static let headerSize = 16

    public let sectors: UInt64
    private let base: Int32
    private let writes: Int32
    private let map: Int32
    /// Quel emplacement porte quel secteur. En mémoire seulement : la carte
    /// sur le disque est la liste des secteurs, dans l'ordre des emplacements.
    private var slots: [UInt64: Int]
    private var used: Int

    public init(base baseURL: URL, writes writesURL: URL) throws {
        let baseFD = open(baseURL.path, O_RDONLY)
        guard baseFD >= 0 else { throw Failure.cannotOpenBase }
        var info = stat()
        guard fstat(baseFD, &info) == 0 else { close(baseFD); throw Failure.cannotOpenBase }
        let size = UInt64(info.st_size)
        guard size >= UInt64(Self.sectorSize) else { close(baseFD); throw Failure.notADisk }
        let sectors = size / UInt64(Self.sectorSize)

        let writesFD = open(writesURL.path, O_RDWR | O_CREAT, 0o600)
        guard writesFD >= 0 else { close(baseFD); throw Failure.cannotOpenOverlay }
        let mapFD = open(writesURL.path + ".map", O_RDWR | O_CREAT, 0o600)
        guard mapFD >= 0 else { close(baseFD); close(writesFD); throw Failure.cannotOpenOverlay }

        func giveUp(_ failure: Failure) -> Failure {
            close(baseFD); close(writesFD); close(mapFD)
            return failure
        }

        var mapInfo = stat()
        guard fstat(mapFD, &mapInfo) == 0 else { throw giveUp(.cannotOpenOverlay) }
        var writesInfo = stat()
        guard fstat(writesFD, &writesInfo) == 0 else { throw giveUp(.cannotOpenOverlay) }

        var table: [UInt64] = []
        if mapInfo.st_size == 0 {
            var header = Self.magic
            var count = sectors.littleEndian
            withUnsafeBytes(of: &count) { header.append(contentsOf: $0) }
            guard Self.writeAll(mapFD, header, at: 0) else { throw giveUp(.cannotOpenOverlay) }
        } else {
            guard Int(mapInfo.st_size) >= Self.headerSize else {
                throw giveUp(.overlayBelongsToAnotherDisk)
            }
            var header = [UInt8](repeating: 0, count: Self.headerSize)
            guard Self.readAll(mapFD, into: &header, at: 0) else {
                throw giveUp(.cannotOpenOverlay)
            }
            guard Array(header[0..<8]) == Self.magic else {
                throw giveUp(.overlayBelongsToAnotherDisk)
            }
            var declared: UInt64 = 0
            for index in 0..<8 { declared |= UInt64(header[8 + index]) << (8 * UInt64(index)) }
            guard declared == sectors else { throw giveUp(.overlayBelongsToAnotherDisk) }

            // **Les deux fichiers ne peuvent se désaccorder que dans un
            // sens.** Le contenu part avant le nom, donc il peut y avoir un
            // emplacement de plus que de noms : c'est l'application tuée entre
            // les deux, et cet emplacement-là n'appartient à personne — on
            // l'ignore, et le prochain secteur le reprend.
            //
            // L'inverse est impossible à produire honnêtement : un nom dont le
            // contenu manque veut dire que le fichier des écritures a été
            // tronqué sous nos pieds. On refuse la couche plutôt que de
            // choisir entre deux mauvaises réponses — rendre le secteur de la
            // base, c'est-à-dire un contenu périmé sans le dire, ou une erreur
            // d'entrée-sortie à chaque lecture de ce secteur.
            let named = (Int(mapInfo.st_size) - Self.headerSize) / 8
            let stored = Int(writesInfo.st_size) / Self.sectorSize
            guard named <= stored else { throw giveUp(.overlayIsTruncated) }
            let count = named
            if count > 0 {
                var bytes = [UInt8](repeating: 0, count: count * 8)
                guard Self.readAll(mapFD, into: &bytes, at: off_t(Self.headerSize)) else {
                    throw giveUp(.cannotOpenOverlay)
                }
                table.reserveCapacity(count)
                for slot in 0..<count {
                    var sector: UInt64 = 0
                    for index in 0..<8 {
                        sector |= UInt64(bytes[slot * 8 + index]) << (8 * UInt64(index))
                    }
                    table.append(sector)
                }
            }
        }

        var slots: [UInt64: Int] = [:]
        slots.reserveCapacity(table.count)
        for (slot, sector) in table.enumerated() { slots[sector] = slot }

        self.base = baseFD
        self.writes = writesFD
        self.map = mapFD
        self.sectors = sectors
        self.slots = slots
        self.used = table.count
    }

    deinit {
        close(base)
        close(writes)
        close(map)
    }

    public var bytesWritten: Int { used * Self.sectorSize }

    private func inRange(_ offset: UInt64, _ count: Int) -> Bool {
        count >= 0 && offset <= sectors * UInt64(Self.sectorSize)
            && UInt64(count) <= sectors * UInt64(Self.sectorSize) - offset
    }

    public func read(at offset: UInt64, count: Int) -> [UInt8]? {
        guard inRange(offset, count) else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        var at = offset
        // Secteur par secteur, parce que la source change à chacun.
        while done < count {
            let sector = at / UInt64(Self.sectorSize)
            let within = Int(at % UInt64(Self.sectorSize))
            let take = min(count - done, Self.sectorSize - within)
            var piece = [UInt8](repeating: 0, count: take)
            let source: Int32
            let from: off_t
            if let slot = slots[sector] {
                source = writes
                from = off_t(slot * Self.sectorSize + within)
            } else {
                source = base
                from = off_t(at)
            }
            guard Self.readAll(source, into: &piece, at: from) else { return nil }
            out.replaceSubrange(done..<(done + take), with: piece)
            done += take
            at += UInt64(take)
        }
        return out
    }

    public func write(at offset: UInt64, _ bytes: [UInt8]) -> Bool {
        guard inRange(offset, bytes.count) else { return false }
        var done = 0
        var at = offset
        while done < bytes.count {
            let sector = at / UInt64(Self.sectorSize)
            let within = Int(at % UInt64(Self.sectorSize))
            let take = min(bytes.count - done, Self.sectorSize - within)
            let existing = slots[sector]
            let slot = existing ?? used

            // Un emplacement entier à chaque fois. Le premier passage recopie
            // ce que le secteur valait — la base, ou l'emplacement qu'il avait
            // déjà — sinon les octets non écrits liraient le zéro d'un
            // emplacement neuf là où il y avait quelque chose.
            var whole = [UInt8](repeating: 0, count: Self.sectorSize)
            if take < Self.sectorSize {
                let source = existing.map { (writes, off_t($0 * Self.sectorSize)) }
                    ?? (base, off_t(sector * UInt64(Self.sectorSize)))
                guard Self.readAll(source.0, into: &whole, at: source.1) else { return false }
            }
            whole.replaceSubrange(within..<(within + take), with: bytes[done..<(done + take)])
            guard Self.writeAll(writes, whole, at: off_t(slot * Self.sectorSize)) else {
                return false
            }

            if existing == nil {
                // Le contenu d'abord, le nom ensuite : un emplacement nommé
                // dont le contenu manque rendrait des zéros pour des octets
                // qu'il prétend avoir.
                var name = sector.littleEndian
                var named = [UInt8]()
                withUnsafeBytes(of: &name) { named.append(contentsOf: $0) }
                guard Self.writeAll(map, named, at: off_t(Self.headerSize + slot * 8)) else {
                    return false
                }
                slots[sector] = slot
                used += 1
            }
            done += take
            at += UInt64(take)
        }
        return true
    }

    public func flush() {
        fsync(writes)
        fsync(map)
    }

    // MARK: - pread / pwrite, jusqu'au bout

    private static func readAll(_ fd: Int32, into buffer: inout [UInt8], at offset: off_t) -> Bool {
        let wanted = buffer.count
        return buffer.withUnsafeMutableBytes { raw -> Bool in
            var done = 0
            while done < wanted {
                let got = pread(fd, raw.baseAddress! + done, wanted - done, offset + off_t(done))
                if got <= 0 { return false }
                done += got
            }
            return true
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: [UInt8], at offset: off_t) -> Bool {
        bytes.withUnsafeBytes { raw -> Bool in
            var done = 0
            while done < bytes.count {
                let put = pwrite(fd, raw.baseAddress! + done, bytes.count - done, offset + off_t(done))
                if put <= 0 { return false }
                done += put
            }
            return true
        }
    }
}

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
/// **La couche est faite de deux fichiers.** `writes` est un fichier épars
/// de la taille de la base, où chaque secteur écrit est rangé à son propre
/// décalage — il n'occupe sur le disque que ce qui a été écrit, et un
/// secteur sur quatre mille coûte un secteur. `writes.map` fait un bit par
/// secteur et dit lesquels lire dans la couche plutôt que dans la base.
///
/// **Chaque écriture est durable au moment où elle est faite.** Le secteur
/// part dans `writes`, et le bit dans `.map`, avant que le périphérique ne
/// réponde à l'invité. Ce sont deux petits `pwrite` par secteur — trois fois
/// rien pour un invité qui tourne à la vitesse d'un interpréteur — et c'est
/// ce qui fait qu'une application tuée sans préavis ne perd pas le fichier
/// qu'on venait de sauver. `flush` ajoute `fsync`, pour le passage en
/// arrière-plan.
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
        /// La carte n'a pas la taille de cette base : cette couche vient d'un
        /// autre disque, et la lire donnerait les secteurs d'un autre fichier.
        case overlayBelongsToAnotherDisk

        public var errorDescription: String? {
            switch self {
            case .cannotOpenBase: return "le disque n'a pas pu être ouvert."
            case .notADisk: return "le disque fait moins d'un secteur."
            case .cannotOpenOverlay:
                return "la couche d'écriture du disque n'a pas pu être créée."
            case .overlayBelongsToAnotherDisk:
                return "la couche d'écriture trouvée appartient à un autre disque."
            }
        }
    }

    public static let sectorSize = 512

    public let sectors: UInt64
    private let base: Int32
    private let writes: Int32
    private let map: Int32
    /// Un bit par secteur, en mémoire ; chaque octet modifié repart aussitôt
    /// dans le fichier de carte.
    private var bitmap: [UInt8]
    private var writtenSectors: Int

    public init(base baseURL: URL, writes writesURL: URL) throws {
        let baseFD = open(baseURL.path, O_RDONLY)
        guard baseFD >= 0 else { throw Failure.cannotOpenBase }
        var info = stat()
        guard fstat(baseFD, &info) == 0 else { close(baseFD); throw Failure.cannotOpenBase }
        let size = UInt64(info.st_size)
        guard size >= UInt64(Self.sectorSize) else { close(baseFD); throw Failure.notADisk }
        let sectors = size / UInt64(Self.sectorSize)
        let mapBytes = Int((sectors + 7) / 8)

        let writesFD = open(writesURL.path, O_RDWR | O_CREAT, 0o600)
        guard writesFD >= 0 else { close(baseFD); throw Failure.cannotOpenOverlay }
        let mapFD = open(writesURL.path + ".map", O_RDWR | O_CREAT, 0o600)
        guard mapFD >= 0 else { close(baseFD); close(writesFD); throw Failure.cannotOpenOverlay }

        var mapInfo = stat()
        guard fstat(mapFD, &mapInfo) == 0 else {
            close(baseFD); close(writesFD); close(mapFD)
            throw Failure.cannotOpenOverlay
        }
        var bitmap = [UInt8](repeating: 0, count: mapBytes)
        if mapInfo.st_size == 0 {
            // Une carte neuve : tout vient de la base. Écrite en entier tout
            // de suite, pour que sa taille dise à quel disque elle appartient.
            guard Self.writeAll(mapFD, bitmap, at: 0) else {
                close(baseFD); close(writesFD); close(mapFD)
                throw Failure.cannotOpenOverlay
            }
        } else if Int(mapInfo.st_size) != mapBytes {
            close(baseFD); close(writesFD); close(mapFD)
            throw Failure.overlayBelongsToAnotherDisk
        } else {
            guard Self.readAll(mapFD, into: &bitmap, at: 0) else {
                close(baseFD); close(writesFD); close(mapFD)
                throw Failure.cannotOpenOverlay
            }
        }

        self.base = baseFD
        self.writes = writesFD
        self.map = mapFD
        self.sectors = sectors
        self.bitmap = bitmap
        self.writtenSectors = bitmap.reduce(0) { $0 + $1.nonzeroBitCount }
    }

    deinit {
        close(base)
        close(writes)
        close(map)
    }

    public var bytesWritten: Int { writtenSectors * Self.sectorSize }

    private func isWritten(_ sector: UInt64) -> Bool {
        bitmap[Int(sector >> 3)] & (1 << UInt8(sector & 7)) != 0
    }

    private func inRange(_ offset: UInt64, _ count: Int) -> Bool {
        count >= 0 && offset <= sectors * UInt64(Self.sectorSize)
            && UInt64(count) <= sectors * UInt64(Self.sectorSize) - offset
    }

    public func read(at offset: UInt64, count: Int) -> [UInt8]? {
        guard inRange(offset, count) else { return nil }
        var out = [UInt8](repeating: 0, count: count)
        var done = 0
        var at = offset
        // Secteur par secteur, parce que la source peut changer à chacun.
        while done < count {
            let sector = at / UInt64(Self.sectorSize)
            let within = Int(at % UInt64(Self.sectorSize))
            let take = min(count - done, Self.sectorSize - within)
            let source = isWritten(sector) ? writes : base
            var piece = [UInt8](repeating: 0, count: take)
            guard Self.readAll(source, into: &piece, at: off_t(at)) else { return nil }
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
            let sectorStart = off_t(sector * UInt64(Self.sectorSize))

            // Un secteur entier à chaque fois. Le premier passage sur un
            // secteur recopie la base, sinon les octets non écrits liraient
            // le zéro du fichier épars là où la base avait quelque chose.
            var whole = [UInt8](repeating: 0, count: Self.sectorSize)
            if take < Self.sectorSize {
                let source = isWritten(sector) ? writes : base
                guard Self.readAll(source, into: &whole, at: sectorStart) else { return false }
            }
            whole.replaceSubrange(within..<(within + take), with: bytes[done..<(done + take)])
            guard Self.writeAll(writes, whole, at: sectorStart) else { return false }

            if !isWritten(sector) {
                let index = Int(sector >> 3)
                bitmap[index] |= 1 << UInt8(sector & 7)
                writtenSectors += 1
                // Le bit part tout de suite : c'est lui qui rend le secteur
                // visible à la prochaine ouverture.
                guard Self.writeAll(map, [bitmap[index]], at: off_t(index)) else { return false }
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

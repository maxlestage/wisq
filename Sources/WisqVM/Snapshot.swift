import Foundation

/// Saving a running machine, and bringing it back.
///
/// The obvious way to give the local Linux persistence is a disk, and it does
/// not work here: the rv32 nommu kernels this runs have the virtio-mmio
/// transport but no block driver, and the reference image's whole filesystem
/// list is devtmpfs, proc, ramfs and sysfs. A perfect virtio-blk would have
/// nobody to talk to, and since the user brings their own kernel, whether a
/// disk worked at all would depend on a build we do not control.
///
/// Saving the machine goes underneath the guest instead. RAM, the hart's
/// registers and the bytes queued for the UART are ours; putting them back
/// returns the guest to exactly where it was.
///
/// **The format is shared with the Rust core, byte for byte.** That is not
/// tidiness: the two interpreters are held to being interchangeable, and a
/// snapshot that only one of them can read would quietly break that the day
/// the app switches cores under someone's saved machine. A test restores each
/// core's snapshot into the other.
enum Snapshot {
    /// Version last, so a future format is recognised and refused rather than
    /// read as garbage.
    static let magic = Array("WISQSNP".utf8) + [UInt8(1)]

    /// **La marque de la pile x87, en queue d'un instantané x86.**
    ///
    /// Des machines sont déjà sauvées sur des téléphones, et la pile x87
    /// s'est ajoutée après elles. Elle se lit donc comme le disque se lit
    /// depuis #144 — en queue, et son absence veut dire « un instantané
    /// d'avant », pas « un instantané abîmé ». Mais le disque est déjà en
    /// queue : « il reste des octets » ne suffit plus à dire lequel des deux
    /// vient, d'où cette marque, posée devant la pile.
    ///
    /// **Ce qui pourrait la tromper, et c'est dit plutôt que tu.** Un
    /// instantané d'avant, avec un disque, commence sa section disque par
    /// `deviceFeaturesSelect` et `driverFeaturesSelect` — deux mots de
    /// trente-deux bits que le pilote invité écrit, et qu'un pilote réel met à
    /// zéro ou à un. Pour que la marque se confonde avec eux, il faudrait un
    /// invité qui y ait écrit exactement `0x51534957` et `0x3738785F`. La
    /// lecture exige en plus que la section entière tienne derrière, de sorte
    /// qu'une confusion refuse au lieu de rendre n'importe quoi.
    static let x87Section: UInt64 = 0x3738_785F_5153_4957  // « WISQ_x87 »

    /// La marque du second disque de la machine PC, posée après le premier.
    ///
    /// Ce qui la précède est l'état PCI du premier disque ; dans un instantané
    /// d'avant, il n'y avait rien derrière — il s'arrêtait là. Une confusion
    /// demanderait un instantané d'avant avec des octets en trop, ce qu'aucune
    /// version n'a écrit, et la lecture exige de toute façon la section
    /// entière derrière la marque.
    static let secondDiskSection: UInt64 = 0x6264_765F_5153_4957  // « WISQ_vdb »

    /// La marque de l'état étendu de la machine PC — XCR0 et le haut des
    /// seize registres YMM —, posée juste après la pile x87, avant le disque.
    /// Même raisonnement que pour celle-ci : un instantané d'avant passe de
    /// la pile au disque, et le disque ne commence pas par ces huit octets.
    static let extendedStateSection: UInt64 = 0x6D6D_795F_5153_4957  // « WISQ_ymm »

    /// La marque du rapport de l'horloge de la machine PC, posée après l'état
    /// étendu, avant le disque. Un instantané d'avant passe de l'état étendu
    /// au disque, qui ne commence pas par ces huit octets.
    static let clockSection: UInt64 = 0x6B63_745F_5153_4957  // « WISQ_tck »

    /// `x[0..32]` then the sixteen control registers, in the order the Rust
    /// `Core` declares them. The two lists must not drift; the cross-core test
    /// is what notices if they do.
    static let coreWords = 48

    enum Failure: Error, Equatable {
        case notASnapshot
        case corrupt
        case ramSizeMismatch(saved: UInt64, expected: UInt64)
    }

    // MARK: - Writing

    struct Writer {
        private(set) var bytes: [UInt8]

        init() { bytes = Snapshot.magic }

        mutating func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func u64(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func blob(_ data: [UInt8]) {
            u64(UInt64(data.count))
            bytes.append(contentsOf: data)
        }

        /// RAM, with runs of zeros folded to a count.
        ///
        /// A booted 64 MB machine has touched a small part of its memory; the
        /// rest is the zero the mapping started as. Writing it all would make
        /// a snapshot too heavy to take every time the app goes to the
        /// background, which is the only moment it can be taken.
        ///
        /// **Seules les longues suites de zéros sont repliées.** Une paire
        /// coûte seize octets d'en-tête ; replier les trois zéros d'un petit
        /// entier sur huit octets coûtait donc seize octets pour en économiser
        /// trois. Mesuré sur une machine PC de 512 Mio portant 90 Mio de
        /// données réelles — l'initramfs d'Alpine et une table d'entiers —
        /// l'instantané pesait **169,8 Mio**, presque le double de ce qu'il
        /// contenait. Une suite plus courte que `minimumFoldedZeros` reste
        /// dans le littéral, où elle coûte ce qu'elle pèse.
        ///
        /// **Le lecteur n'a pas changé** : il lit n'importe quelle suite de
        /// paires, et les instantanés déjà écrits se relisent tels quels. Le
        /// cœur Rust applique la même règle ; `DifferentialBootTests` compare
        /// les deux octet pour octet.
        mutating func ram(_ ram: UnsafeRawBufferPointer) {
            u64(UInt64(ram.count))
            let countAt = bytes.count
            u64(0) // pair count, filled in below
            bytes.reserveCapacity(bytes.count + ram.count + 4096)
            var pairs: UInt64 = 0
            var index = 0
            let count = ram.count
            while index < count {
                let zerosFrom = index
                index = Snapshot.endOfZeros(ram, from: index)
                var zeros = index - zerosFrom
                var literalFrom = index
                // Une suite courte en tête de paire, suivie de données, est
                // du littéral comme les autres.
                if zeros < Snapshot.minimumFoldedZeros && index < count {
                    zeros = 0
                    literalFrom = zerosFrom
                }
                // Le littéral s'étend jusqu'à une longue suite de zéros, ou
                // jusqu'au bout.
                while index < count {
                    if ram[index] != 0 {
                        index = Snapshot.nextZero(ram, from: index + 1)
                        continue
                    }
                    let runFrom = index
                    index = Snapshot.endOfZeros(ram, from: index)
                    if index - runFrom >= Snapshot.minimumFoldedZeros || index == count {
                        index = runFrom
                        break
                    }
                }
                u64(UInt64(zeros))
                u64(UInt64(index - literalFrom))
                bytes.append(contentsOf: UnsafeRawBufferPointer(rebasing: ram[literalFrom..<index]))
                pairs += 1
            }
            withUnsafeBytes(of: pairs.littleEndian) { encoded in
                for (offset, byte) in encoded.enumerated() { bytes[countAt + offset] = byte }
            }
        }
    }

    /// La plus courte suite de zéros qui vaut une paire. Seize octets
    /// d'en-tête, et une marge : en dessous, replier ne rapporte rien.
    static let minimumFoldedZeros = 32

    /// Le premier octet non nul à partir de `index`, ou la fin.
    ///
    /// **Huit octets à la fois** quand l'alignement le permet : la mémoire
    /// d'un invité est surtout vide, et c'est cette boucle qui la parcourt à
    /// chaque passage en arrière-plan.
    static func endOfZeros(_ ram: UnsafeRawBufferPointer, from start: Int) -> Int {
        var index = start
        let count = ram.count
        guard let base = ram.baseAddress else { return count }
        while index < count && (Int(bitPattern: base) &+ index) & 7 != 0 && ram[index] == 0 {
            index += 1
        }
        while index + 8 <= count && base.loadUnaligned(fromByteOffset: index, as: UInt64.self) == 0 {
            index += 8
        }
        while index < count && ram[index] == 0 { index += 1 }
        return index
    }

    /// Le premier octet nul à partir de `index`, ou la fin.
    ///
    /// **Huit octets à la fois**, pour la même raison que `endOfZeros` : une
    /// session de Debian porte plus de deux cents mébioctets de données, et
    /// la première version les parcourait octet par octet. Un mot contient un
    /// octet nul exactement quand `(mot - 0x01…01) & ~mot & 0x80…80` ne vaut
    /// pas zéro ; on ne redescend à l'octet que dans ce mot-là.
    static func nextZero(_ ram: UnsafeRawBufferPointer, from start: Int) -> Int {
        var index = start
        let count = ram.count
        guard let base = ram.baseAddress else { return count }
        let ones: UInt64 = 0x0101_0101_0101_0101
        let highs: UInt64 = 0x8080_8080_8080_8080
        while index + 8 <= count {
            let word = base.loadUnaligned(fromByteOffset: index, as: UInt64.self)
            if (word &- ones) & ~word & highs != 0 { break }
            index += 8
        }
        while index < count && ram[index] != 0 { index += 1 }
        return index
    }

    // MARK: - Reading

    struct Reader {
        private let bytes: [UInt8]
        private var at: Int

        init(_ bytes: [UInt8]) throws {
            guard bytes.count >= Snapshot.magic.count,
                  Array(bytes[..<Snapshot.magic.count]) == Snapshot.magic else {
                throw Failure.notASnapshot
            }
            self.bytes = bytes
            at = Snapshot.magic.count
        }

        mutating func u32() throws -> UInt32 {
            try UInt32(littleEndian: scalar(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }

        mutating func u64() throws -> UInt64 {
            try UInt64(littleEndian: scalar(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        }

        private mutating func scalar(_ count: Int) throws -> [UInt8] {
            guard at + count <= bytes.count else { throw Failure.corrupt }
            defer { at += count }
            return Array(bytes[at..<(at + count)])
        }

        mutating func blob() throws -> [UInt8] {
            let length = try Int(exactly: u64()) ?? -1
            guard length >= 0, at + length <= bytes.count else { throw Failure.corrupt }
            defer { at += length }
            return Array(bytes[at..<(at + length)])
        }

        /// Fills `ram`, which must already be the saved size — the caller
        /// reports the mismatch, because it is the one that knows what the
        /// current machine is.
        mutating func ram(_ ram: UnsafeMutableRawBufferPointer) throws {
            let saved = try u64()
            guard saved == UInt64(ram.count) else {
                throw Failure.ramSizeMismatch(saved: saved, expected: UInt64(ram.count))
            }
            let pairs = try u64()
            // Recopies en bloc : un octet à la fois, la reprise d'une machine
            // de 512 Mio prenait une seconde et demie.
            var cursor = 0
            for _ in 0..<pairs {
                let zeros = try Int(exactly: u64()) ?? -1
                guard zeros >= 0, cursor + zeros <= ram.count else { throw Failure.corrupt }
                Self.clear(ram, from: cursor, count: zeros)
                cursor += zeros
                let length = try Int(exactly: u64()) ?? -1
                guard length >= 0, at + length <= bytes.count, cursor + length <= ram.count else {
                    throw Failure.corrupt
                }
                if length > 0, let target = ram.baseAddress {
                    bytes.withUnsafeBytes { source in
                        (target + cursor).copyMemory(
                            from: source.baseAddress! + at, byteCount: length)
                    }
                }
                at += length
                cursor += length
            }
            // Ce que les paires n'ont pas couvert est nul, comme avant.
            Self.clear(ram, from: cursor, count: ram.count - cursor)
        }

        /// Met à zéro `count` octets à partir de `start` — **seulement ceux
        /// qui ne le sont pas déjà.** Une machine qu'on reprend sort de
        /// `calloc` : ses pages ne sont pas encore fournies, et les lire rend
        /// toutes la même page nulle du système. Les écrire, même avec des
        /// zéros, les rendait résidentes une à une ; remettre toute la RAM à
        /// zéro avant de la recopier écrivait 512 Mio pour en restaurer deux
        /// cents, et une reprise pesait la machine entière dans l'hôte.
        static func clear(_ ram: UnsafeMutableRawBufferPointer, from start: Int, count: Int) {
            guard count > 0, let base = ram.baseAddress else { return }
            let region = UnsafeRawBufferPointer(start: base + start, count: count)
            let dirty = Snapshot.endOfZeros(region, from: 0)
            guard dirty < count else { return }
            (base + start + dirty).initializeMemory(as: UInt8.self, repeating: 0, count: count - dirty)
        }

        /// Whether every byte has been read.
        ///
        /// **A section that may be absent needs this**, and the x86 disk is
        /// one: a snapshot taken before the machine had a disk simply ends
        /// where the RAM ends. Refusing to read those would lose the machines
        /// already saved on people's phones, so their absence is read as
        /// "no disk" rather than as damage.
        var isAtEnd: Bool { at == bytes.count }

        /// Les huit prochains octets valent-ils cette marque, sans les
        /// prendre ?
        ///
        /// Deux sections facultatives se suivent maintenant en queue d'un
        /// instantané x86, et « il reste des octets » ne dit plus laquelle
        /// vient. Regarder sans consommer est ce qui permet de trancher tout
        /// en laissant un instantané d'avant se lire comme il se lisait.
        func peeks(_ mark: UInt64) -> Bool {
            guard at + 8 <= bytes.count else { return false }
            let seen = Array(bytes[at..<(at + 8)]).withUnsafeBytes {
                UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
            }
            return seen == mark
        }

        /// Refuses trailing bytes: a snapshot with something after its last
        /// section is one this build does not fully understand.
        func finish() throws {
            guard at == bytes.count else { throw Failure.corrupt }
        }
    }
}

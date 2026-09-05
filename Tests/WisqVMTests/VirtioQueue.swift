import Foundation

@testable import WisqVM

/// Conduire un disque virtio comme le pilote de Linux le conduit.
///
/// **Écrit une fois pour les deux machines.** La poignée de main, les anneaux
/// et la forme d'une requête ne dépendent ni du processeur ni de l'endroit où
/// la fenêtre est posée : ce sont le transport et la file, et ils sont les
/// mêmes octet pour octet. Ce qui change est où la RAM de l'invité commence —
/// zéro sur le PC, `0x8000_0000` sur la machine rv32 — d'où `base`.
///
/// Le harnais vivait dans les tests du PC, avec ses adresses en dur. Le
/// recopier pour la seconde machine aurait donné deux descriptions du même
/// protocole, à diverger dès la première correction.
struct VirtioQueue {
    /// Où la RAM de l'invité commence, dans son propre espace d'adressage.
    let base: UInt64

    /// Là où l'on pose la file. Des adresses rondes, loin les unes des autres,
    /// pour qu'un débordement se voie plutôt que de tomber dans le voisin.
    var descriptors: UInt64 { base + 0x1000 }
    var available: UInt64 { base + 0x2000 }
    var used: UInt64 { base + 0x3000 }
    var scratch: UInt64 { base + 0x4000 }
    let size: UInt32 = 8

    /// La poignée de main du pilote, dans son ordre.
    ///
    /// Se tromper d'une écriture fait dire au noyau « Wrong magic value » ou
    /// « device does not support VIRTIO_F_VERSION_1 », et le disque n'existe
    /// jamais.
    func start(_ device: VirtioBlock, _ memory: GuestMemory) {
        device.write(0x070, 4, 0, memory)      // remise à zéro
        device.write(0x070, 4, 1, memory)      // ACKNOWLEDGE
        device.write(0x070, 4, 3, memory)      // | DRIVER
        device.write(0x014, 4, 1, memory)      // les bits 32 à 63…
        device.write(0x024, 4, 1, memory)
        device.write(0x020, 4, device.read(0x010, 4), memory)
        device.write(0x070, 4, 11, memory)     // | FEATURES_OK
        device.write(0x030, 4, 0, memory)      // la file zéro
        device.write(0x038, 4, UInt64(size), memory)
        device.write(0x080, 4, descriptors & 0xFFFF_FFFF, memory)
        device.write(0x084, 4, descriptors >> 32, memory)
        device.write(0x090, 4, available & 0xFFFF_FFFF, memory)
        device.write(0x094, 4, available >> 32, memory)
        device.write(0x0A0, 4, used & 0xFFFF_FFFF, memory)
        device.write(0x0A4, 4, used >> 32, memory)
        device.write(0x044, 4, 1, memory)      // la file est prête
        device.write(0x070, 4, 15, memory)     // | DRIVER_OK
    }

    /// Un morceau de la mémoire de l'invité, tel qu'un descripteur le décrit :
    /// où il commence, combien il fait, et si c'est le périphérique qui y
    /// écrit. Les trois voyagent ensemble parce qu'ils ne veulent rien dire
    /// séparément.
    struct Span {
        var at: UInt64
        var length: UInt32
        var writable: Bool
    }

    /// Poser un descripteur.
    func describe(_ memory: GuestMemory, _ index: UInt64,
                  _ span: Span, next: UInt16?) throws {
        let at = descriptors + index * 16
        try memory.write(at, 8, span.at)
        try memory.write(at + 8, 4, UInt64(span.length))
        try memory.write(at + 12, 2, (span.writable ? 2 : 0) | (next != nil ? 1 : 0))
        try memory.write(at + 14, 2, UInt64(next ?? 0))
    }

    /// Une requête complète : l'en-tête, un tampon, l'octet de statut.
    func request(_ memory: GuestMemory, kind: UInt32, sector: UInt64,
                 buffer: Span) throws {
        let header = scratch
        try memory.write(header, 4, UInt64(kind))
        try memory.write(header + 4, 4, 0)
        try memory.write(header + 8, 8, sector)
        try describe(memory, 0, .init(at: header, length: 16, writable: false), next: 1)
        try describe(memory, 1, buffer, next: 2)
        try describe(memory, 2, .init(at: scratch + 0x800, length: 1, writable: true), next: nil)
        try memory.write(scratch + 0x800, 1, 0xFF)  // ni réussite ni échec
        // L'anneau des disponibles : l'entrée, puis l'index qui la publie.
        try memory.write(available + 4, 2, 0)
        try memory.write(available + 2, 2, 1)
    }

    func status(_ memory: GuestMemory) throws -> UInt64 {
        try memory.read(scratch + 0x800, 1)
    }
}

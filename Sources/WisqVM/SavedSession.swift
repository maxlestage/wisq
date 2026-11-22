import Foundation

/// **Ce qu'on trouve en ouvrant une machine** : rien, une session qui se
/// reprend, ou une session qu'on ne sait pas relire.
///
/// **Les deux derniers se confondaient.** `SuspendedMachine.load` rendait
/// `nil` pour un fichier absent comme pour un fichier illisible, et
/// l'application, devant une reprise refusée, démarrait le noyau à neuf sans
/// un mot. Cinq minutes plus tard, la sauvegarde continue écrasait la session
/// avec ce démarrage. Pour un bureau prêt téléchargé, c'est la perte du bureau
/// et une demi-heure de démarrage — et la cause la plus probable n'est même
/// pas un fichier abîmé : c'est une session prise par une version plus récente
/// de wisq (`X86Machine.snapshotLevel`), qu'une mise à jour saurait reprendre.
///
/// La règle : **une session illisible n'est ni reprise, ni remplacée.** Le
/// fichier reste où il est, rien ne démarre, et la personne lit pourquoi et
/// quoi faire (`explanation`). « Oublier » reste le geste qui repart de zéro.
///
/// Ici plutôt que dans l'application, comme `SessionMemory` : la décision se
/// juge sous Linux, la liaison seule est dans `LocalVMModel`.
public enum SavedSession: Sendable {
    /// Aucun fichier de session : un démarrage à froid.
    case none
    /// Une session lisible, décompressée, prête pour `restore`.
    case readable(Data)
    /// Un fichier est là, et il ne se reprend pas. Il est gardé.
    case unreadable(Unreadable)

    /// Pourquoi une session ne se reprend pas.
    public enum Unreadable: Error, Equatable, Sendable {
        /// Le fichier ne s'ouvre pas, n'est pas un instantané, ou une de ses
        /// sections est refusée : tronqué, abîmé, ou d'un autre format.
        case damaged
        /// Pris par une machine plus récente que celle-ci : voir
        /// `X86Machine.snapshotLevel`.
        case newerMachine(saved: UInt64, supported: UInt64)
        /// **Pris avec d'autres disques** que ceux que la machine a
        /// maintenant : un disque débranché, remplacé par un fichier d'une
        /// autre taille, ajouté, ou une image en mémoire là où vivait un
        /// fichier. La session n'a rien d'abîmé : rebranchée sur ses disques,
        /// elle se reprend. La machine PC en Rust le refuse
        /// (`RustPCMachine.Refusal.snapshotOfOtherDisks`, code -8) ; le cœur
        /// Swift reprend sur ce qu'il trouve.
        case otherDisks
    }

    /// **Un refus de reprise qui sait ce qu'il dit de la session** : la
    /// machine qui l'a levé vit hors de ce module (la machine PC en Rust,
    /// dans `WisqVMRust`), et c'est elle qui sait lequel de ses refus veut
    /// dire « d'autres disques ». Sans lui, tout refus inconnu se lit
    /// `damaged`.
    public protocol RefusalOfResume: Error {
        /// Ce que la personne doit en lire.
        var unreadableSession: Unreadable { get }
    }

    /// Les octets de la session, quand elle se reprend.
    public var snapshot: Data? {
        if case .readable(let data) = self { return data }
        return nil
    }

    /// La session de ce noyau, jugée.
    ///
    /// **Lue sans être recopiée** : le fichier est projeté en mémoire quand le
    /// système le permet (`.mappedIfSafe`), si bien qu'un fichier compressé ne
    /// pèse que le temps de sa décompression, et qu'un fichier d'avant la
    /// compression — l'instantané tel quel — est repris sur ses propres pages.
    public static func find(
        kernel: String, in directory: URL? = nil, core: GuestArchitecture.Core
    ) -> SavedSession {
        guard SuspendedMachine.exists(kernel: kernel, in: directory) else { return .none }
        guard let folder = try? (directory ?? SuspendedMachine.directory()),
              let file = try? Data(
                contentsOf: folder.appendingPathComponent(SuspendedMachine.fileName(kernel: kernel)),
                options: .mappedIfSafe),
              let snapshot = try? SnapshotFile.unpack(file)
        else { return .unreadable(.damaged) }
        return judge(snapshot, core: core)
    }

    /// Un instantané déjà décompressé, jugé par le cœur qui le reprendra :
    /// son niveau d'abord, puis tout ce qui précède sa mémoire.
    ///
    /// **Une session de la machine PC en Rust** (`WISQPC\r\n`) se juge par son
    /// en-tête (`RustPCSnapshot`) : sa version, puis sa mémoire. C'est elle
    /// qui décide du cœur qui la reprendra (`RustPCSetting.runs`), pas le
    /// réglage.
    public static func judge(_ snapshot: Data, core: GuestArchitecture.Core) -> SavedSession {
        if core == .x86_64, RustPCSnapshot.recognizes(snapshot) {
            guard let header = RustPCSnapshot.header(of: snapshot) else { return .unreadable(.damaged) }
            guard header.version <= RustPCSnapshot.version else {
                return .unreadable(.newerMachine(
                    saved: UInt64(header.version), supported: UInt64(RustPCSnapshot.version)))
            }
            // Plus ancienne : la version 1 ne portait pas la carte des
            // périphériques, et la machine la refuse (`Refusal.olderSnapshot`).
            guard header.version == RustPCSnapshot.version else { return .unreadable(.damaged) }
            return .readable(snapshot)
        }
        if core == .x86_64 {
            guard let level = X86Machine.savedLevel(in: snapshot) else { return .unreadable(.damaged) }
            guard level <= X86Machine.snapshotLevel else {
                return .unreadable(.newerMachine(saved: level, supported: X86Machine.snapshotLevel))
            }
        }
        guard SessionMemory.savedRAMSize(snapshot, core: core) != nil else { return .unreadable(.damaged) }
        return .readable(snapshot)
    }

    /// Ce que devient une reprise refusée par la machine elle-même — une
    /// section abîmée plus loin que ce que `judge` a lu.
    public static func unreadable(after error: Error) -> Unreadable {
        if let refusal = error as? Unreadable { return refusal }
        if let refusal = error as? RefusalOfResume { return refusal.unreadableSession }
        if case Snapshot.Failure.newerMachine(let saved, let supported)? = error as? Snapshot.Failure {
            return .newerMachine(saved: saved, supported: supported)
        }
        return .damaged
    }

    /// Ce que la personne lit, dans la console, à la place d'un démarrage.
    ///
    /// Trois choses, toujours : la session est gardée, pourquoi elle ne se
    /// reprend pas, et le geste qui repart de zéro si c'est ce qu'on veut.
    public static func explanation(_ refusal: Unreadable, name: String) -> String {
        switch refusal {
        case .damaged:
            return """
                La session de \(name) n'a pas pu être relue : le fichier est \
                abîmé, incomplet, ou d'un format que cette version de wisq ne \
                connaît pas.

                Rien n'a démarré, pour ne pas l'écraser : elle est gardée telle \
                quelle. Pour repartir de zéro, touchez « Oublier », puis \
                rouvrez la machine.
                """
        case .newerMachine(let saved, let supported):
            return """
                La session de \(name) a été sauvée par une version plus récente \
                de wisq (machine de niveau \(saved), celle-ci est de niveau \
                \(supported)).

                Elle est gardée telle quelle : mettez wisq à jour pour la \
                reprendre. Pour repartir de zéro à la place, touchez \
                « Oublier », puis rouvrez la machine.
                """
        case .otherDisks:
            return """
                La session de \(name) a été prise avec d'autres disques que \
                ceux que la machine a maintenant : un disque débranché, \
                remplacé par un autre fichier, ou ajouté depuis.

                Elle n'est pas abîmée, et elle est gardée telle quelle : \
                rebranchez le disque qu'elle avait — le même fichier, sous le \
                même nom — puis rouvrez la machine pour la reprendre. Si un \
                système vient d'être installé sur ce disque, « Démarrer \
                l'image d'installation » remet les disques de la session. \
                Pour repartir de zéro avec les disques d'aujourd'hui, touchez \
                « Oublier », puis rouvrez la machine.
                """
        }
    }
}

/// **L'en-tête d'un instantané de la machine PC en Rust**, lu côté Swift :
/// `WISQPC\r\n`, la version (32 bits), la mémoire (64 bits), petit-boutistes —
/// ce que `crates/wisq-vm/src/pc/instantane.rs` écrit en tête.
///
/// Ici, dans `WisqVM`, et pas dans `WisqVMRust` : la session se juge avant
/// qu'on construise la machine (`SavedSession.judge`, `SessionMemory`), et la
/// décision du cœur (`RustPCSetting.runs`) se juge sous Linux. Le test de
/// `RustPCMachineTests` vérifie que cette version est celle de la
/// bibliothèque.
public enum RustPCSnapshot {
    /// Les huit premiers octets.
    public static let magic = Array("WISQPC\r\n".utf8)
    /// La version que la machine PC en Rust écrit et reprend : la 2, qui
    /// porte la carte des périphériques.
    public static let version: UInt32 = 2

    /// **Est-ce un instantané de la machine PC en Rust ?** La marque seule :
    /// une session du cœur Swift ne commence jamais ainsi.
    public static func recognizes(_ snapshot: Data) -> Bool {
        snapshot.count >= magic.count && snapshot.prefix(magic.count).elementsEqual(magic)
    }

    /// La version et la mémoire, ou rien pour un en-tête tronqué, d'une autre
    /// marque, ou d'une mémoire qui ne tient pas dans un `Int`.
    public static func header(of snapshot: Data) -> (version: UInt32, ramSize: Int)? {
        guard recognizes(snapshot), snapshot.count >= magic.count + 12 else { return nil }
        let start = snapshot.startIndex + magic.count
        let version = snapshot[start..<start + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let ram = snapshot[start + 4..<start + 12].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard let ramSize = Int(exactly: ram) else { return nil }
        return (version, ramSize)
    }
}

/// **Les octets d'une session, gardés jusqu'à la reprise et pas plus.**
///
/// L'application lisait la session sur le fil principal, puis la donnait au
/// fil d'émulation dans la fermeture qui le fait tourner : la fermeture vit
/// autant que la machine, et l'instantané décompressé — 842 Mio pour le bureau
/// Xfce — restait en mémoire toute la session, à côté de la RAM de l'invité
/// qu'il venait de remplir. Cette boîte est ce que la fermeture capture ; la
/// reprise la vide, réussie ou non.
public final class PendingSession: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: Data?
    /// **Une session lisible attendait d'être reprise** quand la boîte a été
    /// faite. Fixé une fois : la reprise vide la boîte, pas ce fait.
    ///
    /// C'est ce que dit l'échec du démarrage sur le fil
    /// (`BootRefusal.couldNotStart`, `sessionKept:`) : la session qu'il n'a
    /// pas pu reprendre est gardée, et la console le promet. L'application le
    /// calculait elle-même, dans `LocalVMModel`, que rien ne juge sous Linux :
    /// une promesse forcée à faux, ou à vrai, n'y faisait tomber aucun test.
    public let awaited: Bool

    public init(_ snapshot: Data?) {
        self.snapshot = snapshot
        awaited = snapshot != nil
    }

    /// Reste-t-il une session à reprendre ?
    public var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return snapshot == nil
    }

    /// Reprend la session dans `machine` et relâche ses octets aussitôt.
    ///
    /// `false` quand il n'y a rien à reprendre : à l'appelant de démarrer à
    /// froid — et de ne lire qu'alors ce qu'un démarrage à froid demande,
    /// l'initramfs en tête. Une reprise refusée lève `SavedSession.Unreadable`
    /// et ne touche pas au fichier : c'est à l'appelant de le dire.
    ///
    /// **Reprise, la machine prend l'aléa de cet appareil** (`seed`, le
    /// générateur du système par défaut ; voir `GuestMachine.reseed`) : un
    /// bureau prêt du cœur Rust porte l'état du générateur de la fabrique, le
    /// même dans toutes les copies.
    public func resume(
        into machine: GuestMachine, seed: () -> UInt64 = { UInt64.random(in: .min ... .max) }
    ) throws -> Bool {
        guard let snapshot = take() else { return false }
        do {
            try machine.restore(snapshot)
        } catch {
            throw SavedSession.unreadable(after: error)
        }
        machine.reseed(seed())
        return true
    }

    /// Les octets, sortis de la boîte : la seule référence qui reste est
    /// celle de l'appelant, et elle finit avec lui.
    private func take() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let taken = snapshot
        snapshot = nil
        return taken
    }
}

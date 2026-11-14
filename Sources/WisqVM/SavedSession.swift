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
    public static func judge(_ snapshot: Data, core: GuestArchitecture.Core) -> SavedSession {
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
        }
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

    public init(_ snapshot: Data?) {
        self.snapshot = snapshot
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
    public func resume(into machine: GuestMachine) throws -> Bool {
        guard let snapshot = take() else { return false }
        do {
            try machine.restore(snapshot)
        } catch {
            throw SavedSession.unreadable(after: error)
        }
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

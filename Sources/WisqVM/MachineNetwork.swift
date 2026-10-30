import Foundation

/// **Couper le réseau d'une machine**, réglage par machine.
///
/// Par défaut, une machine PC sort par l'hôte (`UserNetwork.throughHost()`).
/// Une machine coupée garde sa carte et son bail — l'invité voit toujours
/// `10.0.2.15` et sa passerelle — mais rien ne sort : ni UDP, ni TCP, ni
/// ping. C'est un câble débranché du côté du routeur, pas une carte retirée.
///
/// **Pourquoi garder la carte.** L'instantané d'une machine porte sa carte
/// (`VirtioNet`) ; une machine reprise sans carte ne relirait pas le sien.
/// Garder la carte, c'est pouvoir couper ou rendre le réseau entre deux
/// reprises sans perdre la session, ce qu'un changement de mémoire, lui,
/// coûte.
///
/// **Le bureau reste** : le port relayé de l'hôte vers l'invité
/// (`HostStreams.forward`) ne sort pas de l'appareil, il y entre.
public enum MachineNetwork {
    /// Le réseau de cette machine est-il coupé ? Faux tant que personne n'a
    /// touché au réglage.
    public static func isCut(forKernel kernel: String, in directory: URL? = nil) -> Bool {
        recorded(in: directory).contains(kernel)
    }

    /// Coupe ou rend le réseau. Pris au prochain démarrage ou à la prochaine
    /// reprise.
    public static func setCut(_ cut: Bool, forKernel kernel: String, in directory: URL? = nil) {
        var all = recorded(in: directory)
        if cut { all.insert(kernel) } else { all.remove(kernel) }
        write(all, in: directory)
    }

    /// Oublie le réglage — pour une machine supprimée.
    public static func forget(kernel: String, in directory: URL? = nil) {
        setCut(false, forKernel: kernel, in: directory)
    }

    /// L'autre bout du câble pour cette machine : l'hôte, ou une passerelle
    /// qui ne mène nulle part.
    public static func backend(forKernel kernel: String, in directory: URL? = nil) -> UserNetwork {
        isCut(forKernel: kernel, in: directory) ? UserNetwork.isolated() : UserNetwork.throughHost()
    }

    // MARK: - Où il vit

    static let fileName = "machine-network-cut.json"

    private static func url(in directory: URL?) -> URL? {
        (directory ?? (try? SuspendedMachine.directory()))?.appendingPathComponent(fileName)
    }

    /// Un fichier illisible se lit comme « rien de coupé » : le pire qui
    /// puisse arriver est le réseau, ce qu'avait toute machine avant ce
    /// réglage.
    private static func recorded(in directory: URL?) -> Set<String> {
        guard let url = url(in: directory),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(decoded)
    }

    private static func write(_ all: Set<String>, in directory: URL?) {
        guard let url = url(in: directory) else { return }
        if all.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(all.sorted()).write(to: url, options: .atomic)
    }
}

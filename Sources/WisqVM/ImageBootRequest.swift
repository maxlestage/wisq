import Foundation

/// **Démarrer l'image d'installation, une fois.**
///
/// Une machine dont le disque porte un système installé démarre ce disque
/// (`IsoBoot.decide`, `InstalledSystem`). Il faut pourtant pouvoir revenir à
/// l'image : réparer un système qui ne démarre plus, réinstaller, récupérer
/// des fichiers depuis l'environnement de l'image. Un PC a pour ça son menu
/// de démarrage, qui vaut pour un démarrage et pas pour les suivants.
///
/// C'est la même chose ici : une demande posée sous la clé de la machine, que
/// le démarrage suivant **consomme** (`take`). Une demande permanente aurait
/// laissé la machine revenir à l'image à chaque fois, ce qui est l'inverse de
/// ce qu'une installation finie demande.
public enum ImageBootRequest {
    /// Demande que le prochain démarrage de cette machine prenne son image.
    public static func request(forKernel kernel: String, in directory: URL? = nil) {
        var all = recorded(in: directory)
        all.insert(kernel)
        write(all, in: directory)
    }

    /// La demande est-elle posée ? Sans la consommer : de quoi l'afficher.
    public static func isRequested(forKernel kernel: String, in directory: URL? = nil) -> Bool {
        recorded(in: directory).contains(kernel)
    }

    /// **La demande, consommée** : vrai une fois, puis faux jusqu'à la
    /// suivante. C'est ce que le démarrage appelle.
    public static func take(forKernel kernel: String, in directory: URL? = nil) -> Bool {
        var all = recorded(in: directory)
        guard all.remove(kernel) != nil else { return false }
        write(all, in: directory)
        return true
    }

    /// Oublie la demande — pour une machine supprimée.
    public static func forget(kernel: String, in directory: URL? = nil) {
        _ = take(forKernel: kernel, in: directory)
    }

    // MARK: - Où elle vit

    static let fileName = "image-boot-requests.json"

    private static func url(in directory: URL?) -> URL? {
        (directory ?? (try? SuspendedMachine.directory()))?.appendingPathComponent(fileName)
    }

    /// Un fichier illisible se lit comme « aucune demande » : le pire qui
    /// puisse arriver est un démarrage du disque, ce que fait la machine
    /// sans demande.
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
        try? JSONEncoder().encode(all.sorted()).write(to: url, options: .atomic)
    }
}

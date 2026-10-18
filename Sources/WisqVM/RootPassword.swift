import Foundation

/// Le mot de passe de `root` d'une image de cloud, **gardé en empreinte**.
///
/// La personne le donne une fois, au premier démarrage. wisq n'en garde que
/// l'empreinte `$6$` (`SHA512Crypt`), sur un sel tiré pour elle : c'est tout
/// ce que `systemd-firstboot` demande, et un fichier de l'application qui
/// fuirait ne dirait pas le mot de passe. La même empreinte resservira aux
/// démarrages suivants : `systemd-firstboot` ne change rien à un système déjà
/// mis en route, et une image remise à neuf retrouve le même mot de passe.
///
/// Rangé sous la clé de réglages de la machine, comme sa mémoire
/// (`KernelMemory`) : le nom du fichier pour une image démarrée telle quelle,
/// l'identifiant pour une machine installée. Dans `WisqVM` pour la raison que
/// donne `KernelMemory` : écrire, relire et survivre à un fichier abîmé se
/// testent ici.
public enum RootPassword {
    static let fileName = "root-passwords.json"

    /// L'empreinte gardée pour cette clé, ou `nil`. Une empreinte que
    /// `isHash` refuse se lit comme absente : elle ne passerait pas sur la
    /// ligne de commande.
    public static func hash(forKernel kernel: String, in directory: URL? = nil) -> String? {
        recorded(in: directory)[kernel].flatMap { isHash($0) ? $0 : nil }
    }

    /// Garde l'empreinte de `password`. Faux, et rien d'écrit, pour un mot de
    /// passe que `CloudBoot.acceptsAsRootPassword` refuse.
    @discardableResult
    public static func set(_ password: String, forKernel kernel: String, in directory: URL? = nil) -> Bool {
        guard CloudBoot.acceptsAsRootPassword(password) else { return false }
        var all = recorded(in: directory)
        all[kernel] = SHA512Crypt.hash(password, salt: CloudBoot.randomSalt())
        write(all, in: directory)
        return true
    }

    /// **« Sans mot de passe », retenu** : la question ne revient pas à
    /// chaque démarrage. `root` s'ouvre alors seul sur la console série, et
    /// reste verrouillé ailleurs (voir `CloudBoot.firstbootOptions`).
    public static func decline(forKernel kernel: String, in directory: URL? = nil) {
        var all = recorded(in: directory)
        all[kernel] = declined
        write(all, in: directory)
    }

    /// Ce que vaut une réponse « sans mot de passe » dans le fichier : rien
    /// qui puisse passer pour une empreinte.
    static let declined = "-"

    /// **Faut-il demander, avant de démarrer ce fichier ?** Oui pour une
    /// image de cloud dont la question n'a jamais reçu de réponse — ni mot de
    /// passe, ni « sans ».
    public static func shouldAsk(fileAt url: URL, forKernel kernel: String, in directory: URL? = nil) -> Bool {
        recorded(in: directory)[kernel] == nil && CloudBoot.isCloudImage(fileAt: url)
    }

    /// Oublie le mot de passe d'une clé : un fichier supprimé, une machine
    /// retirée.
    public static func forget(kernel: String, in directory: URL? = nil) {
        var all = recorded(in: directory)
        guard all.removeValue(forKey: kernel) != nil else { return }
        write(all, in: directory)
    }

    /// Donne à `target` l'empreinte de `source`, ou aucune : pour une
    /// machine dupliquée, dont le disque porte le même système.
    public static func copy(from source: String, to target: String, in directory: URL? = nil) {
        var all = recorded(in: directory)
        guard all[target] != all[source] else { return }
        all[target] = all[source]
        write(all, in: directory)
    }

    /// Une empreinte `$6$` que la ligne de commande peut porter : rien que
    /// l'alphabet de `crypt`, les `$` qui séparent ses champs et le `=` de
    /// `rounds=`. Une espace la couperait en deux options.
    public static func isHash(_ text: String) -> Bool {
        let allowed = Set(SHA512Crypt.alphabet + Array("$=".utf8))
        return text.hasPrefix("$6$") && text.utf8.count > 3 && text.utf8.allSatisfy { allowed.contains($0) }
    }

    private static func url(in directory: URL?) -> URL? {
        let base = directory ?? (try? SuspendedMachine.directory())
        return base?.appendingPathComponent(fileName)
    }

    private static func recorded(in directory: URL?) -> [String: String] {
        guard let url = url(in: directory),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func write(_ all: [String: String], in directory: URL?) {
        guard let url = url(in: directory) else { return }
        if all.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

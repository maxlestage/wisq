import Foundation

/// **La toute première reprise d'un bureau prêt téléchargé** : l'heure du
/// téléphone et de l'aléa neuf, donnés une fois à l'invité.
///
/// **Ce qui n'allait pas.** Un bureau prêt a été démarré à la fabrique, sous
/// une horloge figée (`ReadyDesktopBuild.machine`), puis mis en pause. Sa
/// session arrive sur le téléphone par l'import de l'archive, qui écrit le
/// fichier **au moment de l'import** : la reprise ordinaire
/// (`GuestMachine.elapse(since:)`) rattrapait donc les quelques minutes entre
/// l'import et l'ouverture, et l'invité restait au jour de la fabrication —
/// certificats TLS « pas encore valides », signatures de paquets refusées.
/// Donner au fichier la date de la fabrication n'aurait pas mieux valu : des
/// semaines à rattraper par pas de dix secondes, et tout ce qui compte en
/// temps monotone (l'écran de veille d'Xorg) les aurait vues passer.
///
/// **Ce qui est fait, une seule fois** : pas de rattrapage, et deux commandes
/// tapées sur la console série, où la fabrique a laissé un shell `root` à son
/// invite (`ReadyDesktopBuild.voidXfce`) :
///
/// - `date -s @$(cat /sys/class/rtc/rtc0/since_epoch)` : l'heure murale de
///   l'invité prend d'un coup celle de son horloge CMOS, que le téléphone
///   sert depuis la sienne, en UTC (`X86CMOSClock`) ; son temps monotone ne
///   bouge pas. Lue **par l'invité, au moment où il exécute la ligne**, et pas
///   tapée en chiffres par l'hôte : sous l'interprète, la ligne s'exécute
///   quelques secondes après avoir été tapée, et un nombre tapé serait déjà
///   en retard. `date -s` plutôt que `hwclock -s` : ce dernier lit
///   `/etc/adjtime`, qui peut dire « heure locale » ; le fichier du noyau,
///   lui, est en UTC sans réglage à croire.
/// - `echo <64 chiffres> > /dev/urandom` : 32 octets tirés de l'aléa du
///   téléphone, mêlés au réservoir du noyau. L'état du générateur est dans
///   l'instantané, le même pour toutes les copies ; `RDSEED` et `RDRAND`
///   (`X86Entropy`) le font déjà diverger au réensemencement suivant, et ceci
///   y ajoute de l'aléa qui ne doit rien au processeur émulé.
///
/// **« Une seule fois »** se tient par une marque posée à côté de la session
/// par l'installation (`arm`) et **retirée par la première écriture de cette
/// session** (`SuspendedMachine.savePacked`) : tant que le fichier sur le
/// disque est celui qui a été téléchargé, la reprise est une première reprise.
/// Une application tuée avant sa première sauvegarde rouvre donc le bureau
/// téléchargé, et lui redonne l'heure ; une reprise après une sauvegarde est
/// une reprise ordinaire, qui rattrape.
///
/// Ici plutôt que dans l'application, comme `SavedSession` : la décision se
/// juge sous Linux, la liaison seule est dans `LocalVMModel`.
public struct FirstResume: Codable, Equatable, Sendable {
    /// Le jour de la fabrication, pour la phrase ; `nil` quand la marque ne
    /// le dit pas.
    public var madeAt: Date?

    public init(madeAt: Date?) {
        self.madeAt = madeAt
    }

    // MARK: - La marque

    /// Ce qu'on ajoute au nom du fichier de session. **Pas `.wisqvm` à la
    /// fin** : `SuspendedMachine.savedMachineFiles` ne la prend pas pour une
    /// session, ni l'export pour un fichier à emporter.
    public static let markerSuffix = ".premiere"

    static func markerURL(kernel: String, in directory: URL?) throws -> URL {
        let folder = try directory ?? SuspendedMachine.directory()
        return folder.appendingPathComponent(SuspendedMachine.fileName(kernel: kernel) + markerSuffix)
    }

    /// **Poser la marque** : la session `kernel` (son identité, voir
    /// `SuspendedMachine.identity`) est un bureau prêt jamais repris ici.
    public static func arm(_ first: FirstResume, kernel: String, in directory: URL? = nil) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(first).write(to: markerURL(kernel: kernel, in: directory), options: .atomic)
    }

    /// La première reprise qui attend cette session, ou `nil`.
    ///
    /// **Une marque sans session ne compte pas** : il n'y a rien à reprendre,
    /// et la session qu'un démarrage à froid écrira ensuite la retirera.
    /// **Une marque illisible compte quand même**, sans date : remettre
    /// l'heure importe plus que la phrase.
    public static func pending(kernel: String, in directory: URL? = nil) -> FirstResume? {
        guard SuspendedMachine.exists(kernel: kernel, in: directory),
              let url = try? markerURL(kernel: kernel, in: directory),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let first = try? decoder.decode(FirstResume.self, from: data)
        else { return FirstResume(madeAt: nil) }
        return first
    }

    /// Retirer la marque : la session n'est plus celle qui a été téléchargée.
    public static func disarm(kernel: String, in directory: URL? = nil) {
        guard let url = try? markerURL(kernel: kernel, in: directory) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Ce qu'on tape

    /// Combien d'octets d'aléa du téléphone on donne à l'invité : ce que
    /// tient l'état du générateur de Linux (une clé ChaCha20).
    public static let entropyBytes = 32

    /// L'horloge CMOS telle que l'invité la lit (`rtc_cmos`, relue à chaque
    /// lecture) : celle que le guetteur des clés surveille déjà.
    public static let rtcSeconds = ReadyDesktopBuild.rtcSeconds

    /// **La ligne tapée sur la console**, l'heure puis l'aléa. `entropy` est
    /// écrit en hexadécimal : la console série transporte du texte, et
    /// `/dev/urandom` mêle tout ce qu'on lui écrit.
    public static func commands(entropy: [UInt8]) -> String {
        let hex = entropy.map { String(format: "%02x", $0) }.joined()
        return "date -s @$(cat \(rtcSeconds)) >/dev/null; echo \(hex) > /dev/urandom\n"
    }

    /// L'aléa du téléphone (`SystemRandomNumberGenerator` : celui du système,
    /// sur iOS comme sous Linux).
    public static func hostEntropy() -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<entropyBytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    // MARK: - La reprise

    /// **Ce que la reprise fait de l'heure**, sur une machine qui vient d'être
    /// reprise et ne tourne pas encore : sans première reprise, le temps passé
    /// depuis la sauvegarde est rattrapé (`elapse(since:)`) ; avec, rien n'est
    /// rattrapé et la ligne est tapée. Rend ce qui a été tapé, ou `nil`.
    @discardableResult
    public static func resumed(
        _ machine: GuestMachine, first: FirstResume?, savedAt: Date?, now: Date = Date(),
        entropy: () -> [UInt8] = FirstResume.hostEntropy
    ) -> String? {
        guard first != nil else {
            machine.elapse(since: savedAt, now: now)
            return nil
        }
        let line = commands(entropy: entropy())
        machine.send(Data(line.utf8))
        return line
    }

    /// La phrase de la console, à la place de celle d'une reprise ordinaire
    /// (`ResumeNote`) : la console d'une première reprise est vide, et la
    /// ligne tapée qui va s'y afficher mérite une explication.
    public var note: String {
        let day = madeAt.map { " du \(ReadyDesktop.frenchDate($0))" } ?? ""
        return "Bureau prêt\(day), repris pour la première fois : l'heure du téléphone et un aléa neuf "
            + "lui sont donnés par la ligne qui suit."
    }
}

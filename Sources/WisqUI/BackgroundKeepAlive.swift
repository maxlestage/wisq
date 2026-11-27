#if os(iOS)
import AVFoundation
import UIKit

/// **Ce qui garde l'application en vie pendant qu'une machine tourne hors de
/// l'écran** : une session audio ouverte, qui ne joue que du silence.
///
/// iOS suspend une application d'arrière-plan en quelques secondes. Il laisse
/// tourner celles qui déclarent un mode d'arrière-plan (`UIBackgroundModes`,
/// ici `audio`) **et s'en servent** : la déclaration seule ne suffit pas, il
/// faut un son en cours. La décision — continuer ou mettre de côté — vit dans
/// `WisqVM.BackgroundRun`, jugée sous Linux ; ceci n'est que le branchement
/// sur la plateforme, que seule la compilation d'iOS voit.
///
/// **Mêlée aux autres** (`mixWithOthers`) : la musique de la personne
/// continue, rien n'est coupé ni baissé.
///
/// **Ce qui la prend** : un appel, une alarme, Siri. iOS interrompt alors la
/// session, et l'application sera suspendue dans les secondes qui suivent.
/// `onLost` le dit à qui tient la machine, qui la met de côté comme avant.
///
/// **Pas mesuré sur un appareil** : écrit contre la documentation d'Apple,
/// compilé par la CI, jamais lancé par elle.
///
/// Le modèle ne le connaît qu'à travers `BackgroundHold` : les tests y
/// passent le leur, et ne dépendent pas de ce qu'un simulateur fait d'une
/// session audio.
public struct BackgroundHold: Sendable {
    /// Ouvre ce qui tient l'application en vie. Faux : iOS a refusé.
    public var start: @MainActor @Sendable () -> Bool
    public var stop: @MainActor @Sendable () -> Void
    /// Donne quoi appeler quand iOS le reprend.
    public var whenLost: @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    public init(start: @escaping @MainActor @Sendable () -> Bool,
                stop: @escaping @MainActor @Sendable () -> Void,
                whenLost: @escaping @MainActor @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void) {
        self.start = start
        self.stop = stop
        self.whenLost = whenLost
    }

    /// La session audio silencieuse : voir `BackgroundKeepAlive`.
    public static let audio = BackgroundHold(
        start: { BackgroundKeepAlive.shared.start() },
        stop: { BackgroundKeepAlive.shared.stop() },
        whenLost: { BackgroundKeepAlive.shared.onLost = $0 })

    /// Rien ne tient l'application : une machine est mise de côté en
    /// arrière-plan, comme avant.
    public static let nothing = BackgroundHold(start: { false }, stop: {}, whenLost: { _ in })
}

@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    /// Appelé quand iOS a pris la session et qu'elle n'a pas pu être rouverte.
    var onLost: (@MainActor @Sendable () -> Void)?

    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observers: [any NSObjectProtocol] = []

    private init() {}

    var isHolding: Bool { engine?.isRunning == true }

    /// Ouvre la session et joue le silence. Rend faux quand iOS refuse — ce
    /// qu'il fait d'une session demandée par une application déjà en
    /// arrière-plan : c'est pourquoi le modèle l'ouvre dès que la scène
    /// devient inactive, avant de quitter l'écran.
    @discardableResult
    func start() -> Bool {
        if isHolding { return true }
        tearDown()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100) else { return false }
        silence.frameLength = silence.frameCapacity
        // Rien ne dit que le tampon arrive à zéro.
        if let samples = silence.floatChannelData {
            samples[0].update(repeating: 0, count: Int(silence.frameLength))
        }
        let session = AVAudioSession.sharedInstance()
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            return false
        }
        player.scheduleBuffer(silence, at: nil, options: .loops, completionHandler: nil)
        player.play()
        self.engine = engine
        self.player = player
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                               queue: .main) { [weak self] note in
                let kind = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let began = kind == AVAudioSession.InterruptionType.began.rawValue
                // **Sur place**, pas dans une tâche : la file est la
                // principale, et iOS suspend l'application dans les secondes
                // qui suivent — la mise de côté ne peut pas attendre un tour.
                if began { MainActor.assumeIsolated { self?.lost() } }
            },
            // Une sortie qui change (des écouteurs retirés) arrête le moteur.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reopen() }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reopen() }
            },
        ]
        return true
    }

    func stop() {
        onLost = nil
        tearDown()
    }

    /// **Le temps de finir, quand iOS reprend la main** : une tâche
    /// d'arrière-plan autour de `work`, qui laisse à la mise de côté de quoi
    /// écrire la machine avant la suspension.
    static func whileStillAwake(_ work: () -> Void) {
        let task = UIApplication.shared.beginBackgroundTask(withName: "app.wisq.mise-de-cote")
        work()
        if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
    }

    private func reopen() {
        guard engine != nil else { return }
        let handler = onLost
        tearDown()
        if start() {
            onLost = handler
        } else {
            handler?()
        }
    }

    private func lost() {
        guard engine != nil else { return }
        let handler = onLost
        onLost = nil
        tearDown()
        handler?()
    }

    private func tearDown() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        player?.stop()
        engine?.stop()
        let wasOpen = engine != nil
        player = nil
        engine = nil
        if wasOpen {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
#endif

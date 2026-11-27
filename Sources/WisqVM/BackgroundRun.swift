import Foundation

/// **Ce que devient une machine quand l'application part en arrière-plan.**
///
/// Elle était mise de côté d'office (`LocalVMModel.suspend`) : sauvée,
/// arrêtée, reprise au retour. Un démarrage de dix minutes demandait donc de
/// garder l'application à l'écran dix minutes. Maxime l'a demandé autrement :
/// « quand je réduis la fenêtre en arrière-plan ça doit continuer ».
///
/// iOS suspend une application d'arrière-plan en quelques secondes, sauf
/// celles qui déclarent un mode d'arrière-plan et s'en servent. L'application
/// tient donc une session audio ouverte (`BackgroundKeepAlive`, dans
/// `WisqUI`) pendant qu'une machine tourne hors de l'écran. **La règle est
/// ici**, jugée sous Linux : la machine continue seulement si le réglage le
/// veut, qu'une machine tourne et que le garde-en-vie a pris ; sinon elle est
/// mise de côté comme avant, et rien n'est perdu.
///
/// **Ce que ça coûte, et ce qui n'est pas mesuré.** La batterie, d'abord. Et
/// une session audio qui ne joue que du silence n'est pas ce qu'Apple attend
/// du mode `audio` : une revue de l'App Store peut la refuser. Sur un
/// appareil, iOS peut aussi arrêter une application d'arrière-plan qui tient
/// un cœur trop longtemps : la machine y tourne à une allure réduite
/// (`restShare`), et une sauvegarde est demandée à l'entrée
/// (`CheckpointedRun.checkpointNow`) pour reprendre de là si elle est arrêtée
/// quand même.
public enum BackgroundRun {
    public static let key = "wisq.machine.arriere-plan"
    /// **Allumé** : une machine qui tourne continue hors de l'écran.
    public static let defaultValue = true

    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    /// La part du temps où le fil d'émulation se repose en arrière-plan. iOS
    /// tolère d'une application qu'on ne regarde pas 80 % d'un cœur sur une
    /// minute, tous fils confondus : 60 % pour l'émulation laisse le reste à
    /// la compression des sauvegardes et à l'affichage. Un choix prudent, pas
    /// une mesure.
    public static let restShare = 0.4

    public enum Verdict: Equatable, Sendable {
        /// La machine continue, à allure réduite, la session audio ouverte.
        case keepRunning
        /// Comme avant : sauvée, arrêtée, reprise au retour.
        case setAside
    }

    /// `keepAlive` n'est appelé que si tout le reste dit de continuer : il
    /// ouvre la session audio, et rend faux quand iOS la refuse.
    public static func whenLeaving(enabled: Bool, machineRunning: Bool, keepAlive: () -> Bool) -> Verdict {
        guard enabled, machineRunning, keepAlive() else { return .setAside }
        return .keepRunning
    }
}

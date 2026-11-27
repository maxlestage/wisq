import SwiftUI
import UIKit
import WisqUI

/// Le réveil des téléchargements en arrière-plan : le système relance wisq
/// pour lui rendre un fichier, et c'est par ici qu'il le dit.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundDownloads.reconnect()
        application.isIdleTimerDisabled = true
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundDownloads.handleEvents(forSession: identifier, completion: completionHandler)
    }
}

@main
struct WisqApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.indigo)
        }
        // **L'écran reste allumé tant que l'application est ouverte**, partout
        // et pas seulement devant une machine : un démarrage se regarde sans
        // toucher l'écran, et un téléphone qui se verrouille l'envoie en
        // arrière-plan. Redit à chaque retour au premier plan.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { UIApplication.shared.isIdleTimerDisabled = true }
        }
    }
}

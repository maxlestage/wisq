import SwiftUI
import UIKit
import WisqUI

/// Le réveil des téléchargements en arrière-plan : le système relance wisq
/// pour lui rendre un fichier, et c'est par ici qu'il le dit.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundDownloads.handleEvents(forSession: identifier, completion: completionHandler)
    }
}

@main
struct WisqApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.indigo)
        }
    }
}

#if os(iOS)
import SwiftUI
import UIKit
import XCTest

/// **La photographie d'un écran de l'application**, sans rien lui ajouter.
///
/// Ce paquet de tests est hébergé par l'application (`TEST_HOST`) : il tourne
/// dans son processus, donc dans sa scène, et pose chaque vue dans une fenêtre
/// à lui, au-dessus de celle de l'application. La fenêtre est dessinée par
/// `drawHierarchy`, qui rend ce que l'écran montrerait — listes, barres de
/// navigation, matières floues comprises —, là où `ImageRenderer` ne rend pas
/// les vues que UIKit porte (une `List`, un champ de texte).
///
/// **Les données sont posées par le test**, dans le bac à sable de
/// l'application du simulateur : rien de ce mode n'est dans l'application, et
/// rien ne peut donc s'y allumer chez quelqu'un.
@MainActor
enum Apercu {
    /// Clair, sombre, et clair à une grande taille de texte.
    struct Variante {
        let nom: String
        let sombre: Bool
        let texte: DynamicTypeSize
        let categorie: UIContentSizeCategory
    }

    static let variantes = [
        Variante(nom: "clair", sombre: false, texte: .large, categorie: .large),
        Variante(nom: "sombre", sombre: true, texte: .large, categorie: .large),
        Variante(nom: "texte-xxl", sombre: false, texte: .accessibility3,
                 categorie: .accessibilityExtraLarge),
    ]

    /// Où les PNG vont : `WISQ_APERCUS` quand le workflow le donne
    /// (`TEST_RUNNER_WISQ_APERCUS` pour `xcodebuild`), sinon un dossier
    /// temporaire, dit dans le journal.
    static let dossier: URL = {
        let chemin = ProcessInfo.processInfo.environment["WISQ_APERCUS"]
        let dossier = chemin.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("apercus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        print("aperçus : \(dossier.path)")
        return dossier
    }()

    /// Photographie `vue` dans chaque variante : `nom-clair.png`,
    /// `nom-sombre.png`, `nom-texte-xxl.png`. La vue est refaite pour chacune,
    /// pour que l'état de l'une ne passe pas à l'autre.
    ///
    /// `attente` laisse aux tâches de la vue (`.task`, une première image de
    /// l'écran de l'invité) le temps de se faire.
    static func photographier<Contenu: View>(
        _ nom: String, test: XCTestCase, attente: Double = 1.5,
        @ViewBuilder _ vue: () -> Contenu
    ) async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "l'application hôte n'a pas de scène")
        for variante in variantes {
            let fenetre = UIWindow(windowScene: scene)
            fenetre.windowLevel = .alert + 1
            fenetre.overrideUserInterfaceStyle = variante.sombre ? .dark : .light
            fenetre.traitOverrides.preferredContentSizeCategory = variante.categorie
            let hote = UIHostingController(
                rootView: vue()
                    .tint(.indigo)
                    .environment(\.dynamicTypeSize, variante.texte))
            hote.traitOverrides.preferredContentSizeCategory = variante.categorie
            fenetre.rootViewController = hote
            fenetre.isHidden = false
            try await Task.sleep(nanoseconds: UInt64(attente * 1_000_000_000))

            let format = UIGraphicsImageRendererFormat(for: fenetre.traitCollection)
            format.opaque = true
            let image = UIGraphicsImageRenderer(bounds: fenetre.bounds, format: format).image { _ in
                fenetre.drawHierarchy(in: fenetre.bounds, afterScreenUpdates: true)
            }
            let fichier = dossier.appendingPathComponent("\(nom)-\(variante.nom).png")
            let octets = try XCTUnwrap(image.pngData(), "\(nom) : PNG impossible")
            try octets.write(to: fichier, options: .atomic)

            let piece = XCTAttachment(image: image)
            piece.name = "\(nom)-\(variante.nom)"
            piece.lifetime = .keepAlways
            test.add(piece)

            fenetre.isHidden = true
            fenetre.rootViewController = nil
            // Le temps que la vue quitte l'écran (`onDisappear`) avant la
            // suivante.
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
#endif

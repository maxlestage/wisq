#if os(iOS)
import SwiftUI
import WisqCore
@testable import WisqUI
@testable import WisqVM
import XCTest

/// **Les écrans clés de l'application, photographiés** : ce que lance le
/// workflow « Aperçus » (`.github/workflows/apercus.yml`), et lui seul — la
/// scheme `Wisq` ne nomme pas ce paquet, et la CI ne le lance donc jamais.
///
/// Chaque test pose ses données (`Demonstration`), ouvre un écran et le
/// photographie en clair, en sombre et en grand texte (`Apercu`). Les
/// assertions sont celles qu'il faut pour qu'une image vide ne passe pas
/// pour un aperçu : la scène existe, le PNG s'écrit.
@MainActor
final class ApercusTests: XCTestCase {
    func test01AccueilVide() async throws {
        try Demonstration.toutEffacer()
        try await Apercu.photographier("01-accueil-vide", test: self) {
            NavigationStack { LocalVMListView(onRemote: {}) }
        }
    }

    func test02Machines() async throws {
        try Demonstration.bibliotheque()
        try await Apercu.photographier("02-machines", test: self) {
            NavigationStack { LocalVMListView(onRemote: {}) }
        }
    }

    func test03MachineEcran() async throws {
        let machines = try Demonstration.bibliotheque()
        let image = try KernelLibrary.directory().appendingPathComponent(Demonstration.void)
        try await Apercu.photographier("03-machine-ecran", test: self, attente: 2) {
            NavigationStack {
                LocalVMTerminalView(kernelURL: image, installed: machines.void, posed: Self.enMarche(
                    console: [], ecran: Demonstration.bureauXfce(),
                    battement: "1,24 G instructions · 412 MIPS"))
            }
        }
    }

    func test04MachineConsole() async throws {
        try Demonstration.bibliotheque()
        let image = try KernelLibrary.directory().appendingPathComponent(Demonstration.alpine)
        try await Apercu.photographier("04-machine-console", test: self) {
            NavigationStack {
                LocalVMTerminalView(kernelURL: image, posed: Self.enMarche(
                    console: Demonstration.consoleAlpine, ecran: nil,
                    battement: "312 M instructions · 96 MIPS"))
            }
        }
    }

    func test05Telechargement() async throws {
        try Demonstration.bibliotheque()
        let bureau = Demonstration.bureauPret()
        try await Apercu.photographier("05-telechargement", test: self) {
            ImageDownloadSheet(posed: ImageDownloadModel(
                posing: [bureau], releases: Demonstration.images(),
                phase: .fetchingDesktop(title: bureau.title),
                desktopProgress: ReadyDesktop.Progress(
                    step: .image, number: 1, steps: 2, have: 612 << 20, total: 1_400 << 20 + 384 << 20)))
        }
    }

    func test06Connexions() async throws {
        let bibliotheque = Demonstration.connexions(Demonstration.machinesDistantes)
        XCTAssertEqual(bibliotheque.machines.count, Demonstration.machinesDistantes.count)
        try await Apercu.photographier("06-connexions", test: self) {
            NavigationStack {
                MachineListView(library: bibliotheque, onConnect: { _ in }, onEdit: { _ in }, onNew: {},
                                onImportFromAgent: {}, onOpenConnectionFile: {}, onBench: {})
            }
        }
    }

    func test07Editeur() async throws {
        let bibliotheque = Demonstration.connexions(Demonstration.machinesDistantes)
        let machine = try XCTUnwrap(bibliotheque.machines.first { $0.proto == .spice })
        try await Apercu.photographier("07-editeur", test: self) {
            NavigationStack {
                MachineEditorView(draft: MachineDraft(machine: machine), library: bibliotheque) {}
            }
        }
    }

    func test08Banc() async throws {
        try Demonstration.toutEffacer()
        try await Apercu.photographier("08-banc", test: self) {
            NavigationStack { WebKitBenchView() }
        }
    }

    /// Un modèle de machine posé en marche, sans noyau.
    private static func enMarche(console: [String], ecran: (any GuestScreen)?, battement: String)
        -> LocalVMModel {
        let modele = LocalVMModel()
        modele.pose(status: .running, consoleLines: console, screen: ecran, heartbeat: battement)
        return modele
    }
}
#endif

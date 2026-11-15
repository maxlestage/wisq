import Foundation
import XCTest
@testable import WisqVM

/// **L'attente de la première reprise d'un bureau prêt** (`ResumeWait`) :
/// une phrase qui compte les secondes depuis le toucher, dit quand c'est plus
/// long que d'habitude, et se tait au premier octet de l'invité.
final class ResumeWaitTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_794_614_400)

    /// **Comptée depuis le toucher, puis à chaque seconde** : l'attente ordinaire est
    /// nommée, sans crier à la panne.
    func testTheWaitIsSaidFromTheFirstTouch() {
        let wait = ResumeWait(since: start)
        XCTAssertEqual(wait.phrase(now: start),
                       "Reprise du bureau en cours — 0 s. L'écran ne répond pas encore : la console répond "
                        + "d'habitude en 11 à 15 s.")
        XCTAssertEqual(wait.phrase(now: start + 6.7),
                       "Reprise du bureau en cours — 6 s. L'écran ne répond pas encore : la console répond "
                        + "d'habitude en 11 à 15 s.")
        XCTAssertTrue(wait.phrase(now: start + 15)?.contains("— 15 s. L'écran") ?? false)
        XCTAssertEqual(wait.phrase(now: start + 16),
                       "Reprise du bureau en cours — 16 s, plus long que d'habitude (11 à 15 s). Le signe de vie, "
                        + "dessous, dit si la machine avance.")
        XCTAssertTrue(wait.phrase(now: start - 3)?.contains("— 0 s.") ?? false, "une horloge qui recule")
    }

    /// **Le premier octet de l'invité y met fin**, pour de bon ; ce que
    /// l'invité avait écrit avant le toucher ne compte pas.
    func testTheFirstGuestByteEndsIt() {
        var wait = ResumeWait(since: start, guestBytes: 120)
        XCTAssertFalse(wait.observe(guestBytes: 120), "rien de neuf")
        XCTAssertNotNil(wait.phrase(now: start + 3))
        XCTAssertTrue(wait.observe(guestBytes: 121), "l'écho de la ligne tapée")
        XCTAssertTrue(wait.answered)
        XCTAssertNil(wait.phrase(now: start + 12))
        XCTAssertFalse(wait.observe(guestBytes: 500), "une seule fois")
        XCTAssertNil(wait.phrase(now: start + 60))
    }

    /// **Les secondes se comptent depuis le toucher**, dans l'application :
    /// `LocalVMModel.boot` lit l'image, sort son noyau et déplie
    /// l'instantané de 345,8 Mio sur le fil principal, l'écran figé, avant
    /// de créer l'attente. Partie de là, elle comptait sans ce temps-là. Le
    /// fichier est derrière `#if os(iOS)` : il se lit ici, commentaires ôtés
    /// (`BootRefusalTests.withoutComments`).
    func testTheAppCountsTheWaitFromTheTouch() throws {
        let source = BootRefusalTests.withoutComments(try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WisqUI/ViewModels/LocalVMModel.swift"), encoding: .utf8))
        let boot = try XCTUnwrap(source.range(of: "public func boot(kernelURL:"), "boot introuvable")
        let body = source[boot.upperBound...]
        func at(_ text: String) throws -> String.Index {
            try XCTUnwrap(body.range(of: text), "« \(text) » introuvable dans boot").lowerBound
        }
        let touched = try at("let touchedAt = Date()")
        for work in ["IsoBoot.decide(", "Data(contentsOf: bootURL)", "SavedSession.find("] {
            XCTAssertLessThan(touched, try at(work), "le toucher est pris avant \(work)")
        }
        XCTAssertEqual(source.components(separatedBy: "ResumeWait(since:").count - 1, 1, "une seule attente")
        XCTAssertGreaterThan(try at("ResumeWait(since: touchedAt,"), try at("SavedSession.find("))
    }

    /// L'attente ordinaire tient la mesure du banc : 12,0 s.
    func testTheUsualWaitHoldsTheBenchMeasure() {
        XCTAssertTrue(ResumeWait.usual.contains(12))
    }
}

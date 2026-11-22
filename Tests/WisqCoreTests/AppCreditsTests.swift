import Foundation
import WisqCore
import XCTest

/// **Les crédits de l'application disent ce que `NOTICE` dit.**
final class AppCreditsTests: XCTestCase {
    private func repository(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testTheAuthorIsMaximeNathanLestage() throws {
        XCTAssertEqual(AppCredits.author, "Maxime Nathan Lestage")
        let notice = try repository("NOTICE")
        XCTAssertTrue(notice.contains("Copyright 2026 \(AppCredits.author)"), "NOTICE nomme un autre auteur")
        XCTAssertTrue(AppCredits.copyright.contains("2026 \(AppCredits.author)"))
        let manifest = try repository("project.yml")
        XCTAssertTrue(manifest.contains("Designed and developed by \(AppCredits.author)"))
    }

    /// Chaque emprunt de `NOTICE` est crédité dans l'application, et rien
    /// d'autre.
    func testEveryNoticeEntryIsCredited() throws {
        let notice = try repository("NOTICE")
        XCTAssertTrue(notice.contains("mini-rv32ima by Charles Lohr"))
        XCTAssertTrue(notice.contains("UTM"))
        XCTAssertEqual(AppCredits.acknowledgements.map(\.name), [
            "mini-rv32ima, de Charles Lohr (MIT)", "UTM (Apache 2.0)",
        ])
        for credit in AppCredits.acknowledgements {
            XCTAssertTrue(credit.detail.contains("Aucun code source"), credit.name)
        }
    }
}

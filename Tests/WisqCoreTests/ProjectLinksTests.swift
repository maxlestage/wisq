import XCTest
import WisqCore

/// The links the app shows are the repository's own, over HTTPS, and the
/// files they point at exist in this checkout — a link to a LICENSE that was
/// renamed is an open-source claim the app can no longer back.
final class ProjectLinksTests: XCTestCase {
    func testEveryLinkIsHTTPSOnTheRepository() {
        for url in [ProjectLinks.repository, ProjectLinks.issues, ProjectLinks.license, ProjectLinks.notice] {
            XCTAssertEqual(url.scheme, "https", url.absoluteString)
            XCTAssertEqual(url.host, "github.com", url.absoluteString)
            XCTAssertTrue(url.path.hasPrefix("/maxlestage/wisq"), url.absoluteString)
        }
    }

    func testTheFilesTheLinksPromiseExist() throws {
        // Walk up from this test file to the package root, which carries the files.
        var root = URL(fileURLWithPath: #filePath)
        while root.pathComponents.count > 1, !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        for name in ["LICENSE", "NOTICE"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                "\(name) absent du dépôt alors que l'app le promet"
            )
        }
    }
}

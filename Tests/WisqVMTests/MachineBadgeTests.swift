import XCTest

@testable import WisqVM

/// Ce que la carte d'une machine montre avant son nom : sa distribution, si
/// c'est un bureau, son état, et les phrases de ses progressions.
final class MachineBadgeTests: XCTestCase {
    /// Les fichiers que la feuille « Télécharger » propose, et ceux qu'on
    /// importe le plus, tombent sur leur distribution.
    func testPublishedImagesLandOnTheirDistribution() {
        let cases: [(String, MachineBadge.Distribution)] = [
            ("alpine-virt-3.22.2-x86_64.iso", .alpine),
            ("void-live-x86_64-20250202-xfce.iso", .void),
            ("debian-13-nocloud-amd64.qcow2", .debian),
            ("Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2", .fedora),
            ("ubuntu-24.04-minimal-cloudimg-amd64.img", .ubuntu),
            ("archlinux-2025.11.01-x86_64.iso", .arch),
            ("openSUSE-Tumbleweed-NET-x86_64-Current.iso", .opensuse),
            ("Image", .linux),
        ]
        for (name, expected) in cases {
            XCTAssertEqual(MachineBadge.distribution(of: [name]), expected, name)
        }
    }

    /// **Par mots entiers** : une sous-chaîne enverrait « archive » chez Arch
    /// et « avoid » chez Void.
    func testWholeWordsOnly() {
        XCTAssertEqual(MachineBadge.distribution(of: ["archive.img"]), .linux)
        XCTAssertEqual(MachineBadge.distribution(of: ["avoid.iso"]), .linux)
        XCTAssertEqual(MachineBadge.distribution(of: ["debianish.img"]), .linux)
    }

    /// Le nom donné par la personne passe avant le fichier : une machine
    /// « Debian » installée sur un ISO quelconque est une Debian.
    func testTheGivenNameComesFirst() {
        XCTAssertEqual(MachineBadge.distribution(of: ["Ma Debian", "netinst.iso"]), .debian)
        XCTAssertEqual(MachineBadge.distribution(of: ["Debian de test", "alpine-virt.iso"]), .debian,
                       "le nom l'emporte sur un fichier qui dit autre chose")
        XCTAssertEqual(MachineBadge.distribution(of: ["Travail", "alpine-virt.iso"]), .alpine,
                       "un nom qui ne dit rien laisse parler le fichier")
    }

    /// Deux distributions ne portent jamais le même symbole ni la même
    /// teinte : c'est tout l'objet du badge.
    func testNoTwoDistributionsLookAlike() {
        let all = MachineBadge.Distribution.allCases
        XCTAssertEqual(Set(all.map(\.symbol)).count, all.count)
        XCTAssertEqual(Set(all.map { "\($0.tint)" }).count, all.count)
        XCTAssertEqual(Set(all.map(\.displayName)).count, all.count)
    }

    /// Un symbole blanc doit se lire sur chaque teinte : aucune n'est claire.
    func testEveryTintIsDarkEnoughForWhite() {
        for distribution in MachineBadge.Distribution.allCases {
            let (red, green, blue) = distribution.tint
            let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
            XCTAssertLessThan(luminance, 0.5, distribution.displayName)
        }
    }

    func testDesktopsAreToldApart() {
        XCTAssertTrue(MachineBadge.isDesktop(["void-live-x86_64-20250202-xfce.iso"]))
        XCTAssertTrue(MachineBadge.isDesktop(["Mon bureau", "alpine.iso"]))
        XCTAssertFalse(MachineBadge.isDesktop(["alpine-virt-3.22.2-x86_64.iso"]))
        XCTAssertFalse(MachineBadge.isDesktop(["xfcelike.img"]), "par mots entiers ici aussi")
    }

    /// Une session sauvée l'emporte : c'est ce qui dit « Reprendre ».
    func testTheStateFollowsTheSession() {
        let then = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(MachineState.of(savedSessions: 1, lastStartedAt: then), .sessionSaved)
        XCTAssertEqual(MachineState.of(savedSessions: 2, lastStartedAt: nil), .sessionSaved)
        XCTAssertEqual(MachineState.of(savedSessions: 0, lastStartedAt: then), .stopped)
        XCTAssertEqual(MachineState.of(savedSessions: 0, lastStartedAt: nil), .neverStarted)
        XCTAssertEqual(MachineState.sessionSaved.action, "Reprendre")
        XCTAssertEqual(MachineState.stopped.action, "Démarrer")
    }

    func testSpecsSkipWhatIsMissing() {
        XCTAssertEqual(MachineCardText.specs(core: "x86-64", memory: 2 << 30, disk: "disque 8 Gio"),
                       "x86-64 · \(KernelMemory.describe(2 << 30)) · disque 8 Gio")
        XCTAssertEqual(MachineCardText.specs(core: nil, memory: 1 << 30, disk: ""),
                       KernelMemory.describe(1 << 30), "pas de séparateur pendu")
        XCTAssertEqual(MachineCardText.specs(core: nil, memory: nil, disk: nil), "")
    }

    /// « 100 % » n'arrive qu'avec le dernier octet, et rien ne dépasse.
    func testPercentIsFlooredAndBounded() {
        XCTAssertEqual(MachineCardText.percent(have: 0, total: 0), 0)
        XCTAssertEqual(MachineCardText.percent(have: 996, total: 1_000), 99)
        XCTAssertEqual(MachineCardText.percent(have: 29, total: 100), 29, "un flottant rendrait 28")
        XCTAssertEqual(MachineCardText.percent(have: 1_000, total: 1_000), 100)
        XCTAssertEqual(MachineCardText.percent(have: 2_000, total: 1_000), 100)
        XCTAssertEqual(MachineCardText.percent(have: -5, total: 1_000), 0)
        XCTAssertEqual(MachineCardText.percent(have: Int.max, total: Int.max), 100, "sans débordement")
        XCTAssertEqual(MachineCardText.progress(have: 512 << 20, total: 1 << 30),
                       "\(LocalStorage.describe(bytes: 512 << 20)) sur \(LocalStorage.describe(bytes: 1 << 30)) · 50 %")
    }
}

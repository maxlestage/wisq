import Foundation
import WisqVMRust
import XCTest

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// **Le traducteur du bureau, appelé comme l'application l'appellera.**
///
/// Le C ABI est déjà éprouvé par un programme C (`crates/wisq-vm/tests/abi/x86.c`) :
/// ce qui est en jeu ici est l'autre moitié, la façon dont Swift franchit ce
/// pont — un `Data` qui devient un pointeur, un tampon que Rust a alloué et
/// qu'il faut lui rendre, un refus qui doit arriver comme `nil` et non comme un
/// plantage.
///
/// Les tests lisent les **octets du module** plutôt que de croire les nombres
/// sur parole. Un module qui importe une mémoire de la mauvaise taille ne
/// s'instancie pas du tout, et le seul endroit où ça se verrait autrement est
/// un iPhone.
final class DesktopTranslatorTests: XCTestCase {
    /// Une région qui boucle sur elle-même : `addq %rax, %rdx ; jnz` en arrière.
    /// N'importe quelle région que l'émetteur accepte ferait l'affaire — ce qui
    /// est éprouvé ici est le passage, pas la traduction, que les tests Rust
    /// comparent au vrai silicium.
    private let loop = Data([0x48, 0x01, 0xc2, 0x75, 0xfb])

    /// `0x06` est `push es`, qui n'existe pas en mode 64 bits.
    private let invalid = Data([0x06])

    private let guestBase: UInt64 = 0x3000_0000

    /// Les octets d'une traduction réussie, ou `nil` — la forme dont la plupart
    /// de ces tests ont besoin, maintenant que l'issue en compte trois.
    private func moduleOf(_ translation: DesktopTranslator.Translation) -> Data? {
        guard case .module(let bytes) = translation else { return nil }
        return bytes
    }

    // MARK: - Traduire

    func testTheEmitterHandsBackSomethingThatIsAWebAssemblyModule() throws {
        let module = try XCTUnwrap(
            DesktopTranslator.region(loop, base: guestBase, entry: 0)
        )
        XCTAssertEqual(Array(module.prefix(8)), [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
    }

    func testARegionTheEmitterCannotDecodeArrivesAsNothing() {
        XCTAssertNil(DesktopTranslator.region(invalid, base: guestBase, entry: 0))
        XCTAssertNil(
            moduleOf(DesktopTranslator.resolvingRegion(
                invalid, base: guestBase, entry: 0, slot: 0, pages: 16
            ))
        )
    }

    /// Un `Data` vide n'a pas d'adresse de base, et Swift en passe `nil`. Le
    /// refus doit venir du C ABI plutôt que d'un déréférencement.
    func testAnEmptyRegionIsRefusedRatherThanCrashed() {
        XCTAssertNil(DesktopTranslator.region(Data(), base: guestBase, entry: 0))
        XCTAssertNil(
            moduleOf(DesktopTranslator.resolvingRegion(
                Data(), base: guestBase, entry: 0, slot: 0, pages: 16
            ))
        )
    }

    /// **L'adresse de chargement n'est pas décorative** : `call` empile une
    /// adresse de retour et `ret` la relit, et la boucle compare RIP aux
    /// adresses de ses propres blocs. La même région chargée ailleurs est un
    /// autre module.
    func testTheLoadAddressReachesTheEmitter() throws {
        let here = try XCTUnwrap(DesktopTranslator.region(loop, base: 0x3000_0000, entry: 0))
        let there = try XCTUnwrap(DesktopTranslator.region(loop, base: 0x5000_0000, entry: 0))
        XCTAssertNotEqual(here, there)
    }

    /// Et le décalage d'entrée non plus : traduire depuis le début d'un tampon
    /// ou depuis son quatrième octet ne traduit pas les mêmes instructions.
    func testTheEntryOffsetReachesTheEmitter() throws {
        let padded = Data([0x90, 0x90, 0x90]) + loop
        let whole = try XCTUnwrap(DesktopTranslator.region(padded, base: guestBase, entry: 0))
        let tail = try XCTUnwrap(DesktopTranslator.region(padded, base: guestBase, entry: 3))
        XCTAssertNotEqual(whole, tail)
        XCTAssertGreaterThan(whole.count, tail.count)
    }

    /// **Chaque module est rendu à Rust.**
    ///
    /// Le tampon est alloué par Rust et se libère par `wisq_x86_free_module` ;
    /// oublier de le rendre ne casse rien, ne change aucun octet, et ne se voit
    /// sur aucune assertion d'égalité — c'est le seul défaut de ce fichier
    /// qu'un test de forme ne peut pas attraper. Un bureau traduit des milliers
    /// de régions par démarrage, donc la fuite est le défaut qui compte.
    ///
    /// Mesuré sur le sommet de mémoire résidente plutôt que sur un compteur
    /// d'allocations : c'est ce que les deux plateformes savent rendre par le
    /// même appel. Trois cent mille modules de 614 octets font 184 Mio si rien
    /// n'est rendu, et à peu près rien s'ils le sont — le seuil est loin des
    /// deux.
    func testEveryModuleIsHandedBackToRust() throws {
        for _ in 0..<20_000 { _ = DesktopTranslator.region(loop, base: guestBase, entry: 0) }
        let before = try highWaterBytes()
        for _ in 0..<300_000 { _ = DesktopTranslator.region(loop, base: guestBase, entry: 0) }
        let after = try highWaterBytes()
        XCTAssertLessThan(
            after - before, 40 * 1024 * 1024,
            "la mémoire a grimpé de \((after - before) / (1024 * 1024)) Mio en trois cent mille traductions"
        )
    }

    /// Le sommet de mémoire résidente, en octets. Linux le compte en kibioctets
    /// et Darwin en octets ; c'est la seule différence entre les deux.
    private func highWaterBytes() throws -> Int {
        var usage = rusage()
        // Darwin donne un Int32, la glibc une énumération. Le nombre est le
        // même des deux côtés ; seul son type diffère.
        #if canImport(Darwin)
        let who = RUSAGE_SELF
        #else
        let who = __rusage_who_t(RUSAGE_SELF.rawValue)
        #endif
        guard getrusage(who, &usage) == 0 else {
            throw XCTSkip("getrusage indisponible : la fuite ne peut pas être mesurée")
        }
        #if canImport(Darwin)
        return Int(usage.ru_maxrss)
        #else
        return Int(usage.ru_maxrss) * 1024
        #endif
    }

    // MARK: - Ce que la forme qui résout demande à l'hôte

    /// **Le nombre que l'hôte doit connaître, lu dans les octets.**
    ///
    /// La correspondance adresse → indice vit *au-dessus* de la RAM de
    /// l'invité, et le module déclare le total. Un hôte qui crée une mémoire de
    /// `pages` seulement n'instancie rien. Comparer le minimum déclaré à
    /// `pages + tablePages` tient les deux moitiés ensemble.
    func testTheConfinedModuleAsksForTheCorrespondenceOnTopOfTheGuestsRAM() throws {
        for pages: UInt32 in [1, 16, 1024] {
            let module = try XCTUnwrap(
                moduleOf(DesktopTranslator.resolvingRegion(
                    loop, base: guestBase, entry: 0, slot: 0, pages: pages
                )),
                "\(pages) pages"
            )
            let memory = try XCTUnwrap(Imports(of: module).memory, "\(pages) pages")
            XCTAssertEqual(memory, pages + DesktopTranslator.tablePages, "\(pages) pages")
        }
    }

    /// L'autre moitié du même argument : le module importe autant de globales
    /// que le pont en annonce, et une de moins suffit à ce qu'il ne démarre pas.
    func testTheModuleImportsExactlyTheGlobalsTheBridgeAnnounces() throws {
        let module = try XCTUnwrap(
            moduleOf(DesktopTranslator.resolvingRegion(
                loop, base: guestBase, entry: 0, slot: 0, pages: 16
            ))
        )
        XCTAssertEqual(Imports(of: module).globals, DesktopTranslator.globalCount)
    }

    /// **L'emplacement demandé n'est pas décoratif**, et « les deux modules
    /// diffèrent » ne le prouve pas : ils diffèrent par bien d'autres octets.
    /// Ce que la table déclare le prouve — sept emplacements plus loin, il en
    /// faut sept de plus pour que la région tienne.
    func testTheSlotMovesWhereTheRegionsBlocksLandInTheHostsTable() throws {
        let first = try XCTUnwrap(
            moduleOf(DesktopTranslator.resolvingRegion(
                loop, base: guestBase, entry: 0, slot: 0, pages: 16
            ))
        )
        let second = try XCTUnwrap(
            moduleOf(DesktopTranslator.resolvingRegion(
                loop, base: guestBase, entry: 0, slot: 7, pages: 16
            ))
        )
        let near = try XCTUnwrap(Imports(of: first).table)
        let far = try XCTUnwrap(Imports(of: second).table)
        XCTAssertEqual(far, near + 7)
        XCTAssertNotEqual(first, second)
    }

    /// Et la RAM demandée non plus : elle décide du masque, donc de ce que le
    /// module peut atteindre.
    func testTwoRAMSizesGiveTwoModules() throws {
        let small = try XCTUnwrap(
            moduleOf(DesktopTranslator.resolvingRegion(
                loop, base: guestBase, entry: 0, slot: 0, pages: 1
            ))
        )
        let large = try XCTUnwrap(
            moduleOf(DesktopTranslator.resolvingRegion(
                loop, base: guestBase, entry: 0, slot: 0, pages: 1024
            ))
        )
        XCTAssertNotEqual(small, large)
    }

    /// Le repli est un masque, et un masque ne décrit un intervalle que sur une
    /// puissance de deux.
    func testARAMThatIsNotAPowerOfTwoIsRefused() {
        for pages: UInt32 in [0, 3, 12289] {
            XCTAssertNil(
                moduleOf(DesktopTranslator.resolvingRegion(
                    loop, base: guestBase, entry: 0, slot: 0, pages: pages
                )),
                "\(pages) pages"
            )
        }
    }

    /// **Trois issues, et non deux.**
    ///
    /// C'est ce qui permet à la vue de redemander exactement quand ça sert.
    /// Sans le troisième cas, elle abandonnerait 91 régions sur 10 116 — qui
    /// se traduisent toutes au second essai — ou paierait un aller-retour de
    /// plus sur chacun des 95 vrais refus.
    func testATranslationHasThreeOutcomesAndNotTwo() {
        XCTAssertEqual(
            DesktopTranslator.resolvingRegion(
                Data([0x48, 0xb8, 1, 2, 3]), base: guestBase, entry: 0, slot: 0, pages: 16
            ),
            .needsMoreBytes,
            "une instruction coupée demande des octets"
        )
        // Le même octet inconnu, mais avec quinze octets de marge derrière :
        // l'émetteur avait toute la place qu'une instruction peut demander.
        var withRoom = Data([0x06])
        withRoom.append(contentsOf: [UInt8](repeating: 0x90, count: 14))
        XCTAssertEqual(
            DesktopTranslator.resolvingRegion(
                withRoom, base: guestBase, entry: 0, slot: 0, pages: 16
            ),
            .refused,
            "avec la place d'en juger, c'est un refus franc"
        )
        XCTAssertEqual(
            DesktopTranslator.resolvingRegion(
                withRoom.prefix(14), base: guestBase, entry: 0, slot: 0, pages: 16
            ),
            .needsMoreBytes,
            "un octet de moins, et il n'avait plus la place"
        )
        guard case .module = DesktopTranslator.resolvingRegion(
            loop, base: guestBase, entry: 0, slot: 0, pages: 16
        ) else {
            return XCTFail("une région entière doit se traduire")
        }
        XCTAssertEqual(
            DesktopTranslator.resolvingRegion(
                loop, base: guestBase, entry: 0, slot: 0, pages: 3
            ),
            .refused,
            "une RAM qui n'est pas une puissance de deux est un refus franc"
        )
    }

    // MARK: - La page

    func testThePageCarriesTheChannelTheApplicationDeclares() throws {
        let page = try XCTUnwrap(
            DesktopTranslator.page(pages: 16, entry: guestBase, channel: "wisqBureau")
        )
        XCTAssertTrue(page.contains("wisqBureau"))
        XCTAssertTrue(page.count > 1000, "la page fait \(page.count) caractères")
    }

    /// Le nom du canal est **collé dans du JavaScript**. Le même soin que pour
    /// un identifiant de VM collé dans une ligne de commande.
    func testAChannelThatCannotBePastedSafelyIsRefused() {
        for channel in ["wisq; alert(1)", "", "wisq-bureau", "wisq\"bureau"] {
            XCTAssertNil(
                DesktopTranslator.page(pages: 16, entry: guestBase, channel: channel),
                "canal « \(channel) »"
            )
        }
    }

    func testAPageWhoseRAMCannotBeConfinedIsRefused() {
        XCTAssertNil(DesktopTranslator.page(pages: 3, entry: guestBase, channel: "wisq"))
    }

    func testTheCorrespondenceCostsPagesAboveTheGuestsRAM() {
        XCTAssertGreaterThan(DesktopTranslator.tablePages, 0)
    }

    // MARK: - Le cadre

    /// **Le cadre traverse le pont, et la page le porte.** Sans cadre, pas de
    /// canvas : une page qui en porterait un sans rien pour le peindre
    /// montrerait un rectangle vide.
    func testAPageWithAFrameCarriesItsCanvas() throws {
        let framed = try XCTUnwrap(
            DesktopTranslator.page(
                pages: 16,
                entry: guestBase,
                channel: "wisq",
                screen: .init(base: guestBase, width: 320, height: 240)
            )
        )
        XCTAssertTrue(
            framed.contains("<canvas id=\"wisqEcran\" width=\"320\" height=\"240\">"),
            "le canvas doit porter les dimensions du cadre"
        )
        XCTAssertTrue(framed.contains("window.wisqPaint"), "et de quoi le peindre")

        let bare = try XCTUnwrap(
            DesktopTranslator.page(pages: 16, entry: guestBase, channel: "wisq")
        )
        XCTAssertFalse(bare.contains("<canvas"), "sans cadre, pas de canvas")
    }

    /// **Un cadre qui déborderait de la RAM invitée est refusé.** Au-dessus vit
    /// la correspondance adresse → indice : un tel cadre afficherait la table
    /// des blocs à l'écran tout en la détruisant. La borne est vérifiée à
    /// l'octet près, des deux côtés — sans le cas qui passe, un refus qui
    /// refuserait tout aurait l'air d'une garde.
    func testAFrameThatWouldOverflowTheGuestsRAMIsRefused() {
        // Une page de RAM : 65 536 octets, soit exactement 128×128 pixels.
        XCTAssertNotNil(
            DesktopTranslator.page(
                pages: 1, entry: guestBase, channel: "wisq",
                screen: .init(base: 0, width: 128, height: 128)
            ),
            "un cadre qui remplit la RAM au dernier octet tient"
        )
        XCTAssertNil(
            DesktopTranslator.page(
                pages: 1, entry: guestBase, channel: "wisq",
                screen: .init(base: 4, width: 128, height: 128)
            ),
            "quatre octets plus loin, il déborde"
        )
        XCTAssertNil(
            DesktopTranslator.page(
                pages: 1, entry: guestBase, channel: "wisq",
                screen: .init(base: 0, width: 0, height: 128)
            ),
            "un cadre sans largeur n'est pas un cadre"
        )
    }
}

/// **La section des imports d'un module, lue octet par octet.**
///
/// Assez de WebAssembly pour répondre à trois questions : quelle mémoire le
/// module demande, quelle table, et combien de globales. Écrit ici plutôt
/// qu'emprunté à une bibliothèque parce qu'un test qui croit un décodeur tiers
/// ne tient plus rien le jour où le décodeur se trompe.
private struct Imports {
    var memory: UInt32?
    var table: UInt32?
    var globals = 0

    init(of module: Data) {
        let bytes = [UInt8](module)
        var at = 8  // l'en-tête : « \0asm » et la version
        while at < bytes.count {
            guard let id = next(bytes, &at) else { return }
            guard let size = leb(bytes, &at) else { return }
            let end = at + Int(size)
            guard end <= bytes.count else { return }
            if id == 2 { read(bytes, from: at, to: end) }
            at = end
        }
    }

    private mutating func read(_ bytes: [UInt8], from start: Int, to end: Int) {
        var at = start
        guard let count = leb(bytes, &at) else { return }
        for _ in 0..<count {
            guard skipName(bytes, &at), skipName(bytes, &at),
                  let kind = next(bytes, &at)
            else { return }
            switch kind {
            case 0x00:  // une fonction
                guard leb(bytes, &at) != nil else { return }
            case 0x01:  // une table
                guard next(bytes, &at) != nil, let flags = next(bytes, &at),
                      let least = leb(bytes, &at)
                else { return }
                table = UInt32(truncatingIfNeeded: least)
                if flags & 0x01 != 0, leb(bytes, &at) == nil { return }
            case 0x02:  // une mémoire
                guard let flags = next(bytes, &at), let least = leb(bytes, &at) else { return }
                memory = UInt32(truncatingIfNeeded: least)
                if flags & 0x01 != 0, leb(bytes, &at) == nil { return }
            case 0x03:  // une globale
                guard next(bytes, &at) != nil, next(bytes, &at) != nil else { return }
                globals += 1
            default:
                return
            }
            guard at <= end else { return }
        }
    }

    private func skipName(_ bytes: [UInt8], _ at: inout Int) -> Bool {
        guard let length = leb(bytes, &at) else { return false }
        at += Int(length)
        return at <= bytes.count
    }

    private func next(_ bytes: [UInt8], _ at: inout Int) -> UInt8? {
        guard at < bytes.count else { return nil }
        defer { at += 1 }
        return bytes[at]
    }

    private func leb(_ bytes: [UInt8], _ at: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while at < bytes.count {
            let byte = bytes[at]
            at += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }
}

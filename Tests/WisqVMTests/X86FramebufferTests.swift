import Foundation
import XCTest

@testable import WisqVM

/// **Le cadre déclaré au noyau doit exister quelque part.**
///
/// La tranche précédente a écrit l'écran dans `screen_info` : adresse,
/// géométrie, place de chaque couleur. Un noyau qui lit ça peint aussitôt —
/// et jusqu'ici il peignait sur une adresse qu'aucune mémoire ne couvre, donc
/// sur une faute. Ce fichier tient la mémoire qui manque.
///
/// Elle vit **derrière** la RAM, comme le disque : une fenêtre que le chemin
/// chaud ne rencontre jamais, et qui ne coûte donc rien à une écriture
/// ordinaire.
final class X86FramebufferTests: XCTestCase {
    private static let base: UInt64 = 0xE000_0000

    private func machine() -> (X86Memory, X86Framebuffer) {
        let memory = X86Memory(size: 1 << 20, base: 0)
        let screen = X86Framebuffer(base: Self.base, width: 8, height: 4)
        memory.screen = screen
        return (memory, screen)
    }

    /// **Ce que l'invité écrit dans la fenêtre, l'hôte doit le relire.** C'est
    /// tout le contrat : sans ça, il n'y a pas d'image à montrer.
    func testWhatTheGuestWritesTheHostReads() throws {
        let (memory, screen) = machine()
        // Un pixel bleu en haut à gauche, en XRGB8888.
        try memory.write(Self.base, 4, 0x00_00_00_FF)
        // Et un rouge au dernier pixel, pour tenir aussi le bord.
        let last = Self.base &+ UInt64(screen.byteCount - 4)
        try memory.write(last, 4, 0x00_FF_00_00)

        let frame = screen.snapshot()
        XCTAssertEqual(frame.count, 8 * 4 * 4, "un octet par composante, quatre par pixel")
        XCTAssertEqual(Array(frame[0..<4]), [0xFF, 0x00, 0x00, 0x00], "le bleu occupe l'octet bas")
        XCTAssertEqual(Array(frame[(frame.count - 4)...]), [0x00, 0x00, 0xFF, 0x00])
    }

    /// **Relire par la mémoire doit rendre ce qu'on y a mis.** Un noyau ne fait
    /// pas qu'écrire : il lit son propre cadre pour faire défiler une console.
    func testTheGuestCanReadBackItsOwnPixels() throws {
        let (memory, _) = machine()
        try memory.write(Self.base &+ 16, 4, 0x00_12_34_56)
        XCTAssertEqual(try memory.read(Self.base &+ 16, 4), 0x00_12_34_56)
    }

    /// **La fenêtre s'arrête exactement à la fin du cadre.** Un octet de plus
    /// et une écriture perdue deviendrait silencieuse, au lieu de lever la
    /// faute qui la ferait remarquer.
    func testJustPastTheEndIsStillAFault() {
        let (memory, screen) = machine()
        let past = Self.base &+ UInt64(screen.byteCount)
        XCTAssertThrowsError(try memory.write(past, 4, 0xFF)) { error in
            guard case X86Core.Fault.outsideMemory = error else {
                return XCTFail("une adresse hors du cadre doit lever « hors mémoire » : \(error)")
            }
        }
    }

    /// **Le compteur de révision dit si l'image a bougé.** Sans lui, la vue
    /// repeindrait soixante fois par seconde une image identique — et sur un
    /// téléphone, ça se paie en batterie.
    func testTheRevisionAdvancesOnlyOnAWrite() throws {
        let (memory, screen) = machine()
        let start = screen.revision
        _ = try memory.read(Self.base, 4)
        XCTAssertEqual(screen.revision, start, "lire ne change rien")
        try memory.write(Self.base, 4, 1)
        XCTAssertGreaterThan(screen.revision, start, "écrire doit se voir")
    }

    /// **La RAM et le cadre ne se touchent pas.** Une écriture ordinaire ne
    /// doit jamais atterrir dans l'image, sinon un bureau se corromprait sous
    /// des causes sans aucun rapport.
    func testWritingToRAMLeavesTheFrameAlone() throws {
        let (memory, screen) = machine()
        try memory.write(0x1000, 4, 0xDEAD_BEEF)
        XCTAssertEqual(screen.snapshot(), Array(repeating: 0, count: screen.byteCount))
    }

    // MARK: - Branché à la machine

    /// **Une machine avec écran doit le déclarer au noyau et le router.**
    ///
    /// Les deux moitiés existaient séparément : `screen_info` disait où
    /// peindre, `X86Framebuffer` tenait l'endroit. Rien ne les reliait, donc un
    /// vrai noyau aurait encore peint sur une faute.
    func testAMachineWithADisplayDeclaresItAndRoutesIt() throws {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize) { _ in }
        try machine.attachDisplay(width: 640, height: 480)
        let screen = try XCTUnwrap(machine.display, "la machine doit rendre son cadre")
        XCTAssertEqual(screen.width, 640)
        XCTAssertEqual(screen.height, 480)

        // Le noyau synthétique suffit : ce qu'on vérifie, c'est que le
        // chargeur a reçu l'écran, pas qu'un vrai Linux démarre.
        try machine.load(kernelImage: Data(X86BootLoaderTests.syntheticKernel()))
        let page = machine.bootParameters()
        XCTAssertEqual(page[0x0F], X86BootLoader.videoTypeLinearFramebuffer,
                       "la page zéro doit annoncer le cadre")
        let base = (0..<4).reduce(UInt32(0)) { $0 | (UInt32(page[0x18 + $1]) << (8 * UInt32($1))) }
        XCTAssertEqual(UInt64(base), screen.base, "et à l'adresse que la machine a choisie")

        // **Et l'annonce doit être vraie.** Déclarer une adresse sans y router
        // la mémoire donnerait un noyau qui peint sur une faute — ce que la
        // page zéro seule ne dit pas. Mesuré : sans cette assertion, retirer
        // le routage ne faisait tomber aucun test.
        try machine.memory.write(screen.base, 4, 0x00_AB_CD_EF)
        XCTAssertEqual(Array(screen.snapshot()[0..<4]), [0xEF, 0xCD, 0xAB, 0x00],
                       "une écriture invitée à l'adresse annoncée doit atteindre le cadre")
    }

    /// **Sans écran demandé, rien ne change.** Une machine en console série ne
    /// doit pas voir un cadre imaginaire.
    func testAMachineWithoutADisplayHasNone() throws {
        let machine = X86Machine(ramSize: X86Machine.minimumRAMSize) { _ in }
        XCTAssertNil(machine.display)
        try machine.load(kernelImage: Data(X86BootLoaderTests.syntheticKernel()))
        XCTAssertEqual(machine.bootParameters()[0x0F], 0)
    }

    /// **Un cadre qui recouvrirait la RAM est refusé, pas décalé en silence.**
    ///
    /// La fenêtre est à 0xE0000000. Une machine dotée de plus de mémoire que ça
    /// verrait ses deux régions se superposer, et l'écriture d'un pixel
    /// écraserait une page du noyau. Refuser est la seule réponse honnête :
    /// déplacer le cadre demanderait `ext_lfb_base`, que cette tranche
    /// n'implémente pas.
    func testADisplayThatWouldOverlapRAMIsRefused() {
        let machine = X86Machine(ramSize: 4 << 30) { _ in }
        XCTAssertThrowsError(try machine.attachDisplay(width: 640, height: 480)) { error in
            guard case X86Machine.DisplayRefusal.wouldOverlapMemory = error else {
                return XCTFail("le refus doit dire pourquoi : \(error)")
            }
        }
        XCTAssertNil(machine.display, "et rien ne doit rester accroché")
    }

}

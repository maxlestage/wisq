// La garde couvre le fichier entier, comme pour le test RDP en direct et pour
// la même raison : ce qui est écrit sous un `#endif` compile sur Linux et pas
// sur Apple, faute des imports restés dedans.
#if canImport(Glibc)
import Foundation
import WisqCore
import XCTest

@testable import WisqNet
@testable import WisqRemote

/// **Le bureau, en entier, contre un vrai serveur SPICE.**
///
/// **Ce que ce test décide.** wisq a un client SPICE complet — la poignée de
/// main, le canal d'affichage, les codecs, le curseur, le son, l'agent. Chacun
/// est tenu par des vecteurs, et des vecteurs disent qu'on écrit les mêmes
/// octets qu'un client de référence. Ils ne disent pas qu'un serveur les
/// accepte, ni qu'un bureau apparaît au bout. La seule preuve d'une session
/// SPICE est une session SPICE.
///
/// **Et c'est la question que Maxime a posée.** Le bureau réel, avec son image :
/// une machine construite autour d'une ISO par `wisq-agent bureau`, et wisq qui
/// en reçoit les pixels. Ce fichier est la moitié cliente de cette phrase.
///
/// Il se saute quand rien n'écoute, comme le test RDP et comme la mesure de
/// démarrage x86 sans noyau : la CI n'a pas d'hyperviseur, et un test qui
/// échoue là où il n'y a rien à mesurer n'apprend rien à personne.
///
/// Pour le lancer, sur une machine qui a QEMU :
///
///     wisq-agent bureau --image /chemin/vers/omarchy.iso --nom essai
///     WISQ_SPICE_HOST=127.0.0.1 WISQ_SPICE_PORT=5930 \
///       WISQ_SPICE_PASSWORD=… swift test --filter SPICELiveDesktopTests
final class SPICELiveDesktopTests: XCTestCase {
    private func configuration() throws -> SessionConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["WISQ_SPICE_HOST"] else {
            throw XCTSkip("aucun serveur SPICE : définir WISQ_SPICE_HOST pour ce test")
        }
        return SessionConfiguration(
            host: host,
            port: environment["WISQ_SPICE_PORT"].flatMap(Int.init) ?? 5900,
            password: environment["WISQ_SPICE_PASSWORD"])
    }

    /// **Le transport, à la main.** Le fournisseur par défaut de `SPICESession`
    /// n'existe que là où `Network` existe, c'est-à-dire sur Apple ; hors de là
    /// il rend « transport réseau indisponible ». C'est le bon défaut pour une
    /// application iOS et c'est ce qui empêchait de mesurer la pile SPICE
    /// ailleurs. Le test RDP en direct avait déjà tranché la question de la même
    /// façon : `PosixByteStream`, qui existe partout.
    ///
    /// Rien du protocole ne change : c'est une socket, et SPICE en demande une
    /// par canal.
    private static let posixStreams: SPICESession.StreamProvider = { configuration in
        let stream = try PosixByteStream(host: configuration.host, port: configuration.port)
        return stream
    }

    /// **Le ticket, chiffré ici plutôt que par Security.framework.**
    ///
    /// `SpiceTicket.platform` passe par RSA-OAEP-SHA1 d'Apple et rend
    /// `ticketUnavailable` ailleurs. Le fichier qui le déclare dit pourquoi la
    /// couture existe : « a Linux runner that can go red ». La voici employée.
    ///
    /// **La même arithmétique, le même bourrage** : ce chiffreur-ci fait ce que
    /// fait celui d'Apple, à la lettre. Un chiffreur de test qui ferait autre
    /// chose mesurerait autre chose.
    static func encrypt(_ password: String, _ publicKey: [UInt8]) throws -> Data {
        let folder = FileManager.default.temporaryDirectory
        let keyURL = folder.appendingPathComponent("wisq-spice-\(UUID().uuidString).der")
        let clearURL = folder.appendingPathComponent("wisq-spice-\(UUID().uuidString).bin")
        let outURL = folder.appendingPathComponent("wisq-spice-\(UUID().uuidString).enc")
        defer { for url in [keyURL, clearURL, outURL] { try? FileManager.default.removeItem(at: url) } }
        try Data(publicKey).write(to: keyURL)
        try Data(SpiceTicket.clearText(password)).write(to: clearURL)

        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = [
            "pkeyutl", "-encrypt", "-pubin", "-keyform", "DER", "-inkey", keyURL.path,
            "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha1",
            "-in", clearURL.path, "-out", outURL.path,
        ]
        let errors = Pipe()
        openssl.standardError = errors
        try openssl.run()
        openssl.waitUntilExit()
        guard openssl.terminationStatus == 0 else {
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "openssl", code: Int(openssl.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        return try Data(contentsOf: outURL)
    }

    private func session() throws -> SPICESession {
        SPICESession(
            configuration: try configuration(),
            streamProvider: Self.posixStreams,
            encryptTicket: { try Self.encrypt($0, $1) })
    }

    /// Attendre un évènement qui satisfait `matches`, sans dépasser `seconds`.
    ///
    /// Un `for await` nu attendrait pour toujours si le serveur se tait, et un
    /// test qui pend est pire qu'un test qui échoue : personne ne sait ce qu'il
    /// mesurait.
    private func wait(
        for session: SPICESession, seconds: Double,
        until matches: @escaping @Sendable (SessionEvent) -> Bool
    ) async -> SessionEvent? {
        let events = session.events
        return await withTaskGroup(of: SessionEvent?.self) { group in
            group.addTask {
                for await event in events where matches(event) { return event }
                return nil
            }
            group.addTask {
                // `try?` avale l'annulation : sans le `catch`, la tâche
                // continuerait à tourner jusqu'à l'échéance après que l'autre a
                // gagné, et `withTaskGroup` attendrait avec elle. Chaque attente
                // durait alors exactement son délai, réussite comprise — mesuré :
                // trente secondes pour une poignée de main d'une seconde.
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch {
                    return nil
                }
                return nil
            }
            let outcome = await group.next()
            group.cancelAll()
            return outcome.flatMap { $0 }
        }
    }

    /// **La poignée de main aboutit, et le bureau a une taille.**
    ///
    /// C'est le premier fait qui manquait : jusqu'ici rien dans ce dépôt
    /// n'avait montré le client de wisq parler à un serveur SPICE qui n'était
    /// pas le sien.
    func testTheHandshakeCompletesAgainstARealSpiceServer() async throws {
        let session = try session()
        await session.start()
        defer { Task { await session.stop() } }

        let event = await wait(for: session, seconds: 30) {
            if case .ready = $0 { return true }
            if case .disconnected = $0 { return true }
            return false
        }
        guard case .ready(let name, let width, let height)? = event else {
            return XCTFail("pas de bureau : \(String(describing: event))")
        }
        XCTAssertGreaterThan(width, 0, "un bureau sans largeur n'est pas un bureau")
        XCTAssertGreaterThan(height, 0)
        // Le nom vient du serveur ; QEMU envoie le sien, et l'important est
        // qu'il ne soit pas vide — un nom vide veut dire qu'on a lu à côté.
        XCTAssertFalse(name.isEmpty, "le serveur se nomme")
    }

    /// **Et des pixels arrivent.** Une poignée de main réussie avec un écran
    /// resté noir serait une session qui se connecte et ne montre rien — le
    /// symptôme exact qu'un test de vecteurs ne peut pas voir.
    func testPixelsFromTheGuestReachTheFramebuffer() async throws {
        let session = try session()
        await session.start()
        defer { Task { await session.stop() } }

        guard case .ready? = await wait(for: session, seconds: 30, until: {
            if case .ready = $0 { return true }
            return false
        }) else {
            return XCTFail("le bureau n'est jamais arrivé")
        }
        guard await wait(for: session, seconds: 60, until: {
            if case .framebufferChanged = $0 { return true }
            return false
        }) != nil else {
            return XCTFail("aucune région peinte en soixante secondes")
        }
        let (width, height, pixels) = session.framebuffer.snapshot()
        XCTAssertEqual(pixels.count, width * height * 4)
        // Deux octets différents suffisent : un écran d'une seule couleur est
        // ce que rend un tampon jamais peint, et c'est précisément ce cas-là
        // qu'il faut distinguer.
        XCTAssertGreaterThan(Set(pixels).count, 1, "l'écran est resté d'une seule couleur")
    }
}
#endif

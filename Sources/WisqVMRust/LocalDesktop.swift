#if canImport(WebKit)
import Foundation
import WebKit

/// **La machine qui vit dans la vue, pilotée depuis l'application.**
///
/// C'est le dernier morceau du bureau local, et le seul qui ait besoin de
/// WebKit. Tout ce qu'il fait est de tenir ensemble trois choses écrites
/// ailleurs : la page que `DesktopTranslator.page` assemble, les demandes que
/// `DesktopBridge` lit, et les modules que `DesktopTranslator` produit.
///
/// **Pourquoi ce fichier n'est pas dans `WisqUI`.** Une vue SwiftUI y serait à
/// sa place, mais ceci n'est pas une vue : c'est la conduite. `WisqUI` n'est
/// que *compilé* par la CI ; cette cible-ci est **exécutée**, sur macOS comme
/// sur Linux. Mettre la conduite ici la fait juger à chaque commit, et laisse à
/// l'écran la seule chose qui ait vraiment besoin d'un écran.
///
/// **Ce que l'application fournit, et rien d'autre** : l'image du noyau, et la
/// traduction. La RAM de l'invité *est* la mémoire linéaire du module, dans le
/// processus de contenu de WebKit ; l'application ne la partage pas, elle lui
/// parle.
@MainActor
public final class LocalDesktop {
    /// Ce qui peut empêcher le bureau de démarrer. Trois causes distinctes,
    /// parce qu'elles ne se corrigent pas au même endroit : une RAM que
    /// l'émetteur refuse, une vue qui ne charge pas, un JavaScript qui lève.
    public enum Failure: Error, Equatable {
        case ramIsNotAPowerOfTwo(UInt32)
        case viewNeverFinishedLoading
        case script(String)
    }

    /// Pourquoi la machine s'est arrêtée, et où. Jamais « rien » : un arrêt
    /// sans raison est ce qui rend une panne d'émulateur indiagnosticable.
    public struct Stopped: Equatable, Sendable {
        public let why: String
        public let at: UInt64
    }

    /// Ce que le bureau a fait, pour qu'un test puisse le lire. Ce ne sont pas
    /// des statistiques d'agrément : « la machine a tourné » et « la machine a
    /// tourné en traduisant trois régions dont une redemandée » ne se
    /// vérifient pas pareil.
    public private(set) var translations = 0
    public private(set) var refusals = 0
    public private(set) var secondTries = 0
    public private(set) var unreadable = 0

    private let pages: UInt32
    private let entry: UInt64
    private let channel = "wisq"
    private let web: WKWebView
    private let handler: Channel

    public init(pages: UInt32, entry: UInt64) throws {
        guard pages > 0, pages & (pages - 1) == 0 else {
            throw Failure.ramIsNotAPowerOfTwo(pages)
        }
        self.pages = pages
        self.entry = entry
        let settings = WKWebViewConfiguration()
        handler = Channel()
        settings.userContentController.add(handler, name: channel)
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240),
                        configuration: settings)
        handler.desktop = self
    }

    // MARK: - Démarrer

    /// Charge la page dans la vue et attend qu'elle soit prête.
    public func load(patience: TimeInterval = 20) async throws {
        guard let page = DesktopTranslator.page(
            pages: pages, entry: entry, channel: channel
        ) else {
            throw Failure.ramIsNotAPowerOfTwo(pages)
        }
        web.loadHTMLString(page, baseURL: nil)
        let deadline = Date().addingTimeInterval(patience)
        while web.isLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        guard !web.isLoading else { throw Failure.viewNeverFinishedLoading }
    }

    /// **Pose l'image dans la RAM de l'invité**, à l'adresse repliée.
    ///
    /// C'est le seul moment où l'application écrit dans la mémoire de la vue.
    /// Les octets partent en base64, par tranches : une seule évaluation
    /// porterait un littéral de la taille de l'image, et un noyau fait des
    /// dizaines de mégaoctets.
    ///
    /// **Ce chemin coûte cher et c'est assumé pour l'instant** : quelques
    /// dizaines de mégaoctets à travers `evaluateJavaScript`, une fois par
    /// démarrage. Le remplacer par un gestionnaire de schéma que la page va
    /// chercher elle-même est une tranche à part, et elle ne se mesure que sur
    /// un appareil.
    public func place(_ image: Data, at address: UInt64) async throws {
        let chunk = 48 * 1024
        var written = 0
        while written < image.count {
            let piece = image[
                image.startIndex + written ..< image.startIndex + min(written + chunk, image.count)
            ]
            let script = """
                (() => {
                  const brut = atob(octets);
                  const at = Number((\(address)n + BigInt(\(written))) & \(pages * 65536 - 1)n);
                  const vue = new Uint8Array(window.wisqMachine.memory.buffer, at, brut.length);
                  for (let i = 0; i < brut.length; i++) vue[i] = brut.charCodeAt(i);
                  return brut.length;
                })()
                """
            do {
                _ = try await web.callAsyncJavaScript(
                    script,
                    arguments: ["octets": piece.base64EncodedString()],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                throw Failure.script(error.localizedDescription)
            }
            written += piece.count
        }
    }

    /// Fait tourner la machine jusqu'à ce qu'elle s'arrête, et dit pourquoi.
    public func run() async throws -> Stopped {
        do {
            _ = try await web.callAsyncJavaScript(
                "return await window.wisqRun()", arguments: [:], in: nil, contentWorld: .page
            )
        } catch {
            throw Failure.script(error.localizedDescription)
        }
        guard let stopped = handler.stopped else {
            throw Failure.script("la machine s'est arrêtée sans le dire")
        }
        return stopped
    }

    /// La valeur d'une globale de l'invité — RIP, les registres — telle que la
    /// vue la tient. `DesktopTranslator.ripSlot` dit laquelle porte RIP.
    ///
    /// Publique parce que l'application en a besoin pour savoir où en est la
    /// machine, et parce qu'un test qui ne peut pas lire l'état invité ne peut
    /// vérifier que « ça n'a pas planté ».
    public func global(_ slot: Int) async throws -> UInt64 {
        do {
            let value = try await web.callAsyncJavaScript(
                "return window.wisqMachine.globals[slot].value.toString()",
                arguments: ["slot": slot], in: nil, contentWorld: .page
            )
            guard let text = value as? String, let number = UInt64(text) else {
                throw Failure.script("la globale \(slot) n'est pas revenue lisible")
            }
            return number
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.script(error.localizedDescription)
        }
    }

    // MARK: - Répondre

    /// **Le cœur du pont** : une demande arrive, un module repart.
    ///
    /// Trois réponses et non deux, parce que l'émetteur en distingue trois. Un
    /// refus franc arrête la machine ; un manque d'octets lui fait redemander
    /// avec une fenêtre plus large, **une seule fois** — la vue s'en charge, ce
    /// côté-ci se contente de dire lequel des deux c'est.
    fileprivate func answer(_ body: [String: Any]) {
        let request: DesktopBridge.Request
        do {
            request = try DesktopBridge.request(from: body)
        } catch {
            // **Une demande illisible est un défaut, pas une entrée à refuser.**
            // La page est engendrée par wisq : si elle parle une autre langue
            // que ce pont, les deux moitiés ont divergé. Le compter le rend
            // visible à un test au lieu de le perdre.
            unreadable += 1
            return
        }
        switch request {
        case .stopped(let why, let at):
            handler.stopped = Stopped(why: why, at: at)
        case .translate(let id, let address, let slot, let code):
            let reply: String
            switch DesktopTranslator.resolvingRegion(
                code, base: address, entry: 0, slot: slot, pages: pages
            ) {
            case .module(let module):
                translations += 1
                reply = DesktopBridge.translated(id: id, module: module)
            case .needsMoreBytes:
                secondTries += 1
                reply = DesktopBridge.needsMore(id: id)
            case .refused:
                refusals += 1
                reply = DesktopBridge.translated(id: id, module: nil)
            }
            // La réponse ne peut pas être rendue depuis ici : une vue ne
            // répond pas à un message, elle est rappelée. D'où l'évaluation.
            Task { @MainActor [web] in
                _ = try? await web.evaluateJavaScript(reply)
            }
        }
    }

    /// **Le gestionnaire de messages, séparé exprès, et c'est ce qui évite la
    /// fuite.**
    ///
    /// `add(_:name:)` retient **fortement** ce qu'on lui donne. Si le bureau se
    /// déclarait lui-même, la boucle serait fermée : le bureau tient la vue, la
    /// vue tient son contrôleur, le contrôleur tiendrait le bureau. Rien ne se
    /// libérerait jamais — un processus de contenu web par bureau ouvert,
    /// jusqu'à la fin de l'application.
    ///
    /// Avec ce relais et sa référence **faible** vers le bureau, la chaîne
    /// s'arrête : plus personne ne retient le bureau depuis la vue, donc le
    /// relâcher relâche tout, et aucun `deinit` n'a à défaire quoi que ce
    /// soit.
    private final class Channel: NSObject, WKScriptMessageHandler {
        weak var desktop: LocalDesktop?
        var stopped: Stopped?

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            desktop?.answer(body)
        }
    }
}
#endif

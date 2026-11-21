#if canImport(WebKit)
import Foundation
import WebKit
import WisqVM

/// **La machine de l'émetteur dans un `WKWebView`** : le seul morceau qui ait
/// besoin de WebKit, et il ne décide rien.
///
/// Il tient ensemble ce qui est écrit et jugé ailleurs : le magasin
/// (`EmitterStore`), branché comme gestionnaire du schéma `wisq-machine://` ;
/// les messages de la page, lus par `EmitterBridge` ; et le JavaScript qu'on
/// lui envoie, écrit par `EmitterBridge` aussi. La page elle-même
/// (`web/machine.html` et `web/machine.js`) est jugée sous Bun, contre le même
/// magasin, par `EmitterMachineTests`.
///
/// **Ce qui ne se juge que sur un appareil Apple** — que WebKit charge des
/// modules ES et fasse des `fetch` sur un schéma à soi, compile le module, et
/// garde le JIT — est tenu par `LocalDesktopTests`, hébergé par l'application
/// dans le job « App iOS ».
@MainActor
public final class EmitterDesktop {
    public enum Failure: Error, Equatable {
        /// Cette construction n'embarque pas le module de la page.
        case moduleNotInThisBuild
        /// La page n'a pas dit « prête » dans le délai.
        case neverReady
        /// La page est tombée en panne, sous ce nom.
        case page(String)
        /// Le processus de contenu de WebKit est mort.
        case theViewsProcessDied
    }

    /// La vue, à poser dans l'interface.
    public let view: WKWebView
    /// Le magasin, pour dire ce que le disque a servi.
    public let store: EmitterStore

    /// **Ce que l'invité a dit sur son port série**, gardé : les derniers
    /// `consoleKeep` octets, et combien ont été jetés avant.
    public private(set) var console = Data()
    public private(set) var consoleLost = 0
    public static let consoleKeep = 1 << 18
    public private(set) var isReady = false
    public private(set) var screenSize: (width: Int, height: Int)?
    public private(set) var stopped: (why: String, at: UInt64, refusal: String?)?
    public private(set) var failure: Failure?
    /// Les messages illisibles : un défaut de pont, compté pour qu'un test le
    /// voie au lieu de le perdre.
    public private(set) var unreadable = 0

    /// Appelée à chaque message lu, sur le fil principal.
    public var onChange: (() -> Void)?

    private let channel: Channel
    private let schemes: SchemeHandler

    /// `module` : celui que la bibliothèque embarque, par défaut ; un test peut
    /// en donner un autre.
    public init(prepared: EmitterMachine.Prepared, module: Data? = EmitterMachine.embeddedModule) throws {
        guard let module else { throw Failure.moduleNotInThisBuild }
        store = prepared.store(module: module)
        schemes = SchemeHandler(store: store)
        channel = Channel()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemes, forURLScheme: EmitterMachine.scheme)
        configuration.userContentController.add(channel, name: "wisq")
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 400), configuration: configuration)
        channel.desktop = self
        view.navigationDelegate = channel
    }

    /// Charger la page : elle va chercher son plan, son module, la RAM, et
    /// part d'elle-même.
    public func start() {
        view.load(URLRequest(url: EmitterMachine.pageURL))
    }

    /// Attendre que la page ait dit « prête », ou sa panne.
    public func waitUntilReady(patience: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(patience)
        while !isReady && failure == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        if let failure { throw failure }
        guard isReady else { throw Failure.neverReady }
    }

    /// Attendre l'arrêt de la machine, ou rendre `nil` au délai.
    public func waitUntilStopped(patience: TimeInterval) async -> (why: String, at: UInt64, refusal: String?)? {
        let deadline = Date().addingTimeInterval(patience)
        while stopped == nil && failure == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return stopped
    }

    // MARK: - Lui parler

    /// Taper un texte, au rythme d'une main.
    public func type(_ text: String) { send(EmitterBridge.typing(text)) }
    /// Une touche de la barre.
    public func press(_ key: TerminalKey) { send(EmitterBridge.key(key)) }
    /// Une touche du clavier matériel, par son keysym X11.
    public func key(keysym: UInt32, down: Bool) {
        let events = EmitterBridge.events(forKeysym: keysym, down: down)
        if !events.isEmpty { send(EmitterBridge.keys(events)) }
    }
    public func touch(x: Double, y: Double, buttons: UInt8) {
        send(EmitterBridge.touch(x: x, y: y, buttons: buttons))
    }
    public func scroll(notches: Int) { send(EmitterBridge.scroll(notches: notches)) }
    /// Arrêter la machine à la fin de sa tranche.
    public func stop() { send(EmitterBridge.stop) }

    /// **Évaluer une expression dans la page** et rendre sa valeur : ce que
    /// font les gestes ci-dessus, et ce qu'un test lit.
    public func evaluate(_ expression: String) async throws -> Any? {
        do {
            return try await view.callAsyncJavaScript(
                "return await (\(expression));", arguments: [:], in: nil, contentWorld: .page)
        } catch {
            if channel.processDied { throw Failure.theViewsProcessDied }
            throw Failure.page(String(describing: error))
        }
    }

    /// **Envoyer sans attendre**, par le même chemin qu'`evaluate` : celui
    /// que le test hébergé juge.
    ///
    /// C'était `evaluateJavaScript`, dont la forme `async` rend un `Any` non
    /// optionnel. Plusieurs de ces scripts rendent `undefined` — `arreter()`,
    /// `toucher()` quand l'invité n'a pas pris la tablette —, et ce pont
    /// supporte mal un résultat nul selon les versions du SDK. Rien ne jugeait
    /// ce chemin, pas même le test hébergé, qui passait par `evaluate`.
    /// `callAsyncJavaScript` rend un `Any?` : un `undefined` y est `nil`. Les
    /// envois partent dans l'ordre, chaque tâche du fil principal appelant
    /// WebKit avant de rendre la main.
    private func send(_ script: String) {
        guard isReady else { return }
        Task { @MainActor [weak self] in
            _ = try? await self?.evaluate(script)
        }
    }

    // MARK: - L'écouter

    fileprivate func receive(_ body: [String: Any]) {
        let message: EmitterBridge.Message
        do {
            message = try EmitterBridge.message(from: body)
        } catch {
            unreadable += 1
            return
        }
        switch message {
        case .ready:
            isReady = true
        case .console(let octets, let lost):
            consoleLost += lost
            console.append(octets)
            if console.count > Self.consoleKeep {
                let excess = console.count - Self.consoleKeep
                console.removeFirst(excess)
                consoleLost += excess
            }
        case .screen(let width, let height):
            screenSize = (width, height)
        case .stopped(let why, let at, let refusal):
            stopped = (why, at, refusal)
        case .failure(let why):
            failure = .page(why)
        }
        onChange?()
    }

    fileprivate func processDied() {
        failure = .theViewsProcessDied
        onChange?()
    }

    /// **Le relais des messages et de la navigation**, séparé pour ne pas
    /// fermer la boucle de rétention : le contrôleur de contenu retient
    /// fortement ce qu'on lui donne, et ce relais ne tient le bureau que
    /// faiblement (la même raison que dans `LocalDesktop`).
    private final class Channel: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var desktop: EmitterDesktop?
        var processDied = false

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            desktop?.receive(body)
        }

        func webViewWebContentProcessDidTerminate(_ web: WKWebView) {
            processDied = true
            desktop?.processDied()
        }

        func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            desktop?.receive(["kind": "panne", "pourquoi": error.localizedDescription])
        }

        func webView(
            _ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            desktop?.receive(["kind": "panne", "pourquoi": error.localizedDescription])
        }
    }

    /// Une valeur qu'on fait traverser vers un autre fil sans qu'elle soit
    /// `Sendable` : la tâche d'URL, qu'on ne touche que depuis le fil
    /// principal, à l'aller comme au retour.
    private struct Unchecked<Value>: @unchecked Sendable {
        let value: Value
    }

    /// **Le gestionnaire du schéma** : chaque requête part au magasin hors du
    /// fil principal — lire une plage de l'ISO ou un segment du noyau ne doit
    /// pas geler l'interface —, et la réponse revient sur le fil principal.
    /// Une tâche arrêtée par WebKit entre-temps ne reçoit rien : lui répondre
    /// lèverait une exception.
    private final class SchemeHandler: NSObject, WKURLSchemeHandler {
        let store: EmitterStore
        private var live = Set<ObjectIdentifier>()

        init(store: EmitterStore) {
            self.store = store
        }

        func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
            let request = urlSchemeTask.request
            guard let url = request.url else {
                urlSchemeTask.didFailWithError(URLError(.badURL))
                return
            }
            let method = request.httpMethod ?? "GET"
            let body = request.httpBody ?? request.httpBodyStream.map(Self.drain)
            let id = ObjectIdentifier(urlSchemeTask)
            live.insert(id)
            let task = Unchecked(value: urlSchemeTask)
            let store = store
            Task.detached(priority: .userInitiated) { [weak self] in
                let response = store.respond(method: method, url: url, body: body)
                await MainActor.run {
                    self?.finish(task.value, id: id, url: url, response: response)
                }
            }
        }

        func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
            live.remove(ObjectIdentifier(urlSchemeTask))
        }

        private func finish(
            _ task: any WKURLSchemeTask, id: ObjectIdentifier, url: URL, response: EmitterStore.Response
        ) {
            guard live.remove(id) != nil else { return }
            // `Access-Control-Allow-Origin` : la page et ses modules sont du
            // même schéma, mais une origine de schéma à soi peut se lire
            // opaque, et un module ES se charge en mode CORS.
            let headers = [
                "Content-Type": response.contentType,
                "Content-Length": String(response.body.count),
                "Cache-Control": "no-store",
                "Access-Control-Allow-Origin": "*",
            ]
            guard let http = HTTPURLResponse(
                url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: headers)
            else {
                task.didFailWithError(URLError(.cannotParseResponse))
                return
            }
            task.didReceive(http)
            task.didReceive(response.body)
            task.didFinish()
        }

        /// Le corps d'une requête qui arrive en flux plutôt qu'en octets.
        private static func drain(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            return data
        }
    }
}
#endif

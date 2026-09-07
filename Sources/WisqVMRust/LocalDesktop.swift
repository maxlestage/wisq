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
        /// L'image déborderait de la RAM invitée — donc dans la correspondance,
        /// qui vit juste au-dessus. Un refus vaut mieux qu'une machine qui
        /// saute n'importe où au premier changement de région.
        case imageDoesNotFit(folded: Int, bytes: Int, ram: Int)
        /// La machine s'est arrêtée mais n'a pas dit pourquoi : le message
        /// d'arrêt n'est jamais arrivé. C'est un défaut de pont, pas une issue.
        case stopWasNeverAnnounced
        /// **Peindre sans cadre.** Un bureau construit sans écran n'a rien à
        /// montrer ; le refus le dit, plutôt que de laisser l'appelant croire
        /// qu'une image est passée.
        case noFrameWasDeclared
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
    /// Le cadre que la page peindra, ou `nil` pour une machine qu'on juge sur
    /// ses registres. Un démarrage sans écran est un cas réel.
    private let screen: DesktopTranslator.Screen?
    private let channel = "wisq"
    private let web: WKWebView
    private let handler: Channel

    public init(
        pages: UInt32,
        entry: UInt64,
        screen: DesktopTranslator.Screen? = nil
    ) throws {
        guard pages > 0, pages & (pages - 1) == 0 else {
            throw Failure.ramIsNotAPowerOfTwo(pages)
        }
        // **Le cadre est jugé ici**, au plus tôt, et pas à la construction de
        // la page : un bureau dont l'écran ne tient pas ne doit pas exister.
        // C'est la même frontière que partout — au-dessus de la RAM vit la
        // correspondance adresse → indice, et un cadre à cheval sur ce bord
        // afficherait la table des blocs tout en la détruisant.
        if let screen {
            let ram = UInt64(pages) * 65536
            let folded = screen.base & (ram - 1)
            // **La surface peut déborder de soixante-quatre bits**, et ce
            // débordement-là *accepterait* au lieu de refuser : deux dimensions
            // de deux puissance trente et un donnent exactement deux puissance
            // soixante-quatre. En Swift la multiplication piégerait — un
            // plantage au lieu d'un refus, ce qui n'est pas mieux.
            let (pixels, tooWide) = UInt64(screen.width)
                .multipliedReportingOverflow(by: UInt64(screen.height))
            let (bytes, tooBig) = pixels.multipliedReportingOverflow(by: 4)
            // La comparaison est écrite en **soustrayant** plutôt qu'en
            // additionnant : `folded + bytes` déborderait pour un `bytes`
            // proche du maximum, et Swift piégerait là aussi.
            guard screen.width > 0, screen.height > 0, !tooWide, !tooBig,
                  bytes <= ram, folded <= ram - bytes
            else {
                // **`Int(clamping:)` et pas `Int(...)`.** Une surface de deux
                // puissance soixante-trois ne déborde pas d'un `UInt64` mais
                // ne tient pas dans un `Int` : la conversion piégerait, et le
                // refus deviendrait un plantage. Le nombre annoncé est alors
                // « au moins ça », ce qui suffit pour un refus.
                throw Failure.imageDoesNotFit(
                    folded: Int(clamping: folded),
                    bytes: tooWide || tooBig ? Int.max : Int(clamping: bytes),
                    ram: Int(clamping: ram)
                )
            }
        }
        self.pages = pages
        self.entry = entry
        self.screen = screen
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
        // Les trois raisons de refuser une page — la RAM, le nom du canal, le
        // cadre — sont toutes tenues avant d'arriver ici : les deux premières
        // par l'initialisation et par une constante, la troisième par la garde
        // ci-dessous. Ce `guard` ne peut donc plus se déclencher, et c'est dit
        // plutôt que caché derrière un refus qui nommerait la mauvaise cause.
        guard let page = DesktopTranslator.page(
            pages: pages, entry: entry, channel: channel, screen: screen
        ) else {
            throw Failure.ramIsNotAPowerOfTwo(pages)
        }
        // **Attendre l'événement, pas un drapeau.** Ce qu'il y avait ici
        // interrogeait `web.isLoading` en boucle — et juste après
        // `loadHTMLString`, ce drapeau est **encore faux** : la navigation n'a
        // pas commencé. La boucle sortait donc au premier tour, `load` rendait
        // la main sur une page qui n'existait pas encore, et l'appel suivant
        // partait dans le vide. Quand la vraie navigation s'engageait ensuite,
        // elle jetait la continuation en attente — d'où
        // `InvalidTransition { phase: idle, targetPhase: failed(deinit) }`,
        // une erreur WebKit qui ne dit rien de sa cause.
        //
        // C'est **exactement** la course déjà corrigée sur le message d'arrêt :
        // une vue poste et notifie, elle ne renseigne pas un drapeau à
        // l'instant où on le lit. Je l'avais réparée d'un côté et laissée de
        // l'autre.
        //
        // Le délégué est retenu **faiblement** par la vue, mais fortement par
        // le contrôleur de contenu qui l'a déjà comme gestionnaire de
        // messages : rien à garder de plus, rien à défaire.
        handler.loaded = false
        handler.failure = nil
        web.navigationDelegate = handler
        web.loadHTMLString(page, baseURL: nil)
        let deadline = Date().addingTimeInterval(patience)
        while !handler.loaded && handler.failure == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if let why = handler.failure { throw Failure.script(why) }
        guard handler.loaded else { throw Failure.viewNeverFinishedLoading }
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
        // **La RAM de l'invité s'arrête là, et la correspondance commence
        // juste après.** Un morceau à cheval sur ce bord n'écrirait pas « un
        // peu trop loin » : il écrirait dans la table que le module lit pour
        // trouver ses régions, et la machine sauterait n'importe où. C'est la
        // même borne que `host.js` pose sur sa lecture, et elle vaut aussi à
        // l'écriture.
        let ram = Int(pages) * 65536
        let folded = Int(address & UInt64(ram - 1))
        // Écrit en **soustrayant** : `folded + image.count` déborderait pour une
        // taille absurde, et Swift piégerait au lieu de refuser. `folded` est
        // toujours plus petit que `ram`, donc la soustraction est sûre.
        guard image.count <= ram - folded else {
            throw Failure.imageDoesNotFit(folded: folded, bytes: image.count, ram: ram)
        }
        let chunk = 48 * 1024
        var written = 0
        while written < image.count {
            let piece = image[
                image.startIndex + written ..< image.startIndex + min(written + chunk, image.count)
            ]
            let script = """
                const brut = atob(octets);
                const vue = new Uint8Array(window.wisqMachine.memory.buffer, at, brut.length);
                for (let i = 0; i < brut.length; i++) vue[i] = brut.charCodeAt(i);
                return brut.length;
                """
            do {
                _ = try await web.callAsyncJavaScript(
                    script,
                    arguments: [
                        "octets": piece.base64EncodedString(),
                        "at": folded + written,
                    ],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                throw Failure.script(error.localizedDescription)
            }
            written += piece.count
        }
    }

    /// **Relire la mémoire de l'invité**, à l'adresse repliée.
    ///
    /// Le miroir de `place`, et il porte la même borne : la correspondance vit
    /// juste au-dessus de la RAM, et la relire l'enverrait à l'application, qui
    /// la prendrait pour de la mémoire invitée.
    ///
    /// **Pourquoi ça existe.** Une écriture qu'on ne peut pas relire ne se
    /// vérifie pas : une `place` qui perdrait une tranche sur deux se
    /// comporterait exactement comme une `place` qui marche, jusqu'à ce que la
    /// machine saute dans le vide bien plus tard. C'est aussi ce qui permet à
    /// l'application de tirer un instantané, ou de regarder ce que l'invité a
    /// écrit quelque part.
    ///
    /// **Le chemin est le même que celui de l'écriture, et il coûte autant** :
    /// du base64 par tranches à travers le pont. Relire un noyau entier serait
    /// aussi cher que l'écrire.
    public func read(_ count: Int, at address: UInt64) async throws -> Data {
        let ram = Int(pages) * 65536
        let folded = Int(address & UInt64(ram - 1))
        guard count >= 0, count <= ram - folded else {
            throw Failure.imageDoesNotFit(folded: folded, bytes: count, ram: ram)
        }
        var image = Data()
        image.reserveCapacity(count)
        let chunk = 48 * 1024
        while image.count < count {
            let piece = min(chunk, count - image.count)
            let script = """
                const vue = new Uint8Array(
                  window.wisqMachine.memory.buffer, at, combien
                );
                // Par tranches : passer quarante-huit kibioctets à
                // `String.fromCharCode` en une fois dépasse la pile d'arguments.
                let binaire = "";
                for (let i = 0; i < vue.length; i += 4096) {
                  binaire += String.fromCharCode.apply(null, vue.subarray(i, i + 4096));
                }
                return btoa(binaire);
                """
            let returned: Any?
            do {
                returned = try await web.callAsyncJavaScript(
                    script,
                    arguments: ["at": folded + image.count, "combien": piece],
                    in: nil,
                    contentWorld: .page
                )
            } catch {
                throw Failure.script(error.localizedDescription)
            }
            guard let text = returned as? String,
                  let bytes = Data(base64Encoded: text),
                  bytes.count == piece
            else {
                throw Failure.script("la vue n'a pas rendu \(piece) octets lisibles")
            }
            image.append(bytes)
        }
        return image
    }

    /// Fait tourner la machine jusqu'à ce qu'elle s'arrête, et dit pourquoi.
    public func run(patience: TimeInterval = 5) async throws -> Stopped {
        let returned: Any?
        do {
            returned = try await web.callAsyncJavaScript(
                "return await window.wisqRun()", arguments: [:], in: nil, contentWorld: .page
            )
        } catch {
            throw Failure.script(error.localizedDescription)
        }
        // **Le message d'arrêt n'arrive pas forcément avant le retour.** Une
        // vue poste, elle n'appelle pas : `wisqRun` a rendu la main, mais le
        // message peut encore être en route vers l'application. Lire
        // `handler.stopped` tout de suite serait une course — celle qui rend un
        // test vert neuf fois sur dix.
        let deadline = Date().addingTimeInterval(patience)
        while handler.stopped == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        guard let stopped = handler.stopped else { throw Failure.stopWasNeverAnnounced }
        // **Les deux chemins doivent dire la même chose.** `wisqRun` rend la
        // raison, le message la porte aussi : les comparer transforme une
        // redondance en garde, au lieu de la laisser diverger en silence.
        if let announced = returned as? String, announced != stopped.why {
            throw Failure.script(
                "la machine rend « \(announced) » et poste « \(stopped.why) »"
            )
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

    /// **Peindre une image, maintenant.**
    ///
    /// Rend le nombre de pixels peints. **Une fonction qui ne rend rien ne se
    /// distingue pas d'une fonction qui n'a rien fait** — et c'est la seule
    /// chose que l'application puisse lire de l'autre côté du pont.
    ///
    /// **Pourquoi ceci existe alors que la page a déjà sa boucle
    /// d'affichage.** `requestAnimationFrame` ne tourne que dans une vue que le
    /// système considère comme affichée. Cette vue-ci n'est ajoutée à aucune
    /// fenêtre : elle pourrait n'en recevoir aucune. Un test qui attendrait une
    /// image n'aurait alors rien à attendre, et l'application qui montre le
    /// bureau dans un `WKWebView` posé sur l'écran, elle, en recevra. Les deux
    /// chemins mènent au même `wisqPaint`.
    public func paint() async throws -> Int {
        guard screen != nil else { throw Failure.noFrameWasDeclared }
        do {
            // **La valeur revient en texte**, comme celle d'une globale : un
            // nombre JavaScript traverse le pont en `NSNumber`, et le convertir
            // suppose une correspondance que rien ici ne vérifie.
            let value = try await web.callAsyncJavaScript(
                "return window.wisqPaint().toString()",
                arguments: [:], in: nil, contentWorld: .page
            )
            guard let text = value as? String, let pixels = Int(text) else {
                throw Failure.script("wisqPaint n'a pas rendu un nombre lisible")
            }
            return pixels
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
    private final class Channel: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var desktop: LocalDesktop?
        var stopped: Stopped?
        /// Vrai quand la page a **fini** de charger. Pas « n'est plus en train
        /// de charger » : ces deux phrases ne veulent pas dire la même chose
        /// avant que la navigation ait commencé.
        var loaded = false
        /// Et une page qui refuse de charger doit le dire, plutôt que
        /// d'épuiser la patience et de ressembler à une vue lente.
        var failure: String?

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
        }

        func webView(
            _ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error
        ) {
            failure = error.localizedDescription
        }

        func webView(
            _ web: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            failure = error.localizedDescription
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any] else { return }
            desktop?.answer(body)
        }
    }
}
#endif

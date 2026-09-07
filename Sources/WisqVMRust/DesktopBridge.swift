import Foundation

/// **Ce que l'application répond à la vue, sans la vue.**
///
/// Le `WKWebView` n'existe que sur un appareil Apple, mais presque rien de ce
/// que l'application fait avec lui n'en dépend : lire une demande, trouver les
/// octets de la région, appeler l'émetteur, rendre la réponse. Tout ça est du
/// calcul, et le mettre ici plutôt que dans le gestionnaire de messages le rend
/// **jugeable sous Linux** — là où la CI tourne à chaque commit, plutôt que sur
/// le seul runner qui coûte cher.
///
/// Ce qui reste de l'autre côté est le câblage : déclarer le gestionnaire,
/// recevoir un `WKScriptMessage`, évaluer le JavaScript que ce type produit.
///
/// **Une limite du contrat, écrite ici parce qu'elle ne l'est nulle part
/// ailleurs.** La demande ne porte que l'adresse, jamais les octets. C'est donc
/// à l'application de les trouver — et la RAM de l'invité vit dans la vue, pas
/// chez elle : elle ne peut les trouver que dans l'image qu'elle a chargée.
/// Pour le noyau, ça suffit. Pour du code que l'invité écrit lui-même — un
/// module chargé — l'application lirait ce que son image contient à cette
/// adresse, c'est-à-dire **les mauvais octets, sans que rien ne le dise**.
///
/// Tant que le contrat ne porte pas les octets, l'appelant doit donc **refuser**
/// une adresse qui ne tombe pas dans l'image qu'il a posée, plutôt que de
/// traduire au jugé : un refus arrête la machine proprement, un module faux la
/// fait sauter n'importe où. Le refus se dit avec `translated(id:module:)` et
/// `nil`, comme un refus de l'émetteur.
public enum DesktopBridge {
    /// Ce que la vue peut demander. Le contrat est celui de `web/host.js`, et
    /// il n'a que deux entrées.
    public enum Request: Equatable, Sendable {
        /// « traduis-moi la région à cette adresse, et pose ses blocs à partir
        /// de cet emplacement ».
        case translate(id: Int, address: UInt64, slot: UInt32)
        /// « la machine s'est arrêtée, et voilà pourquoi ».
        case stopped(why: String, at: UInt64)
    }

    /// Pourquoi une demande n'a pas pu être lue. Ce sont des **défauts**, pas
    /// des issues normales : la page est engendrée par wisq, donc une demande
    /// illisible veut dire que les deux moitiés ont divergé.
    public enum Unreadable: Error, Equatable, Sendable {
        case noKind
        case unknownKind(String)
        case missingField(String)
        /// **L'adresse n'est pas arrivée en texte.** Un `Number` JavaScript
        /// perd ses bits au-delà de deux puissance cinquante-trois, et un noyau
        /// x86-64 vit couramment plus haut. La refuser bruyamment vaut mieux
        /// que traduire une région à deux mégaoctets de là.
        case addressIsNotText
        case addressIsNotANumber(String)
    }

    /// Lit une demande telle que `WKScriptMessage.body` la livre : un
    /// dictionnaire de valeurs Foundation.
    public static func request(from body: [String: Any]) throws -> Request {
        guard let kind = body["kind"] as? String else { throw Unreadable.noKind }
        switch kind {
        case "traduire":
            guard let id = body["id"] as? Int else { throw Unreadable.missingField("id") }
            guard let slot = body["slot"] as? Int else { throw Unreadable.missingField("slot") }
            return .translate(id: id, address: try address(body["address"]), slot: UInt32(slot))
        case "arrêt":
            guard let why = body["stopped"] as? String else {
                throw Unreadable.missingField("stopped")
            }
            return .stopped(why: why, at: try address(body["at"]))
        default:
            throw Unreadable.unknownKind(kind)
        }
    }

    private static func address(_ value: Any?) throws -> UInt64 {
        guard let text = value as? String else {
            if value == nil { throw Unreadable.missingField("address") }
            throw Unreadable.addressIsNotText
        }
        guard let address = UInt64(text) else { throw Unreadable.addressIsNotANumber(text) }
        return address
    }

    /// **La réponse, en JavaScript à évaluer dans la vue.**
    ///
    /// `octets` est le module, ou `nil` quand l'émetteur refuse — et un refus
    /// est une issue normale : la vue s'arrête proprement au lieu de sauter
    /// dans le vide.
    ///
    /// Rien de ce qui vient de la vue n'est recollé ici : `id` traverse en
    /// nombre et les octets en nombres. C'est ce qui rend la chaîne sûre par
    /// construction plutôt que par échappement.
    public static func translated(id: Int, module: Data?) -> String {
        guard let module else { return "wisqTranslated(\(id), null)" }
        var script = "wisqTranslated(\(id), ["
        script.reserveCapacity(module.count * 4 + 32)
        for (at, byte) in module.enumerated() {
            if at > 0 { script += "," }
            script += String(byte)
        }
        script += "])"
        return script
    }
}

import Foundation

/// Le descripteur OVF d'une appliance, lu pour une seule question : **quel
/// fichier est le disque qui démarre ?**
///
/// **Où est la réponse.** Un OVF décrit ses fichiers (`References/File`,
/// `ovf:id` → `ovf:href`), ses disques (`DiskSection/Disk`, `ovf:diskId` →
/// `ovf:fileRef`), puis le matériel de la machine
/// (`VirtualHardwareSection/Item`). Un disque branché est un `Item` de type
/// 17 dont `rasd:HostResource` vaut `ovf:/disk/<diskId>`, et c'est l'ordre de
/// ces `Item` que VirtualBox, VMware et `ovftool` suivent pour l'ordre des
/// disques sur leur contrôleur : le premier est celui qui démarre. Sans
/// `Item` de disque, le premier disque de `DiskSection` ; sans rien,
/// personne — l'appelant garde alors son choix d'avant.
///
/// **Pourquoi pas `XMLParser`.** Sous Linux il vit dans `FoundationXML`, qui
/// tire libxml2 ; `WisqVM` ne dépend que de Foundation, sur toutes ses
/// plateformes. Un OVF n'emploie qu'un sous-ensemble sage de XML — balises,
/// attributs, texte, commentaires —, et ce que ce lecteur ne comprend pas, il
/// le saute : au pire, il ne répond rien.
public enum OvfDescriptor {
    /// Le `href` du disque de démarrage, ou `nil` si le descripteur ne le
    /// dit pas.
    public static func bootDiskHref(_ descriptor: String) -> String? {
        var files: [String: String] = [:]
        var disks: [(id: String, fileRef: String)] = []
        var attached: [String] = []
        // L'`Item` en cours de lecture : son type et sa ressource, dont le
        // texte arrive entre les balises de ses enfants.
        var inItem = false
        var resourceType = ""
        var hostResource = ""
        var field: String?
        var collected = ""

        for token in tokens(descriptor) {
            switch token {
            case .open(let name, let attributes, let selfClosing):
                switch name {
                case "File":
                    if let id = attributes["id"], let href = attributes["href"] { files[id] = href }
                case "Disk":
                    if let id = attributes["diskId"], let ref = attributes["fileRef"] {
                        disks.append((id, ref))
                    }
                case "Item", "StorageItem":
                    inItem = true
                    resourceType = ""
                    hostResource = ""
                case "ResourceType", "HostResource":
                    guard inItem else { break }
                    field = selfClosing ? nil : name
                    collected = ""
                default:
                    break
                }
            case .text(let chunk):
                if field != nil { collected += chunk }
            case .close(let name):
                if name == field {
                    let value = collected.trimmingCharacters(in: .whitespacesAndNewlines)
                    if name == "ResourceType" { resourceType = value } else { hostResource = value }
                    field = nil
                } else if name == "Item" || name == "StorageItem", inItem {
                    inItem = false
                    if resourceType == "17", let disk = diskReference(hostResource) {
                        attached.append(disk)
                    }
                }
            }
        }

        let byId = Dictionary(disks.map { ($0.id, $0.fileRef) }, uniquingKeysWith: { first, _ in first })
        for id in attached {
            if let ref = byId[id], let href = files[ref] { return href }
        }
        if let first = disks.first, let href = files[first.fileRef] { return href }
        return nil
    }

    /// `ovf:/disk/vmdisk1` ou `/disk/vmdisk1` → `vmdisk1`. Un `ovf:/file/…`
    /// désigne un fichier sans passer par `DiskSection` : il n'est pas un
    /// disque au sens du descripteur, et n'est pas suivi.
    static func diskReference(_ resource: String) -> String? {
        for prefix in ["ovf:/disk/", "/disk/"] where resource.hasPrefix(prefix) {
            let id = String(resource.dropFirst(prefix.count))
            return id.isEmpty ? nil : id
        }
        return nil
    }

    // MARK: - Un XML sage

    enum Token: Equatable {
        /// Le nom local — sans son préfixe d'espace de noms —, et les
        /// attributs par nom local.
        case open(String, [String: String], selfClosing: Bool)
        case close(String)
        case text(String)
    }

    static func tokens(_ source: String) -> [Token] {
        var out: [Token] = []
        var rest = Substring(source)
        while !rest.isEmpty {
            guard let lt = rest.firstIndex(of: "<") else {
                out.append(.text(unescape(rest)))
                break
            }
            if lt > rest.startIndex { out.append(.text(unescape(rest[..<lt]))) }
            rest = rest[lt...]
            // Commentaires, déclarations et instructions : sautés entiers.
            if rest.hasPrefix("<!--") {
                guard let end = rest.range(of: "-->") else { break }
                rest = rest[end.upperBound...]
                continue
            }
            guard let gt = tagEnd(rest) else { break }
            let inside = rest[rest.index(after: rest.startIndex)..<gt]
            rest = rest[rest.index(after: gt)...]
            if inside.hasPrefix("?") || inside.hasPrefix("!") { continue }
            if inside.hasPrefix("/") {
                out.append(.close(localName(inside.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines))))
                continue
            }
            let selfClosing = inside.hasSuffix("/")
            let body = selfClosing ? inside.dropLast() : inside
            let nameEnd = body.firstIndex(where: { $0.isWhitespace }) ?? body.endIndex
            out.append(.open(localName(String(body[..<nameEnd])),
                             attributes(body[nameEnd...]), selfClosing: selfClosing))
        }
        return out
    }

    /// Le `>` qui ferme la balise, en sautant ceux des valeurs entre
    /// guillemets.
    private static func tagEnd(_ tag: Substring) -> Substring.Index? {
        var quote: Character?
        var index = tag.index(after: tag.startIndex)
        while index < tag.endIndex {
            let character = tag[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return index
            }
            index = tag.index(after: index)
        }
        return nil
    }

    private static func attributes(_ text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var rest = text
        while let equal = rest.firstIndex(of: "=") {
            let name = rest[..<equal].trimmingCharacters(in: .whitespacesAndNewlines)
            var after = rest[rest.index(after: equal)...].drop(while: { $0.isWhitespace })
            guard let quote = after.first, quote == "\"" || quote == "'" else { break }
            after = after.dropFirst()
            guard let close = after.firstIndex(of: quote) else { break }
            let key = localName(name)
            if result[key] == nil { result[key] = unescape(after[..<close]) }
            rest = after[after.index(after: close)...]
        }
        return result
    }

    private static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }

    private static func unescape(_ text: Substring) -> String {
        guard text.contains("&") else { return String(text) }
        return text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

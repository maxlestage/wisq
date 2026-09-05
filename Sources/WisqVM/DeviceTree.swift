import Foundation

/// Un arbre de périphériques aplati, construit plutôt que recopié.
///
/// **Pourquoi ce type existe.** L'arbre que la machine rv32 tend à son invité
/// était un blob de 1536 octets repris tel quel de mini-rv32ima, et deux
/// choses s'y écrivaient à des décalages trouvés à la main : la taille de la
/// mémoire, à l'octet 316, et la ligne de commande, à l'octet 192 — avec un
/// plafond de 54 caractères, qui est la place que le blob se trouvait avoir.
/// Aucune des deux ne pouvait *ajouter* quoi que ce soit, et c'est ce qui
/// rendait un disque impossible : un périphérique que l'arbre ne déclare pas
/// n'existe pas pour le noyau.
///
/// **Le blob reste, comme témoin.** Il n'est plus ce qu'on donne à l'invité,
/// mais ce contre quoi on vérifie ce qu'on lui donne : un test démonte les
/// deux et exige qu'ils disent la même chose, nœud par nœud et propriété par
/// propriété. C'est la même discipline que partout ailleurs ici — la vraie
/// chose est la référence, et on ne se mesure pas à soi-même.
///
/// Le format est celui du *Devicetree Specification*, version 17 : un en-tête,
/// un bloc de réservations mémoire, un bloc de structure fait de jetons, et un
/// bloc de chaînes où vivent les noms de propriétés.
public struct DeviceTree {
    /// Ce qu'une propriété porte.
    ///
    /// `empty` n'est pas l'absence : `ranges` et `interrupt-controller` sont
    /// des propriétés **présentes** et vides, et leur seule présence est ce
    /// que le noyau lit.
    public enum Value: Equatable, Sendable {
        case empty
        case string(String)
        /// Plusieurs chaînes bout à bout, chacune terminée par un zéro —
        /// c'est la forme d'un `compatible` qui nomme deux pilotes.
        case strings([String])
        /// Des mots de 32 bits, gros-boutistes. Le format ne connaît que
        /// ceux-là ; une adresse 64 bits est deux cellules.
        case cells([UInt32])

        var bytes: [UInt8] {
            switch self {
            case .empty:
                return []
            case .string(let text):
                return Array(text.utf8) + [0]
            case .strings(let texts):
                return texts.flatMap { Array($0.utf8) + [0] }
            case .cells(let words):
                return words.flatMap { word in
                    (0..<4).map { UInt8(truncatingIfNeeded: word >> (24 - 8 * $0)) }
                }
            }
        }
    }

    /// Un nœud : son nom, ses propriétés dans l'ordre, ses enfants.
    ///
    /// L'ordre des propriétés est gardé parce que l'arbre de référence en a un
    /// et qu'un test compare les deux ; il n'a aucune importance pour le noyau,
    /// qui cherche par nom.
    public struct Node: Equatable, Sendable {
        public var name: String
        public var properties: [(name: String, value: Value)]
        public var children: [Node]

        public init(_ name: String,
                    properties: [(name: String, value: Value)] = [],
                    children: [Node] = []) {
            self.name = name
            self.properties = properties
            self.children = children
        }

        public static func == (lhs: Node, rhs: Node) -> Bool {
            lhs.name == rhs.name && lhs.children == rhs.children
                && lhs.properties.count == rhs.properties.count
                && zip(lhs.properties, rhs.properties).allSatisfy {
                    $0.name == $1.name && $0.value == $1.value
                }
        }

        /// La propriété de ce nom, ou `nil`.
        public func property(_ wanted: String) -> Value? {
            properties.first { $0.name == wanted }?.value
        }

        /// L'enfant de ce nom, ou `nil`. Le nom est celui du nœud tel qu'il
        /// est écrit, unité d'adresse comprise : `uart@10000000`.
        public func child(_ wanted: String) -> Node? {
            children.first { $0.name == wanted }
        }
    }

    public var root: Node
    /// Le processeur de démarrage, écrit dans l'en-tête. Zéro ici, et c'est le
    /// seul hart.
    public var bootCPU: UInt32 = 0

    public init(root: Node) { self.root = root }

    // MARK: - Aplatir

    static let magic: UInt32 = 0xD00D_FEED
    static let version: UInt32 = 17
    static let lastCompatibleVersion: UInt32 = 16
    static let beginNode: UInt32 = 1
    static let endNode: UInt32 = 2
    static let property: UInt32 = 3
    static let end: UInt32 = 9

    /// L'arbre, en octets, prêt à être posé dans la mémoire de l'invité.
    public func flatten() -> [UInt8] {
        var structure: [UInt8] = []
        var strings: [UInt8] = []
        // Les noms de propriétés sont partagés : `reg` apparaît cinq fois dans
        // l'arbre de référence et n'occupe le bloc de chaînes qu'une seule.
        var offsets: [String: UInt32] = [:]

        func nameOffset(_ name: String) -> UInt32 {
            if let known = offsets[name] { return known }
            let offset = UInt32(strings.count)
            offsets[name] = offset
            strings += Array(name.utf8) + [0]
            return offset
        }

        func append(_ word: UInt32, to bytes: inout [UInt8]) {
            for shift in stride(from: 24, through: 0, by: -8) {
                bytes.append(UInt8(truncatingIfNeeded: word >> shift))
            }
        }

        func pad(_ bytes: inout [UInt8]) {
            while bytes.count % 4 != 0 { bytes.append(0) }
        }

        func emit(_ node: Node) {
            append(Self.beginNode, to: &structure)
            structure += Array(node.name.utf8) + [0]
            pad(&structure)
            for property in node.properties {
                let value = property.value.bytes
                append(Self.property, to: &structure)
                append(UInt32(value.count), to: &structure)
                append(nameOffset(property.name), to: &structure)
                structure += value
                pad(&structure)
            }
            for child in node.children { emit(child) }
            append(Self.endNode, to: &structure)
        }

        emit(root)
        append(Self.end, to: &structure)

        // L'en-tête fait quarante octets, et le bloc de réservations qui le
        // suit doit tomber sur huit — il y tombe déjà, mais le dire ici évite
        // d'avoir à le redécouvrir. Une seule entrée, nulle, qui termine la
        // liste : cette machine ne réserve rien.
        let headerBytes = 40
        let reservations = [UInt8](repeating: 0, count: 16)
        let structureStart = headerBytes + reservations.count
        let stringsStart = structureStart + structure.count

        // **La taille totale est arrondie à huit, et c'est une leçon payée.**
        // Le noyau reçoit l'adresse de l'arbre, pas seulement son contenu, et
        // son analyseur exige que cette adresse tombe sur huit octets. Le
        // chargeur pose l'arbre à `taille de la RAM - taille de l'arbre -
        // réserve`, tous deux multiples de huit : c'est donc la **taille de
        // l'arbre** qui décide de l'alignement de l'adresse.
        //
        // Le blob de référence faisait 1536 octets — huit y tombait juste, par
        // chance ou par soin. Le premier arbre construit ici en faisait 1507,
        // le noyau a reçu une adresse impaire, et il n'a pas dit un mot : pas
        // de bannière, pas de panique, une sortie parfaitement vide. C'est ce
        // silence qui rend ce remplissage-ci indispensable.
        // Calculé sur le **total**, pas sur le bloc de chaînes : l'en-tête et
        // les réservations font cinquante-six octets, le bloc de structure est
        // aligné sur quatre, et c'est leur somme qui doit tomber sur huit.
        let unpadded = stringsStart + strings.count
        let padding = [UInt8](repeating: 0, count: (-unpadded) & 7)
        let total = unpadded + padding.count

        var tree: [UInt8] = []
        append(Self.magic, to: &tree)
        append(UInt32(total), to: &tree)
        append(UInt32(structureStart), to: &tree)
        append(UInt32(stringsStart), to: &tree)
        append(UInt32(headerBytes), to: &tree)
        append(Self.version, to: &tree)
        append(Self.lastCompatibleVersion, to: &tree)
        append(bootCPU, to: &tree)
        append(UInt32(strings.count), to: &tree)
        append(UInt32(structure.count), to: &tree)
        return tree + reservations + structure + strings + padding
    }

    // MARK: - Relire

    /// Pourquoi un blob n'a pas pu être relu.
    public enum ReadError: Error, Equatable {
        case notATree
        case truncated
        case unknownToken(UInt32)
    }

    /// L'arbre que ces octets décrivent.
    ///
    /// **Il sert d'abord aux tests**, et c'est sa raison d'être : comparer
    /// l'arbre construit au blob de référence octet pour octet ne dirait rien
    /// d'utile — l'ordre du bloc de chaînes suffit à les séparer sans qu'aucun
    /// noyau ne s'en aperçoive. Ce qu'on veut comparer est ce que les deux
    /// **disent**.
    public static func read(_ blob: [UInt8]) throws -> DeviceTree {
        func word(_ at: Int) throws -> UInt32 {
            guard at >= 0, at + 4 <= blob.count else { throw ReadError.truncated }
            return UInt32(blob[at]) << 24 | UInt32(blob[at + 1]) << 16
                | UInt32(blob[at + 2]) << 8 | UInt32(blob[at + 3])
        }
        guard blob.count >= 40, try word(0) == magic else { throw ReadError.notATree }
        let structureStart = Int(try word(8))
        let stringsStart = Int(try word(12))
        let structureSize = Int(try word(36))

        func text(at start: Int) throws -> String {
            guard start >= 0, start < blob.count else { throw ReadError.truncated }
            guard let end = blob[start...].firstIndex(of: 0) else { throw ReadError.truncated }
            return String(decoding: blob[start..<end], as: UTF8.self)
        }

        var at = structureStart
        var stack: [Node] = []
        var root: Node?
        while at < structureStart + structureSize {
            let token = try word(at)
            at += 4
            switch token {
            case beginNode:
                let name = try text(at: at)
                at += name.utf8.count + 1
                at = (at + 3) & ~3
                stack.append(Node(name))
            case endNode:
                guard let finished = stack.popLast() else { throw ReadError.truncated }
                if var parent = stack.popLast() {
                    parent.children.append(finished)
                    stack.append(parent)
                } else {
                    root = finished
                }
            case property:
                let length = Int(try word(at))
                let nameOffset = Int(try word(at + 4))
                at += 8
                guard at + length <= blob.count else { throw ReadError.truncated }
                let raw = Array(blob[at..<(at + length)])
                at = (at + length + 3) & ~3
                guard var node = stack.popLast() else { throw ReadError.truncated }
                node.properties.append(
                    (try text(at: stringsStart + nameOffset), decode(raw)))
                stack.append(node)
            case end:
                at = structureStart + structureSize
            // **Un jeton NOP est sauté sans bruit.** Le format en autorise
            // partout ; l'arbre de référence n'en a aucun, mais un arbre qui
            // en aurait n'est pas un arbre cassé.
            case 4:
                continue
            default:
                throw ReadError.unknownToken(token)
            }
        }
        guard let root else { throw ReadError.truncated }
        return DeviceTree(root: root)
    }

    /// Ce que ces octets valent, deviné sur leur forme.
    ///
    /// **Le format ne dit pas le type d'une propriété** — c'est le pilote qui
    /// sait. Cette lecture-ci sert à comparer deux arbres, donc elle a le droit
    /// de deviner tant qu'elle devine **pareil** des deux côtés.
    ///
    /// La règle : une valeur qui se termine par un zéro et dont chaque tranche
    /// séparée par un zéro est non vide et imprimable est une chaîne, ou une
    /// suite de chaînes. C'est le « non vide » qui fait le travail — sans lui,
    /// une cellule valant zéro (`00 00 00 00`) passerait pour quatre chaînes
    /// vides, et `offset = <0>` deviendrait du texte.
    ///
    /// **Ce que ça ne tranche pas**, et c'est sans conséquence ici : une
    /// cellule dont les quatre octets seraient imprimables suivis d'un zéro se
    /// lirait comme une chaîne. Les deux côtés la liraient pareil, et le test
    /// d'aller-retour attraperait le jour où l'arbre en contiendrait une.
    static func decode(_ raw: [UInt8]) -> Value {
        if raw.isEmpty { return .empty }
        if raw.last == 0 {
            let parts = raw.dropLast().split(separator: 0, omittingEmptySubsequences: false)
            let readable = !parts.isEmpty && parts.allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            }
            if readable {
                let texts = parts.map { String(decoding: $0, as: UTF8.self) }
                return texts.count == 1 ? .string(texts[0]) : .strings(texts)
            }
        }
        if raw.count % 4 == 0 {
            // **Écrit en boucle, pas en une expression.** Le compilateur
            // d'Apple abandonne sur la version compacte — « unable to
            // type-check this expression in reasonable time » — là où celui de
            // Linux l'avale : quatre conversions, trois décalages et trois
            // « ou » dans une fermeture de `map`, et l'inférence explose. Même
            // famille que les jeux de capacités RDP.
            var words: [UInt32] = []
            words.reserveCapacity(raw.count / 4)
            for at in stride(from: 0, to: raw.count, by: 4) {
                var word = UInt32(raw[at]) << 24
                word |= UInt32(raw[at + 1]) << 16
                word |= UInt32(raw[at + 2]) << 8
                word |= UInt32(raw[at + 3])
                words.append(word)
            }
            return .cells(words)
        }
        return .string(String(decoding: raw, as: UTF8.self))
    }
}

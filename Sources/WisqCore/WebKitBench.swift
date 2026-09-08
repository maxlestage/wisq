import Foundation

/// **Ce qu'un chiffre de la sonde WebKit veut dire.**
///
/// La sonde rend un débit et le coût d'un aller-retour. Seuls, ils ne disent
/// rien à personne : « 400 MIPS » n'est pas une information, « un bureau
/// démarre en deux minutes » en est une. Cette traduction est du calcul, pas
/// de l'affichage, donc elle vit ici — multiplateforme, tenue par des tests
/// que Linux exécute — plutôt que dans une vue que seul un iPhone lance.
///
/// **Pourquoi ce code existe.** Les 1103 MIPS du lot 8 viennent d'un
/// simulateur tournant sur un Mac, où macOS ne restreint pas le JIT. Que
/// WebKit garde le droit de compiler sur un **vrai iPhone** est la conception
/// documentée d'iOS, pas une mesure. Mettre la sonde dans l'application
/// transforme cette inconnue en un chiffre que n'importe quel appareil rend en
/// quelques secondes.
public enum WebKitBench {
    /// **Le module que l'émetteur produit**, pour la boucle de cinq
    /// instructions du banc — pas un module écrit à la main.
    ///
    /// La distinction est tout l'intérêt de la sonde. Le module précédent était
    /// recompilé à la main : il mesurait le **plafond** de l'idée, ce qu'un
    /// émetteur parfait atteindrait. Celui-ci sort de `Module::region`, la
    /// fonction que le bureau local appellera, drapeaux matérialisés et boucle
    /// de répartition comprises. L'appareil chronomètre donc ce que wisq
    /// engendrerait, et le chiffre se compare aux 247 MIPS relevés sous Bun.
    ///
    /// **Écrit par `cargo run -p wisq-vm --release --example bench-module`**, et
    /// tenu par `bench_module_matches_the_probe` : le test refait le module et
    /// le compare à cette chaîne, octet pour octet. Deux copies ne peuvent plus
    /// diverger en silence — c'est ce que l'ancien commentaire affirmait sans
    /// que rien ne le tienne.
    public static let moduleBase64 =
        "AGFzbQEAAAABFQRgAAF/YAF+AGADfn5+AGACfn4BfgKbBDIDZW52A291dAACA2VudgJpbgADA2VudgNtZW0CAIFgA2VudgJnMAN+AQNlbnYCZzED"
        + "fgEDZW52AmcyA34BA2VudgJnMwN+AQNlbnYCZzQDfgEDZW52Amc1A34BA2VudgJnNgN+AQNlbnYCZzcDfgEDZW52Amc4A34BA2VudgJnOQN+AQNl"
        + "bnYDZzEwA34BA2VudgNnMTEDfgEDZW52A2cxMgN+AQNlbnYDZzEzA34BA2VudgNnMTQDfgEDZW52A2cxNQN+AQNlbnYDZzE2A34BA2VudgNnMTcD"
        + "fgEDZW52A2cxOAN+AQNlbnYDZzE5A34BA2VudgNnMjADfgEDZW52A2cyMQN+AQNlbnYDZzIyA34BA2VudgNnMjMDfgEDZW52A2cyNAN+AQNlbnYD"
        + "ZzI1A34BA2VudgNnMjYDfgEDZW52A2cyNwN+AQNlbnYDZzI4A34BA2VudgNnMjkDfgEDZW52A2czMAN+AQNlbnYDZzMxA34BA2VudgNnMzIDfgED"
        + "ZW52A2czMwN+AQNlbnYDZzM0A34BA2VudgNnMzUDfgEDZW52A2czNgN+AQNlbnYDZzM3A34BA2VudgNnMzgDfgEDZW52A2czOQN+AQNlbnYDZzQw"
        + "A34BA2VudgNnNDEDfgEDZW52A2c0MgN+AQNlbnYDZzQzA34BA2VudgNnNDQDfgEDZW52A2c0NQN+AQNlbnYDZzQ2A34BAwMCAAEEBAFwAAEHBwED"
        + "cnVuAAMJBwEAQQALAQIK8QQCxwQAIwJCf4MkJSMAQn+DJCYjJSMmfEJ/gyQnIxBCqm6DIydQrUIGhoQjJ0KAgICAgICAgIB/g1CtQgGFQgeGhCMn"
        + "Qv8Bg3tCAYNCAYVCAoaEIyUjJoUjJ4VCEINCAIaEIycjJVStQgCGhCMlIyeFIyYjJ4WDQoCAgICAgICAgH+DUK1CAYVCC4aEJBAjJ0J/gyQCIwNC"
        + "f4MkJSMBQn+DJCYjJSMmhUJ/gyQnIxBCqm6DIydQrUIGhoQjJ0KAgICAgICAgIB/g1CtQgGFQgeGhCMnQv8Bg3tCAYNCAYVCAoaEIyUjJoUjJ4VC"
        + "EINCAIaEJBAjJ0J/gyQDIwBCf4MkJSMCQn+DJCYjJSMmfEJ/gyQnIxBCqm6DIydQrUIGhoQjJ0KAgICAgICAgIB/g1CtQgGFQgeGhCMnQv8Bg3tC"
        + "AYNCAYVCAoaEIyUjJoUjJ4VCEINCAIaEIycjJVStQgCGhCMlIyeFIyYjJ4WDQoCAgICAgICAgH+DUK1CAYVCC4aEJBAjJ0J/gyQAIwZCf4MkJUIB"
        + "JCYjJSMmfUJ/gyQnIxBCqm6DIydQrUIGhoQjJ0KAgICAgICAgIB/g1CtQgGFQgeGhCMnQv8Bg3tCAYNCAYVCAoaEIyUjJoUjJ4VCEINCAIaEIyUj"
        + "JlStQgCGhCMlIyaFIyUjJ4WDQoCAgICAgICAgH+DUK1CAYVCC4aEJBAjJ0J/gyQGQoCAgIADQo+AgIADIxBCwACDUK1CAYVCAYWnGyQRQQBBfyMQ"
        + "QsAAg1CtQgGFQgGFpxsLJgEBfwJAA0AgAFANASAAQgF9IQAgAREAACEBIAFBAEgNAQwACwsL"

    /// **Ce que l'hôte doit fournir au module.** Ces quatre nombres sont ceux
    /// de `crates/wisq-vm/src/x86_wasm.rs`, et le même test les y compare : un
    /// module qui importe vingt-neuf globales et qu'on instancie avec vingt-huit
    /// ne démarre pas, et la sonde rendrait « indisponible » là où c'est une
    /// dérive entre deux fichiers.
    ///
    /// Les 12289 pages font **768 Mio** : la mémoire linéaire *est* la RAM de
    /// l'invité, adresse pour adresse, et la région du banc vit à 0x30000000.
    /// C'est beaucoup à demander à un WKWebView, et c'est précisément une chose
    /// que la sonde doit découvrir plutôt que supposer.
    public static let guestPages = 12289
    public static let globalCount = 47
    public static let ripSlot = 17
    public static let benchBase: UInt64 = 0x3000_0000

    /// La boucle exécute cinq instructions par tour, et la sonde en fait huit
    /// millions — quarante millions d'instructions, assez pour que le palier
    /// final de JavaScriptCore soit celui qu'on mesure, assez peu pour qu'un
    /// interpréteur ne fasse pas attendre une minute.
    public static let instructionsPerTurn = 5
    public static let benchTurns = 8_000_000

    /// Ce que la sonde a relevé.
    public struct Reading: Equatable, Sendable {
        public let mips: Double
        public let bridgeMilliseconds: Double
        public let instructions: Double
        /// **Cet appareil accepte-t-il deux mémoires importées ?**
        ///
        /// Rien à voir avec le débit, et c'est pour ça que c'est un champ à
        /// part. La question décide de l'architecture du bureau : la
        /// correspondance adresse → indice dont l'enchaînement rapide a besoin
        /// ne peut pas vivre dans la mémoire de l'invité — un noyau qui écrit
        /// au mauvais endroit la détruirait, exactement comme il écrasait RCX
        /// avant que les registres n'en sortent. Il lui faut une **seconde**
        /// mémoire, hors de portée.
        ///
        /// Le JavaScriptCore de Bun l'accepte, sur Linux. Celui d'un iPhone est
        /// une autre question, et cette sonde est le seul endroit qui y répond.
        public let multiMemory: Bool

        public init(
            mips: Double, bridgeMilliseconds: Double, instructions: Double,
            multiMemory: Bool = false
        ) {
            self.mips = mips
            self.bridgeMilliseconds = bridgeMilliseconds
            self.instructions = instructions
            self.multiMemory = multiMemory
        }

        /// Soixante images par seconde laissent 16,7 ms. Un aller-retour qui
        /// mange ça rend le bureau inutilisable **même si le cœur vole**.
        public var bridgeFitsAFrame: Bool { bridgeMilliseconds < WebKitBench.frameMilliseconds }
    }

    public enum Verdict: Equatable, Sendable {
        /// WebKit compile ici : le bureau local a un socle.
        case compiles(Reading)
        /// Le débit est celui d'un interpréteur.
        case interpretsOnly(Reading)
        /// Le module n'a pas tout exécuté : le débit ne veut rien dire.
        case wrongResult
        /// **L'appareil a refusé le module lui-même** — la mémoire trop grande,
        /// ou le module rejeté à la compilation. C'est une réponse, et une
        /// réponse importante : elle porte sur ce que wisq engendre, pas sur la
        /// sonde. La confondre avec `unavailable` ferait passer un mur pour un
        /// contretemps.
        case refused(String)
        /// La vue n'a pas démarré. **Outillage, pas réponse.**
        case unavailable(String)
    }

    /// Le seuil sépare deux mondes, il ne mesure pas une machine : un
    /// JavaScriptCore réduit à son interpréteur rend quelques MIPS sur cette
    /// boucle, et vingt écarte le doute sans dépendre de l'appareil.
    public static let compilingThreshold: Double = 20

    /// Le budget d'une image à soixante par seconde.
    public static let frameMilliseconds: Double = 16.7

    /// L'ordre de grandeur d'un démarrage de bureau complet. **C'est une
    /// estimation assumée, pas une mesure** — elle sert à traduire un débit en
    /// une durée qu'un humain peut juger.
    public static let desktopBootInstructions: Double = 50e9

    /// Ce que le refus de la multi-mémoire coûterait, dit en clair. Un « non »
    /// n'arrête pas le bureau : il ferme un chemin et en laisse un autre, plus
    /// lourd — borner les adresses à la taille de la RAM au lieu de les
    /// tronquer à trente-deux bits, ce que les trois cœurs devraient alors
    /// apprendre ensemble.
    public static func multiMemorySentence(_ accepted: Bool) -> String {
        accepted
            ? "Deux mémoires importées : acceptées. La table qui fait aller vite peut vivre "
                + "hors de portée de l'invité."
            : "Deux mémoires importées : refusées. Ce n'est pas un mur — la table devra vivre "
                + "au-delà de la RAM adressable, ce qui demande de borner les adresses au lieu "
                + "de les tronquer, dans les trois cœurs à la fois."
    }

    public static func judge(mips: Double, bridgeMilliseconds: Double,
                             instructions: Double, expected: Double,
                             multiMemory: Bool = false) -> Verdict {
        // **Le compte d'abord.** Une boucle sortie trop tôt rendrait un débit
        // magnifique et faux ; le croire serait pire que ne rien mesurer.
        guard abs(instructions - expected) <= max(expected * 1e-6, 8) else { return .wrongResult }
        let reading = Reading(
            mips: mips, bridgeMilliseconds: bridgeMilliseconds, instructions: instructions,
            multiMemory: multiMemory)
        return mips > compilingThreshold ? .compiles(reading) : .interpretsOnly(reading)
    }

    /// Combien de minutes pour démarrer un bureau, à ce débit.
    public static func bootMinutes(atMIPS mips: Double) -> Double {
        guard mips > 0 else { return .infinity }
        return desktopBootInstructions / (mips * 1e6) / 60
    }

    /// La phrase à montrer. Elle dit le chiffre **et** ce qu'il implique, parce
    /// qu'un débit sans conséquence se lit de travers.
    public static func sentence(for verdict: Verdict) -> String {
        switch verdict {
        case .unavailable(let why):
            return "Pas de réponse : \(why). C'est de l'outillage, pas un verdict — "
                + "l'appareil n'a rien refusé, la sonde n'a pas pu tourner."
        case .refused(let why):
            return "L'appareil a refusé le module : \(why). Ce n'est pas une mesure "
                + "manquante, c'est un refus — et il porte sur ce que wisq engendre, "
                + "\(guestPages) pages de RAM invitée comprises."
        case .wrongResult:
            return "Le module n'a pas rendu le bon résultat, donc son débit ne veut rien "
                + "dire. Un chiffre ici serait faux, et un faux chiffre est pire qu'aucun."
        case .interpretsOnly(let reading):
            return "\(Int(reading.mips)) MIPS : c'est un interpréteur, pas un compilateur. "
                + "WebKit ne compile pas le WebAssembly sur cet appareil, et le bureau "
                + "local n'a pas de socle par ce chemin."
        case .compiles(let reading):
            let minutes = bootMinutes(atMIPS: reading.mips)
            let boot = minutes < 1
                ? "moins d'une minute"
                : "environ \(Int(minutes.rounded())) minutes"
            let cost = String(format: "%.2f", reading.bridgeMilliseconds)
            let bridge: String
            if reading.bridgeFitsAFrame {
                let perFrame = Int(frameMilliseconds / max(reading.bridgeMilliseconds, 0.001))
                bridge = "le pont coûte \(cost) ms, soit \(perFrame) allers-retours par image"
            } else {
                bridge = "mais le pont coûte \(cost) ms, plus qu'une image entière : "
                    + "il faudrait passer les pixels autrement"
            }
            return "\(Int(reading.mips)) MIPS : WebKit compile ici. Un bureau démarrerait en "
                + "\(boot), contre plus d'une heure avec l'interpréteur. Et \(bridge)."
        }
    }
}

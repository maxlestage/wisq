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
    /// **Les trois modules que l'émetteur produit**, écrits par
    /// `cargo run -p wisq-vm --release --example bench-module` et tenus par
    /// `bench_module_matches_the_probe` : le test les refait et les compare à
    /// ces chaînes, octet pour octet. Deux copies ne peuvent pas diverger en
    /// silence — c'est ce que l'ancien commentaire affirmait sans que rien ne
    /// le tienne.
    ///
    /// **Pourquoi trois, et pourquoi pas un.** La sonde n'en portait qu'un :
    /// `Module::region`, la forme **libre**, sur une boucle de cinq
    /// instructions de registres. L'application n'exécute que
    /// `Module::resolving`, la forme confinée, et tout ce que le confinement
    /// ajoute — le masque, la marche dans les tables, le tampon consulté en
    /// ligne — est **sur les accès mémoire**. Une forme qu'on ne lance pas,
    /// mesurée sur la seule boucle qui n'y touche pas : le chiffre ne pouvait
    /// rien dire du bureau.
    ///
    /// | chaîne | forme | boucle | ce qu'elle répond |
    /// | --- | --- | --- | --- |
    /// | `moduleBase64` | confinée | registres | le débit représentatif |
    /// | `memoryModuleBase64` | confinée | mémoire | — |
    /// | `freeMemoryModuleBase64` | libre | mémoire | — |
    ///
    /// Les deux dernières ne valent qu'**ensemble** : leur écart est ce que le
    /// confinement coûte par accès mémoire, sur cet appareil. Un seul relevé
    /// confiné ne peut pas le rendre, et soustraire deux boucles différentes
    /// mélangerait le coût d'un accès et celui d'un jeu d'instructions.
    ///
    /// La boucle de registres reste la représentative : cinq instructions,
    /// la taille moyenne d'un bloc de base relevée en désassemblant le noyau
    /// Alpine. La boucle mémoire est délibérément dense — deux accès pour
    /// quatre instructions — parce qu'elle mesure le coût d'un accès, pas
    /// celui d'un noyau.
    public static let moduleBase64 =
        "AGFzbQEAAAABNgpgAAF/YAF+AGADfn5+AGACfn4BfmABfgF/YAF/AX5gAX4BfmACfn8BfmADfn5/AGACfn8BfwK6BUADZW52A291dAACA2VudgJp"
        + "bgADA2VudgNtZW0CAJGAAQNlbnYGYmxvY2tzAXAAAQNlbnYCZzADfgEDZW52AmcxA34BA2VudgJnMgN+AQNlbnYCZzMDfgEDZW52Amc0A34BA2Vu"
        + "dgJnNQN+AQNlbnYCZzYDfgEDZW52Amc3A34BA2VudgJnOAN+AQNlbnYCZzkDfgEDZW52A2cxMAN+AQNlbnYDZzExA34BA2VudgNnMTIDfgEDZW52"
        + "A2cxMwN+AQNlbnYDZzE0A34BA2VudgNnMTUDfgEDZW52A2cxNgN+AQNlbnYDZzE3A34BA2VudgNnMTgDfgEDZW52A2cxOQN+AQNlbnYDZzIwA34B"
        + "A2VudgNnMjEDfgEDZW52A2cyMgN+AQNlbnYDZzIzA34BA2VudgNnMjQDfgEDZW52A2cyNQN+AQNlbnYDZzI2A34BA2VudgNnMjcDfgEDZW52A2cy"
        + "OAN+AQNlbnYDZzI5A34BA2VudgNnMzADfgEDZW52A2czMQN+AQNlbnYDZzMyA34BA2VudgNnMzMDfgEDZW52A2czNAN+AQNlbnYDZzM1A34BA2Vu"
        + "dgNnMzYDfgEDZW52A2czNwN+AQNlbnYDZzM4A34BA2VudgNnMzkDfgEDZW52A2c0MAN+AQNlbnYDZzQxA34BA2VudgNnNDIDfgEDZW52A2c0MwN+"
        + "AQNlbnYDZzQ0A34BA2VudgNnNDUDfgEDZW52A2c0NgN+AQNlbnYDZzQ3A34BA2VudgNnNDgDfgEDZW52A2c0OQN+AQNlbnYDZzUwA34BA2VudgNn"
        + "NTEDfgEDZW52A2c1MgN+AQNlbnYDZzUzA34BA2VudgNnNTQDfgEDZW52A2c1NQN+AQNlbnYDZzU2A34BA2VudgNnNTcDfgEDZW52A2c1OAN+AQNl"
        + "bnYDZzU5A34BAwcGAAkGBQcIBxcDA3J1bgAEBnN0YXJ0cwAFBHdhbGsAAwkHAQBBAAsBAgqhEQbXBQAjAkJ/gyQlIwBCf4MkJiMlIyZ8Qn+DJCcj"
        + "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"

    public static let memoryModuleBase64 =
        "AGFzbQEAAAABNgpgAAF/YAF+AGADfn5+AGACfn4BfmABfgF/YAF/AX5gAX4BfmACfn8BfmADfn5/AGACfn8BfwK6BUADZW52A291dAACA2VudgJp"
        + "bgADA2VudgNtZW0CAJGAAQNlbnYGYmxvY2tzAXAAAgNlbnYCZzADfgEDZW52AmcxA34BA2VudgJnMgN+AQNlbnYCZzMDfgEDZW52Amc0A34BA2Vu"
        + "dgJnNQN+AQNlbnYCZzYDfgEDZW52Amc3A34BA2VudgJnOAN+AQNlbnYCZzkDfgEDZW52A2cxMAN+AQNlbnYDZzExA34BA2VudgNnMTIDfgEDZW52"
        + "A2cxMwN+AQNlbnYDZzE0A34BA2VudgNnMTUDfgEDZW52A2cxNgN+AQNlbnYDZzE3A34BA2VudgNnMTgDfgEDZW52A2cxOQN+AQNlbnYDZzIwA34B"
        + "A2VudgNnMjEDfgEDZW52A2cyMgN+AQNlbnYDZzIzA34BA2VudgNnMjQDfgEDZW52A2cyNQN+AQNlbnYDZzI2A34BA2VudgNnMjcDfgEDZW52A2cy"
        + "OAN+AQNlbnYDZzI5A34BA2VudgNnMzADfgEDZW52A2czMQN+AQNlbnYDZzMyA34BA2VudgNnMzMDfgEDZW52A2czNAN+AQNlbnYDZzM1A34BA2Vu"
        + "dgNnMzYDfgEDZW52A2czNwN+AQNlbnYDZzM4A34BA2VudgNnMzkDfgEDZW52A2c0MAN+AQNlbnYDZzQxA34BA2VudgNnNDIDfgEDZW52A2c0MwN+"
        + "AQNlbnYDZzQ0A34BA2VudgNnNDUDfgEDZW52A2c0NgN+AQNlbnYDZzQ3A34BA2VudgNnNDgDfgEDZW52A2c0OQN+AQNlbnYDZzUwA34BA2VudgNn"
        + "NTEDfgEDZW52A2c1MgN+AQNlbnYDZzUzA34BA2VudgNnNTQDfgEDZW52A2c1NQN+AQNlbnYDZzU2A34BA2VudgNnNTcDfgEDZW52A2c1OAN+AQNl"
        + "bnYDZzU5A34BAwcGAAkGBQcIBxcDA3J1bgAEBnN0YXJ0cwAFBHdhbGsAAwkHAQBBAQsBAgrDEAb5BABCACMHfCQvIyBCgICAgAiDUAR+Iy+nQf//"
        + "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"

    public static let freeMemoryModuleBase64 =
        "AGFzbQEAAAABJAdgAAF/YAF+AGADfn5+AGACfn4BfmABfgF/YAF/AX5gAX4BfgKqBT8DZW52A291dAACA2VudgJpbgADA2VudgNtZW0CAIFgA2Vu"
        + "dgJnMAN+AQNlbnYCZzEDfgEDZW52AmcyA34BA2VudgJnMwN+AQNlbnYCZzQDfgEDZW52Amc1A34BA2VudgJnNgN+AQNlbnYCZzcDfgEDZW52Amc4"
        + "A34BA2VudgJnOQN+AQNlbnYDZzEwA34BA2VudgNnMTEDfgEDZW52A2cxMgN+AQNlbnYDZzEzA34BA2VudgNnMTQDfgEDZW52A2cxNQN+AQNlbnYD"
        + "ZzE2A34BA2VudgNnMTcDfgEDZW52A2cxOAN+AQNlbnYDZzE5A34BA2VudgNnMjADfgEDZW52A2cyMQN+AQNlbnYDZzIyA34BA2VudgNnMjMDfgED"
        + "ZW52A2cyNAN+AQNlbnYDZzI1A34BA2VudgNnMjYDfgEDZW52A2cyNwN+AQNlbnYDZzI4A34BA2VudgNnMjkDfgEDZW52A2czMAN+AQNlbnYDZzMx"
        + "A34BA2VudgNnMzIDfgEDZW52A2czMwN+AQNlbnYDZzM0A34BA2VudgNnMzUDfgEDZW52A2czNgN+AQNlbnYDZzM3A34BA2VudgNnMzgDfgEDZW52"
        + "A2czOQN+AQNlbnYDZzQwA34BA2VudgNnNDEDfgEDZW52A2c0MgN+AQNlbnYDZzQzA34BA2VudgNnNDQDfgEDZW52A2c0NQN+AQNlbnYDZzQ2A34B"
        + "A2VudgNnNDcDfgEDZW52A2c0OAN+AQNlbnYDZzQ5A34BA2VudgNnNTADfgEDZW52A2c1MQN+AQNlbnYDZzUyA34BA2VudgNnNTMDfgEDZW52A2c1"
        + "NAN+AQNlbnYDZzU1A34BA2VudgNnNTYDfgEDZW52A2c1NwN+AQNlbnYDZzU4A34BA2VudgNnNTkDfgEDBAMABgUEBAFwAAEHEAIDcnVuAAMGc3Rh"
        + "cnRzAAQJBwEAQQALAQIKnQID6AEAQgAjB3ynKQAAJCcjJ0J/gyQAIwBCf4MkJ0IAIwd8pyMnQn+DNwAAIwZCf4MkJUIBJCYjJSMmfUJ/gyQnIxBC"
        + "qm6DIydQrUIGhoQjJ0KAgICAgICAgIB/g1CtQgGFQgeGhCMnQv8Bg3tCAYNCAYVCAoaEIyUjJoUjJ4VCEINCAIaEIyUjJlStQgCGhCMlIyaFIyUj"
        + "J4WDQoCAgICAgICAgH+DUK1CAYVCC4aEJBAjJ0J/gyQGQoCAgIADQoyAgIADIxBCwACDUK1CAYVCAYWnGyQRQQBBfyMQQsAAg1CtQgGFQgGFpxsL"
        + "KAEBfwJAA0AgAFANASAAQgF9IQAgAREAACEBIAFBAEgNAQwACwsgAAsIAEKAgICAAws="

    /// **La RAM que les modules confinés déclarent**, en pages de 64 Kio :
    /// 16384, soit un gibioctet. Une puissance de deux, parce que le
    /// repliement est un masque ; et pas moins, parce que la région du banc vit
    /// à 0x30000000 et que la RAM doit l'atteindre.
    public static let confinedPages = 16_384

    /// **Ce que l'hôte doit allouer**, et ce n'est pas la ligne du dessus : la
    /// RAM de l'invité, plus la correspondance adresse → indice, plus le tampon
    /// de traduction. Le module **déclare** ce minimum, donc un hôte qui en
    /// fournit moins ne démarre pas — au lieu de piéger plus tard sur une
    /// adresse qu'il croyait sienne, et un piège WebAssembly est sans retour.
    ///
    /// **L'addition ne se refait jamais sur place**, ni ici : le nombre vient
    /// de `host_pages()` dans la bibliothèque, et le test de la sonde le compare
    /// à celui-là. Un pilote qui a refait la somme lui-même a manqué la page du
    /// tampon, ne s'instanciait plus, et sortait avec zéro.
    ///
    /// Ces 16401 pages font **1026 Mio**, contre 768 quand la sonde mesurait la
    /// forme libre. C'est plus à demander à un WKWebView, et c'est précisément
    /// la chose que la sonde doit découvrir plutôt que supposer : c'est
    /// désormais ce que le bureau demandera vraiment.
    public static let hostPages = 16_401
    public static let globalCount = 60
    public static let ripSlot = 17
    public static let benchBase: UInt64 = 0x3000_0000

    /// La boucle de registres exécute cinq instructions par tour, et la sonde
    /// en fait huit millions — quarante millions d'instructions, assez pour que
    /// le palier final de JavaScriptCore soit celui qu'on mesure, assez peu
    /// pour qu'un interpréteur ne fasse pas attendre une minute.
    public static let instructionsPerTurn = 5
    public static let benchTurns = 8_000_000

    /// La boucle mémoire : quatre instructions par tour, dont **deux accès**
    /// — une lecture et une écriture, qui ne prennent pas le même chemin.
    public static let memoryInstructionsPerTurn = 4
    public static let memoryAccessesPerTurn = 2

    /// Ce que la sonde a relevé.
    public struct Reading: Equatable, Sendable {
        public let mips: Double
        public let bridgeMilliseconds: Double
        public let instructions: Double

        /// **Les deux relevés de la boucle mémoire**, confiné puis libre. Ils
        /// ne valent qu'ensemble : leur écart est ce que le confinement coûte
        /// par accès. Séparément ils ne disent rien de plus que `mips`, sur une
        /// boucle moins représentative.
        ///
        /// Zéro veut dire « pas relevé » — une sonde plus vieille, ou un
        /// appareil qui a refusé l'un des modules.
        public let memoryMips: Double
        public let freeMemoryMips: Double
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
            multiMemory: Bool = false, memoryMips: Double = 0, freeMemoryMips: Double = 0
        ) {
            self.mips = mips
            self.bridgeMilliseconds = bridgeMilliseconds
            self.instructions = instructions
            self.multiMemory = multiMemory
            self.memoryMips = memoryMips
            self.freeMemoryMips = freeMemoryMips
        }

        /// **Ce que le confinement coûte par accès mémoire, sur cet appareil.**
        ///
        /// La même boucle sous les deux formes : la différence de temps par
        /// tour, divisée par les deux accès d'un tour. Rien n'est déduit d'une
        /// constante — les deux débits sortent de la machine.
        ///
        /// `nil` quand un des deux relevés manque. **Négatif quand le
        /// confinement est sorti plus vite que la forme libre**, ce qui arrive :
        /// c'est du bruit, et le rendre tel quel vaut mieux que de le border à
        /// zéro, ce qui ferait passer une mesure inexploitable pour un coût nul.
        public var nanosecondsPerAccess: Double? {
            guard memoryMips > 0, freeMemoryMips > 0 else { return nil }
            let perTurn = { (mips: Double) in
                Double(WebKitBench.memoryInstructionsPerTurn) / (mips * 1e6)
            }
            let delta = perTurn(memoryMips) - perTurn(freeMemoryMips)
            return delta / Double(WebKitBench.memoryAccessesPerTurn) * 1e9
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

    /// **Ce que le confinement coûte, dit en nanosecondes et jamais en
    /// pourcentage.**
    ///
    /// Un pourcentage supposerait que le vrai code ait la densité de la boucle
    /// mesurée — deux accès pour quatre instructions — et cette densité n'est
    /// écrite nulle part dans ce dépôt. Une nanoseconde par accès se reporte
    /// sur n'importe quelle densité ; un pourcentage ne se reporte sur rien.
    ///
    /// Un écart négatif se dit tel quel plutôt que borné à zéro : un « coût
    /// nul » affiché serait une conclusion, là où c'est une mesure sous le
    /// bruit.
    public static func accessSentence(_ nanoseconds: Double?) -> String {
        guard let nanoseconds else {
            return "Le coût d'un accès mémoire n'a pas pu être relevé : il faut les deux "
                + "formes de la même boucle, et l'une des deux manque."
        }
        if nanoseconds <= 0 {
            return "Le confinement n'a coûté rien de mesurable par accès mémoire ici — "
                + "l'écart est sous le bruit de la machine, pas nul."
        }
        return "Le confinement coûte environ \(String(format: "%.2f", nanoseconds)) ns par accès "
            + "mémoire sur cet appareil. C'est un ordre de grandeur, pas une précision."
    }

    public static func judge(mips: Double, bridgeMilliseconds: Double,
                             instructions: Double, expected: Double,
                             multiMemory: Bool = false,
                             memoryMips: Double = 0, freeMemoryMips: Double = 0) -> Verdict {
        // **Le compte d'abord.** Une boucle sortie trop tôt rendrait un débit
        // magnifique et faux ; le croire serait pire que ne rien mesurer.
        guard abs(instructions - expected) <= max(expected * 1e-6, 8) else { return .wrongResult }
        let reading = Reading(
            mips: mips, bridgeMilliseconds: bridgeMilliseconds, instructions: instructions,
            multiMemory: multiMemory, memoryMips: memoryMips, freeMemoryMips: freeMemoryMips)
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
                + "\(hostPages) pages de mémoire comprises."
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
            return "\(Int(reading.mips)) MIPS : WebKit compile ici, sur la forme confinée — "
                + "celle que le bureau exécute. Un bureau démarrerait en \(boot), contre plus "
                + "d'une heure avec l'interpréteur. Et \(bridge). "
                + accessSentence(reading.nanosecondsPerAccess)
        }
    }
}

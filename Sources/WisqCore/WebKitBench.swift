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
        "AGFzbQEAAAABQAxgAAF/YAF+AGADfn5+AGACfn4BfmABfgF/YAF/AX5gAX4BfmACfn8BfmADfn5/AGACfn8Bf2ACf38AYAJ+fgACpQhhA2VudgNv"
        + "dXQAAgNlbnYCaW4AAwNlbnYDbWVtAgCygAEDZW52BmJsb2NrcwFwAAEDZW52AmcwA34BA2VudgJnMQN+AQNlbnYCZzIDfgEDZW52AmczA34BA2Vu"
        + "dgJnNAN+AQNlbnYCZzUDfgEDZW52Amc2A34BA2VudgJnNwN+AQNlbnYCZzgDfgEDZW52Amc5A34BA2VudgNnMTADfgEDZW52A2cxMQN+AQNlbnYD"
        + "ZzEyA34BA2VudgNnMTMDfgEDZW52A2cxNAN+AQNlbnYDZzE1A34BA2VudgNnMTYDfgEDZW52A2cxNwN+AQNlbnYDZzE4A34BA2VudgNnMTkDfgED"
        + "ZW52A2cyMAN+AQNlbnYDZzIxA34BA2VudgNnMjIDfgEDZW52A2cyMwN+AQNlbnYDZzI0A34BA2VudgNnMjUDfgEDZW52A2cyNgN+AQNlbnYDZzI3"
        + "A34BA2VudgNnMjgDfgEDZW52A2cyOQN+AQNlbnYDZzMwA34BA2VudgNnMzEDfgEDZW52A2czMgN+AQNlbnYDZzMzA34BA2VudgNnMzQDfgEDZW52"
        + "A2czNQN+AQNlbnYDZzM2A34BA2VudgNnMzcDfgEDZW52A2czOAN+AQNlbnYDZzM5A34BA2VudgNnNDADfgEDZW52A2c0MQN+AQNlbnYDZzQyA34B"
        + "A2VudgNnNDMDfgEDZW52A2c0NAN+AQNlbnYDZzQ1A34BA2VudgNnNDYDfgEDZW52A2c0NwN+AQNlbnYDZzQ4A34BA2VudgNnNDkDfgEDZW52A2c1"
        + "MAN+AQNlbnYDZzUxA34BA2VudgNnNTIDfgEDZW52A2c1MwN+AQNlbnYDZzU0A34BA2VudgNnNTUDfgEDZW52A2c1NgN+AQNlbnYDZzU3A34BA2Vu"
        + "dgNnNTgDfgEDZW52A2c1OQN+AQNlbnYDZzYwA34BA2VudgNnNjEDfgEDZW52A2c2MgN+AQNlbnYDZzYzA34BA2VudgNnNjQDfgEDZW52A2c2NQN+"
        + "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"
        + "NwAABSMvIzBBCBAHCwsL"

    public static let memoryModuleBase64 =
        "AGFzbQEAAAABQAxgAAF/YAF+AGADfn5+AGACfn4BfmABfgF/YAF/AX5gAX4BfmACfn8BfmADfn5/AGACfn8Bf2ACf38AYAJ+fgACpQhhA2VudgNv"
        + "dXQAAgNlbnYCaW4AAwNlbnYDbWVtAgCygAEDZW52BmJsb2NrcwFwAAIDZW52AmcwA34BA2VudgJnMQN+AQNlbnYCZzIDfgEDZW52AmczA34BA2Vu"
        + "dgJnNAN+AQNlbnYCZzUDfgEDZW52Amc2A34BA2VudgJnNwN+AQNlbnYCZzgDfgEDZW52Amc5A34BA2VudgNnMTADfgEDZW52A2cxMQN+AQNlbnYD"
        + "ZzEyA34BA2VudgNnMTMDfgEDZW52A2cxNAN+AQNlbnYDZzE1A34BA2VudgNnMTYDfgEDZW52A2cxNwN+AQNlbnYDZzE4A34BA2VudgNnMTkDfgED"
        + "ZW52A2cyMAN+AQNlbnYDZzIxA34BA2VudgNnMjIDfgEDZW52A2cyMwN+AQNlbnYDZzI0A34BA2VudgNnMjUDfgEDZW52A2cyNgN+AQNlbnYDZzI3"
        + "A34BA2VudgNnMjgDfgEDZW52A2cyOQN+AQNlbnYDZzMwA34BA2VudgNnMzEDfgEDZW52A2czMgN+AQNlbnYDZzMzA34BA2VudgNnMzQDfgEDZW52"
        + "A2czNQN+AQNlbnYDZzM2A34BA2VudgNnMzcDfgEDZW52A2czOAN+AQNlbnYDZzM5A34BA2VudgNnNDADfgEDZW52A2c0MQN+AQNlbnYDZzQyA34B"
        + "A2VudgNnNDMDfgEDZW52A2c0NAN+AQNlbnYDZzQ1A34BA2VudgNnNDYDfgEDZW52A2c0NwN+AQNlbnYDZzQ4A34BA2VudgNnNDkDfgEDZW52A2c1"
        + "MAN+AQNlbnYDZzUxA34BA2VudgNnNTIDfgEDZW52A2c1MwN+AQNlbnYDZzU0A34BA2VudgNnNTUDfgEDZW52A2c1NgN+AQNlbnYDZzU3A34BA2Vu"
        + "dgNnNTgDfgEDZW52A2c1OQN+AQNlbnYDZzYwA34BA2VudgNnNjEDfgEDZW52A2c2MgN+AQNlbnYDZzYzA34BA2VudgNnNjQDfgEDZW52A2c2NQN+"
        + "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"
        + "LyMwQQgQBwsLCw=="

    public static let freeMemoryModuleBase64 =
        "AGFzbQEAAAABJAdgAAF/YAF+AGADfn5+AGACfn4BfmABfgF/YAF/AX5gAX4BfgKVCGADZW52A291dAACA2VudgJpbgADA2VudgNtZW0CAIFgA2Vu"
        + "dgJnMAN+AQNlbnYCZzEDfgEDZW52AmcyA34BA2VudgJnMwN+AQNlbnYCZzQDfgEDZW52Amc1A34BA2VudgJnNgN+AQNlbnYCZzcDfgEDZW52Amc4"
        + "A34BA2VudgJnOQN+AQNlbnYDZzEwA34BA2VudgNnMTEDfgEDZW52A2cxMgN+AQNlbnYDZzEzA34BA2VudgNnMTQDfgEDZW52A2cxNQN+AQNlbnYD"
        + "ZzE2A34BA2VudgNnMTcDfgEDZW52A2cxOAN+AQNlbnYDZzE5A34BA2VudgNnMjADfgEDZW52A2cyMQN+AQNlbnYDZzIyA34BA2VudgNnMjMDfgED"
        + "ZW52A2cyNAN+AQNlbnYDZzI1A34BA2VudgNnMjYDfgEDZW52A2cyNwN+AQNlbnYDZzI4A34BA2VudgNnMjkDfgEDZW52A2czMAN+AQNlbnYDZzMx"
        + "A34BA2VudgNnMzIDfgEDZW52A2czMwN+AQNlbnYDZzM0A34BA2VudgNnMzUDfgEDZW52A2czNgN+AQNlbnYDZzM3A34BA2VudgNnMzgDfgEDZW52"
        + "A2czOQN+AQNlbnYDZzQwA34BA2VudgNnNDEDfgEDZW52A2c0MgN+AQNlbnYDZzQzA34BA2VudgNnNDQDfgEDZW52A2c0NQN+AQNlbnYDZzQ2A34B"
        + "A2VudgNnNDcDfgEDZW52A2c0OAN+AQNlbnYDZzQ5A34BA2VudgNnNTADfgEDZW52A2c1MQN+AQNlbnYDZzUyA34BA2VudgNnNTMDfgEDZW52A2c1"
        + "NAN+AQNlbnYDZzU1A34BA2VudgNnNTYDfgEDZW52A2c1NwN+AQNlbnYDZzU4A34BA2VudgNnNTkDfgEDZW52A2c2MAN+AQNlbnYDZzYxA34BA2Vu"
        + "dgNnNjIDfgEDZW52A2c2MwN+AQNlbnYDZzY0A34BA2VudgNnNjUDfgEDZW52A2c2NgN+AQNlbnYDZzY3A34BA2VudgNnNjgDfgEDZW52A2c2OQN+"
        + "AQNlbnYDZzcwA34BA2VudgNnNzEDfgEDZW52A2c3MgN+AQNlbnYDZzczA34BA2VudgNnNzQDfgEDZW52A2c3NQN+AQNlbnYDZzc2A34BA2VudgNn"
        + "NzcDfgEDZW52A2c3OAN+AQNlbnYDZzc5A34BA2VudgNnODADfgEDZW52A2c4MQN+AQNlbnYDZzgyA34BA2VudgNnODMDfgEDZW52A2c4NAN+AQNl"
        + "bnYDZzg1A34BA2VudgNnODYDfgEDZW52A2c4NwN+AQNlbnYDZzg4A34BA2VudgNnODkDfgEDZW52A2c5MAN+AQNlbnYDZzkxA34BA2VudgNnOTID"
        + "fgEDBAMABgUEBAFwAAEHEAIDcnVuAAMGc3RhcnRzAAQJBwEAQQALAQIKnQID6AEAQgAjB3ynKQAAJCcjJ0J/gyQAIwBCf4MkJ0IAIwd8pyMnQn+D"
        + "NwAAIwZCf4MkJUIBJCYjJSMmfUJ/gyQnIxBCqm6DIydQrUIGhoQjJ0KAgICAgICAgIB/g1CtQgGFQgeGhCMnQv8Bg3tCAYNCAYVCAoaEIyUjJoUj"
        + "J4VCEINCAIaEIyUjJlStQgCGhCMlIyaFIyUjJ4WDQoCAgICAgICAgH+DUK1CAYVCC4aEJBAjJ0J/gyQGQoCAgIADQoyAgIADIxBCwACDUK1CAYVC"
        + "AYWnGyQRQQBBfyMQQsAAg1CtQgGFQgGFpxsLKAEBfwJAA0AgAFANASAAQgF9IQAgAREAACEBIAFBAEgNAQwACwsgAAsIAEKAgICAAws="

    /// **La RAM que les modules confinés déclarent**, en pages de 64 Kio :
    /// 16384, soit un gibioctet. Une puissance de deux, parce que le
    /// repliement est un masque ; et pas moins, parce que la région du banc vit
    /// à 0x30000000 et que la RAM doit l'atteindre.
    public static let confinedPages = 16_384

    /// **Ce que l'hôte doit allouer**, et ce n'est pas la ligne du dessus : la
    /// RAM de l'invité, plus la correspondance adresse → indice, plus le tampon
    /// de traduction, plus la carte du code traduit et son journal. Le module
    /// **déclare** ce minimum, donc un hôte qui en
    /// fournit moins ne démarre pas — au lieu de piéger plus tard sur une
    /// adresse qu'il croyait sienne, et un piège WebAssembly est sans retour.
    ///
    /// **L'addition ne se refait jamais sur place**, ni ici : le nombre vient
    /// de `host_pages()` dans la bibliothèque, et le test de la sonde le compare
    /// à celui-là. Un pilote qui a refait la somme lui-même a manqué la page du
    /// tampon, ne s'instanciait plus, et sortait avec zéro.
    ///
    /// Ces 16434 pages font **1027 Mio**, contre 768 quand la sonde mesurait la
    /// forme libre. C'est plus à demander à un WKWebView, et c'est précisément
    /// la chose que la sonde doit découvrir plutôt que supposer : c'est
    /// désormais ce que le bureau demandera vraiment.
    public static let hostPages = 16_434
    public static let globalCount = 93
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

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
        "AGFzbQEAAAABGgVgAAF/YAF+AGADfn5+AGACfn4BfmABfgF/Au0EOQNlbnYDb3V0AAIDZW52AmluAAMDZW52A21lbQIAkYABA2VudgZibG9ja3MB"
        + "cAABA2VudgJnMAN+AQNlbnYCZzEDfgEDZW52AmcyA34BA2VudgJnMwN+AQNlbnYCZzQDfgEDZW52Amc1A34BA2VudgJnNgN+AQNlbnYCZzcDfgED"
        + "ZW52Amc4A34BA2VudgJnOQN+AQNlbnYDZzEwA34BA2VudgNnMTEDfgEDZW52A2cxMgN+AQNlbnYDZzEzA34BA2VudgNnMTQDfgEDZW52A2cxNQN+"
        + "AQNlbnYDZzE2A34BA2VudgNnMTcDfgEDZW52A2cxOAN+AQNlbnYDZzE5A34BA2VudgNnMjADfgEDZW52A2cyMQN+AQNlbnYDZzIyA34BA2VudgNn"
        + "MjMDfgEDZW52A2cyNAN+AQNlbnYDZzI1A34BA2VudgNnMjYDfgEDZW52A2cyNwN+AQNlbnYDZzI4A34BA2VudgNnMjkDfgEDZW52A2czMAN+AQNl"
        + "bnYDZzMxA34BA2VudgNnMzIDfgEDZW52A2czMwN+AQNlbnYDZzM0A34BA2VudgNnMzUDfgEDZW52A2czNgN+AQNlbnYDZzM3A34BA2VudgNnMzgD"
        + "fgEDZW52A2czOQN+AQNlbnYDZzQwA34BA2VudgNnNDEDfgEDZW52A2c0MgN+AQNlbnYDZzQzA34BA2VudgNnNDQDfgEDZW52A2c0NQN+AQNlbnYD"
        + "ZzQ2A34BA2VudgNnNDcDfgEDZW52A2c0OAN+AQNlbnYDZzQ5A34BA2VudgNnNTADfgEDZW52A2c1MQN+AQNlbnYDZzUyA34BAwQDAAQBBw4CA3J1"
        + "bgAEBHdhbGsAAwkHAQBBAAsBAgqGCgOJBQAjAkJ/gyQlIwBCf4MkJiMlIyZ8Qn+DJCcjEEKqboMjJ1CtQgaGhCMnQoCAgICAgICAgH+DUK1CAYVC"
        + "B4aEIydC/wGDe0IBg0IBhUIChoQjJSMmhSMnhUIQg0IAhoQjJyMlVK1CAIaEIyUjJ4UjJiMnhYNCgICAgICAgICAf4NQrUIBhUILhoQkECMnQn+D"
        + "JAIjA0J/gyQlIwFCf4MkJiMlIyaFQn+DJCcjEEKqboMjJ1CtQgaGhCMnQoCAgICAgICAgH+DUK1CAYVCB4aEIydC/wGDe0IBg0IBhUIChoQjJSMm"
        + "hSMnhUIQg0IAhoQkECMnQn+DJAMjAEJ/gyQlIwJCf4MkJiMlIyZ8Qn+DJCcjEEKqboMjJ1CtQgaGhCMnQoCAgICAgICAgH+DUK1CAYVCB4aEIydC"
        + "/wGDe0IBg0IBhUIChoQjJSMmhSMnhUIQg0IAhoQjJyMlVK1CAIaEIyUjJ4UjJiMnhYNCgICAgICAgICAf4NQrUIBhUILhoQkECMnQn+DJAAjBkJ/"
        + "gyQlQgEkJiMlIyZ9Qn+DJCcjEEKqboMjJ1CtQgaGhCMnQoCAgICAgICAgH+DUK1CAYVCB4aEIydC/wGDe0IBg0IBhUIChoQjJSMmhSMnhUIQg0IA"
        + "hoQjJSMmVK1CAIaEIyUjJoUjJSMnhYNCgICAgICAgICAf4NQrUIBhUILhoQkECMnQn+DJAZCgICAgANCj4CAgAMjEELAAINQrUIBhUIBhacbJBFB"
        + "ACMRQpX4qfqXt96bnn9+QjCIp0EQbEGAgICABGooAghBfyMRQpX4qfqXt96bnn9+QjCIp0EQbEGAgICABGopAwAjEVEbIxBCwACDUK1CAYVCAYWn"
        + "GwvNBAQBfgF/AX4BfyMiQoDg//////8Hg6dB/////wNxIQIgAiAAQieIQv8Dg6dBCGxqKQAAIgFCAYNQBEBCASQyIAAkIUEADwsgAUKAAYNQRQRA"
        + "IAFCgICAgIDw/weDIABCgOD///8Pg4SnQf////8Dca0hAyAAQgyIQv8fg6dBEGxBgIDAgARqIgQgAEIMiEIBfDcAACAEIAM+AAggA6cPCyABQoDg"
        + "//////8Hg6dB/////wNxIQIgAiAAQh6IQv8Dg6dBCGxqKQAAIgFCAYNQBEBCASQyIAAkIUEADwsgAUKAAYNQRQRAIAFCgICAgPz//weDIABCgOD/"
        + "/wODhKdB/////wNxrSEDIABCDIhC/x+Dp0EQbEGAgMCABGoiBCAAQgyIQgF8NwAAIAQgAz4ACCADpw8LIAFCgOD//////weDp0H/////A3EhAiAC"
        + "IABCFYhC/wODp0EIbGopAAAiAUIBg1AEQEIBJDIgACQhQQAPCyABQoABg1BFBEAgAUKAgID/////B4MgAEKA4P8Ag4SnQf////8Dca0hAyAAQgyI"
        + "Qv8fg6dBEGxBgIDAgARqIgQgAEIMiEIBfDcAACAEIAM+AAggA6cPCyABQoDg//////8Hg6dB/////wNxIQIgAiAAQgyIQv8Dg6dBCGxqKQAAIgFC"
        + "AYNQBEBCASQyIAAkIUEADwsgAUKA4P//////B4OnQf////8DcSECIAKtIQMgAEIMiEL/H4OnQRBsQYCAwIAEaiIEIABCDIhCAXw3AAAgBCADPgAI"
        + "IAOnDwsqAQF/QQAhAQJAA0AgAFANASAAQgF9IQAgAREAACEBIAFBAEgNAQwACwsL"

    public static let memoryModuleBase64 =
        "AGFzbQEAAAABGgVgAAF/YAF+AGADfn5+AGACfn4BfmABfgF/Au0EOQNlbnYDb3V0AAIDZW52AmluAAMDZW52A21lbQIAkYABA2VudgZibG9ja3MB"
        + "cAACA2VudgJnMAN+AQNlbnYCZzEDfgEDZW52AmcyA34BA2VudgJnMwN+AQNlbnYCZzQDfgEDZW52Amc1A34BA2VudgJnNgN+AQNlbnYCZzcDfgED"
        + "ZW52Amc4A34BA2VudgJnOQN+AQNlbnYDZzEwA34BA2VudgNnMTEDfgEDZW52A2cxMgN+AQNlbnYDZzEzA34BA2VudgNnMTQDfgEDZW52A2cxNQN+"
        + "AQNlbnYDZzE2A34BA2VudgNnMTcDfgEDZW52A2cxOAN+AQNlbnYDZzE5A34BA2VudgNnMjADfgEDZW52A2cyMQN+AQNlbnYDZzIyA34BA2VudgNn"
        + "MjMDfgEDZW52A2cyNAN+AQNlbnYDZzI1A34BA2VudgNnMjYDfgEDZW52A2cyNwN+AQNlbnYDZzI4A34BA2VudgNnMjkDfgEDZW52A2czMAN+AQNl"
        + "bnYDZzMxA34BA2VudgNnMzIDfgEDZW52A2czMwN+AQNlbnYDZzM0A34BA2VudgNnMzUDfgEDZW52A2czNgN+AQNlbnYDZzM3A34BA2VudgNnMzgD"
        + "fgEDZW52A2czOQN+AQNlbnYDZzQwA34BA2VudgNnNDEDfgEDZW52A2c0MgN+AQNlbnYDZzQzA34BA2VudgNnNDQDfgEDZW52A2c0NQN+AQNlbnYD"
        + "ZzQ2A34BA2VudgNnNDcDfgEDZW52A2c0OAN+AQNlbnYDZzQ5A34BA2VudgNnNTADfgEDZW52A2c1MQN+AQNlbnYDZzUyA34BAwQDAAQBBw4CA3J1"
        + "bgAEBHdhbGsAAwkHAQBBAQsBAgr1CAP4AwBCgICAgAMkEUIAIwd8JC8jIEKAgICACINQBH8jL6dB/////wNxBSMvQgyIJDAjMEL/H4NCEH5CgIDA"
        + "gAR8JDEjMacpAAAjMEIBfFEEfyMxpzUACKcFIy8QAwsjL6dB/x9xcgsjMlBFBEBBfw8LKQAAJCcjJ0J/gyQAQoOAgIADJBEjAEJ/gyQnQgAjB3wk"
        + "LyMgQoCAgIAIg1AEfyMvp0H/////A3EFIy9CDIgkMCMwQv8fg0IQfkKAgMCABHwkMSMxpykAACMwQgF8UQR/IzGnNQAIpwUjLxADCyMvp0H/H3Fy"
        + "CyMyUEUEQEF/DwsjJ0J/gzcAACMGQn+DJCVCASQmIyUjJn1Cf4MkJyMQQqpugyMnUK1CBoaEIydCgICAgICAgICAf4NQrUIBhUIHhoQjJ0L/AYN7"
        + "QgGDQgGFQgKGhCMlIyaFIyeFQhCDQgCGhCMlIyZUrUIAhoQjJSMmhSMlIyeFg0KAgICAgICAgIB/g1CtQgGFQguGhCQQIydCf4MkBkKAgICAA0KM"
        + "gICAAyMQQsAAg1CtQgGFQgGFpxskEUEBIxFClfip+pe33puef35CMIinQRBsQYCAgIAEaigCCEF/IxFClfip+pe33puef35CMIinQRBsQYCAgIAE"
        + "aikDACMRURsjEELAAINQrUIBhUIBhacbC80EBAF+AX8BfgF/IyJCgOD//////weDp0H/////A3EhAiACIABCJ4hC/wODp0EIbGopAAAiAUIBg1AE"
        + "QEIBJDIgACQhQQAPCyABQoABg1BFBEAgAUKAgICAgPD/B4MgAEKA4P///w+DhKdB/////wNxrSEDIABCDIhC/x+Dp0EQbEGAgMCABGoiBCAAQgyI"
        + "QgF8NwAAIAQgAz4ACCADpw8LIAFCgOD//////weDp0H/////A3EhAiACIABCHohC/wODp0EIbGopAAAiAUIBg1AEQEIBJDIgACQhQQAPCyABQoAB"
        + "g1BFBEAgAUKAgICA/P//B4MgAEKA4P//A4OEp0H/////A3GtIQMgAEIMiEL/H4OnQRBsQYCAwIAEaiIEIABCDIhCAXw3AAAgBCADPgAIIAOnDwsg"
        + "AUKA4P//////B4OnQf////8DcSECIAIgAEIViEL/A4OnQQhsaikAACIBQgGDUARAQgEkMiAAJCFBAA8LIAFCgAGDUEUEQCABQoCAgP////8HgyAA"
        + "QoDg/wCDhKdB/////wNxrSEDIABCDIhC/x+Dp0EQbEGAgMCABGoiBCAAQgyIQgF8NwAAIAQgAz4ACCADpw8LIAFCgOD//////weDp0H/////A3Eh"
        + "AiACIABCDIhC/wODp0EIbGopAAAiAUIBg1AEQEIBJDIgACQhQQAPCyABQoDg//////8Hg6dB/////wNxIQIgAq0hAyAAQgyIQv8fg6dBEGxBgIDA"
        + "gARqIgQgAEIMiEIBfDcAACAEIAM+AAggA6cPCyoBAX9BASEBAkADQCAAUA0BIABCAX0hACABEQAAIQEgAUEASA0BDAALCws="

    public static let freeMemoryModuleBase64 =
        "AGFzbQEAAAABGgVgAAF/YAF+AGADfn5+AGACfn4BfmABfgF/At0EOANlbnYDb3V0AAIDZW52AmluAAMDZW52A21lbQIAgWADZW52AmcwA34BA2Vu"
        + "dgJnMQN+AQNlbnYCZzIDfgEDZW52AmczA34BA2VudgJnNAN+AQNlbnYCZzUDfgEDZW52Amc2A34BA2VudgJnNwN+AQNlbnYCZzgDfgEDZW52Amc5"
        + "A34BA2VudgNnMTADfgEDZW52A2cxMQN+AQNlbnYDZzEyA34BA2VudgNnMTMDfgEDZW52A2cxNAN+AQNlbnYDZzE1A34BA2VudgNnMTYDfgEDZW52"
        + "A2cxNwN+AQNlbnYDZzE4A34BA2VudgNnMTkDfgEDZW52A2cyMAN+AQNlbnYDZzIxA34BA2VudgNnMjIDfgEDZW52A2cyMwN+AQNlbnYDZzI0A34B"
        + "A2VudgNnMjUDfgEDZW52A2cyNgN+AQNlbnYDZzI3A34BA2VudgNnMjgDfgEDZW52A2cyOQN+AQNlbnYDZzMwA34BA2VudgNnMzEDfgEDZW52A2cz"
        + "MgN+AQNlbnYDZzMzA34BA2VudgNnMzQDfgEDZW52A2czNQN+AQNlbnYDZzM2A34BA2VudgNnMzcDfgEDZW52A2czOAN+AQNlbnYDZzM5A34BA2Vu"
        + "dgNnNDADfgEDZW52A2c0MQN+AQNlbnYDZzQyA34BA2VudgNnNDMDfgEDZW52A2c0NAN+AQNlbnYDZzQ1A34BA2VudgNnNDYDfgEDZW52A2c0NwN+"
        + "AQNlbnYDZzQ4A34BA2VudgNnNDkDfgEDZW52A2c1MAN+AQNlbnYDZzUxA34BA2VudgNnNTIDfgEDAwIAAQQEAXAAAQcHAQNydW4AAwkHAQBBAAsB"
        + "AgqSAgLoAQBCACMHfKcpAAAkJyMnQn+DJAAjAEJ/gyQnQgAjB3ynIydCf4M3AAAjBkJ/gyQlQgEkJiMlIyZ9Qn+DJCcjEEKqboMjJ1CtQgaGhCMn"
        + "QoCAgICAgICAgH+DUK1CAYVCB4aEIydC/wGDe0IBg0IBhUIChoQjJSMmhSMnhUIQg0IAhoQjJSMmVK1CAIaEIyUjJoUjJSMnhYNCgICAgICAgICA"
        + "f4NQrUIBhUILhoQkECMnQn+DJAZCgICAgANCjICAgAMjEELAAINQrUIBhUIBhacbJBFBAEF/IxBCwACDUK1CAYVCAYWnGwsmAQF/AkADQCAAUA0B"
        + "IABCAX0hACABEQAAIQEgAUEASA0BDAALCws="

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
    public static let globalCount = 53
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

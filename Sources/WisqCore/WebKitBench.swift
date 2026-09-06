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
    /// Le module engendré par `scripts/wasm-jit-probe.ts`, **le même octet pour
    /// octet** que celui de la sonde de test. Deux copies divergeraient, et
    /// l'application mesurerait alors autre chose que la CI — deux chiffres
    /// qu'on croirait comparables.
    public static let moduleBase64 =
        "AGFzbQEAAAABCgJgAX4BfmAAAX8DBAMBAQAEBAFwAAIFAwEAAgcPAgVkcml2ZQACA21lbQIA" +
        "CQgBAEEACwIAAQrxAwPCAwEGfkIApykDACEAQginKQMAIQFCEKcpAwAhAkIYpykDACEDIAAg" +
        "AXwhBEKAAacgBFCtNwMAQpgBpyAEQj+INwMAQogBpyAEIABUrTcDAEKQAacgACAEhSABIASF" +
        "g0I/iDcDACAEIQAgA0L//wODQoAgfKcpAwAhBSAAIAWFIQRCgAGnIARQrTcDAEKYAacgBEI/" +
        "iDcDAEKIAadCADcDAEKQAadCADcDACAEIQAgA0L//wODQoggfKcgADcDACAAIAJ9IQRCgAGn" +
        "IARQrTcDAEKYAacgBEI/iDcDAEKIAacgBCAAVK03AwBCkAGnIAAgBIUgAiAEhYNCP4g3AwBC" +
        "gAGnKQMAUEUEQCACQgF8IQRCgAGnIARQrTcDAEKYAacgBEI/iDcDAEKIAacgBCACVK03AwBC" +
        "kAGnIAIgBIUgAiAEhYNCP4g3AwAgBCECCyABQgF9IQRCgAGnIARQrTcDAEKYAacgBEI/iDcD" +
        "AEKIAacgBCABVK03AwBCkAGnIAEgBIUgASAEhYNCP4g3AwAgBCEBQgCnIAA3AwBCCKcgATcD" +
        "AEIQpyACNwMAQhinIAM3AwBCgAGnKQMAUAR/QQAFQQELCwQAQQELJgEBf0EAIQEDQCABEQEA" +
        "IQEgAEIIfSEAIAFFIABCAFZxDQALIAAL"

    /// Ce que la sonde a relevé.
    public struct Reading: Equatable, Sendable {
        public let mips: Double
        public let bridgeMilliseconds: Double
        public let instructions: Double

        public init(mips: Double, bridgeMilliseconds: Double, instructions: Double) {
            self.mips = mips
            self.bridgeMilliseconds = bridgeMilliseconds
            self.instructions = instructions
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

    public static func judge(mips: Double, bridgeMilliseconds: Double,
                             instructions: Double, expected: Double) -> Verdict {
        // **Le compte d'abord.** Une boucle sortie trop tôt rendrait un débit
        // magnifique et faux ; le croire serait pire que ne rien mesurer.
        guard abs(instructions - expected) <= max(expected * 1e-6, 8) else { return .wrongResult }
        let reading = Reading(
            mips: mips, bridgeMilliseconds: bridgeMilliseconds, instructions: instructions)
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

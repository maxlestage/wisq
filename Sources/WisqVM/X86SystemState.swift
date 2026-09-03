import Foundation

/// Ce qu'un processeur x86-64 porte en dehors de ses seize registres : les
/// registres de contrôle, les MSR, et la traduction d'adresses.
///
/// C'est ce que le décompresseur d'un noyau Linux touche **avant** tout le
/// reste : il demande ce que la machine sait faire (`CPUID`), il lit et écrit
/// `EFER` pour entrer en mode long, il pose `CR3` sur ses tables de pages et
/// allume la pagination dans `CR0`. Sans ça, il n'y a pas de démarrage à
/// tenter.
public struct X86SystemState: Equatable, Sendable {
    /// CR0, CR2, CR3, CR4 et CR8, indexés par leur numéro. CR1, CR5 à CR7 et
    /// CR9 à CR15 n'existent pas.
    public var control = [UInt64](repeating: 0, count: 16)
    /// Les registres de modèle. Peu nombreux en pratique, donc un dictionnaire :
    /// il n'est lu que par `RDMSR` et `WRMSR`, jamais sur le chemin chaud.
    public var modelSpecific: [UInt32: UInt64] = [:]

    public init() {}

    // Les bits qui décident de la traduction d'adresses.
    public static let paging: UInt64 = 1 << 31       // CR0.PG
    public static let protectedMode: UInt64 = 1 << 0  // CR0.PE
    public static let physicalAddressExtension: UInt64 = 1 << 5  // CR4.PAE
    /// EFER, et les deux bits qui y comptent : LME (mode long demandé) et LMA
    /// (mode long actif).
    public static let efer: UInt32 = 0xC000_0080
    public static let longModeEnable: UInt64 = 1 << 8
    public static let longModeActive: UInt64 = 1 << 10

    public var pagingOn: Bool { control[0] & Self.paging != 0 }
    public var longMode: Bool {
        (modelSpecific[Self.efer] ?? 0) & Self.longModeActive != 0
    }

    /// Écrire `EFER` ne suffit pas à entrer en mode long : le processeur pose
    /// **lui-même** LMA quand la pagination s'allume alors que LME est
    /// demandé. Un noyau lit LMA pour savoir où il en est ; le laisser à zéro
    /// le ferait tourner en rond.
    public mutating func refreshLongMode() {
        var value = modelSpecific[Self.efer] ?? 0
        let active = value & Self.longModeEnable != 0 && pagingOn
        value = active ? (value | Self.longModeActive) : (value & ~Self.longModeActive)
        modelSpecific[Self.efer] = value
    }
}

/// Ce que ce processeur virtuel répond quand on lui demande ce qu'il sait
/// faire.
///
/// **Ce n'est pas mesuré, c'est décidé.** L'oracle matériel dirait ce que
/// *cette* machine-ci répond, or un invité ne doit surtout pas croire qu'il
/// tourne sur le processeur de l'hôte : il utiliserait des instructions que ce
/// cœur n'exécute pas. Chaque bit annoncé ici est donc une promesse que le
/// reste du cœur doit tenir, et les tests la relisent dans ce sens.
public enum X86CPUID {
    /// Le nom du constructeur : **exactement douze octets**, comme le veut la
    /// convention, répartis dans EBX, EDX puis ECX — dans cet ordre-là, qui
    /// n'est pas celui qu'on devinerait. C'est ce que l'invité affichera dans
    /// `/proc/cpuinfo`.
    public static let vendor = "wisq  x86-64"

    /// La plus grande feuille ordinaire que ce processeur connaît.
    public static let highestBasicLeaf: UInt32 = 1
    /// La plus grande feuille étendue.
    public static let highestExtendedLeaf: UInt32 = 0x8000_0001

    /// Ce que le noyau doit voir dans EDX pour la feuille 1. Chacun de ces
    /// bits est tenu par le reste du cœur :
    /// - FPU (0) : les trois instructions par lesquelles Linux détecte le
    ///   coprocesseur répondent juste (voir `minimalX87`), et le mode 64 bits
    ///   exige un FPU — un noyau qui n'en trouve pas s'arrête. Aucune
    ///   arithmétique x87 n'existe pour autant, et elle est refusée par son nom
    ///   si elle arrive.
    /// - TSC (4) : `RDTSC` répond.
    /// - MSR (5) : `RDMSR`/`WRMSR` répondent.
    /// - PAE (6) : la traduction d'adresses est à quatre niveaux.
    /// - CMOV (15) : les seize `CMOVcc` sont là depuis la tranche 3a.
    /// - PGE (13) et PSE (3) : les pages larges sont traduites.
    public static let features: UInt32 = 1 | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 3)
        | (1 << 13) | (1 << 15)
    /// Feuille 0x80000001, EDX : LM (29) dit que le mode long existe. Sans ce
    /// bit, un noyau 64 bits refuse de démarrer et le dit.
    public static let extendedFeatures: UInt32 = 1 << 29

    /// La réponse aux quatre registres, pour une feuille donnée.
    public static func answer(leaf: UInt32, subleaf: UInt32) -> (UInt32, UInt32, UInt32, UInt32) {
        let name = Array(vendor.utf8)
        func word(_ start: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(name[start + $1]) << (8 * UInt32($1)) }
        }
        switch leaf {
        case 0:
            return (highestBasicLeaf, word(0), word(8), word(4))
        case 1:
            // La famille et le modèle : un « 6/15 », ce qu'un noyau accepte
            // sans chercher d'errata particulier.
            return (0x0000_06F0, 0, 0, features)
        case 0x8000_0000:
            return (highestExtendedLeaf, 0, 0, 0)
        case 0x8000_0001:
            return (0, 0, 0, extendedFeatures)
        default:
            // Une feuille inconnue rend des zéros, ce que le manuel demande —
            // et non les registres inchangés, qui feraient lire n'importe quoi.
            return (0, 0, 0, 0)
        }
    }
}

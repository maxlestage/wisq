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
    /// Les huit registres de débogage. Notés et rendus, jamais consultés : ce
    /// cœur ne pose pas de point d'arrêt matériel. Un noyau les remet à zéro
    /// dès son démarrage — refuser l'instruction l'arrêterait là, pour un
    /// registre dont il n'attend rien d'autre que d'être écrit.
    public var debug = [UInt64](repeating: 0, count: 8)
    /// Les registres de modèle. Peu nombreux en pratique, donc un dictionnaire :
    /// il n'est lu que par `RDMSR` et `WRMSR`, jamais sur le chemin chaud.
    public var modelSpecific = X86ModelSpecific()

    public init() {}

    // Les bits qui décident de la traduction d'adresses.
    public static let paging: UInt64 = 1 << 31       // CR0.PG
    public static let protectedMode: UInt64 = 1 << 0  // CR0.PE
    public static let physicalAddressExtension: UInt64 = 1 << 5  // CR4.PAE
    /// CR4.PGE : les pages globales. C'est le bit qu'un noyau Linux éteint et
    /// rallume pour vider tout le cache de traductions d'un coup.
    public static let pageGlobalEnable: UInt64 = 1 << 7
    /// EFER, et les deux bits qui y comptent : LME (mode long demandé) et LMA
    /// (mode long actif).
    public static let efer: UInt32 = 0xC000_0080
    /// Les bases de FS et GS. En mode long ce sont les deux seuls segments qui
    /// en aient encore une, et elle vit dans un MSR plutôt que dans un
    /// descripteur.
    public static let fsBase: UInt32 = 0xC000_0100
    public static let gsBase: UInt32 = 0xC000_0101
    /// Celle que `SWAPGS` met de côté : le noyau y garde la sienne pendant que
    /// l'espace utilisateur tourne, et les échange à chaque passage.
    public static let kernelGSBase: UInt32 = 0xC000_0102
    public static let longModeEnable: UInt64 = 1 << 8
    public static let longModeActive: UInt64 = 1 << 10
    /// **SCE**, le bit qui autorise `SYSCALL`. Un noyau le pose au démarrage ;
    /// sans lui, le processeur refuse l'instruction — et ce refus-là est une
    /// vraie règle, pas une limite de ce cœur : un programme qui appelle sans
    /// que le noyau ait ouvert la porte doit être arrêté, pas servi.
    public static let systemCallEnable: UInt64 = 1 << 0

    /// Les quatre MSR de l'appel système rapide.
    ///
    /// `STAR` porte deux sélecteurs de segment de code dans ses trente-deux
    /// bits hauts : celui de l'entrée en 47:32, celui du retour en 63:48. Les
    /// segments de pile, eux, ne sont pas écrits : le processeur les déduit en
    /// ajoutant huit. C'est ce qui oblige un noyau à ranger ses descripteurs
    /// dans un ordre précis, et ce qui rend une inversion invisible jusqu'au
    /// premier retour en anneau trois.
    public static let star: UInt32 = 0xC000_0081
    /// Où `SYSCALL` saute, en mode long.
    public static let longSystemCallTarget: UInt32 = 0xC000_0082
    /// Où il sauterait depuis le mode compatibilité. Ce cœur ne le fait pas
    /// tourner ; la constante existe pour que le MSR soit **nommé** quand un
    /// noyau l'écrit, plutôt que rangé sous un numéro nu.
    public static let compatibilitySystemCallTarget: UInt32 = 0xC000_0083
    /// Les drapeaux que `SYSCALL` efface en entrant. Linux y met au moins le
    /// bit d'interruption et celui de direction : entrer dans le noyau avec
    /// les interruptions ouvertes, ou avec une direction de chaîne héritée
    /// d'un programme, serait lui faire exécuter son propre code de travers.
    public static let systemCallFlagMask: UInt32 = 0xC000_0084

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
    /// n'est pas celui qu'on devinerait.
    ///
    /// **Il a fallu un nom que la glibc connaît.** Le cœur s'annonçait
    /// « wisq  x86-64 », et la glibc, pour un constructeur qu'elle ne
    /// reconnaît pas, ne lit **jamais** la feuille 1 (`get_common_indices`
    /// est appelé sans famille) : tous les bits du socle x86-64 lui
    /// paraissaient absents, quoi qu'on y mette, et chaque programme de
    /// l'initramfs de Debian s'arrêtait sur « CPU ISA level is lower than
    /// required ». On reprend donc l'identité du processeur `qemu64` de
    /// QEMU : `AuthenticAMD`, famille 15, modèle 107. Linux et la glibc la
    /// voient depuis quinze ans sur des machines virtuelles sans JIT, et un
    /// MSR propre au constructeur qu'ils liraient se lit ici comme zéro, sans
    /// faute. Le nom de wisq reste là où on le lit : `model name`, dans
    /// `/proc/cpuinfo`, vient de la chaîne de marque (`brand`).
    public static let vendor = "AuthenticAMD"

    /// La chaîne de marque, feuilles 0x80000002 à 0x80000004 : quarante-huit
    /// octets, complétés de zéros.
    public static let brand = "wisq x86-64 (comme le qemu64 de QEMU)"

    /// La plus grande feuille ordinaire que ce processeur connaît : 0xD,
    /// celle de l'état étendu (`XSAVE`). La feuille 7 annonce BMI1 et BMI2 ;
    /// les autres, de 2 à 0xC, rendent des zéros, comme toute feuille que ce
    /// cœur ne décrit pas.
    public static let highestBasicLeaf: UInt32 = 0xD
    /// La plus grande feuille étendue.
    public static let highestExtendedLeaf: UInt32 = 0x8000_0004

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
    /// - CX8 (8) : `CMPXCHG8B`.
    /// - FXSR (24) : `FXSAVE` et `FXRSTOR`, tenus par leur oracle.
    /// - SSE (25) et SSE2 (26) : les déplacements, la logique, l'arithmétique
    ///   entière et les scalaires flottants. Ce qui reste refusé (les paquets
    ///   de flottants, `CMPSD`) l'est par son nom.
    /// - MMX (23), **au sens où FPU l'est** : aucune instruction MMX n'existe
    ///   ici, et chacune est refusée par son nom si elle arrive.
    ///
    /// **Pourquoi les cinq derniers.** La glibc refuse de charger un programme
    /// sur un processeur qui n'a pas le socle x86-64 : CMOV, CX8, FPU, FXSR,
    /// MMX, SSE et SSE2, lus ici. L'image de cloud de Debian 13 s'arrêtait sur
    /// « libc.so.6: CPU ISA level is lower than required » à chaque programme
    /// de son initramfs, et udev, qui ne démarrait pas, ne créait jamais le
    /// lien de sa racine. Aucun binaire de cet initramfs n'emploie un
    /// registre MMX : le bit est ce que la glibc lit, pas ce qu'elle exécute.
    public static let features: UInt32 = 1 | (1 << 4) | (1 << 5) | (1 << 6) | (1 << 3)
        | (1 << 13) | (1 << 15) | (1 << 8) | (1 << 23) | (1 << 24) | (1 << 25) | (1 << 26)
    /// **Ce que la feuille 1 annonce dans ECX : x86-64-v2.** Vide jusqu'ici,
    /// et AlmaLinux 9, Rocky 9 et CentOS Stream 9 ne démarraient pas : leur
    /// glibc est compilée pour ce niveau et refuse un processeur qui ne
    /// l'annonce pas. Chaque bit est tenu par une tranche et son corpus
    /// (`Tests/Fixtures/x86-v2-oracle.tsv`) :
    /// - SSE3 (0) : `lddqu`, `movddup`, `movsldup`, `addsubpd`, `fisttp` ;
    /// - SSSE3 (9) : `pshufb`, `palignr`, `pabs*`, `pmaddubsw`, `phaddsw` ;
    /// - CX16 (13) : `cmpxchg16b` ;
    /// - SSE4.1 (19) : insertions, extractions, élargissements, mélanges,
    ///   minimums et maximums, `ptest`, l'arrondi ;
    /// - SSE4.2 (20) : `pcmpistri`, `pcmpgtq` ;
    /// - POPCNT (23) : `popcnt`, là depuis longtemps.
    ///
    /// **Ce qui manque de ces extensions, et que ni AlmaLinux ni les autres
    /// n'emploient** — `haddp*`, `hsubp*`, `movshdup`, `pcmpestri`, `crc32`,
    /// les formes `…m` — est refusé par son nom s'il arrive. MONITOR (3) n'est
    /// pas annoncé : `mwait` n'existe pas ici.
    ///
    /// **Et MOVBE (22)**, de x86-64-v3 : un `mov` qui retourne ses octets
    /// (`X86BMI.swift`, `Tests/Fixtures/x86-v3-gpr-oracle.tsv`).
    ///
    /// **Et XSAVE (26)** : `XSAVE`, `XRSTOR`, `XGETBV`, `XSETBV`, sur x87,
    /// SSE et le haut des YMM (`X86XSAVE.swift`). OSXSAVE (27) n'est pas
    /// ici : il recopie CR4.OSXSAVE, et `answer` le pose quand il le faut.
    public static let featuresECX: UInt32 = 1 | (1 << 9) | (1 << 13) | (1 << 19) | (1 << 20) | (1 << 22)
        | (1 << 23) | (1 << 26)
    /// CPUID.1:ECX.OSXSAVE.
    public static let osxsaveBit: UInt32 = 1 << 27
    /// **Feuille 7, EBX : BMI1 (3) et BMI2 (8)**, la part de x86-64-v3 qui
    /// n'emploie que les registres généraux, et que le noyau de RHEL 10
    /// emploie sans demander. AVX2 (5) n'y est pas : les registres YMM
    /// existent (`X86XSAVE.swift`), aucune opération sur 256 bits encore.
    public static let extendedLeaf7EBX: UInt32 = (1 << 3) | (1 << 8)
    /// Feuille 0x80000001, EDX : LM (29) dit que le mode long existe. Sans ce
    /// bit, un noyau 64 bits refuse de démarrer et le dit.
    public static let extendedFeatures: UInt32 = 1 << 29
    /// Feuille 0x80000001, ECX : LAHF-SAHF (0), `lahf` et `sahf` en mode
    /// long, que x86-64-v2 exige aussi ; et ABM (5), qui annonce LZCNT.
    public static let extendedFeaturesECX: UInt32 = 1 | (1 << 5)

    /// La réponse aux quatre registres, pour une feuille donnée. Deux
    /// feuilles dépendent de l'état : la 1, dont OSXSAVE recopie CR4, et la
    /// 0xD, dont EBX dit la taille de la zone pour ce qu'XCR0 active.
    public static func answer(leaf: UInt32, subleaf: UInt32, xcr0: UInt64 = 1, osxsave: Bool = false)
        -> (UInt32, UInt32, UInt32, UInt32) {
        let name = Array(vendor.utf8)
        func word(_ start: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(name[start + $1]) << (8 * UInt32($1)) }
        }
        switch leaf {
        case 0:
            return (highestBasicLeaf, word(0), word(8), word(4))
        case 1:
            // Famille 15 (0xF), modèle 107 (0x6B : 0xB dans le champ de base,
            // 6 dans l'étendu), pas 1 : ce que répond le `qemu64` de QEMU.
            return (0x0006_0FB1, 0, featuresECX | (osxsave ? osxsaveBit : 0), features)
        case 7:
            // Une seule sous-feuille : EAX dit la plus grande, zéro.
            return subleaf == 0 ? (0, extendedLeaf7EBX, 0, 0) : (0, 0, 0, 0)
        case 0xD:
            switch subleaf {
            case 0:
                // Les composants possibles, la taille pour ceux d'XCR0, la
                // plus grande taille ; rien au-dessus du bit 31.
                return (UInt32(X86Core.supportedExtendedState), X86Core.extendedStateSize(xcr0),
                        X86Core.extendedStateSize(X86Core.supportedExtendedState), 0)
            case 2:
                // Le haut des YMM : 256 octets, à l'octet 576 de la zone.
                return (UInt32(X86Core.ExtendedStateArea.upperVectorsSize),
                        UInt32(X86Core.ExtendedStateArea.upperVectors), 0, 0)
            default:
                // La sous-feuille 1 dit XSAVEOPT, XSAVEC, XGETBV1, XSAVES :
                // aucun.
                return (0, 0, 0, 0)
            }
        case 0x8000_0000:
            return (highestExtendedLeaf, 0, 0, 0)
        case 0x8000_0001:
            return (0, 0, extendedFeaturesECX, extendedFeatures)
        case 0x8000_0002...0x8000_0004:
            let bytes = Array(brand.utf8) + [UInt8](repeating: 0, count: 48 - brand.utf8.count)
            let base = Int(leaf - 0x8000_0002) * 16
            func brandWord(_ offset: Int) -> UInt32 {
                (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[base + offset + $1]) << (8 * UInt32($1)) }
            }
            return (brandWord(0), brandWord(4), brandWord(8), brandWord(12))
        default:
            // Une feuille inconnue rend des zéros, ce que le manuel demande —
            // et non les registres inchangés, qui feraient lire n'importe quoi.
            return (0, 0, 0, 0)
        }
    }
}

import Foundation

/// **D'où `RDRAND` et `RDSEED` tirent leurs nombres.**
///
/// Un bureau prêt se télécharge : le même instantané repris sur tous les
/// téléphones. Sans aléa matériel, le générateur du noyau ne mélangeait que
/// des instants comptés en instructions — « Memory KASLR using RDTSC » dit
/// la console du bureau dès sa première ligne, et `RDTSC` est ici le compteur
/// d'instructions. Chaque téléphone repartait donc du même état, et les clés
/// TLS ou SSH tirées juste après la reprise étaient devinables par qui avait
/// l'instantané, c'est-à-dire tout le monde. Linux mélange `RDSEED` et
/// `RDRAND` à chaque réensemencement : avec une vraie source, deux reprises
/// du même fichier divergent dès le premier.
///
/// **Deux sources, et le choix est celui de qui construit la machine.**
/// - `system()` : le générateur du système hôte
///   (`SystemRandomNumberGenerator`, `getrandom` sous Linux,
///   `arc4random_buf` sur iOS). C'est celle de l'application
///   (`GuestMachineFactory.make`).
/// - `seeded(_:)` : une suite fixée par sa graine. C'est celle d'une machine
///   construite sans rien dire — tests, bancs, fabrication d'un bureau —,
///   pour la même raison que le temps de l'invité vient du compteur
///   d'instructions (`X86LegacyDevices`) : deux exécutions du même noyau
///   doivent rendre la même chose, sinon un écart ne se rejoue pas.
///
/// **Hors de l'instantané**, comme l'horloge CMOS : la source appartient à
/// l'hôte qui fait tourner la machine, pas à l'invité. Une machine reprise
/// tire dans la source de la machine qui la reprend ; l'écrire dans le
/// fichier ferait justement rejouer à chaque téléphone la suite du premier.
///
/// Une classe, partagée par la machine et les copies de son cœur, sous un
/// verrou : une instruction rare, et un verrou ne coûte rien à côté de ce
/// qu'une suite tirée deux fois coûterait.
public final class X86Entropy: @unchecked Sendable {
    /// Ce qu'est cette source, pour qu'un test puisse vérifier laquelle une
    /// machine a reçue.
    public enum Kind: Equatable, Sendable {
        case system
        case seeded(UInt64)
    }

    public let kind: Kind
    private let lock = NSLock()
    /// L'état de la suite fixée ; inutile à la source du système.
    private var state: UInt64

    private init(kind: Kind) {
        self.kind = kind
        if case .seeded(let seed) = kind { state = seed } else { state = 0 }
    }

    /// Le générateur du système hôte : ce que l'application donne à ses
    /// machines.
    public static func system() -> X86Entropy { X86Entropy(kind: .system) }

    /// Une suite fixée par sa graine : la même graine rend les mêmes nombres,
    /// dans le même ordre.
    public static func seeded(_ seed: UInt64) -> X86Entropy { X86Entropy(kind: .seeded(seed)) }

    /// La graine d'une machine à qui l'on n'a rien donné.
    public static let reproducibleSeed: UInt64 = 0x7769_7371_5F72_6E67  // « wisq_rng »

    /// Le nombre suivant, sur soixante-quatre bits.
    ///
    /// **SplitMix64** pour la suite fixée : chaque sortie passe par un
    /// mélange complet, si bien que deux graines voisines ne rendent pas des
    /// suites voisines. Ce n'est pas un générateur cryptographique, et il n'a
    /// pas à l'être : il ne sert que là où la reproductibilité est voulue.
    public func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        switch kind {
        case .system:
            var generator = SystemRandomNumberGenerator()
            return generator.next()
        case .seeded:
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }
}

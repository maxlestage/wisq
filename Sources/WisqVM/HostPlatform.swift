import Foundation

/// **La machine qui fait tourner wisq** : son processeur, son système, son
/// modèle.
///
/// L'annonce qui précède un démarrage (`BootAnnouncement`) met les deux
/// plateformes côte à côte — celle de l'image et celle-ci —, parce que c'est
/// leur rapport qui dit ce qui va se passer : un noyau x86-64 sur un iPhone
/// ARM64 est **interprété**, instruction par instruction, et rien d'autre
/// n'explique mieux pourquoi il met une minute là où un PC met trois secondes.
///
/// Le processeur vient de la compilation (`#if arch`), pas d'un appel au
/// système : c'est la seule réponse qui ne peut pas mentir sur le binaire qui
/// la donne.
public struct HostPlatform: Equatable, Sendable {
    /// Le processeur hôte, nommé comme une architecture invitée — c'est le
    /// même vocabulaire, et l'annonce les compare.
    public let architecture: GuestArchitecture
    /// « iOS 18.2 », « Linux »…
    public let system: String
    /// L'identifiant du modèle quand le système le donne (« iPhone16,2 »).
    public let model: String?

    public init(architecture: GuestArchitecture, system: String, model: String?) {
        self.architecture = architecture
        self.system = system
        self.model = model
    }

    /// Ce qui fait tourner ce binaire, maintenant.
    public static var current: HostPlatform {
        HostPlatform(architecture: compiledArchitecture, system: systemName, model: modelIdentifier)
    }

    /// Le processeur pour lequel ce binaire a été compilé.
    public static var compiledArchitecture: GuestArchitecture {
        #if arch(arm64)
        return GuestArchitecture(.arm, bits: 64)
        #elseif arch(x86_64)
        return GuestArchitecture(.x86, bits: 64)
        #elseif arch(arm)
        return GuestArchitecture(.arm, bits: 32)
        #elseif arch(i386)
        return GuestArchitecture(.x86, bits: 32)
        #else
        return GuestArchitecture(.riscv)
        #endif
    }

    private static var systemName: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let number = version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #if os(iOS)
        return "iOS \(number)"
        #elseif os(macOS)
        return "macOS \(number)"
        #elseif os(Linux)
        return "Linux"
        #else
        return number
        #endif
    }

    /// `uname -m` : sur un iPhone, l'identifiant du modèle ; dans le
    /// simulateur, le processeur du Mac, qu'on ne répète pas.
    private static var modelIdentifier: String? {
        #if os(iOS)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return machine.isEmpty ? nil : machine
        #else
        return nil
        #endif
    }

    /// Une ligne : « ARM64 · iOS 18.2 · iPhone16,2 ».
    public var summary: String {
        ([architecture.name, system] + (model.map { [$0] } ?? [])).joined(separator: " · ")
    }
}

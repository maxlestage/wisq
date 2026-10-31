import Foundation

/// Les registres spécifiques au modèle (MSR) d'un cœur x86, **les plus lus
/// rangés à part**.
///
/// C'était un `[UInt32: UInt64]`. Un dictionnaire convient à ce que `RDMSR`
/// et `WRMSR` touchent de loin en loin, mais deux d'entre eux se lisent à
/// presque chaque instruction du noyau : les bases de `%fs` et de `%gs`.
/// Linux range ses variables par processeur derrière `%gs:`, et chaque accès
/// demandait sa base à `segmentBase` — donc un hachage et une recherche dans
/// le dictionnaire, au milieu du calcul d'adresse. Ici, ces bases et les deux
/// autres que le chemin chaud consulte (`KernelGSBase` pour `SWAPGS`, `EFER`)
/// sont des champs ; le reste vit toujours dans le dictionnaire.
///
/// **La même surface qu'avant** : l'indice rend un optionnel et en accepte
/// un, la séquence rend des paires `(key, value)`, un littéral de
/// dictionnaire en construit un. Les soixante-neuf endroits qui lisent ou
/// écrivent un MSR par son indice n'ont pas eu à changer, et l'instantané les
/// écrit dans le même ordre — trié par numéro — octet pour octet. Un test du
/// site recompte ces endroits.
public struct X86ModelSpecific: Equatable, Sendable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var fsBase: UInt64?
    public private(set) var gsBase: UInt64?
    public private(set) var kernelGSBase: UInt64?
    public private(set) var efer: UInt64?
    private var others: [UInt32: UInt64] = [:]

    public init() {}

    public init(dictionaryLiteral elements: (UInt32, UInt64)...) {
        for (number, value) in elements { self[number] = value }
    }

    public subscript(number: UInt32) -> UInt64? {
        @inline(__always) get {
            switch number {
            case X86SystemState.fsBase: return fsBase
            case X86SystemState.gsBase: return gsBase
            case X86SystemState.kernelGSBase: return kernelGSBase
            case X86SystemState.efer: return efer
            default: return others[number]
            }
        }
        set {
            switch number {
            case X86SystemState.fsBase: fsBase = newValue
            case X86SystemState.gsBase: gsBase = newValue
            case X86SystemState.kernelGSBase: kernelGSBase = newValue
            case X86SystemState.efer: efer = newValue
            default: others[number] = newValue
            }
        }
    }

    /// Combien de registres ont une valeur.
    public var count: Int {
        others.count + [fsBase, gsBase, kernelGSBase, efer].filter { $0 != nil }.count
    }

    public var isEmpty: Bool {
        others.isEmpty && fsBase == nil && gsBase == nil && kernelGSBase == nil && efer == nil
    }

    public func makeIterator() -> AnyIterator<(key: UInt32, value: UInt64)> {
        var all = others.map { (key: $0.key, value: $0.value) }
        for (key, value) in [(X86SystemState.efer, efer), (X86SystemState.fsBase, fsBase),
                             (X86SystemState.gsBase, gsBase), (X86SystemState.kernelGSBase, kernelGSBase)] {
            if let value { all.append((key: key, value: value)) }
        }
        return AnyIterator(all.makeIterator())
    }
}

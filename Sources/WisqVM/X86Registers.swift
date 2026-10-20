import Foundation

/// Les seize registres généraux, **sans tableau**.
///
/// Ils ont été un `[UInt64]`, et chaque écriture de registre payait ce
/// qu'un tableau Swift doit payer : la vérification que le stockage n'est
/// partagé avec personne (`swift_isUniquelyReferenced`), celle des bornes,
/// et le compte de références du tampon quand le cœur est copié. Sous
/// callgrind, sur les cent premiers millions d'instructions d'Alpine, c'était
/// un poste à part entière, à chaque `mov` vers un registre.
///
/// Ici, seize mots rangés à plat dans la structure du cœur. L'indice est
/// ramené à quatre bits plutôt que vérifié : tous les appelants passent un
/// numéro de registre, de 0 à 15, et un indice hors de cette plage ne peut
/// pas sortir du stockage.
///
/// **Une collection, pour que rien ne change ailleurs** : `registers[4]`,
/// `Array(core.registers)`, une comparaison ou un `map` s'écrivent comme
/// avant, et un littéral de tableau en construit un — complété de zéros
/// jusqu'à seize, comme un `[]` qui ne sert qu'à comparer.
public struct X86Registers: RandomAccessCollection, MutableCollection, Equatable, Sendable,
    ExpressibleByArrayLiteral, CustomStringConvertible {
    private var storage: (UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64,
                          UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64, UInt64)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    public init() {}

    /// Les seize premières valeurs de `values`, complétées de zéros.
    public init<Values: Sequence>(_ values: Values) where Values.Element == UInt64 {
        for (index, value) in values.prefix(16).enumerated() { self[index] = value }
    }

    public init(arrayLiteral elements: UInt64...) { self.init(elements) }

    public var startIndex: Int { 0 }
    public var endIndex: Int { 16 }

    public subscript(index: Int) -> UInt64 {
        @inline(__always) get {
            withUnsafeBytes(of: storage) { $0.load(fromByteOffset: (index & 15) &* 8, as: UInt64.self) }
        }
        @inline(__always) set {
            withUnsafeMutableBytes(of: &storage) {
                $0.storeBytes(of: newValue, toByteOffset: (index & 15) &* 8, as: UInt64.self)
            }
        }
    }

    /// La même lecture, **en place**. `withUnsafeBytes(of:)` sur une valeur
    /// n'a d'adresse que celle d'une copie, et l'indice ordinaire recopiait
    /// les cent vingt-huit octets du stockage sur la pile à chaque lecture :
    /// deux fois par adresse calculée, la base et l'index. Sur le stockage
    /// lui-même (`&storage`), il n'y a rien à copier ; d'où `mutating`, qui
    /// ne change rien. Un aiguillage de seize cas évitait aussi la copie, et
    /// coûtait plus cher qu'elle.
    ///
    /// **Le cœur ne lit que par ici.** Toutes les lectures de `X86Core`
    /// passaient encore par l'indice — un `push`, une adresse de pile, un
    /// `mov` de registre à registre —, et chacune recopiait les seize mots :
    /// sur cent millions d'instructions du démarrage de Fedora, 526 millions
    /// d'instructions de l'hôte dans le seul aiguillage d'un octet. L'indice
    /// reste pour ce qui lit un cœur sans le modifier : les tests, les
    /// instantanés, les comparaisons.
    @inline(__always)
    public mutating func read(_ index: Int) -> UInt64 {
        withUnsafeBytes(of: &storage) { $0.load(fromByteOffset: (index & 15) &* 8, as: UInt64.self) }
    }

    public static func == (left: X86Registers, right: X86Registers) -> Bool {
        left.elementsEqual(right)
    }

    public var description: String { Array(self).description }
}

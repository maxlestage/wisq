import Foundation

// **Le flottant scalaire.**
//
// Ce dépôt a refusé la virgule flottante cinq tranches durant, et disait
// pourquoi à chaque fois : « le jour où la machine le demandera, elle le dira
// en s'arrêtant dessus ». Elle vient de le dire. Une fois `/init` vivant, le
// SSE2 entier posé et les déplacements scalaires en place, la course s'arrête
// sur `0F 2A` — `CVTSI2SD` — dans le binaire d'Alpine, trente et un mille
// instructions après le mur précédent.
//
// **Le cadrage vient d'un comptage** dans les binaires de l'invité : mulsd
// 914, addsd 748, mulss 503, subsd 458, addss 331, cvtsi2sd 221, subss 197,
// divsd 180, comisd 145, divss 109, cvttsd2si 92, ucomisd 74, cvtss2sd 63,
// ucomiss 35, cvtsd2ss 33, cvtsi2ss 27, comiss 23, cvttss2si 9, maxsd 7,
// minsd 6. Tout est **scalaire** : les formes empaquetées apparaissent une à
// trois fois chacune, dans du code que ce démarrage n'atteint pas.
//
// **Trois règles que le calcul lui-même ne donne pas**, et que seul l'oracle
// matériel pouvait fixer :
//
// 1. **Seule la partie basse change.** Un `addsd` écrit soixante-quatre bits
//    et laisse les soixante-quatre autres tels quels ; un `addss` en écrit
//    trente-deux. Le nom de l'instruction ne le dit pas.
// 2. **`MIN` et `MAX` ne sont pas symétriques.** Quand la comparaison n'est
//    pas ordonnée — un NaN d'un côté ou de l'autre — ou quand les deux
//    valeurs sont des zéros de signes opposés, c'est **la source** qui est
//    rendue, pas la plus grande. Le nom laisse croire l'inverse.
// 3. **Une conversion qui déborde ne faute pas.** `CVTTSD2SI` d'un infini,
//    d'un NaN ou d'un nombre trop grand rend l'« entier indéfini » — le bit
//    de signe seul — et continue.
//
// La référence est `Tests/Fixtures/x86-float-oracle.tsv` : 46 formes, 4 554
// cas, fabriqué par `scripts/build-x86-float-oracle.py`.
//
// **Et ce corpus mesure ce que les six autres interdisaient : les drapeaux.**
// `UCOMIS*` et `COMIS*` écrivent ZF, PF et CF, et effacent OF, SF et AF.
extension X86Core {
    /// Les soixante-quatre bits bas d'un registre, vus comme un double.
    static func asDouble(_ bits: UInt64) -> Double {
        Double(bitPattern: bits)
    }

    static func asSingle(_ bits: UInt64) -> Float {
        Float(bitPattern: UInt32(truncatingIfNeeded: bits))
    }

    /// **Le NaN « indéfini réel »**, celui que x86 fabrique quand l'opération
    /// elle-même est invalide : `0/0`, `inf - inf`, `0 × inf`, la racine d'un
    /// négatif. Le bit de signe est **posé** — c'est un NaN *négatif*, et ce
    /// détail n'est pas cosmétique : un ARM rend `7ff8…`, un x86 rend `fff8…`,
    /// et un émulateur qui laisse l'hôte décider donne deux réponses selon la
    /// machine où il tourne.
    static let indefiniteDouble = Double(bitPattern: 0xFFF8_0000_0000_0000)
    static let indefiniteSingle = Float(bitPattern: 0xFFC0_0000)

    /// Un NaN rendu silencieux, sa charge utile gardée.
    static func quiet(_ value: Double) -> Double {
        Double(bitPattern: value.bitPattern | 0x0008_0000_0000_0000)
    }

    static func quiet(_ value: Float) -> Float {
        Float(bitPattern: value.bitPattern | 0x0040_0000)
    }

    /// L'« entier indéfini » que rend une conversion qui ne peut pas aboutir.
    static func indefinite(_ width: Int) -> UInt64 {
        width == 8 ? 0x8000_0000_0000_0000 : 0x8000_0000
    }

    /// Le résultat d'une conversion vers un entier signé, ou l'entier
    /// indéfini quand la valeur ne tient pas.
    ///
    /// **Ce n'est pas une faute.** Un débordement ici rend une valeur et
    /// continue ; refuser arrêterait un invité que la vraie machine n'aurait
    /// pas arrêté.
    static func toInteger(_ value: Double, _ width: Int) -> UInt64 {
        guard value.isFinite else { return indefinite(width) }
        let limit = width == 8 ? 9.2233720368547758e18 : 2147483648.0
        guard value >= -limit, value < limit else { return indefinite(width) }
        return width == 8
            ? UInt64(bitPattern: Int64(value))
            : UInt64(UInt32(bitPattern: Int32(value)))
    }

    /// Le flottant scalaire. Rend `false` quand l'opcode n'en est pas, pour
    /// que le reste du dispatch continue.
    mutating func floatInstruction(
        _ instruction: X86Instruction, _ opcode: UInt8
    ) throws -> Bool {
        let single = instruction.hasPrefix(0xF3)
        let doubleWide = instruction.hasPrefix(0xF2)
        let operandSize = instruction.hasPrefix(0x66)
        let wide = (instruction.rex ?? 0) & 0x08 != 0

        switch opcode {
        case 0x58 where single || doubleWide:
            try arithmetic(instruction, single, { $0 + $1 }, { $0 + $1 })
        case 0x59 where single || doubleWide:
            try arithmetic(instruction, single, { $0 * $1 }, { $0 * $1 })
        case 0x5C where single || doubleWide:
            try arithmetic(instruction, single, { $0 - $1 }, { $0 - $1 })
        case 0x5E where single || doubleWide:
            try arithmetic(instruction, single, { $0 / $1 }, { $0 / $1 })
        // `MIN` et `MAX` rendent **la source** dès que la comparaison échoue,
        // ce qui couvre le NaN des deux côtés et les zéros de signes opposés.
        case 0x5D where single || doubleWide: try select(instruction, single, keepLower: true)
        case 0x5F where single || doubleWide: try select(instruction, single, keepLower: false)
        case 0x51 where single || doubleWide: try squareRoot(instruction, single)

        // Les comparaisons, seules de tout le vectoriel à écrire des drapeaux.
        case 0x2E, 0x2F where !single && !doubleWide:
            try compare(instruction, !operandSize)

        case 0x5A where single || doubleWide:  // CVTSS2SD / CVTSD2SS
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, single ? 4 : 8)
            let destination = vector(fields.reg)
            if single {
                // La charge utile monte de vingt-neuf bits, et le bit
                // silencieux est posé. Laisser l'hôte convertir donnerait son
                // NaN à lui.
                let from = Self.asSingle(source.0)
                let value: Double
                if from.isNaN {
                    let sign = UInt64(from.bitPattern & 0x8000_0000) << 32
                    let payload = UInt64(from.bitPattern & 0x007F_FFFF) << 29
                    value = Double(bitPattern: sign | 0x7FF8_0000_0000_0000 | payload)
                } else {
                    value = Double(from)
                }
                setVector(fields.reg, value.bitPattern, destination.high)
            } else {
                let from = Self.asDouble(source.0)
                let value: Float
                if from.isNaN {
                    let sign = UInt32(truncatingIfNeeded: from.bitPattern >> 32) & 0x8000_0000
                    let payload = UInt32(truncatingIfNeeded:
                        (from.bitPattern & 0x000F_FFFF_FFFF_FFFF) >> 29)
                    value = Float(bitPattern: sign | 0x7FC0_0000 | payload)
                } else {
                    value = Float(from)
                }
                let low = (destination.low & ~0xFFFF_FFFF) | UInt64(value.bitPattern)
                setVector(fields.reg, low, destination.high)
            }

        case 0x2A where single || doubleWide:  // CVTSI2SS / CVTSI2SD
            let fields = try decodeFields(instruction)
            let raw = try readRM(fields, wide ? 8 : 4)
            let value = wide
                ? Double(Int64(bitPattern: raw))
                : Double(Int32(truncatingIfNeeded: raw))
            let destination = vector(fields.reg)
            if single {
                let low = (destination.low & ~0xFFFF_FFFF) | UInt64(Float(value).bitPattern)
                setVector(fields.reg, low, destination.high)
            } else {
                setVector(fields.reg, value.bitPattern, destination.high)
            }

        // Vers l'entier. `CVTT…` tronque vers zéro ; `CVT…` suit le mode
        // d'arrondi, qui est « au plus proche, pair en cas d'égalité ».
        case 0x2C, 0x2D where single || doubleWide:
            guard single || doubleWide else { return false }
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, single ? 4 : 8)
            let value = single ? Double(Self.asSingle(source.0)) : Self.asDouble(source.0)
            let rounded = opcode == 0x2C ? value.rounded(.towardZero)
                : value.rounded(.toNearestOrEven)
            writeReg(fields, wide ? 8 : 4, Self.toInteger(rounded, wide ? 8 : 4))

        default: return false
        }
        return true
    }

    /// Une opération scalaire : **seule la partie basse de la destination
    /// change**, le reste est laissé tel quel.
    ///
    /// **Deux fermetures, et pas une.** Le premier jet n'en avait qu'une, sur
    /// des `Double`, et convertissait les valeurs simples dans les deux sens
    /// autour. C'est faux, et d'une façon qui ne se voit que sur un cas :
    /// convertir un **NaN signalant** simple en double le rend silencieux, et
    /// le retour donne `7fc00001` là où le processeur rend `7f800001` — ses
    /// bits, intacts. Six cas sur 4 554, et **seulement en débogage** : la
    /// course en optimisé les passait. Une suite verte dans un seul mode de
    /// construction n'est pas une suite verte.
    ///
    /// **Et les NaN ne sont pas laissés à l'hôte.** Le second jet déléguait
    /// l'arithmétique à Swift, donc au processeur qui fait tourner wisq. Sur
    /// x86 ça tombait juste ; sur l'ARM d'un Mac, non — `0.0/0.0` y rend
    /// `7ff8…` là où x86 rend `fff8…`, le NaN indéfini **négatif**. Un
    /// émulateur dont le résultat dépend de la machine qui l'exécute n'émule
    /// rien. Les trois règles sont donc écrites ici :
    ///
    /// 1. si la destination est un NaN, c'est **elle** qui ressort, rendue
    ///    silencieuse et sa charge gardée ;
    /// 2. sinon, si la source en est un, c'est elle, de même ;
    /// 3. sinon on calcule — et si le calcul fabrique un NaN à partir de deux
    ///    nombres, c'est l'indéfini réel qui ressort, pas celui de l'hôte.
    ///
    /// Ce qui reste délégué — les sommes, produits et quotients de valeurs
    /// ordinaires — est exactement spécifié par IEEE 754 et ne varie pas d'une
    /// machine à l'autre.
    private mutating func arithmetic(
        _ instruction: X86Instruction, _ single: Bool,
        _ wide: (Double, Double) -> Double,
        _ narrow: (Float, Float) -> Float
    ) throws {
        let fields = try decodeFields(instruction)
        let source = try readVectorRM(fields, single ? 4 : 8)
        let destination = vector(fields.reg)
        if single {
            let left = Self.asSingle(destination.low)
            let right = Self.asSingle(source.0)
            let result: Float
            if left.isNaN {
                result = Self.quiet(left)
            } else if right.isNaN {
                result = Self.quiet(right)
            } else {
                let computed = narrow(left, right)
                result = computed.isNaN ? Self.indefiniteSingle : computed
            }
            let low = (destination.low & ~0xFFFF_FFFF) | UInt64(result.bitPattern)
            setVector(fields.reg, low, destination.high)
        } else {
            let left = Self.asDouble(destination.low)
            let right = Self.asDouble(source.0)
            let result: Double
            if left.isNaN {
                result = Self.quiet(left)
            } else if right.isNaN {
                result = Self.quiet(right)
            } else {
                let computed = wide(left, right)
                result = computed.isNaN ? Self.indefiniteDouble : computed
            }
            setVector(fields.reg, result.bitPattern, destination.high)
        }
    }

    /// `MIN` et `MAX`, qui **ne sont pas de l'arithmétique** et n'en suivent
    /// pas les règles.
    ///
    /// Ils comparent et choisissent : rien n'est calculé, donc rien n'est
    /// arrondi ni rendu silencieux. Quand la comparaison échoue — un NaN d'un
    /// côté ou de l'autre, ou deux zéros de signes opposés — c'est **la
    /// source** qui ressort, **telle quelle**, bit pour bit. Un NaN signalant
    /// entré signalant ressort signalant. Les fondre avec l'addition, comme
    /// le faisait le jet précédent, leur imposait le silencieux et faussait
    /// quatre-vingt-treize cas.
    private mutating func select(
        _ instruction: X86Instruction, _ single: Bool, keepLower: Bool
    ) throws {
        let fields = try decodeFields(instruction)
        let source = try readVectorRM(fields, single ? 4 : 8)
        let destination = vector(fields.reg)
        if single {
            let left = Self.asSingle(destination.low)
            let right = Self.asSingle(source.0)
            let chosen = (keepLower ? left < right : left > right) ? left : right
            let low = (destination.low & ~0xFFFF_FFFF) | UInt64(chosen.bitPattern)
            setVector(fields.reg, low, destination.high)
        } else {
            let left = Self.asDouble(destination.low)
            let right = Self.asDouble(source.0)
            let chosen = (keepLower ? left < right : left > right) ? left : right
            setVector(fields.reg, chosen.bitPattern, destination.high)
        }
    }

    /// La racine carrée, qui **ne regarde que sa source**. La destination ne
    /// participe pas au calcul : la mettre dans la règle des NaN, comme le
    /// faisait le jet précédent, faisait ressortir la destination quand elle
    /// se trouvait être un NaN.
    private mutating func squareRoot(
        _ instruction: X86Instruction, _ single: Bool
    ) throws {
        let fields = try decodeFields(instruction)
        let source = try readVectorRM(fields, single ? 4 : 8)
        let destination = vector(fields.reg)
        if single {
            let from = Self.asSingle(source.0)
            let result = from.isNaN ? Self.quiet(from)
                : (from < 0 ? Self.indefiniteSingle : from.squareRoot())
            let low = (destination.low & ~0xFFFF_FFFF) | UInt64(result.bitPattern)
            setVector(fields.reg, low, destination.high)
        } else {
            let from = Self.asDouble(source.0)
            let result = from.isNaN ? Self.quiet(from)
                : (from < 0 ? Self.indefiniteDouble : from.squareRoot())
            setVector(fields.reg, result.bitPattern, destination.high)
        }
    }

    /// La comparaison qui écrit les drapeaux. Non ordonnée — un NaN d'un côté
    /// ou de l'autre — vaut ZF, PF et CF tous les trois ; égal vaut ZF seul ;
    /// plus petit vaut CF seul ; plus grand ne vaut rien. OF, SF et AF sont
    /// effacés dans tous les cas.
    private mutating func compare(_ instruction: X86Instruction, _ single: Bool) throws {
        let fields = try decodeFields(instruction)
        let source = try readVectorRM(fields, single ? 4 : 8)
        let left = single
            ? Double(Self.asSingle(vector(fields.reg).low)) : Self.asDouble(vector(fields.reg).low)
        let right = single ? Double(Self.asSingle(source.0)) : Self.asDouble(source.0)
        flags &= ~(Flag.zero | Flag.parity | Flag.carry
                   | Flag.overflow | Flag.sign | Flag.auxiliary)
        if left.isNaN || right.isNaN {
            flags |= Flag.zero | Flag.parity | Flag.carry
        } else if left == right {
            flags |= Flag.zero
        } else if left < right {
            flags |= Flag.carry
        }
    }
}

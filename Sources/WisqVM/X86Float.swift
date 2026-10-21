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
// La référence est `Tests/Fixtures/x86-float-oracle.tsv` : 119 formes, 12 852
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
        // Les racines **empaquetées**, chaque élément selon la règle du
        // scalaire. `SQRTPD` arrêtait `zram-generator` chez Fedora 44.
        case 0x51 where operandSize:
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            setVector(fields.reg, Self.root(Self.asDouble(source.0)).bitPattern,
                      Self.root(Self.asDouble(source.1)).bitPattern)
        case 0x51:  // SQRTPS
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            func lanes(_ value: UInt64) -> UInt64 {
                UInt64(Self.root(Self.asSingle(value)).bitPattern)
                    | UInt64(Self.root(Self.asSingle(value >> 32)).bitPattern) << 32
            }
            setVector(fields.reg, lanes(source.0), lanes(source.1))

        // Les comparaisons, seules de tout le vectoriel à écrire des drapeaux.
        //
        // **La condition est écrite deux fois, et il le faut.** En Swift, un
        // `where` posé après une liste de motifs ne garde que le dernier :
        // `case 0x2E, 0x2F where …` laissait passer `f3 0f 2e`, qui n'est pas
        // une instruction, et le faisait comparer au lieu de le refuser.
        case 0x2E where !single && !doubleWide, 0x2F where !single && !doubleWide:
            try compare(instruction, !operandSize)

        case 0x5A where single || doubleWide:  // CVTSS2SD / CVTSD2SS
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, single ? 4 : 8)
            let destination = vector(fields.reg)
            if single {
                // La charge utile monte de vingt-neuf bits, et le bit
                // silencieux est posé. Laisser l'hôte convertir donnerait son
                // NaN à lui.
                setVector(fields.reg, Self.widened(Self.asSingle(source.0)).bitPattern, destination.high)
            } else {
                let value = Self.narrowed(Self.asDouble(source.0))
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
        // Ici la garde est **dans le corps** — elle couvre donc les deux
        // motifs, ce qu'un `where` sur la liste ne ferait pas.
        case 0x2C, 0x2D:
            guard single || doubleWide else { return false }
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, single ? 4 : 8)
            let value = single ? Double(Self.asSingle(source.0)) : Self.asDouble(source.0)
            let rounded = opcode == 0x2C ? value.rounded(.towardZero)
                : value.rounded(.toNearestOrEven)
            writeReg(fields, wide ? 8 : 4, Self.toInteger(rounded, wide ? 8 : 4))

        // **Ce que la glibc de Debian demande en plus**, arrivé par l'image de
        // cloud de Debian 13 : systemd démarre, et la course s'arrête sur
        // `F2 0F C2` dans l'un de ses programmes. Le comptage sur les binaires
        // de l'initramfs : `cmpnlesd` 15, `cmplesd` 11, `cmpltsd` 8,
        // `cmpless` 8, `cmpnless` 7, `cmpnltsd` 1 ; `mulpd` 15, `addpd` 8 ;
        // `cvtpd2ps` 2, `cvtdq2pd` 1, `cvttpd2dq` 1.

        // La comparaison qui rend un **masque** au lieu d'écrire les
        // drapeaux : tout à un ou tout à zéro dans l'élément bas, le reste
        // laissé tel quel.
        case 0xC2 where single || doubleWide:
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, single ? 4 : 8)
            let destination = vector(fields.reg)
            let code = UInt8(truncatingIfNeeded: instruction.immediate)
            if single {
                let holds = Self.predicate(code, Double(Self.asSingle(destination.low)),
                                           Double(Self.asSingle(source.0)))
                let low = (destination.low & ~0xFFFF_FFFF) | (holds ? 0xFFFF_FFFF : 0)
                setVector(fields.reg, low, destination.high)
            } else {
                let holds = Self.predicate(code, Self.asDouble(destination.low), Self.asDouble(source.0))
                setVector(fields.reg, holds ? .max : 0, destination.high)
            }

        // Les deux doubles d'un registre traités à part, chacun selon la
        // règle des NaN de l'arithmétique scalaire. La soustraction et la
        // division sont venues avec Ubuntu 26.04 : un programme de l'espace
        // utilisateur s'arrêtait sur `0F 5C` à 59 milliards d'instructions.
        case 0x58 where operandSize, 0x59 where operandSize, 0x5C where operandSize,
             0x5E where operandSize:
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            let destination = vector(fields.reg)
            let operation = Self.packedDouble(opcode)
            let low = Self.combine(Self.asDouble(destination.low), Self.asDouble(source.0), operation)
            let high = Self.combine(Self.asDouble(destination.high), Self.asDouble(source.1), operation)
            setVector(fields.reg, low.bitPattern, high.bitPattern)

        // `ADDSUBPD` (SSE3) : soustraire en bas, additionner en haut, chaque
        // moitié selon la même règle des NaN.
        case 0xD0 where operandSize:
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            let destination = vector(fields.reg)
            let low = Self.combine(Self.asDouble(destination.low), Self.asDouble(source.0), { $0 - $1 })
            let high = Self.combine(Self.asDouble(destination.high), Self.asDouble(source.1), { $0 + $1 })
            setVector(fields.reg, low.bitPattern, high.bitPattern)

        // Et les quatre simples, sans préfixe : `ADDPS`, `MULPS`, `SUBPS`,
        // `DIVPS`, chacun selon la même règle.
        case 0x58 where !single && !doubleWide, 0x59 where !single && !doubleWide,
             0x5C where !single && !doubleWide, 0x5E where !single && !doubleWide:
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            let destination = vector(fields.reg)
            let operation = Self.packedSingle(opcode)
            func lanes(_ left: UInt64, _ right: UInt64) -> UInt64 {
                let low = Self.combine(Self.asSingle(left), Self.asSingle(right), operation)
                let high = Self.combine(Self.asSingle(left >> 32), Self.asSingle(right >> 32), operation)
                return UInt64(low.bitPattern) | UInt64(high.bitPattern) << 32
            }
            setVector(fields.reg, lanes(destination.low, source.0), lanes(destination.high, source.1))

        case 0x5A where operandSize:  // CVTPD2PS : deux doubles en deux simples, le haut effacé
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            let low = UInt64(Self.narrowed(Self.asDouble(source.0)).bitPattern)
            let high = UInt64(Self.narrowed(Self.asDouble(source.1)).bitPattern)
            setVector(fields.reg, low | high << 32, 0)

        case 0xE6 where single:  // CVTDQ2PD : deux entiers de trente-deux bits, exacts en double
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 8).0
            let low = Double(Int32(truncatingIfNeeded: source))
            let high = Double(Int32(truncatingIfNeeded: source >> 32))
            setVector(fields.reg, low.bitPattern, high.bitPattern)

        case 0xE6 where operandSize:  // CVTTPD2DQ : tronqués vers zéro, le haut effacé
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            let low = Self.toInteger(Self.asDouble(source.0).rounded(.towardZero), 4)
            let high = Self.toInteger(Self.asDouble(source.1).rounded(.towardZero), 4)
            setVector(fields.reg, low | high << 32, 0)

        // **Les formes empaquetées que Fedora 44 porte encore**, trouvées
        // par la même sonde que le SSE2 entier : presque toutes dans
        // `libmvec`, et `CVTTPS2DQ` dans `libharfbuzz`. Chaque élément suit
        // la règle de sa forme scalaire. `RCPPS` et `RSQRTPS` restent
        // refusés : ce sont des approximations, dont les bits diffèrent d'un
        // processeur à l'autre, et aucun oracle ne pourrait les fixer.
        case 0x5D where !single && !doubleWide, 0x5F where !single && !doubleWide:
            let keepLower = opcode == 0x5D
            try packed(instruction, doubles: operandSize, { left, right in
                Self.chosen(Self.asDouble(left), Self.asDouble(right), keepLower).bitPattern
            }, { left, right in
                Self.chosen(Float(bitPattern: left), Float(bitPattern: right), keepLower).bitPattern
            })
        case 0xC2 where !single && !doubleWide:
            let code = UInt8(truncatingIfNeeded: instruction.immediate)
            try packed(instruction, doubles: operandSize, { left, right in
                Self.predicate(code, Self.asDouble(left), Self.asDouble(right)) ? .max : 0
            }, { left, right in
                Self.predicate(code, Double(Float(bitPattern: left)), Double(Float(bitPattern: right))) ? .max : 0
            })

        case 0x5A where !operandSize:  // CVTPS2PD : les deux simples du bas en deux doubles
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 8).0
            setVector(fields.reg, Self.widened(Self.asSingle(source)).bitPattern,
                      Self.widened(Self.asSingle(source >> 32)).bitPattern)

        // Sans préfixe, `CVTDQ2PS` : quatre entiers en quatre simples, au
        // plus proche. Avec `66`, `CVTPS2DQ`, au plus proche ; avec `F3`,
        // `CVTTPS2DQ`, tronqués. Hors de portée, l'entier indéfini.
        case 0x5B where !doubleWide:
            let fields = try decodeFields(instruction)
            let source = try readVectorRM(fields, 16)
            func lane(_ bits: UInt64) -> UInt64 {
                if !operandSize && !single {
                    return UInt64(Float(Int32(truncatingIfNeeded: bits)).bitPattern)
                }
                let value = Double(Float(bitPattern: UInt32(truncatingIfNeeded: bits)))
                return Self.toInteger(value.rounded(single ? .towardZero : .toNearestOrEven), 4)
            }
            func lanes(_ half: UInt64) -> UInt64 { lane(half) | lane(half >> 32) << 32 }
            setVector(fields.reg, lanes(source.0), lanes(source.1))

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
            let result = Self.combine(Self.asSingle(destination.low), Self.asSingle(source.0), narrow)
            let low = (destination.low & ~0xFFFF_FFFF) | UInt64(result.bitPattern)
            setVector(fields.reg, low, destination.high)
        } else {
            let result = Self.combine(Self.asDouble(destination.low), Self.asDouble(source.0), wide)
            setVector(fields.reg, result.bitPattern, destination.high)
        }
    }

    /// L'opération d'un octet `58`, `59`, `5C` ou `5E`, sur des doubles puis
    /// sur des simples.
    static func packedDouble(_ opcode: UInt8) -> (Double, Double) -> Double {
        switch opcode {
        case 0x58: return { $0 + $1 }
        case 0x59: return { $0 * $1 }
        case 0x5C: return { $0 - $1 }
        default: return { $0 / $1 }
        }
    }

    static func packedSingle(_ opcode: UInt8) -> (Float, Float) -> Float {
        switch opcode {
        case 0x58: return { $0 + $1 }
        case 0x59: return { $0 * $1 }
        case 0x5C: return { $0 - $1 }
        default: return { $0 / $1 }
        }
    }

    /// Les trois règles des NaN, pour un élément : la destination si c'en est
    /// un, sinon la source, sinon le calcul, dont un NaN né de deux nombres
    /// devient l'indéfini réel.
    static func combine(_ left: Double, _ right: Double, _ operation: (Double, Double) -> Double) -> Double {
        if left.isNaN { return quiet(left) }
        if right.isNaN { return quiet(right) }
        let computed = operation(left, right)
        return computed.isNaN ? indefiniteDouble : computed
    }

    static func combine(_ left: Float, _ right: Float, _ operation: (Float, Float) -> Float) -> Float {
        if left.isNaN { return quiet(left) }
        if right.isNaN { return quiet(right) }
        let computed = operation(left, right)
        return computed.isNaN ? indefiniteSingle : computed
    }

    /// Un double ramené en simple, comme le fait x86 : un NaN garde son signe
    /// et le haut de sa charge, et devient silencieux.
    static func narrowed(_ from: Double) -> Float {
        guard from.isNaN else { return Float(from) }
        let sign = UInt32(truncatingIfNeeded: from.bitPattern >> 32) & 0x8000_0000
        let payload = UInt32(truncatingIfNeeded: (from.bitPattern & 0x000F_FFFF_FFFF_FFFF) >> 29)
        return Float(bitPattern: sign | 0x7FC0_0000 | payload)
    }

    /// Les huit prédicats de `CMPSS`/`CMPSD`, dans l'ordre de l'immédiat. Les
    /// comparaisons de Swift rendent faux dès qu'un NaN est là, ce qui est
    /// exactement la règle des quatre premiers ; les quatre suivants en sont
    /// les négations, donc vrais sur un NaN.
    static func predicate(_ code: UInt8, _ left: Double, _ right: Double) -> Bool {
        switch code & 0x07 {
        case 0: return left == right
        case 1: return left < right
        case 2: return left <= right
        case 3: return left.isNaN || right.isNaN
        case 4: return !(left == right)
        case 5: return !(left < right)
        case 6: return !(left <= right)
        default: return !left.isNaN && !right.isNaN
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
            let chosen = Self.chosen(Self.asSingle(destination.low), Self.asSingle(source.0), keepLower)
            let low = (destination.low & ~0xFFFF_FFFF) | UInt64(chosen.bitPattern)
            setVector(fields.reg, low, destination.high)
        } else {
            let chosen = Self.chosen(Self.asDouble(destination.low), Self.asDouble(source.0), keepLower)
            setVector(fields.reg, chosen.bitPattern, destination.high)
        }
    }

    /// Une opération empaquetée, élément par élément : deux doubles avec
    /// `66`, quatre simples sans. Les fermetures reçoivent et rendent des
    /// bits, pour qu'un masque tout à un ne passe jamais par un flottant.
    private mutating func packed(
        _ instruction: X86Instruction, doubles: Bool,
        _ double: (UInt64, UInt64) -> UInt64, _ single: (UInt32, UInt32) -> UInt32
    ) throws {
        let fields = try decodeFields(instruction)
        let source = try readVectorRM(fields, 16)
        let destination = vector(fields.reg)
        func lanes(_ left: UInt64, _ right: UInt64) -> UInt64 {
            if doubles { return double(left, right) }
            let low = single(UInt32(truncatingIfNeeded: left), UInt32(truncatingIfNeeded: right))
            let high = single(UInt32(truncatingIfNeeded: left >> 32), UInt32(truncatingIfNeeded: right >> 32))
            return UInt64(low) | UInt64(high) << 32
        }
        setVector(fields.reg, lanes(destination.low, source.0), lanes(destination.high, source.1))
    }

    /// Le choix de `MIN` et `MAX` : la destination si la comparaison la
    /// garde, **la source** sinon, NaN et zéros de signes opposés compris.
    static func chosen<Value: BinaryFloatingPoint>(_ left: Value, _ right: Value, _ keepLower: Bool) -> Value {
        (keepLower ? left < right : left > right) ? left : right
    }

    /// Un simple élargi en double. Un NaN garde son signe et sa charge
    /// utile, montée de vingt-neuf bits, et devient silencieux : laisser
    /// l'hôte convertir donnerait son NaN à lui.
    static func widened(_ from: Float) -> Double {
        guard from.isNaN else { return Double(from) }
        let sign = UInt64(from.bitPattern & 0x8000_0000) << 32
        let payload = UInt64(from.bitPattern & 0x007F_FFFF) << 29
        return Double(bitPattern: sign | 0x7FF8_0000_0000_0000 | payload)
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
            let result = Self.root(Self.asSingle(source.0))
            let low = (destination.low & ~0xFFFF_FFFF) | UInt64(result.bitPattern)
            setVector(fields.reg, low, destination.high)
        } else {
            setVector(fields.reg, Self.root(Self.asDouble(source.0)).bitPattern, destination.high)
        }
    }

    /// La racine que rend le processeur : un NaN reste NaN, rendu
    /// silencieux ; un nombre négatif (pas -0) donne l'indéfini.
    static func root(_ from: Double) -> Double {
        from.isNaN ? quiet(from) : (from < 0 ? indefiniteDouble : from.squareRoot())
    }

    static func root(_ from: Float) -> Float {
        from.isNaN ? quiet(from) : (from < 0 ? indefiniteSingle : from.squareRoot())
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

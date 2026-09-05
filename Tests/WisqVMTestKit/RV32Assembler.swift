import Foundation

/// L'assembleur qu'on n'a pas, écrit une fois.
///
/// Les tests de ce dépôt donnent au cœur rv32 des instructions encodées à la
/// main. C'est la seule façon d'isoler un bras du décodeur, et c'est aussi
/// exactement le genre de chose qui est fausse en silence : un champ décalé
/// d'un bit donne une autre instruction, qui s'exécute très bien.
///
/// Les encodeurs vivaient en privé dans `RV32CoreTests`. Un second fichier en
/// aurait eu besoin, et deux descriptions du même format binaire divergent à
/// la première correction — la leçon que `VirtioQueue` a déjà servie pour la
/// file virtio.
///
/// Les noms et l'ordre des arguments suivent la syntaxe de l'assembleur
/// RISC-V, `sw rs2, offset(rs1)` compris, pour qu'un programme écrit ici se
/// relise à côté d'un désassemblage.
///
/// **Il vit dans une cible à part** parce que les deux cibles de test qui en
/// ont besoin — celle du cœur Swift et celle qui compare les deux cœurs — ne
/// peuvent pas se partager un fichier autrement. Ce n'est pas un produit :
/// rien de tout ça n'est construit pour l'application.
public enum RV32Asm {
    // MARK: - Registre à registre

    public static func add(_ rd: Int, _ rs1: Int, _ rs2: Int) -> UInt32 {
        (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (UInt32(rd) << 7) | 0x33
    }

    public static func mul(_ rd: Int, _ rs1: Int, _ rs2: Int) -> UInt32 {
        (1 << 25) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15) | (UInt32(rd) << 7) | 0x33
    }

    // MARK: - Immédiats

    public static func addi(_ rd: Int, _ rs1: Int, _ imm: Int32) -> UInt32 {
        (UInt32(bitPattern: imm) << 20) | (UInt32(rs1) << 15) | (UInt32(rd) << 7) | 0x13
    }

    /// Décalage à gauche. Le `shamt` occupe la place de l'immédiat.
    public static func slli(_ rd: Int, _ rs1: Int, _ shamt: UInt32) -> UInt32 {
        (shamt << 20) | (UInt32(rs1) << 15) | (1 << 12) | (UInt32(rd) << 7) | 0x13
    }

    /// Les vingt bits de poids fort ; les douze du bas restent à zéro.
    public static func lui(_ rd: Int, _ imm20: UInt32) -> UInt32 {
        (imm20 << 12) | (UInt32(rd) << 7) | 0x37
    }

    // MARK: - Mémoire

    public static func lw(_ rd: Int, _ offset: Int32, _ rs1: Int) -> UInt32 {
        load(rd, offset, rs1, funct3: 2)
    }

    /// Octet non signé : c'est celui qu'on veut pour un octet de statut ou un
    /// caractère, `lb` étendant le signe et transformant 0xFF en −1.
    public static func lbu(_ rd: Int, _ offset: Int32, _ rs1: Int) -> UInt32 {
        load(rd, offset, rs1, funct3: 4)
    }

    public static func sw(_ rs2: Int, _ offset: Int32, _ rs1: Int) -> UInt32 {
        store(rs2, offset, rs1, funct3: 2)
    }

    public static func sb(_ rs2: Int, _ offset: Int32, _ rs1: Int) -> UInt32 {
        store(rs2, offset, rs1, funct3: 0)
    }

    private static func load(_ rd: Int, _ offset: Int32, _ rs1: Int, funct3: UInt32) -> UInt32 {
        (UInt32(bitPattern: offset) << 20) | (UInt32(rs1) << 15)
            | (funct3 << 12) | (UInt32(rd) << 7) | 0x03
    }

    /// L'immédiat d'un `store` est coupé en deux morceaux, de part et d'autre
    /// des registres — c'est ce qui permet à `rs1` et `rs2` d'occuper la même
    /// place que partout ailleurs.
    private static func store(_ rs2: Int, _ offset: Int32, _ rs1: Int, funct3: UInt32) -> UInt32 {
        let imm = UInt32(bitPattern: offset)
        return ((imm >> 5) << 25) | (UInt32(rs2) << 20) | (UInt32(rs1) << 15)
            | (funct3 << 12) | ((imm & 0x1F) << 7) | 0x23
    }

    // MARK: - Sauts

    public static func beq(_ rs1: Int, _ rs2: Int, _ offset: Int32) -> UInt32 {
        branch(rs1, rs2, offset, funct3: 0)
    }

    public static func bne(_ rs1: Int, _ rs2: Int, _ offset: Int32) -> UInt32 {
        branch(rs1, rs2, offset, funct3: 1)
    }

    /// Le déplacement d'un branchement est en pas de deux octets, et son bit
    /// de poids fort est rangé tout en haut : le bit 0 n'existe pas.
    private static func branch(_ rs1: Int, _ rs2: Int, _ offset: Int32, funct3: UInt32) -> UInt32 {
        let imm = UInt32(bitPattern: offset)
        return ((imm >> 12) & 1) << 31 | ((imm >> 5) & 0x3F) << 25
            | UInt32(rs2) << 20 | UInt32(rs1) << 15 | (funct3 << 12)
            | ((imm >> 1) & 0xF) << 8 | ((imm >> 11) & 1) << 7 | 0x63
    }

    public static func jal(_ rd: Int, _ offset: Int32) -> UInt32 {
        let imm = UInt32(bitPattern: offset)
        return ((imm >> 20) & 1) << 31 | ((imm >> 1) & 0x3FF) << 21
            | ((imm >> 11) & 1) << 20 | ((imm >> 12) & 0xFF) << 12
            | UInt32(rd) << 7 | 0x6F
    }

    // MARK: - Le mode machine

    /// Écrit un CSR et jette l'ancienne valeur — le `csrw rd=x0` habituel.
    public static func csrw(_ csr: UInt32, _ rs1: Int) -> UInt32 {
        (csr << 20) | (UInt32(rs1) << 15) | (1 << 12) | 0x73
    }

    /// Lit un CSR sans y toucher : `csrrs rd, csr, x0`.
    ///
    /// C'est la forme canonique de la lecture seule. `csrrs` met à un les bits
    /// de `rs1` ; avec `x0` il n'y en a aucun, et la valeur relue est réécrite
    /// telle quelle.
    public static func csrr(_ rd: Int, _ csr: UInt32) -> UInt32 {
        (csr << 20) | (2 << 12) | (UInt32(rd) << 7) | 0x73
    }

    public static func andi(_ rd: Int, _ rs1: Int, _ imm: Int32) -> UInt32 {
        (UInt32(bitPattern: imm) << 20) | (UInt32(rs1) << 15)
            | (7 << 12) | (UInt32(rd) << 7) | 0x13
    }

    public static let mret: UInt32 = 0x3020_0073

    // MARK: - Les numéros que le programme désigne par leur nom

    public static let mstatus: UInt32 = 0x300
    public static let mie: UInt32 = 0x304
    public static let mtvec: UInt32 = 0x305
    public static let mcause: UInt32 = 0x342
    public static let mip: UInt32 = 0x344

    /// Les mots, dans l'ordre, tels que la mémoire de l'invité les attend.
    public static func image(_ words: [UInt32]) -> Data {
        var data = Data(capacity: words.count * 4)
        for word in words {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

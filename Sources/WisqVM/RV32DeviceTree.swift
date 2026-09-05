import Foundation

/// L'arbre que la machine rv32 tend à son invité, écrit en clair.
///
/// **Il décrit exactement le matériel que `LinuxMachine` émule** : un hart
/// rv32ima sans MMU, la RAM à 0x8000_0000, un UART 8250 à 0x1000_0000, un
/// CLINT, un syscon. C'est aussi, propriété par propriété, ce que le
/// `sixtyfourmb.dtb` de mini-rv32ima (Charles Lohr, MIT) déclare — et
/// `DeviceTreeAgainstTheReferenceTests` le tient : le blob reste dans le dépôt
/// comme témoin, pas comme source.
///
/// **Ce que le blob ne pouvait pas faire.** On y écrivait la taille mémoire à
/// l'octet 316 et la ligne de commande à l'octet 192, plafonnée à la place
/// qu'elle s'y trouvait avoir. Ajouter un nœud était hors de question, et un
/// périphérique qu'un arbre ne déclare pas n'existe pas pour le noyau : c'est
/// la vraie raison pour laquelle cette machine ne pouvait pas avoir de disque.
public enum RV32DeviceTree {
    /// Le phandle du contrôleur d'interruptions du hart.
    ///
    /// C'est **lui** que les périphériques désignent, faute de PLIC. Le CLINT
    /// le fait déjà dans l'arbre de référence ; un disque fera pareil, et
    /// n'aura donc besoin d'aucun contrôleur intermédiaire.
    public static let hartInterruptController: UInt32 = 2
    static let cpuPhandle: UInt32 = 1
    static let sysconPhandle: UInt32 = 4

    /// Ce que la ligne de commande vaut quand personne n'en donne une.
    public static let defaultCommandLine =
        "earlycon=uart8250,mmio,0x10000000,1000000 console=ttyS0"

    /// Ce que l'arbre de référence garde hors de portée du noyau, en haut de
    /// la mémoire : le DTB lui-même et l'état réservé y vivent.
    ///
    /// Le blob déclare `0x03ff_c000` pour une machine de 64 Mo, soit seize
    /// kibioctets de moins. C'est le choix de la disposition de référence, pas
    /// le nôtre, et le garder à toutes les tailles est ce qui fait qu'une
    /// machine redimensionnée se comporte comme celle-là.
    public static let memoryTopReserve = 16 * 1024

    /// L'arbre, pour une machine de cette taille et cette ligne de commande.
    ///
    /// La ligne de commande n'a plus de plafond : elle est écrite comme une
    /// propriété, et l'arbre grandit avec elle. Le seul plafond qui reste est
    /// celui de la mémoire de l'invité, que `LinuxMachine` vérifie.
    public static func tree(ramSize: Int, commandLine: String? = nil) -> DeviceTree {
        let declared = UInt32(max(0, ramSize - memoryTopReserve))
        return DeviceTree(root: DeviceTree.Node(
            "",
            properties: [
                ("#address-cells", .cells([2])),
                ("#size-cells", .cells([2])),
                ("compatible", .string("riscv-minimal-nommu")),
                ("model", .string("riscv-minimal-nommu,qemu")),
            ],
            children: [
                DeviceTree.Node("chosen", properties: [
                    ("bootargs", .string(commandLine ?? defaultCommandLine)),
                ]),
                DeviceTree.Node("memory@80000000", properties: [
                    ("device_type", .string("memory")),
                    // Deux cellules pour la base, deux pour la taille : la
                    // racine annonce `#address-cells = <2>`, et un `reg` qui
                    // n'en donnerait qu'une serait lu de travers.
                    ("reg", .cells([0, 0x8000_0000, 0, declared])),
                ]),
                cpus,
                soc,
            ]))
    }

    static let cpus = DeviceTree.Node(
        "cpus",
        properties: [
            ("#address-cells", .cells([1])),
            ("#size-cells", .cells([0])),
            // Un mégahertz : c'est la fréquence que `LinuxMachine` donne au
            // `mtime` du CLINT, en avançant d'une microseconde par tour.
            ("timebase-frequency", .cells([1_000_000])),
        ],
        children: [
            DeviceTree.Node(
                "cpu@0",
                properties: [
                    ("phandle", .cells([cpuPhandle])),
                    ("device_type", .string("cpu")),
                    ("reg", .cells([0])),
                    ("status", .string("okay")),
                    ("compatible", .string("riscv")),
                    ("riscv,isa", .string("rv32ima")),
                    ("mmu-type", .string("riscv,none")),
                ],
                children: [
                    DeviceTree.Node("interrupt-controller", properties: [
                        ("#interrupt-cells", .cells([1])),
                        // Présente et vide : c'est sa présence qui dit « ce
                        // nœud est un contrôleur », pas sa valeur.
                        ("interrupt-controller", .empty),
                        ("compatible", .string("riscv,cpu-intc")),
                        ("phandle", .cells([hartInterruptController])),
                    ]),
                ]),
            DeviceTree.Node("cpu-map", children: [
                DeviceTree.Node("cluster0", children: [
                    DeviceTree.Node("core0", properties: [
                        ("cpu", .cells([cpuPhandle])),
                    ]),
                ]),
            ]),
        ])

    static let soc = DeviceTree.Node(
        "soc",
        properties: [
            ("#address-cells", .cells([2])),
            ("#size-cells", .cells([2])),
            ("compatible", .string("simple-bus")),
            ("ranges", .empty),
        ],
        children: [
            DeviceTree.Node("uart@10000000", properties: [
                ("clock-frequency", .cells([0x0100_0000])),
                ("reg", .cells([0, 0x1000_0000, 0, 0x100])),
                ("compatible", .string("ns16850")),
            ]),
            // L'extinction et le redémarrage écrivent deux valeurs différentes
            // dans le même registre du syscon — c'est ainsi que le noyau les
            // distingue, et `LinuxMachine` les lit à 0x1110_0000.
            DeviceTree.Node("poweroff", properties: [
                ("value", .cells([0x5555])),
                ("offset", .cells([0])),
                ("regmap", .cells([sysconPhandle])),
                ("compatible", .string("syscon-poweroff")),
            ]),
            DeviceTree.Node("reboot", properties: [
                ("value", .cells([0x7777])),
                ("offset", .cells([0])),
                ("regmap", .cells([sysconPhandle])),
                ("compatible", .string("syscon-reboot")),
            ]),
            DeviceTree.Node("syscon@11100000", properties: [
                ("phandle", .cells([sysconPhandle])),
                ("reg", .cells([0, 0x1110_0000, 0, 0x1000])),
                ("compatible", .string("syscon")),
            ]),
            DeviceTree.Node("clint@11000000", properties: [
                // Deux paires : le contrôleur du hart et le numéro de ligne.
                // Trois pour le logiciel, sept pour le timer — ce sont les
                // bits de `mip`, et c'est le même chemin qu'un périphérique
                // empruntera avec onze.
                ("interrupts-extended",
                 .cells([hartInterruptController, 3, hartInterruptController, 7])),
                ("reg", .cells([0, 0x1100_0000, 0, 0x1_0000])),
                ("compatible", .strings(["sifive,clint0", "riscv,clint0"])),
            ]),
        ])
}

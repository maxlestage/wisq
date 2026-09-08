import Foundation

/// **Une image ISO 9660 gravée à la main, pour les tests Swift.**
///
/// Le lecteur vit en Rust et ses propres cas — bourrage entre deux secteurs,
/// noms Rock Ridge qui mentent sur leur longueur, entrées de chargeur,
/// intrus — sont jugés là-bas. Ce qu'on grave ici est **le gréement** de ce
/// côté-ci de la frontière : de quoi voir ce que Swift reçoit, et ce qu'il
/// fait d'une recette qui promet un fichier absent.
///
/// La duplication avec les fixtures Rust et celle du harnais d'ABI est
/// assumée : chaque langue doit pouvoir en poser une sur le disque sans
/// dépendre des autres, et une image fausse fait tomber le test bruyamment
/// plutôt que passer en silence.
struct IsoGravure {
    static let sector = 2048

    /// Le noyau que l'image porte : un motif reconnaissable, pour qu'une
    /// lecture au mauvais secteur se voie.
    static let kernel = Data((0..<3000).map { UInt8($0 % 251) })

    /// L'initramfs. Court, et commençant comme un gzip — c'est ce qu'un vrai
    /// initramfs est, et le reconnaisseur de noyaux le juge là-dessus.
    static let initramfs = Data([0x1f, 0x8b, 0x08, 0x00])

    /// Ce que la recette **dit**. Peut nommer un fichier que l'image n'a pas :
    /// c'est le cas qui compte, puisqu'un noyau chargé sans son initramfs
    /// démarre entièrement avant de paniquer sur sa racine.
    var recipeKernel = "/boot/vmlinuz-virt"
    var recipeInitrd: String? = "/boot/initramfs-virt"
    var commandLine = "modules=loop,squashfs quiet"

    /// Ce que l'image **porte**.
    var carriesKernel = true
    var carriesInitrd = true

    /// Les octets du noyau gravé. Réglable pour qu'un test puisse poser deux
    /// images portant deux noyaux différents — c'est ce qui distingue deux
    /// machines sauvegardées.
    var kernel = IsoGravure.kernel

    func write() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisq-essai-\(getpid())-\(UUID().uuidString).iso")
        try data().write(to: url)
        return url
    }

    private func both32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
            + withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    private func both16(_ value: UInt16) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian, Array.init)
            + withUnsafeBytes(of: value.bigEndian, Array.init)
    }

    private func record(
        lba: UInt32, size: UInt32, directory: Bool, name: [UInt8], rock: String?
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 33)
        out.replaceSubrange(2..<10, with: both32(lba))
        out.replaceSubrange(10..<18, with: both32(size))
        out[25] = directory ? 2 : 0
        out.replaceSubrange(28..<32, with: both16(1))
        out[32] = UInt8(name.count)
        out += name
        // Un octet de bourrage quand la longueur du nom est paire, pour que la
        // zone d'usage système commence sur un mot.
        if name.count % 2 == 0 { out.append(0) }
        if let rock {
            out += Array("NM".utf8)
            out.append(UInt8(5 + rock.utf8.count))
            out.append(1)
            out.append(0)
            out += Array(rock.utf8)
        }
        out[0] = UInt8(out.count)
        return out
    }

    private func directory(own: UInt32, children: [[UInt8]]) -> [UInt8] {
        var out = record(
            lba: own, size: UInt32(Self.sector), directory: true, name: [0], rock: nil)
        out += record(lba: 0, size: UInt32(Self.sector), directory: true, name: [1], rock: nil)
        for child in children { out += child }
        return out
    }

    /// L'image, gravée secteur par secteur.
    func data() -> Data {
        var sectors = [[UInt8]](repeating: [UInt8](repeating: 0, count: Self.sector), count: 18)

        func push(_ bytes: [UInt8]) -> (lba: UInt32, size: UInt32) {
            let lba = UInt32(sectors.count)
            var at = 0
            while at < bytes.count {
                var sector = [UInt8](repeating: 0, count: Self.sector)
                let end = min(at + Self.sector, bytes.count)
                sector.replaceSubrange(0..<(end - at), with: bytes[at..<end])
                sectors.append(sector)
                at = end
            }
            return (lba, UInt32(bytes.count))
        }

        // **Le noyau est gravé en dernier**, et son adresse est promise ici.
        // C'est ce qui permet de tronquer l'image sans emporter les
        // répertoires : sans ça, une image coupée n'ouvrirait même pas, et le
        // test de l'effacement ne pourrait pas exister.
        let kernelLBA: UInt32 = 23
        let initrd = push([UInt8](Self.initramfs))
        var lines = ["DEFAULT virt", "LABEL virt", "  KERNEL \(recipeKernel)"]
        if let recipeInitrd { lines.append("  INITRD \(recipeInitrd)") }
        lines.append("  APPEND \(commandLine)")
        let recipe = push(Array((lines.joined(separator: "\n") + "\n").utf8))

        let syslinuxLBA = UInt32(sectors.count)
        let syslinux = directory(
            own: syslinuxLBA,
            children: [
                record(
                    lba: recipe.lba, size: recipe.size, directory: false,
                    name: Array("SYSLINUX.CFG;1".utf8), rock: "syslinux.cfg")
            ])
        let syslinuxAt = push(syslinux)

        let bootLBA = UInt32(sectors.count)
        var children: [[UInt8]] = []
        if carriesKernel {
            children.append(
                record(
                    lba: kernelLBA, size: UInt32(kernel.count), directory: false,
                    name: Array("VMLINUZ_.VIR;1".utf8), rock: "vmlinuz-virt"))
        }
        if carriesInitrd {
            children.append(
                record(
                    lba: initrd.lba, size: initrd.size, directory: false,
                    name: Array("INITRAMF.VIR;1".utf8), rock: "initramfs-virt"))
        }
        children.append(
            record(
                lba: syslinuxAt.lba, size: UInt32(Self.sector), directory: true,
                name: Array("SYSLINUX".utf8), rock: nil))
        let bootAt = push(directory(own: bootLBA, children: children))

        let rootLBA = UInt32(sectors.count)
        let rootAt = push(
            directory(
                own: rootLBA,
                children: [
                    record(
                        lba: bootAt.lba, size: UInt32(Self.sector), directory: true,
                        name: Array("BOOT".utf8), rock: nil)
                ]))

        var pvd = [UInt8](repeating: 0, count: Self.sector)
        pvd[0] = 1
        pvd.replaceSubrange(1..<6, with: Array("CD001".utf8))
        pvd[6] = 1
        pvd.replaceSubrange(8..<40, with: [UInt8](repeating: 0x20, count: 32))
        pvd.replaceSubrange(40..<72, with: [UInt8](repeating: 0x20, count: 32))
        pvd.replaceSubrange(40..<48, with: Array("WISQPONT".utf8))
        pvd.replaceSubrange(80..<88, with: both32(UInt32(sectors.count)))
        pvd.replaceSubrange(128..<132, with: both16(UInt16(Self.sector)))
        let rootRecord = record(
            lba: rootAt.lba, size: UInt32(Self.sector), directory: true, name: [0], rock: nil)
        pvd.replaceSubrange(156..<(156 + rootRecord.count), with: rootRecord)
        sectors[16] = pvd

        var end = [UInt8](repeating: 0, count: Self.sector)
        end[0] = 255
        end.replaceSubrange(1..<6, with: Array("CD001".utf8))
        end[6] = 1
        sectors[17] = end

        // La promesse tenue. Un décalage ici donnerait une image dont le noyau
        // n'est pas là où son enregistrement le dit, et les tests tomberaient
        // sur le gréement plutôt que sur ce qu'ils visent.
        precondition(
            sectors.count == Int(kernelLBA),
            "le noyau doit être gravé au secteur promis, pas au \(sectors.count)")
        _ = push([UInt8](kernel))

        return Data(sectors.flatMap { $0 })
    }
}

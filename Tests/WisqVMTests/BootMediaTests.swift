import XCTest

@testable import WisqVM

/// L'initramfs : ce qu'on accepte, et à quel noyau il va.
///
/// **Pourquoi ce fichier existe.** Un noyau de distribution n'a aucun pilote
/// de disque compilé dedans — ce sont des modules, et ils vivent dans
/// l'initramfs. Sans lui, le noyau démarre entièrement puis panique :
/// « VFS: Unable to mount root fs on unknown-block(0,0) ». C'est ce que
/// l'application faisait vivre à qui importait un noyau de PC, parce qu'elle
/// appelait toujours `load(…, initialRamdisk: nil)`.
///
/// Et elle **refusait** l'initramfs à l'import : celui d'Alpine commence par
/// `1f 8b`, donc `KernelImageKind` y voyait un noyau compressé et répondait
/// « wisq démarre un noyau non compressé, prenez plutôt celui-là ». Pour ce
/// fichier-là, il n'y a pas d'autre fichier à prendre.
///
/// **Les octets ne peuvent pas trancher**, et c'est le fait qui commande tout
/// le reste : un noyau compressé et un initramfs compressé sont l'un et
/// l'autre un flux gzip, et l'en-tête d'Alpine ne porte même pas de nom de
/// fichier (l'octet de drapeaux vaut zéro). C'est donc à la personne de dire
/// lequel elle apporte — un second import — et à ce type-ci de vérifier
/// seulement que le fichier *pourrait* en être un.
final class BootMediaTests: XCTestCase {
    static func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    // MARK: - Ce qu'on accepte

    /// Les six enveloppes qu'un `mkinitfs` produit selon la distribution.
    func testEveryCompressedStreamIsAccepted() {
        for (magic, format) in [
            ([0x1F, 0x8B] as [UInt8], "gzip"),
            ([0xFD, 0x37, 0x7A, 0x58, 0x5A], "xz"),
            ([0x28, 0xB5, 0x2F, 0xFD], "zstd"),
            ([0x42, 0x5A, 0x68], "bzip2"),
            ([0x04, 0x22, 0x4D, 0x18], "lz4"),
            ([0x89, 0x4C, 0x5A, 0x4F], "lzop"),
        ] {
            let padded = magic + [UInt8](repeating: 0, count: 64)
            XCTAssertNil(BootMedia.refusal(for: Data(padded), name: "initramfs-lts"),
                         "\(format) est une enveloppe d'initramfs")
        }
    }

    /// Un cpio nu : c'est ce qu'un noyau accepte aussi, et ce que produit un
    /// `find | cpio -o -H newc` sans compression.
    func testABareCpioIsAccepted() {
        let cpio = Array("070701".utf8) + [UInt8](repeating: 0x30, count: 100)
        XCTAssertNil(BootMedia.refusal(for: Data(cpio), name: "initrd"))
    }

    /// **Un noyau est refusé, et le refus dit que c'en est un.** C'est la
    /// confusion exacte qu'on répare : quelqu'un qui se trompe de bouton doit
    /// lire « c'est un noyau », pas « fichier non reconnu ».
    func testAKernelIsRefusedAsAKernel() throws {
        let image = Data(LinuxBootProtocolTests.header())
        let refusal = try XCTUnwrap(BootMedia.refusal(for: image, name: "vmlinuz-lts"))
        XCTAssertTrue(refusal.contains("noyau"), refusal)
        XCTAssertTrue(refusal.contains("vmlinuz-lts"), "le refus nomme le fichier")
    }

    /// Une image de disque n'est pas un initramfs non plus, et pour une raison
    /// qui lui est propre.
    func testADiscImageIsRefused() throws {
        var iso = [UInt8](repeating: 0, count: 0x8100)
        for (offset, byte) in Array("CD001".utf8).enumerated() { iso[0x8001 + offset] = byte }
        let refusal = try XCTUnwrap(BootMedia.refusal(for: Data(iso), name: "alpine.iso"))
        XCTAssertTrue(refusal.contains("image de disque"), refusal)
    }

    /// Et ce qui ne ressemble à rien est refusé plutôt que tenté : un noyau à
    /// qui l'on donne des octets quelconques comme initramfs ne dit pas
    /// « ce n'est pas un initramfs », il déballe du vide et panique plus loin.
    func testSomethingUnrecognisableIsRefused() throws {
        let refusal = try XCTUnwrap(
            BootMedia.refusal(for: Data([UInt8](repeating: 0x5A, count: 64)), name: "notes.txt"))
        XCTAssertTrue(refusal.contains("notes.txt"))
    }

    // MARK: - À quel noyau il va

    /// Alpine : `vmlinuz-lts` et `initramfs-lts`.
    func testAlpineNamesPair() {
        let media = [Self.url("initramfs-lts"), Self.url("initramfs-virt")]
        XCTAssertEqual(BootMedia.pair(kernel: "vmlinuz-lts", among: media),
                       .named(Self.url("initramfs-lts")))
    }

    /// Debian et Ubuntu : `vmlinuz-6.8.0-31-generic` et `initrd.img-…`, où le
    /// `.img` est au milieu du nom et non à la fin.
    func testDebianNamesPair() {
        let media = [Self.url("initrd.img-6.8.0-31-generic"), Self.url("initrd.img-6.5.0-9-generic")]
        XCTAssertEqual(BootMedia.pair(kernel: "vmlinuz-6.8.0-31-generic", among: media),
                       .named(Self.url("initrd.img-6.8.0-31-generic")))
    }

    /// Fedora et Arch : le `.img` est à la fin, cette fois.
    func testTheTrailingImgSuffixIsIgnored() {
        let media = [Self.url("initramfs-linux.img")]
        XCTAssertEqual(BootMedia.pair(kernel: "vmlinuz-linux", among: media),
                       .named(Self.url("initramfs-linux.img")))
    }

    /// **Un seul candidat qui ne correspond à rien est quand même le bon.**
    /// C'est le cas courant — un noyau, un initramfs, importés ensemble — et
    /// refuser parce que leurs noms diffèrent servirait la règle plutôt que la
    /// personne. Le choix se nomme autrement pour que l'application puisse le
    /// dire.
    func testTheOnlyOneIsUsedEvenWhenTheNamesDiffer() {
        let media = [Self.url("truc-de-marc")]
        XCTAssertEqual(BootMedia.pair(kernel: "vmlinuz-lts", among: media),
                       .theOnlyOne(Self.url("truc-de-marc")))
    }

    /// **Mais deux qui ne correspondent à rien n'en désignent aucun.** En
    /// choisir un au hasard donnerait un démarrage qui échoue pour une raison
    /// qu'on aurait soi-même fabriquée.
    func testTwoThatMatchNothingChooseNothing() {
        let media = [Self.url("truc-de-marc"), Self.url("machin-de-jean")]
        XCTAssertEqual(BootMedia.pair(kernel: "vmlinuz-lts", among: media), .nothing)
    }

    func testNoMediaAtAllPairsWithNothing() {
        XCTAssertEqual(BootMedia.pair(kernel: "vmlinuz-lts", among: []), .nothing)
    }

    /// Le nom exact l'emporte sur le compte : deux candidats, un seul qui
    /// répond, et c'est lui — pas « il y en a deux, tant pis ».
    func testANamedMatchWinsOverTheCount() {
        let media = [Self.url("machin"), Self.url("initramfs-lts")]
        XCTAssertEqual(BootMedia.pair(kernel: "vmlinuz-lts", among: media),
                       .named(Self.url("initramfs-lts")))
    }
}

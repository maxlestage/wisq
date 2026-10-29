import XCTest
@testable import WisqVM

/// `extlinux.conf`, le chargeur qu'Alpine installe par défaut : voir
/// `CloudBoot.extlinuxEntry`.
final class ExtlinuxEntryTests: XCTestCase {
    /// Ce qu'écrit `update-extlinux` sur un Alpine installé par `setup-disk`.
    static let alpine = """
        DEFAULT menu.c32
        PROMPT 0
        MENU TITLE Alpine/Linux Boot Menu
        MENU HIDDEN
        MENU AUTOBOOT Alpine will be booted automatically in # seconds.
        TIMEOUT 10
        LABEL virt
          MENU DEFAULT
          MENU LABEL Linux virt
          LINUX vmlinuz-virt
          INITRD initramfs-virt
          APPEND root=UUID=0b6c-11 modules=sd-mod,usb-storage,ext4 quiet rootfstype=ext4

        MENU SEPARATOR
        """

    /// L'entrée marquée `MENU DEFAULT` quand `DEFAULT` nomme le menu, avec
    /// ses chemins relatifs au dossier du fichier.
    func testAlpinesEntryIsReadWithItsPathsResolved() throws {
        let entry = try XCTUnwrap(CloudBoot.extlinuxEntry(Self.alpine, in: "/boot"))
        XCTAssertEqual(entry.kernel, "/boot/vmlinuz-virt")
        XCTAssertEqual(entry.initrds, ["/boot/initramfs-virt"])
        XCTAssertEqual(entry.options, ["root=UUID=0b6c-11", "modules=sd-mod,usb-storage,ext4", "quiet",
                                       "rootfstype=ext4"])
    }

    /// `/boot` sur sa propre partition : le fichier est à la racine, et ses
    /// chemins aussi.
    func testASeparateBootPartitionResolvesFromItsRoot() throws {
        let entry = try XCTUnwrap(CloudBoot.extlinuxEntry(Self.alpine, in: "/"))
        XCTAssertEqual(entry.kernel, "/vmlinuz-virt")
        XCTAssertEqual(entry.initrds, ["/initramfs-virt"])
    }

    /// `DEFAULT` qui nomme une entrée l'emporte ; `KERNEL` vaut `LINUX`, et
    /// l'initramfs peut venir d'`APPEND`. Les mots-clés ignorent la casse.
    func testTheNamedDefaultWinsAndInitrdMayComeFromAppend() throws {
        let text = """
            default second
            label first
              linux /vmlinuz-a
            label second
              kernel /vmlinuz-b
              append initrd=/one.img,/two.img root=/dev/vda1
            """
        let entry = try XCTUnwrap(CloudBoot.extlinuxEntry(text, in: "/boot"))
        XCTAssertEqual(entry.kernel, "/vmlinuz-b")
        XCTAssertEqual(entry.initrds, ["/one.img", "/two.img"])
        XCTAssertEqual(entry.options, ["root=/dev/vda1"])
    }

    /// Sans `DEFAULT` utilisable ni entrée marquée, la première qui a un
    /// noyau ; sans noyau du tout, rien.
    func testTheFirstEntryWithAKernelOtherwise() throws {
        let text = "LABEL empty\nLABEL real\n  LINUX /vmlinuz\n"
        XCTAssertEqual(CloudBoot.extlinuxEntry(text, in: "/")?.kernel, "/vmlinuz")
        XCTAssertNil(CloudBoot.extlinuxEntry("DEFAULT x\nLABEL x\n  APPEND quiet\n", in: "/"))
    }
}

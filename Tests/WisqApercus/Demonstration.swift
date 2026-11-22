#if os(iOS)
import CoreGraphics
import Foundation
import UIKit
import WisqCore
@testable import WisqUI
@testable import WisqVM

/// **Les données de démonstration** des aperçus : une bibliothèque, des
/// machines installées, un écran d'invité, des connexions à distance.
///
/// Écrites dans le bac à sable de l'application hôte du simulateur, par les
/// mêmes fonctions que l'application (`InstalledMachines.install`,
/// `KernelLibrary.createBlankDisk`) : la liste les lit comme elle lirait
/// celles de quelqu'un. Les images sont des fichiers creux, qui ne portent
/// que la signature d'un ISO 9660 : assez pour être reconnues, rien à
/// démarrer.
@MainActor
enum Demonstration {
    static let alpine = "alpine-virt-3.22.2-x86_64.iso"
    static let void = "void-live-x86_64-20250202-xfce.iso"
    static let debian = "debian-13.2.0-amd64-netinst.iso"

    /// Tout ce que la VM locale range, et les réglages : chaque scène part
    /// de rien.
    static func toutEffacer() throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try? FileManager.default.removeItem(at: support.appendingPathComponent("Wisq", isDirectory: true))
        if let domaine = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: domaine)
        }
    }

    /// Les machines installées de la démonstration.
    struct Machines {
        let void: InstalledMachine
        let debian: InstalledMachine
    }

    /// Trois images, deux machines installées : un bureau Void Xfce prêt,
    /// session sauvée ; une Debian installée sur son disque vierge.
    @discardableResult
    static func bibliotheque() throws -> Machines {
        try toutEffacer()
        let dossier = try KernelLibrary.directory()
        try iso(dossier.appendingPathComponent(alpine), octets: 63 << 20)
        try iso(dossier.appendingPathComponent(void), octets: 1_400 << 20)
        try iso(dossier.appendingPathComponent(debian), octets: 754 << 20)

        let maintenant = Date()
        let voidMachine = try InstalledMachines.install(
            image: void, name: "Void Xfce", now: maintenant.addingTimeInterval(-86_400 * 3),
            id: "a1b2c3d4e5f6")
        InstalledMachines.markStarted(id: voidMachine.id, at: maintenant.addingTimeInterval(-1_800))
        // La session sauvée : un fichier au nom que `SuspendedMachine` écrit.
        let sessions = try SuspendedMachine.directory()
        try creux(sessions.appendingPathComponent("machine-\(voidMachine.key)-1a2b3c4d5e6f7a8b.wisqvm"),
                  octets: 212 << 20)

        let debianMachine = try InstalledMachines.install(
            image: debian, name: "Debian", now: maintenant.addingTimeInterval(-86_400 * 10),
            id: "0f1e2d3c4b5a")
        InstalledMachines.markStarted(id: debianMachine.id, at: maintenant.addingTimeInterval(-86_400 * 2))
        let disque = try KernelLibrary.createBlankDisk(for: debianMachine, bytes: 8 << 30)
        LocalDisk.attach(disque, forKernel: debianMachine.key)

        KernelMemory.setSize(2 << 30, forKernel: voidMachine.key)
        KernelMemory.setSize(1 << 30, forKernel: debianMachine.key)
        return Machines(
            void: InstalledMachines.machine(id: voidMachine.id) ?? voidMachine,
            debian: InstalledMachines.machine(id: debianMachine.id) ?? debianMachine)
    }

    /// Un fichier creux de `octets`, qui commence comme un ISO 9660 : le
    /// descripteur de volume au secteur 16 (« CD001 »).
    private static func iso(_ url: URL, octets: Int) throws {
        try creux(url, octets: octets)
        let poignee = try FileHandle(forWritingTo: url)
        defer { try? poignee.close() }
        try poignee.seek(toOffset: 16 * 2_048)
        try poignee.write(contentsOf: Data([0x01]) + Data("CD001".utf8) + Data([0x01]))
    }

    private static func creux(_ url: URL, octets: Int) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let poignee = try FileHandle(forWritingTo: url)
        defer { try? poignee.close() }
        try poignee.truncate(atOffset: UInt64(octets))
    }

    // MARK: - L'écran d'une machine

    /// Un écran d'invité immobile : l'image d'un bureau, dessinée une fois.
    final class Ecran: GuestScreen {
        let width: Int
        let height: Int
        let revision: UInt64 = 1
        private let pixels: Data

        init(width: Int = 1_024, height: Int = 768, dessin: (CGContext, CGSize) -> Void) {
            self.width = width
            self.height = height
            let taille = CGSize(width: width, height: height)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let image = UIGraphicsImageRenderer(size: taille, format: format).image { contexte in
                dessin(contexte.cgContext, taille)
            }
            // XRGB8888 petit-boutien, ce que `GuestScreenView.makeImage` lit.
            var octets = Data(count: width * height * 4)
            octets.withUnsafeMutableBytes { tampon in
                let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                if let contexte = CGContext(
                    data: tampon.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info),
                   let cg = image.cgImage {
                    contexte.draw(cg, in: CGRect(origin: .zero, size: taille))
                }
            }
            pixels = octets
        }

        func frame() -> (mode: X86Framebuffer.Mode, data: Data) {
            (X86Framebuffer.Mode(width: width, height: height, bytesPerRow: width * 4, start: 0), pixels)
        }
    }

    /// Un bureau Xfce de démonstration, en formes simples : un fond, le
    /// tableau de bord, un terminal et un gestionnaire de fichiers.
    static func bureauXfce() -> Ecran {
        Ecran { contexte, taille in
            let fond = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(red: 0.10, green: 0.20, blue: 0.36, alpha: 1).cgColor,
                         UIColor(red: 0.16, green: 0.42, blue: 0.52, alpha: 1).cgColor] as CFArray,
                locations: [0, 1])
            if let fond {
                contexte.drawLinearGradient(fond, start: .zero, end: CGPoint(x: taille.width, y: taille.height),
                                            options: [])
            }
            // Le tableau de bord, en haut.
            UIColor(white: 0.12, alpha: 0.95).setFill()
            contexte.fill(CGRect(x: 0, y: 0, width: taille.width, height: 26))
            let barre: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: UIColor.white,
            ]
            NSString(string: "Applications").draw(at: CGPoint(x: 12, y: 5), withAttributes: barre)
            NSString(string: "14:32").draw(at: CGPoint(x: taille.width - 52, y: 5), withAttributes: barre)

            // Les icônes du bureau.
            for (rang, nom) in ["Corbeille", "Système", "Dossier"].enumerated() {
                let y = 52 + CGFloat(rang) * 86
                UIColor(white: 1, alpha: 0.85).setFill()
                UIBezierPath(roundedRect: CGRect(x: 28, y: y, width: 44, height: 40), cornerRadius: 6).fill()
                NSString(string: nom).draw(
                    at: CGPoint(x: 20, y: y + 46),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.white])
            }

            // Un gestionnaire de fichiers.
            fenetre(contexte, CGRect(x: 420, y: 90, width: 520, height: 360), titre: "Dossier personnel",
                    fond: UIColor(white: 0.96, alpha: 1))
            for rang in 0..<8 {
                let colonne = CGFloat(rang % 4), ligne = CGFloat(rang / 4)
                UIColor(red: 0.36, green: 0.55, blue: 0.85, alpha: 1).setFill()
                UIBezierPath(roundedRect: CGRect(x: 450 + colonne * 118, y: 150 + ligne * 120,
                                                 width: 56, height: 46), cornerRadius: 5).fill()
                NSString(string: ["Bureau", "Documents", "Images", "Musique",
                                  "Projets", "Public", "Téléchargements", "Vidéos"][rang]).draw(
                    at: CGPoint(x: 444 + colonne * 118, y: 202 + ligne * 120),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray])
            }

            // Un terminal.
            fenetre(contexte, CGRect(x: 130, y: 300, width: 470, height: 300), titre: "Terminal — anon@void",
                    fond: UIColor(white: 0.08, alpha: 1))
            let lignes = [
                "anon@void:~$ uname -sr", "Linux 6.12.11_1", "anon@void:~$ free -h",
                "        total   utilisé   libre", "Mem:    1,9Gi   412Mi    1,2Gi",
                "anon@void:~$ xbps-query -l | wc -l", "412", "anon@void:~$ █",
            ]
            for (rang, ligne) in lignes.enumerated() {
                NSString(string: ligne).draw(
                    at: CGPoint(x: 142, y: 336 + CGFloat(rang) * 19),
                    withAttributes: [.font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                     .foregroundColor: UIColor(red: 0.75, green: 0.95, blue: 0.75, alpha: 1)])
            }
        }
    }

    private static func fenetre(_ contexte: CGContext, _ cadre: CGRect, titre: String, fond: UIColor) {
        contexte.saveGState()
        contexte.setShadow(offset: CGSize(width: 0, height: 6), blur: 18,
                           color: UIColor(white: 0, alpha: 0.45).cgColor)
        fond.setFill()
        UIBezierPath(roundedRect: cadre, cornerRadius: 6).fill()
        contexte.restoreGState()
        UIColor(white: 0.22, alpha: 1).setFill()
        UIBezierPath(roundedRect: CGRect(x: cadre.minX, y: cadre.minY, width: cadre.width, height: 26),
                     byRoundingCorners: [.topLeft, .topRight], cornerRadii: CGSize(width: 6, height: 6)).fill()
        NSString(string: titre).draw(
            at: CGPoint(x: cadre.minX + 12, y: cadre.minY + 5),
            withAttributes: [.font: UIFont.systemFont(ofSize: 12, weight: .semibold),
                             .foregroundColor: UIColor.white])
    }

    /// Le journal d'un démarrage d'Alpine, à la console série.
    static let consoleAlpine: [String] = [
        "[    0.000000] Linux version 6.12.13-0-virt (buildozer@build-3-21-x86_64)",
        "[    0.000000] Command line: console=ttyS0 modules=loop,squashfs,sd-mod",
        "[    0.412871] virtio_blk virtio1: [vda] 8388608 512-byte logical blocks",
        "[    0.618230] virtio_net virtio0 eth0: renamed from eth0",
        "[    1.204551] Freeing unused kernel image (initmem) memory: 2048K",
        "",
        " * Mounting /proc ... [ ok ]",
        " * Starting networking ...",
        " *   eth0 ... udhcpc: lease of 10.0.2.15 obtained",
        " [ ok ]",
        " * Starting sshd ... [ ok ]",
        "",
        "Welcome to Alpine Linux 3.22",
        "Kernel 6.12.13-0-virt on an x86_64 (/dev/ttyS0)",
        "",
        "localhost login: root",
        "localhost:~# apk add htop",
        "(1/2) Installing ncurses-terminfo-base (6.5_p20250503-r0)",
        "(2/2) Installing htop (3.4.1-r0)",
        "OK: 12 MiB in 27 packages",
        "localhost:~# ",
    ]

    // MARK: - Le téléchargement

    /// Le bureau prêt de la feuille, tel que l'index le donnerait.
    static func bureauPret() -> ReadyDesktop {
        let jour = Date(timeIntervalSince1970: 1_763_078_400)  // 14 novembre 2025
        let index = ReadyDesktop.index
        return ReadyDesktop(
            title: "Void Xfce (prêt)", core: .rust, level: ReadyDesktop.Core.firstRustLevel,
            ramBytes: 2 << 30, kernelDigest: "9c1f0e7a", madeAt: jour,
            image: ImageDownload.Release(
                distribution: "Void Xfce (prêt)", flavor: "ready-image", title: "image",
                version: "2025.11.14", arch: "x86_64", file: void, size: 1_468_006_400,
                checksum: .sha256(String(repeating: "ab", count: 32)), index: index),
            archive: ImageDownload.Release(
                distribution: "Void Xfce (prêt)", flavor: "ready-archive", title: "bureau prêt",
                version: "2025.11.14", arch: "x86_64", file: "void-xfce.wisqmachine", size: 402_653_184,
                checksum: .sha256(String(repeating: "cd", count: 32)), index: index))
    }

    /// Des images de distributions, comme leurs index les donneraient.
    static func images() -> [ImageDownload.Release] {
        let index = URL(string: "https://example.invalid/index")!
        func image(_ distribution: String, _ titre: String, _ version: String, _ fichier: String,
                   _ taille: Int) -> ImageDownload.Release {
            ImageDownload.Release(
                distribution: distribution, flavor: "virt", title: titre, version: version, arch: "x86_64",
                file: fichier, size: taille, checksum: .sha256(String(repeating: "0f", count: 32)),
                index: index)
        }
        return [
            image("Alpine", "virt", "3.22.2", alpine, 66_060_288),
            image("Debian", "nocloud", "13", "debian-13-nocloud-amd64.qcow2", 361_758_720),
            image("Fedora", "Cloud Base", "43", "Fedora-Cloud-Base-Generic-43-1.6.x86_64.qcow2", 525_336_576),
            image("Ubuntu", "minimal cloud", "24.04", "ubuntu-24.04-minimal-cloudimg-amd64.img", 268_435_456),
        ]
    }

    // MARK: - Les connexions à distance

    /// Une bibliothèque de connexions, dans un fichier temporaire et sans
    /// trousseau.
    static func connexions(_ machines: [Machine]) -> MachineLibraryModel {
        let fichier = FileManager.default.temporaryDirectory
            .appendingPathComponent("apercus-machines-\(UUID().uuidString).json")
        let bibliotheque = MachineLibraryModel(
            store: MachineStore(fileURL: fichier), credentials: EphemeralCredentialStore())
        for machine in machines { _ = bibliotheque.save(machine, password: nil) }
        bibliotheque.reload()
        return bibliotheque
    }

    static let machinesDistantes: [Machine] = {
        let maintenant = Date()
        return [
            Machine(name: "Poste de travail", host: "atelier.local", proto: .rdp, security: .tls,
                    guestOS: .windows, tags: ["bureau"], lastConnectedAt: maintenant.addingTimeInterval(-3_600)),
            Machine(name: "VM Fedora (QEMU)", host: "192.168.1.20", port: 5_930, proto: .spice,
                    guestOS: .linux, lastConnectedAt: maintenant.addingTimeInterval(-86_400)),
            Machine(name: "Raspberry Pi", host: "pi.local", proto: .vnc, guestOS: .linux,
                    lastConnectedAt: maintenant.addingTimeInterval(-86_400 * 6)),
            Machine(name: "Mac mini", host: "mini.local", proto: .vnc, security: .tls, guestOS: .macos),
        ]
    }()
}
#endif

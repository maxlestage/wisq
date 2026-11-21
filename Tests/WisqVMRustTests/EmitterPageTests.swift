import Foundation
import WisqVM
@testable import WisqVMRust
import XCTest

/// **La page de la machine de l'émetteur, de bout en bout, sans iPhone.**
///
/// La page (`web/machine.js`, la boucle hôte, la carte, l'émetteur) tourne
/// sous Bun, et **chaque `fetch` qu'elle fait revient ici** : ce test tient le
/// rôle du `WKURLSchemeHandler`, et répond par le même `EmitterStore` que
/// l'application. Les messages qu'elle poste sont lus par le même
/// `EmitterBridge`, et ce qu'on lui envoie est le JavaScript qu'`EmitterBridge`
/// écrit pour WebKit, évalué tel quel. Ce qui reste hors d'atteinte — que
/// WebKit charge les modules et compile sous un schéma à soi — est jugé par
/// `LocalDesktopTests`, dans le job « App iOS ».
///
/// Il faut Bun et le module de la page (`scripts/build-page-emitter.sh`, la
/// cible `wasm32-unknown-unknown`) : sans eux le test saute, **en le disant**.
final class EmitterPageTests: XCTestCase {
    /// Le petit noyau jusqu'à son `hlt` : la RAM posée par le magasin, l'écran
    /// peint par la carte, l'horloge CMOS figée par le plan, et la touche
    /// tapée par le JavaScript que l'application enverrait.
    func testThePageBootsThroughTheStoreAndTheBridge() throws {
        let page = try BunPage.open(name: "petit")
        defer { page.close() }
        let kernel = page.folder.appendingPathComponent("vmlinux")
        try Data(EmitterFixtures.elf(EmitterFixtures.kernel())).write(to: kernel)
        let disk = page.folder.appendingPathComponent("disque.img")
        try Data((0..<8192).map { UInt8($0 % 251) }).write(to: disk)
        let prepared = try EmitterMachine.prepare(
            .init(kernel: kernel, disk: disk, ramBytes: 64 << 20,
                  screen: .init(width: 8, height: 4), clock: 1_795_178_096_000),
            scratch: page.folder)
        try page.start(prepared)

        let ready = try page.wait(for: "prête") { if case .ready = $0 { return true }; return false }
        XCTAssertEqual(ready, .ready(pages: 1024, pieces: 2))
        let screen = try page.wait(for: "l'écran") { if case .screen = $0 { return true }; return false }
        XCTAssertEqual(screen, .screen(width: 8, height: 4))

        // La touche, comme l'application l'enverrait.
        XCTAssertEqual(try page.evaluate(EmitterBridge.typing("a")) as? Int, 2, "« a » enfoncé puis relâché")
        let stopped = try page.wait(for: "l'arrêt") { if case .stopped = $0 { return true }; return false }
        guard case .stopped(let why, _, let refusal) = stopped else { return XCTFail("\(stopped)") }
        XCTAssertEqual(why, "arrêtée sur hlt")
        XCTAssertNil(refusal)

        func register(_ number: Int) throws -> String? {
            try page.evaluate("window.wisq.registre(\(number))") as? String
        }
        XCTAssertEqual(try register(3), "16", "CS à __BOOT_CS dès l'entrée")
        XCTAssertEqual(try register(8), "24", "DS à __BOOT_DS")
        XCTAssertEqual(try register(13), "86", "les secondes de l'horloge figée, 0x56 en BCD")
        XCTAssertEqual(try register(14), "52", "les minutes, 0x34")
        XCTAssertEqual(try register(15), "30", "la touche « a » lue à l'i8042")
        XCTAssertEqual(try register(6), "36864", "RSI sur la page zéro, comme un chargeur")
        XCTAssertEqual(try register(9), String(0x1001_1AF4), "le disque du plan, en virtio-blk sur 00:03.0")
        let console = page.messages.reduce(into: Data()) { said, message in
            if case .console(let octets, _) = message { said.append(octets) }
        }
        XCTAssertEqual(console, Data("W".utf8), "le port série, arrivé par la console de la page")
        // Rouge puis bleu, opaques, en RGBA : le XRGB8888 de la carte converti.
        XCTAssertEqual(
            try page.evaluate("Array.from(globalThis.derniereImage.slice(0, 8))") as? [Int],
            [255, 0, 0, 255, 0, 0, 255, 255])

        // **Le disque, par le client de `carte.js`** contre le magasin : une
        // lecture, une écriture qui reste dans la couche, la lecture d'après.
        let read = try page.evaluate(
            "(async () => Array.from(await disque(8192).lire(250, 4)))()") as? [Int]
        XCTAssertEqual(read, [250, 0, 1, 2])
        XCTAssertEqual(try page.evaluate("disque(8192).ecrire(1022, Uint8Array.from([7, 7, 7, 7]))") as? Bool, true)
        let again = try page.evaluate(
            "(async () => Array.from(await disque(8192).lire(1020, 8)))()") as? [Int]
        XCTAssertEqual(again, [1020 % 251, 1021 % 251, 7, 7, 7, 7, 1026 % 251, 1027 % 251])
        XCTAssertEqual(page.store?.layeredSectors, 2)
        XCTAssertEqual([UInt8](try Data(contentsOf: disk))[1022], UInt8(1022 % 251), "le fichier intact")

        XCTAssertEqual(page.unreadable, 0, "la page et le pont parlent la même langue")
        XCTAssertEqual(page.notFound, [], "la page n'a rien demandé que le magasin n'ait")
    }

    /// **Le chemin de l'application, d'une ISO au `hlt`** : `EmitterMachine.open`
    /// sur une image gravée qui porte le petit noyau, la page sous Bun, l'ISO
    /// servie en disque — son descripteur de volume lu par le client de la
    /// carte, là où un noyau le chercherait.
    func testTheApplicationsPathRunsFromAnISOToTheHalt() throws {
        let page = try BunPage.open(name: "iso")
        defer { page.close() }
        var gravure = IsoGravure()
        gravure.kernel = Data(EmitterFixtures.elf(EmitterFixtures.kernel()))
        let image = try gravure.write()
        defer { try? FileManager.default.removeItem(at: image) }
        let prepared = try EmitterMachine.open(
            image, unpackingInto: page.folder.appendingPathComponent("iso"), ceiling: 4 << 30,
            screen: .init(width: 16, height: 8))
        try page.start(prepared)
        try page.wait(for: "prête") { if case .ready = $0 { return true }; return false }
        try page.wait(for: "l'écran") { if case .screen = $0 { return true }; return false }
        XCTAssertEqual(try page.evaluate(EmitterBridge.key(.escape)) as? Int, 2)
        let stopped = try page.wait(for: "l'arrêt") { if case .stopped = $0 { return true }; return false }
        guard case .stopped(let why, _, _) = stopped else { return XCTFail("\(stopped)") }
        XCTAssertEqual(why, "arrêtée sur hlt")
        XCTAssertEqual(try page.evaluate("window.wisq.registre(15)") as? String, "1", "Échap, le code 1")
        XCTAssertEqual(try page.evaluate("window.wisq.registre(9)") as? String, String(0x1001_1AF4),
                       "l'ISO branchée en disque")
        let volume = try page.evaluate(
            "(async () => Array.from(await disque(\(prepared.diskBytes)).lire(32769, 5)))()") as? [Int]
        XCTAssertEqual(volume.map { String(decoding: $0.map(UInt8.init), as: UTF8.self) }, "CD001")
        XCTAssertEqual(page.notFound, [])
    }

    /// **Une page qui ne trouve pas un morceau s'arrête en le nommant**, au
    /// lieu de partir sur une RAM à moitié posée.
    func testAMissingPieceStopsThePageByName() throws {
        let page = try BunPage.open(name: "manque")
        defer { page.close() }
        let kernel = page.folder.appendingPathComponent("vmlinux")
        try Data(EmitterFixtures.elf(EmitterFixtures.kernel())).write(to: kernel)
        let prepared = try EmitterMachine.prepare(.init(kernel: kernel, ramBytes: 64 << 20), scratch: page.folder)
        // Le noyau disparaît entre le montage et la page.
        try FileManager.default.removeItem(at: kernel)
        try page.start(prepared)
        let failure = try page.wait(for: "la panne") { if case .failure = $0 { return true }; return false }
        guard case .failure(let why) = failure else { return XCTFail("\(failure)") }
        XCTAssertTrue(why.contains("noyau-0 répond 500"), why)
    }

    /// **Alpine depuis son ISO, par le magasin**, quand on en donne une
    /// (`WISQ_EMITTER_ALPINE_ISO`) : `IsoBoot` tire le noyau et l'archive de
    /// l'image, `EmitterMachine` les monte, la page les pose et lit l'ISO par
    /// plages à travers ce test. C'est une mesure, pas une garde : elle dit
    /// combien de temps et de lectures il faut, et où la machine s'arrête —
    /// sous `kernel-entry`, après « Mounting boot media: ok » (JOURNAL, 20
    /// novembre). La ligne est celle des courses du JOURNAL : celle de l'image,
    /// `console=ttyS0` devant.
    func testAlpineBootsFromItsISOThroughTheStore() throws {
        guard let iso = ProcessInfo.processInfo.environment["WISQ_EMITTER_ALPINE_ISO"] else {
            throw XCTSkip("WISQ_EMITTER_ALPINE_ISO absent : pas d'ISO à démarrer")
        }
        let page = try BunPage.open(name: "alpine")
        defer { page.close() }
        let start = Date()
        let boot = try IsoBoot.decide(
            URL(fileURLWithPath: iso), into: page.folder.appendingPathComponent("iso"), ceiling: 4 << 30).get()
        let prepared = try EmitterMachine.prepare(
            .init(kernel: boot.kernel, initrd: boot.initrd, disk: boot.disk,
                  commandLine: "console=ttyS0 modules=loop,squashfs,sd-mod,usb-storage",
                  ramBytes: 512 << 20),
            scratch: page.folder)
        let mounted = Date().timeIntervalSince(start)
        try page.start(prepared)
        let patience = Double(ProcessInfo.processInfo.environment["WISQ_EMITTER_PATIENCE"] ?? "") ?? 1800
        var serial = Data()
        var typed = false
        var media: TimeInterval?
        var shell: TimeInterval?
        let last = try page.wait(for: "l'arrêt ou le shell", patience: patience) { message in
            if case .console(let octets, _) = message { serial.append(octets) }
            let text = String(decoding: serial, as: UTF8.self)
            if media == nil, text.contains("Mounting boot media: ok") { media = Date().timeIntervalSince(start) }
            if !typed, text.contains("login: ") {
                typed = true
                try page.sendSerial("root\n")
            }
            if typed, shell == nil, text.hasSuffix("# ") {
                shell = Date().timeIntervalSince(start)
                return true
            }
            if case .stopped = message { return true }
            return false
        }
        func seconds(_ value: TimeInterval?) -> String { value.map { String(format: "%.1f s", $0) } ?? "jamais" }
        print("""
            Alpine depuis l'ISO, par le magasin : monté en \(seconds(mounted)), \
            « Mounting boot media: ok » à \(seconds(media)), shell à \(seconds(shell)), \
            arrêt : \(last), \(page.store?.reads ?? 0) lectures de l'ISO \
            (\(page.store?.bytesRead ?? 0) octets), \(serial.count) octets de console, \
            ligne « \(prepared.commandLine) »
            """)
        if let out = ProcessInfo.processInfo.environment["WISQ_EMITTER_SERIE"] {
            try? serial.write(to: URL(fileURLWithPath: out))
        }
        XCTAssertNotNil(media, "le noyau monte l'ISO par le magasin :\n\(String(decoding: serial, as: UTF8.self).suffix(3000))")
    }
}

/// **Une page sous Bun, dont les `fetch` reviennent ici.**
///
/// Le protocole, une ligne JSON par message dans chaque sens :
///
/// - Bun → ici : `{ id, methode, url, corps }` (une requête, le corps en
///   base64), `{ message }` (ce que la page poste), `{ n, rendu }` ou
///   `{ n, erreur }` (la valeur d'une évaluation) ;
/// - ici → Bun : `{ id, statut, corps }` (la réponse), `{ n, js }` (une
///   expression à évaluer, attendue si c'est une promesse), `{ serie }` (des
///   octets pour le port série).
final class BunPage: @unchecked Sendable {
    let folder: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var lines: [String] = []
    private let lock = NSCondition()
    private var ended = false
    private var ticket = 0
    private(set) var store: EmitterStore?
    private(set) var messages: [EmitterBridge.Message] = []
    private var pending: [EmitterBridge.Message] = []
    private var results: [Int: Result<Any?, Error>] = [:]
    private(set) var unreadable = 0
    private(set) var notFound: [String] = []

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private init(folder: URL) {
        self.folder = folder
    }

    /// **Bun et le module, ou un saut qui dit lequel manque.**
    static func open(name: String) throws -> BunPage {
        let environment = ProcessInfo.processInfo.environment
        let path = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/bun" }
        let candidates = [environment["WISQ_BUN"], "/root/.bun/bin/bun"]
            + (environment["HOME"].map { ["\($0)/.bun/bin/bun"] } ?? []) + path
        guard let bun = candidates.compactMap({ $0 }).first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw XCTSkip("Bun est absent (WISQ_BUN) : la page n'est jugée par rien ici")
        }
        guard let module = try pageModule() else {
            throw XCTSkip("le module de la page ne se construit pas ici (WISQ_PAGE_MODULE, ou la cible wasm32)")
        }
        let page = BunPage(folder: try EmitterFixtures.folder(name))
        page.module = module
        // **Les fichiers de la page, tels que la bibliothèque les porte** :
        // ceux que le magasin servirait, et pas ceux du dépôt.
        for file in EmitterMachine.pageFiles where file.hasSuffix(".js") {
            try XCTUnwrap(EmitterMachine.asset(file)).write(to: page.folder.appendingPathComponent(file))
        }
        try Data(harness.utf8).write(to: page.folder.appendingPathComponent("banc.mjs"))
        page.bun = bun
        return page
    }

    private var module = Data()
    private var bun = ""

    /// Le module : `WISQ_PAGE_MODULE`, ou construit par le script du dépôt.
    static func pageModule() throws -> Data? {
        if let path = ProcessInfo.processInfo.environment["WISQ_PAGE_MODULE"] {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/bin/bash")
        script.arguments = [root.appendingPathComponent("scripts/build-page-emitter.sh").path, root.path]
        let out = Pipe()
        script.standardOutput = out
        script.standardError = FileHandle.nullDevice
        do { try script.run() } catch { return nil }
        let printed = out.fileHandleForReading.readDataToEndOfFile()
        script.waitUntilExit()
        guard script.terminationStatus == 0 else { return nil }
        let path = String(decoding: printed, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Lancer la page sur cette machine.
    func start(_ prepared: EmitterMachine.Prepared) throws {
        store = prepared.store(module: module)
        process.executableURL = URL(fileURLWithPath: bun)
        process.arguments = [folder.appendingPathComponent("banc.mjs").path]
        process.currentDirectoryURL = folder
        process.standardInput = input
        process.standardOutput = output
        _ = FileManager.default.createFile(atPath: errors.path, contents: nil)
        process.standardError = try FileHandle(forWritingTo: errors)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            self.lock.lock()
            if data.isEmpty {
                self.ended = true
            } else {
                self.buffer.append(data)
                while let newline = self.buffer.firstIndex(of: 0x0A) {
                    self.lines.append(String(decoding: self.buffer[self.buffer.startIndex..<newline], as: UTF8.self))
                    self.buffer.removeSubrange(self.buffer.startIndex...newline)
                }
            }
            self.lock.broadcast()
            self.lock.unlock()
        }
        try process.run()
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: errors)
    }

    /// Ce que Bun a écrit en erreur : la raison d'un banc mort.
    private var errors: URL { folder.appendingPathExtension("err") }
    var errorText: String { (try? String(contentsOf: errors, encoding: .utf8)) ?? "" }

    private func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    /// Une ligne de Bun, ou `nil` au délai ou à la fin.
    private func nextLine(until deadline: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        while lines.isEmpty && !ended {
            if !lock.wait(until: deadline) { return nil }
        }
        return lines.isEmpty ? nil : lines.removeFirst()
    }

    /// **Servir ce qui arrive** : chaque requête répondue par le magasin,
    /// chaque message lu par le pont, jusqu'au délai.
    private func pump(until deadline: Date) throws -> Bool {
        guard let line = nextLine(until: deadline) else { return false }
        guard let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            throw Failure(description: "une ligne illisible : \(line)")
        }
        if let id = object["id"] as? Int, let url = (object["url"] as? String).flatMap(URL.init(string:)) {
            let body = (object["corps"] as? String).flatMap { Data(base64Encoded: $0) }
            let method = object["methode"] as? String ?? "GET"
            let response = store?.respond(method: method, url: url, body: body)
                ?? EmitterStore.Response(status: 503, contentType: "text/plain", body: Data())
            if response.status == 404 { notFound.append(url.absoluteString) }
            try write(["id": id, "statut": response.status, "corps": response.body.base64EncodedString()])
        } else if let message = object["message"] as? [String: Any] {
            do {
                let read = try EmitterBridge.message(from: message)
                messages.append(read)
                pending.append(read)
            } catch {
                unreadable += 1
            }
        } else if let number = object["n"] as? Int {
            if let why = object["erreur"] as? String {
                results[number] = .failure(Failure(description: why))
            } else {
                results[number] = .success(object["rendu"] is NSNull ? nil : object["rendu"])
            }
        }
        return true
    }

    /// Servir jusqu'au premier message que `predicate` accepte.
    @discardableResult
    func wait(
        for what: String, patience: TimeInterval = 60, _ predicate: (EmitterBridge.Message) throws -> Bool
    ) throws -> EmitterBridge.Message {
        let deadline = Date().addingTimeInterval(patience)
        while true {
            while !pending.isEmpty {
                let message = pending.removeFirst()
                if try predicate(message) { return message }
                if case .failure(let why) = message, what != "la panne" {
                    throw Failure(description: "la page est en panne en attendant \(what) : \(why)")
                }
            }
            guard try pump(until: deadline) else {
                throw Failure(description: "\(what) n'est pas venu en \(Int(patience)) s ; reçus : \(messages.suffix(5)) ; Bun : \(errorText.suffix(2000))")
            }
        }
    }

    /// Envoyer une expression sans attendre sa valeur.
    @discardableResult
    func send(_ expression: String) throws -> Int {
        ticket += 1
        try write(["n": ticket, "js": expression])
        return ticket
    }

    /// Des octets pour le port série de l'invité.
    func sendSerial(_ text: String) throws {
        try write(["serie": Data(text.utf8).base64EncodedString()])
    }

    /// **Évaluer une expression dans la page** et rendre sa valeur, en
    /// servant tout ce qui arrive entre-temps.
    func evaluate(_ expression: String, patience: TimeInterval = 30) throws -> Any? {
        let number = try send(expression)
        let deadline = Date().addingTimeInterval(patience)
        while results[number] == nil {
            guard try pump(until: deadline) else {
                throw Failure(description: "« \(expression) » n'a pas rendu sa valeur")
            }
        }
        return try results.removeValue(forKey: number)!.get()
    }

    /// Le banc, côté Bun : la page sans la page.
    static let harness = #"""
    import { demarrer } from "./machine.js";
    import { arriereParUrl } from "./carte.js";
    import { createInterface } from "readline";

    const BASE = "wisq-machine://machine/";
    const ecrire = (objet) => process.stdout.write(JSON.stringify(objet) + "\n");
    let ticket = 0;
    const attente = new Map();
    // Chaque `fetch` part vers le test, qui répond par le magasin.
    const chercher = (url, options = {}) => new Promise((resoudre) => {
      const id = ++ticket;
      attente.set(id, resoudre);
      const corps = options.body ? Buffer.from(options.body).toString("base64") : null;
      ecrire({ id, methode: options.method ?? "GET", url: String(url), corps });
    });
    globalThis.derniereImage = null;
    const peintre = {
      image(largeur, hauteur) {
        if (!this.i || this.i.width !== largeur || this.i.height !== hauteur) {
          this.i = { width: largeur, height: hauteur, data: new Uint8ClampedArray(largeur * hauteur * 4) };
        }
        return this.i;
      },
      montrer() { globalThis.derniereImage = this.i.data; },
    };
    globalThis.disque = (octets) => arriereParUrl(BASE + "disque", octets, { fetch: chercher });
    let conducteur = null;
    createInterface({ input: process.stdin }).on("line", async (ligne) => {
      const m = JSON.parse(ligne);
      if (m.id !== undefined) {
        const resoudre = attente.get(m.id);
        attente.delete(m.id);
        resoudre(new Response(Buffer.from(m.corps, "base64"), { status: m.statut }));
      } else if (m.js !== undefined) {
        try {
          const rendu = await (0, eval)(m.js);
          ecrire({ n: m.n, rendu: rendu === undefined ? null : rendu });
        } catch (raison) {
          ecrire({ n: m.n, erreur: String(raison?.message ?? raison) });
        }
      } else if (m.serie !== undefined && conducteur !== null) {
        conducteur.vm.send(Buffer.from(m.serie, "base64"));
      }
    });
    try {
      conducteur = await demarrer({ base: BASE, chercher, poster: (message) => ecrire({ message }), peintre });
      globalThis.window = { wisq: conducteur };
      conducteur.courir().catch((raison) => ecrire({ message: { kind: "panne", pourquoi: String(raison?.message ?? raison) } }));
    } catch (raison) {
      ecrire({ message: { kind: "panne", pourquoi: String(raison?.message ?? raison) } });
    }
    """#
}

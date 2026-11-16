import XCTest

@testable import WisqVM

/// **Un démarrage refusé avant la première instruction ne touche jamais à une
/// session sauvée.**
///
/// Le défaut, laissé en reste par la reprise sûre (#702) : ces refus passaient
/// par `guestFinished`, l'état valait `ended`, et « Arrêter », resté dans la
/// barre, effaçait la session rangée sous le nom de la course — celui de la
/// course précédente quand le refus tombait avant la lecture de l'image.
/// Chaque chemin de refus de `LocalVMModel.boot` est ici, par son cas de
/// `BootRefusal`, et le dernier test lit `LocalVMModel.swift` pour tenir la
/// liaison, que le compilateur de Linux ne voit pas. Sauf un : la session
/// trop grande pour la mémoire libre passe par `MachineLifecycle.machineSize`,
/// que `MachineLifecycleTests` juge.
final class BootRefusalTests: XCTestCase {
    /// Un exemple de chaque refus, dans l'ordre où `boot` les rencontre.
    static let examples: [BootRefusal] = [
        .notEnoughRoom(requested: 2 << 30, ceiling: 1 << 30),
        .image("L'image ne se déballe pas."),
        .bootMedia,
        .cannotRunHere("Ce noyau est pour ARM."),
        .tooLargeForRiscv(size: 80 << 20, ramSize: 64 << 20),
        .unreadableKernel("Le fichier n'existe pas."),
        .session(.damaged),
        .session(.newerMachine(saved: 9, supported: 8)),
        .pcNeedsMoreRoom(minimumRAM: 0, room: 100 << 20),
        .pcNeedsInitramfs,
        .couldNotStart("Le disque ne se branche pas.", sessionKept: true),
        .couldNotStart("Le chargeur refuse ce noyau.", sessionKept: false),
    ]

    /// Le nom du cas, tel que `LocalVMModel` l'écrit. Le `switch` est
    /// exhaustif : un cas ajouté sans exemple ni nom ne compile pas ici.
    static func name(_ refusal: BootRefusal) -> String {
        switch refusal {
        case .notEnoughRoom: return "notEnoughRoom"
        case .image: return "image"
        case .bootMedia: return "bootMedia"
        case .cannotRunHere: return "cannotRunHere"
        case .tooLargeForRiscv: return "tooLargeForRiscv"
        case .unreadableKernel: return "unreadableKernel"
        case .pcNeedsMoreRoom: return "pcNeedsMoreRoom"
        case .pcNeedsInitramfs: return "pcNeedsInitramfs"
        case .session: return "session"
        case .couldNotStart: return "couldNotStart"
        }
    }

    // MARK: - Le cycle de vie

    /// **Le cœur du défaut** : après chaque refus, « Arrêter » n'efface rien,
    /// la fermeture de l'écran n'écrit rien, et la fin tardive d'une course
    /// précédente — sa tâche passe encore sous le même numéro de course quand
    /// le refus tombe avant le fil — n'efface rien non plus.
    func testNoRefusalBeforeTheFirstInstructionTouchesASavedSession() {
        for refusal in Self.examples {
            var life = MachineLifecycle()
            life.booted()
            XCTAssertEqual(life.refusedToStart(refusal), .nothing, "\(refusal)")
            XCTAssertEqual(life.state, refusal.keepsASession ? .refused : .notStarted, "\(refusal)")
            XCTAssertEqual(life.guestFinished(), .nothing, "la fin tardive d'une autre course : \(refusal)")
            XCTAssertEqual(life.userStopped(), .nothing, "« Arrêter » n'efface rien : \(refusal)")
            XCTAssertEqual(life.steppedAway(), .nothing, "le départ n'écrit rien : \(refusal)")
            for start in [MachineLifecycle.Start.pending, .running, .refused, .failed, .finished] {
                XCTAssertEqual(life.interpreterStopped(after: start), .nothing, "\(refusal), \(start)")
            }
            XCTAssertFalse(life.shouldResumeOnReturn, "rien n'a tourné : \(refusal)")
            XCTAssertFalse(life.reportsGuestExit, "\(refusal)")
            XCTAssertFalse(life.restartsOnReboot, "\(refusal)")
            // Rouvrir la machine est une course neuve.
            life.booted()
            XCTAssertEqual(life.userStopped(), .forget, "\(refusal)")
        }
    }

    /// **La session promise gardée se nomme `refused`**, l'autre refus
    /// `notStarted` : la session illisible, et l'échec du fil quand une
    /// session lisible attendait.
    func testOnlyTheRefusalsThatKeepASessionSayRefused() {
        XCTAssertEqual(Self.examples.filter(\.keepsASession), [
            .session(.damaged),
            .session(.newerMachine(saved: 9, supported: 8)),
            .couldNotStart("Le disque ne se branche pas.", sessionKept: true),
        ])
    }

    /// **Un refus tombé avant la lecture de l'image ne nomme aucune
    /// session.** Le nom vivait dans l'application d'une course à l'autre :
    /// après un refus, celui de la course précédente restait, et « Oublier »,
    /// offert sur lui, effaçait la session d'une autre machine.
    func testARefusalBeforeTheImageIsReadNamesNoSession() {
        var life = MachineLifecycle()
        XCTAssertNil(life.session)
        life.booted()
        life.identified("Image-1a2b")
        XCTAssertEqual(life.session, "Image-1a2b")
        XCTAssertEqual(life.steppedAway(), .save)
        XCTAssertEqual(life.interpreterStopped(after: .running), .save)
        XCTAssertEqual(life.session, "Image-1a2b", "suspendue, elle garde son nom : c'est elle qu'on reprend")

        life.booted()
        XCTAssertNil(life.session, "une course neuve ne sait pas encore quelle image elle a")
        life.refusedToStart(.unreadableKernel("absent"))
        XCTAssertNil(life.session)
        XCTAssertEqual(life.userStopped(), .nothing)
    }

    /// **Un échec que le fil a noté compte avant que sa tâche ne passe** :
    /// « Arrêter » dans l'intervalle n'efface rien. Avant, seul le refus de
    /// la session comptait ; l'échec effaçait.
    func testAFailureTheThreadAlreadySawIsNotForgottenByAStop() {
        var failed = MachineLifecycle()
        failed.booted()
        XCTAssertEqual(failed.userStopped(seen: .failed), .nothing)
        XCTAssertEqual(failed.state, .notStarted)

        var refused = MachineLifecycle()
        refused.booted()
        XCTAssertEqual(refused.userStopped(seen: .refused), .nothing)
        XCTAssertEqual(refused.state, .refused)

        // Une machine que l'interprète a, ou que le fil n'a pas encore jugée,
        // s'arrête pour de bon, comme avant.
        for start in [nil, MachineLifecycle.Start.pending, .running, .finished] {
            var life = MachineLifecycle()
            life.booted()
            XCTAssertEqual(life.userStopped(seen: start), .forget, "\(String(describing: start))")
            XCTAssertEqual(life.state, .ended)
        }
    }

    /// **Une session effacée pendant le démarrage n'est plus promise
    /// gardée.** « Arrêter » ou « Oublier » touché pendant que le fil n'avait
    /// encore rien noté (`Start.pending`) efface la session, comme demandé ;
    /// l'échec ou le refus du fil arrivait ensuite par sa tâche, et la
    /// console affirmait « gardée telle quelle ».
    func testARefusalAfterTheSessionWasErasedPromisesNothing() {
        let name = "vmlinuz-lts"
        for refusal in Self.examples {
            var stopped = MachineLifecycle()
            stopped.booted()
            stopped.identified("Image-1a2b")
            XCTAssertEqual(stopped.userStopped(seen: .pending), .forget, "préalable : « Arrêter » efface")
            var forgot = MachineLifecycle()
            forgot.booted()
            forgot.identified("Image-1a2b")
            forgot.userForgot()
            for var life in [stopped, forgot] {
                let text = life.refusedToStart(refusal, name: name)
                XCTAssertFalse(text.contains("gardée"), "\(refusal) : \(text)")
                XCTAssertEqual(text.contains("effacée pendant le démarrage"), refusal.keepsASession,
                               "\(refusal) : \(text)")
                XCTAssertEqual(life.state, .notStarted, "plus rien de gardé : \(refusal)")
                XCTAssertEqual(life.userStopped(), .nothing, "\(refusal)")
            }
        }

        // Sans effacement, la phrase est celle du refus, promesse comprise —
        // y compris quand « Arrêter » arrive après que le fil a noté l'échec.
        for refusal in Self.examples {
            var life = MachineLifecycle()
            life.booted()
            XCTAssertEqual(life.refusedToStart(refusal, name: name), refusal.explanation(name: name), "\(refusal)")
        }
        var seen = MachineLifecycle()
        seen.booted()
        XCTAssertEqual(seen.userStopped(seen: .failed), .nothing)
        let kept = BootRefusal.couldNotStart("disque absent", sessionKept: true)
        XCTAssertEqual(seen.refusedToStart(kept, name: name), kept.explanation(name: name))
        XCTAssertEqual(seen.state, .refused)

        XCTAssertEqual(BootRefusal.couldNotStart("disque absent", sessionKept: true)
            .explanation(name: name, sessionErased: true),
                       """
                       Démarrage impossible : disque absent

                       La session sauvée de vmlinuz-lts a été effacée pendant le démarrage : la \
                       prochaine ouverture ne reprendra rien.
                       """)
        XCTAssertEqual(BootRefusal.session(.damaged).explanation(name: name, sessionErased: true),
                       """
                       La session de vmlinuz-lts n'a pas pu être relue, et elle a été effacée \
                       pendant le démarrage : la prochaine ouverture ne reprendra rien.
                       """)
    }

    // MARK: - Ce qui est dit

    /// **Chaque refus dit sa raison**, et la phrase des refus qui gardent une
    /// session dit qu'elle est gardée et quel geste l'efface.
    func testEachRefusalSaysWhy() {
        let name = "vmlinuz-lts"
        for refusal in Self.examples {
            let text = refusal.explanation(name: name)
            XCTAssertFalse(text.isEmpty, "\(refusal)")
            if refusal.keepsASession {
                XCTAssertTrue(text.contains("gardée telle quelle"), "\(refusal) : \(text)")
                XCTAssertTrue(text.contains("« Oublier »"), "\(refusal) : \(text)")
            }
        }
        XCTAssertEqual(BootRefusal.unreadableKernel("absent").explanation(name: name),
                       "Démarrage impossible : absent")
        XCTAssertEqual(BootRefusal.couldNotStart("absent", sessionKept: false).explanation(name: name),
                       "Démarrage impossible : absent", "aucune session à promettre")
        XCTAssertEqual(BootRefusal.couldNotStart("disque absent", sessionKept: true).explanation(name: name),
                       """
                       Démarrage impossible : disque absent

                       La session sauvée de vmlinuz-lts est gardée telle quelle : rien ne l'a \
                       remplacée. Pour repartir de zéro, touchez « Oublier », puis rouvrez la machine.
                       """)
        XCTAssertEqual(BootRefusal.session(.damaged).explanation(name: name),
                       SavedSession.explanation(.damaged, name: name))
        XCTAssertEqual(BootRefusal.image("phrase d'IsoBoot").explanation(name: name), "phrase d'IsoBoot")
        XCTAssertEqual(BootRefusal.notEnoughRoom(requested: 2 << 30, ceiling: 1 << 30).explanation(name: name),
                       KernelMemory.notEnoughRoomExplanation(requested: 2 << 30, ceiling: 1 << 30, name: name))
        XCTAssertEqual(BootRefusal.tooLargeForRiscv(size: 80 << 20, ramSize: 64 << 20).explanation(name: name),
                       LinuxMachine.tooLargeExplanation(size: 80 << 20, name: name, ramSize: 64 << 20))
        XCTAssertTrue(BootRefusal.bootMedia.explanation(name: "initramfs-lts").hasPrefix(
            "initramfs-lts est un fichier compressé — wisq le garde comme initramfs."))
        XCTAssertTrue(BootRefusal.pcNeedsInitramfs.explanation(name: name).contains("besoin d'un initramfs"))
    }

    /// Le plancher nommé est celui qui a joué : celui du système de l'image
    /// quand il dépasse celui de la machine PC.
    func testAMachineThatDoesNotFitNamesTheFloorThatCounted() {
        let machine = BootRefusal.pcNeedsMoreRoom(minimumRAM: 0, room: 100 << 20).explanation(name: "bzImage")
        XCTAssertTrue(machine.contains("au moins \(X86Machine.minimumRAMSize >> 20) Mo — son noyau"), machine)
        XCTAssertTrue(machine.contains("n'a que 100 Mo de libre"), machine)
        let system = BootRefusal.pcNeedsMoreRoom(minimumRAM: 512 << 20, room: 100 << 20).explanation(name: "bzImage")
        XCTAssertTrue(system.contains("le système de cette image a besoin d'au moins 512 Mo"), system)
    }

    // MARK: - La liaison

    /// **Chaque refus de `LocalVMModel` passe par `refuseToStart`**, et aucun
    /// par `guestFinished`, qui ne sert plus qu'à la fin d'un invité qui a
    /// tourné. L'exception, la session trop grande pour la mémoire libre,
    /// passe par `life.machineSize`, qui met l'état à `refused`.
    ///
    /// Ce fichier-là ne se compile que pour iOS : seule la CI d'Apple le voit,
    /// et aucun test d'ici ne l'exécute. Ce test en lit donc le **texte**,
    /// sans ses commentaires (`withoutComments`). Il ne remplace pas cette
    /// CI ; il attrape, sous Linux et en un instant, le retour d'un refus par
    /// l'ancien chemin, un refus affiché par un `finish` direct, un appel de
    /// moins (ou de plus) pour un cas — le refus `.session` en a deux, l'un
    /// sur le fil d'émulation —, un cas de `BootRefusal` que personne
    /// n'emploie, et un appel qui n'est plus à sa place : sorti de sa
    /// condition, enfermé dans un bloc qui ne s'exécute pas (`if false {`),
    /// ou séparé du `return` qui le suit (`refusalSites`). Il ne juge pas
    /// le code en amont : un `return` placé plus tôt, ou une valeur changée
    /// avant la condition, lui échappe.
    func testEveryRefusalOfTheAppGoesThroughRefuseToStart() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/WisqUI/ViewModels/LocalVMModel.swift"), encoding: .utf8)
        XCTAssertEqual(source.components(separatedBy: "life.guestFinished()").count - 1, 1,
                       "seule la fin d'un invité qui a tourné passe par guestFinished")
        // **Combien d'appels, cas par cas**, et non « au moins un » : le refus
        // `.session` a deux lieux, le fil principal et le fil d'émulation
        // (la reprise refusée par la machine après un `judge` réussi). Celui
        // du fil remplacé par un `finish` direct laissait l'autre seul tenir
        // l'assertion : rien ne tombait, l'état restait `running`, et
        // « Arrêter » effaçait la session que la console venait de promettre
        // gardée. Un appel ajouté ou retiré change ce tableau, exprès.
        let expected = [
            "notEnoughRoom": 1, "image": 1, "bootMedia": 1, "cannotRunHere": 1,
            "tooLargeForRiscv": 1, "unreadableKernel": 1, "pcNeedsMoreRoom": 1,
            "pcNeedsInitramfs": 1, "session": 2, "couldNotStart": 1,
        ]
        // Les commentaires en moins : ils citent ces appels sans en être.
        // **Tous les commentaires**, pas seulement les lignes qui commencent
        // par `//` : un appel mis entre `/* */` ou derrière `_ = refusal //`
        // était encore compté, et le refus du fil, désactivé ainsi, passait
        // ce test (`withoutComments`).
        let code = Self.withoutComments(source)
        XCTAssertEqual(Set(expected.keys), Set(Self.examples.map(Self.name)), "un compte par cas de BootRefusal")
        for (name, count) in expected {
            let call = try NSRegularExpression(pattern: #"refuseToStart\(\s*\.\#(name)\b"#)
            XCTAssertEqual(call.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code)),
                           count, "appels à refuseToStart(.\(name) dans LocalVMModel")
        }
        XCTAssertEqual(code.components(separatedBy: "refuseToStart(").count - 1,
                       expected.values.reduce(0, +) + 1, "chaque appel est compté, plus la définition")
        // **Chaque appel à sa place**, et non un compte d'occurrences : le
        // refus du fil retiré et un second ajouté sur le fil principal
        // laissaient le compte à deux, et rien ne tombait ; un appel enfermé
        // dans un `if false {` aussi. Chaque appel est donc cherché avec la
        // condition qui le déclenche et le `return` qui le suit, tels quels.
        for (name, site) in Self.refusalSites {
            let pattern = try NSRegularExpression(pattern: Self.pattern(site))
            XCTAssertEqual(pattern.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code)), 1,
                           "le refus .\(name) n'est plus à sa place : \(site)")
        }
        XCTAssertEqual(Dictionary(Self.refusalSites.map { ($0.0, 1) }, uniquingKeysWith: +), expected,
                       "un lieu par appel compté")
        // **Aucun refus par `finish` en direct.** Les seuls `finish(with:`
        // permis hors de la fin d'un invité qui a tourné (celles qui
        // finissent par `+ silence`) sont le corps de `refuseToStart` et
        // l'exception de la session trop grande.
        let direct = code.components(separatedBy: "\n").filter {
            $0.contains("finish(with:") && !$0.contains("+ silence)") && !$0.contains("func finish(with")
        }.map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(direct, [
            "finish(with: SessionMemory.explanation(",
            "finish(with: life.refusedToStart(refusal, name: name))",
        ], "un refus affiché sans passer par refuseToStart")
        // **Le corps de `refuseToStart`**, mot pour mot : c'est la ligne qui
        // porte toute la liaison. Sans elle, l'état restait `running` après
        // chaque refus, et « Arrêter » effaçait — la session illisible promise
        // gardée comprise ; les appels à `refuseToStart` restaient là, et
        // aucune autre assertion de ce test ne tombait.
        let body = try NSRegularExpression(
            pattern: #"private func refuseToStart\(_ refusal: BootRefusal, name: String\) \{\s*"#
                + #"finish\(with: life\.refusedToStart\(refusal, name: name\)\)\s*\}"#)
        XCTAssertNotNil(body.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
                        "refuseToStart dit le refus au cycle de vie, et affiche la phrase qu'il rend")
        XCTAssertTrue(source.contains("life.userStopped(seen: runStart?.recorded)"),
                      "« Arrêter » lit ce que le fil a déjà noté")
        XCTAssertTrue(source.contains("life.identified("), "le nom de la session vient de la course")
        XCTAssertTrue(source.contains("guard let size = life.machineSize(memory) else {"),
                      "la session trop grande pour la mémoire libre est refusée par le cycle de vie")
        // La promesse de l'échec sur le fil vient de la boîte, que
        // `SavedSessionTests` juge ; forcée à vrai ou à faux ici, rien d'autre
        // ne la verrait.
        XCTAssertEqual(source.components(separatedBy: ".couldNotStart(").count - 1, 1,
                       "un seul échec sur le fil")
        XCTAssertTrue(source.contains(".couldNotStart(reason, sessionKept: pending.awaited)"),
                      "l'échec du fil promet la session gardée quand une attendait")
    }

    /// **Chaque lieu de refus de `LocalVMModel`**, tel qu'il s'écrit : la
    /// condition qui le déclenche, l'appel, et le `return` qui suit. Les
    /// espaces y comptent pour « au moins un blanc » (`pattern`).
    static let refusalSites: [(String, String)] = [
        ("notEnoughRoom", """
            if ramSize > roomNow { refuseToStart(.notEnoughRoom(requested: ramSize, ceiling: roomNow), \
            name: kernelURL.lastPathComponent) return }
            """),
        ("image", """
            case .failure(let refusal): refuseToStart( .image(IsoBoot.explanation(refusal, \
            name: kernelURL.lastPathComponent)), name: kernelURL.lastPathComponent) return }
            """),
        ("bootMedia", """
            if kind.core == nil, BootMedia.couldBeMedia(fileAt: kernelURL) { \
            refuseToStart(.bootMedia, name: kernelURL.lastPathComponent) return }
            """),
        ("cannotRunHere", """
            kind, name: bootURL.lastPathComponent) { \
            refuseToStart(.cannotRunHere(refusal), name: kernelURL.lastPathComponent) return }
            """),
        ("tooLargeForRiscv", """
            forRAMSize: KernelMemory.riscvMachine(holding: ramSize)) { refuseToStart( \
            .tooLargeForRiscv(size: size, ramSize: KernelMemory.riscvMachine(holding: ramSize)), \
            name: kernelURL.lastPathComponent) return }
            """),
        ("unreadableKernel", """
            image = try Data(contentsOf: bootURL) } catch { \
            refuseToStart(.unreadableKernel(error.localizedDescription), name: kernelURL.lastPathComponent) \
            return }
            """),
        ("pcNeedsMoreRoom", """
            if machineRAM > Int(roomNow) { refuseToStart( .pcNeedsMoreRoom(minimumRAM: minimumRAM, room: roomNow), \
            name: kernelURL.lastPathComponent) return }
            """),
        ("pcNeedsInitramfs", """
            if ramdisk == nil, saved == nil { refuseToStart(.pcNeedsInitramfs, name: kernelURL.lastPathComponent) \
            return }
            """),
        // Le fil principal : la session que `SavedSession.find` dit illisible.
        ("session", """
            if case .unreadable(let refusal) = session { \
            refuseToStart(.session(refusal), name: kernelURL.lastPathComponent) return }
            """),
        // Le fil d'émulation : la reprise que la machine refuse après un
        // `judge` réussi, notée sur ce fil puis dite sur le fil principal.
        ("session", """
            } catch let refusal as SavedSession.Unreadable { runStart.record(.refused) \
            Task { @MainActor [weak self] in guard let self, thisRun == self.run else { return } \
            self.refuseToStart(.session(refusal), name: kernelURL.lastPathComponent) } return }
            """),
        ("couldNotStart", """
            } catch { runStart.record(.failed) let reason = error.localizedDescription \
            Task { @MainActor [weak self] in guard let self, thisRun == self.run else { return } \
            self.refuseToStart( .couldNotStart(reason, sessionKept: pending.awaited), \
            name: kernelURL.lastPathComponent) } return }
            """),
    ]

    /// Un extrait de code en motif : chaque blanc de l'extrait vaut « au
    /// moins un blanc » dans le source, tout le reste est pris à la lettre.
    static func pattern(_ site: String) -> String {
        site.split(whereSeparator: { $0 == " " || $0 == "\n" })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)
    }

    /// Le source sans ses commentaires : les blocs `/* */` et tout ce qui suit
    /// un `//` hors d'une chaîne. Les chaînes sont lues d'un guillemet à
    /// l'autre, échappements compris ; `LocalVMModel` n'a pas de chaîne sur
    /// plusieurs lignes, et `testCommentsAreStrippedWhereverTheyStand` le
    /// vérifie sur des formes choisies.
    static func withoutComments(_ source: String) -> String {
        var out = ""
        var chars = Array(source)[...]
        var inString = false
        var blockDepth = 0
        while let char = chars.first {
            let next = chars.dropFirst().first
            if blockDepth > 0 {
                if char == "*", next == "/" { blockDepth -= 1; chars = chars.dropFirst(2); continue }
                if char == "/", next == "*" { blockDepth += 1; chars = chars.dropFirst(2); continue }
                if char == "\n" { out.append(char) }
                chars = chars.dropFirst()
                continue
            }
            if inString {
                out.append(char)
                if char == "\\", let next { out.append(next); chars = chars.dropFirst(2); continue }
                if char == "\"" || char == "\n" { inString = false }
                chars = chars.dropFirst()
                continue
            }
            if char == "/", next == "/" {
                chars = chars.drop { $0 != "\n" }
                continue
            }
            if char == "/", next == "*" { blockDepth = 1; chars = chars.dropFirst(2); continue }
            if char == "\"" { inString = true }
            out.append(char)
            chars = chars.dropFirst()
        }
        return out
    }

    /// Les formes de commentaire qui laissaient un appel compté : la ligne
    /// entière en bloc, la fin de ligne, le bloc au milieu d'une ligne ; et
    /// un `//` dans une chaîne, qui n'est pas un commentaire.
    func testCommentsAreStrippedWhereverTheyStand() {
        let call = "self.refuseToStart(.session(refusal), name: kernelURL.lastPathComponent)"
        XCTAssertFalse(Self.withoutComments("    /* \(call) */\n").contains("refuseToStart"))
        XCTAssertFalse(Self.withoutComments("    _ = refusal // \(call)\n").contains("refuseToStart"))
        XCTAssertFalse(Self.withoutComments("a /* b /* \(call) */ c */ d").contains("refuseToStart"),
                       "les blocs s'imbriquent en Swift")
        XCTAssertEqual(Self.withoutComments("a /* b */ c\nd // e\nf"), "a  c\nd \nf")
        XCTAssertEqual(Self.withoutComments(#"let u = "https://x" // y"#), #"let u = "https://x" "#)
        XCTAssertEqual(Self.withoutComments(#"let q = "a\"//b" + c"#), #"let q = "a\"//b" + c"#)
    }
}

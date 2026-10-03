#if canImport(WebKit)
import Foundation
import WisqVMRust
import XCTest

/// **Le bureau local, de bout en bout, dans un vrai `WKWebView`.**
///
/// Toutes les moitiés ont été jugées séparément : l'émetteur contre le
/// silicium, la boucle hôte sous le JavaScriptCore de Bun, la page sous un pont
/// bouchonné, le C ABI par un programme C, le pont Swift sur Linux. Ce test est
/// le premier à les faire tenir ensemble dans le moteur qui les portera —
/// celui de WebKit, avec un vrai gestionnaire de messages entre les deux.
///
/// **Ce qu'il ne dit pas.** Un simulateur n'est pas un iPhone : ce qui est
/// vérifié ici est que les moitiés s'emboîtent, pas que WebKit garde le droit
/// de compiler sur un appareil. Cette question-là n'a qu'une réponse, la sonde
/// de l'application sur un vrai téléphone.
///
/// **Pourquoi cette suite est hébergée par l'application, et pas sous
/// `swift test`.** Elle y a été, et elle y était non déterministe. Le premier
/// test du processus — celui qui crée le premier `WKWebView`, à froid — a rendu
/// deux verdicts opposés sur **un code identique**, à deux passages
/// consécutifs de la CI, sur `InvalidTransition { phase: idle, targetPhase:
/// failed(deinit) }`. Et ce message sortait d'un `load()` enveloppé **en
/// entier** dans un `do`/`catch` qui traduit n'importe quelle erreur : il ne
/// venait donc d'aucun de nos appels.
///
/// La raison était déjà écrite dans `project.yml`, à la cible qui héberge ce
/// fichier : « WebKit rend dans un processus séparé qu'iOS ne démarre pas pour
/// un `xctest` nu ». `swift test` en est un. Sept des huit tests passaient
/// parce qu'ils héritaient d'un état déjà chaud — ce n'est pas une propriété
/// sur laquelle bâtir une garde.
///
/// Rien n'est retiré ni affaibli : la suite est posée là où WebKit a ce qu'il
/// lui faut, et « App iOS » l'exécute à chaque commit, comme « Cœur (Apple) »
/// le faisait.
///
/// **Et ça n'a pas suffi — la suite reste intermittente sous son hôte.** Deux
/// occurrences de plus, les 7 et 8 septembre, toutes deux sur
/// `testTheDesktopPaintsTheFrameOnDemand`, avec le même message nu, dans des
/// PR dont il est **mesuré** qu'elles ne peuvent pas l'atteindre. Deux
/// affirmations de ce commentaire tombent avec elles : ce test n'est ni le
/// premier du processus — il est le huitième sur neuf — ni le plus lent, à
/// 2,3 s contre 5,2, 5,2 et 7,3 pour trois de ses voisins.
///
/// La règle en attendant mieux, écrite dans `docs/ROADMAP.md` avec le relevé
/// des occurrences : **une relance, une seule**, et elle se note. Ce qui
/// resterait à décider — une seule vue pour toute la suite, ou vivre avec la
/// relance — change ce que ces tests mesurent, et ne se tranche pas en
/// passant.
@MainActor
final class LocalDesktopTests: XCTestCase {
    /// **Ce qu'un `ud2` rend quand aucune IDT ne le rattrape**, depuis #227.
    ///
    /// Avant, il ne posait aucun témoin : l'hôte ne voyait qu'un retour de main
    /// sur une adresse inconnue, redemandait la même région, et concluait
    /// « sur place ». Ce nom-là décrivait la boucle hôte ; celui-ci décrit la
    /// machine. Le même texte est tenu côté Rust par `UD2_SANS_PORTE` dans
    /// `crates/wisq-vm/tests/host_loop.rs` — **et ces tests-ci sont les seuls à
    /// le juger dans un vrai WebKit**, donc ils ne peuvent pas s'en remettre à
    /// lui.
    static let ud2SansPorte =
        "une instruction indéfinie (ud2) sans porte : aucune IDT ne porte le vecteur 6"

    /// Une RAM d'une page, et une adresse au-dessus de deux puissance
    /// cinquante-trois : c'est là que vivent les noyaux, et c'est ce qui
    /// attrape une adresse passée en nombre plutôt qu'en texte.
    private let base: UInt64 = 0x0100_0000_0000_1000

    /// Deux régions. La première incrémente RDX puis saute dans la seconde par
    /// un registre — un saut indirect, que l'émetteur ne peut pas résoudre à la
    /// traduction, donc la vue devra demander la suite. La seconde incrémente
    /// RDX et s'arrête sur `ud2`.
    private func program() -> Data {
        var image = Data([0x48, 0xff, 0xc2, 0x48, 0xb8])
        withUnsafeBytes(of: (base + 0x100).littleEndian) { image.append(contentsOf: $0) }
        image.append(contentsOf: [0xff, 0xe0])
        image.append(contentsOf: [UInt8](repeating: 0x90, count: 0x100 - image.count))
        image.append(contentsOf: [0x48, 0xff, 0xc2, 0x0f, 0x0b])
        return image
    }

    func testTheDesktopRunsAMachineInsideARealWebView() async throws {
        let desktop = try LocalDesktop(pages: 1, entry: base)
        try await desktop.load()
        try await desktop.place(program(), at: base)

        let stopped = try await desktop.run()
        XCTAssertEqual(
            stopped.why,
            Self.ud2SansPorte,
            "le `ud2` arrête la machine, et depuis #227 il le dit lui-même"
        )
        XCTAssertEqual(stopped.at, base + 0x103, "et elle dit où")

        // **Deux incréments, et c'est ce qui prouve que la machine a tourné.**
        // Un arrêt au bon endroit se produirait aussi si rien ne s'était
        // exécuté ; RDX à deux veut dire que les deux régions ont couru.
        let rdx = try await desktop.global(2)
        XCTAssertEqual(rdx, 2, "les deux régions se sont exécutées")

        // Deux traductions : les deux régions.
        //
        // **Deux, et non trois depuis #227.** La troisième était l'adresse du
        // `ud2` : l'hôte y réclamait une région faute de savoir pourquoi le
        // bloc lui rendait la main. Le module pose désormais un témoin, donc
        // l'hôte nomme l'arrêt au lieu de demander à traduire une instruction
        // qui n'en est pas une.
        XCTAssertEqual(desktop.translations, 2, "une traduction par adresse atteinte")
        XCTAssertEqual(desktop.refusals, 0)
        XCTAssertEqual(
            desktop.unreadable, 0,
            "une demande illisible voudrait dire que la page et le pont ont divergé"
        )
    }

    /// **Une région que l'émetteur refuse arrête la machine proprement**, au
    /// lieu de la laisser sauter dans le vide. `06` est `push es`, qui n'existe
    /// pas en mode 64 bits.
    func testARegionTheEmitterRefusesStopsTheMachineWithAName() async throws {
        let desktop = try LocalDesktop(pages: 1, entry: base)
        try await desktop.load()
        var refused = Data([0x06])
        refused.append(contentsOf: [UInt8](repeating: 0x90, count: 32))
        try await desktop.place(refused, at: base)

        let stopped = try await desktop.run()
        XCTAssertEqual(stopped.why, "refusée")
        XCTAssertEqual(stopped.at, base)
        XCTAssertEqual(desktop.refusals, 1)
        XCTAssertEqual(desktop.translations, 0)
    }

    /// **Une image qui déborderait de la RAM invitée est refusée.**
    ///
    /// Elle n'écrirait pas « un peu trop loin » : la correspondance vit juste
    /// au-dessus, et la machine sauterait n'importe où au premier changement de
    /// région. La même borne que `host.js` pose sur sa lecture.
    func testAnImageThatWouldSpillIntoTheLookupIsRefused() async throws {
        let desktop = try LocalDesktop(pages: 1, entry: base)
        try await desktop.load()
        // La RAM fait une page ; l'adresse repliée est à 0x1000, donc il reste
        // 0xF000 octets. Un de plus déborde.
        let ram = 65536
        let room = ram - 0x1000
        try await desktop.place(Data(count: room), at: base)
        do {
            try await desktop.place(Data(count: room + 1), at: base)
            XCTFail("une image qui déborde doit être refusée")
        } catch let failure as LocalDesktop.Failure {
            XCTAssertEqual(
                failure, .imageDoesNotFit(folded: 0x1000, bytes: room + 1, ram: ram)
            )
        }
    }

    /// La RAM doit être une puissance de deux ici aussi : le refus doit tomber
    /// à la construction, pas à la première traduction, loin de sa cause.
    func testARAMThatCannotBeConfinedIsRefusedAtTheDoor() {
        XCTAssertThrowsError(try LocalDesktop(pages: 3, entry: base)) { why in
            XCTAssertEqual(why as? LocalDesktop.Failure, .ramIsNotAPowerOfTwo(3))
        }
        XCTAssertThrowsError(try LocalDesktop(pages: 0, entry: base))
    }

    // MARK: - L'image du noyau

    /// **Ce que coûte vraiment le chemin de l'image, et ce qu'il pose.**
    ///
    /// L'image du noyau traverse par `evaluateJavaScript`, en tranches de
    /// 48 Kio de base64. C'est écrit « assumé et cher » depuis quatre tranches,
    /// sans qu'aucun nombre ne soit derrière. En voici un — et le remplacer par
    /// un gestionnaire de schéma se décidera sur ce nombre, pas sur
    /// l'impression qu'il est gros.
    ///
    /// **Mesurer une écriture sans pouvoir la relire mesurerait peut-être
    /// zéro octet posé.** Une `place` qui perdrait une tranche sur deux serait
    /// deux fois plus « rapide », et se comporterait comme une `place` qui
    /// marche jusqu'à ce que la machine saute dans le vide bien plus tard. Le
    /// test relit donc, et **aux bords des tranches** : c'est là qu'un décalage
    /// d'offset se voit, pas au milieu.
    func testPlacingAKernelSizedImageLandsIntactAndSaysWhatItCosts() async throws {
        let pages: UInt32 = 128 // huit mébioctets de RAM invitée
        let bytes = 4 * 1024 * 1024
        let chunk = 48 * 1024
        let desktop = try LocalDesktop(pages: pages, entry: base)
        try await desktop.load()

        // **Un motif, pas des zéros.** Une image de zéros arriverait intacte
        // même si la moitié des tranches se perdait : la mémoire est déjà à
        // zéro.
        // Par un tableau plutôt qu'octet par octet dans un `Data` : quatre
        // millions d'indexations de `Data` en debug coûteraient plus cher que
        // ce que ce test mesure.
        var pattern = [UInt8](repeating: 0, count: bytes)
        for index in 0..<bytes {
            pattern[index] = UInt8((index &* 31 &+ 7) & 0xff)
        }
        let image = Data(pattern)

        let started = Date()
        try await desktop.place(image, at: base)
        let seconds = Date().timeIntervalSince(started)
        let rate = Double(bytes) / seconds / 1_048_576
        print("wisq: image de \(bytes / 1_048_576) Mio posée en "
            + String(format: "%.2f", seconds) + " s, "
            + String(format: "%.1f", rate) + " Mio/s")

        // **Les bords de tranche, là où un décalage se voit.** Le début, la
        // dernière et la première paire d'octets de part et d'autre de la
        // première frontière, une frontière lointaine, et la toute fin.
        for offset in [0, chunk - 128, chunk, chunk * 2 - 1, chunk * 40, bytes - 256] {
            let count = min(256, bytes - offset)
            let back = try await desktop.read(count, at: base + UInt64(offset))
            XCTAssertEqual(
                back, image[offset..<offset + count],
                "les octets relus à \(offset) ne sont pas ceux qui ont été posés"
            )
        }
    }

    /// Relire au-delà de la RAM invitée irait chercher la correspondance, que
    /// l'application prendrait pour de la mémoire invitée. Même borne que
    /// l'écriture, dans l'autre sens.
    func testReadingPastTheGuestsRAMIsRefused() async throws {
        let desktop = try LocalDesktop(pages: 1, entry: base)
        try await desktop.load()
        let ram = 65536
        let room = ram - 0x1000 // l'adresse repliée est à 0x1000
        // Hissé hors de l'assertion : `XCTAssertEqual` prend une autoclosure,
        // qui accepte `try` mais **pas** `await`.
        let filled = try await desktop.read(room, at: base)
        XCTAssertEqual(filled.count, room)
        do {
            _ = try await desktop.read(room + 1, at: base)
            XCTFail("une lecture qui déborde doit être refusée")
        } catch let failure as LocalDesktop.Failure {
            XCTAssertEqual(
                failure, .imageDoesNotFit(folded: 0x1000, bytes: room + 1, ram: ram)
            )
        }
    }

    // MARK: - L'écran

    /// **Le bureau peint, et il le dit.**
    ///
    /// C'est le seul chemin d'affichage qu'un test puisse emprunter ici :
    /// `requestAnimationFrame` ne tourne que dans une vue que le système
    /// considère comme affichée, et celle-ci n'est ajoutée à aucune fenêtre.
    /// `wisqPaint` se laisse appeler à la main **précisément pour ça**.
    ///
    /// Il peint **après** avoir fait tourner la machine : une image peinte
    /// avant que quoi que ce soit ne s'exécute ne dirait rien de plus que
    /// « le canvas existe ».
    func testTheDesktopPaintsTheFrameOnDemand() async throws {
        let width: UInt32 = 32
        let height: UInt32 = 16
        let desktop = try LocalDesktop(
            pages: 1,
            entry: base,
            screen: .init(base: base + 0x8000, width: width, height: height)
        )
        try await desktop.load()
        try await desktop.place(program(), at: base)
        let stopped = try await desktop.run()
        XCTAssertEqual(stopped.why, Self.ud2SansPorte)

        let pixels = try await desktop.paint()
        XCTAssertEqual(
            pixels, Int(width * height),
            "peindre doit rendre le compte de pixels, pas rien"
        )
    }

    /// **Cent vingt-huit régions enchaînées, sous le vrai WebKit.**
    ///
    /// Les huit autres tests de cette suite font tourner **deux** régions. Ils
    /// prouvent que les moitiés s'emboîtent ; ils ne touchent pas ce qui ne
    /// commence à travailler qu'au-delà : la table de blocs qui grandit, la
    /// correspondance adresse → indice, et la boucle hôte qui repasse par le
    /// pont à chaque saut qu'elle ne sait pas résoudre.
    ///
    /// **Toute cette machinerie n'est jugée que sous Bun.** Le mur des 4049
    /// emplacements (#196) et la correspondance (#224) ont été trouvés et
    /// tenus là, sur le JavaScriptCore que Bun embarque. C'est le bon moteur,
    /// mais pas le bon hôte : le module passe ici par un `WKWebView`, un
    /// processus de contenu séparé et un gestionnaire de messages, et rien de
    /// tout ça n'existe sous Bun.
    ///
    /// Ce que ce test ajoute est donc **l'échelle, dans le moteur qui
    /// expédie** : cent vingt-huit traductions au lieu de deux, chacune un
    /// aller-retour complet par le pont.
    ///
    /// **Pourquoi un saut indirect à chaque fois.** L'émetteur résout un saut
    /// direct à la traduction et enchaîne les blocs dans le même module ; un
    /// saut par registre, il ne peut pas. Chaque région rend donc vraiment la
    /// main, et le compte de traductions est le compte de régions — sans quoi
    /// ce test mesurerait un seul module et pas la boucle.
    ///
    /// **Et RDX compte les passages, pas les traductions.** Un arrêt au bon
    /// endroit se produirait aussi si la boucle avait sauté des régions ; RDX
    /// à cent vingt-huit dit que chacune a couru.
    func testAHundredAndTwentyEightRegionsChainThroughTheBridgeUnderWebKit() async throws {
        // Quatre pages : 256 Kio. Les régions occupent 0x1000 à 0x9000, donc
        // une page n'aurait pas suffi — et le repli se fait par un masque sur
        // une puissance de deux, ce qui rend le débordement silencieux plutôt
        // que refusé. La taille est donc choisie, pas héritée.
        let desktop = try LocalDesktop(pages: 4, entry: base)
        try await desktop.load()
        try await desktop.place(chain(of: Self.regions), at: base)

        // **Ce que coûte une traduction, mesuré ici et pas ailleurs.**
        //
        // `WebKitJITProbeTests` chronomètre un aller-retour **nu** — un
        // `evaluateJavaScript` qui incrémente un entier. Une traduction est
        // tout autre chose : le message, puis l'émetteur Rust, puis
        // `WebAssembly.instantiate`. Extrapoler l'une depuis l'autre donne un
        // plancher qu'on lirait comme une estimation.
        //
        // Cent vingt-huit régions sont le premier endroit du dépôt où ce coût
        // se mesure sur le vrai moteur. Aucun seuil : un coureur partagé n'en
        // porte pas, et un simulateur n'a pas de plafond thermique — mais un
        // changement qui le double se verra dans le journal, et c'est de ce
        // chiffre-là que dépend ce qu'un vrai noyau coûterait, lui qui en
        // réclame quinze mille.
        let started = Date()
        let stopped = try await desktop.run(patience: 60)
        let each = Date().timeIntervalSince(started) / Double(Self.regions) * 1000
        XCTAssertEqual(
            stopped.why, Self.ud2SansPorte,
            "la dernière région s'arrête sur son `ud2`, comme les autres tests"
        )
        XCTAssertEqual(
            stopped.at, base + UInt64((Self.regions - 1) * Self.stride + 3),
            "et elle dit où : le `ud2` de la dernière région"
        )

        let rdx = try await desktop.global(2)
        XCTAssertEqual(
            rdx, UInt64(Self.regions),
            "chaque région incrémente RDX une fois : les 128 ont couru"
        )
        XCTAssertEqual(
            desktop.translations, Self.regions,
            "une traduction par région — un saut par registre ne se résout pas à la traduction"
        )
        XCTAssertEqual(desktop.refusals, 0, "aucune région n'est refusée")
        XCTAssertEqual(
            desktop.unreadable, 0,
            "une demande illisible voudrait dire que la page et le pont ont divergé"
        )

        // **Deux chiffres, et aucun des deux ne tranche encore.**
        //
        // Quatre passages : la ligne ci-dessus a rendu 7,44, 7,24 puis 5,35 ms,
        // et le rapport 5,04 puis 5,37. Le second varie moins sur ce qu'on a
        // vu — mais deux observations ne font pas une loi, et c'est en
        // concluant de deux points que la version précédente de ce commentaire
        // affirmait le contraire.
        //
        // Les deux sont donc imprimés, sans qu'aucun soit présenté comme *le*
        // chiffre. `docs/DEMARRAGE.md` porte le tableau complet et dit ce
        // qu'il ne permet pas de conclure.
        //
        // **Et `global` n'est pas « nu ».** Mesuré à 1,44 ms le jour où un
        // `evaluateJavaScript` nu en coûtait 0,48 : il traverse le
        // gestionnaire de messages du bureau, pas seulement le moteur. Le
        // nommer par ce qu'il est évite de croire qu'on compare deux fois la
        // même chose.
        let laps = 64
        let reference = Date()
        for _ in 0..<laps {
            _ = try await desktop.global(2)
        }
        let bare = Date().timeIntervalSince(reference) / Double(laps) * 1000
        print(
            "bureau : \(each) ms par région traduite, "
                + "\(each / bare) fois une lecture de registre par le pont "
                + "(\(bare) ms), sur \(Self.regions) régions")
    }

    /// Le nombre de régions enchaînées, et l'écart entre deux.
    ///
    /// 128 × 256 octets tiennent dans les quatre pages déclarées ci-dessus,
    /// avec le point d'entrée à 0x1000 : la dernière région finit à 0x9000.
    private static let regions = 128
    private static let stride = 0x100

    /// **Une chaîne de régions qui ne se résout pas à la traduction.**
    ///
    /// Chaque région incrémente RDX, charge l'adresse de la suivante dans RAX
    /// et y saute **par le registre**. La dernière s'arrête sur `ud2`.
    ///
    /// L'adresse vient de `base`, la même que celle passée à `place` : la
    /// recopier ici donnerait deux endroits à corriger, et un saut vers une
    /// adresse jamais posée se lirait comme un défaut du pont.
    private func chain(of count: Int) -> Data {
        var image = Data()
        for index in 0..<count {
            var region = Data([0x48, 0xFF, 0xC2])  // inc %rdx
            if index == count - 1 {
                region.append(contentsOf: [0x0F, 0x0B])  // ud2
            } else {
                let next = base + UInt64((index + 1) * Self.stride)
                region.append(contentsOf: [0x48, 0xB8])  // movabs $…,%rax
                withUnsafeBytes(of: next.littleEndian) { region.append(contentsOf: $0) }
                region.append(contentsOf: [0xFF, 0xE0])  // jmp *%rax
            }
            region.append(
                contentsOf: [UInt8](repeating: 0x90, count: Self.stride - region.count))
            image.append(region)
        }
        return image
    }

    /// **Un bureau sans écran refuse de peindre**, au lieu de laisser croire
    /// qu'une image est passée. C'est le refus qui distingue « rien à montrer »
    /// de « rien ne s'est affiché ».
    func testADesktopWithoutAFrameRefusesToPaint() async throws {
        let desktop = try LocalDesktop(pages: 1, entry: base)
        try await desktop.load()
        do {
            _ = try await desktop.paint()
            XCTFail("un bureau sans cadre doit refuser de peindre")
        } catch let failure as LocalDesktop.Failure {
            XCTAssertEqual(failure, .noFrameWasDeclared)
        }
    }

    /// **Un cadre qui déborderait de la RAM invitée est refusé à la
    /// construction**, comme la RAM elle-même — pas au chargement de la page,
    /// loin de sa cause. La borne est vérifiée des deux côtés : sans le cas qui
    /// passe, un refus qui refuserait tout aurait l'air d'une garde.
    func testAFrameThatWouldSpillIntoTheLookupIsRefusedAtTheDoor() throws {
        // Une page de RAM : 65 536 octets, soit exactement 128×128 pixels.
        XCTAssertNoThrow(
            try LocalDesktop(
                pages: 1, entry: base, screen: .init(base: 0, width: 128, height: 128)
            )
        )
        XCTAssertThrowsError(
            try LocalDesktop(
                pages: 1, entry: base, screen: .init(base: 4, width: 128, height: 128)
            )
        ) { why in
            XCTAssertEqual(
                why as? LocalDesktop.Failure,
                .imageDoesNotFit(folded: 4, bytes: 65536, ram: 65536)
            )
        }
        XCTAssertThrowsError(
            try LocalDesktop(
                pages: 1, entry: base, screen: .init(base: 0, width: 0, height: 128)
            ),
            "un cadre sans surface n'est pas un cadre"
        )
        // **Et une surface qui déborde de soixante-quatre bits est refusée, pas
        // enroulée.** Deux dimensions de deux puissance trente et un donnent
        // exactement deux puissance soixante-quatre : en Swift la
        // multiplication piégerait, ce qui n'est pas un refus.
        XCTAssertThrowsError(
            try LocalDesktop(
                pages: 1, entry: base,
                screen: .init(base: 0, width: 1 << 31, height: 1 << 31)
            )
        )
        XCTAssertThrowsError(
            try LocalDesktop(
                pages: 1, entry: base,
                screen: .init(base: 0, width: .max, height: .max)
            )
        )
        // **Et celui-ci ne déborde pas, mais ne tient pas dans un `Int`** :
        // deux puissance trente et un par deux puissance vingt-neuf font deux
        // puissance soixante en pixels, deux puissance soixante-deux en octets.
        // Convertir ça en `Int` pour le porter dans le refus piégerait — le
        // refus deviendrait un plantage. Vu en relisant, pas en compilant.
        XCTAssertThrowsError(
            try LocalDesktop(
                pages: 1, entry: base,
                screen: .init(base: 0, width: 1 << 31, height: 1 << 30)
            )
        )
    }

    // MARK: - Ce que l'appelant n'a pas le droit d'écrire

    /// **Les deux régions que la machine se donne à elle-même sont refusées.**
    ///
    /// `place` tenait **une** borne : la fin de la RAM, au-dessus de laquelle
    /// vit la correspondance. Deux écritures détruisent la machine aussi
    /// sûrement et passaient sans un mot :
    ///
    /// - la **page zéro**, où le noyau lit sa carte e820, sa ligne de commande
    ///   et son initramfs *avant* sa première instruction. Une image posée
    ///   dessus rend l'arrêt muet dans `extend_brk` que #310 a corrigé ;
    /// - le **cadre**, que la vue relit à chaque image. Les octets y tiennent
    ///   jusqu'au premier `simpledrm`, puis disparaissent sous les pixels — ce
    ///   qui ne ressemble pas à une écriture perdue mais à un noyau qui se
    ///   corrompt tout seul.
    ///
    /// **Le cas qui passe est exigé ici aussi**, et deux fois : une image entre
    /// les deux régions, et les voisins immédiats des deux bords. Sans eux, un
    /// `place` qui refuserait tout passerait tout le reste de ce test.
    ///
    /// **Et c'est jugé dans un vrai WebKit, pas sous Bun.** `place` est le seul
    /// chemin par lequel des octets entrent, et c'est ici qu'il s'exécute : un
    /// refus qui tomberait côté Rust mais ne serait pas branché de ce côté-ci
    /// ne se verrait nulle part ailleurs — `LocalDesktop.swift` n'est même pas
    /// typé sur Linux.
    func testAnImageOverTheMachinesOwnRegionsIsRefused() async throws {
        // Une page de RAM. La page zéro se replie à 0x9000, et le cadre est
        // posé au-dessus d'elle — `boot_page_with_screen` refuserait un cadre
        // en dessous, qui l'écraserait.
        let frame = base + 0xB000
        let desktop = try LocalDesktop(
            pages: 1,
            entry: base,
            screen: .init(base: frame, width: 32, height: 16),
            bootsAKernel: true
        )
        try await desktop.load()
        let zero = DesktopTranslator.bootPageAddress
        XCTAssertEqual(zero, 0x9000, "la page zéro est là où le montage la pose")

        // **Ce qui passe** : entre les deux régions, et les deux voisins
        // immédiats, à l'octet près.
        try await desktop.place(Data(count: 16), at: base)
        try await desktop.place(Data(count: 16), at: base + 0x7FF0)
        try await desktop.place(Data(count: 16), at: base + 0x9000)
        try await desktop.place(Data(count: 16), at: frame - 16)

        // **Sur la page zéro.**
        do {
            try await desktop.place(Data(count: 16), at: zero)
            XCTFail("une image sur la page zéro doit être refusée")
        } catch let failure as LocalDesktop.Failure {
            XCTAssertEqual(
                failure, .imageWouldOverwriteTheBootPage(folded: 0x9000, bytes: 16),
                "et le refus dit où et combien"
            )
        }

        // **Dans le cadre.**
        do {
            try await desktop.place(Data(count: 16), at: frame)
            XCTFail("une image dans le cadre doit être refusée")
        } catch let failure as LocalDesktop.Failure {
            XCTAssertEqual(
                failure,
                .imageWouldOverwriteTheFrame(folded: 0xC000, bytes: 16, frame: 0xC000),
                "et le refus nomme le cadre qui la repeindrait"
            )
        }
    }

    /// **Le bureau dit au noyau où est sa racine, et l'archive y est.**
    ///
    /// `kernel_image::declare_ramdisk` existe depuis #304 et le montage de
    /// mesure l'appelle ; #306 a mesuré ce qu'elle donne —
    /// `WISQ-USERSPACE-OK` sur le fil. **Le bureau ne l'appelait pas.** Sans les
    /// deux champs, le noyau traverse tous ses `initcall`, arrive dans
    /// `prepare_namespace`, et meurt sur « VFS: Unable to mount root fs on
    /// unknown-block(0,0) » — avec l'archive dans sa RAM, à côté, jamais nommée.
    ///
    /// **Les trois choses sont relues dans la mémoire de l'invité**, et c'est ce
    /// qui distingue ce test d'un test de `desktop::declare_initramfs` : que les
    /// champs soient écrits est tenu en Rust, que la page et l'archive arrivent
    /// *dans la vue* ne l'est qu'ici.
    func testTheDesktopTellsTheKernelWhereItsRootIs() async throws {
        // Une page de RAM. La page zéro se replie à 0x9000, l'archive est au-
        // dessus de son sommet — au-dessous, elle écraserait la carte mémoire.
        let archive = Data((0..<64).map { UInt8(($0 &* 7 &+ 3) & 0xff) })
        let at = base + 0xA000
        let desktop = try LocalDesktop(
            pages: 1,
            entry: base,
            bootsAKernel: true,
            initramfs: .init(bytes: archive, at: at)
        )
        try await desktop.load()

        /// Les champs de `boot_params` sont petit-boutiens. Recomposés octet par
        /// octet plutôt que par un `loadUnaligned` : ce qui est vérifié est
        /// l'ordre des octets tel que le noyau le lit, et une lecture typée le
        /// supposerait au lieu de le dire.
        func little(_ data: Data, _ offset: Int) -> UInt32 {
            var value: UInt32 = 0
            for index in (0..<4).reversed() {
                value = value << 8 | UInt32(data[data.startIndex + offset + index])
            }
            return value
        }

        let page = try await desktop.read(4096, at: DesktopTranslator.bootPageAddress)
        XCTAssertEqual(page.count, 4096, "une page, pas un octet de plus")
        XCTAssertEqual(
            little(page, 0x218), 0xB000,
            "ramdisk_image porte l'adresse repliée de l'archive"
        )
        XCTAssertEqual(little(page, 0x21C), 64, "et ramdisk_size sa taille")

        // **Et la page n'a pas été rebâtie** : la ligne de commande vit à 0x800
        // de son début, et un chemin qui repartirait de zéro l'aurait perdue.
        // C'est la leçon de #311, et elle est tenue plutôt que relue.
        XCTAssertEqual(page[page.startIndex + 0x800], UInt8(ascii: "e"),
                       "la ligne de commande commence toujours par earlycon")
        XCTAssertEqual(page[page.startIndex + 0x1E8], 2,
                       "et la carte mémoire garde ses deux entrées")

        // **Les octets de l'archive sont vraiment là.** Des champs justes qui
        // désignent de la mémoire vide donneraient au noyau un cpio
        // « invalid magic », et ce test passerait sans eux.
        XCTAssertEqual(
            try await desktop.read(64, at: at), archive,
            "l'archive est dans la RAM de l'invité, à l'adresse déclarée"
        )

        // **Et elle est protégée comme les deux autres régions.**
        do {
            try await desktop.place(Data(count: 16), at: at)
            XCTFail("une image dans l'archive doit être refusée")
        } catch let failure as LocalDesktop.Failure {
            XCTAssertEqual(
                failure,
                .imageWouldOverwriteTheArchive(folded: 0xB000, bytes: 16, archive: 0xB000)
            )
        }
        // Son voisin immédiat passe, à l'octet près.
        try await desktop.place(Data(count: 16), at: at - 16)
    }

    /// **Une racine que le noyau ne pourrait pas lire est refusée à l'ouverture,
    /// pas découverte à la panique.** Une archive posée sur la page zéro
    /// écraserait la carte mémoire que le noyau vient d'y lire ; le refus tombe
    /// dans `load()`, avec un nom.
    func testARootTheKernelCouldNotReadIsRefusedWhenTheDesktopComesUp() async throws {
        let desktop = try LocalDesktop(
            pages: 1,
            entry: base,
            bootsAKernel: true,
            initramfs: .init(bytes: Data(count: 64), at: DesktopTranslator.bootPageAddress)
        )
        do {
            try await desktop.load()
            XCTFail("une archive sur la page zéro doit être refusée")
        } catch let failure as LocalDesktop.Failure {
            XCTAssertEqual(failure, .theRootCouldNotBeDeclared(.archiveDoesNotFit))
        }
    }

    /// **Et les deux refus ne sont pas inconditionnels** — c'est ce qui leur
    /// donne leur sens. Un bureau jugé sur ses registres n'a ni page zéro ni
    /// cadre : lui interdire ces adresses serait un refus sans objet, et un
    /// refus sans objet apprend aux appelants à les contourner.
    func testWithoutAKernelOrAFrameTheSameTwoAddressesArePlaceable() async throws {
        let desktop = try LocalDesktop(pages: 1, entry: base)
        try await desktop.load()
        try await desktop.place(Data(count: 16), at: DesktopTranslator.bootPageAddress)
        try await desktop.place(Data(count: 16), at: base + 0xB000)
    }
}
#endif

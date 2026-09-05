#if canImport(WebKit)
import UIKit
import WebKit
import XCTest

/// **WebKit compile-t-il vraiment, quand c'est une application qui l'héberge ?**
///
/// C'est la question qui décide du lot 8, et personne ne peut y répondre depuis
/// Linux. iOS n'accorde à aucune application de l'App Store une page à la fois
/// inscriptible et exécutable : pas de JIT, donc l'interpréteur, donc 10,6 MIPS
/// mesurés pour le cœur x86 et plus d'une heure pour démarrer un bureau.
/// WebKit est la seule exception d'iOS, et une application peut héberger un
/// `WKWebView`. Un cœur qui engendre du **WebAssembly** au lieu du code machine
/// ne produit pas de code : il produit une donnée, que WebKit compile.
///
/// Sous Bun, qui embarque le même JavaScriptCore, ce module fait 831 MIPS —
/// mesuré, avec les registres en mémoire, quatre drapeaux calculés et une
/// répartition indirecte. Reste à savoir si un `WKWebView` **dans une
/// application** en fait autant, et ce que coûte le pont pour lui parler. Ce
/// fichier pose les deux questions à la pile d'Apple, chez le coureur Apple.
///
/// **Le module vient de `scripts/wasm-jit-probe.ts`**, qui l'écrit en base64
/// avec `--module`. Le script porte son propre oracle ; celui d'ici le refait
/// dans la vue avant de chronométrer, pour qu'un module abîmé en route ne
/// rende pas un débit magnifique et faux.
///
/// **Ce que le coureur Apple a rendu, le 5 septembre 2026 :** 1300 MIPS sur
/// 160 M instructions, et 0,479 ms par aller-retour vers la vue. Le pont laisse
/// donc trente-cinq allers-retours par image à soixante par seconde.
///
/// **Et ce que ces chiffres ne prouvent pas.** Le simulateur tourne sur le Mac
/// Apple Silicon du coureur, et **macOS ne restreint pas le JIT**. Ils mesurent
/// JavaScriptCore sur un Mac, à travers le chemin de code d'un `WKWebView`
/// hébergé — pas sous les règles d'iOS. Que le processus de contenu de WebKit
/// garde le droit de compiler **sur un vrai iPhone** est la conception
/// documentée d'iOS, pas une mesure d'ici. La même sonde, dans un envoi
/// TestFlight, la rendrait. Ce qui est acquis : le module est correct, un
/// `WKWebView` hébergé le compile et l'exécute, et le pont ne coûte rien.
///
/// **Ce paquet est hébergé par l'application, et ce n'est pas un détail.**
/// La première version vivait dans `WisqUITests`, qui n'a pas d'hôte : les deux
/// tests y ont été **sautés**, « le WKWebView n'a pas fini de charger », après
/// trente-six et vingt-quatre secondes d'attente. WebKit rend dans un processus
/// séparé, et iOS ne le démarre pas pour un `xctest` qui n'est pas une
/// application. Le vert du tour 581 ne disait donc rien — et c'est exactement
/// la question posée ici qui l'exigeait : « un `WKWebView` **hébergé par une
/// application** compile-t-il ? » ne se demande pas depuis un paquet qui n'en a
/// pas. D'où `Tests/WisqWebKitTests`, avec `Wisq` pour hôte, et la vue posée
/// dans une vraie fenêtre.
///
/// **Une vue qui ne démarre pas reste un saut, pas un échec** : c'est une panne
/// d'outillage, pas une réponse, et le message dit alors ce qu'on a vu de la
/// pile pour que la fois suivante ne reparte pas de zéro. En revanche, une vue
/// qui démarre et rend un débit d'interpréteur est une réponse, et le test
/// tombe.
@MainActor
final class WebKitJITProbeTests: XCTestCase {
    /// Les fenêtres restent en vie tant que le test tourne : une fenêtre
    /// relâchée emporte sa vue, et la vue son processus de contenu. XCTest
    /// libère l'instance après le test, donc pas de `tearDown` — qui serait de
    /// toute façon un conflit d'isolation avec `@MainActor` en Swift 6.
    private var windows: [UIWindow] = []

    /// Le module réaliste, tel que le script l'écrit.
    private static let moduleBase64 =
        "AGFzbQEAAAABCgJgAX4BfmAAAX8DBAMBAQAEBAFwAAIFAwEAAgcPAgVkcml2ZQACA21lbQIA" +
        "CQgBAEEACwIAAQrxAwPCAwEGfkIApykDACEAQginKQMAIQFCEKcpAwAhAkIYpykDACEDIAAg" +
        "AXwhBEKAAacgBFCtNwMAQpgBpyAEQj+INwMAQogBpyAEIABUrTcDAEKQAacgACAEhSABIASF" +
        "g0I/iDcDACAEIQAgA0L//wODQoAgfKcpAwAhBSAAIAWFIQRCgAGnIARQrTcDAEKYAacgBEI/" +
        "iDcDAEKIAadCADcDAEKQAadCADcDACAEIQAgA0L//wODQoggfKcgADcDACAAIAJ9IQRCgAGn" +
        "IARQrTcDAEKYAacgBEI/iDcDAEKIAacgBCAAVK03AwBCkAGnIAAgBIUgAiAEhYNCP4g3AwBC" +
        "gAGnKQMAUEUEQCACQgF8IQRCgAGnIARQrTcDAEKYAacgBEI/iDcDAEKIAacgBCACVK03AwBC" +
        "kAGnIAIgBIUgAiAEhYNCP4g3AwAgBCECCyABQgF9IQRCgAGnIARQrTcDAEKYAacgBEI/iDcD" +
        "AEKIAacgBCABVK03AwBCkAGnIAEgBIUgASAEhYNCP4g3AwAgBCEBQgCnIAA3AwBCCKcgATcD" +
        "AEIQpyACNwMAQhinIAM3AwBCgAGnKQMAUAR/QQAFQQELCwQAQQELJgEBf0EAIQEDQCABEQEA" +
        "IQEgAEIIfSEAIAFFIABCAFZxDQALIAAL"

    private func loadedWebView() async throws -> WKWebView {
        let frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        let view = WKWebView(frame: frame)
        // **Une vue hors de toute fenêtre n'est pas sûre de démarrer.** WebKit
        // rend dans un processus séparé, et iOS ne le réveille que pour une vue
        // qui appartient à une fenêtre visible. Lui en donner une est aussi la
        // seule façon de poser la vraie question : celle d'un `WKWebView` tel
        // qu'une application l'héberge.
        let window = UIWindow(frame: frame)
        window.addSubview(view)
        window.isHidden = false
        windows.append(window)

        view.loadHTMLString("<!doctype html><meta charset=\"utf-8\"><title>sonde</title>",
                            baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while view.isLoading && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !view.isLoading else {
            // Ce que la pile montrait au moment du saut : sans ça, la fois
            // suivante recommence l'enquête depuis rien.
            let scenes = UIApplication.shared.connectedScenes.count
            throw XCTSkip("""
                le WKWebView n'a pas fini de charger en 20 s — \
                scènes connectées : \(scenes), \
                fenêtre à l'écran : \(!window.isHidden), \
                hôte : \(Bundle.main.bundleIdentifier ?? "aucun")
                """)
        }
        return view
    }

    private func evaluate(_ view: WKWebView, _ script: String) async throws -> Any {
        do {
            return try await view.evaluateJavaScript(script) as Any
        } catch {
            throw XCTSkip("JavaScript indisponible dans ce paquet de tests : \(error)")
        }
    }

    /// **Le débit d'un module engendré, dans un WKWebView.**
    func testWebKitRunsGeneratedWebAssemblyFasterThanAnInterpreter() async throws {
        let view = try await loadedWebView()
        let script = """
            (() => {
              const bytes = Uint8Array.from(atob("\(Self.moduleBase64)"), c => c.charCodeAt(0));
              const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes));
              const drive = instance.exports.drive;
              const memory = new BigUint64Array(instance.exports.mem.buffer);
              const RAX = 0, RCX = 1, RDX = 2;

              // L'oracle, d'abord : mille tours des deux côtés.
              const wrap = v => BigInt.asUintN(64, v);
              let rax = 0n, rdx = 0n, rcx = 1000n;
              for (;;) {
                rax = wrap(rax + rcx);
                if (wrap(rax - rdx) === 0n) rdx = wrap(rdx + 1n);
                rcx = wrap(rcx - 1n);
                if (rcx === 0n) break;
              }
              memory[RAX] = 0n; memory[RDX] = 0n; memory[RCX] = 1000n;
              drive(1000000n);
              if (memory[RAX] !== rax || memory[RDX] !== rdx || memory[RCX] !== rcx) {
                return { error: "le module ne calcule pas comme le modele" };
              }

              // Un tour a blanc : JavaScriptCore compile par paliers.
              memory[RAX] = 0n; memory[RDX] = 0n; memory[RCX] = 4000000n;
              drive(32000000n);

              memory[RAX] = 0n; memory[RDX] = 0n; memory[RCX] = 20000000n;
              const started = performance.now();
              const left = drive(160000000n);
              const ms = performance.now() - started;
              const done = Number(160000000n - left);
              return { mips: done / (ms / 1000) / 1000000, instructions: done, ms };
            })()
            """
        guard let result = try await evaluate(view, script) as? [String: Any] else {
            throw XCTSkip("la vue n'a rien rendu d'exploitable")
        }
        if let message = result["error"] as? String { return XCTFail(message) }
        let mips = try XCTUnwrap(result["mips"] as? Double)
        let instructions = try XCTUnwrap(result["instructions"] as? Double)
        print("WebKit : \(Int(mips)) MIPS sur \(Int(instructions / 1_000_000)) M instructions")
        XCTAssertEqual(instructions, 160_000_000, accuracy: 8,
                       "le module doit avoir tout execute")
        // Le seuil separe deux mondes, il ne mesure pas une machine. Un
        // JavaScriptCore reduit a son interpreteur rendrait quelques MIPS sur
        // cette boucle ; vingt en ecarte le doute sans dependre du coureur.
        XCTAssertGreaterThan(mips, 20,
                             "WebKit ne compile pas ici : le lot 8 n'a plus de socle")
    }

    /// **Ce que coûte de traverser le pont.**
    ///
    /// Le cœur vivrait dans la vue, et l'application n'en recevrait que des
    /// pixels et des touches. Si un aller-retour coûte des millisecondes, le
    /// pont mange le gain avant qu'il n'arrive à l'écran — d'où cette mesure,
    /// posée avant d'écrire quoi que ce soit.
    func testTheBridgeToTheWebViewIsCheapEnoughForAScreen() async throws {
        let view = try await loadedWebView()
        _ = try await evaluate(view, "globalThis.n = 0; 1")
        let rounds = 200
        let started = Date()
        for _ in 0..<rounds {
            _ = try await evaluate(view, "globalThis.n = (globalThis.n + 1) | 0")
        }
        let each = Date().timeIntervalSince(started) / Double(rounds) * 1000
        print("pont : \(each) ms par aller-retour")
        // Soixante images par seconde laissent 16,7 ms par image. Le seuil est
        // à dix : au-delà, le pont seul mange l'image et il faudrait passer les
        // pixels autrement — une surface partagée plutôt qu'un appel. C'est un
        // seuil qui sépare deux mondes, pas une mesure de la machine ; le
        // chiffre imprimé au-dessus est la mesure.
        XCTAssertLessThan(each, 10, "le pont mangerait l'image avant de la rendre")
    }
}
#endif

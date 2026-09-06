#if os(iOS)
import SwiftUI
import WebKit
import WisqCore

/// **La question du bureau local, posée à ton téléphone.**
///
/// Tout le lot 8 repose sur une phrase : « WebKit a le droit de compiler, donc
/// un cœur qui engendre du WebAssembly contourne l'interdiction du JIT ». Elle
/// a été mesurée sous Bun (831 MIPS) et dans un simulateur iPhone (1103), et
/// **ces deux mesures tournent sur un Mac, où le JIT n'est pas restreint**.
/// Que le processus de contenu de WebKit garde le droit de compiler sur un
/// vrai appareil est la conception documentée d'iOS — documentée n'est pas
/// mesurée.
///
/// Cet écran transforme cette inconnue en un chiffre. Il ne sert à rien
/// d'autre, et c'est déjà beaucoup : il décide si le bureau local est
/// possible.
@MainActor
struct WebKitBenchView: View {
    @State private var verdict: WebKitBench.Verdict?
    @State private var running = false
    private let host = BenchHost()

    var body: some View {
        List {
            Section {
                if let verdict {
                    Text(WebKitBench.sentence(for: verdict))
                        .font(.callout)
                } else if running {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Mesure en cours, quelques secondes…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(
                        "Cet écran mesure si WebKit compile le WebAssembly sur cet appareil. "
                        + "C'est la seule chose qui dise si un bureau Linux local est possible.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await measure() }
                } label: {
                    Label(verdict == nil ? "Mesurer" : "Mesurer à nouveau",
                          systemImage: "gauge.with.dots.needle.67percent")
                }
                .disabled(running)
            } footer: {
                Text(
                    "Rien n'est envoyé nulle part : la mesure tourne sur le téléphone et "
                    + "s'affiche ici.")
            }

            if case .compiles(let reading) = verdict {
                Section("Ce qui a été relevé") {
                    LabeledContent("Débit", value: "\(Int(reading.mips)) MIPS")
                    LabeledContent(
                        "Aller-retour",
                        value: String(format: "%.2f ms", reading.bridgeMilliseconds))
                    LabeledContent(
                        "Instructions",
                        value: "\(Int(reading.instructions / 1_000_000)) M")
                }
            }
        }
        .navigationTitle("Le bureau est-il possible ?")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func measure() async {
        running = true
        defer { running = false }
        verdict = await host.run()
    }
}

/// Le `WKWebView` et son script. Séparé de la vue parce qu'une vue SwiftUI est
/// recréée à chaque rendu, et qu'un processus de contenu web qui redémarre à
/// chaque rendu ne mesure rien.
@MainActor
private final class BenchHost {
    private var view: WKWebView?

    /// Le nombre d'instructions que le module doit avoir exécuté. Le vérifier
    /// est ce qui distingue une mesure d'un chiffre : une boucle sortie trop
    /// tôt rendrait un débit magnifique et faux.
    private static let expected: Double = 160_000_000

    func run() async -> WebKitBench.Verdict {
        let web: WKWebView
        if let existing = view {
            web = existing
        } else {
            web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
            web.loadHTMLString("<!doctype html><meta charset=\"utf-8\"><title>banc</title>",
                               baseURL: nil)
            view = web
        }

        let deadline = Date().addingTimeInterval(20)
        while web.isLoading && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !web.isLoading else {
            return .unavailable("la vue web n'a pas fini de charger en vingt secondes")
        }

        // **Le pont d'abord, et à vide.** Ce qui est chronométré ici est le
        // coût d'un aller-retour, pas un calcul : c'est un budget indépendant
        // du débit, et un pont trop cher rend le bureau inutilisable même si
        // le cœur vole.
        let rounds = 100
        for _ in 0..<10 { _ = try? await web.evaluateJavaScript("1") }
        let started = Date()
        for _ in 0..<rounds { _ = try? await web.evaluateJavaScript("1") }
        let bridge = Date().timeIntervalSince(started) / Double(rounds) * 1000

        let result: Any?
        do {
            result = try await web.evaluateJavaScript(Self.script)
        } catch {
            return .unavailable("JavaScript indisponible ici : \(error.localizedDescription)")
        }
        guard let fields = result as? [String: Any] else {
            return .unavailable("la vue n'a rien rendu d'exploitable")
        }
        if fields["error"] != nil { return .wrongResult }
        guard let mips = fields["mips"] as? Double,
              let instructions = fields["instructions"] as? Double
        else {
            return .unavailable("la mesure est revenue incomplète")
        }
        return WebKitBench.judge(
            mips: mips, bridgeMilliseconds: bridge,
            instructions: instructions, expected: Self.expected)
    }

    /// **L'oracle avant le chronomètre.** Le module est refait contre un modèle
    /// écrit en clair ; un module abîmé en route rendrait un débit magnifique
    /// et faux, et personne ne le verrait.
    private static let script = """
        (() => {
          const bytes = Uint8Array.from(atob("\(WebKitBench.moduleBase64)"), c => c.charCodeAt(0));
          const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes));
          const drive = instance.exports.drive;
          const memory = new BigUint64Array(instance.exports.mem.buffer);
          const RAX = 0, RDX = 1, RCX = 2;

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
          const began = performance.now();
          const left = drive(160000000n);
          const ms = performance.now() - began;
          const done = Number(160000000n - left);
          return { mips: done / (ms / 1000) / 1000000, instructions: done };
        })()
        """
}
#endif

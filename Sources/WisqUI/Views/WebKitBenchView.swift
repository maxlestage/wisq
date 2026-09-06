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
    private static let expected =
        Double(WebKitBench.benchTurns * WebKitBench.instructionsPerTurn)

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
        // **Un refus n'est pas une absence de mesure.** Le module importe
        // 768 Mio de RAM invitée ; un appareil qui les refuse répond quelque
        // chose sur ce que wisq engendre, et le ranger dans « indisponible »
        // ferait passer un mur pour un contretemps.
        if let refusal = fields["refused"] as? String { return .refused(refusal) }
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
    ///
    /// **Ce que l'hôte fournit.** Le module de l'émetteur n'est pas autonome :
    /// il **importe** la RAM de l'invité et les vingt-neuf globales qui
    /// portent les registres. C'est ce qui permet à deux régions compilées
    /// séparément de se passer la main sans recopier huit cents mégaoctets —
    /// l'architecture du bureau local, pas un détail de banc. La sonde doit
    /// donc les créer, exactement comme le fera `X86Machine`.
    private static let script = """
        (() => {
          const RAX = 0, RCX = 1, RDX = 2, RBX = 3, RSI = 6;
          const RIP = \(WebKitBench.ripSlot);
          const BASE = \(WebKitBench.benchBase)n;
          const TURNS = \(WebKitBench.benchTurns)n;
          const wrap = v => BigInt.asUintN(64, v);
          // **Une globale `i64` se lit signée.** L'ancien module gardait les
          // registres en mémoire, lue par un `BigUint64Array` ; celui-ci les
          // garde en globales, et JavaScript en rend le complément à deux.
          // Comparer sans repasser en non signé faisait échouer l'oracle sur
          // des valeurs pourtant exactes.
          const u = slot => BigInt.asUintN(64, globals[slot].value);

          let instance, globals;
          try {
            const bytes = Uint8Array.from(atob("\(WebKitBench.moduleBase64)"), c => c.charCodeAt(0));
            const memory = new WebAssembly.Memory({ initial: \(WebKitBench.guestPages) });
            globals = [];
            const env = { mem: memory };
            for (let slot = 0; slot < \(WebKitBench.globalCount); slot++) {
              globals.push(new WebAssembly.Global({ value: "i64", mutable: true }, 0n));
              env["g" + slot] = globals[slot];
            }
            instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), { env });
          } catch (why) {
            return { refused: String(why && why.message ? why.message : why) };
          }
          const run = instance.exports.run;

          // **Chaque passage repart du même état.** RAX et RCX partent non
          // nuls : à zéro, la boucle additionnerait et ouexclusiverait des
          // zéros, et l'oracle ne prouverait rien.
          const seed = () => {
            for (const global of globals) { global.value = 0n; }
            globals[RAX].value = 1n;
            globals[RCX].value = 0x0123456789abcdefn;
          };

          // **Le modèle, écrit en clair.** Cinq instructions, la boucle du
          // banc : addq %rax,%rdx ; xorq %rcx,%rbx ; addq %rdx,%rax ;
          // subq $1,%rsi ; jnz.
          const model = turns => {
            let rax = 1n, rbx = 0n, rcx = 0x0123456789abcdefn, rdx = 0n, rsi = turns;
            for (;;) {
              rdx = wrap(rdx + rax);
              rbx = rbx ^ rcx;
              rax = wrap(rax + rdx);
              rsi = wrap(rsi - 1n);
              if (rsi === 0n) break;
            }
            return { rax, rbx, rdx };
          };

          // **L'échauffement d'abord, l'oracle ensuite.** JavaScriptCore
          // compile par paliers : le premier passage paie son interpréteur puis
          // ses compilateurs. Juger avant l'échauffement vérifierait le palier
          // qu'on ne chronomètre pas — c'est le code optimisé qui doit calculer
          // juste, et c'est celui-là qu'on veut voir se tromper.
          //
          // **Rien ne tient l'échauffement lui-même, et rien ne le peut.** Le
          // supprimer ne fait pas échouer la sonde : le débit baisse de moins
          // de dix pour cent, mesuré sous Bun. Un seuil assez serré pour
          // attraper ça refuserait de répondre sur un téléphone occupé. La
          // mesure est donc juste, l'échauffement la rend seulement fidèle.
          seed();
          globals[RSI].value = 1000000n;
          run(1000008n);

          // **Mille et un tours, pas mille.** Le `xor` rend RBX à sa valeur de
          // départ après un nombre pair de tours : avec mille, l'oracle
          // laisserait passer un module qui ne fait pas le `xor` du tout.
          const oracle = model(1001n);
          seed();
          globals[RSI].value = 1001n;
          run(1009n);
          if (u(RAX) !== oracle.rax || u(RBX) !== oracle.rbx
              || u(RDX) !== oracle.rdx || u(RSI) !== 0n) {
            return { error: "le module ne calcule pas comme le modele" };
          }
          // Et la boucle doit avoir rendu la main **après** sa dernière
          // instruction, pas au milieu : sinon le compte est faux.
          if (u(RIP) !== BASE + 15n) {
            return { error: "le module n'a pas rendu la main a la sortie de la boucle" };
          }

          seed();
          globals[RSI].value = TURNS;
          // **Le compte se lit sur la machine, il ne se déduit pas d'une
          // constante.** RSI porte les tours restants ; le nombre exécuté est
          // la différence entre ce qui a été semé et ce qui reste. Écrire
          // `TURNS * 5` rendrait le débit insensible à une boucle semée trop
          // court — un chiffre deux fois trop beau, et rien pour le dire.
          const seeded = u(RSI);
          const began = performance.now();
          run(TURNS + 8n);
          const ms = performance.now() - began;
          if (u(RSI) !== 0n) {
            return { error: "la boucle chronometree n'est pas allee jusqu'au bout" };
          }
          const done = Number(seeded - u(RSI)) * \(WebKitBench.instructionsPerTurn);
          return { mips: done / (ms / 1000) / 1000000, instructions: done };
        })()
        """
}
#endif

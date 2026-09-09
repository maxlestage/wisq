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
                    LabeledContent(
                        "Deux mémoires", value: reading.multiMemory ? "acceptées" : "refusées")
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
        // **Les deux relevés de la boucle mémoire sont facultatifs.** Zéro veut
        // dire « pas relevé », et `nanosecondsPerAccess` rend alors `nil` plutôt
        // qu'un coût inventé. Les exiger ferait rendre « la mesure est revenue
        // incomplète » à une sonde qui a parfaitement mesuré le débit.
        return WebKitBench.judge(
            mips: mips, bridgeMilliseconds: bridge,
            instructions: instructions, expected: Self.expected,
            multiMemory: fields["multiMemory"] as? Bool ?? false,
            memoryMips: fields["memoryMips"] as? Double ?? 0,
            freeMemoryMips: fields["freeMemoryMips"] as? Double ?? 0)
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
          const RAX = 0, RCX = 1, RDX = 2, RBX = 3, RSI = 6, RDI = 7;
          const RIP = \(WebKitBench.ripSlot);
          const BASE = \(WebKitBench.benchBase)n;
          const TURNS = \(WebKitBench.benchTurns)n;
          const wrap = v => BigInt.asUintN(64, v);

          // **Une mémoire et une table pour les trois modules.** La forme libre
          // en déclare moins que la confinée ; la plus grande des deux sert aux
          // deux, et un module qui n'importe pas la table ne s'offusque pas
          // qu'on la lui tende.
          let memory, blocks;
          const make = base64 => {
            const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
            const globals = [];
            // **Les deux fonctions que tout module émis réclame maintenant.**
            // Ce banc ne fait aucune entrée-sortie, mais un module qui
            // *déclare* un import que l'objet ne porte pas est refusé à
            // l'instanciation, et le refus s'appellerait « la sonde est en
            // panne » plutôt que « il manque `env.out` ».
            const env = { mem: memory, out: () => {}, in: () => 0n, blocks };
            for (let slot = 0; slot < \(WebKitBench.globalCount); slot++) {
              globals.push(new WebAssembly.Global({ value: "i64", mutable: true }, 0n));
              env["g" + slot] = globals[slot];
            }
            const instance = new WebAssembly.Instance(new WebAssembly.Module(bytes), { env });
            // **Une globale `i64` se lit signée.** JavaScript en rend le
            // complément à deux ; comparer sans repasser en non signé faisait
            // échouer l'oracle sur des valeurs pourtant exactes.
            const u = slot => BigInt.asUintN(64, globals[slot].value);
            return { run: instance.exports.run, globals, u };
          };

          let confined, confinedMemory, freeMemory;
          try {
            // **La taille vient de `host_pages`, jamais d'une addition ici.**
            // La RAM de l'invité, la correspondance adresse → indice et le
            // tampon de traduction : un hôte qui en oublie une ne démarre pas,
            // et c'est voulu — un piège WebAssembly est sans retour.
            memory = new WebAssembly.Memory({ initial: \(WebKitBench.hostPages) });
            blocks = new WebAssembly.Table({ element: "anyfunc", initial: 64 });
            confined = make("\(WebKitBench.moduleBase64)");
            confinedMemory = make("\(WebKitBench.memoryModuleBase64)");
            freeMemory = make("\(WebKitBench.freeMemoryModuleBase64)");
          } catch (why) {
            return { refused: String(why && why.message ? why.message : why) };
          }

          // **Chaque passage repart du même état.** RAX et RCX partent non
          // nuls : à zéro, la boucle additionnerait et ouexclusiverait des
          // zéros, et l'oracle ne prouverait rien.
          const seed = module => {
            for (const global of module.globals) { global.value = 0n; }
            module.globals[RAX].value = 1n;
            module.globals[RCX].value = 0x0123456789abcdefn;
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
          // attraper ça refuserait de répondre sur un téléphone occupé.
          seed(confined);
          confined.globals[RSI].value = 1000000n;
          confined.run(1000008n);

          // **Mille et un tours, pas mille.** Le `xor` rend RBX à sa valeur de
          // départ après un nombre pair de tours : avec mille, l'oracle
          // laisserait passer un module qui ne fait pas le `xor` du tout.
          const oracle = model(1001n);
          seed(confined);
          confined.globals[RSI].value = 1001n;
          confined.run(1009n);
          if (confined.u(RAX) !== oracle.rax || confined.u(RBX) !== oracle.rbx
              || confined.u(RDX) !== oracle.rdx || confined.u(RSI) !== 0n) {
            return { error: "le module ne calcule pas comme le modele" };
          }
          // Et la boucle doit avoir rendu la main **après** sa dernière
          // instruction, pas au milieu : sinon le compte est faux.
          if (confined.u(RIP) !== BASE + 15n) {
            return { error: "le module n'a pas rendu la main a la sortie de la boucle" };
          }

          // **La boucle mémoire, et son oracle.** `movq (%rdi),%rax` puis
          // `movq %rax,(%rdi)`, avec RDI à zéro : elle relit ce qu'elle vient
          // d'écrire. Un témoin posé en RAM avant le tour dit si la lecture a
          // vraiment eu lieu — sans lui, une boucle qui ne touche pas la
          // mémoire rendrait les mêmes zéros et passerait.
          const WITNESS = 0x0123456789abcdefn;
          const runMemory = (module, turns, budget) => {
            for (const global of module.globals) { global.value = 0n; }
            new BigUint64Array(memory.buffer, 0, 1)[0] = WITNESS;
            module.globals[RDI].value = 0n;
            module.globals[RSI].value = turns;
            const began = performance.now();
            module.run(budget);
            const ms = performance.now() - began;
            const witnessed = module.u(RAX) === WITNESS
              && new BigUint64Array(memory.buffer, 0, 1)[0] === WITNESS
              && module.u(RSI) === 0n
              && module.u(RIP) === BASE + 12n;
            return { ms, witnessed };
          };

          for (const module of [confinedMemory, freeMemory]) {
            const warm = runMemory(module, 1001n, 1009n);
            if (!warm.witnessed) {
              return { error: "la boucle memoire ne relit pas ce qu'elle ecrit" };
            }
          }

          seed(confined);
          confined.globals[RSI].value = TURNS;
          // **Le compte se lit sur la machine, il ne se déduit pas d'une
          // constante.** RSI porte les tours restants ; le nombre exécuté est
          // la différence entre ce qui a été semé et ce qui reste. Écrire
          // `TURNS * 5` rendrait le débit insensible à une boucle semée trop
          // court — un chiffre deux fois trop beau, et rien pour le dire.
          const seeded = confined.u(RSI);
          const began = performance.now();
          confined.run(TURNS + 8n);
          const ms = performance.now() - began;
          if (confined.u(RSI) !== 0n) {
            return { error: "la boucle chronometree n'est pas allee jusqu'au bout" };
          }
          const done = Number(seeded - confined.u(RSI)) * \(WebKitBench.instructionsPerTurn);

          // **Les deux formes de la boucle mémoire, dos à dos.** Leur écart est
          // ce que le confinement coûte par accès. Séparées par autre chose que
          // quelques microsecondes, elles ne partageraient plus la même charge
          // de machine, et l'écart mesurerait le voisinage plutôt que la forme.
          const perTurn = \(WebKitBench.memoryInstructionsPerTurn);
          const mipsOf = reading =>
            reading.witnessed ? Number(TURNS) * perTurn / (reading.ms / 1000) / 1000000 : 0;
          const confinedRun = runMemory(confinedMemory, TURNS, TURNS + 8n);
          const freeRun = runMemory(freeMemory, TURNS, TURNS + 8n);
          // **Une question à part, posée pendant qu'on est là.** Deux mémoires
          // importées dans un même module : soixante-huit octets, deux pages,
          // et `run` qui lit la seconde. Si l'appareil les accepte, la table
          // qui fait aller vite pourra vivre hors de portée de l'invité ; s'il
          // refuse, il faudra borner les adresses dans les trois cœurs.
          //
          // La valeur attendue compte : un encodage faux fait lire la première
          // mémoire à un décalage de un, ce qui rend un nombre plausible. On
          // compare, on ne se contente pas de « ça n'a pas explosé ».
          let multiMemory = false;
          try {
            const bytes = new Uint8Array([
              0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
              0x01, 0x7f, 0x02, 0x1a, 0x02, 0x03, 0x65, 0x6e, 0x76, 0x05, 0x67, 0x75, 0x65,
              0x73, 0x74, 0x02, 0x00, 0x01, 0x03, 0x65, 0x6e, 0x76, 0x04, 0x73, 0x69, 0x64,
              0x65, 0x02, 0x00, 0x01, 0x03, 0x02, 0x01, 0x00, 0x07, 0x07, 0x01, 0x03, 0x72,
              0x75, 0x6e, 0x00, 0x00, 0x0a, 0x0a, 0x01, 0x08, 0x00, 0x41, 0x00, 0x28, 0x42,
              0x01, 0x00, 0x0b,
            ]);
            const first = new WebAssembly.Memory({ initial: 1 });
            const second = new WebAssembly.Memory({ initial: 1 });
            new Uint32Array(second.buffer)[0] = 0xc0ffee;
            new Uint32Array(first.buffer)[0] = 0xdead;
            const two = new WebAssembly.Instance(new WebAssembly.Module(bytes), {
              env: { guest: first, side: second },
            });
            multiMemory = (two.exports.run() >>> 0) === 0xc0ffee;
          } catch (why) {
            multiMemory = false;
          }

          return {
            mips: done / (ms / 1000) / 1000000,
            instructions: done,
            multiMemory,
            memoryMips: mipsOf(confinedRun),
            freeMemoryMips: mipsOf(freeRun),
          };
        })()
        """
}
#endif

#if os(iOS)
#if WISQ_RUST_CORE
import SwiftUI
import WebKit
import WisqVM
import WisqVMRust

/// **La machine de l'émetteur, à l'écran** : l'image ouverte par
/// `EmitterMachine.open`, la page de la machine dans un `WKWebView`
/// (`EmitterDesktop`), le clavier et la barre des touches vers le clavier de
/// la carte, le doigt sur la tablette (la page le prend elle-même), et la
/// console série dans une feuille.
///
/// **Derrière un réglage éteint par défaut** (`EmitterSetting`) : la liste
/// des machines n'ouvre ici que si on l'a allumé, dans l'écran « Le bureau
/// est-il possible ? ». Tout ce qui décide est dans `WisqVMRust` et jugé sous
/// Linux ; cette vue ne fait que poser les morceaux.
struct EmitterMachineView: View {
    let image: URL

    @State private var model = EmitterMachineModel()
    @State private var showsConsole = false
    @State private var keyboardShown = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let desktop = model.desktop {
                EmitterWebView(view: desktop.view)
                    .ignoresSafeArea(edges: .horizontal)
                // **Le clavier**, matériel ou logiciel : une vue d'un point
                // qui garde le premier répondeur, comme dans les sessions.
                KeyboardCaptureView(
                    showsSoftwareKeyboard: keyboardShown,
                    onText: { model.desktop?.type($0) },
                    onBackspace: {
                        model.desktop?.key(keysym: 0xFF08, down: true)
                        model.desktop?.key(keysym: 0xFF08, down: false)
                    },
                    onKey: { keysym, down in model.desktop?.key(keysym: keysym, down: down) },
                    commandIsSuper: true
                )
                .frame(width: 1, height: 1)
                .opacity(0.01)
            }
            if let note = model.note {
                VStack(spacing: 12) {
                    if model.working { ProgressView() }
                    Text(note)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                }
                .padding(20)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }
        }
        .navigationTitle(image.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Fermer") {
                    model.close()
                    dismiss()
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    keyboardShown.toggle()
                } label: {
                    Image(systemName: keyboardShown ? "keyboard.chevron.compact.down" : "keyboard")
                }
                .accessibilityLabel(keyboardShown ? "Rentrer le clavier" : "Sortir le clavier")
                Button {
                    showsConsole = true
                } label: {
                    Image(systemName: "terminal")
                }
                .accessibilityLabel("Console série")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.desktop != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(TerminalKey.bar, id: \.self) { key in
                            Button(key.label) { model.desktop?.press(key) }
                                .buttonStyle(.bordered)
                                .font(.footnote.monospaced())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                }
                .background(.bar)
            }
        }
        .sheet(isPresented: $showsConsole) {
            NavigationStack {
                ScrollView {
                    Text(model.consoleText.isEmpty ? "L'invité n'a encore rien dit." : model.consoleText)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Console série")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Fermer") { showsConsole = false }
                    }
                }
            }
        }
        .task { await model.open(image) }
    }
}

/// **L'état de l'écran**, et la seule chose qu'il fasse : ouvrir l'image hors
/// du fil principal (décompresser un noyau prend des secondes), puis poser la
/// vue et la démarrer.
@Observable
@MainActor
final class EmitterMachineModel {
    var desktop: EmitterDesktop?
    var note: String? = "Préparation de la machine…"
    var working = true
    var consoleText = ""

    func open(_ image: URL) async {
        guard desktop == nil else { return }
        guard EmitterMachine.isInThisBuild else {
            note = "Cette construction de wisq ne porte pas la machine de l'émetteur."
            working = false
            return
        }
        guard let folder = IsoBoot.folder(in: nil) else {
            note = "Le dossier où déballer l'image ne peut pas être créé."
            working = false
            return
        }
        let ceiling = KernelMemory.ceiling(for: .x86_64)
        let opened = await Task.detached(priority: .userInitiated) {
            () -> Result<EmitterMachine.Prepared, EmitterMachine.Refusal> in
            do {
                return .success(try EmitterMachine.open(image, unpackingInto: folder, ceiling: ceiling))
            } catch let refusal as EmitterMachine.Refusal {
                return .failure(refusal)
            } catch {
                return .failure(.image(error.localizedDescription))
            }
        }.value
        switch opened {
        case .failure(let refusal):
            note = EmitterMachine.explanation(refusal)
            working = false
        case .success(let prepared):
            do {
                let desktop = try EmitterDesktop(prepared: prepared)
                desktop.onChange = { [weak self] in self?.refresh() }
                self.desktop = desktop
                note = "Démarrage…"
                desktop.start()
            } catch {
                note = "La page de la machine ne peut pas être posée : \(error)"
                working = false
            }
        }
    }

    /// Ce que la page vient de dire, relu.
    func refresh() {
        guard let desktop else { return }
        consoleText = String(decoding: desktop.console.suffix(64 * 1024), as: UTF8.self)
        if let failure = desktop.failure {
            note = "La page de la machine est en panne : \(failure)"
            working = false
        } else if let stopped = desktop.stopped {
            note = "La machine s'est arrêtée : \(stopped.why)" + (stopped.refusal.map { " (\($0))" } ?? "")
            working = false
        } else if desktop.screenSize != nil {
            note = nil
        } else if desktop.isReady {
            note = "La machine tourne ; l'écran n'a encore rien peint."
        }
    }

    func close() {
        desktop?.stop()
    }
}

/// La vue de la page, posée telle quelle : elle vit dans `EmitterDesktop`, et
/// SwiftUI ne doit pas en fabriquer une seconde à chaque rendu.
struct EmitterWebView: UIViewRepresentable {
    let view: WKWebView

    func makeUIView(context: Context) -> WKWebView { view }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif
#endif

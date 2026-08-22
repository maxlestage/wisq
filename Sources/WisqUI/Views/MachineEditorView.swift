#if os(iOS)
import SwiftUI
import WisqCore

/// Editable copy of a machine, so cancelling a sheet leaves the library untouched.
@Observable
public final class MachineDraft: Identifiable {
    public let id = UUID()
    public var machine: Machine
    public var password: String
    public var isNew: Bool
    /// Free-form `host` or `host:port` field; the port is split out on save.
    public var address: String

    public init(machine: Machine? = nil) {
        let base = machine ?? Machine(name: "", host: "")
        self.machine = base
        self.password = ""
        self.isNew = machine == nil
        self.address = base.host.isEmpty ? "" : "\(base.host):\(base.port)"
    }
}

public struct MachineEditorView: View {
    @Bindable var draft: MachineDraft
    let library: MachineLibraryModel
    let onClose: () -> Void

    @State private var validationError: String?
    @State private var passwordTouched = false

    public var body: some View {
        Form {
            Section("Machine") {
                TextField("Nom", text: $draft.machine.name)
                    .textInputAutocapitalization(.words)
                TextField("Adresse (hôte ou hôte:port)", text: $draft.address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Picker("Système invité", selection: $draft.machine.guestOS) {
                    ForEach(GuestOS.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }

            Section("Connexion") {
                Picker("Protocole", selection: $draft.machine.proto) {
                    ForEach(RemoteProtocol.allCases, id: \.self) { proto in
                        Text(proto.isImplemented ? proto.displayName : "\(proto.displayName) (bientôt)")
                            .tag(proto)
                    }
                }
                Picker("Chiffrement", selection: $draft.machine.security) {
                    ForEach(TransportSecurity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if draft.machine.proto.requiresUsername {
                    TextField("Utilisateur", text: Binding(
                        get: { draft.machine.username ?? "" },
                        set: { draft.machine.username = $0.isEmpty ? nil : $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }
                SecureField("Mot de passe", text: $draft.password)
                    .onChange(of: draft.password) { passwordTouched = true }
                if draft.machine.security == .none {
                    Label(
                        "Sans chiffrement, le mot de passe VNC et l'image de l'écran circulent en clair. À réserver à un réseau de confiance ou à un tunnel déjà établi.",
                        systemImage: "exclamationmark.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Section("Affichage") {
                Picker("Échelle", selection: $draft.machine.display.scaling) {
                    ForEach(DisplaySettings.Scaling.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Suivre la résolution de l'appareil", isOn: $draft.machine.display.followDeviceResolution)
                Toggle("Mode bas débit", isOn: $draft.machine.display.lowBandwidth)
                Toggle("Garder l'écran allumé", isOn: $draft.machine.display.keepScreenAwake)
            }

            Section("Pointeur et clavier") {
                Picker("Mode", selection: $draft.machine.input.pointerMode) {
                    ForEach(InputSettings.PointerMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                if draft.machine.input.pointerMode == .trackpad {
                    LabeledContent("Vitesse") {
                        Slider(value: $draft.machine.input.pointerSpeed, in: 0.5...4, step: 0.1)
                    }
                }
                Toggle("Défilement naturel", isOn: $draft.machine.input.naturalScrolling)
                Toggle("Inertie", isOn: $draft.machine.input.inertia)
                Toggle("Retour haptique", isOn: $draft.machine.input.hapticFeedback)
                Toggle("⌘ vers la touche Super", isOn: $draft.machine.input.mapCommandToSuper)
            }

            Section {
                gesturePicker("Appui long", selection: $draft.machine.input.longPressAction)
                gesturePicker("Tape à deux doigts", selection: $draft.machine.input.twoFingerTapAction)
                gesturePicker("Glissé à deux doigts", selection: $draft.machine.input.twoFingerPanAction)
                gesturePicker("Glissé à trois doigts", selection: $draft.machine.input.threeFingerPanAction)
                Toggle("Balayage à trois doigts = clavier", isOn: $draft.machine.input.threeFingerSwipeShowsKeyboard)
            } header: {
                Text("Gestes")
            } footer: {
                Text("Un doigt pilote toujours le pointeur. Ce que font deux et trois doigts dépend de votre bureau : déplacer la vue n'a de sens que si l'écran distant ne tient pas sur celui du téléphone.")
            }

            if let validationError {
                Section {
                    Label(validationError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(draft.isNew ? "Nouvelle machine" : draft.machine.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Annuler", action: onClose)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Enregistrer", action: save)
                    .disabled(draft.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func gesturePicker(_ title: String, selection: Binding<GestureAction>) -> some View {
        Picker(title, selection: selection) {
            ForEach(GestureAction.allCases, id: \.self) { Text($0.displayName).tag($0) }
        }
    }

    private func save() {
        let (host, port) = Validation.splitHostPort(draft.address)
        do {
            var machine = draft.machine
            machine.host = try Validation.normalizedHost(host)
            machine.port = try Validation.validatedPort(port ?? machine.proto.defaultPort)
            if machine.name.trimmingCharacters(in: .whitespaces).isEmpty {
                machine.name = machine.host
            }
            // Only write the secret when the field was actually edited, so opening
            // an existing machine and saving does not wipe its stored password.
            library.save(machine, password: passwordTouched ? draft.password : nil)
            onClose()
        } catch let error as WisqError {
            validationError = error.localizedDescription
        } catch {
            validationError = error.localizedDescription
        }
    }
}
#endif

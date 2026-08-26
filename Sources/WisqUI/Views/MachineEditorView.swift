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
    /// Set when the password was filled in from somewhere other than the
    /// keyboard — a connection file, so far.
    ///
    /// The editor only writes the secret when the field was *edited*, so that
    /// opening an existing machine and saving does not wipe its stored
    /// password. An imported ticket is filled in and never touched, so without
    /// this it would be dropped on save: the machine would be created with no
    /// credential, and connecting would ask for a password the user does not
    /// have and cannot guess — it was a one-shot ticket from a server.
    public var passwordCameFilledIn = false
    /// Free-form `host` or `host:port` field; the port is split out on save.
    public var address: String

    // Agent binding, unpacked into editable fields.
    public var agentEnabled: Bool
    public var agentAddress: String
    public var agentVMID: String
    public var agentAutoStart: Bool
    public var agentToken: String

    public init(machine: Machine? = nil) {
        let base = machine ?? Machine(name: "", host: "")
        self.machine = base
        self.password = ""
        self.isNew = machine == nil
        self.address = base.host.isEmpty ? "" : "\(base.host):\(base.port)"
        self.agentEnabled = base.agent != nil
        if let agent = base.agent, let host = agent.baseURL.host {
            self.agentAddress = agent.baseURL.port.map { "\(host):\($0)" } ?? host
        } else {
            self.agentAddress = ""
        }
        self.agentVMID = base.agent?.vmIdentifier ?? ""
        self.agentAutoStart = base.agent?.autoStart ?? true
        self.agentToken = ""
    }

    /// A draft from a connection file somebody sent.
    ///
    /// It is a new machine even though it arrives filled in, and the title has
    /// to say so: `MachineDraft(machine:)` reads a non-nil machine as one the
    /// library already holds, which would head the sheet with a host name and
    /// let it pass for something the user had saved before.
    ///
    /// The password comes in beside the machine rather than inside it, and it
    /// is set here so the editor's field is filled: a one-shot console ticket
    /// is exactly the sort of thing the user wants to see before saving, and
    /// the sort of thing they will never type in by hand.
    public convenience init(imported: ConnectionImport.Imported) {
        self.init(machine: imported.machine)
        self.isNew = true
        self.password = imported.password ?? ""
        self.passwordCameFilledIn = imported.password?.isEmpty == false
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

            Section {
                Toggle("Démarrer via un agent", isOn: $draft.agentEnabled)
                if draft.agentEnabled {
                    TextField("Adresse de l'agent (hôte ou hôte:port)", text: $draft.agentAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Identifiant de la VM", text: $draft.agentVMID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Jeton (laisser vide pour conserver)", text: $draft.agentToken)
                    Toggle("Démarrer la VM à la connexion", isOn: $draft.agentAutoStart)
                }
            } header: {
                Text("Agent hôte")
            } footer: {
                if draft.agentEnabled {
                    Text("À la connexion, wisq demande à l'agent de démarrer la VM si nécessaire, attend sa console, puis s'y connecte — l'adresse et le port ci-dessus sont alors résolus automatiquement.")
                }
            }

            Section("Affichage") {
                Picker("Échelle", selection: $draft.machine.display.scaling) {
                    ForEach(DisplaySettings.Scaling.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Toggle("Suivre la résolution de l'appareil", isOn: $draft.machine.display.followDeviceResolution)
                Toggle("Mode bas débit", isOn: $draft.machine.display.lowBandwidth)
                Toggle("JPEG (avec pertes)", isOn: Binding(
                    get: { draft.machine.display.jpegQuality != nil },
                    set: { draft.machine.display.jpegQuality = $0 ? 6 : nil }
                ))
                if let quality = draft.machine.display.jpegQuality {
                    LabeledContent("Qualité JPEG : \(quality)") {
                        Slider(
                            value: Binding(
                                get: { Double(quality) },
                                set: { draft.machine.display.jpegQuality = Int($0.rounded()) }
                            ),
                            in: 0...9,
                            step: 1
                        )
                    }
                }
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
            var agentToken = ""
            machine.host = try Validation.normalizedHost(host)
            machine.port = try Validation.validatedPort(port ?? machine.proto.defaultPort)
            if machine.name.trimmingCharacters(in: .whitespaces).isEmpty {
                machine.name = machine.host
            }
            if draft.agentEnabled {
                let (agentHost, agentPort) = Validation.splitHostPort(draft.agentAddress)
                let normalizedAgentHost = try Validation.normalizedHost(agentHost)
                let resolvedPort = try Validation.validatedPort(agentPort ?? 7442)
                guard let baseURL = Validation.agentURL(
                    scheme: "http", host: normalizedAgentHost, port: resolvedPort) else {
                    throw WisqError.invalidHost(draft.agentAddress)
                }
                guard !draft.agentVMID.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw WisqError.agentFailure("l'identifiant de la VM est requis")
                }
                // One token per agent host, shared by all its VMs. It is handed
                // to `save` rather than written here: a token written before
                // the machine that references it is a key no machine points
                // at, which puts it out of reach of the reaping too.
                let tokenRef = "agent.\(normalizedAgentHost):\(resolvedPort)"
                agentToken = draft.agentToken
                machine.agent = AgentBinding(
                    baseURL: baseURL,
                    vmIdentifier: draft.agentVMID,
                    autoStart: draft.agentAutoStart,
                    credentialRef: tokenRef
                )
            } else {
                machine.agent = nil
            }
            // Only write the secret when the field was actually edited, so opening
            // an existing machine and saving does not wipe its stored password —
            // or when it arrived filled in from a connection file, which is an
            // edit the user did not have to make.
            let writeSecret = passwordTouched || draft.passwordCameFilledIn
            library.save(
                machine,
                password: writeSecret ? draft.password : nil,
                agentToken: agentToken
            )
            onClose()
        } catch let error as WisqError {
            validationError = error.localizedDescription
        } catch {
            validationError = error.localizedDescription
        }
    }
}
#endif

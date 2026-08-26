#if os(iOS)
import SwiftUI
import WisqCore
import WisqRemote

/// The "my VMs, from my phone" entry point: point at a host agent, see its VMs,
/// tap to add them as machines — endpoint, guest OS and agent binding filled in.
struct AgentImportView: View {
    let library: MachineLibraryModel
    /// Filled from a wisq:// pairing link; the query then fires by itself.
    var prefill: AgentPairing.Payload?
    let onClose: () -> Void

    @State private var address = ""
    @State private var token = ""
    @State private var vms: [AgentVM]?
    @State private var isQuerying = false
    @State private var errorMessage: String?
    @State private var importedIDs: Set<String> = []
    /// From the pairing link only: pinning is a promise the link made, and an
    /// address typed by hand never made it.
    @State private var fingerprint: Data?
    @State private var browser = AgentBrowser()

    var body: some View {
        Form {
            Section {
                TextField("Adresse de l'agent (hôte ou hôte:port)", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                SecureField("Jeton", text: $token)
                Button {
                    query()
                } label: {
                    if isQuerying {
                        ProgressView()
                    } else {
                        Text("Interroger l'agent")
                    }
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isQuerying)
            } header: {
                Text("Agent hôte")
            } footer: {
                Text("Le jeton est affiché par `wisq-agent` à son lancement. Il sera conservé dans le trousseau, une fois par agent.")
            }

            if vms == nil, !browser.agents.isEmpty {
                Section("Agents détectés sur ce réseau") {
                    ForEach(browser.agents) { agent in
                        Button {
                            address = agent.address
                        } label: {
                            Label(agent.name, systemImage: "dot.radiowaves.left.and.right")
                        }
                    }
                }
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            if let vms {
                Section("Machines virtuelles") {
                    if vms.isEmpty {
                        Text("Aucune VM sur cet hôte.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(vms) { vm in
                        Button {
                            importVM(vm)
                        } label: {
                            HStack {
                                Image(systemName: (vm.guestOS ?? .unknown).symbolName)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vm.name)
                                    Text(vm.state.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: importedIDs.contains(vm.id)
                                      ? "checkmark.circle.fill" : "plus.circle")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(importedIDs.contains(vm.id))
                    }
                }
            }
        }
        .navigationTitle("Importer depuis un agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(importedIDs.isEmpty ? "Fermer" : "Terminé", action: onClose)
            }
        }
        .onAppear {
            browser.start()
            if let prefill {
                address = prefill.port == 7442 ? prefill.host : "\(prefill.host):\(prefill.port)"
                token = prefill.token ?? ""
                fingerprint = prefill.certificateFingerprint
                query()
            }
        }
        .onDisappear {
            browser.stop()
        }
    }

    /// The pairing link decides the scheme: a fingerprint means the agent
    /// speaks TLS and the connection pins it; no fingerprint means a pre-0.3
    /// agent, or one deliberately run with --no-tls, and stays plain HTTP. An
    /// address typed by hand has no fingerprint to pin.
    private var agentBaseURL: URL? {
        let (host, port) = Validation.splitHostPort(address)
        guard let normalized = try? Validation.normalizedHost(host) else { return nil }
        let scheme = fingerprint == nil ? "http" : "https"
        return URL(string: "\(scheme)://\(normalized):\(port ?? 7442)")
    }

    private var tokenRef: String? {
        agentBaseURL.map { "agent.\($0.host ?? "")\($0.port.map { ":\($0)" } ?? "")" }
    }

    private func query() {
        guard let baseURL = agentBaseURL else {
            errorMessage = "Adresse invalide."
            return
        }
        isQuerying = true
        errorMessage = nil
        Task {
            defer { isQuerying = false }
            do {
                let client: AgentClient = if let fingerprint {
                    AgentClient(
                        baseURL: baseURL,
                        token: token.isEmpty ? nil : token,
                        pinnedFingerprint: fingerprint
                    )
                } else {
                    AgentClient(baseURL: baseURL, token: token.isEmpty ? nil : token)
                }
                // The token is kept in view state until a VM is imported, not
                // written here: browsing an agent and closing the sheet without
                // adding anything would otherwise leave a key in the keychain
                // that no machine references and no screen offers to remove.
                vms = try await client.listVMs()
            } catch let error as WisqError {
                vms = nil
                errorMessage = error.localizedDescription
            } catch {
                vms = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importVM(_ vm: AgentVM) {
        guard let baseURL = agentBaseURL, let host = baseURL.host else { return }
        let machine = Machine(
            name: vm.name,
            host: host,
            port: vm.consolePort ?? (vm.consoleProtocol ?? .vnc).defaultPort,
            proto: vm.consoleProtocol ?? .vnc,
            guestOS: vm.guestOS ?? .unknown,
            agent: AgentBinding(
                baseURL: baseURL,
                vmIdentifier: vm.id,
                autoStart: true,
                credentialRef: token.isEmpty ? nil : tokenRef,
                certificateFingerprint: fingerprint
            )
        )
        library.save(machine, password: nil, agentToken: token)
        importedIDs.insert(vm.id)
    }
}
#endif

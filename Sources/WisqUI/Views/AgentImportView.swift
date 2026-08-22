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
                query()
            }
        }
        .onDisappear {
            browser.stop()
        }
    }

    /// v1 agents speak plain HTTP behind a token; the URL is built accordingly.
    private var agentBaseURL: URL? {
        let (host, port) = Validation.splitHostPort(address)
        guard let normalized = try? Validation.normalizedHost(host) else { return nil }
        return URL(string: "http://\(normalized):\(port ?? 7442)")
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
                let client = AgentClient(baseURL: baseURL, token: token.isEmpty ? nil : token)
                vms = try await client.listVMs()
                // The token worked: keep it, keyed per agent so every VM on this
                // host shares the one secret.
                if let tokenRef, !token.isEmpty {
                    try? library.credentialStore.setSecret(token, for: tokenRef)
                }
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
                credentialRef: token.isEmpty ? nil : tokenRef
            )
        )
        library.save(machine, password: nil)
        importedIDs.insert(vm.id)
    }
}
#endif

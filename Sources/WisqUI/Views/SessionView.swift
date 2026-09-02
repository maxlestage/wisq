#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WisqCore
import WisqRemote

/// A live session, full screen. Chrome stays out of the way and comes back on tap.
public struct SessionView: View {
    @State private var model: SessionModel
    @State private var showChrome = true
    @State private var keyboardVisible = false
    @State private var showKeyBar = false
    @State private var choosingFileToSend = false
    @Environment(\.dismiss) private var dismiss

    private let library: MachineLibraryModel

    public init(machine: Machine, library: MachineLibraryModel) {
        self._model = State(initialValue: SessionModel(machine: machine))
        self.library = library
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if model.status.isLive {
                RemoteDisplayView(model: model) { wantsKeyboard in
                    keyboardVisible = wantsKeyboard
                }
                .ignoresSafeArea()
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) { showChrome.toggle() }
                }
            } else {
                StatusOverlay(model: model, onRetry: connect, onClose: close)
            }

            // Always mounted: it carries the hardware keyboard too, not just the
            // on-screen one.
            KeyboardCaptureView(
                showsSoftwareKeyboard: keyboardVisible,
                onText: { model.type($0) },
                onBackspace: { model.press(Keysym.backspace) },
                onKey: { keysym, down in model.setKey(keysym, down: down) },
                commandIsSuper: model.machine.input.mapCommandToSuper
            )
            .frame(width: 0, height: 0)

            VStack {
                if showChrome { topBar }
                // Shown even with the chrome hidden: a transfer ends long
                // after the tap that started it, and its outcome should not
                // depend on whether the bar happens to be out.
                if model.fileSend != nil { fileSendBanner }
                Spacer()
                if showKeyBar, model.status.isLive {
                    KeyBarView(model: model)
                }
            }
        }
        // Every content type, like the connection-file picker: what the guest
        // accepts is the guest's business, and a picker that greys files out
        // refuses sends the agent would take.
        .fileImporter(
            isPresented: $choosingFileToSend,
            allowedContentTypes: [.data]
        ) { result in
            sendPickedFile(result)
        }
        .statusBarHidden(!showChrome)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            connect()
            UIApplication.shared.isIdleTimerDisabled = model.machine.display.keepScreenAwake
        }
        .onDisappear {
            model.disconnect()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: model.clipboardFromGuest) { _, text in
            // The guest owning the clipboard is the whole point of a remote session:
            // copy there, paste here.
            if let text { UIPasteboard.general.string = text }
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(model.machine.name)
                    .font(.subheadline.weight(.semibold))
                Text(model.desktopName.isEmpty ? model.status.label : model.desktopName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if model.machine.proto == .spice {
                Button {
                    choosingFileToSend = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(!model.status.isLive)
            }

            Button {
                if let text = UIPasteboard.general.string { model.sendClipboard(text) }
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .disabled(!model.status.isLive)

            Button {
                withAnimation(.snappy) { showKeyBar.toggle() }
            } label: {
                Image(systemName: showKeyBar ? "keyboard.chevron.compact.down.fill" : "command")
            }

            Button {
                keyboardVisible.toggle()
            } label: {
                Image(systemName: keyboardVisible ? "keyboard.fill" : "keyboard")
            }
        }
        .font(.title3)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var fileSendBanner: some View {
        HStack(spacing: 10) {
            switch model.fileSend {
            case .sending(let name)?:
                ProgressView().controlSize(.small)
                Text("Envoi de « \(name) »…")
            case .sent(let name)?:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("« \(name) » envoyé à l'invité")
            case .failed(let message)?:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
            case .none:
                EmptyView()
            }
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .onTapGesture {
            // A transfer in flight is not dismissed by a tap: it is still
            // happening, and hiding it would not make it stop.
            if case .sending? = model.fileSend { return }
            model.dismissFileSend()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Reads the picked file and hands it to the session. The whole file is
    /// read into memory — the transfer's own chunking is downstream — which
    /// is fine for documents and wrong for movies; the day someone sends one,
    /// this is the line to revisit.
    private func sendPickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            model.fileSendFailed(error.localizedDescription)
        case .success(let url):
            // The picker hands back a URL into somebody else's container;
            // without claiming the scope the read fails as if the file
            // vanished.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let contents = try Data(contentsOf: url)
                model.sendFile(name: url.lastPathComponent, contents: contents)
            } catch {
                model.fileSendFailed(error.localizedDescription)
            }
        }
    }

    private func connect() {
        model.connect(credentials: library.credentialStore)
        library.markConnected(model.machine)
    }

    private func close() {
        model.disconnect()
        dismiss()
    }
}

/// Shown while connecting, and when a session ends or fails.
struct StatusOverlay: View {
    let model: SessionModel
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            switch model.status {
            case .connecting, .authenticating, .idle, .reconnecting, .startingVM:
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(model.status.label)
                    .foregroundStyle(.white.opacity(0.8))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 40)
                HStack(spacing: 12) {
                    Button("Réessayer", action: onRetry).buttonStyle(.borderedProminent)
                    Button("Fermer", action: onClose).buttonStyle(.bordered)
                }
            case .closed, .connected:
                Text(model.status.label).foregroundStyle(.white.opacity(0.8))
                Button("Fermer", action: onClose).buttonStyle(.bordered)
            }
        }
        .padding()
    }
}
#endif

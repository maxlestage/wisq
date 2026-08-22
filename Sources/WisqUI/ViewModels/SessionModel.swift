import CoreGraphics
import Foundation
import Observation
import WisqCore
import WisqRemote

/// Drives one live session for the UI: owns the backend actor, mirrors its events
/// into observable state, and turns touches into protocol input.
@Observable
@MainActor
public final class SessionModel {
    public enum Status: Equatable {
        case idle
        case connecting
        case authenticating
        case connected
        case failed(String)
        case closed

        public var isLive: Bool { self == .connected }

        public var label: String {
            switch self {
            case .idle: return "Prêt"
            case .connecting: return "Connexion…"
            case .authenticating: return "Authentification…"
            case .connected: return "Connecté"
            case .failed(let message): return message
            case .closed: return "Déconnecté"
            }
        }
    }

    public private(set) var status: Status = .idle
    public private(set) var desktopName = ""
    public private(set) var size = CGSize.zero
    /// Bumped on every framebuffer change so the renderer knows to redraw.
    public private(set) var frameGeneration: UInt64 = 0
    public private(set) var clipboardFromGuest: String?

    public let machine: Machine
    public private(set) var session: (any RemoteSession)?

    private var eventTask: Task<Void, Never>?
    /// Modifier keys held down by the on-screen key bar, released after the next keypress.
    private var stickyModifiers: Set<UInt32> = []
    /// Virtual cursor for trackpad mode, in framebuffer coordinates.
    public private(set) var pointer = CGPoint.zero
    private var heldButtons: MouseButtons = []

    public init(machine: Machine) {
        self.machine = machine
    }

    public var framebuffer: Framebuffer? { session?.framebuffer }

    public func connect(credentials: CredentialStore) {
        guard session == nil else { return }
        status = .connecting
        do {
            let session = try SessionFactory.makeSession(machine: machine, credentials: credentials)
            self.session = session
            observe(session)
            Task { await session.start() }
        } catch let error as WisqError {
            status = .failed(error.localizedDescription)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    public func disconnect() {
        eventTask?.cancel()
        eventTask = nil
        if let session {
            Task { await session.stop() }
        }
        session = nil
        status = .closed
    }

    private func observe(_ session: any RemoteSession) {
        eventTask = Task { [weak self] in
            for await event in session.events {
                guard let self else { return }
                await self.apply(event)
            }
        }
    }

    private func apply(_ event: SessionEvent) {
        switch event {
        case .connecting:
            status = .connecting
        case .authenticating:
            status = .authenticating
        case .ready(let name, let width, let height):
            desktopName = name
            size = CGSize(width: width, height: height)
            pointer = CGPoint(x: width / 2, y: height / 2)
            status = .connected
            frameGeneration &+= 1
        case .framebufferChanged:
            frameGeneration &+= 1
        case .resized(let width, let height):
            size = CGSize(width: width, height: height)
            frameGeneration &+= 1
        case .clipboard(let text):
            clipboardFromGuest = text
        case .bell:
            break
        case .disconnected(let error):
            status = error.map { .failed($0.localizedDescription) } ?? .closed
            session = nil
        }
    }

    // MARK: - Input

    public func movePointer(to point: CGPoint) {
        pointer = clamp(point)
        sendPointer()
    }

    public func movePointer(by delta: CGSize) {
        let speed = machine.input.pointerSpeed
        pointer = clamp(CGPoint(x: pointer.x + delta.width * speed, y: pointer.y + delta.height * speed))
        sendPointer()
    }

    public func click(_ button: MouseButtons, at point: CGPoint? = nil) {
        if let point { pointer = clamp(point) }
        heldButtons.insert(button)
        sendPointer()
        heldButtons.remove(button)
        sendPointer()
    }

    public func setButton(_ button: MouseButtons, down: Bool) {
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        sendPointer()
    }

    /// Scroll wheel is expressed as button presses in RFB; one call is one notch.
    public func scroll(vertical: Int, horizontal: Int = 0) {
        let up = machine.input.naturalScrolling ? vertical > 0 : vertical < 0
        if vertical != 0 {
            for _ in 0..<min(abs(vertical), 8) { click(up ? .scrollUp : .scrollDown) }
        }
        if horizontal != 0 {
            for _ in 0..<min(abs(horizontal), 8) { click(horizontal > 0 ? .scrollRight : .scrollLeft) }
        }
    }

    public func type(_ text: String) {
        for scalar in text.unicodeScalars {
            let keysym = scalar == "\n" ? Keysym.enter : Keysym.character(scalar)
            press(keysym)
        }
    }

    /// Sends a keypress with any sticky modifiers wrapped around it, then clears them.
    public func press(_ keysym: UInt32) {
        let modifiers = stickyModifiers
        Task { [session] in
            guard let session else { return }
            for modifier in modifiers { await session.send(.key(keysym: modifier, down: true)) }
            await session.send(.key(keysym: keysym, down: true))
            await session.send(.key(keysym: keysym, down: false))
            for modifier in modifiers.reversed() { await session.send(.key(keysym: modifier, down: false)) }
        }
        stickyModifiers.removeAll()
    }

    public func toggleModifier(_ keysym: UInt32) {
        if stickyModifiers.contains(keysym) {
            stickyModifiers.remove(keysym)
        } else {
            stickyModifiers.insert(keysym)
        }
    }

    public func isModifierHeld(_ keysym: UInt32) -> Bool {
        stickyModifiers.contains(keysym)
    }

    public func sendClipboard(_ text: String) {
        Task { [session] in await session?.send(.clipboard(text)) }
    }

    public func viewportChanged(to size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        Task { [session] in
            await session?.setPreferredSize(width: Int(size.width), height: Int(size.height))
        }
    }

    private func sendPointer() {
        let event = InputEvent.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: heldButtons)
        Task { [session] in await session?.send(event) }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(
            x: min(max(0, point.x), size.width - 1),
            y: min(max(0, point.y), size.height - 1)
        )
    }
}

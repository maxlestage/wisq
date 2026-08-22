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
        case reconnecting(attempt: Int)
        case failed(String)
        case closed

        public var isLive: Bool { self == .connected }

        public var label: String {
            switch self {
            case .idle: return "Prêt"
            case .connecting: return "Connexion…"
            case .authenticating: return "Authentification…"
            case .connected: return "Connecté"
            case .reconnecting(let attempt): return "Reconnexion (tentative \(attempt))…"
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
    private var inputChain: Task<Void, Never>?
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
        inputChain?.cancel()
        inputChain = nil
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
        case .reconnecting(let attempt):
            status = .reconnecting(attempt: attempt)
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

    /// Press and release, with a gap in between: a guest that samples input on a
    /// timer sees nothing at all when both edges land in the same instant.
    public func click(_ button: MouseButtons, at point: CGPoint? = nil) {
        if let point { pointer = clamp(point) }
        let position = pointer
        let held = heldButtons
        enqueue { session in
            await session.send(.pointer(x: Int(position.x), y: Int(position.y), buttons: held.union(button)))
            try? await Task.sleep(for: InputTiming.pressReleaseGap)
            await session.send(.pointer(x: Int(position.x), y: Int(position.y), buttons: held))
        }
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
        stickyModifiers.removeAll()
        enqueue { session in
            for modifier in modifiers { await session.send(.key(keysym: modifier, down: true)) }
            await session.send(.key(keysym: keysym, down: true))
            try? await Task.sleep(for: InputTiming.pressReleaseGap)
            await session.send(.key(keysym: keysym, down: false))
            for modifier in modifiers.reversed() { await session.send(.key(keysym: modifier, down: false)) }
        }
    }

    /// Raw key edge, for a hardware keyboard where the OS reports press and
    /// release separately and modifiers are genuinely held.
    public func setKey(_ keysym: UInt32, down: Bool) {
        enqueue { session in await session.send(.key(keysym: keysym, down: down)) }
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
        enqueue { session in await session.send(.clipboard(text)) }
    }

    public func viewportChanged(to size: CGSize) {
        guard size.width > 0, size.height > 0, let session else { return }
        Task { await session.setPreferredSize(width: Int(size.width), height: Int(size.height)) }
    }

    private func sendPointer() {
        let event = InputEvent.pointer(x: Int(pointer.x), y: Int(pointer.y), buttons: heldButtons)
        enqueue { session in await session.send(event) }
    }

    /// Input has to reach the guest in the order it happened: a click that races
    /// ahead of the move that positioned it lands in the wrong place. Chaining
    /// the tasks costs one allocation per event and removes the whole class of bug.
    private func enqueue(_ work: @escaping @Sendable (any RemoteSession) async -> Void) {
        guard let session else { return }
        let previous = inputChain
        inputChain = Task { @MainActor in
            await previous?.value
            await work(session)
        }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(
            x: min(max(0, point.x), size.width - 1),
            y: min(max(0, point.y), size.height - 1)
        )
    }
}

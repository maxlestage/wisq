import Foundation
import WisqCore
import WisqNet

/// RFB 3.8 client (RFC 6143).
///
/// Handshake, then a message pump that decodes framebuffer updates into the shared
/// `Framebuffer` and publishes what changed on `events`. Input goes out immediately;
/// nothing is queued behind the decoder.
public actor VNCSession: RemoteSession {
    public typealias StreamProvider = @Sendable (SessionConfiguration) async throws -> any ByteStream

    public nonisolated let events: AsyncStream<SessionEvent>
    public nonisolated let framebuffer = Framebuffer(width: 0, height: 0)

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let configuration: SessionConfiguration
    private let makeStream: StreamProvider

    private var stream: (any ByteStream)?
    private var pump: Task<Void, Never>?
    private var desktopName = ""
    private var supportsResize = false
    private var hasFinished = false

    public init(configuration: SessionConfiguration, streamProvider: StreamProvider? = nil) {
        self.configuration = configuration
        self.makeStream = streamProvider ?? VNCSession.defaultStreamProvider
        var escapee: AsyncStream<SessionEvent>.Continuation!
        // `.bufferingNewest` keeps the UI from stalling the decoder if a redraw
        // takes longer than the next update.
        self.events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { escapee = $0 }
        self.continuation = escapee
    }

    // MARK: - RemoteSession

    public func start() async {
        guard pump == nil else { return }
        pump = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run()
            } catch is CancellationError {
                await self.finish(with: nil)
            } catch let error as WisqError {
                await self.finish(with: error)
            } catch {
                await self.finish(with: .connectionFailed(error.localizedDescription))
            }
        }
    }

    public func stop() async {
        pump?.cancel()
        pump = nil
        await stream?.close()
        stream = nil
        finish(with: nil)
    }

    public func send(_ event: InputEvent) async {
        guard let stream else { return }
        do {
            switch event {
            case .pointer(let x, let y, let buttons):
                try await stream.write(Self.pointerMessage(x: x, y: y, buttons: buttons))
            case .key(let keysym, let down):
                try await stream.write(Self.keyMessage(keysym: keysym, down: down))
            case .clipboard(let text):
                try await stream.write(Self.cutTextMessage(text))
            }
        } catch {
            // A failed write means the socket is gone; the pump will report it.
        }
    }

    public func setPreferredSize(width: Int, height: Int) async {
        guard supportsResize, configuration.display.followDeviceResolution,
              let stream, width > 0, height > 0 else { return }
        try? await stream.write(Self.setDesktopSizeMessage(width: width, height: height))
    }

    // MARK: - Session lifecycle

    private func run() async throws {
        continuation.yield(.connecting)
        let stream = try await makeStream(configuration)
        self.stream = stream

        try await performVersionHandshake(stream)
        try await performSecurityHandshake(stream)
        let (width, height) = try await performInitialisation(stream)

        framebuffer.resize(width: width, height: height)

        // Negotiate the format and ask for the first full frame before announcing
        // readiness, so anything observing `.ready` sees a fully configured session.
        try await stream.write(Self.setPixelFormatMessage())
        try await stream.write(Self.setEncodingsMessage(lowBandwidth: configuration.display.lowBandwidth))
        try await requestUpdate(incremental: false, width: width, height: height)

        continuation.yield(.ready(desktopName: desktopName, width: width, height: height))

        try await pumpMessages(stream)
    }

    private func performVersionHandshake(_ stream: any ByteStream) async throws {
        let greeting = try await stream.readLatin1(count: 12)
        guard greeting.hasPrefix("RFB ") else {
            throw WisqError.handshakeFailed("réponse inattendue de l'hôte (\(greeting.debugDescription))")
        }
        // Every server built in the last twenty years speaks 3.8; older ones accept
        // being asked for it and downgrade the security list themselves.
        try await stream.write(Data("RFB 003.008\n".utf8))
    }

    private func performSecurityHandshake(_ stream: any ByteStream) async throws {
        continuation.yield(.authenticating)

        let count = Int(try await stream.readUInt8())
        guard count > 0 else {
            let length = Int(try await stream.readUInt32())
            let reason = try await stream.readLatin1(count: length)
            throw WisqError.handshakeFailed(reason.isEmpty ? "l'hôte a refusé la connexion" : reason)
        }

        let offered = [UInt8](try await stream.read(exactly: count))
        let chosen: RFB.SecurityType
        if offered.contains(RFB.SecurityType.vncAuth.rawValue), configuration.password?.isEmpty == false {
            chosen = .vncAuth
        } else if offered.contains(RFB.SecurityType.none.rawValue) {
            chosen = .none
        } else if offered.contains(RFB.SecurityType.vncAuth.rawValue) {
            throw WisqError.authenticationRequired
        } else {
            throw WisqError.handshakeFailed("aucune méthode d'authentification commune")
        }

        try await stream.write(Data([chosen.rawValue]))

        if chosen == .vncAuth {
            let challenge = try await stream.read(exactly: 16)
            let response = VNCAuth.response(challenge: challenge, password: configuration.password ?? "")
            try await stream.write(response)
        }

        let result = try await stream.readUInt32()
        guard result == 0 else {
            let length = Int(try await stream.readUInt32())
            let reason = try await stream.readLatin1(count: length)
            throw WisqError.authenticationFailed(reason.isEmpty ? "mot de passe refusé" : reason)
        }
    }

    private func performInitialisation(_ stream: any ByteStream) async throws -> (Int, Int) {
        // Shared flag: never kick other viewers off the desktop.
        try await stream.write(Data([1]))

        let width = Int(try await stream.readUInt16())
        let height = Int(try await stream.readUInt16())
        _ = try PixelFormat.decode(try await stream.read(exactly: 16))
        let nameLength = Int(try await stream.readUInt32())
        desktopName = try await stream.readLatin1(count: nameLength)

        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw WisqError.malformedMessage("taille de bureau invalide (\(width)×\(height))")
        }
        return (width, height)
    }

    private func pumpMessages(_ stream: any ByteStream) async throws {
        while !Task.isCancelled {
            let type = try await stream.readUInt8()
            switch RFB.ServerMessage(rawValue: type) {
            case .framebufferUpdate:
                try await handleFramebufferUpdate(stream)
            case .bell:
                continuation.yield(.bell)
            case .serverCutText:
                _ = try await stream.read(exactly: 3)
                let length = Int(try await stream.readUInt32())
                let text = try await stream.readLatin1(count: length)
                continuation.yield(.clipboard(text))
            case .setColourMapEntries:
                // We always negotiate true colour, so this should never arrive.
                // Consume it rather than desynchronising the stream.
                _ = try await stream.read(exactly: 3)
                let colourCount = Int(try await stream.readUInt16())
                _ = try await stream.read(exactly: colourCount * 6)
            case nil:
                throw WisqError.malformedMessage("message serveur inconnu (\(type))")
            }
        }
    }

    private func handleFramebufferUpdate(_ stream: any ByteStream) async throws {
        _ = try await stream.read(exactly: 1)
        let rectangleCount = Int(try await stream.readUInt16())
        let decoder = RFBDecoder(stream: stream, framebuffer: framebuffer)

        var painted: [Rect] = []
        var resizedTo: (width: Int, height: Int)?

        rectangles: for _ in 0..<rectangleCount {
            switch try await decoder.decodeRectangle() {
            case .painted(let rect):
                painted.append(rect)
            case .resized(let width, let height):
                supportsResize = true
                framebuffer.resize(width: width, height: height)
                resizedTo = (width, height)
            case .serverSupportsResize:
                supportsResize = true
            case .renamed(let name):
                desktopName = name
            case .endOfRectangles:
                // LastRect: the server sent a placeholder count and ends here.
                break rectangles
            case .ignored:
                continue
            }
        }

        if let resizedTo {
            continuation.yield(.resized(width: resizedTo.width, height: resizedTo.height))
            try await requestUpdate(incremental: false, width: resizedTo.width, height: resizedTo.height)
        } else {
            if !painted.isEmpty {
                continuation.yield(.framebufferChanged(painted))
            }
            let (width, height, _) = framebuffer.snapshot()
            try await requestUpdate(incremental: true, width: width, height: height)
        }
    }

    private func requestUpdate(incremental: Bool, width: Int, height: Int) async throws {
        guard let stream, width > 0, height > 0 else { return }
        try await stream.write(Self.updateRequestMessage(
            incremental: incremental,
            rect: Rect(x: 0, y: 0, width: width, height: height)
        ))
    }

    private func finish(with error: WisqError?) {
        guard !hasFinished else { return }
        hasFinished = true
        continuation.yield(.disconnected(error))
        continuation.finish()
    }

    // MARK: - Client messages

    static func setPixelFormatMessage() -> Data {
        var writer = ByteWriter()
        writer.write(RFB.ClientMessage.setPixelFormat.rawValue)
        writer.pad(3)
        writer.write(PixelFormat.bgra32.encoded)
        return writer.data
    }

    static func setEncodingsMessage(lowBandwidth: Bool) -> Data {
        let encodings = RFB.preferredEncodings(lowBandwidth: lowBandwidth)
        var writer = ByteWriter()
        writer.write(RFB.ClientMessage.setEncodings.rawValue)
        writer.pad(1)
        writer.write(UInt16(encodings.count))
        for encoding in encodings { writer.write(encoding) }
        return writer.data
    }

    static func updateRequestMessage(incremental: Bool, rect: Rect) -> Data {
        var writer = ByteWriter()
        writer.write(RFB.ClientMessage.framebufferUpdateRequest.rawValue)
        writer.write(incremental ? 1 as UInt8 : 0)
        writer.write(UInt16(clamping: rect.x))
        writer.write(UInt16(clamping: rect.y))
        writer.write(UInt16(clamping: rect.width))
        writer.write(UInt16(clamping: rect.height))
        return writer.data
    }

    static func pointerMessage(x: Int, y: Int, buttons: MouseButtons) -> Data {
        var writer = ByteWriter()
        writer.write(RFB.ClientMessage.pointerEvent.rawValue)
        writer.write(buttons.rawValue)
        writer.write(UInt16(clamping: max(0, x)))
        writer.write(UInt16(clamping: max(0, y)))
        return writer.data
    }

    static func keyMessage(keysym: UInt32, down: Bool) -> Data {
        var writer = ByteWriter()
        writer.write(RFB.ClientMessage.keyEvent.rawValue)
        writer.write(down ? 1 as UInt8 : 0)
        writer.pad(2)
        writer.write(keysym)
        return writer.data
    }

    static func cutTextMessage(_ text: String) -> Data {
        let payload = latin1Payload(text)
        var writer = ByteWriter()
        writer.write(RFB.ClientMessage.clientCutText.rawValue)
        writer.pad(3)
        writer.write(UInt32(payload.count))
        writer.write(payload)
        return writer.data
    }

    /// RFB carries clipboard text as latin-1 with LF-only line endings (RFC 6143 §7.5.6).
    ///
    /// Foundation's own lossy conversion is not usable here: on swift-corelibs it
    /// returns nothing at all for a string containing one emoji, which would drop
    /// the entire paste. Substituting per scalar keeps the text a guest can use and
    /// behaves identically on every platform.
    static func latin1Payload(_ text: String) -> Data {
        var data = Data()
        data.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r":
                continue                        // the spec forbids CR
            case let scalar where scalar.value < 0x100:
                data.append(UInt8(scalar.value))
            default:
                data.append(0x3F)               // '?'
            }
        }
        return data
    }

    /// SetDesktopSize (client message 251) from the ExtendedDesktopSize extension:
    /// one screen covering the whole device viewport.
    static func setDesktopSizeMessage(width: Int, height: Int) -> Data {
        var writer = ByteWriter()
        writer.write(UInt8(251))
        writer.pad(1)
        writer.write(UInt16(clamping: width))
        writer.write(UInt16(clamping: height))
        writer.write(UInt8(1))
        writer.pad(1)
        writer.write(UInt32(1))          // screen id
        writer.write(UInt16(0))          // x
        writer.write(UInt16(0))          // y
        writer.write(UInt16(clamping: width))
        writer.write(UInt16(clamping: height))
        writer.write(UInt32(0))          // flags
        return writer.data
    }

    // MARK: - Transport

    private static let defaultStreamProvider: StreamProvider = { configuration in
        #if canImport(Network)
        let stream = try NetworkByteStream(
            host: configuration.host,
            port: configuration.port,
            security: configuration.security
        )
        try await stream.open()
        return stream
        #else
        throw WisqError.notImplemented("transport réseau indisponible sur cette plateforme")
        #endif
    }
}

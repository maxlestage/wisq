import Foundation
import WisqCore
import WisqNet

/// La session RDP : de la socket aux pixels.
///
/// **Elle parle la sécurité historique de RDP, et rien d'autre pour l'instant.**
/// Ce n'est pas un oubli mais ce qui a pu être mesuré : le seul serveur RDP
/// disponible pendant l'écriture — xrdp 0.9 — ne fait pas serveur NLA, et un
/// CredSSP écrit sans rien contre quoi le juger serait du code qu'on croit bon.
/// Un serveur qui exige NLA est donc refusé en le disant, plutôt que d'échouer
/// au milieu de la poignée de main.
///
/// **Et cette sécurité-là n'authentifie pas le serveur.** Le certificat est
/// signé par une clé que Microsoft a publiée en 1998 ; n'importe qui sur le
/// chemin peut se mettre au milieu. Le dire est le minimum, et c'est ce que
/// cette session fait : elle ne demande que la sécurité historique, et un
/// serveur qui exige TLS ou NLA est refusé par son nom plutôt que contourné.
/// Demander TLS d'abord supposerait de le *démarrer* au milieu d'une socket
/// déjà ouverte, ce que le transport de wisq ne sait pas faire aujourd'hui.
public actor RDPSession: RemoteSession {
    public typealias StreamProvider = @Sendable (SessionConfiguration) async throws -> any ByteStream

    public nonisolated let events: AsyncStream<SessionEvent>
    public nonisolated let framebuffer: Framebuffer

    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let configuration: SessionConfiguration
    private let makeStream: StreamProvider

    private var stream: (any ByteStream)?
    private var pump: Task<Void, Never>?
    private var security: RDPStandardSecurity?
    private var user: UInt16 = 0
    private var ioChannel: UInt16 = 0
    private var share: UInt32 = 0
    private var serverChannel: UInt16 = 0
    private var active = false
    private var hasFinished = false
    /// Les boutons tenus au dernier événement. **RDP envoie des transitions, et
    /// wisq reçoit un état** : sans mémoire, un bouton relâché ne le serait
    /// jamais côté serveur, et la fenêtre resterait accrochée au curseur.
    private var held: MouseButtons = []
    /// Ce qu'on demandera au serveur. La valeur par défaut est celle d'un écran
    /// de portable ordinaire : la vue n'a pas encore dit sa taille quand la
    /// session s'ouvre, et un bureau démesuré coûterait des pixels que personne
    /// ne regarde.
    private var requestedSize = (width: 1024, height: 768)

    public init(
        configuration: SessionConfiguration,
        framebuffer: Framebuffer? = nil,
        streamProvider: StreamProvider? = nil
    ) {
        self.configuration = configuration
        self.framebuffer = framebuffer ?? Framebuffer(width: 0, height: 0)
        self.makeStream = streamProvider ?? RDPSession.defaultStreamProvider
        var escapee: AsyncStream<SessionEvent>.Continuation!
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
        guard active else { return }
        switch event {
        case .pointer(let x, let y, let buttons):
            let slices = Self.pointerEvents(from: held, to: buttons, x: x, y: y)
            held = buttons.subtracting(Self.wheelButtons)
            await write(slices)
        case .key(let keysym, let down):
            guard let (code, extended) = Self.scancode(forKeysym: keysym) else { return }
            var flags: RDPInput.Key = down ? [] : .release
            if extended { flags.insert(.extended) }
            await write(.key(code, flags))
        case .clipboard:
            // Le presse-papiers voyage sur un canal virtuel que wisq n'ouvre
            // pas encore. Le laisser tomber en silence vaut mieux que de
            // l'envoyer sur le canal d'écran, où le serveur le lirait comme un
            // PDU quelconque.
            break
        }
    }

    /// **Avant l'ouverture, la taille est prise ; après, elle est ignorée.**
    ///
    /// RDP fixe la taille du bureau à l'ouverture de la conférence, c'est-à-dire
    /// dans le tout premier paquet. La changer ensuite est possible dans le
    /// protocole — le serveur renvoie un Deactivate All puis un nouveau Demand
    /// Active — mais wisq ne sait pas encore conduire cette seconde activation,
    /// et l'entamer laisserait la session muette. Ignorer en silence est le
    /// moindre mal : la vue met à l'échelle ce qu'elle reçoit.
    public func setPreferredSize(width: Int, height: Int) async {
        guard !active, width > 0, height > 0 else { return }
        requestedSize = (min(width, RDPConnect.maximumWidth),
                         min(height, RDPConnect.maximumHeight))
    }

    // MARK: - La conduite

    private func write(_ event: RDPInput.Event) async {
        await write([event])
    }

    private func write(_ events: [RDPInput.Event]) async {
        guard let stream, var sealed = security else { return }
        guard let pdu = try? RDPInput.events(events, share: share, source: user) else { return }
        let payload = sealed.seal(pdu)
        security = sealed
        try? await stream.write(RDPMCS.sendData(user: user, channel: ioChannel, payload))
    }

    /// Lire un PDU entier : l'en-tête d'abord, puis ce qu'il annonce.
    private func readPDU(_ stream: any ByteStream) async throws -> Data {
        let header = try await stream.read(exactly: RDPWire.tpktHeaderBytes)
        let length = try RDPWire.payloadLength(ofHeader: header)
        return try await stream.read(exactly: length)
    }

    private func run() async throws {
        continuation.yield(.connecting)
        let stream = try await makeStream(configuration)
        self.stream = stream
        try Task.checkCancellation()

        let name = configuration.username ?? ""
        try await stream.write(RDPWire.connectionRequest(user: name, requesting: .standard))
        switch try RDPWire.readConnectionConfirm(await readPDU(stream)) {
        case .standardSecurity:
            break
        case .selected(let protocols, _) where protocols == .standard:
            break
        case .selected(let protocols, _):
            throw WisqError.notImplemented(
                "ce serveur exige une sécurité que wisq ne parle pas encore "
                    + "(0x\(String(protocols.rawValue, radix: 16)))")
        case .refused(let reason, let code):
            throw WisqError.handshakeFailed(
                "le serveur a refusé la négociation : "
                    + (reason.map(String.init(describing:)) ?? "code \(code)"))
        }

        // La conférence, puis le domaine.
        // **La taille est demandée une fois et ne bouge plus.** RDP la fixe à
        // l'ouverture de la conférence ; la changer ensuite demande une seconde
        // activation, que `setPreferredSize` explique ne pas savoir conduire.
        let client = RDPConnect.ClientDescription(
            width: requestedSize.width, height: requestedSize.height, name: "wisq")
        try await stream.write(RDPConnect.connectInitial(client))
        let server = try RDPConnect.readConnectResponse(await readPDU(stream))
        ioChannel = server.ioChannel
        try await stream.write(RDPMCS.erectDomainRequest())
        try await stream.write(RDPMCS.attachUserRequest())
        user = try RDPMCS.readAttachUserConfirm(await readPDU(stream))
        for channel in [user, server.ioChannel] + server.channels {
            try await stream.write(RDPMCS.channelJoinRequest(user: user, channel: channel))
            try RDPMCS.readChannelJoinConfirm(await readPDU(stream), expecting: channel)
        }

        // Les clés. **L'aléa est tiré ici et ne ressort jamais** : ni dans un
        // événement, ni dans une erreur, ni dans un journal.
        continuation.yield(.authenticating)
        guard !server.certificate.isEmpty else {
            throw WisqError.handshakeFailed("le serveur n'a pas envoyé de certificat")
        }
        let key = try RDPStandardSecurity.publicKey(fromCertificate: [UInt8](server.certificate))
        let clientRandom = (0..<32).map { _ in UInt8.random(in: 0...255) }
        try await stream.write(RDPMCS.sendData(
            user: user, channel: server.ioChannel,
            RDPStandardSecurity.securityExchange(clientRandom: clientRandom, key: key)))
        var sealed = RDPStandardSecurity(keys: try RDPStandardSecurity.deriveKeys(
            clientRandom: clientRandom, serverRandom: [UInt8](server.serverRandom),
            method: server.encryptionMethod))
        let info = RDPClientInfo.packet(
            user: name, password: configuration.password ?? "",
            flags: RDPClientInfo.defaultFlags.union(.forceEncryptedCSPDU))
        try await stream.write(RDPMCS.sendData(user: user, channel: server.ioChannel,
                                               sealed.seal(info, flags: [.info])))
        security = sealed

        try await pump(stream, server: server)
    }

    /// Envoyer un PDU de partage déjà formé, scellé.
    private func send(_ payload: Data, flags: RDPStandardSecurity.Flags = []) async throws {
        guard let stream, var sealed = security else { return }
        let wrapped = sealed.seal(payload, flags: flags)
        security = sealed
        try await stream.write(RDPMCS.sendData(user: user, channel: ioChannel, wrapped))
    }

    private func pump(_ stream: any ByteStream,
                      server: RDPConnect.ServerDescription) async throws {
        while !Task.isCancelled {
            let frame = try await readPDU(stream)
            guard case .data(let indication) = try RDPMCS.readIncoming(frame) else {
                throw WisqError.connectionClosed
            }
            guard var sealed = security else { return }
            let clear = try sealed.open(indication.payload)
            security = sealed
            let flags = UInt16(indication.payload[0]) | UInt16(indication.payload[1]) << 8

            // L'étape de licence : un client qui ne répond rien reste là.
            if flags & 0x0080 != 0 {
                switch try RDPLicensing.read(clear) {
                case .wantsRequest:
                    try await send(RDPLicensing.newLicenseRequest(user: configuration.username ?? "",
                                                                  machine: "wisq"),
                                   flags: [.licence])
                case .finished:
                    break
                case .refused(let code):
                    throw WisqError.authenticationFailed(
                        "le serveur a refusé la licence (code \(code))")
                }
                continue
            }

            let received = try RDPShare.read(clear)
            switch received.kind {
            case .demandActive:
                try await activate(received, server: server)
            case .deactivateAll:
                // Le serveur veut refaire l'activation — un changement de
                // résolution, par exemple. wisq ne sait pas encore la conduire
                // une seconde fois, et le dire vaut mieux qu'un écran figé.
                throw WisqError.notImplemented(
                    "le serveur a redemandé une activation, que wisq ne sait pas encore refaire")
            case .data where received.dataKind == .update:
                try paint(received.body)
            case .data where received.dataKind == .setErrorInfo:
                let code = received.body.count >= 4
                    ? RDPStandardSecurity.le32([UInt8](received.body), 0) : 0
                if code != 0 {
                    throw WisqError.connectionFailed("le serveur a mis fin à la session (\(code))")
                }
            default:
                break
            }
        }
    }

    private func activate(_ received: RDPShare.Incoming,
                          server: RDPConnect.ServerDescription) async throws {
        let offer = try RDPCapabilities.readDemandActive(received.body, source: received.source)
        share = offer.shareId
        serverChannel = offer.source
        try await send(RDPCapabilities.confirmActive(
            offer: offer, source: user,
            width: offer.width, height: offer.height, depth: offer.colourDepth))
        for message in [
            RDPShare.synchronise(share: offer.shareId, source: user, target: offer.source),
            RDPShare.controlCooperate(share: offer.shareId, source: user),
            RDPShare.controlRequest(share: offer.shareId, source: user),
            RDPShare.fontList(share: offer.shareId, source: user)
        ] {
            try await send(message)
        }
        framebuffer.resize(width: offer.width, height: offer.height)
        active = true
        continuation.yield(.ready(desktopName: configuration.host,
                                  width: offer.width, height: offer.height))
    }

    private func paint(_ body: Data) throws {
        guard try RDPBitmapUpdate.kind(of: body) == .bitmap else { return }
        var painted: [Rect] = []
        for rectangle in try RDPBitmapUpdate.rectangles(body) {
            // **Un rectangle illisible n'emporte pas les autres.** Une
            // profondeur qu'on ne sait pas lire est un trou dans l'image, pas
            // une raison de fermer la session.
            guard let (rect, pixels) = try? RDPBitmapUpdate.paintable(rectangle) else { continue }
            framebuffer.write(rect: rect, bgra: pixels)
            painted.append(rect)
        }
        if !painted.isEmpty { continuation.yield(.framebufferChanged(painted)) }
    }

    private func finish(with error: WisqError?) {
        guard !hasFinished else { return }
        hasFinished = true
        active = false
        continuation.yield(.disconnected(error))
        continuation.finish()
    }

    // MARK: - Les entrées, traduites

    /// Le code PC AT d'une touche X11, et s'il porte le préfixe étendu.
    ///
    /// **La table est celle de SPICE**, parce que les deux protocoles emploient
    /// les mêmes codes ; ce qui diffère est où va le préfixe `E0`. SPICE le met
    /// dans la valeur, RDP dans un drapeau à part — les mélanger fait taper une
    /// touche du pavé numérique à la place d'une flèche.
    static func scancode(forKeysym keysym: UInt32) -> (code: UInt16, extended: Bool)? {
        guard let code = SpiceScancode.scancode(forKeysym: keysym) else { return nil }
        if code & 0xFF00 == 0xE000 { return (UInt16(code & 0xFF), true) }
        return (UInt16(truncatingIfNeeded: code), false)
    }

    /// Ce qu'un changement d'état de souris devient sur le fil.
    ///
    /// **RDP n'envoie pas un état de boutons mais des transitions**, et
    /// `InputEvent.pointer` porte les boutons *tenus*. La conversion compare
    /// donc au coup d'avant : ce qui vient d'être pris s'enfonce, ce qui vient
    /// d'être lâché se relâche. Sans la comparaison, aucun bouton ne se
    /// relâcherait jamais.
    static func pointerEvents(from: MouseButtons, to: MouseButtons,
                              x: Int, y: Int) -> [RDPInput.Event] {
        var out: [RDPInput.Event] = [.pointer([.move], x, y)]
        for (button, flag) in buttonFlags {
            if to.contains(button), !from.contains(button) {
                out.append(.pointer([flag, .down], x, y))
            } else if from.contains(button), !to.contains(button) {
                // **L'absence de `.down` est le relâchement.** Il n'y a pas de
                // drapeau « relâché » ; en inventer un laisserait le bouton
                // enfoncé côté serveur.
                out.append(.pointer([flag], x, y))
            }
        }
        // La molette n'a pas d'état : chaque cran est un événement, et le
        // « bouton » tenu de wisq en vaut un.
        if to.contains(.scrollUp) { out.append(RDPInput.wheel(1, at: (x, y))) }
        if to.contains(.scrollDown) { out.append(RDPInput.wheel(-1, at: (x, y))) }
        if to.contains(.scrollLeft) {
            out.append(RDPInput.wheel(-1, at: (x, y), horizontal: true))
        }
        if to.contains(.scrollRight) {
            out.append(RDPInput.wheel(1, at: (x, y), horizontal: true))
        }
        return out
    }

    /// Les quatre « boutons » qui n'en sont pas : on ne se souvient pas d'eux,
    /// sinon un cran de molette tenu deux fois de suite n'en ferait qu'un.
    static let wheelButtons: MouseButtons = [.scrollUp, .scrollDown,
                                             .scrollLeft, .scrollRight]

    static let buttonFlags: [(MouseButtons, RDPInput.Pointer)] = [
        (.left, .left), (.middle, .middle), (.right, .right),
    ]

    // MARK: - Transport

    private static let defaultStreamProvider: StreamProvider = { configuration in
        #if canImport(Network)
        let stream = try NetworkByteStream(
            host: configuration.host,
            port: configuration.port,
            security: configuration.security,
            pinnedFingerprint: configuration.certificateFingerprint
        )
        try await stream.open()
        return stream
        #else
        throw WisqError.notImplemented("transport réseau indisponible sur cette plateforme")
        #endif
    }
}

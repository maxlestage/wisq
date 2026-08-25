import Foundation
import WisqNet

/// The display channel, driven: messages in, pixels out.
///
/// The pieces this joins were each finished and each inert. `SpiceDisplayWire`
/// decodes a draw but has nowhere to put it; `SpiceSurfaces` puts pixels
/// somewhere but is never handed any; `SpiceLZ` turns bytes into an image
/// nobody asked for. This reads the socket and makes them one thing.
///
/// It is a `struct` over a `ByteStream` rather than an actor, like the main
/// channel next door. The session that owns it is the actor; this is the part
/// that can be run against a scripted server in a test with no socket at all,
/// and running it that way is how the ordering rules below get checked.
struct SpiceDisplayChannel {
    let stream: ByteStream

    /// Everything drawn since the caller last looked, and where.
    struct Update: Equatable {
        var surfaceID: UInt32
        var regions: [SpiceDisplayWire.Rect]
    }

    /// What a run of the pump produced.
    struct Progress: Equatable {
        var updates: [Update] = []
        /// Messages this does not handle, by type. Counted rather than logged:
        /// a client that silently ignores half a protocol should be able to say
        /// how much of it, and a test should be able to assert on that.
        var ignored: [UInt16: Int] = [:]
        /// Draws refused because the encoding or the shape is not done yet.
        /// Distinct from `ignored`: the message was understood and could not be
        /// carried out, which is the count that says what to build next.
        var undrawable = 0
        /// The serial to use for the next message this client sends.
        ///
        /// Returned rather than kept, because the pump is a `struct` and the
        /// caller is what persists between calls. A server that acknowledges by
        /// serial is entitled to a sequence with no holes, and a caller that
        /// passed the same number back in every time would give it one full of
        /// them.
        var nextSerial: UInt64 = 0
    }

    private static let firstSerial: UInt64 = 1

    /// A cap on one message, in the same spirit as the main channel's.
    ///
    /// Larger here because a display message legitimately carries an image: a
    /// full-screen 4K frame of uncompressed pixels is about 33 MB, and the
    /// point of a bound is to refuse the absurd rather than the merely big.
    static let maximumMessageBytes = 64 << 20

    /// Announces what this client can do and asks for what it can read.
    ///
    /// Order matters and is the protocol's, not a preference: `INIT` first,
    /// because the server does not draw until it arrives, and the compression
    /// request after it. Sent the other way round, the preference can reach a
    /// server that has not yet decided this client exists.
    func announce(serverCapabilities: [UInt32]) async throws -> UInt64 {
        var serial = Self.firstSerial

        try await stream.write(SpiceWire.message(
            SpiceDisplayClient.Message.initialise.rawValue,
            serial: serial,
            payload: Data(SpiceDisplayClient.initialise())
        ))
        serial += 1

        // Only when the server said it would listen. A message the other end
        // has declared it does not understand is noise, not a request.
        if let wanted = SpiceDisplayClient.compressionToRequest(
            givenServerCapabilities: serverCapabilities
        ) {
            try await stream.write(SpiceWire.message(
                SpiceDisplayClient.Message.preferredCompression.rawValue,
                serial: serial,
                payload: Data(SpiceDisplayClient.preferredCompression(wanted))
            ))
            serial += 1
        }
        return serial
    }

    /// Reads up to `limit` messages, drawing what it understands.
    ///
    /// The default is **one**, and that is a decision rather than a timid
    /// number. A batch only reports what it drew once the whole batch is done,
    /// so a first frame of three messages would sit unpainted until the two
    /// hundred and fifty-third arrived — which on a quiet desktop is never. One
    /// message per call means the caller publishes damage as it happens, and
    /// the cost is a function call per message.
    ///
    /// `limit` remains for callers that want to bound a burst, and for tests
    /// that script an exact number of messages.
    /// `glz` is threaded alongside `surfaces` and for the same reason: it is
    /// state the pump owns for as long as it runs. A GLZ stream refers to
    /// images decoded earlier **on this connection**, so the window's honest
    /// lifetime is the connection's — a reconnect starts with an empty one,
    /// exactly as it starts with a blank screen.
    func pump(
        into surfaces: inout SpiceSurfaces, glz: inout SpiceGLZ.Window,
        serial: UInt64, limit: Int = 1
    ) async throws -> Progress {
        var progress = Progress()
        var serial = serial

        for _ in 0..<limit {
            let header = try SpiceWire.decodeDataHeader(
                try await stream.read(exactly: SpiceWire.dataHeaderBytes)
            )
            guard header.size <= Self.maximumMessageBytes else { throw SpiceError.invalidData }
            let payload = header.size == 0
                ? Data() : try await stream.read(exactly: Int(header.size))

            switch header.type {
            case SpiceWire.Message.ping:
                // Answered rather than counted as ignored: a server that pings
                // and hears nothing back concludes the client is gone.
                try await stream.write(SpiceWire.message(
                    SpiceWire.ClientMessage.pong, serial: serial, payload: payload
                ))
                serial += 1

            case SpiceDisplayWire.Message.surfaceCreate.rawValue:
                try surfaces.create(try SpiceDisplayWire.surfaceCreate([UInt8](payload)))

            case SpiceDisplayWire.Message.surfaceDestroy.rawValue:
                surfaces.destroy(try SpiceDisplayWire.surfaceDestroy([UInt8](payload)))

            case SpiceDisplayWire.Message.drawFill.rawValue:
                let fill = try SpiceDisplayWire.fill([UInt8](payload))
                progress.record(try draw(fill, into: &surfaces), on: fill.base.surfaceID)

            // **Blend is copy.** Not "close enough to reuse the decoder": the
            // reference wires them to the same function with the comment
            // `// copy and blend are the same`, and the protocol gives blend
            // copy's own C type. So this is one message with two numbers.
            case SpiceDisplayWire.Message.drawCopy.rawValue,
                 SpiceDisplayWire.Message.drawBlend.rawValue:
                let copy = try SpiceDisplayWire.copy([UInt8](payload))
                progress.record(try draw(copy, into: &surfaces, glz: &glz), on: copy.base.surfaceID)

            case SpiceDisplayWire.Message.drawAlphaBlend.rawValue:
                let blend = try SpiceDisplayWire.alphaBlend([UInt8](payload))
                progress.record(
                    try draw(blend, into: &surfaces, glz: &glz), on: blend.base.surfaceID
                )

            case SpiceDisplayWire.Message.drawTransparent.rawValue:
                let transparent = try SpiceDisplayWire.transparent([UInt8](payload))
                progress.record(
                    try draw(transparent, into: &surfaces, glz: &glz),
                    on: transparent.base.surfaceID
                )

            case SpiceDisplayWire.Message.drawOpaque.rawValue:
                let opaque = try SpiceDisplayWire.opaque([UInt8](payload))
                progress.record(
                    try draw(opaque, into: &surfaces, glz: &glz), on: opaque.base.surfaceID
                )

            case SpiceDisplayWire.Message.copyBits.rawValue:
                let bits = try SpiceDisplayWire.copyBits([UInt8](payload))
                progress.record(try draw(bits, into: &surfaces), on: bits.base.surfaceID)

            case SpiceDisplayWire.Message.drawBlackness.rawValue,
                 SpiceDisplayWire.Message.drawWhiteness.rawValue,
                 SpiceDisplayWire.Message.drawInvers.rawValue:
                let operation: SpiceDisplayWire.MaskedRaster.Operation =
                    switch header.type {
                    case SpiceDisplayWire.Message.drawBlackness.rawValue: .blackness
                    case SpiceDisplayWire.Message.drawWhiteness.rawValue: .whiteness
                    default: .invers
                    }
                let raster = try SpiceDisplayWire.maskedRaster([UInt8](payload), operation)
                progress.record(try draw(raster, into: &surfaces), on: raster.base.surfaceID)

            default:
                progress.ignored[header.type, default: 0] += 1
            }
        }
        progress.nextSerial = serial
        return progress
    }

    // MARK: - One draw

    /// A draw that cannot be carried out yields no regions rather than throwing.
    ///
    /// The distinction is the whole point of `undrawable`: an encoding wisq does
    /// not decode is a part of the screen left alone, and a malformed message is
    /// a connection to drop. Turning the first into the second would disconnect
    /// a phone because a server sent one JPEG.
    private func draw(
        _ fill: SpiceDisplayWire.Fill, into surfaces: inout SpiceSurfaces
    ) throws -> [SpiceDisplayWire.Rect]? {
        do {
            return try surfaces.fill(fill)
        } catch SpiceSurfaces.Failure.notDrawable {
            return nil
        }
    }

    private func draw(
        _ bits: SpiceDisplayWire.CopyBits, into surfaces: inout SpiceSurfaces
    ) throws -> [SpiceDisplayWire.Rect]? {
        do {
            return try surfaces.copyBits(bits)
        } catch SpiceSurfaces.Failure.notDrawable {
            return nil
        }
    }

    private func draw(
        _ raster: SpiceDisplayWire.MaskedRaster, into surfaces: inout SpiceSurfaces
    ) throws -> [SpiceDisplayWire.Rect]? {
        do {
            return try surfaces.raster(raster)
        } catch SpiceSurfaces.Failure.notDrawable {
            return nil
        }
    }

    private func draw(
        _ blend: SpiceDisplayWire.AlphaBlend, into surfaces: inout SpiceSurfaces,
        glz: inout SpiceGLZ.Window
    ) throws -> [SpiceDisplayWire.Rect]? {
        guard let image = blend.source,
              let decoded = try SpiceDisplayWire.pixels(of: image, glzWindow: &glz)
        else { return nil }
        do {
            return try surfaces.alphaBlend(
                blend, source: decoded,
                bytesPerSourcePixel: decoded.pixels.count
                    / max(decoded.width * decoded.height, 1)
            )
        } catch SpiceSurfaces.Failure.notDrawable {
            return nil
        }
    }

    private func draw(
        _ transparent: SpiceDisplayWire.Transparent, into surfaces: inout SpiceSurfaces,
        glz: inout SpiceGLZ.Window
    ) throws -> [SpiceDisplayWire.Rect]? {
        guard let image = transparent.source,
              let decoded = try SpiceDisplayWire.pixels(of: image, glzWindow: &glz)
        else { return nil }
        do {
            return try surfaces.transparent(
                transparent, source: decoded,
                bytesPerSourcePixel: decoded.pixels.count
                    / max(decoded.width * decoded.height, 1)
            )
        } catch SpiceSurfaces.Failure.notDrawable {
            return nil
        }
    }

    private func draw(
        _ opaque: SpiceDisplayWire.Opaque, into surfaces: inout SpiceSurfaces,
        glz: inout SpiceGLZ.Window
    ) throws -> [SpiceDisplayWire.Rect]? {
        guard let image = opaque.source,
              let decoded = try SpiceDisplayWire.pixels(of: image, glzWindow: &glz)
        else { return nil }
        let bytesPerPixel = decoded.pixels.count
            / max(decoded.width * decoded.height, 1)
        do {
            return try surfaces.opaque(
                opaque, source: decoded, bytesPerSourcePixel: bytesPerPixel
            )
        } catch SpiceSurfaces.Failure.notDrawable {
            return nil
        }
    }

    private func draw(
        _ copy: SpiceDisplayWire.Copy, into surfaces: inout SpiceSurfaces,
        glz: inout SpiceGLZ.Window
    ) throws -> [SpiceDisplayWire.Rect]? {
        guard let image = copy.source,
              let decoded = try SpiceDisplayWire.pixels(
                of: image, glzWindow: &glz
              ) else { return nil }

        // Three bytes for a 24-bit stream, four for a 32-bit one. Taken from
        // what the decoder produced rather than from the message, because the
        // message describes the image and the decoder describes the bytes.
        let bytesPerPixel = decoded.pixels.count / max(decoded.width * decoded.height, 1)
        do {
            return try surfaces.copy(
                copy, source: decoded, bytesPerSourcePixel: bytesPerPixel
            )
        } catch SpiceSurfaces.Failure.notDrawable {
            return nil
        }
    }
}

private extension SpiceDisplayChannel.Progress {
    mutating func record(_ regions: [SpiceDisplayWire.Rect]?, on surface: UInt32) {
        guard let regions else {
            undrawable += 1
            return
        }
        guard !regions.isEmpty else { return }
        updates.append(SpiceDisplayChannel.Update(surfaceID: surface, regions: regions))
    }
}

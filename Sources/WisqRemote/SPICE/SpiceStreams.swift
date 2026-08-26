import Foundation

/// The streams a server has opened on the display channel.
///
/// A SPICE server watches for a rectangle that keeps changing and, past a
/// threshold, stops sending it as draws and starts sending it as video. On a
/// desktop playing anything — a video, a scrolling page, an animation — that is
/// where most of the pixels go. A client that ignores streams shows a frozen
/// rectangle exactly where the motion is, which looks less like a missing
/// feature than like a broken connection.
///
/// This is the registry and the placement. What it deliberately is *not* is a
/// video decoder: the frame bytes go to whatever decodes that codec, and only
/// `mjpeg` has one here.
struct SpiceStreams {
    /// One open stream.
    struct Stream: Equatable, Sendable {
        var surfaceID: UInt32
        var codec: SpiceDisplayWire.VideoCodec
        var topDown: Bool
        var frameWidth: Int
        var frameHeight: Int
        var destination: SpiceDisplayWire.Rect
        var clip: SpiceDisplayWire.Clip
    }

    enum Failure: Error, Equatable {
        case unknownStream(UInt32)
        case streamAlreadyExists(UInt32)
        case unreasonableSize(width: UInt32, height: UInt32)
    }

    private(set) var streams: [UInt32: Stream] = [:]

    /// The largest frame this will admit, before anything is allocated from the
    /// numbers. The same reasoning as `SpiceSurfaces`: they come off a socket.
    static let maximumFramePixels = 1 << 26

    mutating func create(_ request: SpiceDisplayWire.StreamCreate) throws {
        guard streams[request.id] == nil else {
            throw Failure.streamAlreadyExists(request.id)
        }
        let width = Int(request.streamWidth)
        let height = Int(request.streamHeight)
        // Bounded per side before multiplying — see `SpiceSurfaces.create` for
        // why the order matters. These two came off the wire as `UInt32`.
        guard width > 0, height > 0,
              width <= Self.maximumFramePixels, height <= Self.maximumFramePixels,
              width * height <= Self.maximumFramePixels else {
            throw Failure.unreasonableSize(
                width: request.streamWidth, height: request.streamHeight
            )
        }
        streams[request.id] = Stream(
            surfaceID: request.surfaceID, codec: request.codec, topDown: request.topDown,
            frameWidth: width, frameHeight: height,
            destination: request.destination, clip: request.clip
        )
    }

    /// `STREAM_CLIP` — the visible part of a stream changing without the stream
    /// restarting, which is what happens when a window moves over the video.
    mutating func clip(_ id: UInt32, to clip: SpiceDisplayWire.Clip) throws {
        guard streams[id] != nil else { throw Failure.unknownStream(id) }
        streams[id]?.clip = clip
    }

    /// Destroying a stream that does not exist is not an error.
    ///
    /// The server sends `STREAM_DESTROY_ALL` on a reset, and a client that
    /// dropped a create it could not honour would otherwise refuse the tidy-up
    /// and drop the connection over it.
    mutating func destroy(_ id: UInt32) { streams[id] = nil }

    mutating func destroyAll() { streams.removeAll() }

    /// Everything a caller needs to put one frame on a surface.
    ///
    /// A type of its own rather than the `Stream` plus a size, and that is the
    /// whole point. In the sized case the stream's `frameWidth`, `frameHeight`
    /// and `destination` are *not* this frame's — so handing both back would
    /// hand back two answers to each of three questions, with the stale one
    /// spelled more naturally. A caller reaching for `stream.destination`
    /// instead of `destination` would put the video in the previous frame's
    /// place, and nothing would say so. This type simply does not carry them.
    struct Placement: Equatable, Sendable {
        var surfaceID: UInt32
        var codec: SpiceDisplayWire.VideoCodec
        var topDown: Bool
        var clip: SpiceDisplayWire.Clip
        /// The size of *this* frame on the wire.
        var width: Int
        var height: Int
        /// Where *this* frame lands on the surface.
        var destination: SpiceDisplayWire.Rect
    }

    /// Where a frame goes, and how big it is on the wire.
    ///
    /// `STREAM_DATA_SIZED` overrides both for one frame. The reference reads
    /// the same fields into the same `SpiceFrame` and does not touch the
    /// stream's own — so a sized frame does *not* resize the stream, and the
    /// next plain frame goes back to the original geometry. Storing it would be
    /// the obvious mistake and would show as the video jumping size. Here it is
    /// not merely not stored: `placement` cannot store, being non-mutating, and
    /// what it returns does not carry the stream's geometry to be confused with.
    func placement(for data: SpiceDisplayWire.StreamData) throws -> Placement {
        guard let stream = streams[data.id] else { throw Failure.unknownStream(data.id) }
        func placed(_ width: Int, _ height: Int, _ destination: SpiceDisplayWire.Rect) -> Placement {
            Placement(
                surfaceID: stream.surfaceID, codec: stream.codec, topDown: stream.topDown,
                clip: stream.clip, width: width, height: height, destination: destination
            )
        }
        guard let sized = data.sized else {
            return placed(stream.frameWidth, stream.frameHeight, stream.destination)
        }
        let width = Int(sized.width)
        let height = Int(sized.height)
        // Same guard, same reason: `Sized` carries two `UInt32` of its own, and
        // a sized frame is the one a hostile server can send at any moment
        // rather than only at stream creation.
        guard width > 0, height > 0,
              width <= Self.maximumFramePixels, height <= Self.maximumFramePixels,
              width * height <= Self.maximumFramePixels else {
            throw Failure.unreasonableSize(width: sized.width, height: sized.height)
        }
        return placed(width, height, sized.destination)
    }
}

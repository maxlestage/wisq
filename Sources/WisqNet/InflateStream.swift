import CZlib
import Foundation
import WisqCore

/// A zlib inflate stream that lives as long as the session.
///
/// This is the whole point of RFB's compressed encodings and the thing that makes
/// them awkward: the stream is *not* restarted per rectangle. Its dictionary carries
/// across the whole session, which is where the compression ratio comes from — and
/// which means one dropped or mis-parsed byte corrupts every frame after it.
///
/// Marked `@unchecked Sendable` on the strength of an actual lock rather than a
/// promise: a decoder runs as a nonisolated async call made from the session
/// actor, so the stream is handed between executors even though only one decode
/// is ever in flight. The lock makes that transfer safe rather than merely
/// unlikely to hurt.
public final class InflateStream: @unchecked Sendable {
    private let lock = NSLock()
    private var stream = z_stream()
    private var isOpen = false
    /// Reused across calls so a 60 Hz stream of updates does not allocate a
    /// 64 KiB scratch buffer per frame.
    private var scratch = [UInt8](repeating: 0, count: 64 * 1024)

    public init() throws {
        try start()
    }

    deinit {
        if isOpen { inflateEnd(&stream) }
    }

    /// Feeds compressed bytes in and returns everything that comes out, up to
    /// `limit` bytes.
    ///
    /// A call may legitimately produce nothing: zlib buffers until it has a
    /// complete block. The caller must not treat empty output as an error.
    ///
    /// **`limit` is not decoration, and it has no default on purpose.** Every
    /// caller already knew the answer — each one inflates and then refuses what
    /// is not the size its own message promised — and every one of them asked
    /// *after* the bytes existed. Compression ratios do not care about the
    /// order: measured on this machine, 101 929 compressed bytes produce
    /// 104 857 600, a ratio of 1 028 to 1. `decodeZlib` admits a compressed
    /// block of `pixels × 4 + 1 MiB`, so a **one-pixel** rectangle carries a
    /// licence for a gigabyte, allocated here, before its `pixels.count == 4`
    /// ever runs.
    ///
    /// The allocation audit looked at this path and recorded it as covered "on
    /// the pixel side". That was true of the check and false of the allocation,
    /// which is the whole distinction: a guard downstream of the thing it
    /// guards is a report, not a defence.
    ///
    /// Having no default value is the second half. A caller that forgets the
    /// bound does not compile, rather than inheriting a number someone else
    /// guessed.
    public func inflate(_ input: Data, limit: Int) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard isOpen else { throw WisqError.malformedMessage("flux zlib fermé") }
        guard limit >= 0 else {
            throw WisqError.malformedMessage("plafond zlib négatif : \(limit)")
        }
        guard !input.isEmpty else { return Data() }

        var output = Data()
        var inputBytes = [UInt8](input)

        try inputBytes.withUnsafeMutableBufferPointer { inputPointer in
            stream.next_in = inputPointer.baseAddress
            stream.avail_in = uInt(inputPointer.count)

            while true {
                let produced = try scratch.withUnsafeMutableBufferPointer { outputPointer -> Int in
                    stream.next_out = outputPointer.baseAddress
                    stream.avail_out = uInt(outputPointer.count)

                    let status = CZlib.inflate(&stream, Z_NO_FLUSH)
                    switch status {
                    case Z_OK, Z_STREAM_END, Z_BUF_ERROR:
                        return outputPointer.count - Int(stream.avail_out)
                    default:
                        throw WisqError.malformedMessage("flux zlib corrompu (code \(status))")
                    }
                }
                if produced > 0 {
                    // Refused as it arrives rather than once it is all here:
                    // the point is the bytes that never get allocated, so the
                    // count is checked against the ceiling before the append
                    // that would cross it.
                    guard output.count + produced <= limit else {
                        throw WisqError.malformedMessage(
                            "flux zlib au-delà de son plafond : \(output.count + produced) octets "
                                + "produits pour \(limit) admis")
                    }
                    output.append(contentsOf: scratch[0..<produced])
                }
                // Stop once zlib has consumed the input and stopped filling the
                // buffer; a full buffer means there is more waiting.
                if produced < scratch.count { break }
            }

            // zlib must not hold a pointer into a buffer that is about to die.
            stream.next_in = nil
            stream.avail_in = 0
        }
        return output
    }

    /// Restarts the stream, discarding its dictionary. Tight uses this: its
    /// compression-control byte can ask for any of its four streams to be reset.
    public func reset() throws {
        lock.lock()
        defer { lock.unlock() }
        if isOpen {
            inflateEnd(&stream)
            isOpen = false
        }
        stream = z_stream()
        try start()
    }

    private func start() throws {
        let status = inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            throw WisqError.malformedMessage("initialisation zlib impossible (code \(status))")
        }
        isOpen = true
    }
}

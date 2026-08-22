import CZlib
import Foundation
import WisqCore

/// A zlib inflate stream that lives as long as the session.
///
/// This is the whole point of RFB's compressed encodings and the thing that makes
/// them awkward: the stream is *not* restarted per rectangle. Its dictionary carries
/// across the whole session, which is where the compression ratio comes from — and
/// which means one dropped or mis-parsed byte corrupts every frame after it.
public final class InflateStream {
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

    /// Feeds compressed bytes in and returns everything that comes out.
    ///
    /// A call may legitimately produce nothing: zlib buffers until it has a
    /// complete block. The caller must not treat empty output as an error.
    public func inflate(_ input: Data) throws -> Data {
        guard isOpen else { throw WisqError.malformedMessage("flux zlib fermé") }
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

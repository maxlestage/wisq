import Foundation
import WisqCore

/// A bidirectional byte stream. Protocol backends talk to this, never to the socket,
/// which keeps them testable against an in-memory pipe.
public protocol ByteStream: Actor {
    /// Reads exactly `count` bytes, or throws if the peer closes first.
    func read(exactly count: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}

public extension ByteStream {
    func readUInt8() async throws -> UInt8 {
        try await read(exactly: 1)[0]
    }

    func readUInt16() async throws -> UInt16 {
        let data = try await read(exactly: 2)
        return UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
    }

    func readInt16() async throws -> Int16 {
        Int16(bitPattern: try await readUInt16())
    }

    func readUInt32() async throws -> UInt32 {
        let data = try await read(exactly: 4)
        var value: UInt32 = 0
        for byte in data { value = value << 8 | UInt32(byte) }
        return value
    }

    func readInt32() async throws -> Int32 {
        Int32(bitPattern: try await readUInt32())
    }

    /// Reads `count` bytes and decodes them as latin-1, the encoding RFB mandates
    /// for desktop names and clipboard text.
    func readLatin1(count: Int) async throws -> String {
        let data = try await read(exactly: count)
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}

/// Big-endian byte assembly for outgoing messages.
public struct ByteWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func write(_ value: UInt8) { data.append(value) }

    public mutating func write(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    public mutating func write(_ value: Int16) { write(UInt16(bitPattern: value)) }

    public mutating func write(_ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    public mutating func write(_ value: Int32) { write(UInt32(bitPattern: value)) }

    public mutating func write(_ bytes: Data) { data.append(bytes) }

    /// Writes `count` zero bytes, used for the padding RFB messages carry.
    public mutating func pad(_ count: Int) {
        data.append(contentsOf: [UInt8](repeating: 0, count: count))
    }
}

import Foundation
import WisqCore
import WisqNet

/// Wire constants for RFB 3.8 (RFC 6143).
public enum RFB {
    public enum SecurityType: UInt8 {
        case invalid = 0
        case none = 1
        case vncAuth = 2
        case tight = 16
        case vencrypt = 19
    }

    public enum ClientMessage: UInt8 {
        case setPixelFormat = 0
        case setEncodings = 2
        case framebufferUpdateRequest = 3
        case keyEvent = 4
        case pointerEvent = 5
        case clientCutText = 6
    }

    public enum ServerMessage: UInt8 {
        case framebufferUpdate = 0
        case setColourMapEntries = 1
        case bell = 2
        case serverCutText = 3
    }

    public enum Encoding: Int32 {
        case raw = 0
        case copyRect = 1
        case rre = 2
        case hextile = 5
        case zrle = 16
        case cursor = -239
        case desktopSize = -223
        case lastRect = -224
        case desktopName = -307
        case extendedDesktopSize = -308
    }

    /// Encodings this build can decode, most preferred first. Advertising an
    /// encoding we cannot decode would strand the stream mid-rectangle.
    public static func preferredEncodings(lowBandwidth: Bool) -> [Int32] {
        var encodings: [Int32] = []
        if lowBandwidth {
            encodings += [Encoding.hextile.rawValue, Encoding.rre.rawValue, Encoding.copyRect.rawValue, Encoding.raw.rawValue]
        } else {
            encodings += [Encoding.copyRect.rawValue, Encoding.hextile.rawValue, Encoding.rre.rawValue, Encoding.raw.rawValue]
        }
        encodings += [
            Encoding.desktopSize.rawValue,
            Encoding.extendedDesktopSize.rawValue,
            Encoding.desktopName.rawValue,
            Encoding.lastRect.rawValue,
        ]
        return encodings
    }
}

/// The 16-byte PIXEL_FORMAT structure.
public struct PixelFormat: Equatable, Sendable {
    public var bitsPerPixel: UInt8
    public var depth: UInt8
    public var bigEndian: Bool
    public var trueColour: Bool
    public var redMax: UInt16
    public var greenMax: UInt16
    public var blueMax: UInt16
    public var redShift: UInt8
    public var greenShift: UInt8
    public var blueShift: UInt8

    /// The one format wisq asks for: 32bpp little-endian with the components laid
    /// out as B,G,R,X in memory, which is exactly what Core Graphics and Metal
    /// consume with no conversion pass.
    public static let bgra32 = PixelFormat(
        bitsPerPixel: 32, depth: 24, bigEndian: false, trueColour: true,
        redMax: 255, greenMax: 255, blueMax: 255,
        redShift: 16, greenShift: 8, blueShift: 0
    )

    public var encoded: Data {
        var writer = ByteWriter()
        writer.write(bitsPerPixel)
        writer.write(depth)
        writer.write(bigEndian ? 1 as UInt8 : 0)
        writer.write(trueColour ? 1 as UInt8 : 0)
        writer.write(redMax)
        writer.write(greenMax)
        writer.write(blueMax)
        writer.write(redShift)
        writer.write(greenShift)
        writer.write(blueShift)
        writer.pad(3)
        return writer.data
    }

    public static func decode(_ data: Data) throws -> PixelFormat {
        guard data.count >= 16 else { throw WisqError.malformedMessage("PIXEL_FORMAT tronqué") }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
        return PixelFormat(
            bitsPerPixel: bytes[0],
            depth: bytes[1],
            bigEndian: bytes[2] != 0,
            trueColour: bytes[3] != 0,
            redMax: u16(4),
            greenMax: u16(6),
            blueMax: u16(8),
            redShift: bytes[10],
            greenShift: bytes[11],
            blueShift: bytes[12]
        )
    }
}

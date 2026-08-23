import Foundation

/// The guest's mouse cursor, delivered by the server so the client can draw it
/// locally instead of having it painted into the framebuffer.
///
/// Drawing it locally is what makes a remote pointer feel attached to the finger:
/// the cursor moves at the display's refresh rate while the framebuffer behind it
/// updates at whatever rate the link allows.
public struct RemoteCursor: Hashable, Sendable {
    public var width: Int
    public var height: Int
    /// The point inside the image that sits on the pointer position.
    public var hotspotX: Int
    public var hotspotY: Int
    /// BGRA pixels, alpha already applied from the wire bitmask.
    public var bgra: [UInt8]

    public init(width: Int, height: Int, hotspotX: Int, hotspotY: Int, bgra: [UInt8]) {
        self.width = width
        self.height = height
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.bgra = bgra
    }

    /// A zero-sized cursor is the server's way of hiding it.
    public var isEmpty: Bool { width <= 0 || height <= 0 }
}

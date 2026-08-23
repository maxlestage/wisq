import Foundation

/// A remote screen held as 32-bit BGRA, the layout Core Graphics and Metal both
/// consume without a conversion pass.
public final class Framebuffer: @unchecked Sendable {
    public private(set) var width: Int
    public private(set) var height: Int
    /// Row stride in bytes. Always `width * 4` here; kept explicit for the renderer.
    public var bytesPerRow: Int { width * 4 }
    public private(set) var pixels: [UInt8]

    private let lock = NSLock()

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = [UInt8](repeating: 0, count: max(0, width) * max(0, height) * 4)
    }

    /// Resize, dropping the old contents. Called on desktop-resize events.
    public func resize(width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        self.width = max(0, width)
        self.height = max(0, height)
        self.pixels = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    /// Blit a rectangle of BGRA pixels. Out-of-bounds rows and columns are clipped
    /// rather than trapping: a misbehaving server must not crash the app.
    public func write(rect: Rect, bgra: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        guard rect.width > 0, rect.height > 0 else { return }
        guard bgra.count >= rect.width * rect.height * 4 else { return }

        for row in 0..<rect.height {
            let dstY = rect.y + row
            guard dstY >= 0, dstY < height else { continue }
            let copyWidth = min(rect.width, width - rect.x)
            guard copyWidth > 0, rect.x >= 0 else { continue }

            let srcStart = row * rect.width * 4
            let dstStart = (dstY * width + rect.x) * 4
            pixels.replaceSubrange(
                dstStart..<(dstStart + copyWidth * 4),
                with: bgra[srcStart..<(srcStart + copyWidth * 4)]
            )
        }
    }

    /// Move a rectangle inside the framebuffer (RFB CopyRect).
    public func copy(from src: Point, to rect: Rect) {
        lock.lock(); defer { lock.unlock() }
        guard rect.width > 0, rect.height > 0 else { return }

        // Copy through a scratch buffer so overlapping regions stay correct.
        var scratch = [UInt8](repeating: 0, count: rect.width * rect.height * 4)
        for row in 0..<rect.height {
            let srcY = src.y + row
            guard srcY >= 0, srcY < height, src.x >= 0 else { continue }
            let copyWidth = min(rect.width, width - src.x)
            guard copyWidth > 0 else { continue }
            let from = (srcY * width + src.x) * 4
            let into = row * rect.width * 4
            scratch.replaceSubrange(into..<(into + copyWidth * 4), with: pixels[from..<(from + copyWidth * 4)])
        }

        for row in 0..<rect.height {
            let dstY = rect.y + row
            guard dstY >= 0, dstY < height, rect.x >= 0 else { continue }
            let copyWidth = min(rect.width, width - rect.x)
            guard copyWidth > 0 else { continue }
            let into = (dstY * width + rect.x) * 4
            let from = row * rect.width * 4
            pixels.replaceSubrange(into..<(into + copyWidth * 4), with: scratch[from..<(from + copyWidth * 4)])
        }
    }

    /// Snapshot of the pixel buffer, safe to hand to a renderer on another thread.
    public func snapshot() -> (width: Int, height: Int, pixels: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        return (width, height, pixels)
    }
}

public struct Point: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public init(x: Int, y: Int) { self.x = x; self.y = y }
}

public struct Rect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var origin: Point { Point(x: x, y: y) }
}

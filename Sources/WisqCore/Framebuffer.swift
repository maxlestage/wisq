import Foundation

/// A remote screen held as 32-bit BGRA, the layout Core Graphics and Metal both
/// consume without a conversion pass.
///
/// `@unchecked Sendable` on the strength of the lock below, and a lock only
/// keeps that promise if **every** path in and out of the state goes through
/// it. The three stored properties used to be `public private(set)`: written
/// under the lock, readable by anyone without it.
///
/// Nothing in the app actually did — the renderer has always gone through
/// `snapshot()` — but that is a habit, not a guarantee, and the failure it
/// leaves open is not a stale pixel. Reading a `[UInt8]` on one thread while
/// `replaceSubrange` grows it on another is a torn read of the array's own
/// buffer reference. The state is private now, and the only way to look at it
/// takes the lock, so the promise is one the type keeps rather than one its
/// callers have to.
public final class Framebuffer: @unchecked Sendable {
    private var width: Int
    private var height: Int
    private var pixels: [UInt8]

    private let lock = NSLock()

    /// The screen's size, as a pair.
    ///
    /// One accessor rather than two, because two could straddle a resize and
    /// between them describe a screen that never existed.
    public var size: (width: Int, height: Int) {
        lock.lock(); defer { lock.unlock() }
        return (width, height)
    }

    /// Row stride in bytes for a screen of this width. Always four bytes a
    /// pixel here; spelled out because a renderer has to be handed it next to
    /// the pixels it belongs to rather than deriving it from a width it read
    /// separately.
    public static func bytesPerRow(width: Int) -> Int { width * 4 }

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

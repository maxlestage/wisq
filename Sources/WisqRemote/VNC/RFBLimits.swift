import Foundation
import WisqCore

/// Ceilings on what an RFB server may ask this client to allocate.
///
/// RFB's geometry arrives in `UInt16`, which bounds every pixel product on its
/// own — that is why the decoders need no arithmetic guards. Its **lengths**
/// arrive in `UInt32` and are bounded by nothing at all, and the difference
/// matters because of what happens next: each length feeds
/// `read(exactly:)`, which **accumulates**. A server that names 0xFFFFFFFF and
/// then dribbles bytes makes the client's buffer grow without bound, at no cost
/// to the server and with no error to report. The counter that RRE reads in
/// `UInt32` is the opposite case and is safe for the opposite reason: it loops,
/// consuming each subrectangle as it goes, and throws at end of stream.
///
/// **The paragraph above was right about arithmetic and wrong about the
/// conclusion drawn from it, and this file drew it.** `UInt16` does bound the
/// product so it cannot leave an `Int` — and the bound it gives is 65535² × 4,
/// about seventeen gigabytes. "Bounded" was read as "small". The number that
/// showed the arithmetic was safe is the same number that shows the allocation
/// is not, and it was written out below, in full, as reassurance.
///
/// So a rectangle is bounded now as well: `requirePaintableRect` refuses the
/// geometry before an encoding acts on it.
///
/// Measured before it was guarded: a rectangle claiming a desktop name, a zlib
/// block or a ZRLE block of `UInt32.max` made the decoder ask for
/// 4 294 967 295 bytes in one read.
enum RFBLimits {
    /// Text the server sends for a person to read — a desktop name, a reason a
    /// connection or a password was refused.
    ///
    /// The protocol sets no bound, so this one is chosen rather than derived.
    /// 64 KiB is four orders of magnitude above any real desktop name and still
    /// a rounding error against what the field allows.
    static let maximumTextBytes = 64 << 10

    /// One `ServerCutText` payload.
    ///
    /// Larger than a name because a clipboard legitimately carries a document,
    /// and refusing a paste the user asked for would be a worse failure than
    /// the one being prevented. 8 MiB of latin-1 is roughly eight million
    /// characters.
    static let maximumClipboardBytes = 8 << 20

    /// The compressed payload for one rectangle, given the rectangle.
    ///
    /// This one is derived rather than chosen, which is why it is a function.
    /// The inflated result has to be the rectangle's pixels — `decodeZlib`
    /// already refuses anything else *after* inflating — so the compressed form
    /// cannot sensibly be larger than those pixels plus what a compressor adds
    /// when it gives up. The slack is deliberately generous: zlib's stored
    /// blocks cost about five bytes per 64 KiB, and ZRLE adds a header per
    /// tile, so a full-size rectangle's overhead stays far inside a megabyte.
    ///
    /// Both sides being `UInt16` on the wire, the product is at most
    /// 65535² × 4 ≈ 1.7e10 and cannot leave an `Int`.
    ///
    /// Being derived is what makes it a good ceiling **and** what made it
    /// useless on its own: measured, this returned 17 180 393 476 for a
    /// 65535 × 65535 rectangle. A guard computed from the attacker's number
    /// grants whatever that number asks for. It is a real bound only because
    /// `requirePaintableRect` now bounds the rectangle first — at 64 Mpx a
    /// rectangle, this is at most 257 MiB.
    static func maximumCompressedBytes(for rect: Rect) -> Int {
        let pixels = max(0, rect.width) * max(0, rect.height) * 4
        return pixels + (1 << 20)
    }

    /// Refuses a rectangle this client will not paint.
    ///
    /// The screen has had a ceiling since the desktop-size slice; the
    /// rectangles that paint on it had none, and they are not the same number
    /// arriving twice. Two encodings allocate from the geometry **alone**,
    /// before a single pixel byte has to arrive: CopyRect, which carries no
    /// pixels at all and reaches `Framebuffer.copy` after twelve bytes on the
    /// wire, and RRE, which allocates its tile after about eight. Measured:
    /// a 64 × 64 framebuffer, one CopyRect rectangle, `failed to allocate
    /// 17179344932 bytes of memory`.
    ///
    /// The bound is `Framebuffer.maximumPixels` — the same number as the
    /// screen's — rather than the current framebuffer's own size. RFB says a
    /// rectangle lies within the framebuffer, but a resize and an update
    /// crossing on the wire make a legitimate rectangle overhang for one
    /// message, and `Framebuffer.write` already clips. Refusing the overhang
    /// would break real servers to prevent nothing: what has to be refused is
    /// the allocation, and no screen this client holds is larger than the
    /// ceiling anyway.
    static func requirePaintableRect(_ rect: Rect) throws {
        guard Framebuffer.canHold(width: rect.width, height: rect.height) else {
            throw WisqError.malformedMessage(
                "rectangle de \(rect.width)×\(rect.height) : au-delà de ce que ce client peut peindre")
        }
    }
}

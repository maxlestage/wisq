import Foundation

extension SpiceGLZ {
    /// The GLZ match loop, `rgb32`.
    ///
    /// LZ's loop with one field added, and the field changes what a match can
    /// mean. Alongside the pixel offset the encoder writes an **image
    /// distance**: at zero the match is inside the image being decoded, and
    /// otherwise it names an earlier image in the window and the offset is an
    /// **absolute position from that image's start** rather than a distance
    /// backwards. Reading it as a backward distance decodes most streams into
    /// something, which is why it is written down here.
    ///
    /// Three more things the reference imposes that LZ's loop would get wrong:
    ///
    ///   * **the offset is biased by one only when the match is local.** A
    ///     cross-image offset is used as it stands. `if (!image_dist)
    ///     pixel_ofs += 1;`
    ///   * **the length biases are not LZ's.** GLZ adds 2 for the palette forms
    ///     and for the alpha pass, 1 for `rgb16`, and **nothing** for `rgb24`
    ///     and `rgb32`. LZ's own table is different, so borrowing it gives every
    ///     32-bit match one pixel too many.
    ///   * **the image distance is variable-length**, and its layout depends on
    ///     the pixel flag that came before it.
    /// How a literal pixel is read, which is the only part of the loop that
    /// differs between the types decoding to 32-bit output.
    ///
    /// `DECODE_TO_RGB32` sends rgb24, rgb32 and rgba to one function and rgb16
    /// to another, and the two differ in exactly this and in the length bias.
    /// Everything else — the match arithmetic, the window, the offsets — works
    /// on 32-bit output pixels either way.
    enum Literal {
        /// Three bytes, blue then green then red, and a fourth never
        /// transmitted. Covers rgb24 and rgb32 alike.
        case threeBytes
        /// Two bytes of 0555, **high byte first**.
        case fiveFiveFive
        /// One byte, and it lands on the *fourth* byte of a pixel already
        /// decoded by the colour pass. `rgba` is two passes over one buffer:
        /// `glz_rgb32_decode` first, then `glz_rgb_alpha_decode` starting where
        /// the first stopped, with its own control bytes, its own matches and
        /// its own run of the whole image.
        case alpha

        /// GLZ's own table: 2 for the alpha pass and the palette forms, 1 for
        /// rgb16, nothing for rgb24 and rgb32. Not LZ's, which differs.
        var lengthBias: Int {
            switch self {
            case .threeBytes: return 0
            case .fiveFiveFive: return 1
            case .alpha: return 2
            }
        }

        /// Which bytes of a pixel a match copies. The alpha pass must leave
        /// the colour the first pass wrote exactly alone.
        var copiedBytes: Range<Int> { self == .alpha ? 3..<4 : 0..<4 }
    }

    static func decodeRGB32(
        _ stream: [UInt8], from start: Int, pixels count: Int,
        imageID: UInt64, window: Window, literal: Literal = .threeBytes,
        into: [UInt8]? = nil
    ) throws -> (pixels: [UInt8], bytesRead: Int) {
        var out = into ?? [UInt8](repeating: 0, count: count * 4)
        var input = start
        var op = 0

        func byte() throws -> UInt8 {
            guard input < stream.count else { throw Failure.truncated }
            defer { input += 1 }
            return stream[input]
        }

        while op < count {
            var control = Int(try byte())

            if control >= SpiceLZ.maxCopy {
                var length = control >> 5
                var pixelFlag = (control >> 4) & 0x01
                var pixelOffset = control & 0x0F
                var imageDistance = 0

                if length == 7 {                    // longer than the field holds
                    var code: UInt8
                    repeat {
                        code = try byte()
                        length += Int(code)
                    } while code == 255
                }
                pixelOffset += Int(try byte()) << 4

                let code = Int(try byte())
                let imageFlag = (code >> 6) & 0x03
                if pixelFlag == 0 {                 // short pixel offset
                    imageDistance = code & 0x3F
                    for i in 0..<imageFlag {
                        imageDistance += Int(try byte()) << (6 + 8 * i)
                    }
                } else {
                    pixelFlag = (code >> 5) & 0x01
                    pixelOffset += (code & 0x1F) << 12
                    for i in 0..<imageFlag {
                        imageDistance += Int(try byte()) << (8 * i)
                    }
                    if pixelFlag != 0 {             // very long pixel offset
                        pixelOffset += Int(try byte()) << 17
                    }
                }

                length += literal.lengthBias
                if imageDistance == 0 { pixelOffset += 1 }

                guard length > 0, op + length <= count else { throw Failure.truncated }

                if imageDistance == 0 {
                    guard pixelOffset <= op else { throw Failure.referenceBeforeStart }
                    var reference = op - pixelOffset
                    for _ in 0..<length {
                        for byteIndex in literal.copiedBytes {
                            out[op * 4 + byteIndex] = out[reference * 4 + byteIndex]
                        }
                        op += 1
                        reference += 1
                    }
                } else {
                    guard imageDistance <= Int(UInt32.max),
                          let source = window.image(
                            from: imageID, back: UInt32(imageDistance)
                          ) else { throw Failure.referenceOutsideTheWindow }
                    let available = source.pixels.count / 4
                    guard pixelOffset + length <= available else {
                        throw Failure.referenceBeforeStart
                    }
                    for index in 0..<length {
                        for byteIndex in literal.copiedBytes {
                            out[(op + index) * 4 + byteIndex] =
                                source.pixels[(pixelOffset + index) * 4 + byteIndex]
                        }
                    }
                    op += length
                }
            } else {
                control += 1                        // copy count is biased by 1
                guard op + control <= count else { throw Failure.truncated }
                for _ in 0..<control {
                    switch literal {
                    case .threeBytes:
                        out[op * 4] = try byte()        // b
                        out[op * 4 + 1] = try byte()    // g
                        out[op * 4 + 2] = try byte()    // r
                        out[op * 4 + 3] = 0             // never transmitted

                    case .alpha:
                        // Only the fourth byte. The colour pass already wrote
                        // the other three and must not be disturbed.
                        out[op * 4 + 3] = try byte()

                    case .fiveFiveFive:
                        // Written in the reference's own order, and the order
                        // is load-bearing: it reads the two bytes into `r` and
                        // `b`, computes `g` **from those**, and only then
                        // expands `r` and `b` in place. Reordering the three
                        // lines changes the green channel.
                        //
                        // Note also that the high byte comes first — big-endian
                        // inside the pixel, unlike the little-endian 0555
                        // bitmaps elsewhere in this client.
                        // Every step lands in a **byte**, and that truncation
                        // is part of the arithmetic rather than an artefact of
                        // it. In the reference these are fields of a
                        // `rgb32_pixel_t`, so `out->g = (out->r << 6) | ...`
                        // keeps only the low eight bits, and the `>> 5` on the
                        // next line then works on the truncated value.
                        //
                        // Computing it wider and truncating only at the end
                        // gives a different green — which is exactly what
                        // happened here, with blue and red correct and green
                        // wrong by the bits that should have fallen off.
                        var red = UInt8(try byte())
                        var blue = UInt8(try byte())
                        var green = UInt8(truncatingIfNeeded:
                            ((UInt32(red) << 6) | (UInt32(blue) >> 2)) & ~UInt32(0x07))
                        green |= green >> 5
                        red = ((red << 1) & ~UInt8(0x07)) | ((red >> 4) & 0x07)
                        blue = (blue << 3) | ((blue >> 2) & 0x07)
                        out[op * 4] = blue
                        out[op * 4 + 1] = green
                        out[op * 4 + 2] = red
                        out[op * 4 + 3] = 0
                    }
                    op += 1
                }
            }
        }
        return (out, input - start)
    }
}

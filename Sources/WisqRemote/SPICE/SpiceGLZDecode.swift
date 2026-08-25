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
    static func decodeRGB32(
        _ stream: [UInt8], from start: Int, pixels count: Int,
        imageID: UInt64, window: Window
    ) throws -> (pixels: [UInt8], bytesRead: Int) {
        var out = [UInt8](repeating: 0, count: count * 4)
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

                // No length bias for rgb32. See the note above.
                if imageDistance == 0 { pixelOffset += 1 }

                guard length > 0, op + length <= count else { throw Failure.truncated }

                if imageDistance == 0 {
                    guard pixelOffset <= op else { throw Failure.referenceBeforeStart }
                    var reference = op - pixelOffset
                    for _ in 0..<length {
                        for byteIndex in 0..<4 {
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
                        for byteIndex in 0..<4 {
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
                    out[op * 4] = try byte()        // b
                    out[op * 4 + 1] = try byte()    // g
                    out[op * 4 + 2] = try byte()    // r
                    out[op * 4 + 3] = 0             // never transmitted
                    op += 1
                }
            }
        }
        return (out, input - start)
    }
}

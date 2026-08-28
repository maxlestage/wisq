import Foundation
import XCTest

@testable import WisqRemote

/// One LZ match, and how far past its own image it could reach.
///
/// `decompress` loops `while out.count < limit`, which only looks **between**
/// iterations — and one iteration is not bounded. A match's length is built by
/// a continuation that adds 255 for every `0xFF` the stream cares to spend, so
/// a single match can be as long as the payload is, times two hundred and
/// fifty-five. The copy then ran to completion, and the `out.count == limit`
/// at the bottom refused what already existed.
///
/// Measured before this was written, on a four-by-four image whose limit is
/// sixty-four bytes: **400 051 bytes of payload, 645 MiB of peak allocation**,
/// and then a refusal. On a phone that is not a refusal, it is a kill — and it
/// is one SPICE image message.
///
/// The codec already knew the answer. `run`, the two-pass loop written for the
/// `rgba` and `xxxa` forms, checks `written < count` before every element of
/// both its literal run and its copy. The single-pass loop appends into a
/// growing array and did not. Same file, two loops, one guarded.
final class SpiceLZMatchCeilingTests: XCTestCase {
    private func lzHeader(type: UInt32, _ width: Int32, _ height: Int32) -> [UInt8] {
        var bytes: [UInt8] = []
        func be(_ word: UInt32) {
            bytes.append(contentsOf: [
                UInt8((word >> 24) & 0xFF), UInt8((word >> 16) & 0xFF),
                UInt8((word >> 8) & 0xFF), UInt8(word & 0xFF),
            ])
        }
        be(SpiceLZ.magic)
        be(SpiceLZ.versionMajor << 16 | SpiceLZ.versionMinor)
        be(type)
        be(UInt32(bitPattern: width))
        be(UInt32(bitPattern: height))
        be(0)
        be(0)
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 16))
        return bytes
    }

    /// A payload whose single match asks for `255 × continuations` pixels from
    /// an image that declares sixteen.
    private func bomb(continuations: Int) -> [UInt8] {
        var payload = lzHeader(type: 8, 4, 4)  // rgb32, limite 4 × 4 × 4 = 64
        payload.append(0x00)  // un littéral, pour que la correspondance ait une source
        payload.append(contentsOf: [1, 2, 3])
        payload.append(0xE0)  // correspondance : trois bits de longueur à 7, distance nulle
        payload.append(contentsOf: [UInt8](repeating: 255, count: continuations))
        payload.append(0x00)  // fin de la rallonge
        payload.append(0x00)  // octet bas de la distance
        return payload
    }

    /// The probe has to be able to say "something here" first: if the payload
    /// were malformed in some other way it would be refused for the wrong
    /// reason, and the refusal below would prove nothing.
    func testTheBombIsAWellFormedStreamUpToItsLength() throws {
        // Two continuations only: the match asks for 6 + 510 + 1 pixels, still
        // past the sixteen this image has, so it is refused — but by the
        // ceiling, having read the whole header and control structure.
        XCTAssertThrowsError(try SpiceLZ.decompress(bomb(continuations: 2))) { error in
            XCTAssertEqual(error as? SpiceLZ.Failure, .truncated)
        }
    }

    /// The defect, measured rather than described: the payload grows by four
    /// hundred kibibytes and the work must not grow with it.
    ///
    /// The assertion is on peak resident memory, because the outcome cannot
    /// tell the two versions apart — both refuse. What changed is whether the
    /// bytes existed first.
    func testALongMatchDoesNotAllocateWhatItAsksFor() throws {
        // `/proc` is Linux's. Without it this probe would compare zero to zero
        // and pass on every platform, which is worse than not running: a test
        // that cannot fail is a test that says nothing. It skips loudly, and
        // the Linux job is its arbiter.
        guard let before = Self.peakKibibytes() else {
            throw XCTSkip("pic mémoire non lisible ici : /proc/self/status absent")
        }
        XCTAssertThrowsError(try SpiceLZ.decompress(bomb(continuations: 400_000)))
        let grew = (Self.peakKibibytes() ?? before) - before
        XCTAssertLessThan(
            grew, 64 * 1024,
            "pic de \(grew) Kio pour une image qui en déclare 64 octets : la copie n'est pas bornée"
        )
    }

    /// The other edge, and half the work: a match that fits must still be
    /// copied. A guard that refused every match would pass both tests above and
    /// break every real SPICE server.
    func testAMatchThatFitsIsStillCopied() throws {
        var payload = lzHeader(type: 8, 2, 1)  // deux pixels, limite 8 octets
        payload.append(0x00)  // un littéral
        payload.append(contentsOf: [0x11, 0x22, 0x33])
        payload.append(0x20)  // correspondance : longueur 1, distance 1
        payload.append(0x00)
        let (_, pixels) = try SpiceLZ.decompress(payload)
        XCTAssertEqual(pixels.count, 8)
        XCTAssertEqual(Array(pixels.prefix(4)), Array(pixels.suffix(4)), "le second pixel est copié du premier")
    }

    /// Nil where the kernel does not publish it, so the caller can say it was
    /// skipped rather than quietly compare nothing to nothing.
    private static func peakKibibytes() -> Int? {
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else {
            return nil
        }
        for line in status.split(separator: "\n") where line.hasPrefix("VmHWM:") {
            return line.split(separator: " ").compactMap { Int($0) }.first
        }
        return nil
    }
}

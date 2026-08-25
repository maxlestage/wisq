import Foundation

extension SpiceGLZ {
    /// The window of decoded images a GLZ stream may reach back into.
    ///
    /// This is the part of GLZ that makes it a **session** feature rather than
    /// a codec: a stream on its own means nothing without the images that came
    /// before it, so the window outlives any single decode and belongs to the
    /// channel.
    ///
    /// Unlike the header, the bit reader or the family tables, a ring buffer
    /// has no reference *number* to be compared against — `decode-glz.c` gives
    /// its behaviour, not a table of answers. So this is checked as what it is:
    /// a data structure with stated semantics, each of them read off the
    /// reference and pinned by a test. Pretending otherwise — dressing unit
    /// tests up as differential ones — would claim an authority they do not
    /// have.
    struct Window {
        /// `INIT_IMAGES_CAPACITY` is 100 in the reference's comment but the
        /// code uses 16, and the code is what runs.
        static let initialCapacity = 16

        struct Image {
            let id: UInt64
            let winHeadDistance: UInt32
            /// BGRA, top row first, as everything else in this client.
            var pixels: [UInt8]
            let width: Int
            let height: Int
        }

        private(set) var slots: [Image?]
        private(set) var oldest: UInt64 = 0
        /// The first id not yet known to be present. Images may arrive out of
        /// order — several displays, separate sockets — so the run of known
        /// ids ends here even when later ones have landed.
        private(set) var tailGap: UInt64 = 0

        init() { slots = [Image?](repeating: nil, count: Self.initialCapacity) }

        var capacity: Int { slots.count }
        var count: Int { slots.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

        /// Empties the window, as `glz_decoder_window_clear` does on reconnect
        /// and on session switching.
        ///
        /// **`oldest` is reset here and the reference does not reset it.** A
        /// deliberate difference, and this is why: `oldest` only ever moves
        /// forward, and `release` stops as soon as it reaches its target. After
        /// a reconnect the ids restart at zero, so every later target is far
        /// below the stale `oldest` and nothing is ever released again — while
        /// `add` keeps doubling the array on each slot collision. The reference
        /// therefore leaks a whole session's images on reconnect and grows
        /// without bound.
        ///
        /// Left alone that is a paper cut on a desktop and a real problem on a
        /// phone. Nothing in the protocol asks for it; it is an omission in one
        /// function, not a rule.
        mutating func clear() {
            slots = [Image?](repeating: nil, count: Self.initialCapacity)
            tailGap = 0
            oldest = 0
        }

        /// Doubles the array and rehashes, skipping the holes.
        private mutating func grow() {
            var bigger = [Image?](repeating: nil, count: slots.count * 2)
            for case let image? in slots {
                bigger[Int(image.id % UInt64(bigger.count))] = image
            }
            slots = bigger
        }

        mutating func add(_ image: Image) {
            var slot = Int(image.id % UInt64(slots.count))
            if slots[slot] != nil {
                grow()
                slot = Int(image.id % UInt64(slots.count))
            }
            slots[slot] = image

            // Close the gap: advance over the run of ids that are now present,
            // and **no further than the id just added** — that bound is the
            // reference's, and it means filling a hole does not run the counter
            // on over images that arrived early. They are in the window and
            // findable; they are simply not counted until their own ids come
            // round. `releaseAfterAdding` reads `slots[tailGap - 1]`, so the
            // image deciding what is still needed is not always the newest.
            while tailGap <= image.id, slots[Int(tailGap % UInt64(slots.count))] != nil {
                tailGap += 1
            }
        }

        /// The image a match refers to, or nil if it is not in the window.
        ///
        /// `dist` is how far back from `id`, not an absolute id. Returning nil
        /// rather than reaching for a slot that holds *some* image is the whole
        /// point: the slot is `target % capacity`, so a wrong id lands on a
        /// real image of a different generation and the picture that comes out
        /// is plausible.
        func image(from id: UInt64, back distance: UInt32) -> Image? {
            guard UInt64(distance) <= id else { return nil }
            let target = id - UInt64(distance)
            guard let found = slots[Int(target % UInt64(slots.count))],
                  found.id == target else { return nil }
            return found
        }

        /// Drops everything older than `upTo`, as the reference does after each
        /// image using `id - winHeadDistance` of the newest one.
        mutating func release(before upTo: UInt64) {
            while oldest < upTo {
                slots[Int(oldest % UInt64(slots.count))] = nil
                oldest += 1
            }
        }

        /// What the reference runs at the end of every decode: the newest image
        /// says how far back anything may still reach, and the rest goes.
        mutating func releaseAfterAdding() {
            guard tailGap > 0,
                  let newest = slots[Int((tailGap - 1) % UInt64(slots.count))] else { return }
            release(before: newest.id - UInt64(newest.winHeadDistance))
        }
    }
}

@testable import WisqRemote

/// The adaptive model's layout and behaviour, as the reference produces them.
///
/// Dumped by `scripts/spice-quic-fixtures/qmodel.c`, which `#include`s
/// `quic.c` so it can call `find_model_params`, `fill_model_structures`,
/// `tabrand`, `set_wm_trigger` and `update_model` directly. The bucket map and
/// the update trace are the codec's own numbers, not a second reading of the
/// same C.
enum SpiceQUICModelFixtures {
    struct Update: Equatable {
        let value: UInt8
        let bestCode: Int
        let counters: [UInt32]
    }

    /// bpc 8: 8 buckets over 256 levels, 8 counters each.
    static let bucketCount8 = 8
    static let bucketOfValue8: [Int] = [
        0, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6,
        6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
        6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
        6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
        7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7
    ]
    static let updates8: [Update] = [
        Update(value: 0, bestCode: 0, counters: [1, 2, 3, 4, 5, 6, 7, 8]),
        Update(value: 1, bestCode: 0, counters: [3, 4, 6, 8, 10, 12, 14, 16]),
        Update(value: 2, bestCode: 0, counters: [6, 7, 9, 12, 15, 18, 21, 24]),
        Update(value: 3, bestCode: 1, counters: [10, 10, 12, 16, 20, 24, 28, 32]),
        Update(value: 7, bestCode: 1, counters: [18, 15, 16, 20, 25, 30, 35, 40]),
        Update(value: 15, bestCode: 2, counters: [34, 24, 22, 25, 30, 36, 42, 48]),
        Update(value: 31, bestCode: 3, counters: [60, 41, 32, 32, 36, 42, 49, 56]),
        Update(value: 63, bestCode: 3, counters: [86, 67, 50, 43, 44, 49, 56, 64]),
        Update(value: 127, bestCode: 4, counters: [112, 93, 76, 62, 56, 58, 64, 72]),
        Update(value: 255, bestCode: 5, counters: [138, 119, 102, 87, 75, 70, 73, 80]),
        Update(value: 128, bestCode: 5, counters: [164, 145, 128, 107, 88, 80, 82, 88]),
        Update(value: 64, bestCode: 5, counters: [190, 171, 147, 119, 97, 88, 90, 96]),
        Update(value: 5, bestCode: 5, counters: [196, 175, 151, 123, 102, 94, 97, 104]),
        Update(value: 5, bestCode: 5, counters: [202, 179, 155, 127, 107, 100, 104, 112]),
        Update(value: 5, bestCode: 5, counters: [208, 183, 159, 131, 112, 106, 111, 120]),
        Update(value: 200, bestCode: 5, counters: [117, 104, 92, 78, 64, 59, 60, 64]),
        Update(value: 199, bestCode: 6, counters: [143, 130, 118, 103, 81, 71, 69, 72]),
        Update(value: 1, bestCode: 6, counters: [145, 132, 121, 107, 86, 77, 76, 80]),
        Update(value: 0, bestCode: 6, counters: [146, 134, 124, 111, 91, 83, 83, 88]),
        Update(value: 250, bestCode: 6, counters: [172, 160, 150, 136, 110, 95, 92, 96]),
    ]

    /// bpc 5: 5 buckets over 32 levels, 8 counters each.
    static let bucketCount5 = 5
    static let bucketOfValue5: [Int] = [
        0, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 4
    ]
    static let updates5: [Update] = [
        Update(value: 0, bestCode: 0, counters: [1, 2, 3, 4, 5]),
        Update(value: 1, bestCode: 0, counters: [3, 4, 6, 8, 10]),
        Update(value: 2, bestCode: 0, counters: [6, 7, 9, 12, 15]),
        Update(value: 3, bestCode: 1, counters: [10, 10, 12, 16, 20]),
        Update(value: 7, bestCode: 1, counters: [18, 15, 16, 20, 25]),
        Update(value: 15, bestCode: 2, counters: [34, 24, 22, 25, 30]),
        Update(value: 31, bestCode: 3, counters: [59, 40, 31, 31, 35]),
        Update(value: 31, bestCode: 3, counters: [84, 56, 40, 37, 40]),
        Update(value: 31, bestCode: 3, counters: [109, 72, 49, 43, 45]),
        Update(value: 31, bestCode: 3, counters: [134, 88, 58, 49, 50]),
        Update(value: 0, bestCode: 3, counters: [135, 90, 61, 53, 55]),
        Update(value: 0, bestCode: 3, counters: [136, 92, 64, 57, 60]),
        Update(value: 5, bestCode: 3, counters: [142, 96, 68, 61, 65]),
        Update(value: 5, bestCode: 3, counters: [148, 100, 72, 65, 70]),
        Update(value: 5, bestCode: 3, counters: [154, 104, 76, 69, 75]),
        Update(value: 8, bestCode: 3, counters: [163, 110, 81, 74, 80]),
        Update(value: 7, bestCode: 3, counters: [171, 115, 85, 78, 85]),
        Update(value: 1, bestCode: 3, counters: [173, 117, 88, 82, 90]),
        Update(value: 0, bestCode: 3, counters: [174, 119, 91, 86, 95]),
        Update(value: 26, bestCode: 3, counters: [199, 134, 100, 92, 100]),
    ]

    /// `stabrand()` then the first 40 draws of `tabrand()`.
    static let chaosSeed: UInt32 = 255
    static let chaosDraws: [UInt32] = [
        46495042, 893548311, 794435923, 2453991765, 2077388039, 894197842,
        1462934312, 697534094, 1826128012, 343623392, 2581292719, 3811265708,
        459739748, 2638427270, 1654964626, 101227083, 2654850628, 3668700691,
        572794346, 2758751005, 3445133904, 2344099199, 3367450297, 898927923,
        3618406352, 1606297603, 754696453, 20823118, 2050458127, 972590750,
        3990194068, 3305596553, 4239238564, 1690498157, 3015324227, 2306127097,
        1510321853, 548392192, 971157512, 2292288069
    ]

    /// The halving boundary, taken from the reference by setting the trigger
    /// directly — `set_wm_trigger` can only produce its eleven tabulated
    /// values, and none of them is reached exactly by an ordinary sequence.
    ///
    /// `update_model` halves when the best total is **strictly greater** than
    /// the trigger. The two readings of that comparison differ only here.
    static let boundaryTrigger: UInt32 = 1
    static let boundaryAt = Update(
        value: 0, bestCode: 0, counters: [1, 2, 3, 4, 5, 6, 7, 8]
    )
    static let boundaryBelowTrigger: UInt32 = 0
    static let boundaryBelow = Update(
        value: 0, bestCode: 0, counters: [0, 1, 1, 2, 2, 3, 3, 4]
    )

    /// `set_wm_trigger` for wait-mask indices 0…12, past the clamp at ten.
    static let triggers: [UInt32] = [110, 550, 900, 800, 550, 400, 350, 250, 140, 160, 140, 140, 140]
}

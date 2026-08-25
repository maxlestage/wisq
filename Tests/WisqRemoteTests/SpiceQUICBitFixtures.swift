@testable import WisqRemote

/// The reference bit reader's own state, step by step.
///
/// Produced by `scripts/spice-quic-fixtures/qbits.c`, which `#include`s
/// `quic.c` and prints `io_word` and `io_available_bits` after
/// `init_decode_io` and after every `decode_eatbits`. Comparing only the final
/// answer would let a reader be wrong in the middle and right at the end;
/// comparing every step says exactly which call diverged.
///
/// The bit lengths cross both branches of `decode_eatbits` — the one where the
/// lookahead still has enough bits and the one where it has to fetch —
/// including at the boundaries 1 and 31.
enum SpiceQUICBitFixtures {
    struct Step: Equatable {
        let window: UInt32
        let availableBits: Int
    }

    struct Trace {
        let name: String
        let stream: String
        /// How many bits each successive `eat` consumes.
        let lengths: [Int]
        /// State after `init`, then after each `eat`.
        let steps: [Step]
    }

    static let all: [Trace] = [
        Trace(
            name: "rgb32 8x6",
            stream: """
                5155494300000000040000000800000006000000800028508080808080808080100c0281
                fff7ff7fc40200c0008f000000401b00000010041f0000bcc5a9bbcbb67bc7b35d59bedd
                bcd3edf70480103c88880102618c30468431c21810e008634618070818618c30638431c2
                0000000800000000
                """,
            lengths: [16, 16, 16, 16, 3, 5, 13, 1, 31, 7, 16, 16, 9, 2, 30, 11],
            steps: [
                Step(window: 0x43495551, availableBits: 0),
                Step(window: 0x55510000, availableBits: 16),
                Step(window: 0x00000000, availableBits: 0),
                Step(window: 0x00000000, availableBits: 16),
                Step(window: 0x00000004, availableBits: 0),
                Step(window: 0x00000020, availableBits: 29),
                Step(window: 0x00000400, availableBits: 24),
                Step(window: 0x00800000, availableBits: 11),
                Step(window: 0x01000000, availableBits: 10),
                Step(window: 0x01000000, availableBits: 11),
                Step(window: 0x80000000, availableBits: 4),
                Step(window: 0x00006502, availableBits: 20),
                Step(window: 0x65028008, availableBits: 4),
                Step(window: 0x05001010, availableBits: 27),
                Step(window: 0x14004040, availableBits: 25),
                Step(window: 0x10101010, availableBits: 27),
                Step(window: 0x80808080, availableBits: 16)
            ]
        ),
        Trace(
            name: "rgb24 16x12",
            stream: """
                515549430000000003000000100000000c000000800028508080808080808080100c0281
                ffffff7ffe3fffff100b00c0003c020000006d00020040107f0000f016a7ee2edbee1dcf
                7765f976f04eb7dfdd6264f8e3e06420850484ad89019053e25458000084200c100a1020
                4208218408218410218410428410420810420821420821841020c0112184100a84104208
                104208214608218418218c10618430420010c20800806d000000800a30a003002e00380d
                0a5b00005c3441c060563dd601800b744f13a9a1d1c02c06af76cf0684d3e02e1b5810a5
                43800d474b0bf32bfdee11fa14f104a0b805800b71c70ea88007d9ed0f6ca8171344901b
                6d6362b42a0731812ea06ac585120fdec28f066516350fc03c0e5995451f29c7056d00cd
                89563525030058661f19741d7f8be35b19a54001d014329fb5d6e27f75cddac28ed084e9
                80d79dd580779b78139a0600d4fc6c5c41e5ac77ec2ed6857c7675015042d393d95763e8
                13a963010f06380dc9b0a09f1004e6b9f1ffb83b00000000
                """,
            lengths: [1, 1, 1, 1, 31, 31, 31, 5, 27, 16, 16, 8, 8, 8, 8, 15, 17, 2],
            steps: [
                Step(window: 0x43495551, availableBits: 0),
                Step(window: 0x8692aaa2, availableBits: 31),
                Step(window: 0x0d255544, availableBits: 30),
                Step(window: 0x1a4aaa88, availableBits: 29),
                Step(window: 0x34955510, availableBits: 28),
                Step(window: 0x00000000, availableBits: 29),
                Step(window: 0x0000000c, availableBits: 30),
                Step(window: 0x00000020, availableBits: 31),
                Step(window: 0x00000400, availableBits: 26),
                Step(window: 0x00000018, availableBits: 31),
                Step(window: 0x0018a050, availableBits: 15),
                Step(window: 0xa0500101, availableBits: 31),
                Step(window: 0x50010101, availableBits: 23),
                Step(window: 0x01010101, availableBits: 15),
                Step(window: 0x01010101, availableBits: 7),
                Step(window: 0x01010101, availableBits: 31),
                Step(window: 0x80808080, availableBits: 16),
                Step(window: 0x01010101, availableBits: 31),
                Step(window: 0x04040404, availableBits: 29)
            ]
        ),
        Trace(
            name: "rgb16 16x12",
            stream: """
                515549430000000002000000100000000c0000006108212d3be75818bbbbbbbbff9fffff
                1000006000800100a90800d82b6c96b70b780bcabe5f51402a48985050602fe4a04951d1
                0a10a08803c22ffc70804e09270c08bfe1a1d3c25af88401015a3c74fcc2af00e9943020
                0c08bff0a7d3c227f00903c210f0e9b409000002581b8b007a078af481730f438303b0b2
                0ec4303fa0362ce901a148c582452c8a6be91893fd1168304048f01c369892046c1b98ab
                8085f3a31b56031bf30f256bf31044af5364621f3a473ddb3a80f270e8164ab8dfbc68eb
                00081386be715c1eb5fe9f7279fce633b7e7b2fb345b934af288feecfe307dc55cf25e49
                1aaf15220080b8d600000000
                """,
            lengths: [8, 8, 8, 8, 8, 8, 8, 8, 31, 1, 31, 1, 16, 16, 16, 16, 20, 12, 4],
            steps: [
                Step(window: 0x43495551, availableBits: 0),
                Step(window: 0x49555100, availableBits: 24),
                Step(window: 0x55510000, availableBits: 16),
                Step(window: 0x51000000, availableBits: 8),
                Step(window: 0x00000000, availableBits: 0),
                Step(window: 0x00000000, availableBits: 24),
                Step(window: 0x00000000, availableBits: 16),
                Step(window: 0x00000000, availableBits: 8),
                Step(window: 0x00000002, availableBits: 0),
                Step(window: 0x00000008, availableBits: 1),
                Step(window: 0x00000010, availableBits: 0),
                Step(window: 0x00000006, availableBits: 1),
                Step(window: 0x0000000c, availableBits: 0),
                Step(window: 0x000c2d21, availableBits: 16),
                Step(window: 0x2d210861, availableBits: 0),
                Step(window: 0x08611858, availableBits: 16),
                Step(window: 0x1858e73b, availableBits: 0),
                Step(window: 0x73bbbbbb, availableBits: 12),
                Step(window: 0xbbbbbbbb, availableBits: 0),
                Step(window: 0xbbbbbbbf, availableBits: 28)
            ]
        ),
    ]
}

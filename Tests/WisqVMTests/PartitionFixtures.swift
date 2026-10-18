import Foundation

// La table de partitions de l'image cloud « nocloud » de Debian 13, telle
// que l'écrit l'équipe cloud de Debian : `debian-13-nocloud-amd64.qcow2`, somme
// SHA-512 401ffd04…5bd0df26 publiée dans SHA512SUMS, convertie en brut par
// `qemu-img convert -O raw`. Ne sont gardés que les octets non nuls des 34
// premiers et des 33 derniers secteurs : le MBR protecteur, l'en-tête GPT et
// ses entrées, et leur copie de secours. Ne pas éditer à la main ; pour les
// refaire : scripts/build-partition-fixtures.py.
enum PartitionFixtures {
    /// La taille du disque virtuel : 3 Gio.
    static let debianSize: UInt64 = 3221225472

    /// Les plages non nulles : décalage, octets en hexadécimal.
    static let debianRuns: [(UInt64, String)] = [
        (0, "eb6390"),
        (91, [
            "800008000000000000fffa9090f6c2807405f6c2707402b280ea797c000031c08ed88ed0bc0020fba0647c3cff740288",
            "c252be807de81701be057cb441bbaa55cd135a52723d81fb55aa753783e101743231c0894404408844ff894402c70410",
            "00668b1e5c7c66895c08668b1e607c66895c0cc744060070b442cd137205bb0070eb76b408cd13730d5a84d20f83d800",
            "be8b7de98200660fb6c68864ff40668944040fb6d1c1e20288e888f4408944080fb6c2c0e80266890466a1607c6609c0",
            "754e66a15c7c6631d266f73488d131d266f774043b44087d37fec188c530c0c1e80208c188d05a88c6bb00708ec331db",
            "b80102cd13721e8cc3601eb900018edb31f6bf00808ec6fcf3a51f61ff265a7cbe867deb03be957de83400be9a7de82e",
            "00cd18ebfe47525542200047656f6d0048617264204469736b005265616400204572726f720d0a00bb0100b40ecd10ac",
            "3c0075f4c3",
        ].joined()),
        (448, "0200eeffffff01000000ffff5f"),
        (510, [
            "55aa4546492050415254000001005c00000053426d4b000000000100000000000000ffff5f0000000000000800000000",
            "0000deff5f0000000000eb32df8827db1249992c0c4d19d4a0060200000000000000800000008000000058f8fc7f",
        ].joined()),
        (1024, "e3bc684fcde8b14d96e7fbcaf984b7091dd47b3f64e59549bb29b2aebe93a04c0000040000000000fff75f"),
        (2688, "4861682149646f6e744e656564454649f566da8f8f36b54eaf23aa818f8f74860008000000000000ff1f"),
        (2816, "28732ac11ff8d211ba4b00a0c93ec93b29b136d1ec415c409e4cfd190105a0c80020000000000000ffff03"),
        (3221208576, "e3bc684fcde8b14d96e7fbcaf984b7091dd47b3f64e59549bb29b2aebe93a04c0000040000000000fff75f"),
        (3221210240, "4861682149646f6e744e656564454649f566da8f8f36b54eaf23aa818f8f74860008000000000000ff1f"),
        (3221210368, "28732ac11ff8d211ba4b00a0c93ec93b29b136d1ec415c409e4cfd190105a0c80020000000000000ffff03"),
        (3221224960, "4546492050415254000001005c000000efe0b2a200000000ffff5f000000000001"),
        (3221225001, [
            "08000000000000deff5f0000000000eb32df8827db1249992c0c4d19d4a006dfff5f0000000000800000008000000058",
            "f8fc7f",
        ].joined()),
    ]

    /// Le même disque en qcow2 (`qemu-img convert -O qcow2 -o cluster_size=4096`),
    /// 49152 octets, en deflate brut puis base64.
    static let debianQcow2Size = 49152
    static let debianQcow2 = [
        "7d1fSFNRHMDxs+uUFZqWD9VDugj6R0QLqQetVJY1KquVECKkNC9GlDJnEG10S4k7iimEQT3ECnqR6I+Y/THWpmR/YJDSQyRk",
        "f4hWi3qo7I/V7S6nkCAVFJl9P5d7fueeC78D52xwHy6/u77A1i+ESBDfS441waHLpHhcEI9pscYgfo5RP6sEAAAAAAD4y8ws",
        "AQAAAAAAY5lhhAMAAAAAAIwZyre2lIUAAAAAAAAAAAAAAAAAAAAAAGAUUuLtQKQ8PwAAAAAAY1l0S8OfSq0I00BH+9jQ0Neu",
        "uBL72qtcUrPyfJdbCEvQd9d3+4ow9/sd7hzNJant9oDiiUw2BBLdLXltTUXh9GK7c8ne/qKmmsW1Dw2uhZag12rMVa2a1ypd",
        "N6YJ+UBGiVv2lpj0Tmmsk3zdmiSqWvLD6c7ENlEV3dliCqdXpxTXdafW3hWBA55n+4Sc2tqpOrRcWc+V2toVeiSpEfVNrtdq",
        "Sm1tD0Yk2WuUj+vZxgVrCuXjen5Lt/wuS+2KBZcx22ryLP4SUq8tCIYikimk3i5WO/WpfB2WnosGSZ8442BHacYlYfD1WPqu",
        "CsXX+en1ycwybWaxO7DfE00INHoiWSJw1BOZL8JTol9W2IvyzWJFeeV2sbLM6TBbt1ZvE/byMocwL3c6K50p40WbQbRMCKed",
        "yhE1bzqGL7IkXmqaFivXqGmbf3mLipqWF9jM6/LsG2OFIEv0kQ3521fF7gwWgBzKGt/L+/Hr6MJedVbPJNuReclrpt7xJ0lD",
        "mz5wbnr/aQ//rtHv8ZWKteHIuTWHn/bf+lB3Ydy0O7uXOZ402trmNJ8OHPKvHvh8p/47eLeZxQIA/DYryyqm2xyVO1yF5eUO",
        "/WHkrXyvvn7R+cIzM5r21te79g89Q2b+mflnV88NZb7vnnh5lfDfXHoze865RV0v8kpyj63+PNWQ6L8x+GksTUtgswAAAAAA",
        "AACMCsq3tiEe/SPcP8tCAQAAAMB/gvc/AQB/A+9/AgAAAAAAAAAA/F7D63+9etB8IjY+WPdrsA7Yj+p/9cbHFUH9r3/JVw==",
    ].joined()
}

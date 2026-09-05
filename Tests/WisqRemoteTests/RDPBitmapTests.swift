import XCTest
import WisqCore

@testable import WisqRemote

/// Les mises à jour d'écran : ce que le serveur annonce, et ce qu'on en lit.
final class RDPBitmapUpdateTests: XCTestCase {
    /// **Une mise à jour qui ne porte pas de pixels est un genre à part.** La
    /// lire comme un bitmap prendrait ses deux octets de garniture pour un
    /// compte de rectangles.
    func testTheRealSynchroniseUpdateCarriesNoBitmap() throws {
        XCTAssertEqual(try RDPBitmapUpdate.kind(of: RDPServerFixtures.updateSynchronise),
                       .synchronise)
        XCTAssertThrowsError(try RDPBitmapUpdate.rectangles(RDPServerFixtures.updateSynchronise))
    }

    /// Le rectangle unique d'une vraie mise à jour, tel que xrdp l'a décrit.
    func testTheRealSingleRectangleIsReadWholeAndCompressed() throws {
        let rectangles = try RDPBitmapUpdate.rectangles(RDPServerFixtures.updateWithOneRectangle)
        XCTAssertEqual(rectangles.count, 1)
        let it = try XCTUnwrap(rectangles.first)
        XCTAssertEqual(it.width, 8)
        XCTAssertEqual(it.height, 15)
        XCTAssertEqual(it.bitsPerPixel, 24)
        XCTAssertTrue(it.compressed)
        // **La destination est plus petite que le bloc de pixels.** Le serveur
        // arrondit la largeur ; peindre le bloc entier déborderait de deux
        // pixels sur la droite.
        XCTAssertEqual(it.right - it.left + 1, 7)
        XCTAssertEqual(it.bottom - it.top + 1, 15)
    }

    /// **Deux rectangles dans un message, et le second n'est trouvé que si la
    /// longueur du premier est respectée.** C'est la lecture qui casse en
    /// silence quand on se trompe : le second rectangle prend des pixels pour
    /// des coordonnées.
    func testTheRealTwoRectangleUpdateFindsBoth() throws {
        let rectangles = try RDPBitmapUpdate.rectangles(RDPServerFixtures.updateWithTwoRectangles)
        XCTAssertEqual(rectangles.count, 2)
        XCTAssertEqual(rectangles[0].height, 22)
        XCTAssertEqual(rectangles[1].height, 3)
        for it in rectangles {
            XCTAssertEqual(it.width, 240)
            XCTAssertEqual(it.bitsPerPixel, 24)
        }
        // Le second est juste au-dessus du premier, et ils se touchent.
        XCTAssertEqual(rectangles[1].bottom + 1, rectangles[0].top)
    }

    /// **L'en-tête de compression est retiré, et ce qu'il annonce est la vraie
    /// longueur.** Le garder ferait décaler l'image de huit octets sans erreur.
    func testTheCompressionHeaderIsRemovedAndItsLengthObeyed() throws {
        let it = try XCTUnwrap(
            try RDPBitmapUpdate.rectangles(RDPServerFixtures.updateWithOneRectangle).first)
        let bytes = [UInt8](RDPServerFixtures.updateWithOneRectangle)
        let declared = Int(bytes[20]) | Int(bytes[21]) << 8     // longueur du bloc
        let main = Int(bytes[24]) | Int(bytes[25]) << 8         // corps comprimé
        XCTAssertEqual(it.data.count, main)
        XCTAssertEqual(it.data.count, declared - 8)
        XCTAssertNotEqual([UInt8](it.data.prefix(2)), Array(bytes[22..<24]),
                          "le corps ne doit pas commencer par l'en-tête")
    }

    /// Et ces pixels-là se décomprimment à la taille que l'en-tête annonce.
    func testTheRealRectangleDecompressesToTheSizeItAnnounces() throws {
        let it = try XCTUnwrap(
            try RDPBitmapUpdate.rectangles(RDPServerFixtures.updateWithOneRectangle).first)
        let pixels = try RDPInterleavedRLE.decompress(
            it.data, width: it.width, height: it.height, bitsPerPixel: it.bitsPerPixel)
        XCTAssertEqual(pixels.count, it.width * it.height * 3)
    }

    // MARK: - Ce qu'on refuse

    /// Un compte de rectangles absurde est refusé avant la boucle.
    func testAnAbsurdRectangleCountIsRefused() {
        var bytes = [UInt8](RDPServerFixtures.updateWithOneRectangle)
        bytes[2] = 0xFF
        bytes[3] = 0xFF
        XCTAssertThrowsError(try RDPBitmapUpdate.rectangles(Data(bytes))) {
            guard case WisqError.malformedMessage(let why) = $0 else {
                return XCTFail("attendu un message malformé, obtenu \($0)")
            }
            XCTAssertTrue(why.contains("65535"), why)
        }
    }

    /// **Un rectangle qui annonce plus de pixels qu'il n'en envoie est refusé.**
    /// Sans cette borne, la lecture continuerait au-delà du message.
    func testARectangleThatAnnouncesMoreThanItSendsIsRefused() {
        // **Quatre octets manquants suffisent.** Une garde qui ne refuse que
        // les grosses troncatures laisse passer les petites, qui sont
        // justement celles qu'un serveur produit par accident.
        let cut = RDPServerFixtures.updateWithOneRectangle.dropLast(4)
        XCTAssertThrowsError(try RDPBitmapUpdate.rectangles(Data(cut))) {
            guard case WisqError.malformedMessage(let why) = $0 else {
                return XCTFail("attendu un message malformé, obtenu \($0)")
            }
            XCTAssertTrue(why.contains("pixels"), why)
        }
    }

    /// Un rectangle sans même son en-tête de dix-huit octets est refusé.
    func testARectangleWithoutItsHeaderIsRefused() {
        // Seize octets d'en-tête au lieu de dix-huit : deux de moins que le
        // minimum, ce qui est exactement le cas qu'une garde trop lâche laisse
        // passer avant de lire deux octets qui ne sont pas là.
        var bytes = [UInt8](RDPServerFixtures.updateWithOneRectangle.prefix(20))
        bytes[2] = 1
        bytes[3] = 0
        XCTAssertThrowsError(try RDPBitmapUpdate.rectangles(Data(bytes)))
    }

    /// Un en-tête de compression qui annonce un corps plus long que son bloc
    /// est refusé.
    func testACompressionHeaderLongerThanItsBlockIsRefused() {
        var bytes = [UInt8](RDPServerFixtures.updateWithOneRectangle)
        // Quatre octets de trop seulement : le corps comprimé ne peut pas
        // dépasser son bloc moins les huit octets d'en-tête.
        let length = Int(bytes[20]) | Int(bytes[21]) << 8
        bytes[24] = UInt8((length - 4) & 0xFF)
        bytes[25] = UInt8((length - 4) >> 8)
        XCTAssertThrowsError(try RDPBitmapUpdate.rectangles(Data(bytes))) {
            guard case WisqError.malformedMessage(let why) = $0 else {
                return XCTFail("attendu un message malformé, obtenu \($0)")
            }
            XCTAssertTrue(why.contains("comprimé"), why)
        }
    }

    /// **Un drapeau dit que l'en-tête de compression a été omis**, et il faut
    /// le croire : le lire quand même mangerait huit octets de pixels.
    func testTheOmittedHeaderFlagIsObeyed() throws {
        var bytes = [UInt8](RDPServerFixtures.updateWithOneRectangle)
        bytes[19] |= 0x04                                        // 0x0400, dans l'octet haut
        let it = try XCTUnwrap(try RDPBitmapUpdate.rectangles(Data(bytes)).first)
        let declared = Int(bytes[20]) | Int(bytes[21]) << 8
        XCTAssertEqual(it.data.count, declared, "aucun en-tête à retirer")
    }

    /// Un genre de mise à jour inconnu est nommé plutôt qu'ignoré.
    func testAnUnknownUpdateKindIsRefused() {
        XCTAssertThrowsError(try RDPBitmapUpdate.kind(of: Data([0x09, 0x00])))
    }
}

/// **Le codec entrelacé, jugé par FreeRDP 2.11.**
///
/// Voir `RDPBitmapVectors` pour d'où viennent les vecteurs et pourquoi ils ne
/// sont pas de moi. Ce qui est mesuré ici est l'égalité pixel pour pixel avec
/// une seconde implémentation, sur des rectangles d'un vrai serveur, des
/// motifs comprimés par FreeRDP lui-même, et des flux fabriqués pour les codes
/// que son compresseur n'émet jamais.
final class RDPInterleavedRLETests: XCTestCase {
    /// **Les trente-huit vecteurs donnent les mêmes pixels que FreeRDP.**
    func testEveryVectorDecodesToWhatFreeRDPDecodes() throws {
        for vector in RDPBitmapVectors.all {
            let pixels = try RDPInterleavedRLE.decompress(
                vector.data, width: vector.width, height: vector.height,
                bitsPerPixel: vector.depth)
            XCTAssertEqual(pixels.count, vector.width * vector.height * (vector.depth == 24 ? 3 : 2),
                           vector.name)
            let wide = RDPBitmapVectors.asBGRX32(pixels, depth: vector.depth)
            if let expected = vector.expected {
                XCTAssertEqual(wide, [UInt8](expected), vector.name)
            }
            let digest = RDPCrypto.sha1(wide).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, vector.digest, vector.name)
        }
    }

    /// Et les trois familles de vecteurs sont toutes représentées : sans quoi
    /// le test ci-dessus pourrait passer en n'ayant mesuré qu'un seul genre de
    /// flux.
    func testTheThreeFamiliesOfVectorsAreAllPresent() {
        let names = RDPBitmapVectors.all.map(\.name)
        XCTAssertGreaterThanOrEqual(names.filter { $0.hasPrefix("xrdp-") }.count, 6,
                                    "des rectangles d'un vrai serveur")
        XCTAssertGreaterThanOrEqual(names.filter { $0.hasPrefix("forge") }.count, 18,
                                    "des motifs comprimés par FreeRDP")
        XCTAssertGreaterThanOrEqual(names.filter { $0.hasPrefix("synth-") }.count, 12,
                                    "des flux pour les codes que FreeRDP n'émet pas")
        XCTAssertGreaterThanOrEqual(names.filter { $0.hasPrefix("insert-") }.count, 3,
                                    "des fonds dos à dos, que rien d'autre ne produit")
        for depth in [24, 16, 15] {
            XCTAssertTrue(RDPBitmapVectors.all.contains { $0.depth == depth },
                          "aucun vecteur en \(depth) bits")
        }
    }

    // MARK: - Ce qu'on refuse

    /// **Le 8 bits est refusé plutôt que deviné.** Ses « couleurs » sont des
    /// index dans une palette que wisq ne tient pas : décoder marcherait, et
    /// chaque pixel serait d'une couleur quelconque.
    func testEightBitsPerPixelIsRefusedBecauseThereIsNoPalette() {
        XCTAssertThrowsError(try RDPInterleavedRLE.decompress(
            Data([0x81, 0x00]), width: 1, height: 1, bitsPerPixel: 8)) {
            guard case WisqError.unsupportedEncoding(let depth) = $0 else {
                return XCTFail("attendu un encodage non pris en charge, obtenu \($0)")
            }
            XCTAssertEqual(depth, 8)
        }
    }

    /// Et le 32 bits aussi, qui emploie un autre codec.
    func testThirtyTwoBitsPerPixelIsRefused() {
        XCTAssertThrowsError(try RDPInterleavedRLE.decompress(
            Data([0x81, 0, 0, 0, 0]), width: 1, height: 1, bitsPerPixel: 32))
    }

    /// **Un flux qui écrit plus de pixels que le rectangle n'en contient est
    /// arrêté.** Sans cette garde, il écrirait derrière le tampon.
    func testAStreamThatOverflowsItsRectangleIsRefused() {
        // Une course de couleur de trente et un pixels dans un rectangle de
        // quatre.
        let stream = Data([0x7F, 0x11, 0x22, 0x33])
        XCTAssertThrowsError(try RDPInterleavedRLE.decompress(
            stream, width: 2, height: 2, bitsPerPixel: 24)) {
            guard case WisqError.malformedMessage(let why) = $0 else {
                return XCTFail("attendu un message malformé, obtenu \($0)")
            }
            XCTAssertTrue(why.contains("déborde"), why)
        }
    }

    /// Un flux coupé au milieu d'une couleur est refusé plutôt que complété.
    func testATruncatedStreamIsRefused() {
        XCTAssertThrowsError(try RDPInterleavedRLE.decompress(
            Data([0x64, 0x11, 0x22]), width: 4, height: 1, bitsPerPixel: 24)) {
            guard case WisqError.malformedMessage(let why) = $0 else {
                return XCTFail("attendu un message malformé, obtenu \($0)")
            }
            XCTAssertTrue(why.contains("tronqué"), why)
        }
    }

    /// Les codes que la spécification laisse vides sont refusés, pas ignorés.
    func testTheUnusedCodesAreRefused() {
        for code: UInt8 in [0xA0, 0xB5, 0xF5, 0xFB, 0xFC, 0xFF] {
            XCTAssertThrowsError(try RDPInterleavedRLE.decompress(
                Data([code, 0, 0, 0, 0, 0]), width: 4, height: 1, bitsPerPixel: 24),
                "0x\(String(code, radix: 16)) devrait être refusé")
        }
    }

    /// Un rectangle de taille nulle ou démesurée est refusé.
    func testAnImpossibleGeometryIsRefused() {
        for (width, height) in [(0, 8), (8, 0), (1 << 20, 1 << 20)] {
            XCTAssertThrowsError(try RDPInterleavedRLE.decompress(
                Data([0xFE]), width: width, height: height, bitsPerPixel: 24),
                "\(width)×\(height) devrait être refusé")
        }
    }
}

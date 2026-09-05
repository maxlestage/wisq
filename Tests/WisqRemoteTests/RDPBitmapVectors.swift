#if canImport(Glibc)
import Foundation

/// Les vecteurs du codec entrelacé, et **l'oracle qui les a jugés**.
///
/// La question qu'un décodeur de compression pose est simple et sans réponse
/// facile : le résultat est-il juste ? Une image plausible ne prouve rien, et
/// une image qui a la bonne taille non plus. Il faut une seconde implémentation
/// que personne ici n'a écrite.
///
/// **C'est FreeRDP 2.11 qui arbitre.** Sa bibliothèque est installée dans ce
/// conteneur, et ses deux fonctions publiques `interleaved_compress` et
/// `interleaved_decompress` ont servi à trois choses :
///
/// 1. Décomprimer les rectangles qu'un vrai xrdp a envoyés (`xrdp-…`), ce qui
///    donne l'attendu sur des pixels que personne n'a choisis.
/// 2. Comprimer des motifs — dégradés, damiers, bruit, bandes — en 24, 16 et 15
///    bits (`forge…`), puis les redécomprimer : l'entrée comme la sortie sont
///    de FreeRDP.
/// 3. Arbitrer des flux fabriqués exprès (`synth-…`) pour les familles de codes
///    que son compresseur n'émet **jamais** : pose de couleur de forme, masques
///    spéciaux, blanc, noir, et les formes longues. Le flux est de moi ; le
///    résultat attendu reste le sien.
///
/// Deux cent soixante-seize vecteurs ont été comparés ainsi, dont ces
/// trente-huit sont gardés. L'attendu est l'empreinte SHA-1 de ce que FreeRDP
/// écrit en BGRX 32 bits — calculée par `sha1sum`, et vérifiée ici par le SHA-1
/// du dépôt, lui-même tenu par des vecteurs d'`openssl`. Les deux plus petits
/// gardent en plus leurs pixels en clair, pour que l'échec dise où.
enum RDPBitmapVectors {
    struct Vector {
        let name: String
        let width: Int
        let height: Int
        let depth: Int
        let data: Data
        /// Les pixels attendus en BGRX 32 bits, quand ils tiennent.
        let expected: Data?
        /// Et leur empreinte, toujours.
        let digest: String
    }

    static func bytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return out
    }

    /// Étendre un canal de cinq bits à huit, **comme FreeRDP le fait** : un
    /// décalage plus les bits hauts, additionnés et non ou-és — ce qui change le
    /// résultat d'une unité quand les deux se recouvrent — puis borné à 255.
    /// Mesuré sur ses sorties, pas déduit d'une spécification.
    static func widen(_ value: UInt32, bits: Int) -> UInt8 {
        let shift = 8 - bits
        return UInt8(min(255, (value << shift) + (value >> (bits - shift))))
    }

    /// Ce que wisq vient de décoder, mis dans la forme où FreeRDP l'écrit.
    static func asBGRX32(_ pixels: [UInt8], depth: Int) -> [UInt8] {
        guard depth != 24 else {
            var out = [UInt8]()
            out.reserveCapacity(pixels.count / 3 * 4)
            for at in stride(from: 0, to: pixels.count, by: 3) {
                out += [pixels[at], pixels[at + 1], pixels[at + 2], 0xFF]
            }
            return out
        }
        var out = [UInt8]()
        out.reserveCapacity(pixels.count / 2 * 4)
        for at in stride(from: 0, to: pixels.count, by: 2) {
            let value = UInt32(pixels[at]) | UInt32(pixels[at + 1]) << 8
            if depth == 16 {
                let six: UInt32 = (value >> 5) & 0x3F
                let green: UInt32 = min(255, (six << 2) + (six >> 3))
                out.append(widen(value & 0x1F, bits: 5))
                out.append(UInt8(green))
                out.append(widen((value >> 11) & 0x1F, bits: 5))
            } else {
                out.append(widen(value & 0x1F, bits: 5))
                out.append(widen((value >> 5) & 0x1F, bits: 5))
                out.append(widen((value >> 10) & 0x1F, bits: 5))
            }
            out.append(0xFF)
        }
        return out
    }

    static let all: [Vector] = [
        Vector(
            name: "xrdp-12-update-0", width: 8, height: 15, depth: 24,
            data: bytes("81dedede79dedede810000006500000089dedede000000dedededededededede" +
                         "dedede000000000000dedede6ddedede85000000000000dededededede000000" +
                         "6500000084dedede000000000000dedede65dedede82000000dedede66dedede" +
                         "820000000000000682dedede0000006500000081dedede77dedede"),
            expected: bytes("dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeff000000ff000000ff000000ff000000ff000000ff000000ff" +
                             "dededeff000000ff000000ffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeff000000ffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeff000000ff000000ffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeff000000ff000000ff000000ff000000ff000000ff000000ff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeff000000ff000000ff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeff000000ffdededeffdededeffdededeffdededeff000000ff000000ff" +
                             "dededeffdededeff000000ff000000ff000000ff000000ff000000ff000000ff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff"),
            digest: "f887ff513b0cf74f67fa33f6121f0ba65bfa0eac"),
        Vector(
            name: "xrdp-13-update-0", width: 8, height: 15, depth: 24,
            data: bytes("81dedede7adedede810000006400000084dedede000000000000dedede65dede" +
                         "de82000000dedede66dedede810000006600000083dedede000000dedede66de" +
                         "dede8a000000000000dededededede000000000000000000dededededede0000" +
                         "006500000081dedede6007dedede"),
            expected: bytes("dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeff000000ff000000ff000000ff000000ff000000ff000000ff" +
                             "dededeff000000ff000000ffdededeffdededeff000000ff000000ff000000ff" +
                             "dededeff000000ffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeff000000ff000000ff000000ff000000ff000000ff000000ff000000ff" +
                             "dededeff000000ffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeff000000ff000000ffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeffdededeff000000ff000000ff000000ff000000ff000000ff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff" +
                             "dededeffdededeffdededeffdededeffdededeffdededeffdededeffdededeff"),
            digest: "b832a6a5fe8f5d1bacb84089cc78d30b8bc1cf0b"),
        Vector(
            name: "xrdp-11-update-1", width: 240, height: 3, depth: 24,
            data: bytes("2e84fefefefffffffffffffefefe200a94fefefefffffffffffffefffee5f2fa" +
                         "80bff81889fc067efe047dff0279ff0074fe0070fb0069f83583f0b1caedf5f6" +
                         "f9fffffefffffffffffffefefe2684fefefefffffffffffffefefe20760e600f" +
                         "ffffff93fefefefffffffffffffefefef9fcfbd8ecf986c0f9449cfb278cfb2c" +
                         "8cfa5a9ff5adccf3eaf2f8fbfcfcfefefefffffffefefffefefeffffff0660b8" +
                         "ffffff91fefefefffffffffefefefffefefefffcfdfdf7fcfaf6fbfcf9fbfdfa" +
                         "fcfcfdfefdfffefffefefefefefefffffffefefeffffff0081"),
            expected: nil,
            digest: "6ba99e27734a14391604215bd26e9f688123db81"),
        Vector(
            name: "xrdp-9-update-1", width: 240, height: 3, depth: 24,
            data: bytes("2f82fefefefffffe269bf6f9fdefcd88f1a71af3a100f3a201f5a302f3ab17f4" +
                         "dfa9fbfbf8fffffffffffffffffffffefff8f7f8d0e3d56dc88509b63900b632" +
                         "00b83a00b93a1dc1507bd997ebf7efffffffcbf2fed3f2faf9fdfe3d83eae4ba" +
                         "b59c00ddd18b248001e9e2b6c4b24180866a0033d40032d23257d5f8f5eeffff" +
                         "fffffffffefefefffffefefefffcfdfdfafabff9f9a4fbfbd2fdfdf9fefeffff" +
                         "fffffffffefefefefffffffffffffefefefffffffffeffe9faf494f7d483fdd5" +
                         "eafdf9fffefffffffffefefe203283eee9c7c7b541d8ca7920040d8005fefefe" +
                         "fffefefffffffefffffafefff9f0d5fbecbbfaecc4faf9effcfffff0e3c2eea5" +
                         "17f3a100f4a301f5a400f2a90ff5e5b9fdfefdfefffffffffffefefefefefeff" +
                         "fffffffffffcfafce4ebe695d1a425b94d00b32f08b94003b93c0bbc4344cc6f" +
                         "cef0d3cff2ffd2f2fbf9fdfd1d83fefdfcbca519c9b7460494fffffff1f3fc3f" +
                         "67de0033d40032d23559d4fcf8eefffffffffffefffffffefefffcfbedf9f8ac" +
                         "fbfbb0fcfce3fdfdfcfffffffffffffefefeffffff64ffffff8afefefeffffff" +
                         "fffeffeafaf592f8d584fcd4e6fcf6fffefffffffffefefe00316013ffffff80" +
                         "09fefefefffefefffffffbfdfce9d0a0e2ac3ee9ae21f2b71dedb221e4a827e2" +
                         "b665f1e9d6f4daa1f1a60bf4a400f5ac12f5e6bcfdfefefffffffffffefefefe" +
                         "fffffffffffffefefefffffffffffffffdfef0f2f1badbc24fc26d02b53400b6" +
                         "3600b83901ba3b24c35268d5a6caeef5fdfefffffffffffffefefefe1a9affff" +
                         "ffd8ca79b79e07fbfaf3fefefefffffffffffffffffff0f3fc3764df0034d401" +
                         "33d33d5dd6fffcf0fffffffefefffdfdfffafbd8f9f9a2fafbc5fdfef4fefeff" +
                         "fefefffffffefefefeffffff058bfffffffefefefffffffffeffeafbf58df6d2" +
                         "7afccfe6fcf5fffefffffffefeffff0057"),
            expected: nil,
            digest: "a6c5436bc250d71051774b7465e8a34deec0592c"),
        Vector(
            name: "xrdp-8-update-2", width: 240, height: 9, depth: 24,
            data: bytes("2889fffdffc5ebd326d96e00df5f02e16300e26400e3628df1b9fffeff3f84fe" +
                         "fefd95defaeaf7fcfffffe288000fefffffffefefffffffffffffffefffefefe" +
                         "e1fbf6c5f7f2d6ebe4ebcca1e9b058ed9c20f19200f19300f19907f29700f097" +
                         "00efb03bf3cf88f6e4c1fbfaf4fcfffffffffffffffffffffffcfdfea9bcec00" +
                         "38d9073ed81a48d792a4e4fffffa200186f9f9dbf9e85dfee220fce424faf19b" +
                         "fdfdf8204d088bffffffecf4ee6cda9800db5601de6002df6200e05c52e994e1" +
                         "faecfffffffefefe1d84eef9fba1e0f8eef9fdffffff088000fffffffefefeff" +
                         "fffffffffffffffff8fbfff0edf0eccea5e9ae51ee9a1bf09200f19604f39805" +
                         "f69600f19a07f2b446f3d498f6ead0fcfdfbfefffffffffffffffffffffffefe" +
                         "fefffffffefefecad8f00035d8023ad71142d67c93e0fffff81f88fefefeffff" +
                         "fffaf7c6f9e74efde52dfae849fcf7cafeffff004d92fefefeffffffffffffff" +
                         "fffffefefefffffffffffffefefefffffffffafdaee4c317d86500dc5c02dd5f" +
                         "00de5f10e169aff3ccffffff7effffff85dff5fbade4f9f2fafefffffffefefe" +
                         "068001fefefefffffffffffffffffff9fcffeef1f4ead2b1ecae52ed9a1cf091" +
                         "00f29300f39600f29500ed9e0ed0bb50e5daa2f9efdafdfefefeffffffffffff" +
                         "fffffffffffefefefffffffffffffffffffffffee7edf70039d7013ad7073cd4" +
                         "6680defffff71f89fffffffdfffff9f2a5fae636fce732f8ee89fcfbf0ffffff" +
                         "fefefe004c94fffffffffffffcfcfcfdfdfdfffffffefefeffffffffffffffff" +
                         "ffffffffe6f0ea61d89100d95302db5c02dc5e00dc5963e99ceafbf1fffffffe" +
                         "fefe1c84d1f1fdb8e8f9f5fbfeffffff65ffffff8003fefefeffffffffffffff" +
                         "fffffbfdffeff3f8eadac3ebb15bed9b1ef09200f19200f39500f29400f29903" +
                         "f4ba56f5deb1d8f1d9b3fae7cafdf3f9fefdfffffffffffffefefefefffeffff" +
                         "fffffffffffffffefffffffffff2f5fc174ad9013ad7083cd64c6adbfffff51e" +
                         "89fefefefffffffbfbeff8ed83fce730faea4cf9f6c3fdfeffffffff604dffff" +
                         "ff95fefefefefefefbfbfbfafafafefefefffffffffffffffffffefefeffffff" +
                         "fffafdaee4c31fd46700d75600d95a02da5d12de67b2f2cdfffffffffffffefe" +
                         "fe1b83c4eefcc4ebf8f8fcfe068005fffffffffffffefefff2f4faeae2d6eab6" +
                         "6bed9b21f09304f19200f29500f19400ef9700f1b64cf6deb1fbf5e7fefefef9" +
                         "feffe7fbf4d1f7eeabfae5cdfdf2fefefefffffffffffffffffffefefeffffff" +
                         "fefefefffffff4f6fd3360de063ed80439d53158d8fefbf1fffffffefefe1c89" +
                         "fffffefefffff9f7c8f9ea53fce72ffaf18dfcfdf5fefffffffffe004f93f9f9" +
                         "f9fafafafbfbfbfffffffffffffefefefefefefffffffffffff0f2f072d89900" +
                         "d35204d75b0ad95f00d9584be389dff8eafffffffefffe1581fefefe0583b8ec" +
                         "fbcfedf8fafdfe048006fefefefffffffffffff5f8fbebeae9eac083ed9d23ef" +
                         "9309f19200f29500f29500f19600f0b140f5dcaefbf4e8fefefdfeffffffffff" +
                         "fffffffcfbfbf5f9f8e7f9f5c0f9eca7fce8dafff6fffefffffffffffffffffe" +
                         "fffffffffffffff6f8fd547ae1033bd80035d42751d7eaebeeffffff75ffffff" +
                         "81fefefe048cfefefefffffffefefefffffffcfcf8f7f196fce931fbee5ffbf9" +
                         "d1fffffffffffffefefe004d96fffffffefefefcfcfcfcfcfcfbfbfbfafafafd" +
                         "fdfdfffffffefefefefefefffffffffcffc9e6d33ed27700d55505d65a00d758" +
                         "00d8578eecb5f7fdfafffffffefefe128015fefefefffffffffffffefefefdfd" +
                         "fdfdfdfdfefefeffffffade8fcd8f2f7fdfefdfffffffffffffefefeffffffff" +
                         "fffffafcfdedf1f5eacea8eca539f0950df09100f19400f39700f09400f1a92f" +
                         "f3d9a4f9f5e8fdfcfbfffffffffffffffefefefefefffffffdfdfdfcfcfcfdfc" +
                         "fcf1f9f7e3faf4b0fbe7adfde9f0fefbfffffffffffffefefefffffff7f9fd68" +
                         "89e20036d70035d4244fd6d7dbebfffffe1393fefefefffffffffffffefefefd" +
                         "fdfdfdfdfdfefefefffffffffffffffffffefffffbf8cffbec56fbeb3ff8f4a5" +
                         "fdfdfefffffffefefeffffff604effffff96fefefefefefefefefefcfcfcf9f9" +
                         "f9fbfbfbfefefefffffffefefefffffffffffffbf6f999ddb216d15e00d25201" +
                         "d45700d55519da66c8f4dafffffffffffffefefe108016fefefefffffffefefe" +
                         "fdfdfdfdfdfdfefefefefefefcfcfcfffffea5e4fae4f4f9fffefeffffffffff" +
                         "fffffffffdfefef1f5f9eadccaedac48ec9611f09406f19609f39500ee9500f0" +
                         "a21bf2d295f9f4e8fcfbfafefffffefffffffffefefefeffffffffffffffffff" +
                         "fefefefefefefdfdfdfafafafafafaf2fbf9dbfbf3a1fbe5c1fef0fbfefcffff" +
                         "fffffffff9fafd7c9ae70035d60035d4204cd6c6cce9fffffd1390ffffffffff" +
                         "fffefefefdfdfdfefefefefefefdfdfdfcfcfcfefefefefefffcfcf3f9f294fc" +
                         "ec35f9f182fbfbeeffffff6050ffffff98fefefefffffffffffffffffffefefe" +
                         "fcfcfcf8f8f8f9f9f9fdfdfdfffffffefefeffffffffffffeeeeee6ad39001ce" +
                         "5000d05300d35500d3524ae185e4f9ecfffffffefffefefefe0f8016fffffffe" +
                         "fefefdfdfdfcfcfcfcfcfcfbfbfbfbfbfbfcfcfcfffefcb8e7f8e9f5f9fffefe" +
                         "fffffffffffff6f8fae9e9e7eabc76ee9513f09302f19400f29502f19604f09e" +
                         "13f0c777f8f3e4fcfaf8fefffffefffffffffffffffffefefeffffffffffffff" +
                         "fffffefefefffffffffffffefefefefefef9f9f9f9f8f9fafbfbf4fdfbc9fbed" +
                         "9cfde2ddfff7fffffffbfbfe94abea0034d60035d41c49d5b3bee7fffffb1391" +
                         "fefefefefefefcfcfcfcfcfcfcfcfcfbfbfbfbfbfbfcfcfcfcfcfcfbfcfffaf6" +
                         "c3fcec48fbf064faf8d0fefefffffffffefefe004f"),
            expected: nil,
            digest: "0669580d0b8208cb8e9aa5d7485748c79aca2195"),
        Vector(
            name: "xrdp-8-update-0", width: 240, height: 22, depth: 24,
            data: bytes("201d91fefefefefffffffffffffffffefefefcfcfbeef6fbc7e1f9acd1fbb5d4" +
                         "fbdcebfaf8fbfbfefefdfffffffffffefffffffefefe2082001c93fefefeffff" +
                         "fffffffefffffefefefedbecf972b5f61987fb0179fd0278fd0073fd006efb32" +
                         "88f5a9ccf7f0f5fafefefdfffffffffffffefefe00bd94fefffffffffffffefe" +
                         "f5f9fbabd4f92893fa0d84fd0c81ff077fff037bff0175fe0172fb006df90065" +
                         "f65396f2d5e4f5fefefdfffffffffffffefefe00bb89fefefefffffffffffef0" +
                         "f7fb95ccf8188efb198cfe188afd0c82fe0489026ff9016cf70063f52f7ef2c8" +
                         "d9f7fefdfdfffffffffffffefefe00b998fefefefffffffffffff5fafd99cef8" +
                         "1b91fc1e91fe1a8cfe188afc1286fc067ffe037aff0175fe0172fb026ff9026c" +
                         "f60168f6005ef42e77eecbdcf4fefefdfffffffefefffefefe00b798fefefeff" +
                         "fffffffffffafdfeb0daf92398fa2695ff1e91fe178bfe1287fe1888fc1887fc" +
                         "097dfe0074fd0070fb016ff9026cf60168f60164f3005df24589eedce7f6ffff" +
                         "feffffff00b89afefefffffffefefefed1eafa38a3fa2999ff2595fe2192fc32" +
                         "98f94da4fa72b5fa80bcf867adfa3790fa167cf9026ff9006bf60068f60365f4" +
                         "0d69f40057ee6f9feeeff3fafffffefffffffefefe00b59cfefefeffffffffff" +
                         "feecf6fa67bbf82a9cfe2a9afe339bfc6ab4f5cae1f6fffffbfffffefffffdff" +
                         "fffbf9fcfba5ccf94190f5096ef50067f60b69f50363f2005fef0056ecaac3ee" +
                         "fbfcfcfffffffffffffefefe00b48bfefefffffffefcfdfda7d7f62a9ffd319f" +
                         "fe3fa3fa9bccf7fffdf9fffffeffffff64ffffff8cfffffde7f0f76ca6f41672" +
                         "f40163f30062f2005fef0059ed286eeadbe5f5fefefeffffff60b6ffffff9afe" +
                         "feffe1f1f947aff835a3ff46a7faabd4f5fffffafffffffffffffefefeffffff" +
                         "fffffffffffffefefefefefffffffef8fafa76a9f10c68f10060f2005fef025c" +
                         "ed004ee87aa2ecf8f9fbfffffe00a181fefefe0481fefefe0e8afffffefdfdfd" +
                         "8dccf733a4fd41a8fda2d0f5fffffbfffffffefefeffffff65ffffff8dfefefe" +
                         "fefffffffffef4f6f8649df10664f1005eef025ced0056e90d59e8cedaf2fdfe" +
                         "fefffffe1985fefefefffffffffffffffffffefefe008287fffffffefefefdfd" +
                         "fdfdfdfdfefefefffffffefefe0c8afefefefefeffdef0f945aefc3ca8fe89c7" +
                         "f7fffdf9fffffffefefeffffff0691fffffffefefefefefffffffee1ebf74186" +
                         "f1015fef015ced0053e9004ae7779debfcfbfcfffffffffffffffffffffffffe" +
                         "fefe1586fffffffdfdfdfdfdfdfefefefffffffefefe008287fdfdfdfafafafb" +
                         "fbfbfcfcfcfefefefffffffefefe0b89fefefffffefe91cff83eabfe64b7f8ee" +
                         "f3f6fffffffefefeffffff0891fffffffefefefefefffffffeb8d1f51b6cef00" +
                         "56ed377aec75a2eea4bef1e8effbecf3fdfffefdfffffefffffffffefffefefe" +
                         "1586fbfbfbfafafafcfcfcfefefefffffffefefe006181fefefe0581fefefe1b" +
                         "86fafafafbfbfbfdfdfdfefefefffffffefefe0989fefefeffffffe5f3fb54b5" +
                         "fb4eb1fbc5dff3fffffefefeffffffff0a91fffffffefefefffffffffffc77a4" +
                         "f276a5f4b7cbf1abc0e980a4ea6296f46195f3789feca1b8eae8ecf6fffffffe" +
                         "fefffefefe1685fafafafcfcfcfefefefffffffefefe005e8cfefefeffffffff" +
                         "fffffefefefdfdfdfdfdfdfdfdfdfefefefffffffffffffffffffefefe1689fe" +
                         "fefefdfdfdfcfcfcfafafaf9f9f9fcfcfcfefefefffffffefefe0888fefeffff" +
                         "fffea1d8f942aefe86c7f6fffdfafffffffefefe0c8ffffffffefefeffffffec" +
                         "f3facdd3ea728ad32b5fd20c51db004ee40047e30040d80d4acd5c7dd0c8d0e9" +
                         "ffffff1588fdfdfdfdfdfdfbfbfbf9f9f9fafafafefefefffffffefefe005d8d" +
                         "fffffffefefefefefefdfdfdfefefefcfcfcfdfdfdfdfdfdfdfdfdfdfdfdfefe" +
                         "fefffffffefefe148bfefefefffffffffffffefefefbfbfbf9f9f9fafafafcfc" +
                         "fcfefefefffffffefefe0788fffffff5fafb60befa52b6fbdcecf6fffffffefe" +
                         "feffffff6dffffff90fefefeffffffe0e3ec637ac5395fc53a67ce396ad63d72" +
                         "dd1f5cd80745cc033ec3002eb33c5bbbd7dbecfffffffefefe128afefefeffff" +
                         "fffffffffdfdfdf9f9f9f9f9f9fcfcfcfdfdfdfffffffefefe005e8bfcfcfcfd" +
                         "fdfdfcfcfcfcfcfcfdfdfdfcfcfcfcfcfcfbfbfbfdfdfdfefefeffffff148cff" +
                         "fffffffffffefefefffffffefefefcfcfcfafafaf9f9f9fdfdfdffffffffffff" +
                         "fefefe0587fefefeffffffc2e6f84cb5fe90cdf5fffffcffffff71ffffff8d76" +
                         "86c14a64bb3b5dbc2750bc315bc72755cd466fd61e4dc4345ac1002aab0026a1" +
                         "576ab6ffffff75ffffff89fefefefffffffdfdfdfbfbfbfafafafbfbfbfefefe" +
                         "fffffffefefe005e83fcfcfcfbfbfbfcfcfce2fbfbfbfcfcfc198bfffffffefe" +
                         "fefffffffefefefcfcfcfafafafbfbfbfdfdfdfefefefffffffefefe0487feff" +
                         "fffffffe7eccf955b9fce2eef5fffffffefefe108ed7d9e84f62ae4a5fb21d3d" +
                         "ae345fcb2859d12d5cd53161d73a67d73f67d00f35ae001d94132d97cbcde115" +
                         "8afffffffffffffffffffdfdfdfbfbfbfafafafcfcfcfefefefffffffefefe00" +
                         "5d82fbfbfbfcfcfc66fcfcfc198afffffffefefefffffffffffffbfbfbf9f9f9" +
                         "fafafafcfcfcfefefeffffff0486ffffffeaf4fa59befc87ccf5fffefcffffff" +
                         "71ffffff8e9ca2cc5460ab3652b22b5ece3973de1259db2769dd2365db427ae1" +
                         "306bdc2059cf02259f0b1f8b8b90c31689fefefefffffffffffffefefef9f9f9" +
                         "fafafafbfbfbfefefeffffff605bffffff0484fdfdfdfcfcfcfdfdfdfdfdfd1c" +
                         "93fffffffefefefffffffdfdfdfcfcfcfcfcfcfbfbfbfefefefffffffffffffe" +
                         "fefefffffffefefeffffffb2e1f751bafdd4e9f4fffffffefefe118e8388bc4c" +
                         "55a0386fd02272e14c8de71b6ee11d71e14c8ee72274e14085e3196de0034ccb" +
                         "0b18847176b2168bfffffffefefefffffffefefefcfcfcfcfcfcfbfbfbfcfcfc" +
                         "fffffffffffffefefe005b88fdfdfdfbfbfbfcfcfcfcfcfcfcfcfcfbfbfbfbfb" +
                         "fbfdfdfd1b91fffffffffffffefefefefefefdfdfdfbfbfbfcfcfcfdfdfdfefe" +
                         "fefffffffefefefefffffffffd7bcdf973c5f7fafbfbffffff72ffffff8e8e91" +
                         "bd3b4a9d5091e2157ae52c8ae74698ea4698eb2c8bea2082e64f9deb0573e501" +
                         "68df102c937a7eb2178bfffffffffffffefefefefefefefefefbfbfbfbfbfbfd" +
                         "fdfdfefefefffffffefefe005b88fdfdfdfcfcfcfafafafbfbfbfdfdfdfcfcfc" +
                         "fdfdfdffffff1b90fefefefffffffffffffefefefbfbfbfafafafafafafdfdfd" +
                         "ffffffffffffffffffe9f7fa5dc0fdafdbf4fffffefeffff128ec2bfd625409d" +
                         "4192e14da7f02b97eb1d92ed2295ed349cef51acf02294eb0082ec0079e3163d" +
                         "a0adacca188bfefefefffffffffffffffffffdfdfdfafafafafafafcfcfcfefe" +
                         "fefffffffefefe0053"),
            expected: nil,
            digest: "6de4f8152c5219b1a12c3d9ebf46cb4ab02b3268"),
        Vector(
            name: "forge24-motif1", width: 16, height: 8, depth: 24,
            data: bytes("8060074d00084d07094d0e0a4d150b4d1c0c4d230d4d2a0e4d310f4d38104d3f" +
                         "114d46124d4d134d54144d5b154d62164d6906420007420708420e0942150a42" +
                         "1c0b42230c422a0d42310e42380f423f10424611424d12425413425b14426215" +
                         "426905370006370707370e08371509371c0a37230b372a0c37310d37380e373f" +
                         "0f374610374d11375412375b133762143769042c00052c07062c0e072c15082c" +
                         "1c092c230a2c2a0b2c310c2c380d2c3f0e2c460f2c4d102c54112c5b122c6213" +
                         "2c6903210004210705210e06211507211c08212309212a0a21310b21380c213f" +
                         "0d21460e214d0f215410215b11216212216902160003160704160e0516150616" +
                         "1c07162308162a0916310a16380b163f0c16460d164d0e16540f165b10166211" +
                         "1669010b00020b07030b0e040b15050b1c060b23070b2a080b31090b380a0b3f" +
                         "0b0b460c0b4d0d0b540e0b5b0f0b62100b6900000001000702000e0300150400" +
                         "1c05002306002a07003108003809003f0a00460b004d0c00540d005b0e00620f" +
                         "0069"),
            expected: nil,
            digest: "322a51f8067dfdff027ff47c84112182bf64efbe"),
        Vector(
            name: "forge24-motif2", width: 16, height: 8, depth: 24,
            data: bytes("82000000000000e7000000ffffff2050"),
            expected: nil,
            digest: "bd2af125a49551b2c2f4d38f17fe5f493cc3eb1f"),
        Vector(
            name: "forge24-motif4", width: 16, height: 8, depth: 24,
            data: bytes("81000000601f000000300010"),
            expected: nil,
            digest: "91c96789c029e061b2cb100313d04176bda6cc7b"),
        Vector(
            name: "forge24-motif5", width: 16, height: 8, depth: 24,
            data: bytes("8060af7a8d02cb504455a56a55bca09b4061aa6e7e53a77617953944f1775dbf" +
                         "f37db9fe31777dc31fcebaf1f27cbe1d2a798934b8dee727ab9b7606fdc91f24" +
                         "959a477ae2490b676f4d829534799f7cc7cccec7bee9ecc1037e816f376e27f3" +
                         "45be0154b92bf152e5b68b323c2df3852e88e4cc11fbb002dfb4656cd6715f10" +
                         "88196c72ef20046e4ca3f22ff63cec3edcd9ad6e90abd91cd39eea9888da03e0" +
                         "db7e42c1b872eb032c4d187b77432fe5b47f39cad92e4d0b6aaf6cab7f1306d9" +
                         "556de5d4fbe14f8f12115ca31882f7182b8fdf72477ad5e4de5b933474915c26" +
                         "8bd99d5954e60f9d8ad40e1fe0dd2a5ed8dcbe997910c0780287667fe59935d2" +
                         "6c8ffbbcee9d44e13be28cccecbff5bf0bc2be6bf8db4fe59c07b685e946cf2a" +
                         "4b4a11914a3b5d5fc23e5116a453e56ead1194389a28d0f54ca37c34c0f0ca59" +
                         "f395840b1b61d56850f9049829b72e575599744e6c251392312e2213cda1ed12" +
                         "be666942fc24cedad72397208d066a61c26e9503d48a2868131e57d4ee5d3cc0" +
                         "5e6e"),
            expected: nil,
            digest: "25044036693d38efea007b78b8b1f9ac0c36e7a6"),
        Vector(
            name: "forge24-motif6", width: 16, height: 8, depth: 24,
            data: bytes("9000000000000000000000000000000000000000000000000000000000000000" +
                         "0000000000000000000000000000000000000090202020202020202020c0c0c0" +
                         "c0c0c0c0c0c0202020202020202020c0c0c0c0c0c0c0c0c02020202020202020" +
                         "20c0c0c00020"),
            expected: nil,
            digest: "c92828ad947a27267eafe0fe9c5c30c2fe19bf5b"),
        Vector(
            name: "forge24-motif8", width: 16, height: 8, depth: 24,
            data: bytes("8f00000000000000000000000000000000000000000000000000000000000000" +
                         "00000000000000000000000000006001ffffff86101010ffffffffffff101010" +
                         "ffffffffffff0484101010ffffffffffff1010100022"),
            expected: nil,
            digest: "c653bdeedec7874f95fd02a8ddc52a29cbb52827"),
        Vector(
            name: "forge16-motif1", width: 16, height: 8, depth: 16,
            data: bytes("806060026102610a6112611a6122612a6132613a623a6242624a6252625a6262" +
                         "626a00020002010a0112011a0122012a0132013a013a0242024a0252025a0262" +
                         "026aa001a001a009a111a119a121a129a131a139a139a141a249a251a259a261" +
                         "a269600160016009601161196121612961316139613961416149625162596261" +
                         "6269000100010009001100190121012901310139013901410149015102590261" +
                         "0269a000a000a008a010a018a020a128a130a138a138a140a148a150a158a260" +
                         "a268400040004008401040184020402841304138413841404148415041584160" +
                         "4268000000000008001000180020002800300138013801400148015001580160" +
                         "0168"),
            expected: nil,
            digest: "3ee4a033c7c0688899a34591e7b80fbe47babcd1"),
        Vector(
            name: "forge16-motif2", width: 16, height: 8, depth: 16,
            data: bytes("4255552050"),
            expected: nil,
            digest: "7f1706eab4881af5f4fad888fa5f1cf0325c2e3f"),
        Vector(
            name: "forge16-motif4", width: 16, height: 8, depth: 16,
            data: bytes("100010300010"),
            expected: nil,
            digest: "91c96789c029e061b2cb100313d04176bda6cc7b"),
        Vector(
            name: "forge16-motif5", width: 16, height: 8, depth: 16,
            data: bytes("8060d58b4056a8a2adbad4444c6d8fa2ae9027f2eebafebb9f710f1ed9f5febb" +
                         "4379b1b93b27d574e0cf2391337a5c0a6c4bb034ef7c78cef8ed1d060f6c6623" +
                         "3ebaa0ba8557bc8de6293e2c31cfc2b7e0b66cd3ee12d1686e27604b942ffee9" +
                         "e7de7593d51efaec53dc00df0fc297eb6049c37368e1f63bd92e496875ab8f00" +
                         "bb6abcfe7c8a8258d480de28f176c8d3fc5eb271f222d19eabe2e18c7a18fc2e" +
                         "cbded77c027e20642f9f866ed1bffd44dce171eeb7bf01becddf299fa0853dca" +
                         "454a824ce75af85122557caba23c53d17ea2afc15e5ebe84c1605a533f98a52d" +
                         "aa9a6e6a8490662162a69db84c433fc9bb26128940637893a08e4513a3d2fd3a" +
                         "f86a"),
            expected: nil,
            digest: "36920a6b2e90e716453579275895c425d11015a0"),
        Vector(
            name: "forge16-motif6", width: 16, height: 8, depth: 16,
            data: bytes("9018c618c618c604210421042118c618c618c604210421042118c618c618c604" +
                         "2100009004210421042118c618c618c604210421042118c618c618c604210421" +
                         "042118c60020"),
            expected: nil,
            digest: "7af1f429738cbbb1ae743d3728d81b82cc6fdf7a"),
        Vector(
            name: "forge16-motif8", width: 16, height: 8, depth: 16,
            data: bytes("868210ffff8210ffffffff821024858210ffffffff8210ffff6001ffff868210" +
                         "ffff8210ffffffff821004848210ffffffff82100022"),
            expected: nil,
            digest: "4aac4fa081c83210dd6205e8d067e5f52ae485ce"),
        Vector(
            name: "forge15-motif1", width: 16, height: 8, depth: 15,
            data: bytes("80602001210121052109210d211121152119211d221d222122252229222d2231" +
                         "22350001000101050109010d011101150119011d011d022102250229022d0231" +
                         "0235c000c000c004c108c10cc110c114c118c11cc11cc120c224c228c22cc230" +
                         "c234a000a000a004a008a10ca110a114a118a11ca11ca120a124a228a22ca230" +
                         "a2348000800080048008800c811081148118811c811c812081248128822c8230" +
                         "82344000400040044008400c401041144118411c411c412041244128412c4230" +
                         "42342000200020042008200c201020142118211c211c212021242128212c2130" +
                         "22340000000000040008000c001000140018011c011c012001240128012c0130" +
                         "0134"),
            expected: nil,
            digest: "33a3a271f6597e85bca9c16b274de698660bf433"),
        Vector(
            name: "forge15-motif2", width: 16, height: 8, depth: 15,
            data: bytes("82ff7f0000e7ff7f0000820000ff7fe7ff7f000082ff7f0000e70000ff7f8200" +
                         "00ff7fe7ff7f000082ff7f0000e70000ff7f820000ff7fe7ff7f000082ff7f00" +
                         "00e70000ff7f820000ff7fe7ff7f0000"),
            expected: nil,
            digest: "96101e6dec2ffdac70e68a203cda8beaf8bbea6b"),
        Vector(
            name: "forge15-motif4", width: 16, height: 8, depth: 15,
            data: bytes("10001081ff7f601fff7f"),
            expected: nil,
            digest: "91c96789c029e061b2cb100313d04176bda6cc7b"),
        Vector(
            name: "forge15-motif5", width: 16, height: 8, depth: 15,
            data: bytes("8060f545202b48514d5d7422ac364f514e4807796e5dfe5ddf380f0ff97afe5d" +
                         "a33cd15c9b13753ae0678348133d3c05ac25501a6f3e3867f8761d030f36a611" +
                         "1e5d405dc52bdc46e6141e169167e25b605bac696e097134ae13a025d417fe74" +
                         "676fb549750f7a76336e806f0f61d775a024e339a870f61d79172934b5554f00" +
                         "5b355c7f3c45422c74407e14713be8697c2fd2387211714f4b7161463a0c7c17" +
                         "6b6f773e023f00328f4f4637f15f7d22fc703177d75f015fed6f894fc0421d65" +
                         "25254226672df828822abc55421eb3683e51cf603e2f5e426130ba291f4cc516" +
                         "4a4d2e354448a61022535d5cac219f645b139244a031b8494047a50943697d1d" +
                         "7835"),
            expected: nil,
            digest: "d540d74e8d044bdcddf3c4a2891cd0dc42852b34"),
        Vector(
            name: "forge15-motif6", width: 16, height: 8, depth: 15,
            data: bytes("9018631863186384108410841018631863186384108410841018631863186384" +
                         "1000009084108410841018631863186384108410841018631863186384108410" +
                         "841018630020"),
            expected: nil,
            digest: "7af1f429738cbbb1ae743d3728d81b82cc6fdf7a"),
        Vector(
            name: "forge15-motif8", width: 16, height: 8, depth: 15,
            data: bytes("8f4208ff7f4208ff7fff7f4208ff7fff7fff7fff7f4208ff7fff7f4208ff7f60" +
                         "01ff7f864208ff7f4208ff7fff7f420804844208ff7fff7f42080022"),
            expected: nil,
            digest: "4aac4fa081c83210dd6205e8d067e5f52ae485ce"),
        Vector(
            name: "synth-setfg0", width: 24, height: 8, depth: 24,
            data: bytes("ceeee761cdf35f30c5482e15c8500720c1617b0fc6e16477c8022beac72a82a1" +
                         "c9930f23c73794c5c1006d6bc8c0cbd6ca658aacc5aa07d1c37e3305c8f95a60" +
                         "c96143d6c2cad76cc59b0a6bc733154ac88404a8c725262eca7c07bccae841f7" +
                         "cec55d4ec7747f61"),
            expected: nil,
            digest: "f14855d419ed487075c0468f97b5fba27a236797"),
        Vector(
            name: "synth-setfg1", width: 24, height: 8, depth: 24,
            data: bytes("c5b349c3c6f78cebc9004ae1c3ad6b1ec2accf2ccf1f722ec839d845cf531a57" +
                         "c7d6f0f4c90f2a62c6b9c59ec578abbac95b0ec3c10d71dac7683470c28c12dd" +
                         "c8b01aebc4ad90e9ccf67a55cfba5d60cf0389aec404147ec64f0ca5cb3c75f4" +
                         "c8b586e3"),
            expected: nil,
            digest: "da3cb6547150f8fdf4144012de97e1491b2c1f89"),
        Vector(
            name: "synth-setmask0", width: 24, height: 8, depth: 24,
            data: bytes("7ceee761d3f35f30e49b48d315cae7500720d1617b0fed6f647796612bea8e72" +
                         "2a82a1d3930f2337cd376d220800d11af0c0cb63658aacd2aa07d13c44d11eee" +
                         "f95a62cad76c"),
            expected: nil,
            digest: "2f8781c4d175d6ccf259c552308023aca93763b3"),
        Vector(
            name: "synth-setmask2", width: 24, height: 8, depth: 24,
            data: bytes("6a5f764bd35f42246d960f65078d4bd2e6df4783b6d2dbbadca03c7b86e54576" +
                         "e35a96d1b681beeb748fca42727878636525dced61d91673d2e38151d38064bf" +
                         "4679"),
            expected: nil,
            digest: "322bc8c5ca1c0b349eeceeef68e9ace5dbafc015"),
        Vector(
            name: "synth-special0", width: 24, height: 8, depth: 24,
            data: bytes("7ceee761faf96a482e157fe75007f9f9f96be1647770022bea6e2a82a1faf9fa" +
                         "fa6308006d67cbd625"),
            expected: nil,
            digest: "833f36ed0446c7c78a64796c68082846b2cbaae3"),
        Vector(
            name: "synth-special2", width: 24, height: 8, depth: 24,
            data: bytes("6a5f764bf9f9fafaf97b4b2b8678df47837c77f9db7ddca03c7b86e54567e35a" +
                         "96"),
            expected: nil,
            digest: "e369162ab86efcda4fd3f05fd696161d498c5f6c"),
        Vector(
            name: "synth-white0", width: 24, height: 8, depth: 24,
            data: bytes("fdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfd" +
                         "fdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfd" +
                         "fdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfd" +
                         "fdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfd" +
                         "fdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfd" +
                         "fdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfdfd"),
            expected: nil,
            digest: "fc1b469729f5a061d4b8b5eb1efba13a7b52d5a7"),
        Vector(
            name: "synth-black0", width: 24, height: 8, depth: 24,
            data: bytes("fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe" +
                         "fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe" +
                         "fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe" +
                         "fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe" +
                         "fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe" +
                         "fefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefefe"),
            expected: nil,
            digest: "41e0c5ebad480795c67cb5a237deaceac54d935a"),
        Vector(
            name: "synth-megabg1", width: 24, height: 8, depth: 24,
            data: bytes("f0a900f01700"),
            expected: nil,
            digest: "41e0c5ebad480795c67cb5a237deaceac54d935a"),
        Vector(
            name: "synth-megafg0", width: 24, height: 8, depth: 24,
            data: bytes("f1c000"),
            expected: nil,
            digest: "fc1b469729f5a061d4b8b5eb1efba13a7b52d5a7"),
        Vector(
            name: "synth-megamask1", width: 24, height: 8, depth: 24,
            data: bytes("69b349c3f2b000f78ceb74004ae1bc53ad6b1e6626accf2c091f722ed864d845" +
                         "a063f0f4c4"),
            expected: nil,
            digest: "1a66debfb1d447744e1b6bfb194b2240c8abafed"),
        Vector(
            name: "synth-megasetfg0", width: 24, height: 8, depth: 24,
            data: bytes("f6c000e7615e"),
            expected: nil,
            digest: "4469088ff3ef2960aba96d1c97ba8d28ac54f411"),
        Vector(
            name: "synth-mask2", width: 24, height: 8, depth: 24,
            data: bytes("6a5f764b435f422443960fdc43078d4b42e6df42b6777ddbbadc753cb1867245" +
                         "e1e341b662eb868f"),
            expected: nil,
            digest: "13cb76fe2c1e558890a5e772a58c45007a462228"),
        Vector(
            name: "synth-dither1", width: 24, height: 8, depth: 24,
            data: bytes("69b349c3e6f78ceb74004a6c53ad6bea6626accf2c09ee722ed8e339d8e9a053" +
                         "1a572acd76f0f4c4eb2a6285b6b9c5648178ab6c5b0ec3620d71dae76834705b" +
                         "278ce78dffb01aebbc63f3f67a"),
            expected: nil,
            digest: "e57331c46caa134f1c5973c9381bd73817eb06ef"),
        // **Les fonds dos à dos**, que le compresseur de FreeRDP ne produit
        // jamais sur les motifs essayés et que les rectangles de xrdp ne
        // contiennent pas non plus. Le pixel de premier plan intercalaire ne se
        // voit que là : `insert-two` le montre seul au milieu d'une ligne
        // noire, et les deux autres après une course de forme.
        Vector(
            name: "insert-two", width: 24, height: 2, depth: 24,
            data: bytes("180c0c"),
            expected: bytes(
                "000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ffffffffff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff000000ff"),
            digest: "70a228c3778e7b19cf95535babd8e337927c63bf"),
        Vector(
            name: "insert-after", width: 24, height: 3, depth: 24,
            data: bytes("38180c0c"),
            expected: bytes(
                "000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
            digest: "7b7c497deda6ab5adaec93632e1f98b531fb3b9b"),
        Vector(
            name: "insert-mega", width: 24, height: 3, depth: 24,
            data: bytes("38f018000c0c"),
            expected: bytes(
                "000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff000000ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
            digest: "7b7c497deda6ab5adaec93632e1f98b531fb3b9b"),
    ]
}
#endif

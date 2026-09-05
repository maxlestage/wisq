#if canImport(Glibc)
import Foundation

/// Ce qu'un **vrai serveur** a envoyé, octet pour octet.
///
/// **Aucun de ces vecteurs n'est de moi.** Ils sortent d'une session ouverte
/// contre xrdp 0.9 dans ce conteneur, capturée après déchiffrement : la sonde
/// a écrit chaque PDU en clair dans un fichier, et ce fichier est recopié ici.
/// Un vecteur que j'aurais écrit d'après la spécification prouverait seulement
/// que je lis la spécification comme je l'ai codée ; celui-ci prouve qu'un
/// serveur envoie bien ça.
///
/// La session : `xrdp --nodaemon` sur 127.0.0.1:3389, sécurité historique,
/// RC4 128 bits, écran 1024x768 en 24 bits.
enum RDPServerFixtures {
    static func bytes(_ hex: String) -> Data {
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            out.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return out
    }

    /// Le premier message que xrdp envoie après le Client Info : une demande de
    /// licence de 318 octets, dont le préambule dit 0x013e.
    static let licenseRequest = bytes(
        "01023e017b3c31a6aee874f6b4a50390e7c2c739ba531c30546e9005d005ce44" +
        "18918381000004002c0000004d006900630072006f0073006f00660074002000" +
        "43006f00720070006f0072006100740069006f006e0000000800000032003300" +
        "360000000d000400010000000300b80001000000010000000100000006005c00" +
        "5253413148000000000200003f0000000100010001c7c9f78e5a38e429c30095" +
        "2ddd4c3e50450b0d9e2a5d186364c42cf78f29d53fc5352234ffad3ae6e39506" +
        "ae5582e3c8c7b4a847c85071742953896d9ced70000000000000000008004800" +
        "a8f431b9ab4be6b4f43989d6b1daf61eecb1f0543b5e3e6a71b4f775c8162f24" +
        "00dee982995f330ba9a694afcb11c3f2db0942682956580156db590369db7d37" +
        "0000000000000000010000000e000e006d6963726f736f66742e636f6d00")

    /// Sa réponse à notre demande : une alerte dont le code est 7,
    /// `STATUS_VALID_CLIENT` — ce qui veut dire que tout va bien.
    static let statusValidClient = bytes(
        "ff021000070000000200000028140000")

    /// Le Demand Active : treize jeux de capacités, 1024x768 en 24 bits.
    static let demandActive = bytes(
        "9a011100ec03ea03010004008401524450000d00000009000800ec03b5e20100" +
        "1800010003000002000000000104000000000000010102001c00180001000100" +
        "0100000400030000010001000000000000000e00040003005800000000000000" +
        "0000000000000000000040420f0001001400000001002f002200010101010000" +
        "0000010001000000000000000100000000000000000100000000a10602004042" +
        "0f0040420f0001000000000000001d005d0004b91b8dca0f004f15589fae2d1a" +
        "87e2d6010300010103122f777672bd6344afb3b73c9c6f788600040000000000" +
        "d4cc44278a9d744e803c0ecbeea19c5400040000000000e64caf1bed9e0c4386" +
        "9acb8b37b662370001004b0a0008000600000008000a000100190019000d0058" +
        "003d010000000000000000000000000000000000000000000000000000000000" +
        "0000000000000000000000000000000000000000000000000000000000000000" +
        "00000000000000000000000000000000000000000006000500001a0008000040" +
        "30001e000800020000001c000c00520000000000000000000000")

    /// La synchronisation que le serveur renvoie après notre Confirm Active.
    static let serverSynchronise = bytes(
        "16001700ec03ea030100000116001f0016000100ea03")

    /// Son contrôle « coopérer » (action 4).
    static let serverControlCooperate = bytes(
        "1a001700ec03ea03010000011a0014001a0004000000ea030000")

    /// Son contrôle « accordé » (action 2) : la session est à nous.
    static let serverControlGranted = bytes(
        "1a001700ec03ea03010000011a0014001a0002000000ea030000")

    /// Sa carte des polices : le dernier message de l'établissement.
    static let serverFontMap = bytes(
        "1a001700ec03ea03010000011a0028001a000000000003000400")

    /// Et sa première mise à jour, qui suit immédiatement.
    static let serverFirstUpdate = bytes(
        "16001700ec03ea030100000116000200160003000000")
    // MARK: - Les mises à jour d'écran

    /// Sa synchronisation d'écran : une mise à jour de genre 3, qui ne porte
    /// aucun pixel.
    static let updateSynchronise = bytes(
        "03000000")

    /// Une mise à jour d'un seul rectangle, 8×15 en 24 bits, comprimée.
    static let updateWithOneRectangle = bytes(
        "010001006f0185017501930108000f0018000100830000007b001800680181de" +
        "dede79dedede810000006500000089dedede000000dedededededededededede" +
        "de000000000000dedede6ddedede85000000000000dededededede0000006500" +
        "000084dedede000000000000dedede65dedede82000000dedede66dedede8200" +
        "00000000000682dedede0000006500000081dedede77dedede")

    /// Et une de **deux** rectangles dans le même message. Le second commence
    /// où le premier finit, et c'est la longueur du premier qui le dit.
    static let updateWithTwoRectangles = bytes(
        "010002008801de007702f300f000160018000100f60b0000ee0bd002e03d2014" +
        "85fffffd73ccfca5dcf8fefefefeffff3887fefefa2363e5014ce20047de0546" +
        "de94a8ddfdfbf92078001386fefefeffffffa2dcfb70c9f9f9fcfdffffff1689" +
        "fefefeffffffbed0f00751e5004ce20147de0d4bddd2d6e0ffffff00ab87ffff" +
        "ffffffffd5edfa56befcd8edf8fffffffefefe158affffffffffff6993ed0450" +
        "e5004ce20148de3b69ddf2f0eafffffffefefe007785fefefeffffffffffffff" +
        "fffffefefe001085fefffc6fc5fa99d6f8fffffefeffff0f8ffefefeffffffff" +
        "fffffffffffefefefefefefffffff5f7f91c60e8024fe5014ce20148de819ddd" +
        "f8f7f5ffffff607affffff84fefefefefefefffffffefefe000e87fefefeffff" +
        "ff9cd8fa65c2fbf2f8fafffffffefefe0d8ffefefefffffffefefefefefefefe" +
        "fefffffffefeffffffff9fbaf00756e7014fe5004ce2094bdec5cdddfffffe00" +
        "7985fefefefefefefbfbfbfcfcfcffffff6011ffffff85d1edfb52bbfeb5ddf8" +
        "fffffefeffff0d90fffffffffffffcfcfcfbfbfbfefefefffffffffffffffffa" +
        "417beb0254e8014fe5004be23668def0efeafffffffefefe007a86fafafafafa" +
        "fafdfdfdfffffffffffffefefe000281fefefe0481fefefe0686fefdfd65c2fb" +
        "6ac1f9f9fbfcfffffffefefe0d8efefefefbfbfbf9f9f9fcfcfcfefefeffffff" +
        "c2d3f10d5ae80052e8024fe5004ae28aa2ddf9f8f7ffffff7bffffff81fefefe" +
        "0481fefefe005889fffffffefefefafafafbfbfbfbfbfbfdfdfdfefefeffffff" +
        "fefefe1f94fefefefffffffffffffefefefefefefefefeffffffffffffffffff" +
        "fffffffefefefffffffffffffefefeffffff9fd9f84ab5fdc1e5f9fffffefefe" +
        "ff0c8efefefefffffffcfcfcfbfbfbfbfbfbfdfdfdfffffa568bed0456e90053" +
        "e8014fe51052e1d1d5e1ffffff1a8bfefefefffffffffffffffffffefefefefe" +
        "fefefefefffffffffffffffffffefefe005788fdfdfdfdfdfdfbfbfbf9f9f9fc" +
        "fcfcfefefefffffffefefe1d96fefefefffffffefefefefefefdfdfdfdfdfdfe" +
        "fefefdfdfdfefefefefefefefefefffffffefefeffffffffffffffffffdff1fa" +
        "50b7fb6cc2faf9fbfbfffffffefefe0b8ffffffffffffffefefefefefefcfcfc" +
        "fffdfac9d9f21b69eb0053e80053e8004de5537ddff2f1eefffffffefefe198c" +
        "fffffffffffffefefefefefefdfdfdfdfdfdfefefefdfdfdfefefefefefeffff" +
        "fffefefe00548bfefefefffffffffffffffffffdfdfdfbfbfbf9f9f9fbfbfbfe" +
        "fefefffffffefefe1c96fffffffefefefefefefdfdfdfdfdfdfdfdfdfcfcfcfc" +
        "fcfcfcfcfcfcfcfcfdfdfdfefefefffffffffffffffffffefefffffffd78c6f9" +
        "46b1fdb9dff9fffffefefeff0c8dfefefefffffffffffffffffefdfcf96b9ced" +
        "1e6be80656e70053e8024ce4adbdddfbfbfbffffff7affffff8cfefefefefefe" +
        "fdfdfdfcfcfcfdfdfdfdfdfdfcfcfcfcfcfcfcfcfcfcfcfcfefefeffffff0054" +
        "8cfffffffffffffefefefffffffffffffefefef9f9f9f9f9f9fbfbfbfefefeff" +
        "fffffefefe1d89fdfdfdfdfdfdfcfcfcfbfbfbfbfbfbfbfbfbfcfcfcfbfbfbfb" +
        "fbfb0488fefefeffffffc8e7fa43b0fd61bafbeff6f9fffffffefefe0b8cffff" +
        "fffffffffefeffffffffb1caf53479eb1e69e71e64e80253e73469e2e7e8e9ff" +
        "ffff7bffffff8bfefefefcfcfcfdfdfdfcfcfcfbfbfbfbfbfbfbfbfbfcfcfcfc" +
        "fcfcfbfbfbfdfdfd00578bfffffffefefefffffffefefefdfdfdfbfbfbf9f9f9" +
        "fbfbfbfefefefffffffefefe1b88fdfdfdfcfcfcfdfdfdfcfcfcfcfcfcfcfcfc" +
        "fafafafefefe0689fffffffffffff9fcfd64befa40adfe94cef8fffffdffffff" +
        "fefefe0b8cfefefeffffffecf2f94183f10c61ed1463e83373ea115ae698aede" +
        "f8f8f8fffffffefefe1b89fbfbfbfefefefbfbfbfcfcfcfcfcfcfbfbfbfbfbfb" +
        "fdfdfdfafafa00598bfffffffefefefffffffffffffdfdfdf9f9f9f9f9f9fbfb" +
        "fbfefefefffffffefefe1c88fcfcfcfdfdfdfcfcfcfcfcfcfbfbfbfdfdfdfbfb" +
        "fbfcfcfc0589fefefeffffffb8e1f83baafe4baffdc6e4fafffffefefffffefe" +
        "fe098bfefefefffffffffffc7aaaf10963ef005aed0459e92269e9497ce1dde0" +
        "e5fdfdfd1e86fcfcfcfcfcfcfdfdfdfbfbfbfcfcfcfcfcfc005c8bfffffffefe" +
        "fefffffffefefefdfdfdfbfbfbfafafafdfdfdfefefefffffffefefe1a88fdfd" +
        "fdfcfcfcfbfbfbfcfcfcfdfdfdfdfdfdfcfcfcfcfcfc068afffffffefefef1f9" +
        "fb61bafa39a6ff5eb6fbe2f0f9fffffefffefffefefe078ffefefeffffffffff" +
        "fea6c8f51970f0005eef025ced0157e90151e89db3def4f4f4fdfdfdfdfdfdff" +
        "fffffefefe1b88fefefefbfbfbfcfcfcfcfcfcfdfdfdfdfdfdfcfcfcfcfcfc00" +
        "5b8bfffffffefefefffffffffffffdfdfdfafafafbfbfbfcfcfcfefefeffffff" +
        "fefefe1889fefefefdfdfdfdfdfdfcfcfcfcfcfcfcfcfcfbfbfbfcfcfcfdfdfd" +
        "078afffffefefefec0e3fa32a4fc37a4fd71bbf7ecf5f9fffffefffefffefefe" +
        "0591fefefefffffffffffebcd5f72d7cf20061f2005fef025ced0054e9326ee3" +
        "dee2ebfafafafafafafbfbfbfdfdfdfffffffefefe1987fdfdfdfdfdfdfcfcfc" +
        "fbfbfbfcfcfcfbfbfbfbfbfb005e8bfffffffffffffffffffefefefcfcfcfafa" +
        "fafafafafcfcfcfefefefffffffefefe178afffffffdfdfdfcfcfcfdfdfdfdfd" +
        "fdfdfdfdfcfcfcfcfcfcfcfcfcfefefe068001fffffffffffff5fafd6dbef72f" +
        "a2fe33a0fd71bcf9e5f2f7fffffefffffffefffffefefefffffffefefefeffff" +
        "fffffffffffdbad4f73683f40363f30061f2005fef035ded0054e9a5b9e0fafa" +
        "fafdfdfdfafafafafafafbfbfbfdfdfdfffffffefefe188afefefefcfcfcfcfc" +
        "fcfefefefdfdfdfdfdfdfcfcfcfcfcfcfdfdfdfefefe005e89fffffffdfdfdf9" +
        "f9f9f9f9f9fafafafcfcfcfefefefffffffefefe158dfefefefffffffefefefe" +
        "fefefefefefdfdfdfdfdfdfcfcfcfdfdfdfefefefefefefffffffefefe048002" +
        "fefefefffffffefefed1ebfa3ba7fa2f9fff2c9bfd5cb0f8c1e0fafffffcffff" +
        "fefffffffffffffffffffffffcfbfbfa98c2f82a80f40267f50063f30062f204" +
        "61ef0159ef5c8ae2e9ecf1fffffefffffffafafaf9f9f9fafafafafafafefefe" +
        "fffffffefefe1684fffffffffffffefefefefefe0484fdfdfdfefefefffffffe" +
        "fefe005d8afefefefbfbfbf6f6f6f9f9f9fafafaf8f8f8fbfbfbfefefeffffff" +
        "fefefe1485fffffffefefefffffffffffffefefe64fefefe84fffffffffffffe" +
        "fefeffffff048003fffffffefefffffffef9fcfda1d3f8259afc2b9aff2695fd" +
        "389dfa6ab6fab4d8f9e0effbebf5fcd7e9fc97c5fa4998f71378f8006bf60067" +
        "f60063f30564f20560f1246de8c8d4e9fdfdfcfffffffdfdfdf7f7f7f7f7f7fb" +
        "fbfbf8f8f8fafafafefefefffffffefefe1585fefefefffffffffffffffffffe" +
        "fefe64fefefe83fffffffefefeffffff005d8afffffffdfdfdfbfbfbfdfdfdfd" +
        "fdfdfafafafafafafbfbfbfefefeffffff1584fffffffffffffefefeffffff65" +
        "ffffff82fefefeffffff068002fefefefffffffffffeecf5fb71bcf72096fd27" +
        "95ff1c90fd1d8efe2992fc2f93fb3092fa308ff81880fa0071fb006ef9016cf7" +
        "0068f60665f40965f4055eefa2b9e4f7f8f8fffffefffffffefefefafafafcfc" +
        "fcfefefefbfbfbfafafafafafafcfcfcffffff1584fffffffffffffefefeffff" +
        "ff65ffffff82fefefeffffff005d87fefefefffffffefefefefefefffffffefe" +
        "fefdfdfd1b70ffffff8000fefefffffffffffffedaeef951adf61d92fe1f91fe" +
        "198cff1186fe0a80fe047dfe047afd0878fc0573fb016ffa016cf60669f60b67" +
        "f5005cf383a7e4f0f2f6fffffefffffffefefefffffffefefefefefefffffffe" +
        "fefefcfcfcfafafafefefe186067ffffff82fefefeffffff64ffffff83fdfdfd" +
        "fdfdfdffffff00088000fefefefefefffffffffefefecde8f943a5f7188dfc1a" +
        "8cff1387ff0c82ff077fff037bff0376fd0a77fb0571f9056ef5096bf6005ff5" +
        "75a0e6e7ecf3fffefefffffffefefffefefefefefeffffffffffffffffffffff" +
        "fffefefefcfcfcffffff007f64ffffff86fefefefffffffefefefefefeffffff" +
        "fefefe00078001fffffffefefefffffffffffffefefed2e8fa4fa9f80d86fc13" +
        "87ff0d82ff077ffe037bff0175fe0373fb0c76f90c6ff50667f380a9e9e9eef5" +
        "fffefefffffffffffffefefefffffffffffffffffffffffffefefefffffffefe" +
        "fefefefefffffffefefe00758801db007702dd00f000030018000100e1000000" +
        "d900d00270082e84fefefefffffffffffffefefe200a94fefefeffffffffffff" +
        "fefffee5f2fa80bff81889fc067efe047dff0279ff0074fe0070fb0069f83583" +
        "f0b1caedf5f6f9fffffefffffffffffffefefe2684fefefefffffffffffffefe" +
        "fe20760e600fffffff93fefefefffffffffffffefefef9fcfbd8ecf986c0f944" +
        "9cfb278cfb2c8cfa5a9ff5adccf3eaf2f8fbfcfcfefefefffffffefefffefefe" +
        "ffffff0660b8ffffff91fefefefffffffffefefefffefefefffcfdfdf7fcfaf6" +
        "fbfcf9fbfdfafcfcfdfefdfffefffefefefefefefffffffefefeffffff0081")
}
#endif

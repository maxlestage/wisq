import CWisqVM
import Foundation

/// **Une image de disque optique, telle que Swift l'atteint.**
///
/// Quelqu'un arrive avec une image d'installation et veut la faire tourner. Le
/// noyau est dedans, sous `/boot`, avec son initramfs et la recette qui dit
/// comment les démarrer. Le lecteur vit en Rust, à côté du reconnaisseur de
/// noyaux qui juge ce qu'on en sort ; l'application, la bibliothèque et le
/// chargeur vivent ici.
///
/// **Ce qui ne traverse pas la frontière est le point important : l'image.**
/// Elle pèse des gibioctets, et un téléphone n'en a pas. Ce qui passe, ce sont
/// deux chemins et un verdict.
///
/// Pas d'instance, parce qu'il n'y a pas d'état : chaque appel ouvre l'image,
/// lit ce qu'on lui demande, et referme. Garder un descripteur ouvert entre
/// deux appels obligerait à décider quand le fermer, pour économiser une
/// ouverture de fichier qui ne coûte rien à côté de ce qu'on en extrait.
public enum IsoImage {
    /// **La recette de démarrage que l'image porte.**
    ///
    /// Le chargeur d'amorçage de la distribution est un fichier texte qui dit
    /// exactement ce qu'il faut : quel noyau, quel initramfs, et avec quels
    /// arguments. **On le lit, on ne le devine pas** — une ligne de commande
    /// inventée démarre un noyau qui ne trouve pas sa racine, et la panne tombe
    /// très loin de sa cause.
    public struct Recipe: Equatable, Sendable {
        /// Le fichier d'où elle vient. **Rendu pour que l'écran puisse le
        /// nommer** : quand un démarrage tourne mal, savoir quelle recette a
        /// servi vaut mieux que la deviner.
        public let from: String
        public let kernel: String
        /// Absent quand la recette n'en cite pas. Une recette sans initramfs
        /// existe — un noyau qui porte ses pilotes — et prétendre le contraire
        /// serait une supposition de plus.
        public let initrd: String?
        public let commandLine: String
    }

    /// La recette de l'image, ou `nil` si ce n'en est pas une, ou si elle n'en
    /// porte aucune.
    ///
    /// **Les deux `nil` ne sont pas distingués ici, et c'est délibéré** :
    /// l'appelant fait la même chose des deux — il refuse en disant ce que le
    /// fichier est — et une distinction que personne n'emploie est une
    /// promesse de plus à tenir.
    public static func recipe(of url: URL) -> Recipe? {
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        let ok = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return wisq_iso_recipe(path, &out, &length)
        }
        guard ok == 0, let out else { return nil }
        defer { wisq_x86_free_module(out, length) }
        let bytes = Data(UnsafeBufferPointer(start: out, count: length))

        // **Quatre chaînes terminées par un octet nul.** C'est la convention de
        // la frontière, et elle a une raison : une ligne de commande porte des
        // espaces, des égales et des virgules ; un chemin porte tout sauf
        // l'octet nul. Le seul séparateur qui n'ait pas besoin d'échappement.
        var fields: [String] = []
        var start = bytes.startIndex
        while let nul = bytes[start...].firstIndex(of: 0) {
            fields.append(String(decoding: bytes[start..<nul], as: UTF8.self))
            start = bytes.index(after: nul)
        }
        // **Quatre exactement — et ce n'est pas ce test-ci qui le tient.**
        //
        // Aucune image ne peut faire rendre autre chose que quatre champs à
        // l'ABI : il faudrait que l'ABI change. C'est `tests/abi/iso.c` qui
        // surveille ça, en comptant les champs contre l'en-tête.
        //
        // Ce que cette ligne fait, c'est **transformer une dérive en refus
        // plutôt qu'en arrêt brutal** : sans elle, `fields[3]` sortirait du
        // tableau, et l'application mourrait sur un téléphone au lieu de dire
        // qu'elle ne sait pas lire l'image. Une garde peut valoir pour ce
        // qu'elle évite même quand rien d'ici ne peut la faire échouer.
        guard fields.count == 4 else { return nil }
        return Recipe(
            from: fields[0], kernel: fields[1],
            initrd: fields[2].isEmpty ? nil : fields[2],
            commandLine: fields[3])
    }

    /// Écrit un membre de l'image dans un fichier. Rend `false` en cas d'échec.
    ///
    /// `ceiling` est ce que l'appelant accepte d'écrire ; au-delà, refus
    /// **avant** d'avoir rien écrit. Un noyau à moitié extrait se charge, et
    /// meurt dans une instruction qui n'a rien à voir.
    ///
    /// **Le fichier de destination est effacé quand la copie échoue en
    /// chemin.** L'ABI le laisse incomplet — elle ne décide pas à la place de
    /// qui l'a nommé — et c'est ici qu'on décide : un reste tronqué sur le
    /// disque d'un téléphone se ferait prendre pour un noyau au démarrage
    /// suivant.
    @discardableResult
    public static func extract(
        _ inside: String, from url: URL, to destination: URL, ceiling: UInt64
    ) -> Bool {
        let ok = url.withUnsafeFileSystemRepresentation { image -> Int32 in
            destination.withUnsafeFileSystemRepresentation { into -> Int32 in
                guard let image, let into else { return -1 }
                return wisq_iso_extract(image, inside, into, ceiling)
            }
        }
        if ok != 0 {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        return true
    }
}

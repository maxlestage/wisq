import Foundation
import WisqVM

/// **Démarrer depuis l'image qu'on apporte.**
///
/// Quelqu'un arrive avec une image d'installation — Alpine, Arch, Ubuntu — et
/// veut la faire tourner. Ce qu'il faut est dedans : un noyau sous `/boot`,
/// son initramfs à côté, et la recette du chargeur d'amorçage qui dit avec
/// quels arguments les démarrer. `IsoImage` sait les atteindre ; ce fichier-ci
/// décide **quoi en faire**, et surtout quand refuser.
///
/// ## Ce qui ne traverse pas
///
/// L'image reste sur le disque. Elle pèse des gibioctets et un téléphone n'en
/// a pas ; seuls le noyau et l'initramfs sont sortis, dans un dossier que
/// l'appelant nomme. L'image elle-même est ensuite branchée comme disque, lue
/// secteur par secteur là où elle est — c'est ce que la distribution attend,
/// puisque sa racine y vit.
///
/// ## Trois décisions, et pourquoi elles sont ici
///
/// **Le dossier est vidé avant d'écrire.** Sans ça, l'initramfs d'une image
/// chargerait avec le noyau d'une autre — une machine qui démarre à moitié,
/// sur une combinaison que personne n'a jamais gravée. Rien dans le résultat
/// ne le dirait.
///
/// **Les noms sur le disque sont fixes.** Les chemins de la recette sont
/// écrits par qui a gravé l'image, et ce n'est pas nous. S'ils décidaient où
/// les octets atterrissent, un `../../` bien placé écrirait ailleurs. Deux
/// noms posés ici, et la garde est dans la forme plutôt que dans un filtre
/// qu'il faudrait tenir à jour.
///
/// **Un initramfs promis et absent est un refus.** Un noyau de PC n'a aucun
/// pilote de disque compilé dedans : ils vivent là. Sans lui, ce qui suit est
/// un démarrage complet, deux cent soixante-deux lignes de journal, puis
/// « VFS: Unable to mount root fs on unknown-block(0,0) » — une panne trois
/// cents lignes après sa cause.
public enum IsoBoot {
    /// Le nom du noyau extrait, dans le dossier de déballage. Posé ici, jamais
    /// pris dans l'image.
    public static let kernelName = "vmlinuz"
    /// Celui de l'initramfs, pour la même raison.
    public static let initrdName = "initramfs"

    /// De quoi démarrer une machine, une fois l'image ouverte.
    public struct Plan: Equatable, Sendable {
        /// Le noyau extrait, sur le disque de l'application.
        public let kernel: URL
        /// L'initramfs extrait, quand la recette en cite un.
        public let initrd: URL?
        /// La ligne de commande **lue** dans la recette, au caractère près.
        public let commandLine: String
        /// Le fichier de recette d'où tout vient, pour que la console puisse
        /// le nommer quand un démarrage tourne mal.
        public let recipe: String
    }

    /// Pourquoi on ne démarre pas.
    ///
    /// **Aucun cas ne prétend savoir pourquoi une extraction a échoué.** La
    /// frontière rend un seul échec pour « ce membre n'est pas là » et « il
    /// dépasse le plafond » ; les distinguer ici serait inventer.
    public enum Refusal: Error, Equatable, Sendable {
        /// Pas une image, ou une image sans recette de démarrage lisible. Les
        /// deux se traitent pareil, donc ils ne sont pas séparés.
        case noRecipe
        case cannotPrepare
        case cannotExtractKernel(String)
        case cannotExtractInitrd(String)
    }

    /// **Ce qu'il faut savoir du fichier choisi, image ou non.**
    ///
    /// Le modèle de vue appelle ceci et lie ce qu'il reçoit. La décision vit
    /// ici plutôt que là-bas pour une raison de couverture, pas d'élégance :
    /// `WisqUI` est derrière `#if os(iOS)` et n'est compilé que par la CI
    /// d'Apple, alors que ce fichier-ci est typé et exécuté par la CI Linux à
    /// chaque commit. Ce qui reste dans le modèle est une liaison de champs.
    public struct Boot: Equatable, Sendable {
        /// Ce que la machine doit exécuter — le noyau **sorti** de l'image
        /// quand c'en était une, le fichier choisi sinon. C'est lui qui décide
        /// du cœur : l'image, personne ne l'exécute.
        public let kind: KernelImageKind
        public let kernel: URL
        /// L'image elle-même, à brancher comme disque : sa racine y vit.
        public let disk: URL?
        /// Celle de la recette, ou rien quand le fichier n'est pas une image.
        public let commandLine: String?
        public let initrd: URL?

        /// Le fichier tel qu'il est, quand il n'y a rien à déballer.
        static func plain(_ url: URL, _ kind: KernelImageKind) -> Boot {
            Boot(kind: kind, kernel: url, disk: nil, commandLine: nil, initrd: nil)
        }
    }

    /// **Ce que l'image demande, plus ce dont wisq a besoin pour parler.**
    ///
    /// Ce sont deux lignes qui disent des choses différentes, et il faut les
    /// deux. Celle de l'image dit **où est la racine** — sans
    /// `archisobasedir`, archiso ne trouve pas son squashfs et panique. Celle
    /// de wisq dit **où écrire** : `console=ttyS0` ouvre la console une fois le
    /// pilote série chargé, `earlyprintk=serial` fait écrire le noyau
    /// directement sur le port 0x3F8 dès sa première ligne.
    ///
    /// **Une tranche a coûté un écran noir pour l'apprendre.** La ligne de la
    /// recette *remplaçait* celle de wisq. La machine démarrait, affichait
    /// « Démarrage… », et plus rien — le noyau écrivait sur un écran que
    /// personne ne lit. `X86BootLoader` le dit dans son propre commentaire :
    /// « sans elle, un démarrage qui échoue à mi-chemin ne dit rien du tout ».
    ///
    /// **La nôtre vient en dernier**, parce que Linux retient le **dernier**
    /// `console=` comme `/dev/console` : une image qui en nommerait un autre ne
    /// doit pas nous rendre muets.
    ///
    /// **Et `quiet` part.** C'est le seul mot qu'on retire, et pour une raison
    /// précise : il est écrit pour une machine qui a un écran de démarrage et
    /// qui n'a rien à dire à personne, alors qu'ici il éteindrait la seule
    /// sortie qui existe. Le reste passe mot pour mot — `splash` compris, qui
    /// ne demande qu'un dessin que personne ne fera.
    public static func commandLine(from recipe: String) -> String {
        let kept = recipe
            .split(separator: " ", omittingEmptySubsequences: true)
            .filter { $0 != "quiet" }
            .joined(separator: " ")
        return kept.isEmpty
            ? X86BootLoader.defaultCommandLine
            : "\(kept) \(X86BootLoader.defaultCommandLine)"
    }

    /// Où déballer, à partir du stockage que l'application connaît.
    ///
    /// **`nil` veut dire « l'endroit habituel »**, comme partout ailleurs dans
    /// ce dépôt : `SuspendedMachine` traite son `directory` de la même façon,
    /// et deux conventions pour la même chose seraient une occasion de plus de
    /// se tromper.
    public static func folder(in storage: URL?) -> URL? {
        guard let base = storage ?? (try? SuspendedMachine.directory()) else { return nil }
        return base.appendingPathComponent("iso", isDirectory: true)
    }

    /// Regarde le fichier choisi ; déballe si c'est une image amorçable.
    ///
    /// **Ce qui n'est pas une image traverse sans être touché** — pas de
    /// dossier créé, pas d'octet écrit. Le déballage est une branche, pas un
    /// passage obligé.
    ///
    /// `storage` est le dossier de l'application, tel qu'elle le porte :
    /// **optionnel**, et résolu ici. C'est délibéré, et c'est une leçon payée
    /// par un rouge. La version d'avant prenait un dossier déjà construit, donc
    /// l'appelant composait `storage.appendingPathComponent("iso")` — sur un
    /// `URL?`. Cette ligne-là vivait dans `LocalVMModel`, que la CI Linux ne
    /// compile pas, et elle n'a été refusée que dix minutes plus tard par la CI
    /// d'Apple. Le type optionnel traverse maintenant jusqu'ici, où il est
    /// vérifié à chaque commit.
    public static func decide(
        _ chosen: URL, unpackingInto storage: URL?, ceiling: UInt64
    ) -> Result<Boot, Refusal> {
        let kind = KernelImageKind.identify(fileAt: chosen)
        guard case .discImage = kind else { return .success(.plain(chosen, kind)) }
        guard let folder = folder(in: storage) else { return .failure(.cannotPrepare) }
        return decide(chosen, into: folder, ceiling: ceiling)
    }

    /// La même, sur un dossier nommé — ce que les tests emploient.
    public static func decide(
        _ chosen: URL, into folder: URL, ceiling: UInt64
    ) -> Result<Boot, Refusal> {
        let kind = KernelImageKind.identify(fileAt: chosen)
        guard case .discImage = kind else { return .success(.plain(chosen, kind)) }
        return unpack(chosen, into: folder, ceiling: ceiling).map { plan in
            Boot(
                kind: KernelImageKind.identify(fileAt: plan.kernel),
                kernel: plan.kernel, disk: chosen,
                // **La ligne complète, pas celle de la recette.** Voir
                // `commandLine(from:)` : celle de l'image ne dit pas où parler.
                commandLine: commandLine(from: plan.commandLine), initrd: plan.initrd)
        }
    }

    /// Ouvre l'image, en sort de quoi démarrer, ou dit pourquoi non.
    ///
    /// `ceiling` est ce que l'appelant accepte d'écrire pour **chaque** membre.
    public static func unpack(
        _ image: URL, into folder: URL, ceiling: UInt64
    ) -> Result<Plan, Refusal> {
        guard let recipe = IsoImage.recipe(of: image) else { return .failure(.noRecipe) }

        // Le dossier est refait à neuf : voir plus haut, c'est la garde qui
        // empêche deux images de se mélanger.
        let files = FileManager.default
        try? files.removeItem(at: folder)
        guard (try? files.createDirectory(at: folder, withIntermediateDirectories: true)) != nil
        else { return .failure(.cannotPrepare) }

        let kernel = folder.appendingPathComponent(kernelName)
        // **Rien à effacer ici, et un sabotage l'a dit.** `IsoImage.extract`
        // supprime déjà sa propre destination quand la copie échoue, et le
        // dossier vient d'être refait : il ne reste donc rien d'autre. Un
        // effacement de plus à cet endroit était du code que rien ne pouvait
        // tenir — celui d'en dessous, lui, est porteur, parce que le noyau y
        // est déjà écrit et que ce n'est pas `extract` qui l'a nommé.
        guard IsoImage.extract(recipe.kernel, from: image, to: kernel, ceiling: ceiling) else {
            return .failure(.cannotExtractKernel(recipe.kernel))
        }

        var initrd: URL?
        if let inside = recipe.initrd {
            let out = folder.appendingPathComponent(initrdName)
            guard IsoImage.extract(inside, from: image, to: out, ceiling: ceiling) else {
                // **Le noyau déjà sorti part avec.** Seul sur le disque d'un
                // téléphone, il se ferait prendre pour un noyau importé au
                // démarrage suivant.
                try? files.removeItem(at: folder)
                return .failure(.cannotExtractInitrd(inside))
            }
            initrd = out
        }

        return .success(
            Plan(
                kernel: kernel, initrd: initrd,
                commandLine: recipe.commandLine, recipe: recipe.from))
    }

    /// Ce qu'on affiche dans la console, en français et sans balisage : elle
    /// est une grille de terminal, pas une page.
    public static func explanation(_ refusal: Refusal, name: String) -> String {
        switch refusal {
        case .noRecipe:
            return """
                \(name) est une image de disque, mais wisq n'y a trouvé aucune \
                recette de démarrage — le fichier du chargeur d'amorçage qui \
                dit quel noyau prendre et avec quels arguments.

                Les images d'installation des distributions en portent une. \
                Une image de données, un disque gravé à la main ou une image \
                pour une autre architecture, non.
                """
        case .cannotPrepare:
            return """
                wisq n'a pas pu préparer de place pour déballer \(name).

                Il reste peut-être trop peu d'espace sur cet appareil.
                """
        case .cannotExtractKernel(let inside):
            return """
                \(name) annonce son noyau à \(inside), et wisq n'a pas pu l'en \
                sortir.

                Soit ce chemin ne mène nulle part dans l'image, soit le noyau \
                dépasse ce que cette machine peut charger.
                """
        case .cannotExtractInitrd(let inside):
            return """
                \(name) annonce son initramfs à \(inside), et wisq n'a pas pu \
                l'en sortir.

                Sans lui, ce noyau démarrerait entièrement avant de s'arrêter \
                faute de racine à monter : ses pilotes de disque ne sont pas \
                compilés dedans, ils vivent là.
                """
        }
    }
}

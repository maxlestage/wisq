import CWisqVM
import Foundation

/// **Le traducteur du bureau local, tel que Swift l'atteint.**
///
/// Le cœur x86 de wisq-vm n'est pas une machine : ni pagination, ni
/// périphériques, ni chargeur de noyau. Ce qui traverse le C ABI est une
/// fonction pure d'octets vers octets, plus quelques nombres décrivant ce que
/// le module engendré importe. La machine reste ici, en Swift.
///
/// Le type n'a pas d'instance parce qu'il n'a pas d'état : chaque appel
/// traduit une région et rend ses octets. Ce qui a un état — la table des
/// blocs, la correspondance adresse → indice, la mémoire de l'invité — vit
/// dans la vue, pas ici.
public enum DesktopTranslator {
    // MARK: - Ce que l'hôte doit fournir

    /// Ce que la correspondance adresse → indice occupe **au-dessus** de la RAM
    /// invitée, en pages de 64 Kio. L'hôte l'ajoute à la taille de la mémoire
    /// qu'il crée.
    ///
    /// Des fonctions et non des constantes, ici comme dans le header : un
    /// littéral serait une seconde déclaration d'un nombre que l'émetteur
    /// possède, et un module qui importe vingt-neuf globales instancié avec
    /// vingt-huit ne démarre pas du tout.
    public static var tablePages: UInt32 { wisq_desktop_table_pages() }

    /// Ce que le **tampon de traduction** occupe, encore au-dessus. L'hôte
    /// l'ajoute lui aussi : un module confiné le déclare dans son minimum.
    public static var tlbPages: UInt32 { wisq_desktop_tlb_pages() }

    /// Combien de globales `env.g0 … env.g<n-1>` le module importe.
    public static var globalCount: Int { wisq_x86_global_count() }

    /// L'emplacement de RIP parmi ces globales : où l'exécution s'est arrêtée.
    public static var ripSlot: Int { wisq_x86_rip_slot() }

    /// L'emplacement de la base du segment GS, que l'hôte pose et que le module lit.
    public static var gsSlot: Int { wisq_x86_gs_slot() }

    // MARK: - Traduire

    /// **La forme historique** : une région seule, qui rend la main dès qu'elle
    /// sort d'elle-même.
    ///
    /// `base` est l'adresse invitée où la région est chargée, et ce n'est pas
    /// décoratif : `call` empile une adresse de retour et `ret` la relit.
    /// `entry` est le décalage, dans `code`, où la traduction commence.
    ///
    /// Rend `nil` quand l'émetteur refuse la région. **Un refus est une issue
    /// normale, pas un défaut** — l'appelant interprète alors.
    public static func region(_ code: Data, base: UInt64, entry: Int) -> Data? {
        code.withUnsafeBytes { bytes -> Data? in
            var out: UnsafeMutablePointer<UInt8>?
            var length = 0
            let ok = wisq_x86_emit_region(
                bytes.bindMemory(to: UInt8.self).baseAddress, code.count,
                base, entry, &out, &length
            )
            return claim(ok, out, length)
        }
    }

    /// **La forme dont le bureau a besoin** : *liée* — ses blocs occupent la
    /// table partagée de l'hôte à partir de `slot` — et *confinée* : les
    /// adresses invitées sont pliées dans `pages` pages de 64 Kio, ce qui met
    /// la correspondance juste au-dessus, hors de portée de l'invité. Le module
    /// la lit lui-même et passe d'une région à l'autre sans repasser par
    /// l'application.
    ///
    /// `pages` doit être une puissance de deux : le pliage est un masque, et un
    /// masque ne décrit un intervalle que sur une puissance de deux. Sinon,
    /// `nil` — comme pour une région que l'émetteur ne sait pas traduire.
    public static func resolvingRegion(
        _ code: Data, base: UInt64, entry: Int, slot: UInt32, pages: UInt32
    ) -> Translation {
        code.withUnsafeBytes { bytes -> Translation in
            var out: UnsafeMutablePointer<UInt8>?
            var length = 0
            let outcome = wisq_x86_emit_resolving(
                bytes.bindMemory(to: UInt8.self).baseAddress, code.count,
                base, entry, slot, pages, &out, &length
            )
            if outcome == WISQ_X86_NEEDS_MORE { return .needsMoreBytes }
            guard let module = claim(outcome, out, length) else { return .refused }
            return .module(module)
        }
    }

    /// **Ce qu'une traduction peut donner, et il y a trois issues.**
    ///
    /// Un refus franc et un manque d'octets ne se corrigent pas pareil : le
    /// premier arrête la machine, le second coûte un aller-retour et donne le
    /// module. Les confondre ferait abandonner une région traduisible, ou
    /// redemander pour rien à chaque vrai refus.
    public enum Translation: Equatable, Sendable {
        case module(Data)
        /// L'émetteur ne sait pas traduire cette région, et davantage d'octets
        /// n'y changerait rien.
        case refused
        /// L'émetteur s'est arrêté à moins de quinze octets du bord de ce qu'on
        /// lui a donné : l'instruction qui l'a bloqué a pu être coupée.
        /// Redemander la même région avec une fenêtre plus large, **une seule
        /// fois**. Sur un vrai noyau, 91 régions sur 10 116 tombent là avec
        /// quatre kibioctets, et toutes se traduisent au second essai.
        case needsMoreBytes
    }

    // MARK: - La page

    /// **Le cadre que le chargeur a déclaré au noyau**, tel que la vue doit le
    /// peindre. Les trois nombres sont ceux du `screen_info` que l'application
    /// remplit avant de démarrer la machine.
    public struct Screen: Equatable, Sendable {
        /// L'adresse **invitée** du tampon d'affichage, repliée dans la RAM
        /// comme toutes les autres.
        public let base: UInt64
        public let width: UInt32
        public let height: UInt32

        public init(base: UInt64, width: UInt32, height: UInt32) {
            self.base = base
            self.width = width
            self.height = height
        }
    }

    /// **La page que l'application charge dans sa vue** : la boucle hôte, le
    /// pont vers l'application, l'état de départ de la machine.
    ///
    /// `channel` nomme le gestionnaire de messages que l'application déclare.
    /// Il est *collé dans du JavaScript*, donc seules les lettres et les
    /// chiffres sont acceptés — le même soin que pour un identifiant de VM
    /// collé dans une ligne de commande.
    ///
    /// **Le cadre est facultatif.** Quand il est donné, la page porte un
    /// `<canvas>` à ses dimensions et une boucle d'affichage ; sans lui, il n'y
    /// a rien à montrer — un démarrage jugé sur ses registres est un cas réel.
    /// Ses trois nombres viennent du `screen_info` que l'application a rempli
    /// avant de démarrer la machine : c'est elle qui a choisi où vit le tampon
    /// d'affichage.
    ///
    /// Rend `nil` quand la RAM n'est pas une puissance de deux, quand le nom du
    /// canal ne peut pas être collé sans risque, ou quand le cadre déborderait
    /// de la RAM de l'invité — au-dessus vit la correspondance, et un cadre à
    /// cheval sur ce bord afficherait la table des blocs en la détruisant.
    public static func page(
        pages: UInt32,
        entry: UInt64,
        channel: String,
        screen: Screen? = nil
    ) -> String? {
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        let ok = channel.withCString { name in
            wisq_desktop_page(
                pages, entry, name,
                screen?.base ?? 0, screen?.width ?? 0, screen?.height ?? 0,
                &out, &length
            )
        }
        guard let bytes = claim(ok, out, length) else { return nil }
        // La page est de l'UTF-8 que Rust vient d'écrire ; un String qui échoue
        // ici serait un défaut de l'émetteur, pas une entrée à refuser.
        return String(data: bytes, encoding: .utf8)
    }

    // MARK: -

    /// Recopie ce que Rust a alloué et le lui rend aussitôt.
    ///
    /// Les trois producteurs se rendent à `wisq_x86_free_module` et à rien
    /// d'autre — pas à `free()`, et pas à `wisq_vm_free_snapshot`, qui appartient
    /// aux instantanés de machine. La copie est le prix d'un `Data` que Swift
    /// possède vraiment ; un module fait quelques centaines d'octets, et il est
    /// produit une fois par région.
    ///
    /// **Le `ok == 0` est une garde qu'aucun test d'ici ne peut tenir**, et c'est
    /// dit plutôt que caché : côté Rust, chaque refus rend `-1` *avant* d'écrire
    /// quoi que ce soit dans les sorties, donc le pointeur reste `nil` et le
    /// `guard let out` seul répondrait pareil. Le sabotage qui retire la
    /// vérification du code de retour survit à toute la suite, forcément. Ce qui
    /// tient vraiment cette promesse est le programme C
    /// (`crates/wisq-vm/tests/abi/x86.c`), qui vérifie qu'un refus **ne touche
    /// pas aux sorties de l'appelant**. La garde est ici pour le jour où ça
    /// changerait de l'autre côté.
    private static func claim(
        _ ok: Int32, _ out: UnsafeMutablePointer<UInt8>?, _ length: Int
    ) -> Data? {
        guard ok == 0, let out else { return nil }
        defer { wisq_x86_free_module(out, length) }
        return Data(UnsafeBufferPointer(start: out, count: length))
    }
}

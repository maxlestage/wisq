import XCTest

@testable import WisqVM

/// **Un message écrit pour un humain, posé dans une grille de terminal.**
///
/// Les refus de wisq — « ce fichier est un ISO », « ce noyau vise une
/// architecture qu'on n'a pas » — sont de la prose. Ils finissent dans une
/// `TerminalGrid`, qui est un vrai terminal : elle coupe à la colonne, sans
/// savoir ce qu'est un mot, et elle ne rend aucun balisage.
///
/// Les deux défauts que ce fichier tient viennent d'une capture d'écran de
/// Maxime, pas d'une relecture :
///
/// * `**disque**` s'affichait avec ses astérisques, et `` `/dev/vda` `` avec
///   ses accents graves. Du Markdown écrit pour un lecteur qui n'existe pas.
/// * Le retour à la ligne tombait au milieu des mots — « ne changer / a ça »,
///   « pour quo / i », « l / a verra ».
///
/// La correction est une seule fonction, et ces tests disent ce qu'elle doit
/// faire **avant** qu'elle existe.
final class ConsoleProseTests: XCTestCase {
    /// **L'emphase et le code disparaissent, leur contenu reste.**
    ///
    /// Retirer les marques sans garder le texte serait pire que de les laisser :
    /// `/dev/vda` est précisément ce que la personne doit lire.
    func testMarkdownMarkersAreRemovedAndTheirTextKept() {
        let written = ConsoleProse.plain(
            "Gardez-la comme **disque** : l'invité la verra sur `/dev/vda`.",
            columns: 200)
        XCTAssertEqual(
            written, "Gardez-la comme disque : l'invité la verra sur /dev/vda.",
            "les marques partent, le mot et le chemin restent")
    }

    /// **Un astérisque qui n'est pas une marque n'est pas touché.**
    ///
    /// Une ligne de commande porte des astérisques ; les manger ferait d'une
    /// mise en forme une corruption de la chose même qu'on affiche.
    func testALoneAsteriskSurvives() {
        let written = ConsoleProse.plain("rm -f /tmp/*.img", columns: 200)
        XCTAssertEqual(written, "rm -f /tmp/*.img", "un astérisque seul n'est pas de l'emphase")
    }

    /// **Une marque ouverte et jamais fermée n'avale pas la fin de la ligne.**
    ///
    /// Ce cas-ci a été ajouté après un sabotage qui a survécu : le test
    /// précédent n'a qu'**un** astérisque, donc il ne peut pas distinguer
    /// « je ne vois pas de paire » de « je prends tout jusqu'au bout ». Une
    /// marque ouverte sans fermeture est la seule entrée qui les sépare.
    func testAnUnclosedMarkerDoesNotSwallowTheRest() {
        XCTAssertEqual(
            ConsoleProse.plain("un ** ouvert et jamais fermé", columns: 200),
            "un ** ouvert et jamais fermé",
            "sans fermeture, il n'y a pas de paire : rien ne part")
        XCTAssertEqual(
            ConsoleProse.plain("un ` seul et rien d'autre", columns: 200),
            "un ` seul et rien d'autre",
            "un seul accent grave non plus")
        // **Et le contre-exemple, pour que la garde ci-dessus ne passe pas
        // pour une règle qu'elle n'est pas** : deux accents graves *forment*
        // une paire, et là le contenu sort bien de ses marques.
        XCTAssertEqual(
            ConsoleProse.plain("trois `est` un mot", columns: 200),
            "trois est un mot",
            "deux marques appariées, elles, disparaissent")
    }

    /// **Le retour à la ligne tombe entre les mots, jamais dedans.**
    ///
    /// C'est le défaut visible sur la capture : à quarante-huit colonnes, la
    /// grille coupait « changera » en « changer » et « a ».
    func testWrappingNeverBreaksAWord() {
        let written = ConsoleProse.plain(
            "Ce n'est pas une question de mémoire, et aucun réglage ne changera ça.",
            columns: 40)
        for line in written.split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertLessThanOrEqual(line.count, 40, "aucune ligne ne dépasse la largeur")
        }
        XCTAssertTrue(
            written.contains("changera"),
            "le mot reste entier : c'est exactement ce que la grille cassait")
        // **Et la reconstitution doit être fidèle.** Un repli qui perdrait ou
        // dupliquerait un espace passerait la garde ci-dessus tout en abîmant
        // le texte.
        XCTAssertEqual(
            written.split(separator: "\n").joined(separator: " "),
            "Ce n'est pas une question de mémoire, et aucun réglage ne changera ça.",
            "recollées, les lignes rendent la phrase de départ")
    }

    /// **Un mot plus long que la ligne est coupé plutôt que perdu.**
    ///
    /// Le cas existe — un chemin de fichier interminable — et le refuser
    /// ferait disparaître du texte. Couper est laid ; perdre est faux.
    func testAWordLongerThanTheLineIsCutRatherThanDropped() {
        let long = String(repeating: "a", count: 25)
        let written = ConsoleProse.plain(long, columns: 10)
        XCTAssertEqual(
            written.replacingOccurrences(of: "\n", with: ""), long,
            "tous les caractères sont là")
        for line in written.split(separator: "\n") {
            XCTAssertLessThanOrEqual(line.count, 10, "et aucune ligne ne déborde")
        }
    }

    /// **Les paragraphes survivent au repli.**
    ///
    /// Le message de l'ISO en a deux, séparés par une ligne vide. Les fondre
    /// en un seul bloc rendrait le texte illisible sur un écran de téléphone.
    func testBlankLinesBetweenParagraphsAreKept() {
        let written = ConsoleProse.plain("Premier paragraphe.\n\nSecond.", columns: 40)
        XCTAssertEqual(
            written, "Premier paragraphe.\n\nSecond.",
            "la ligne vide qui sépare deux paragraphes reste")
    }
}

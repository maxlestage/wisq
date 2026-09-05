import XCTest

@testable import WisqUI
@testable import WisqVM

/// Ce que le refus a l'air, une fois arrivé à l'écran.
///
/// **Maxime l'a vu avant nous** : un import refusé, et au milieu de la
/// phrase, `**en mémoire**` avec ses quatre étoiles. Tous les refus de wisq
/// sont écrits en markdown léger — six d'entre eux portent un `**gras**` ou
/// un `` `chemin` `` — et pas un seul n'arrivait rendu.
///
/// La cause est une surcharge : `Text("**deux**")` écrit en toutes lettres
/// choisit `LocalizedStringKey`, qui lit le balisage ; la **même chaîne dans
/// une variable** choisit `String`, qui ne le lit pas. Rien ne prévient, et
/// le littéral d'à côté, lui, marche.
final class RefusalTextTests: XCTestCase {
    /// **Le balisage disparaît, les mots restent.**
    ///
    /// Le refus est celui d'un vrai fichier plutôt qu'une chaîne inventée :
    /// c'est celui-là qui doit sortir propre.
    func testTheMarkupIsGoneAndTheWordsStay() throws {
        // Un refus qui existe encore, et qui porte du balisage : l'identité de
        // l'image d'installation, suivie du plancher d'un secteur. Le plafond
        // de mémoire, lui, n'existe plus — le disque n'est plus tenu en
        // mémoire.
        let refusal = try XCTUnwrap(LocalDisk.refusal(
            size: 100, name: "omarchy-4.0.2.iso", kind: .discImage("ISO 9660")))
        XCTAssertTrue(refusal.contains("**"), "le refus est bien écrit en markdown")
        XCTAssertTrue(refusal.contains("`"), "et il porte un chemin")
        let plain = String(RefusalText.rendered(refusal).characters)
        XCTAssertFalse(plain.contains("**"), "les étoiles ne vont pas à l'écran")
        XCTAssertFalse(plain.contains("`"), "les accents graves non plus")
        XCTAssertTrue(plain.contains("dedans"),
                      "le mot reste : c'est sa mise en avant qui change, pas le texte")
        XCTAssertTrue(plain.contains("/boot"), "et le chemin reste lisible")
    }

    /// Et l'accent est **porté**, pas seulement retiré.
    ///
    /// Sans ce test, effacer les étoiles à la main passerait aussi bien : la
    /// phrase serait propre et n'aurait plus rien de gras, ce qui est
    /// exactement ce qu'on ne veut pas.
    func testTheEmphasisIsActuallyCarried() throws {
        let rendered = RefusalText.rendered("Le disque est tenu **en mémoire**, entier.")
        let strong = try XCTUnwrap(rendered.range(of: "en mémoire"))
        XCTAssertEqual(rendered[strong].inlinePresentationIntent, .stronglyEmphasized)
        let code = RefusalText.rendered("L'invité la verra sur `/dev/vda`.")
        let path = try XCTUnwrap(code.range(of: "/dev/vda"))
        XCTAssertEqual(code[path].inlinePresentationIntent, .code)
    }

    /// Les paragraphes tiennent.
    ///
    /// Un refus dit quoi, puis pourquoi, et la ligne vide entre les deux fait
    /// la moitié du travail. Le markdown en bloc les fusionnerait en une seule
    /// coulée ; c'est pour ça que l'analyse est inline et préserve les blancs.
    func testTheBlankLineBetweenParagraphsSurvives() throws {
        let refusal = try XCTUnwrap(LocalDisk.refusal(
            size: 100, name: "omarchy-4.0.2.iso", kind: .discImage("ISO 9660")))
        let plain = String(RefusalText.rendered(refusal).characters)
        XCTAssertEqual(plain.components(separatedBy: "\n\n").count, 3,
                       "trois paragraphes : ce que c'est, la taille, et pourquoi")
    }

    /// **Un pourcent dans un nom de fichier n'est pas une spécification de
    /// format.**
    ///
    /// Le raccourci habituel pour rendre du markdown depuis une variable est
    /// `Text(.init(chaîne))`, qui force `LocalizedStringKey`. Mais une clé
    /// passe aussi par le formatage, et « 50%.iso » est un nom de fichier
    /// valide — que le refus recopie. Le rendu passe donc par
    /// `AttributedString`, qui ne formate rien.
    func testAPercentInAFileNameSurvivesVerbatim() {
        let plain = String(RefusalText.rendered("50%.iso est une image.").characters)
        XCTAssertTrue(plain.hasPrefix("50%.iso"), "rendu : \(plain)")
    }

    /// Ce qui ne s'analyse pas s'affiche quand même.
    ///
    /// Le pire cas doit rester « le texte tel quel », jamais « rien ».
    func testTextThatCannotBeParsedIsStillShown() {
        XCTAssertEqual(String(RefusalText.rendered("un refus tout simple").characters),
                       "un refus tout simple")
    }
}

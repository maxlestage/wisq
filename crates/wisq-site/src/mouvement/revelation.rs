//! Chaque bloc se lève une fois, quand il entre dans la vue.

use super::outils;
use web_sys::{Document, HtmlElement};

/// Ce qui se révèle en entrant dans la vue : les sections de l'accueil — sauf
/// l'ouverture, qui a sa propre entrée —, et les blocs d'un document — sauf
/// son en-tête, qui entre avant la première peinture, mot par mot, sous
/// `html.entree`. Révélé ici aussi, il serait peint, masqué, puis rejoué. Posé ici
/// plutôt qu'à la construction : une marque dans le HTML serait une promesse
/// rendue à un lecteur sans script, et elle ne lui sert à rien.
const REVELES: &str = "#main > section:not([data-ouverture]), .doc > .wrap > :not(.doc-head)";

/// Les grilles dont les enfants arrivent en cascade plutôt qu'ensemble — les
/// cartes, et depuis qu'il y a plus à lire, tout ce qui est une liste : les
/// points d'un document, ses définitions, les lignes d'un tableau, le sommaire,
/// les colonnes du pied, et les lettres du nom géant qui le termine.
const GRILLES: &str = ".cards, .steps, .facts, .traits, .etat-liste, .doc-list, .doc-dl, \
                       tbody, .sommaire ol, .footer-groups, .pied-geant";

/// À la huitième carte le retard cesse de croître : une grille longue ferait
/// sinon attendre sa fin plus d'une seconde, ce qui n'est plus un rythme mais
/// une latence.
const RANG_MAX: i32 = 7;

pub fn demarrer(document: &Document) {
    // Le bas de la fenêtre est trop tard : le bloc arriverait déjà lu.
    let Some(observateur) = outils::observer("0px 0px -10% 0px", |entree, observateur| {
        if !entree.is_intersecting() {
            return;
        }
        let cible = entree.target();
        let _ = cible.set_attribute("data-revealed", "");
        // **Une fois, et on cesse de regarder.** Un bloc qui rejouerait à
        // chaque passage transformerait une page longue en clignotement.
        observateur.unobserve(&cible);
    }) else {
        return;
    };

    for bloc in outils::tous::<HtmlElement>(document, REVELES) {
        let _ = bloc.set_attribute("data-reveal", "");
        observateur.observe(&bloc);
    }

    // **La cascade.** Une grille entière qui apparaît d'un bloc se lit comme une
    // image ; ses cartes qui arrivent l'une après l'autre se lisent comme une
    // liste. Le rang est posé ici et la feuille de style en fait un retard.
    for grille in outils::tous::<HtmlElement>(document, GRILLES) {
        let enfants = grille.children();
        for rang in 0..enfants.length() {
            let Some(cellule) = enfants
                .item(rang)
                .and_then(|e| wasm_bindgen::JsCast::dyn_into::<HtmlElement>(e).ok())
            else {
                continue;
            };
            let _ = cellule.set_attribute("data-reveal", "");
            let pas = (rang as i32).min(RANG_MAX);
            outils::poser(&cellule, "--step", &outils::entier(pas));
            observateur.observe(&cellule);
        }
    }
}

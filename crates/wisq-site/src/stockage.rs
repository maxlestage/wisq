//! Le stockage local, en un seul endroit.
//!
//! **Pourquoi ce fichier existe.** Trois comportements du site mémorisent
//! quelque chose : le thème choisi, la langue choisie, et le fait d'avoir
//! renvoyé l'invite d'installation. Chacun a besoin exactement des trois mêmes
//! gestes — lire, écrire, effacer — et chacun a besoin de la même chaîne de
//! refus : pas de fenêtre, pas de stockage, un navigateur qui le refuse. Écrite
//! trois fois, cette chaîne est trois endroits où se tromper ; le premier à être
//! porté la portait déjà en double.
//!
//! **Rien ici n'est porteur, et c'est la règle du site.** Un navigateur en
//! navigation privée, un stockage refusé par une politique, un quota atteint :
//! chacun doit obtenir le site tel qu'il est, entier et lisible. Donc tout rend
//! `None` ou ne fait rien, jamais une erreur qui remonte. Ce qui se perd est la
//! *survie* du choix à la page suivante, jamais la page.
//!
//! **Sous `ssr`, ces fonctions n'existent pas.** Le pré-rendu n'a ni fenêtre ni
//! stockage, et un bouchon qui rendrait `None` en silence serait un bouchon
//! complaisant : il laisserait croire qu'un lecteur sans choix mémorisé a été
//! consulté, alors que personne ne l'a été. Les bouchons du bas refusent donc
//! par construction, et les trois appelants partent de `None` au pré-rendu —
//! ce qui est aussi ce que l'hydratation exige, le premier rendu du client
//! devant coïncider avec celui du serveur.

/// La clé du thème. La même que celle du script bloquant de la tête, qui
/// applique les couleurs avant la première peinture.
pub const THEME: &str = "wisq.theme";

/// La clé de la langue choisie. Elle ne nourrit qu'une décision — la
/// redirection depuis l'accueil anglais — et elle est écrite ici pour que les
/// deux lecteurs de ce fait n'en aient qu'une seule orthographe.
pub const LANGUE: &str = "wisq.lang";

#[cfg(feature = "hydrate")]
fn stockage() -> Option<web_sys::Storage> {
    // `local_storage()` rend `Err` quand la politique du navigateur l'interdit
    // et `Ok(None)` dans un contexte qui n'en a pas : les deux sont la même
    // réponse pour nous, et aucun des deux n'est une panne.
    web_sys::window()?.local_storage().ok()?
}

#[cfg(feature = "hydrate")]
pub fn lire(cle: &str) -> Option<String> {
    stockage()?.get_item(cle).ok()?
}

#[cfg(feature = "hydrate")]
pub fn ecrire(cle: &str, valeur: &str) {
    if let Some(s) = stockage() {
        // Un quota atteint lève : le choix tient pour cette page et ne lui
        // survit simplement pas.
        let _ = s.set_item(cle, valeur);
    }
}

#[cfg(feature = "hydrate")]
pub fn effacer(cle: &str) {
    if let Some(s) = stockage() {
        let _ = s.remove_item(cle);
    }
}

// Les bouchons du pré-rendu. Ils ne rendent pas « rien de mémorisé » : ils
// disent qu'**il n'y a pas de lecteur à consulter**, ce qui est la vérité d'un
// rendu de serveur, et c'est ce que l'hydratation exige du premier rendu.

#[cfg(not(feature = "hydrate"))]
pub fn lire(_: &str) -> Option<String> {
    None
}

#[cfg(not(feature = "hydrate"))]
pub fn ecrire(_: &str, _: &str) {}

#[cfg(not(feature = "hydrate"))]
pub fn effacer(_: &str) {}

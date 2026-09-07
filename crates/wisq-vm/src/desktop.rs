//! **La page que le bureau local charge dans sa vue.**
//!
//! `web/host.js` est la boucle hôte : elle tient la RAM de l'invité, les
//! globales, la table des blocs et la correspondance, demande une traduction
//! quand elle tombe sur une adresse inconnue, et enchaîne. Ce module l'habille
//! de ce qu'il faut pour vivre dans un `WKWebView` : une page, un pont vers
//! l'application, et l'état de départ de la machine.
//!
//! **Pourquoi l'assemblage est en Rust plutôt qu'en Swift.** Ce sont des
//! chaînes de caractères, donc ça se teste — et ça ne se teste que là où il y a
//! un moteur JavaScript. Écrit en Swift, ce code ne serait exécuté par rien
//! avant un envoi TestFlight ; écrit ici, la page se construit, son script
//! s'exécute sous Bun avec un pont bouchonné, et on sait qu'elle tient avant
//! de la donner à un téléphone. Le côté Swift n'a plus qu'à l'appeler.

/// **La boucle hôte, telle qu'elle est écrite dans `web/host.js`.**
///
/// Elle est *incluse à la compilation*, pas recopiée : deux copies finiraient
/// par diverger, et celle qui ment serait celle que personne ne lit.
pub const HOST_SCRIPT: &str = include_str!("../../../web/host.js");

/// Ce que le bureau refuse de construire, et pourquoi.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refusal {
    /// La RAM d'un invité confiné se replie par un masque, qui ne décrit un
    /// intervalle que sur une puissance de deux.
    RamIsNotAPowerOfTwo(u32),
    /// Le nom du canal est **recollé dans du JavaScript**. Tout ce qui n'est
    /// pas une lettre ou un chiffre pourrait en sortir et devenir du code —
    /// c'est la même faute que l'identifiant de VM recollé dans une ligne de
    /// commande, que ce dépôt a déjà payée une fois.
    ChannelIsNotAName(String),
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, out: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::RamIsNotAPowerOfTwo(pages) => write!(
                out,
                "la RAM d'un invité confiné doit être une puissance de deux de pages, pas {pages}"
            ),
            Self::ChannelIsNotAName(name) => write!(
                out,
                "le nom du canal ne peut porter que des lettres et des chiffres : « {name} »"
            ),
        }
    }
}

impl std::error::Error for Refusal {}

/// **La page complète, prête à être chargée dans un `WKWebView`.**
///
/// - `pages` : la RAM de l'invité, en pages de 64 Kio, **puissance de deux**.
/// - `entry` : l'adresse où la machine commence.
/// - `channel` : le nom du gestionnaire de messages que l'application déclare.
///
/// **Le pont est asynchrone, et c'est imposé, pas choisi.** Une vue ne peut pas
/// appeler l'application et attendre : elle poste un message et reçoit la
/// réponse plus tard, par un appel de l'application vers la vue. La boucle
/// hôte est écrite pour ça depuis le début — `translate` rend une promesse.
///
/// **Ce que l'application doit fournir**, et rien d'autre :
/// - un gestionnaire de messages nommé `channel`, qui reçoit
///   `{ id, address, slot }` pour une traduction et `{ stopped, at }` quand la
///   machine s'arrête ;
/// - un appel à `wisqTranslated(id, octets)` pour répondre, `octets` étant un
///   tableau de nombres ou `null` si l'émetteur refuse ;
/// - un appel à `wisqRun()` pour lancer la machine.
pub fn page(pages: u32, entry: u64, channel: &str) -> Result<String, Refusal> {
    if pages == 0 || !pages.is_power_of_two() {
        return Err(Refusal::RamIsNotAPowerOfTwo(pages));
    }
    if channel.is_empty() || !channel.chars().all(|glyph| glyph.is_ascii_alphanumeric()) {
        return Err(Refusal::ChannelIsNotAName(channel.to_string()));
    }
    Ok(format!(
        "<!doctype html>\n\
         <meta charset=\"utf-8\">\n\
         <title>wisq</title>\n\
         <script type=\"module\">\n\
         {HOST_SCRIPT}\n\
         {}\n\
         </script>\n",
        driver(pages, entry, channel)
    ))
}

/// **Le pilote : ce qui relie la boucle hôte au pont de l'application.**
///
/// Séparé de la page pour qu'un test puisse l'exécuter sans HTML autour — un
/// moteur JavaScript en ligne de commande n'a pas de `WKWebView`, mais il sait
/// très bien bouchonner `window.webkit.messageHandlers`.
pub fn driver(pages: u32, entry: u64, channel: &str) -> String {
    format!(
        r#"
// **Le pont vers l'application.** Une vue ne peut pas appeler l'hôte et
// attendre : elle poste, et l'hôte rappelle. Chaque demande porte donc un
// numéro, et sa promesse attend dans `waiting` jusqu'à ce qu'il revienne.
const bridge = window.webkit.messageHandlers.{channel};
let ticket = 0;
const waiting = new Map();

// Appelé par l'application quand la traduction est prête. `octets` est un
// tableau de nombres, ou `null` si l'émetteur a refusé la région.
window.wisqTranslated = (id, octets) => {{
  const settle = waiting.get(id);
  if (settle === undefined) return;
  waiting.delete(id);
  settle(octets === null ? null : Uint8Array.from(octets));
}};

const translate = (address, slot) => new Promise(settle => {{
  const id = ++ticket;
  waiting.set(id, settle);
  // L'adresse part en **texte** : un entier de soixante-quatre bits ne
  // traverse pas JSON sans perdre ses bits de poids fort.
  bridge.postMessage({{ kind: "traduire", id, address: address.toString(), slot }});
}});

const vm = machine({{ translate, pages: {pages} }});
vm.globals[SLOTS.rip].value = {entry}n;
window.wisqMachine = vm;

window.wisqRun = async () => {{
  const why = await vm.run();
  bridge.postMessage({{ kind: "arrêt", stopped: why.stopped, at: why.at.toString() }});
  return why.stopped;
}};
"#
    )
}

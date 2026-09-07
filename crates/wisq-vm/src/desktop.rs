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

/// **Le cadre que le chargeur a déclaré au noyau**, tel que la vue doit le
/// peindre.
///
/// Les trois nombres viennent du `screen_info` que l'application remplit avant
/// de démarrer la machine : c'est elle qui décide où vit le tampon
/// d'affichage, donc c'est elle qui le dit à la page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Screen {
    /// L'adresse **invitée** du tampon d'affichage. Elle est repliée dans la
    /// RAM comme toutes les autres.
    pub base: u64,
    pub width: u32,
    pub height: u32,
}

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
    /// **Le cadre déborderait de la RAM de l'invité.** Au-dessus vit la
    /// correspondance adresse → indice : un cadre à cheval sur ce bord
    /// afficherait la table des blocs à l'écran, et l'invité la détruirait en
    /// peignant. C'est la même frontière que la lecture de la fenêtre et
    /// l'écriture de l'image gardent déjà, refusée ici **avant** que la page
    /// n'existe.
    ScreenDoesNotFit { folded: u64, bytes: u64, ram: u64 },
    /// Un cadre sans surface n'est pas un cadre.
    ScreenHasNoSurface { width: u32, height: u32 },
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
            Self::ScreenDoesNotFit { folded, bytes, ram } => write!(
                out,
                "le cadre occupe {bytes} octets à {folded} et déborde d'une RAM de {ram}"
            ),
            Self::ScreenHasNoSurface { width, height } => {
                write!(out, "un cadre de {width}×{height} n'a pas de surface")
            }
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
///   `{ id, address, slot, octets }` pour une traduction et `{ stopped, at }`
///   quand la machine s'arrête ;
/// - un appel à `wisqTranslated(id, octets)` pour répondre, `octets` étant un
///   tableau de nombres ou `null` si l'émetteur refuse franchement ;
/// - un appel à `wisqNeedsMore(id)` quand l'émetteur a manqué d'octets — la vue
///   redemande alors **une** fois avec une fenêtre plus large ;
/// - un appel à `wisqRun()` pour lancer la machine.
///
/// **La demande porte les octets, et c'est le point qui a manqué le plus
/// longtemps.** La RAM de l'invité vit dans la vue ; l'application ne l'a pas.
/// Une demande qui ne porterait que l'adresse obligerait l'application à
/// chercher le code dans l'image qu'elle a chargée — juste pour le noyau,
/// **faux en silence** pour un module que l'invité charge lui-même.
///
/// **Ils traversent en base64, et le sens inverse pas.** Ce n'est pas une
/// incohérence : vers la vue, ce qui coûte est l'analyse d'une source
/// JavaScript, où un littéral de tableau gagne (mesuré,
/// `scripts/wasm-crossing-probe.ts`). Depuis la vue, ce qui coûte est la
/// sérialisation de `postMessage` — une seule chaîne contre quatre mille
/// nombres à emballer. **Ce second compromis n'est pas mesuré** : il demande un
/// vrai `WKWebView`, et rien ici n'en a.
pub fn page(
    pages: u32,
    entry: u64,
    channel: &str,
    screen: Option<Screen>,
) -> Result<String, Refusal> {
    if pages == 0 || !pages.is_power_of_two() {
        return Err(Refusal::RamIsNotAPowerOfTwo(pages));
    }
    if channel.is_empty() || !channel.chars().all(|glyph| glyph.is_ascii_alphanumeric()) {
        return Err(Refusal::ChannelIsNotAName(channel.to_string()));
    }
    // **Le cadre est jugé ici, avant que la page n'existe.** `host.js` le juge
    // une seconde fois à la construction de la machine, et ce n'est pas une
    // redondance inutile : celle-ci refuse en Rust, avec un nom, quand l'autre
    // ne peut que lever dans une vue que personne ne regarde.
    let frame = match screen {
        None => String::new(),
        Some(screen) => {
            if screen.width == 0 || screen.height == 0 {
                return Err(Refusal::ScreenHasNoSurface {
                    width: screen.width,
                    height: screen.height,
                });
            }
            let ram = u64::from(pages) * 65536;
            let folded = screen.base & (ram - 1);
            // **La surface peut déborder de soixante-quatre bits**, et c'est un
            // débordement qui *accepterait* au lieu de refuser : deux
            // dimensions de deux puissance trente et un donnent exactement deux
            // puissance soixante-quatre, qui enroule à **zéro** en release. Un
            // cadre impossible passerait alors la garde. `saturating_mul` rend
            // un nombre au moins aussi grand que le vrai, ce qui suffit pour
            // refuser — et un cadre de cette taille n'a pas de vrai nombre à
            // annoncer.
            let bytes = u64::from(screen.width)
                .saturating_mul(u64::from(screen.height))
                .saturating_mul(4);
            if folded.saturating_add(bytes) > ram {
                return Err(Refusal::ScreenDoesNotFit { folded, bytes, ram });
            }
            // **Le canvas est dans le corps de la page, pas fabriqué par le
            // script.** Ses dimensions sont alors lisibles dans la page
            // elle-même, et elles sont celles que ce refus vient de valider —
            // un canvas construit à la volée les tiendrait d'une variable, et
            // plus rien ne dirait laquelle.
            format!(
                "<canvas id=\"wisqEcran\" width=\"{}\" height=\"{}\"></canvas>\n",
                screen.width, screen.height
            )
        }
    };
    Ok(format!(
        "<!doctype html>\n\
         <meta charset=\"utf-8\">\n\
         <title>wisq</title>\n\
         {frame}\
         <script type=\"module\">\n\
         {HOST_SCRIPT}\n\
         {}\n\
         </script>\n",
        driver(pages, entry, channel, screen)
    ))
}

/// **Ce que la page fait de l'écran de l'invité.**
///
/// **Peindre est séparé de la boucle qui peint, et ce n'est pas du confort.**
/// `requestAnimationFrame` ne tourne que dans une vue que le système considère
/// comme affichée. Un `WKWebView` construit sans être ajouté à une fenêtre —
/// exactement ce que fait `LocalDesktopTests` — pourrait n'en voir aucune, et
/// un test qui attendrait une image n'aurait alors rien à attendre. `wisqPaint`
/// se laisse donc appeler à la main, et la boucle ne fait que l'appeler.
///
/// **Rien ne traverse vers l'application.** Le cadre vit dans la mémoire de la
/// vue, le canvas aussi : la conversion se fait sur place. C'est la seule
/// raison pour laquelle un affichage est possible — trois mégaoctets par image
/// ne passeraient jamais un pont de messages.
fn painter(screen: Screen) -> String {
    format!(
        r#"
// **L'écran.** Le canvas est dans le corps de la page, à ses dimensions ; le
// contexte peut être refusé, et un refus muet donnerait un écran noir qu'on
// mettrait sur le compte de la machine.
const écran = document.getElementById("wisqEcran");
if (écran === null) {{
  throw new Error("la page déclare un cadre mais pas de canvas");
}}
const pinceau = écran.getContext("2d");
if (pinceau === null) {{
  throw new Error("la vue n'accorde pas de contexte 2d");
}}
// **Une seule ImageData, réutilisée.** En construire une par image
// allouerait {octets} octets soixante fois par seconde ; et `putImageData`
// n'accepte de toute façon que celle que le contexte a rendue.
const image = pinceau.createImageData({width}, {height});

// Peindre une image, tout de suite, quel que soit l'état de la machine.
//
// **Elle rend le nombre de pixels**, et ce n'est pas décoratif : une fonction
// qui ne rend rien ne se distingue pas d'une fonction qui n'a rien fait. C'est
// le seul moyen, depuis l'application, de savoir qu'une image est passée.
window.wisqPaint = () => {{
  const pixels = vm.paint(image.data);
  pinceau.putImageData(image, 0, 0);
  return pixels;
}};

let enMarche = false;
const boucle = () => {{
  if (!enMarche) return;
  window.wisqPaint();
  requestAnimationFrame(boucle);
}};

window.wisqAfficher = () => {{
  if (enMarche) return;
  enMarche = true;
  requestAnimationFrame(boucle);
}};

window.wisqCesser = () => {{
  enMarche = false;
  window.wisqPaint();
}};
"#,
        width = screen.width,
        height = screen.height,
        octets = u64::from(screen.width) * u64::from(screen.height) * 4,
    )
}

/// **Le pilote : ce qui relie la boucle hôte au pont de l'application.**
///
/// Séparé de la page pour qu'un test puisse l'exécuter sans HTML autour — un
/// moteur JavaScript en ligne de commande n'a pas de `WKWebView`, mais il sait
/// très bien bouchonner `window.webkit.messageHandlers`.
pub fn driver(pages: u32, entry: u64, channel: &str, screen: Option<Screen>) -> String {
    // **Ce que la page fait de l'écran, et rien si elle n'en a pas.** Une
    // machine sans cadre est un cas réel — un démarrage jugé sur ses registres
    // n'a pas besoin d'être regardé — et un canvas qu'on peindrait pour rien
    // coûterait une image par rafraîchissement.
    let (declared, painting) = match screen {
        // **Deux fonctions vides, et elles disent quelque chose.** Sans cadre
        // il n'y a rien à montrer, et `wisqRun` a un seul chemin plutôt qu'un
        // test sur l'existence d'une globale. `wisqPaint`, lui, n'est pas
        // déclaré : l'appeler doit lever, pas ne rien faire.
        None => (
            String::new(),
            r#"
// Aucun cadre déclaré : il n'y a rien à peindre.
window.wisqAfficher = () => {};
window.wisqCesser = () => {};
"#
            .to_string(),
        ),
        Some(screen) => (
            format!(
                ", screen: {{ base: {}n, width: {}, height: {} }}",
                screen.base, screen.width, screen.height
            ),
            painter(screen),
        ),
    };
    format!(
        r#"
// **Le pont vers l'application.** Une vue ne peut pas appeler l'hôte et
// attendre : elle poste, et l'hôte rappelle. Chaque demande porte donc un
// numéro, et sa promesse attend dans `waiting` jusqu'à ce qu'il revienne.
const bridge = window.webkit.messageHandlers.{channel};
let ticket = 0;
const waiting = new Map();

// Appelé par l'application quand la traduction est prête. `octets` est un
// tableau de nombres, ou `null` si l'émetteur a refusé franchement la région.
window.wisqTranslated = (id, octets) => {{
  const settle = waiting.get(id);
  if (settle === undefined) return;
  waiting.delete(id);
  settle(octets === null ? null : Uint8Array.from(octets));
}};

// Appelé quand l'émetteur a manqué d'octets plutôt que refusé : la vue
// redemande alors une fois, avec une fenêtre plus large.
window.wisqNeedsMore = id => {{
  const settle = waiting.get(id);
  if (settle === undefined) return;
  waiting.delete(id);
  settle("encore");
}};

const translate = (address, slot, code) => new Promise(settle => {{
  const id = ++ticket;
  waiting.set(id, settle);
  // **Les octets partent en base64.** Une seule chaîne à sérialiser plutôt que
  // quatre mille nombres à emballer un par un — le compromis inverse de celui
  // du retour, où c'est l'analyse d'une source JavaScript qui coûte. Concaténé
  // par tranches : passer seize kibioctets à `String.fromCharCode` en une fois
  // dépasse la pile d'arguments.
  let binaire = "";
  for (let at = 0; at < code.length; at += 4096) {{
    binaire += String.fromCharCode.apply(null, code.subarray(at, at + 4096));
  }}
  // L'adresse part en **texte** : un entier de soixante-quatre bits ne
  // traverse pas JSON sans perdre ses bits de poids fort.
  bridge.postMessage({{
    kind: "traduire",
    id,
    address: address.toString(),
    slot,
    octets: btoa(binaire),
  }});
}});

const vm = machine({{ translate, pages: {pages}{declared} }});
vm.globals[SLOTS.rip].value = {entry}n;
window.wisqMachine = vm;
{painting}
window.wisqRun = async () => {{
  window.wisqAfficher();
  const why = await vm.run();
  // **Cesser peint une dernière fois.** Sans ça, la dernière image montrée
  // serait celle d'avant l'arrêt : on regarderait un écran qui n'est pas
  // l'état dans lequel la machine s'est arrêtée.
  window.wisqCesser();
  bridge.postMessage({{ kind: "arrêt", stopped: why.stopped, at: why.at.toString() }});
  return why.stopped;
}};
"#
    )
}

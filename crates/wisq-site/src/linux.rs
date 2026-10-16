//! La page `linux/` : la machine rv32ima de wisq, dans le navigateur.
//!
//! **La même machine que sur l'iPhone.** `crates/wisq-vm` est le cœur que
//! l'application embarque comme bibliothèque statique ; ici il est compilé en
//! WebAssembly avec le reste du front (drapeau `linux`), et un îlot Active le
//! conduit : il lit l'image que le lecteur choisit, la charge, fait tourner la
//! machine par tranches entre deux images d'écran, et montre la console.
//!
//! **Rien ne quitte l'onglet.** L'image est lue par `File.arrayBuffer()` et
//! copiée dans la RAM de l'invité ; aucune requête n'est faite avec elle. Le
//! site n'en distribue aucune : la page dit où en trouver une, et c'est le
//! lecteur qui la donne — comme l'application, qui « lit le fichier qu'on lui
//! tend ».
//!
//! **Un module à part.** L'interpréteur ne part que chez qui ouvre cette page :
//! la construction compile le crate une seconde fois avec `linux`, et seule
//! cette route charge ce module-là. Les autres pages gardent le module commun,
//! et son budget.

use active::prelude::*;
use active::Node;

use crate::content::Lang;
use crate::doc::mots;

/// Le nom de l'îlot du terminal, tel qu'il est écrit dans la page et enregistré
/// par le module.
pub const ILOT: &str = "terminal";

/// La page entière : le titre, ce qu'est la machine, comment la démarrer, et le
/// terminal.
pub fn page(lang: Lang) -> Node {
    let copy = lang.linux();
    article()
        .class("doc linux")
        .child(
            div()
                .class("wrap")
                .child(
                    header()
                        .class("doc-head")
                        .child(h1().child(mots(copy.title)))
                        .child(p().class("lede").text(copy.lede)),
                )
                .children(copy.intro.iter().map(|t| p().text(*t)))
                .child(h2().id("boot").text(copy.steps_title))
                .child(
                    ol().class("doc-list doc-steps")
                        .children(copy.steps.iter().map(|t| li().text(*t))),
                )
                .child(
                    div()
                        .attr("data-ilot", ILOT)
                        .child(island(ILOT, lang.code(), terminal)),
                )
                .child(
                    aside()
                        .class("doc-note doc-note-info")
                        .child(p().text(copy.privacy)),
                )
                .child(p().class("linux-credit").text(copy.credit)),
        )
        .into()
}

/// Où en est la machine, pour l'interface.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Marche {
    Arret,
    Lecture,
    EnMarche,
}

/// Le terminal : le choix de l'image, les deux boutons, l'état, la console et
/// la ligne de saisie.
///
/// **La saisie a deux chemins**, et le second est pour le téléphone. Sur un
/// ordinateur, la console prend le focus et chaque touche part vers l'UART
/// telle quelle — flèches et Ctrl-C compris. Un clavier d'iPhone ne s'ouvre
/// pas sur un `<pre>` : la ligne de saisie, en dessous, envoie une ligne
/// entière, suivie d'un retour.
pub fn terminal(props: &str) -> Node {
    let lang = Lang::parse(props).unwrap_or(Lang::En);
    let copy = lang.linux();
    let marche = use_state(Marche::Arret);
    let statut = use_state(String::from(copy.idle));
    let ecran = use_state(String::new());
    let ligne = use_state(String::new());
    let vue = Vue {
        marche,
        statut,
        ecran,
    };

    div()
        .class("linux-terminal")
        .child(
            div()
                .class("linux-controls")
                .child(
                    label()
                        .attr("for", "linux-image")
                        .class("linux-label")
                        .text(copy.image_label),
                )
                .child(
                    input()
                        .attr("type", "file")
                        .id("linux-image")
                        .attr("aria-describedby", "linux-hint"),
                )
                .child(
                    button()
                        .attr("type", "button")
                        .class("btn btn-primary")
                        .attr("data-linux-boot", "")
                        .bool_attr("disabled", move || marche.get() == Marche::Lecture)
                        .on_click(move |_| machine::demarrer(lang, vue))
                        .text(copy.boot),
                )
                .child(
                    button()
                        .attr("type", "button")
                        .class("btn btn-quiet")
                        .attr("data-linux-stop", "")
                        .bool_attr("hidden", move || marche.get() != Marche::EnMarche)
                        .on_click(move |_| machine::arreter(lang, vue))
                        .text(copy.stop),
                ),
        )
        .child(
            p().id("linux-hint")
                .class("linux-hint")
                .text(copy.image_hint),
        )
        .child(
            p().class("linux-status")
                .attr("role", "status")
                .attr("aria-live", "polite")
                .text_dyn(move || statut.get()),
        )
        .child(
            pre()
                .class("linux-console")
                .attr("tabindex", "0")
                .attr("aria-label", copy.terminal_label)
                .attr("data-linux-console", "")
                .on("keydown", move |e| {
                    if let Some(octets) = crate::console::touche(&e.key(), ctrl(&e)) {
                        e.prevent_default();
                        machine::envoyer(&octets);
                    }
                })
                .text_dyn(move || ecran.get()),
        )
        .child(
            form()
                .class("linux-input")
                .on_submit(move |_| {
                    let mut octets = ligne.get().into_bytes();
                    octets.push(b'\r');
                    machine::envoyer(&octets);
                    ligne.set(String::new());
                })
                .child(
                    label()
                        .attr("for", "linux-line")
                        .class("visually-hidden")
                        .text(copy.input_label),
                )
                .child(
                    input()
                        .attr("type", "text")
                        .id("linux-line")
                        .attr("autocomplete", "off")
                        .attr("autocapitalize", "off")
                        .attr("autocorrect", "off")
                        .attr("spellcheck", "false")
                        .attr("enterkeyhint", "send")
                        .attr("placeholder", copy.input_placeholder)
                        .bind_value(ligne),
                )
                .child(
                    button()
                        .attr("type", "submit")
                        .class("btn btn-secondary")
                        .text(copy.send),
                )
                .child(
                    button()
                        .attr("type", "button")
                        .class("btn btn-quiet")
                        .attr("data-linux-ctrl-c", "")
                        .on_click(|_| machine::envoyer(&[3]))
                        .text(copy.ctrl_c),
                ),
        )
        .into()
}

/// Les trois états que la machine met à jour : ce que l'interface montre.
#[derive(Clone, Copy)]
pub struct Vue {
    pub marche: State<Marche>,
    pub statut: State<String>,
    pub ecran: State<String>,
}

#[cfg(feature = "hydrate")]
fn ctrl(e: &active::Event) -> bool {
    use wasm_bindgen::JsCast;
    e.raw()
        .dyn_ref::<web_sys::KeyboardEvent>()
        .is_some_and(|k| k.ctrl_key())
}

#[cfg(not(feature = "hydrate"))]
fn ctrl(_: &active::Event) -> bool {
    false
}

/// La machine elle-même : seulement dans le module de cette page.
#[cfg(feature = "linux")]
mod machine {
    use std::cell::RefCell;
    use std::sync::{Arc, Mutex};

    use wasm_bindgen::closure::Closure;
    use wasm_bindgen::JsCast;
    use wisq_vm::kernel_image::{recognise, KernelImage};
    use wisq_vm::{LoadError, Machine, Outcome, DEFAULT_RAM_SIZE};

    use super::{Marche, Vue};
    use crate::console::Console;
    use crate::content::Lang;

    /// Le temps qu'une tranche s'accorde avant de rendre la main au
    /// navigateur : assez pour avancer, assez peu pour qu'une image d'écran
    /// sur deux reste libre pour défiler et taper.
    const TRANCHE_MS: f64 = 10.0;

    struct Session {
        machine: Machine,
        sortie: Arc<Mutex<Vec<u8>>>,
        console: Console,
        budget: u64,
        /// Distingue cette session de la suivante : une boucle d'une machine
        /// arrêtée qui se réveille ne doit pas faire tourner la nouvelle.
        generation: u32,
        debut: f64,
    }

    thread_local! {
        static SESSION: RefCell<Option<Session>> = const { RefCell::new(None) };
        static GENERATION: RefCell<u32> = const { RefCell::new(0) };
    }

    fn maintenant() -> f64 {
        web_sys::window()
            .and_then(|w| w.performance())
            .map_or(0.0, |p| p.now())
    }

    pub fn envoyer(octets: &[u8]) {
        SESSION.with(|s| {
            if let Some(session) = s.borrow().as_ref() {
                session.machine.handle().send(octets);
            }
        });
    }

    pub fn arreter(lang: Lang, vue: Vue) {
        GENERATION.with(|g| *g.borrow_mut() += 1);
        SESSION.with(|s| s.borrow_mut().take());
        vue.marche.set(Marche::Arret);
        vue.statut.set(lang.linux().stopped.to_string());
    }

    /// Lit le fichier choisi, puis démarre.
    pub fn demarrer(lang: Lang, vue: Vue) {
        let copy = lang.linux();
        let fichier = web_sys::window()
            .and_then(|w| w.document())
            .and_then(|d| d.get_element_by_id("linux-image"))
            .and_then(|e| e.dyn_into::<web_sys::HtmlInputElement>().ok())
            .and_then(|i| i.files())
            .and_then(|f| f.get(0));
        let Some(fichier) = fichier else {
            vue.statut.set(copy.idle.to_string());
            return;
        };
        arreter(lang, vue);
        vue.marche.set(Marche::Lecture);
        vue.statut.set(copy.reading.to_string());

        let lu = Closure::once(move |tampon: wasm_bindgen::JsValue| {
            let octets = js_sys::Uint8Array::new(&tampon).to_vec();
            lancer(lang, vue, &octets);
        });
        let refus = Closure::once(move |_: wasm_bindgen::JsValue| {
            vue.marche.set(Marche::Arret);
            vue.statut.set(copy.unreadable.to_string());
        });
        let _ = fichier.array_buffer().then2(&lu, &refus);
        lu.forget();
        refus.forget();
    }

    fn lancer(lang: Lang, vue: Vue, image: &[u8]) {
        let copy = lang.linux();
        // Un bzImage x86 ou un ELF est reconnu, et dit, plutôt que chargé à
        // l'adresse d'un noyau RISC-V où il ne ferait rien d'intelligible.
        if !matches!(recognise(image), KernelImage::Unknown) {
            vue.marche.set(Marche::Arret);
            vue.statut.set(copy.not_riscv.to_string());
            return;
        }
        let sortie = Arc::new(Mutex::new(Vec::new()));
        let puits = Arc::clone(&sortie);
        let mut machine = Machine::new(
            DEFAULT_RAM_SIZE,
            Box::new(move |octets: &[u8]| {
                if let Ok(mut tampon) = puits.lock() {
                    tampon.extend_from_slice(octets);
                }
            }),
        );
        if let Err(erreur) = machine.load(image, None) {
            vue.marche.set(Marche::Arret);
            vue.statut.set(
                match erreur {
                    LoadError::ImageTooLarge => copy.too_large,
                    _ => copy.unreadable,
                }
                .to_string(),
            );
            return;
        }
        let generation = GENERATION.with(|g| *g.borrow());
        SESSION.with(|s| {
            *s.borrow_mut() = Some(Session {
                machine,
                sortie,
                console: Console::new(),
                budget: 1_000_000,
                generation,
                debut: maintenant(),
            })
        });
        vue.ecran.set(String::new());
        vue.marche.set(Marche::EnMarche);
        boucle(lang, vue, generation);
    }

    /// La console suit la dernière ligne, comme un terminal — sauf si le
    /// lecteur est remonté lire plus haut : on ne lui arrache pas la page.
    fn suivre() {
        let Some(console) = web_sys::window()
            .and_then(|w| w.document())
            .and_then(|d| d.query_selector("[data-linux-console]").ok().flatten())
        else {
            return;
        };
        // La hauteur d'avant la dernière écriture n'est plus connue ; une
        // marge d'un écran de console dit « il était en bas ».
        let bas = console.scroll_height() - console.client_height();
        if bas - console.scroll_top() <= console.client_height() * 2 {
            console.set_scroll_top(bas);
        }
    }

    /// Une tranche, puis la suivante à la prochaine image d'écran.
    fn boucle(lang: Lang, vue: Vue, generation: u32) {
        let copy = lang.linux();
        let fin = SESSION.with(|s| {
            let mut s = s.borrow_mut();
            let session = s.as_mut().filter(|s| s.generation == generation)?;
            let avant = maintenant();
            let issue = session.machine.run(session.budget);
            let duree = maintenant() - avant;
            // Le budget suit la vitesse de l'appareil : il vise une tranche de
            // `TRANCHE_MS`, sans jamais tomber à rien ni s'emballer.
            if duree > 0.0 {
                let vise = session.budget as f64 * TRANCHE_MS / duree;
                session.budget = vise.clamp(100_000.0, 50_000_000.0) as u64;
            }
            let octets = std::mem::take(&mut *session.sortie.lock().ok()?);
            if !octets.is_empty() {
                session.console.ecrire(&octets);
                vue.ecran.set(session.console.texte());
                suivre();
            }
            let retirees = session.machine.retired_instructions();
            let ecoule = (maintenant() - session.debut).max(1.0);
            vue.statut.set(format!(
                "{} — {:.1} M instructions, {:.0} MIPS",
                copy.running,
                retirees as f64 / 1e6,
                retirees as f64 / ecoule / 1e3,
            ));
            Some(issue)
        });
        match fin {
            // Une autre session a pris la place, ou celle-ci a été arrêtée.
            None => {}
            Some(Outcome::PowerOff | Outcome::Reboot) => {
                SESSION.with(|s| s.borrow_mut().take());
                vue.marche.set(Marche::Arret);
                vue.statut.set(copy.power_off.to_string());
            }
            Some(Outcome::Stopped) => {
                let suite = Closure::once_into_js(move || boucle(lang, vue, generation));
                if let Some(fenetre) = web_sys::window() {
                    let _ = fenetre.request_animation_frame(suite.unchecked_ref());
                }
            }
        }
    }
}

/// Sans la machine — le module commun et le pré-rendu — les boutons ne font
/// rien : cette page charge toujours le module qui l'a.
#[cfg(not(feature = "linux"))]
mod machine {
    use super::Vue;
    use crate::content::Lang;

    pub fn envoyer(_: &[u8]) {}
    pub fn arreter(_: Lang, _: Vue) {}
    pub fn demarrer(_: Lang, _: Vue) {}
}

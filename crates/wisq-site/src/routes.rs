//! Toutes les pages que le site expédie, et le seul endroit qui les connaisse.
//!
//! Chaque route devient un vrai dossier avec son HTML pré-rendu, plutôt qu'un
//! fragment de routeur côté client. Trois choses en découlent et les trois
//! comptent : la page arrive lisible dans la première réponse, un moteur de
//! recherche voit une vraie URL, et le service worker peut mettre en cache un
//! document par adresse au lieu d'une coquille qui doit démarrer avant de
//! savoir ce qu'elle affiche.

use crate::content::{Copy, Lang};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum RouteId {
    Home,
    Docs,
    Protocol,
    Architecture,
    Faq,
    Roadmap,
    Releases,
    Privacy,
    Offline,
    NotFound,
}

pub struct Route {
    pub id: RouteId,
    /// Dossier sous la racine du site. Vide pour les pages qui vivent à la
    /// racine.
    pub path: &'static str,
    /// Si la page a sa place dans la navigation d'en-tête et dans le sitemap.
    pub listed: bool,
    /// Où va le fichier, quand ce n'est pas `<path>/index.html`. Un `404.html` à
    /// la racine est ce qu'un hôte statique va chercher sur une adresse
    /// inconnue.
    pub output: Option<&'static str>,
}

pub static ROUTES: &[Route] = &[
    Route {
        id: RouteId::Home,
        path: "",
        listed: true,
        output: None,
    },
    Route {
        id: RouteId::Docs,
        path: "docs",
        listed: true,
        output: None,
    },
    Route {
        id: RouteId::Protocol,
        path: "protocol",
        listed: true,
        output: None,
    },
    Route {
        id: RouteId::Architecture,
        path: "architecture",
        listed: true,
        output: None,
    },
    Route {
        id: RouteId::Faq,
        path: "faq",
        listed: true,
        output: None,
    },
    Route {
        id: RouteId::Roadmap,
        path: "roadmap",
        listed: true,
        output: None,
    },
    Route {
        id: RouteId::Releases,
        path: "releases",
        listed: true,
        output: None,
    },
    // Atteignable depuis le pied plutôt que l'en-tête : un lecteur la cherche là
    // où sont les lignes légales, et la navigation du haut est déjà pleine.
    Route {
        id: RouteId::Privacy,
        path: "privacy",
        listed: false,
        output: None,
    },
    // Montrée seulement quand le réseau a disparu et que l'adresse n'a jamais
    // été mise en cache, donc elle n'a sa place ni en navigation ni dans un
    // sitemap.
    Route {
        id: RouteId::Offline,
        path: "offline",
        listed: false,
        output: None,
    },
    Route {
        id: RouteId::NotFound,
        path: "",
        listed: false,
        output: Some("404.html"),
    },
];

impl RouteId {
    pub fn slug(self) -> &'static str {
        match self {
            RouteId::Home => "home",
            RouteId::Docs => "docs",
            RouteId::Protocol => "protocol",
            RouteId::Architecture => "architecture",
            RouteId::Faq => "faq",
            RouteId::Roadmap => "roadmap",
            RouteId::Releases => "releases",
            RouteId::Privacy => "privacy",
            RouteId::Offline => "offline",
            // Le nom que portait la clé de `content.ts`, gardé : c'est celui
            // que le catalogue publie et que `data-route` écrit sur la page.
            RouteId::NotFound => "notFound",
        }
    }

    pub fn parse(slug: &str) -> Option<RouteId> {
        ROUTES.iter().map(|r| r.id).find(|id| id.slug() == slug)
    }

    /// Le libellé de navigation, dans la langue demandée.
    pub fn label(self, copy: &'static Copy) -> &'static str {
        match self {
            RouteId::Home => copy.pages.home,
            RouteId::Docs => copy.pages.docs,
            RouteId::Protocol => copy.pages.protocol,
            RouteId::Architecture => copy.pages.architecture,
            RouteId::Faq => copy.pages.faq,
            RouteId::Roadmap => copy.pages.roadmap,
            RouteId::Releases => copy.pages.releases,
            RouteId::Privacy => copy.pages.privacy,
            RouteId::Offline => copy.pages.offline,
            RouteId::NotFound => copy.pages.not_found,
        }
    }
}

pub fn route(id: RouteId) -> &'static Route {
    ROUTES
        .iter()
        .find(|r| r.id == id)
        // Impossible par construction : `RouteId` et `ROUTES` sont dans ce
        // fichier, et un identifiant absent de la table ne compilerait pas plus
        // loin que ce `find`. Le refus nomme quand même le coupable, parce
        // qu'un `unwrap` muet dans une page servie est une page blanche sans
        // explication.
        .unwrap_or_else(|| panic!("route absente de ROUTES : {}", id.slug()))
}

/// L'adresse d'une page, relative à la racine du site : `""`, `"docs/"`,
/// `"fr/"`, `"fr/docs/"`.
///
/// **`output` n'y entre pas, et c'est le garde de fidélité qui l'a dit.** La
/// première version rendait `404.html` pour la page introuvable : le sélecteur
/// de langue d'une 404 menait donc à la 404 de l'autre langue — une page qui
/// dit « cette adresse n'existe pas » à propos d'une adresse qu'on vient de lui
/// demander. React, et la règle d'origine, mènent à l'accueil de l'autre langue.
/// Le fichier qu'une route écrit et l'adresse qu'on donne pour elle sont deux
/// choses, et seule la première dépend de `output`.
pub fn page_path(id: RouteId, lang: Lang) -> String {
    let r = route(id);
    if r.path.is_empty() {
        lang.prefix().to_string()
    } else {
        format!("{}{}/", lang.prefix(), r.path)
    }
}

/// Le chemin du fichier écrit par la construction.
pub fn output_path(id: RouteId, lang: Lang) -> String {
    let r = route(id);
    match r.output {
        Some(file) => format!("{}{file}", lang.prefix()),
        None if r.path.is_empty() => format!("{}index.html", lang.prefix()),
        None => format!("{}{}/index.html", lang.prefix(), r.path),
    }
}

/// De quoi remonter à la racine du site depuis une page donnée. Tout ce que le
/// site écrit est relatif, pour qu'il reste déplaçable.
///
/// Compté sur le fichier écrit plutôt que sur l'adresse, parce que c'est lui
/// que le navigateur résout : `fr/404.html` est à un niveau de profondeur alors
/// que son adresse, `fr/`, l'est aussi — mais `404.html` est à la racine alors
/// que rien dans son adresse ne le dirait si elle changeait.
pub fn relative_base(id: RouteId, lang: Lang) -> String {
    let depth = output_path(id, lang).matches('/').count();
    if depth == 0 {
        "./".to_string()
    } else {
        "../".repeat(depth)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn les_adresses_suivent_la_regle_du_site() {
        assert_eq!(page_path(RouteId::Home, Lang::En), "");
        assert_eq!(page_path(RouteId::Docs, Lang::Fr), "fr/docs/");
        // La 404 a son fichier, pas son adresse.
        assert_eq!(page_path(RouteId::NotFound, Lang::Fr), "fr/");
        assert_eq!(output_path(RouteId::NotFound, Lang::Fr), "fr/404.html");
        assert_eq!(relative_base(RouteId::NotFound, Lang::En), "./");
        assert_eq!(relative_base(RouteId::NotFound, Lang::Fr), "../");
        assert_eq!(relative_base(RouteId::Docs, Lang::Fr), "../../");
    }
}

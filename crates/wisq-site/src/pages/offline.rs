//! Les deux pages de repli : hors ligne, et introuvable.
//!
//! Des données, pas du balisage : `crate::doc` est le seul rendu, et une
//! traduction manquante ne compile pas.

use crate::doc::{Block, Doc, Tone};

pub static OFFLINE_EN: Doc = Doc {
    title: "Offline",
    lede: "This page was never visited while you had a connection, so there was nothing cached to show.",
    blocks: &[
        Block::P("Every page you have opened before is still available — the site keeps them on the device once they have been read. Navigate back to one, or return when you have a network."),
        Block::Note { tone: Tone::Info, text: "This is the site being offline, not wisq. The local Linux machine in the app needs no network at all." },
    ],
};

pub static OFFLINE_FR: Doc = Doc {
    title: "Hors ligne",
    lede: "Cette page n'a jamais été visitée pendant que vous aviez une connexion : il n'y avait rien en cache à afficher.",
    blocks: &[
        Block::P("Toutes les pages déjà ouvertes restent disponibles — le site les garde sur l'appareil une fois lues. Revenez à l'une d'elles, ou repassez ici quand vous aurez du réseau."),
        Block::Note { tone: Tone::Info, text: "C'est le site qui est hors ligne, pas wisq. La machine Linux locale de l'application n'a besoin d'aucun réseau." },
    ],
};

pub static NOT_FOUND_EN: Doc = Doc {
    title: "Not found",
    lede: "That address does not exist on this site.",
    blocks: &[
        Block::P("It may have been renamed, or the link may have been typed by hand. The pages above cover everything the site has: how to install wisq, how the agent protocol works, what the architecture is built on, and what is coming next."),
    ],
};

pub static NOT_FOUND_FR: Doc = Doc {
    title: "Page introuvable",
    lede: "Cette adresse n'existe pas sur ce site.",
    blocks: &[
        Block::P("Elle a peut-être été renommée, ou le lien a été saisi à la main. La navigation ci-dessus couvre tout ce que le site contient : comment installer wisq, comment fonctionne le protocole de l'agent, sur quoi repose l'architecture, et ce qui vient ensuite."),
    ],
};

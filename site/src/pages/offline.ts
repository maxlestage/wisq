import type { Doc } from "../doc";

export const offlineEn: Doc = {
  title: "Offline",
  lede: "This page was never visited while you had a connection, so there was nothing cached to show.",
  blocks: [
    {
      kind: "p",
      text:
        "Every page you have opened before is still available — the site keeps them on the device once they have been read. Navigate back to one, or return when you have a network.",
    },
    {
      kind: "note",
      tone: "info",
      text:
        "This is the site being offline, not wisq. The local Linux machine in the app needs no network at all.",
    },
  ],
};

export const offlineFr: Doc = {
  title: "Hors ligne",
  lede: "Cette page n'a jamais été visitée pendant que vous aviez une connexion : il n'y avait rien en cache à afficher.",
  blocks: [
    {
      kind: "p",
      text:
        "Toutes les pages déjà ouvertes restent disponibles — le site les garde sur l'appareil une fois lues. Revenez à l'une d'elles, ou repassez ici quand vous aurez du réseau.",
    },
    {
      kind: "note",
      tone: "info",
      text:
        "C'est le site qui est hors ligne, pas wisq. La machine Linux locale de l'application n'a besoin d'aucun réseau.",
    },
  ],
};

export const notFoundEn: Doc = {
  title: "Not found",
  lede: "That address does not exist on this site.",
  blocks: [
    {
      kind: "p",
      text:
        "It may have been renamed, or the link may have been typed by hand. The pages above cover everything the site has: how to install wisq, how the agent protocol works, what the architecture is built on, and what is coming next.",
    },
  ],
};

export const notFoundFr: Doc = {
  title: "Page introuvable",
  lede: "Cette adresse n'existe pas sur ce site.",
  blocks: [
    {
      kind: "p",
      text:
        "Elle a peut-être été renommée, ou le lien a été saisi à la main. La navigation ci-dessus couvre tout ce que le site contient : comment installer wisq, comment fonctionne le protocole de l'agent, sur quoi repose l'architecture, et ce qui vient ensuite.",
    },
  ],
};

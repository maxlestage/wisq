/// The stored theme, and how it reaches the live document.
///
/// This file exists apart from `components/ThemeSwitch.tsx` for one reason:
/// **it must be importable without importing React.** The enhancement script
/// that runs in the browser needs `applyTheme`, and it is the only thing in the
/// site that ships to a visitor. Importing it from a `.tsx` module would drag
/// the JSX runtime — and behind it react-dom — into a bundle whose whole point
/// is that neither is there.

export const THEME_KEY = "wisq.theme";
export type Theme = "light" | "dark" | "auto";

/// Les deux `--bg` de `styles.css`, et ce que le navigateur peint autour de la
/// page : la barre d'état sur iOS, le bandeau d'onglet ailleurs.
///
/// Exporté parce que le reste du site les lisait de mémoire. Ces deux couleurs
/// étaient écrites à la main en cinq endroits — ici, les deux métas de
/// `src/index.html`, les deux métas de chaque document, le script en ligne du
/// thème et les deux clés du manifeste — et rien ne les comparait. La bascule
/// du bleu nuit vers le noir d'encre en a trouvé quatre sur cinq. Il y a
/// maintenant une source, et un test qui la confronte à la feuille de style
/// construite plutôt qu'à une copie.
export const BAR: Record<"light" | "dark", string> = { light: "#f2ede3", dark: "#0e0d0c" };

/// Anything that is not an explicit choice is `auto`, including a browser that
/// refuses storage outright.
export function storedTheme(): Theme {
  try {
    const value = localStorage.getItem(THEME_KEY);
    return value === "light" || value === "dark" ? value : "auto";
  } catch {
    return "auto";
  }
}

export function rememberTheme(theme: Theme) {
  try {
    if (theme === "auto") localStorage.removeItem(THEME_KEY);
    else localStorage.setItem(THEME_KEY, theme);
  } catch {
    /* the choice holds for this page and simply does not outlive it */
  }
}

/// Applies a choice to the live document, so the page changes under the
/// reader's finger rather than on the next navigation.
export function applyTheme(theme: Theme) {
  const root = document.documentElement;
  if (theme === "auto") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", theme);

  // The two theme-color metas carry a `media` attribute, so on `auto` they
  // already follow the system. An explicit choice has to override both, or the
  // browser paints its chrome for a theme the page is not using.
  const metas = document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]');
  metas.forEach((meta) => {
    const media = meta.getAttribute("media") ?? "";
    const own = media.includes("dark") ? BAR.dark : BAR.light;
    meta.content = theme === "auto" ? own : BAR[theme];
  });
}

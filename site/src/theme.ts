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

/// Kept beside the palette in `styles.css`: these are the two `--bg` values,
/// and they are what the browser paints around the page — the status bar on
/// iOS, the tab strip elsewhere.
const BAR: Record<"light" | "dark", string> = { light: "#ffffff", dark: "#0b0d10" };

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

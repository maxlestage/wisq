/// Light, dark, or whatever the system says.
///
/// Three states rather than two, because a toggle cannot express "follow my
/// phone": a reader whose device turns dark at sunset wants the site to do the
/// same, and a two-way switch silently opts them out of that the first time
/// they touch it.
///
/// The choice is applied before the first paint by a small script in the
/// document head (see `build.tsx`) — not here. A React effect runs after the
/// page has already painted, so a reader who asked for light on a dark system
/// would see a flash of the wrong theme on every single navigation. This
/// component only reflects the stored choice and changes it.

import { useEffect, useState } from "react";
import type { copy as allCopy } from "../content";

export const THEME_KEY = "wisq.theme";
export type Theme = "light" | "dark" | "auto";

/// Kept beside the palette in `styles.css`: these are the two `--bg` values,
/// and they are what the browser paints around the page — the status bar on
/// iOS, the tab strip elsewhere.
const BAR: Record<"light" | "dark", string> = { light: "#ffffff", dark: "#0b0d10" };

function storedTheme(): Theme {
  try {
    const value = localStorage.getItem(THEME_KEY);
    return value === "light" || value === "dark" ? value : "auto";
  } catch {
    return "auto";
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

export function ThemeSwitch({ copy }: { copy: (typeof allCopy)["en"] }) {
  // "auto" is what the server rendered, so the first client render must agree
  // or hydration mismatches. The effect below corrects the pressed state one
  // frame later — the colours themselves were already right before paint.
  const [theme, setTheme] = useState<Theme>("auto");

  useEffect(() => {
    setTheme(storedTheme());
  }, []);

  const choose = (next: Theme) => {
    setTheme(next);
    applyTheme(next);
    try {
      if (next === "auto") localStorage.removeItem(THEME_KEY);
      else localStorage.setItem(THEME_KEY, next);
    } catch {
      /* the choice holds for this page and simply does not outlive it */
    }
  };

  const options: { id: Theme; label: string; icon: React.ReactNode }[] = [
    { id: "light", label: copy.theme.light, icon: <SunIcon /> },
    { id: "dark", label: copy.theme.dark, icon: <MoonIcon /> },
    { id: "auto", label: copy.theme.auto, icon: <AutoIcon /> },
  ];

  return (
    <div className="theme-switch" role="group" aria-label={copy.theme.label}>
      {options.map((option) => (
        <button
          key={option.id}
          type="button"
          aria-pressed={theme === option.id}
          aria-label={option.label}
          title={option.label}
          onClick={() => choose(option.id)}
        >
          {option.icon}
        </button>
      ))}
    </div>
  );
}

/// The icons are drawn rather than typed: an emoji sun is a different picture
/// in every font, and a font that lacks it draws a box.
function SunIcon() {
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" focusable="false">
      <circle cx="12" cy="12" r="4.4" fill="currentColor" />
      {[0, 45, 90, 135, 180, 225, 270, 315].map((angle) => (
        <rect
          key={angle}
          x="11.1"
          y="1.4"
          width="1.8"
          height="3.6"
          rx="0.9"
          fill="currentColor"
          transform={`rotate(${angle} 12 12)`}
        />
      ))}
    </svg>
  );
}

function MoonIcon() {
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" focusable="false">
      <path
        d="M20 14.4A8.6 8.6 0 0 1 9.6 4 8.6 8.6 0 1 0 20 14.4Z"
        fill="currentColor"
      />
    </svg>
  );
}

/// A circle lit on one side: the page taking its side from somewhere else.
function AutoIcon() {
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true" focusable="false">
      <circle cx="12" cy="12" r="8" fill="none" stroke="currentColor" strokeWidth="2" />
      <path d="M12 4a8 8 0 0 1 0 16Z" fill="currentColor" />
    </svg>
  );
}

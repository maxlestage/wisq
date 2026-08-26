/// Light, dark, or whatever the system says.
///
/// Three states rather than two, because a toggle cannot express "follow my
/// phone": a reader whose device turns dark at sunset wants the site to do the
/// same, and a two-way switch silently opts them out of that the first time
/// they touch it.
///
/// The choice is applied before the first paint by a small script in the
/// document head (see `build.tsx`), and the pressed state is set by the
/// enhancement script once the page is up (see `main.ts`). Neither happens
/// here: **this component never runs in a browser.** It is rendered once, at
/// build time, into the markup those two scripts then drive.
///
/// That is why the buttons carry `data-theme-choice` rather than an `onClick`.
/// An `onClick` is a promise that React will be there to honour it, and the
/// whole point of the pre-rendered site is that it is not: the behaviour costs
/// about a kilobyte of plain JavaScript, where hydrating this one switch cost
/// sixty-four.

import type { copy as allCopy } from "../content";
import type { Theme } from "../theme";

export function ThemeSwitch({ copy }: { copy: (typeof allCopy)["en"] }) {
  // `auto` is what the markup ships with, because it is the only answer that is
  // right for a reader whose choice has not been read yet — and for one who has
  // JavaScript off entirely, where the page simply follows the system and this
  // switch does nothing. The script corrects the pressed state on load.
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
          data-theme-choice={option.id}
          aria-pressed={option.id === "auto"}
          aria-label={option.label}
          title={option.label}
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

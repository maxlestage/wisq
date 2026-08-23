import { useEffect, useState } from "react";
import type { Copy } from "../content";

/// The affordance that turns the site into something on the Home Screen.
///
/// Two platforms, two mechanisms, and the one this project cares about is the
/// one with no API. Chromium fires `beforeinstallprompt` and hands over a
/// prompt to call later; iOS Safari fires nothing at all and installs through
/// the Share sheet, so the only honest thing to offer there is the three taps
/// that work.
///
/// Nothing renders on the server or on the first client render. That is not a
/// detail — the decision depends on the browser, and rendering it during
/// hydration would mean the markup React expects and the markup in the page
/// disagree.

const DISMISSED_KEY = "wisq.install.dismissed";

interface InstallEvent extends Event {
  prompt(): Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

function isStandalone(): boolean {
  if (window.matchMedia?.("(display-mode: standalone)").matches) return true;
  // Safari on iOS predates display-mode and reports this instead.
  return (navigator as unknown as { standalone?: boolean }).standalone === true;
}

function isIOS(): boolean {
  const ua = navigator.userAgent;
  if (/iPad|iPhone|iPod/.test(ua)) return true;
  // iPadOS reports itself as a Mac; the touch points give it away.
  return ua.includes("Macintosh") && navigator.maxTouchPoints > 1;
}

function wasDismissed(): boolean {
  try {
    return localStorage.getItem(DISMISSED_KEY) === "1";
  } catch {
    // Private mode, or storage the browser refuses. Not a reason to fail.
    return false;
  }
}

function remember() {
  try {
    localStorage.setItem(DISMISSED_KEY, "1");
  } catch {
    /* nothing to do: the banner simply asks again next time */
  }
}

export function InstallPrompt({ copy }: { copy: Copy }) {
  const [mode, setMode] = useState<"hidden" | "prompt" | "ios">("hidden");
  const [event, setEvent] = useState<InstallEvent | null>(null);

  useEffect(() => {
    if (isStandalone() || wasDismissed()) return;

    if (isIOS()) {
      setMode("ios");
      return;
    }

    const onPrompt = (raw: Event) => {
      // Keeping the event is the whole point: the browser only lets the prompt
      // be shown in response to a gesture, so it has to be held until a tap.
      raw.preventDefault();
      setEvent(raw as InstallEvent);
      setMode("prompt");
    };
    window.addEventListener("beforeinstallprompt", onPrompt);
    return () => window.removeEventListener("beforeinstallprompt", onPrompt);
  }, []);

  if (mode === "hidden") return null;

  const dismiss = () => {
    remember();
    setMode("hidden");
  };

  const install = async () => {
    if (!event) return;
    await event.prompt();
    await event.userChoice;
    remember();
    setMode("hidden");
  };

  const ios = mode === "ios";

  return (
    <aside className="install-banner" role="complementary">
      <div className="wrap install-banner-inner">
        <div>
          <strong>{ios ? copy.pwa.iosTitle : copy.pwa.title}</strong>
          <p>{ios ? copy.pwa.iosBody : copy.pwa.body}</p>
        </div>
        <div className="install-banner-actions">
          {ios ? null : (
            <button type="button" className="btn btn-primary" onClick={install}>
              {copy.pwa.action}
            </button>
          )}
          <button type="button" className="btn btn-quiet" onClick={dismiss}>
            {copy.pwa.dismiss}
          </button>
        </div>
      </div>
    </aside>
  );
}

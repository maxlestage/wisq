import type { Copy } from "../content";

/// The affordance that turns the site into something on the Home Screen.
///
/// Two platforms, two mechanisms, and the one this project cares about is the
/// one with no API. Chromium fires `beforeinstallprompt` and hands over a
/// prompt to call later; iOS Safari fires nothing at all and installs through
/// the Share sheet, so the only honest thing to offer there is the three taps
/// that work.
///
/// **Both wordings are rendered, and both start hidden.** Which one applies is
/// a fact about the browser, so it cannot be known at build time — but the
/// alternative was worse. Building this banner in the browser means shipping
/// its four strings, in the page's language, to the script; rendering it here
/// and revealing it there keeps every word of the site in one place and lets
/// the script stay a few hundred bytes of DOM calls.
///
/// It used to render `null` on the server for a different reason: React
/// hydrated this page, and markup the server produced that the first client
/// render did not would be a mismatch. Nothing hydrates any more, so that
/// constraint is gone and the cheaper arrangement is available.
export function InstallPrompt({ copy }: { copy: Copy }) {
  return (
    <aside className="install-banner" role="complementary" hidden data-install>
      <div className="wrap install-banner-inner">
        <div data-install-variant="prompt" hidden>
          <strong>{copy.pwa.title}</strong>
          <p>{copy.pwa.body}</p>
        </div>
        <div data-install-variant="ios" hidden>
          <strong>{copy.pwa.iosTitle}</strong>
          <p>{copy.pwa.iosBody}</p>
        </div>
        <div className="install-banner-actions">
          {/* Only Chromium's path has a button that can do anything: on iOS
              there is no API to call, so the wording is the whole feature. */}
          <button type="button" className="btn btn-primary" data-install-accept hidden>
            {copy.pwa.action}
          </button>
          <button type="button" className="btn btn-quiet" data-install-dismiss>
            {copy.pwa.dismiss}
          </button>
        </div>
      </div>
    </aside>
  );
}

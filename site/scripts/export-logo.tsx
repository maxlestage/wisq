/// Exports the full mark as standalone SVG, at whatever size someone needs.
///
/// The mark lives as a React component because that is where the site uses it;
/// this renders the same component — not a copy of it — so an exported icon
/// can never drift from the one on the page.
///
/// Two shapes come out, and the difference matters if the destination is an
/// app icon. The web mark carries its own rounded plate. iOS applies its own
/// mask to whatever you hand it, so a pre-rounded PNG gets rounded twice and
/// the corners come out visibly wrong: the full-bleed variant fills the square
/// edge to edge and lets the platform do the rounding.

import { renderToStaticMarkup } from "react-dom/server";
import { writeFile, mkdir } from "node:fs/promises";
import { join } from "node:path";
import { Logo } from "../src/components/Logo";

const outdir = process.argv[2] ?? "logo-export";
await mkdir(outdir, { recursive: true });

const markup = renderToStaticMarkup(<Logo />);

/// The component renders width/height for the page; a standalone file wants
/// neither, so it scales to whatever it is placed in.
function standalone(body: string, fullBleed: boolean): string {
  let svg = body
    .replace(/ class="[^"]*"/, "")
    .replace(/ width="240" height="240"/, "")
    .replace("<svg ", '<svg xmlns="http://www.w3.org/2000/svg" ');
  if (fullBleed) {
    // The plate's own rounding goes, and so does the hairline that traced it.
    svg = svg
      .replace(/<rect width="240" height="240" rx="54"/, '<rect width="240" height="240"')
      // React's SSR closes SVG elements explicitly — `</rect>`, never `/>` —
      // so a pattern looking for a self-closing tag silently matches nothing
      // and the hairline survives into an icon that should not have one.
      .replace(/<rect x="0\.75"[\s\S]*?<\/rect>/, "");
  }
  return svg;
}

await writeFile(join(outdir, "wisq-mark.svg"), standalone(markup, false));
await writeFile(join(outdir, "wisq-mark-fullbleed.svg"), standalone(markup, true));
console.log(`exporté dans ${outdir}/`);

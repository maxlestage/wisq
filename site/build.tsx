/// Builds the site, then pre-renders the page into the HTML shell.
///
/// A landing page that needs 400 KB of JavaScript before showing a word is the
/// opposite of mobile-first. Rendering at build time means the content paints
/// on the first response; React then hydrates it to power the tabs and the
/// language switch.
import { renderToString } from "react-dom/server";
import { rm } from "node:fs/promises";
import { App } from "./src/App";

const outdir = "dist";
await rm(outdir, { recursive: true, force: true });

const result = await Bun.build({
  entrypoints: ["src/index.html"],
  outdir,
  minify: true,
  publicPath: "./",
});

if (!result.success) {
  for (const log of result.logs) console.error(log);
  process.exit(1);
}

const shellPath = `${outdir}/index.html`;
const shell = await Bun.file(shellPath).text();
const markup = renderToString(<App lang="en" />);

const injected = shell.replace('<div id="root"></div>', `<div id="root">${markup}</div>`);
if (injected === shell) {
  console.error("le point d'injection #root est introuvable dans le HTML construit");
  process.exit(1);
}
await Bun.write(shellPath, injected);

const bytes = (await Bun.file(shellPath).text()).length;
console.log(`site construit : index.html pré-rendu (${(bytes / 1024).toFixed(1)} Kio)`);

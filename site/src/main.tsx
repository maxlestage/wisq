import { StrictMode } from "react";
import { hydrateRoot } from "react-dom/client";
import { App } from "./App";

const container = document.getElementById("root");
if (!container) throw new Error("#root introuvable");

// The HTML arrives pre-rendered, so this attaches behaviour to existing markup
// instead of building it: the page is readable before this script even loads.
hydrateRoot(
  container,
  <StrictMode>
    <App />
  </StrictMode>,
);

/// **Les deux README ne disent pas la même chose, et l'un manque une capacité.**
///
/// Ce sont deux documents, pas une traduction : le tableau français est plus fin
/// que l'anglais — vingt-cinq lignes contre vingt — et c'est délibéré. Une garde
/// ligne à ligne serait donc fausse.
///
/// Ce qui n'est pas délibéré : **le README français ne dit nulle part que l'agent
/// parle TLS**. L'anglais le dit deux fois — un paragraphe (« The agent speaks
/// TLS by default: a self-signed certificate whose SHA-256 fingerprint travels in
/// the pairing link, pinned by the app ») et une ligne de tableau (« Agent TLS |
/// done »). Le démon a `tls.rs` depuis la 0.3, le lien d'appairage porte `fp=`,
/// et `AgentClient` épingle. Le lecteur francophone — celui du dépôt — lisait un
/// document d'où une fonction de sécurité livrée était absente.
///
/// **Ce que cette garde tient** : une capacité nommée, présente dans le code, doit
/// être nommée dans les deux langues. Rien de plus. Elle ne compare pas les
/// tableaux, ne compte pas les lignes et ne juge pas la granularité — trois
/// choses qui diffèrent à dessein.

import { expect, test } from "bun:test";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

const repoRoot = join(import.meta.dir, "..", "..");

/// Une capacité : ce qui prouve qu'elle existe dans le code, et ce qui prouve que
/// chaque README la nomme. Les marqueurs sont des motifs, pas des phrases : la
/// formulation des deux documents est libre, leur contenu ne l'est pas.
const capabilities = [
  {
    name: "le TLS de l'agent",
    provenFor: "crates/wisq-agent/src/tls.rs",
    markers: {
      "README.md": /agent speaks TLS|Agent TLS/i,
      "README.fr.md": /agent parle TLS|TLS de l'agent|Agent .*TLS/i,
    },
  },
];

test("une capacité que le code porte est nommée dans les deux README", () => {
  for (const { name, provenFor, markers } of capabilities) {
    expect(
      existsSync(join(repoRoot, provenFor)),
      `${name} : ${provenFor} n'existe plus, donc l'exigence ne repose sur rien.`,
    ).toBe(true);
    for (const [file, marker] of Object.entries(markers)) {
      expect(
        marker.test(readFileSync(join(repoRoot, file), "utf8")),
        `${file} ne nomme pas ${name}, que ${provenFor} porte. L'autre langue ` +
          `le nomme : un lecteur d'une des deux langues lit un document d'où une ` +
          `capacité livrée est absente.`,
      ).toBe(true);
    }
  }
});

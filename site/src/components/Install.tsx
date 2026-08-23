import { useState } from "react";
import { RELEASES, type Copy } from "../content";
import { CommandBlock } from "./CommandBlock";

type Platform = "iphone" | "mac" | "linux";

/// Platform tabs rather than three stacked sections: on a phone, scrolling
/// past instructions that do not apply to you is the whole problem.
export function Install({ copy }: { copy: Copy }) {
  const [platform, setPlatform] = useState<Platform>("iphone");
  const panel = copy.install[platform];

  return (
    <section id="install">
      <div className="wrap">
        <h2>{copy.install.title}</h2>
        <p className="lede">{copy.install.lede}</p>

        <div className="tabs" role="tablist" aria-label={copy.install.title}>
          {(["iphone", "mac", "linux"] as const).map((key) => (
            <button
              key={key}
              type="button"
              role="tab"
              id={`tab-${key}`}
              aria-selected={platform === key}
              aria-controls={`panel-${key}`}
              onClick={() => setPlatform(key)}
            >
              {copy.install.tabs[key]}
            </button>
          ))}
        </div>

        <div role="tabpanel" id={`panel-${platform}`} aria-labelledby={`tab-${platform}`}>
          <p className="tab-intro">{panel.intro}</p>
          {panel.commands.map((command) => (
            <CommandBlock
              key={command.label}
              command={command}
              copyLabel={copy.install.copy}
              copiedLabel={copy.install.copied}
            />
          ))}
          {platform === "iphone" ? (
            <a className="release-link" href={RELEASES}>
              {copy.install.releaseLink} →
            </a>
          ) : null}
        </div>
      </div>
    </section>
  );
}

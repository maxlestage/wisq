import { useCallback, useEffect, useState } from "react";
import type { Command } from "../content";

interface Props {
  command: Command;
  copyLabel: string;
  copiedLabel: string;
}

/// A shell snippet with a copy button — the one interactive thing on the page
/// that has to work on a phone, where selecting multi-line text by hand is
/// miserable.
export function CommandBlock({ command, copyLabel, copiedLabel }: Props) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1800);
    return () => clearTimeout(timer);
  }, [copied]);

  const copy = useCallback(async () => {
    try {
      // Clipboard access needs a secure context; without one the button simply
      // does nothing visible rather than throwing at the user.
      await navigator.clipboard.writeText(command.code);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  }, [command.code]);

  return (
    <div className="command">
      <div className="command-head">
        <h3>{command.label}</h3>
        <button
          type="button"
          className="copy-btn"
          data-copied={copied}
          onClick={copy}
          aria-label={`${copyLabel}: ${command.label}`}
        >
          {copied ? copiedLabel : copyLabel}
        </button>
      </div>
      <pre>
        <code>{command.code}</code>
      </pre>
      {command.note ? <p className="command-note">{command.note}</p> : null}
    </div>
  );
}

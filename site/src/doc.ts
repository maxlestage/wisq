/// The document model the written pages are built from.
///
/// Pages are data, not markup. Two reasons, both learned from the landing page:
/// a translation that exists in one language and not the other is a type error
/// rather than an English paragraph leaking into the French site, and the tests
/// can walk a page looking for empty strings or broken claims without parsing
/// HTML.
///
/// The block set is deliberately small. Every kind here earns its place by
/// appearing in the real documentation; anything rarer belongs in prose.

export type Block =
  | { kind: "p"; text: string }
  | { kind: "h2"; text: string }
  | { kind: "h3"; text: string }
  | { kind: "ul"; items: string[] }
  | { kind: "ol"; items: string[] }
  | { kind: "code"; code: string; caption?: string }
  | { kind: "note"; tone: "info" | "warn"; text: string }
  | { kind: "table"; columns: string[]; rows: string[][] }
  | { kind: "dl"; items: { term: string; detail: string }[] };

export interface Doc {
  /// Shown in the browser tab and as the page's h1.
  title: string;
  /// One sentence under the title, and the page's meta description.
  lede: string;
  blocks: Block[];
}

/// Every string a document carries, for the guards that check none is empty.
export function documentStrings(doc: Doc): string[] {
  const out = [doc.title, doc.lede];
  for (const block of doc.blocks) {
    switch (block.kind) {
      case "p":
      case "h2":
      case "h3":
        out.push(block.text);
        break;
      case "note":
        out.push(block.text);
        break;
      case "ul":
      case "ol":
        out.push(...block.items);
        break;
      case "code":
        out.push(block.code);
        if (block.caption) out.push(block.caption);
        break;
      case "table":
        out.push(...block.columns, ...block.rows.flat());
        break;
      case "dl":
        for (const item of block.items) out.push(item.term, item.detail);
        break;
    }
  }
  return out;
}

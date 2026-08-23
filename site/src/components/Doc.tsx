import type { Block, Doc } from "../doc";

/// Renders a written page from its blocks.
///
/// One renderer for every document means a heading looks the same on the guide
/// and on the protocol reference, and that adding a page is adding content
/// rather than markup. It also means the block set stays small: a kind that
/// exists here has to be worth the layout it brings.

function slug(text: string): string {
  return text
    .toLowerCase()
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function renderBlock(block: Block, index: number) {
  switch (block.kind) {
    case "p":
      return <p key={index}>{block.text}</p>;

    case "h2": {
      // Every section is addressable, so a link into the middle of the guide
      // lands where it says it will.
      const id = slug(block.text);
      return (
        <h2 key={index} id={id}>
          <a className="anchor" href={`#${id}`} aria-label={block.text}>
            {block.text}
          </a>
        </h2>
      );
    }

    case "h3":
      return (
        <h3 key={index} id={slug(block.text)}>
          {block.text}
        </h3>
      );

    case "ul":
      return (
        <ul key={index} className="doc-list">
          {block.items.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ul>
      );

    case "ol":
      return (
        <ol key={index} className="doc-list doc-steps">
          {block.items.map((item) => (
            <li key={item}>{item}</li>
          ))}
        </ol>
      );

    case "code":
      return (
        <figure key={index} className="doc-code">
          {block.caption ? <figcaption>{block.caption}</figcaption> : null}
          <pre>
            <code>{block.code}</code>
          </pre>
        </figure>
      );

    case "note":
      return (
        <aside key={index} className={`doc-note doc-note-${block.tone}`}>
          <p>{block.text}</p>
        </aside>
      );

    case "table":
      return (
        <div key={index} className="table-scroll">
          <table>
            <thead>
              <tr>
                {block.columns.map((column) => (
                  <th key={column} scope="col">
                    {column}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {block.rows.map((row) => (
                <tr key={row.join("|")}>
                  {row.map((cell, cellIndex) => (
                    <td key={cellIndex}>{cell}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );

    case "dl":
      return (
        <dl key={index} className="doc-dl">
          {block.items.map((item) => (
            <div key={item.term}>
              <dt>{item.term}</dt>
              <dd>{item.detail}</dd>
            </div>
          ))}
        </dl>
      );
  }
}

export function DocPage({ doc }: { doc: Doc }) {
  return (
    <article className="doc">
      <div className="wrap">
        <header className="doc-head">
          <h1>{doc.title}</h1>
          <p className="lede">{doc.lede}</p>
        </header>
        {doc.blocks.map(renderBlock)}
      </div>
    </article>
  );
}

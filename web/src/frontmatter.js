/* Frontmatter: the leading `---` (YAML) or `+++` (TOML) block.
 *
 * The only parser in the app. Swift does not parse frontmatter at all — the page
 * sends it the parsed fields — so this is the single place the shape of a block
 * is decided.
 */

/** Split a leading `---` (YAML) or `+++` (TOML) block off the document. */
export function splitFrontmatter(text) {
  const match = /^\uFEFF?(---|\+\+\+)[ \t]*\r?\n([\s\S]*?)\r?\n?\1[ \t]*(?:\r?\n|$)/.exec(text);
  if (!match) return { fields: [], body: text };
  return { fields: parseFields(match[2]), body: text.slice(match[0].length) };
}

/**
 * Runs of anything that is not a space or a newline. The class is Swift's
 * `Character.isNewline` set, so the number matches what the titlebar showed
 * when Swift counted the raw file. A tab is deliberately not a separator.
 * tools/wordcount-tests.js pins the whole set.
 */
export function countWords(text) {
  return (text.match(/[^ \n\r\u000b\u000c\u0085\u2028\u2029]+/g) || []).length;
}

function unquote(value) {
  return value
    .trim()
    .replace(/,$/, "")
    .trim()
    .replace(/^(['"])([\s\S]*)\1$/, "$2")
    .trim();
}

/**
 * Reads the flat `key: value` shape that frontmatter almost always uses:
 * scalars, inline `[a, b]` lists and `- item` block lists. Nested maps are
 * skipped rather than guessed at — this is deliberately not a YAML parser.
 */
function parseFields(raw) {
  const lines = raw.split(/\r?\n/);
  const fields = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (!line.trim() || /^\s*#/.test(line)) continue;
    const match = /^([A-Za-z0-9_.\-]+)\s*[:=]\s*(.*)$/.exec(line);
    if (!match) continue; // indented sub-keys, etc.
    const key = match[1];
    const value = match[2].trim();

    if (!value) {
      const items = [];
      while (i + 1 < lines.length && /^\s*-\s+/.test(lines[i + 1])) {
        items.push(unquote(lines[++i].replace(/^\s*-\s+/, "")));
      }
      if (items.length) fields.push([key, items.filter(Boolean)]);
      continue; // a bare key holds a nested map
    }
    if (/^\[[\s\S]*\]$/.test(value)) {
      fields.push([key, value.slice(1, -1).split(",").map(unquote).filter(Boolean)]);
    } else {
      fields.push([key, unquote(value)]);
    }
  }
  return fields;
}

const DOCUMENT_FIELDS = ["title", "subtitle"];

/**
 * The fields the titlebar disclosure shows: everything except the two the
 * document itself displays as its head. Keeping that split here means one place
 * decides which field belongs where.
 */
export function panelFields(fields) {
  return fields
    .filter(([name]) => !DOCUMENT_FIELDS.includes(name.toLowerCase()))
    .map(([name, value]) => ({
      name,
      values: Array.isArray(value) ? value : [value],
      isList: Array.isArray(value),
    }));
}

/**
 * Builds the header shown above the document: the title, and a subtitle if
 * there is one. The remaining fields go to the titlebar disclosure — showing
 * them in both places at once just duplicates the metadata.
 * Values are set as text, never HTML.
 */
export function frontmatterHeader(fields, firstBodyHeading) {
  const header = document.createElement("header");
  header.className = "frontmatter";

  const titleIndex = fields.findIndex(([key]) => key.toLowerCase() === "title");
  const rest = fields.slice();
  // Don't print the title twice when the body already opens with it.
  if (titleIndex >= 0) {
    const [, value] = rest[titleIndex];
    const text = Array.isArray(value) ? value.join(", ") : value;
    if (text && text.trim() !== (firstBodyHeading || "").trim()) {
      const h1 = document.createElement("h1");
      h1.className = "fm-title";
      h1.textContent = text;
      header.appendChild(h1);
    }
    rest.splice(titleIndex, 1);
  }

  const subtitleIndex = rest.findIndex(([key]) => key.toLowerCase() === "subtitle");
  if (subtitleIndex >= 0) {
    const [, value] = rest[subtitleIndex];
    const text = Array.isArray(value) ? value.join(", ") : value;
    if (text) {
      const line = document.createElement("p");
      line.className = "fm-subtitle";
      line.textContent = text;
      header.appendChild(line);
    }
    rest.splice(subtitleIndex, 1);
  }

  return header.childElementCount ? header : null;
}

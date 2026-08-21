/* The in-page find bar.
 *
 * Matches are painted with the CSS Custom Highlight API: a Range per match,
 * handed to CSS.highlights and coloured by the ::highlight() rules in
 * style.css. Nothing here touches the document selection.
 *
 * That is the whole point. A page has exactly one selection, and WebKit routes
 * typed characters to *it*, not to document.activeElement — so window.find(),
 * which is what used to make a match visible, moved the insertion point out of
 * the field. The field still reported focus, the second character went nowhere,
 * and macOS beeped at it. Refocusing the field afterwards only trades that for
 * an invisible search. See DESIGN.md.
 */
import { KEYBOARD_SCROLL_BEHAVIOR } from "./motion.js";

/** The two highlight names, matched by the ::highlight() rules in style.css. */
const ALL = "mdview-find";
const CURRENT = "mdview-find-current";

/** A ceiling on ranges, so a one-letter query in a huge document stays cheap. */
const MATCH_LIMIT = 2000;

/** On the page but not the document's text, so a match here would either
 *  highlight nothing visible or count something the reader cannot see:
 *
 *  - `script` / `style` — never rendered, and a mermaid diagram carries a
 *    `<style>` block of its own inside #doc.
 *  - `.sr-only` — the "Footnotes" heading marked-footnote emits for screen
 *    readers.
 *  - `.anchor` — the aria-hidden "#" viewer.js puts at the front of every
 *    heading, which would also cut a heading's own words in two.
 *  - `.copy` — the code figure's button. It is a control, and its label
 *    changes to "Copied" while you look at it.
 */
const SKIP = "script, style, .sr-only, .anchor, .copy";

/** Tags whose text runs straight on into their neighbours'. Everything else is
 *  treated as a block: a newline goes in on the way in and on the way out, so a
 *  match spans inline markup but can never span two blocks.
 *
 *  `br` is deliberately absent — it is a line break, so the text either side of
 *  it is no more one phrase than two paragraphs are. So are SVG's tags, which
 *  arrive lowercase: a diagram's labels are separate strings, not a sentence.
 */
const INLINE = new Set([
  "A",
  "ABBR",
  "B",
  "BDI",
  "BDO",
  "CITE",
  "CODE",
  "DATA",
  "DEL",
  "DFN",
  "EM",
  "I",
  "IMG",
  "INS",
  "KBD",
  "MARK",
  "PICTURE",
  "Q",
  "RP",
  "RT",
  "RUBY",
  "S",
  "SAMP",
  "SMALL",
  "SPAN",
  "STRONG",
  "SUB",
  "SUP",
  "TIME",
  "U",
  "VAR",
  "WBR",
]);

/** #doc flattened to one string, plus the way back: `runs` records where each
 *  text node's characters start in it.
 *
 *  Walking one text node at a time — which is what this replaced — misses any
 *  phrase inline markup breaks up, the "down" of a bolded `mark**down**`. So
 *  the search runs over the whole string and each match is turned back into a
 *  Range that may start and end in different nodes. The Highlight API paints
 *  those, so nothing downstream cares.
 */
function buildIndex(root) {
  const parts = [];
  const runs = [];
  let length = 0;
  (function walk(parent) {
    for (let node = parent.firstChild; node; node = node.nextSibling) {
      if (node.nodeType === Node.TEXT_NODE) {
        const text = node.nodeValue || "";
        if (!text) continue;
        parts.push(text);
        runs.push({ node, at: length });
        length += text.length;
      } else if (node.nodeType === Node.ELEMENT_NODE) {
        if (node.matches(SKIP)) continue;
        const block = !INLINE.has(node.tagName);
        if (block) {
          parts.push("\n");
          length += 1;
        }
        walk(node);
        if (block) {
          parts.push("\n");
          length += 1;
        }
      }
    }
  })(root);
  return { text: parts.join(""), runs };
}

/** The (node, offset) an offset in that string came from, as a Range endpoint.
 *
 *  A binary search for the run the character belongs to. `end` looks for the
 *  run holding the character *before* the offset instead, because a match that
 *  finishes exactly where a text node does has two equivalent endpoints — the
 *  end of that node, and offset 0 of the next one — and the first keeps the
 *  Range inside the markup it crossed.
 *
 *  The separators belong to no run, and no match can land in one: a text input
 *  cannot hold a newline, so a needle never contains one.
 */
function locate(runs, offset, end) {
  let low = 0;
  let high = runs.length - 1;
  let found = 0;
  while (low <= high) {
    const mid = (low + high) >> 1;
    if (end ? runs[mid].at < offset : runs[mid].at <= offset) {
      found = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  return [runs[found].node, offset - runs[found].at];
}

/** The element a range endpoint sits in. Reported by state() because a match
    spanning inline markup ends somewhere other than where it started, and
    nothing outside this module can see that. */
const tagOf = (node) => (node && node.parentElement ? node.parentElement.tagName : "");

/** Owns the bar's elements and its keys; returns the commands the app sends. */
export function createFindBar() {
  const bar = document.getElementById("findbar");
  const field = document.getElementById("findinput");
  const all = new Highlight();
  const current = new Highlight();
  CSS.highlights.set(ALL, all);
  CSS.highlights.set(CURRENT, current);

  /** Every match for the query now in the field, in document order. */
  let matches = [];
  /** Which of them is the current one, or -1. */
  let index = -1;

  /** Ranges for `query`, case-insensitively, over the flat text of #doc. */
  function collect(query) {
    const root = document.getElementById("doc");
    if (!root || !query) return [];
    const { text, runs } = buildIndex(root);
    // toLowerCase is length-preserving for everything but a few Unicode
    // oddities (U+0130 lowercases to two units). If it is not, every offset
    // after it would shift, so match case rather than highlight the wrong words.
    const lower = text.toLowerCase();
    const even = lower.length === text.length;
    const haystack = even ? lower : text;
    const needle = even ? query.toLowerCase() : query;
    const found = [];
    let at = haystack.indexOf(needle);
    while (at !== -1) {
      const range = document.createRange();
      range.setStart(...locate(runs, at, false));
      range.setEnd(...locate(runs, at + needle.length, true));
      found.push(range);
      if (found.length >= MATCH_LIMIT) break;
      at = haystack.indexOf(needle, at + needle.length);
    }
    return found;
  }

  function clear() {
    all.clear();
    current.clear();
  }

  /** The current match in one highlight, the rest in the other, so the two can
      be told apart without either being the selection. */
  function paint() {
    clear();
    matches.forEach((range, at) => (at === index ? current : all).add(range));
    bar.classList.toggle("nomatch", !!field.value && matches.length === 0);
  }

  /** The first match at or below the top of the viewport, so a keystroke does
      not throw the reader back to the top of the document. */
  function nearestToView() {
    for (let at = 0; at < matches.length; at += 1) {
      if (matches[at].getBoundingClientRect().bottom > 0) return at;
    }
    return matches.length ? 0 : -1;
  }

  /** Scrolls the current match in, if it is not already comfortably on screen.
      A jump, not a glide: this is keyboard motion. See ./motion.js. */
  function reveal() {
    if (index < 0) return;
    const rect = matches[index].getBoundingClientRect();
    const pad = 24;
    if (rect.top >= pad && rect.bottom <= window.innerHeight - pad) return;
    window.scrollTo({
      top: Math.max(0, rect.top + window.scrollY - window.innerHeight / 4),
      behavior: KEYBOARD_SCROLL_BEHAVIOR,
    });
  }

  /** Re-reads the document for whatever is in the field. */
  function update() {
    matches = collect(field.value);
    index = nearestToView();
    paint();
    reveal();
  }

  /** The next match, or the previous one. Wraps, as window.find did. */
  function step(backwards) {
    if (!matches.length) update();
    if (!matches.length) return;
    const count = matches.length;
    index =
      index < 0 ? (backwards ? count - 1 : 0) : (index + (backwards ? -1 : 1) + count) % count;
    paint();
    reveal();
  }

  function open() {
    bar.hidden = false;
    field.focus();
    field.select();
    if (field.value) update();
  }

  function close() {
    // Blur before hiding, so the focusout handler always fires and the app's
    // plain-key shortcuts come back. Hiding a focused element ought to blur it
    // anyway, but if it ever did not, every plain key would stay disabled.
    field.blur();
    bar.hidden = true;
    bar.classList.remove("nomatch");
    matches = [];
    index = -1;
    clear();
    window.focus();
  }

  /** A new document has replaced the old one, so every Range points at nodes
      that are gone. Search again if the bar is open; drop the ranges if not. */
  function refresh() {
    matches = [];
    index = -1;
    clear();
    if (bar.hidden) {
      bar.classList.remove("nomatch");
      return;
    }
    update();
  }

  /** What the bar has found. Exposed for tools/snapshot.swift: a highlight is
      not in computed style and not in the selection, so nothing else can see it. */
  function state() {
    const at = index >= 0 ? matches[index] : null;
    return {
      query: field.value,
      matches: matches.length,
      current: index,
      currentText: at ? at.toString() : "",
      currentStartTag: at ? tagOf(at.startContainer) : "",
      currentEndTag: at ? tagOf(at.endContainer) : "",
      currentSpansNodes: !!at && at.startContainer !== at.endContainer,
      paintedAll: CSS.highlights.get(ALL).size,
      paintedCurrent: CSS.highlights.get(CURRENT).size,
      nomatch: bar.classList.contains("nomatch"),
      open: !bar.hidden,
      activeElement: (document.activeElement || {}).id || "none",
      scrollY: Math.round(window.scrollY),
    };
  }

  field.addEventListener("input", update);
  field.addEventListener("keydown", (event) => {
    if (event.key === "Enter") {
      event.preventDefault();
      step(event.shiftKey);
    } else if (event.key === "Escape") {
      event.preventDefault();
      close();
    }
  });
  document.getElementById("findnext").addEventListener("click", () => step(false));
  document.getElementById("findprev").addEventListener("click", () => step(true));
  document.getElementById("findclose").addEventListener("click", close);
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !bar.hidden) close();
  });

  return { open, close, refresh, state };
}

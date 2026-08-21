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

/** Painting needs macOS 14.2; below that find still steps and scrolls. */
const canPaint = typeof CSS !== "undefined" && !!CSS.highlights && typeof Highlight === "function";

/** Owns the bar's elements and its keys; returns the commands the app sends. */
export function createFindBar() {
  const bar = document.getElementById("findbar");
  const field = document.getElementById("findinput");
  const all = canPaint ? new Highlight() : null;
  const current = canPaint ? new Highlight() : null;
  if (canPaint) {
    CSS.highlights.set(ALL, all);
    CSS.highlights.set(CURRENT, current);
  }

  /** Every match for the query now in the field, in document order. */
  let matches = [];
  /** Which of them is the current one, or -1. */
  let index = -1;

  /** Ranges for `query`, case-insensitively, over the document's text nodes.
   *
   * One text node at a time, so a match split across elements — the "down" of a
   * bolded "mark**down**" — is not found. window.find crossed those boundaries;
   * this is the cost of not using it, and it is invisible in prose.
   */
  function collect(query) {
    const root = document.getElementById("doc");
    if (!root || !query) return [];
    const needle = query.toLowerCase();
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    const found = [];
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const haystack = (node.nodeValue || "").toLowerCase();
      let at = haystack.indexOf(needle);
      while (at !== -1) {
        const range = document.createRange();
        range.setStart(node, at);
        range.setEnd(node, at + needle.length);
        found.push(range);
        if (found.length >= MATCH_LIMIT) return found;
        at = haystack.indexOf(needle, at + needle.length);
      }
    }
    return found;
  }

  function clear() {
    if (!canPaint) return;
    all.clear();
    current.clear();
  }

  /** The current match in one highlight, the rest in the other, so the two can
      be told apart without either being the selection. */
  function paint() {
    clear();
    if (canPaint) {
      matches.forEach((range, at) => (at === index ? current : all).add(range));
    }
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
    return {
      query: field.value,
      matches: matches.length,
      current: index,
      currentText: index >= 0 ? matches[index].toString() : "",
      paintedAll: canPaint ? CSS.highlights.get(ALL).size : -1,
      paintedCurrent: canPaint ? CSS.highlights.get(CURRENT).size : -1,
      canPaint,
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

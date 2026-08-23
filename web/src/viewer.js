/* MDView renderer. Swift hands us {markdown, path, dir}; we turn it into DOM,
   post-process it, and keep the scroll position stable across live reloads.

   Bundled by web/build.mjs into Resources/bundle.js. */
import { marked } from "marked";
import markedFootnote from "marked-footnote";
import hljs from "highlight.js/lib/common";
import DOMPurify from "dompurify";
import { createRail } from "./rail.js";
import { countWords, frontmatterHeader, panelFields, splitFrontmatter } from "./frontmatter.js";
import { createFindBar } from "./find.js";
import { createDiagrams } from "./diagrams.js";
import { escapeHtml } from "./util.js";
import { KEYBOARD_SCROLL_BEHAVIOR } from "./motion.js";

(function () {
  "use strict";

  const bridge =
    window.webkit && window.webkit.messageHandlers ? window.webkit.messageHandlers.mdview : null;
  const post = (msg) => {
    if (bridge) bridge.postMessage(msg);
  };

  const elDoc = document.getElementById("doc");
  const elEmpty = document.getElementById("empty");
  const find = createFindBar();

  let current = { path: "", dir: "" };
  let renderToken = 0; // guards async mermaid work against a newer render
  let appliedFormat = ""; // which parser the last render used, for the tests
  const diagrams = createDiagrams();

  // Where the reader was in each document this session, by path. A document
  // left and come back to reopens where it was left — pixel-exact, because it
  // is the same DOM that position was measured on. Swift keeps its own map for
  // positions across launches, which arrives as payload.resumeY.
  const scrollMemory = new Map();
  // Debounce for reporting the settled position to Swift, which persists the
  // last few across launches.
  let scrollPostTimer = 0;

  /**
   * Where the reader is, as an anchor rather than a pixel offset.
   *
   * A live reload restores `window.scrollY`, but the content above it has just
   * been re-laid-out from the edited source: add or remove a line before the
   * viewport and every pixel below shifts by a line height, so the sentence
   * being read drifts up or down on each save — worse the further up the edit
   * was. The nearest heading above the viewport plus the distance into its
   * section is stable under exactly those edits.
   *
   * Also captured here: which <details> are open. They are the one interactive
   * state in a rendered document, and a full innerHTML replacement resets them,
   * which made every save fold the section the reader had opened.
   */
  function captureReadingAnchor() {
    const headings = elDoc.querySelectorAll("h1, h2, h3, h4, h5, h6");
    const y = window.scrollY;
    let index = -1;
    let offset = y;
    for (let i = 0; i < headings.length; i++) {
      const top = headings[i].getBoundingClientRect().top + y;
      if (top <= y + 1) {
        index = i;
        offset = y - top;
      } else break;
    }
    const open = [];
    elDoc.querySelectorAll("details").forEach((d, at) => {
      if (d.open) open.push(at);
    });
    return { index, offset, open };
  }

  /** Re-opens the <details> the previous DOM had open, by their position. */
  function restoreOpenDetails(open) {
    if (!open.length) return;
    const details = elDoc.querySelectorAll("details");
    open.forEach((at) => {
      if (details[at]) details[at].open = true;
    });
  }

  /**
   * Lands the viewport back on the anchor the old DOM recorded.
   *
   * The offset is clamped to the new gap between the anchor heading and the
   * next one: if the edit removed most of the section the reader was deep in,
   * the raw offset would overshoot into the next section entirely.
   */
  function restoreReadingAnchor(anchor) {
    const headings = elDoc.querySelectorAll("h1, h2, h3, h4, h5, h6");
    if (anchor.index >= 0 && headings[anchor.index]) {
      const heading = headings[anchor.index];
      let top = heading.getBoundingClientRect().top + window.scrollY;
      const next = headings[anchor.index + 1];
      const limit = next ? next.getBoundingClientRect().top + window.scrollY : Infinity;
      top += Math.min(anchor.offset, Math.max(0, limit - top - 1));
      window.scrollTo(0, top);
      return;
    }
    // Nothing above the viewport to anchor to — a pixel offset is then still
    // exact, because everything above is empty.
    window.scrollTo(0, anchor.offset);
  }

  // gfm covers tables, strikethrough, task lists and autolinks. Footnotes are a
  // GitHub extension on top of that, so they come from a marked plugin.
  marked.use({ gfm: true, breaks: false, pedantic: false });
  marked.use(markedFootnote());

  // --- helpers --------------------------------------------------------------

  function encodeSegments(path) {
    return path
      .split("/")
      .map((seg) => {
        try {
          return encodeURIComponent(decodeURIComponent(seg));
        } catch (_) {
          return encodeURIComponent(seg);
        }
      })
      .join("/");
  }

  /**
   * Turn a markdown-relative path into something WebKit can load.
   *
   * Anything that already carries a scheme is returned untouched, `javascript:`
   * included. That is safe only because the one caller runs after DOMPurify has
   * already stripped such hrefs — see the call in render().
   */
  function resolveURL(raw) {
    if (!raw) return raw;
    if (/^([a-z][a-z0-9+.\-]*:|\/\/|#|data:)/i.test(raw)) return raw;
    const hash = raw.indexOf("#");
    const frag = hash >= 0 ? raw.slice(hash) : "";
    let path = hash >= 0 ? raw.slice(0, hash) : raw;
    if (!path) return raw;
    if (!path.startsWith("/")) {
      if (!current.dir) return raw;
      path = current.dir + "/" + path;
    }
    return "file://" + encodeSegments(path) + frag;
  }

  function slug(text, seen) {
    let base =
      text
        .toLowerCase()
        .trim()
        .replace(/[^\w\s\-]/g, "")
        .replace(/\s+/g, "-") || "section";
    let id = base,
      n = 1;
    while (seen.has(id)) {
      id = base + "-" + ++n;
    }
    seen.add(id);
    return id;
  }

  // --- GitHub alerts --------------------------------------------------------

  const ALERT_KINDS = ["note", "tip", "important", "warning", "caution"];

  /** Turns `> [!NOTE]` blockquotes into styled callouts. */
  function decorateAlerts(root) {
    root.querySelectorAll("blockquote").forEach((quote) => {
      const first = quote.firstElementChild;
      if (!first || first.tagName !== "P") return;
      const match = /^\s*\[!(note|tip|important|warning|caution)\]\s*/i.exec(
        first.textContent || ""
      );
      if (!match) return;
      const kind = match[1].toLowerCase();
      if (!ALERT_KINDS.includes(kind)) return;

      // Strip the marker out of the leading text node.
      const lead = first.firstChild;
      if (lead && lead.nodeType === Node.TEXT_NODE) {
        lead.nodeValue = lead.nodeValue.replace(/^\s*\[![a-z]+\]\s*/i, "");
      }
      if (!first.textContent.trim() && first.childElementCount === 0) first.remove();

      quote.classList.add("alert", "alert-" + kind);
      const label = document.createElement("p");
      label.className = "alert-label";
      label.textContent = kind.charAt(0).toUpperCase() + kind.slice(1);
      quote.insertBefore(label, quote.firstChild);
    });
  }

  // --- post-processing passes ----------------------------------------------

  /**
   * Marks what on the page is ours rather than the document's, so the find bar
   * and the outline can leave it alone.
   *
   * An attribute we control, not a class name, and DOMPurify is told to strip it
   * from the document (FORBID_ATTR) so a page cannot claim it. The classes this
   * replaces belonged to the document as much as to us: `class="anchor"` is the
   * usual convention for a heading permalink, `sr-only` is Bootstrap's and
   * Tailwind's, and `copy` is an ordinary word for a copyright line. A page using
   * any of them had that text dropped from the search index, so ⌘F answered "no
   * match" for words the reader was looking at.
   */
  function markChrome(root) {
    // marked-footnote's "Footnotes" heading — the only chrome in the document
    // that we did not put there. Identified by the library's own attribute on
    // the section, rather than by the `sr-only` class an author may also use.
    root.querySelectorAll("[data-footnotes] > h2.sr-only").forEach((h) => {
      h.setAttribute("data-chrome", "");
    });
  }

  function addHeadingAnchors(root) {
    const seen = new Set();
    const headings = "h1:not(.fm-title), h2:not([data-chrome]), h3, h4, h5, h6";
    root.querySelectorAll(headings).forEach((h) => {
      if (!h.id) h.id = slug(h.textContent || "", seen);
      const a = document.createElement("a");
      a.className = "anchor";
      a.setAttribute("data-chrome", "");
      a.href = "#" + h.id;
      a.textContent = "#";
      a.setAttribute("aria-hidden", "true");
      h.insertBefore(a, h.firstChild);
    });
  }

  /**
   * Wrap code blocks in a figure, highlight them, and hand ```mermaid blocks
   * to the diagrams module, which swaps in a figure of its own.
   */
  function decorateCode(root) {
    root.querySelectorAll("pre > code").forEach((code) => {
      const pre = code.parentElement;
      const lang = (code.className.match(/language-([\w+#.\-]+)/) || [, ""])[1];
      const source = code.textContent || "";

      if (lang === "mermaid") {
        pre.replaceWith(diagrams.figure(source));
        return;
      }

      const figure = document.createElement("figure");
      figure.className = "code";
      pre.replaceWith(figure);

      // A hairline caption bar carries the language, as the design specifies,
      // rather than a chip floating over the code.
      const caption = document.createElement("figcaption");
      const tag = document.createElement("span");
      tag.className = "lang";
      tag.setAttribute("data-chrome", "");
      tag.textContent = lang || "text";
      caption.appendChild(tag);
      figure.appendChild(caption);
      figure.appendChild(pre);

      const copy = document.createElement("button");
      copy.className = "copy";
      copy.setAttribute("data-chrome", "");
      copy.type = "button";
      copy.textContent = "Copy";
      copy.addEventListener("click", () => {
        post({ action: "copyText", text: source });
        copy.textContent = "Copied";
        copy.classList.add("done");
        setTimeout(() => {
          copy.textContent = "Copy";
          copy.classList.remove("done");
        }, 1400);
      });
      caption.appendChild(copy);

      // Box-drawing only connects when the line box matches the glyph height.
      // Diagrams get line-height 1; ordinary code keeps its comfortable leading.
      if (/[\u2500-\u257f]/.test(source)) figure.classList.add("ascii");

      if (lang && hljs.getLanguage(lang)) {
        try {
          hljs.highlightElement(code);
        } catch (_) {
          /* leave plain */
        }
      }
    });
  }

  function wrapTables(root) {
    root.querySelectorAll("table").forEach((table) => {
      const wrap = document.createElement("div");
      wrap.className = "table-wrap";
      table.replaceWith(wrap);
      wrap.appendChild(table);
    });
  }

  /**
   * Rewrites every URL in a `srcset`.
   *
   * Not `split(",")`, which is what this did first and is wrong: a candidate URL
   * runs to the next *whitespace*, so it may contain commas — `?w=100,200` is a
   * legal query string — and only a comma at the end of the URL closes the
   * candidate. Splitting on every comma turned one valid candidate into two
   * broken ones and the picture vanished. So the shape of the real grammar:
   * skip separators, take the URL as the next run of non-whitespace, and let a
   * descriptor run to the next comma.
   */
  function resolveSrcset(value) {
    const isSpace = (c) => c === " " || c === "\t" || c === "\n" || c === "\r" || c === "\f";
    const out = [];
    let i = 0;
    while (i < value.length) {
      while (i < value.length && (isSpace(value[i]) || value[i] === ",")) i += 1;
      const from = i;
      while (i < value.length && !isSpace(value[i])) i += 1;
      let url = value.slice(from, i);
      // Trailing commas are the candidate separator, not part of the URL.
      let closed = false;
      while (url.endsWith(",")) {
        url = url.slice(0, -1);
        closed = true;
      }
      let descriptor = "";
      if (!closed) {
        const at = i;
        while (i < value.length && value[i] !== ",") i += 1;
        descriptor = value.slice(at, i).trim();
        i += 1; // the comma
      }
      if (!url) continue;
      out.push(descriptor ? resolveURL(url) + " " + descriptor : resolveURL(url));
    }
    return out.join(", ");
  }

  function resolveLocalPaths(root) {
    // Every attribute that survives the sanitiser carrying a URL, not just
    // `img[src]`. `srcset` matters most and is the least obvious: the spec
    // prefers it over `src`, so an <img> with both used to *lose* a picture that
    // resolving `src` alone had got right — the unresolved candidate won and
    // pointed inside the app bundle. Markdown never emitted one; an HTML file
    // written by hand or exported by a tool routinely does.
    root.querySelectorAll("[src]").forEach((el) => {
      el.setAttribute("src", resolveURL(el.getAttribute("src")));
    });
    root.querySelectorAll("[srcset]").forEach((el) => {
      el.setAttribute("srcset", resolveSrcset(el.getAttribute("srcset")));
    });
    root.querySelectorAll("[poster]").forEach((el) => {
      el.setAttribute("poster", resolveURL(el.getAttribute("poster")));
    });
    root.querySelectorAll("a[href]").forEach((a) => {
      const href = a.getAttribute("href");
      if (href && href.startsWith("#")) return; // in-page anchor, leave alone
      a.href = resolveURL(href);
    });
  }

  function markTaskItems(root) {
    root.querySelectorAll("li > input[type=checkbox]").forEach((box) => {
      const li = box.parentElement;
      li.classList.add("task");
      if (box.checked) li.classList.add("done");
    });
  }

  /**
   * Images arrive without jank and fade in once painted.
   *
   * `decoding: async` keeps a large picture off the main thread as it decodes.
   * Everything more than two viewports down also becomes `loading: lazy`, so a
   * long document fetches pictures on approach rather than all at once; nearer
   * ones stay eager, so the first screenful never waits on the decision.
   * Measuring getBoundingClientRect here is free — layout has already been
   * forced by the passes above.
   *
   * The fade: an image that pops in mid-read yanks the eye. `.loaded` turns the
   * opacity on over a beat instead (style.css). Cached images are complete
   * before this runs, so they settle immediately rather than fading from blank.
   */
  function decorateImages(root) {
    const canFade = !document.hidden;
    root.querySelectorAll("img").forEach((img) => {
      img.setAttribute("decoding", "async");
      if (img.getBoundingClientRect().top > window.innerHeight * 2) {
        img.setAttribute("loading", "lazy");
      }
      // A hidden page cannot animate — its transition clock is stopped — so
      // there the image simply gets its final state.
      if (!canFade) return;
      img.classList.add("pending");
      const settle = () => {
        img.classList.remove("pending");
        img.classList.add("loaded");
      };
      if (img.complete && img.naturalWidth > 0) {
        settle();
        return;
      }
      img.addEventListener("load", settle, { once: true });
      // A broken picture must not sit invisible forever: show whatever WebKit
      // draws for it.
      img.addEventListener("error", () => img.classList.remove("pending"), { once: true });
    });
  }

  // --- appearance -----------------------------------------------------------

  const rail = createRail(post);
  elEmpty.addEventListener("click", () => post({ action: "openPanel" }));

  // Tell Swift where the reader settled, so the position survives a relaunch
  // (it comes back as payload.resumeY). Within a session the page remembers by
  // itself; this only has to be roughly current, hence the debounce.
  window.addEventListener(
    "scroll",
    () => {
      if (!current.path) return;
      clearTimeout(scrollPostTimer);
      scrollPostTimer = setTimeout(() => {
        if (!current.path) return;
        post({
          action: "scrollPosition",
          path: current.path,
          y: Math.round(window.scrollY),
        });
      }, 350);
    },
    { passive: true }
  );

  const THEMES = ["paper", "vellum", "night"];
  const SIZES = ["small", "regular", "large"];

  /** Paper, Vellum or Colophon. Anything else follows the OS appearance. */
  function applyTheme(theme) {
    const root = document.documentElement;
    if (THEMES.includes(theme)) {
      root.dataset.theme = theme;
    } else {
      delete root.dataset.theme;
    }
    // Let the repaint cross-fade instead of snapping: for a beat every themed
    // property transitions (see the .theming rules in style.css), then the
    // class goes away so ordinary hover/scroll work carries no transition cost.
    // Only on a visible page — a hidden one cannot animate, and a frozen
    // transition here would hold the *previous* palette on screen.
    if (!document.hidden) {
      root.classList.add("theming");
      clearTimeout(applyTheme.timer);
      applyTheme.timer = setTimeout(() => root.classList.remove("theming"), 260);
    }
  }

  function applySize(size) {
    const root = document.documentElement;
    if (SIZES.includes(size) && size !== "regular") {
      root.dataset.size = size;
    } else {
      delete root.dataset.size;
    }
  }

  /** Justified with hyphenation, or ragged-right without it. */
  function applyAlignment(alignment) {
    document.documentElement.dataset.align = alignment === "left" ? "left" : "justify";
  }

  /** The width of the text column, in points. */
  function applyMeasure(measure) {
    const width = Number(measure);
    document.documentElement.style.setProperty(
      "--measure",
      `${Number.isFinite(width) && width > 0 ? width : 700}px`
    );
  }

  // --- render --------------------------------------------------------------

  function render(payload) {
    const token = ++renderToken;
    const samePage = payload.path && payload.path === current.path;
    // Where the reader is in the document being left, and where to land in the
    // one being opened. Session memory wins — it is exact for this launch;
    // Swift's resumeY covers coming back after a relaunch.
    if (!samePage && current.path) {
      scrollMemory.set(current.path, window.scrollY);
      if (scrollMemory.size > 64) scrollMemory.delete(scrollMemory.keys().next().value);
    }
    let landingY = 0;
    if (!samePage && payload.path) {
      if (scrollMemory.has(payload.path)) {
        landingY = scrollMemory.get(payload.path);
      } else {
        const resume = Number(payload.resumeY);
        if (Number.isFinite(resume) && resume > 0) landingY = resume;
      }
    }
    // Reading position, read off the DOM before it is replaced.
    const anchor = samePage ? captureReadingAnchor() : null;
    // An arrival animation is for a *different* document, seen by someone —
    // the first render is not that, and neither is any render into a hidden
    // page. See the end of this function for why the visibility half matters.
    const switching = !samePage && !!payload.path && !!current.path;
    current = { path: payload.path || "", dir: payload.dir || "" };

    if (!payload.path) {
      elDoc.hidden = true;
      elEmpty.hidden = false;
      appliedFormat = "";
      return;
    }
    elEmpty.hidden = true;
    elDoc.hidden = false;

    if (payload.error) {
      elDoc.innerHTML = '<div class="error">' + escapeHtml(payload.error) + "</div>";
      appliedFormat = "";
      return;
    }

    applyTheme(payload.theme);
    applySize(payload.size);
    applyAlignment(payload.alignment);
    applyMeasure(payload.measure);

    // Frontmatter is a markdown convention, so an HTML file has none — and
    // splitting one anyway would eat any file that happened to start with `---`.
    const isHtml = payload.format === "html";
    // render() is a public entry point, so a caller that is not Swift can pass
    // anything; Swift itself now sends a DocumentFormat and can only send the
    // two. An unrecognised value renders as markdown, which for an HTML file is
    // the bug this field exists to prevent, so it must not be silent.
    if (payload.format !== "html" && payload.format !== "markdown") {
      console.error("mdview: unknown payload format " + JSON.stringify(payload.format));
    }
    appliedFormat = isHtml ? "html" : "markdown";
    const split = isHtml
      ? { body: payload.markdown || "", fields: [] }
      : splitFrontmatter(payload.markdown || "");

    // The titlebar's word count and the fields for its disclosure. The
    // frontmatter parser lives here rather than in Swift, which would be two
    // implementations to keep in step. Separators are space and newline — a tab
    // deliberately is not one, so `a\tb` stays one word, and
    // tools/wordcount-tests.js pins it. Title and subtitle are left out, already
    // being on the page as the document's own head.
    //
    // An HTML document gets neither: no fields, because frontmatter is a
    // markdown convention, and no count, because "how many words" has no honest
    // answer for a page — three attempts at one produced three different numbers
    // and the last of them still disagreed with the markdown count by 30% on the
    // same prose. `words` is therefore absent rather than zero: Swift reads it as
    // an optional and leaves the titlebar's second row empty. Absent and not
    // simply unsent, because the count is deliberately not cleared when a
    // document opens — saying nothing would leave the previous file's number up.
    //
    // Sent before anything is parsed either way, so a throw in marked or
    // DOMPurify still leaves the titlebar right.
    post(
      isHtml
        ? { action: "frontmatter", fields: [] }
        : {
            action: "frontmatter",
            words: countWords(split.body),
            fields: panelFields(split.fields),
          }
    );

    // An HTML file already *is* the markup, so the markdown parser is skipped.
    // What it damages is block-level: HTML is indented, and four spaces of
    // indent is a markdown code block, so nested elements come out as
    // `<pre><code>&lt;p&gt;…`. Text sitting between HTML blocks is parsed as
    // markdown too, so a `~~a~~` there turns into a strikethrough.
    //
    // The sanitiser is not what changes. Both formats go through it, which is
    // why skipping the parser cannot also skip the stripping of <script>.
    const dirty = isHtml ? split.body : marked.parse(split.body);
    elDoc.innerHTML = DOMPurify.sanitize(dirty, {
      ADD_ATTR: ["target"],
      // So `data-chrome` can only ever mean "viewer.js put this here".
      FORBID_ATTR: ["data-chrome"],
    });

    if (anchor) restoreOpenDetails(anchor.open);

    if (split.fields.length && payload.showFrontmatter !== false) {
      const firstHeading = elDoc.querySelector("h1");
      const header = frontmatterHeader(split.fields, firstHeading && firstHeading.textContent);
      if (header) elDoc.insertBefore(header, elDoc.firstChild);
    }

    // Collecting figures for this render starts fresh; decorateCode below
    // registers each ```mermaid block as it walks the DOM.
    diagrams.reset();
    markChrome(elDoc);
    addHeadingAnchors(elDoc);
    decorateAlerts(elDoc);
    decorateCode(elDoc);
    wrapTables(elDoc);
    // Must stay after the sanitize above: resolveURL returns scheme-carrying
    // hrefs unchanged, so DOMPurify is what removes `javascript:` ones.
    resolveLocalPaths(elDoc);
    markTaskItems(elDoc);
    decorateImages(elDoc);

    // Restore position without animating there.
    const root = document.documentElement;
    const behavior = root.style.scrollBehavior;
    root.style.scrollBehavior = "auto";
    if (samePage) {
      restoreReadingAnchor(anchor);
    } else {
      window.scrollTo(0, landingY);
    }
    requestAnimationFrame(() => {
      root.style.scrollBehavior = behavior;
    });

    // A document the reader has never seen fades up; a live reload swaps under
    // them with no ceremony at all. The entrance is opt-in per render —
    // `.enter` hides the fresh content, a reflow commits that, and removing it
    // a frame later is what `.settle` turns into the fade-and-rise.
    //
    // Only on a page that can paint. A hidden page's clocks do not tick: rAF
    // never runs, and a transition started there freezes at its first frame.
    // Since the document's resting state is fully visible (style.css), a
    // skipped animation costs nothing — the content is simply there, which in
    // a window nobody sees is exactly right. This is load-bearing for the
    // offscreen test harnesses, which caught the frozen-blank page this
    // comment describes.
    const entering = switching && !document.hidden;
    if (entering) {
      elDoc.classList.add("enter", "settle");
      void elDoc.offsetWidth;
      requestAnimationFrame(() => elDoc.classList.remove("enter"));
      setTimeout(() => elDoc.classList.remove("settle"), 240);
    }
    // getBoundingClientRect forces layout, so heading offsets are already real —
    // no need to wait for a frame, which never arrives when the window is
    // offscreen and rAF is throttled.
    // No outline for an HTML file. Its headings are as likely to be a nav bar,
    // a sidebar or a footer as they are the document's sections — a saved page
    // with a three-heading article gave a seven-row contents panel — and there
    // is no way to tell which is which from the markup.
    rail.update(elDoc, !isHtml);
    // The find bar's ranges point into the document that was just replaced.
    find.refresh();
    // Diagrams draw asynchronously; when the last one lands (still current)
    // the module calls onSettled, which re-reads the outline — a diagram
    // changes the height of the page, so the offsets above go stale. Same
    // gating as the synchronous call: no outline for an HTML file.
    diagrams.draw({
      isCurrent: () => token === renderToken,
      onSettled: () => rail.update(elDoc, !isHtml),
    });
  }

  // --- focus, so the app knows when a keystroke is ours ----------------------

  /* The chrome's plain-key shortcuts (j, k, n, /, esc) have to stand down while
     the find bar has focus, and Swift cannot see inside the page — so the page
     reports it. Focus, not the first keystroke: the keystroke is the one that
     would have been swallowed. */
  const TEXT_ENTRY = 'input:not([type="checkbox"]), textarea, [contenteditable="true"]';
  const reportFocus = (focused) => post({ action: "pageFocus", focused });
  const inputHasFocus = () => {
    const node = document.activeElement;
    return !!node && node.nodeType === 1 && node.matches(TEXT_ENTRY);
  };
  document.addEventListener("focusin", (e) => {
    const node = e.target;
    reportFocus(!!node && node.nodeType === 1 && node.matches(TEXT_ENTRY));
  });
  document.addEventListener("focusout", () => reportFocus(false));

  /* focusin/focusout alone leave the flag stuck on. Moving first responder out
     of the web view — clicking the sidebar's search field, a file row, a
     contents row — fires no focusout at all: the find bar keeps DOM focus, so
     Swift went on believing an input had it and every plain key (j k g G n N h l
     / ?) died silently with not even a beep to explain why.
     The window's own blur is the event that does fire, so it is what stands
     the flag down; window focus puts back whatever is true then. */
  window.addEventListener("blur", () => reportFocus(false));
  window.addEventListener("focus", () => reportFocus(inputHasFocus()));
  /* And once now, so a page that has just loaded re-syncs Swift's copy: ⌥⌘R
     (reloadFromOrigin) sends no message of its own, so without this a reload with
     the find bar open would leave the flag true for good. */
  reportFocus(inputHasFocus());

  // --- moving about, for the chrome's keyboard shortcuts ---------------------

  /**
   * Half the window, so a page turn always leaves half a screen of overlap.
   *
   * `KEYBOARD_SCROLL_BEHAVIOR`, so it jumps. Two reasons. A smooth `scrollBy`
   * retargets from wherever the running animation has got to, so pressing `j`
   * five times quickly covers less ground than five presses; and the reader is
   * turning a page, not being taken somewhere, so there is nothing to follow
   * with the eye. Mouse-driven heading jumps do animate — see the rail —
   * because there the distance is the point.
   *
   * `"auto"` would not do: it inherits `scroll-behavior: smooth` from the
   * stylesheet rather than overriding it. See ./motion.js.
   */
  function scrollHalfPage(direction) {
    window.scrollBy({
      top: (direction * window.innerHeight) / 2,
      behavior: KEYBOARD_SCROLL_BEHAVIOR,
    });
  }

  /**
   * The end of the document (+1) or its start (-1). A jump, for the same reason:
   * animating the whole length of a long document is a wait, not a transition.
   */
  function scrollToEdge(direction) {
    const bottom = document.documentElement.scrollHeight;
    window.scrollTo({
      top: direction > 0 ? bottom : 0,
      behavior: KEYBOARD_SCROLL_BEHAVIOR,
    });
  }

  window.mdview = {
    render,
    openFind: find.open,
    /** Escape from the chrome. A no-op unless the find bar is actually open. */
    dismissFind() {
      find.close();
    },
    /** The contents panel in the chrome asks for a jump by index. */
    scrollToHeading(index) {
      rail.jumpTo(Number(index));
    },
    scrollHalfPage(direction) {
      scrollHalfPage(Number(direction));
    },
    scrollToEdge(direction) {
      scrollToEdge(Number(direction));
    },
    /** The next heading (+1) or the previous one (-1). The rail owns the list. */
    stepHeading(direction) {
      rail.step(Number(direction));
    },
    // Exposed so the test harness can exercise the parser and the word count
    // directly — and so it can assert the one decision that no offscreen render
    // can observe: keyboard motion jumps rather than animates. See ./motion.js.
    _internals: {
      splitFrontmatter,
      countWords,
      // Which parser the last render used. This reports the decision, not the
      // behaviour — it is read from the same flag the branch reads, so it catches
      // Swift sending the wrong format and *not* the branch itself going wrong.
      // What catches that is in tools/run-tests.sh: a paragraph markdown would
      // turn into a code block, and a `~~` markdown would strike through.
      format: () => appliedFormat,
      keyboardScrollBehavior: KEYBOARD_SCROLL_BEHAVIOR,
      // What the find bar has found. A custom highlight is in neither computed
      // style nor the selection, so this is the only way to see it.
      findState: () => find.state(),
    },
    /** Called by the app when the system appearance changes. */
    refreshDiagrams() {
      const token = renderToken;
      diagrams.draw({
        isCurrent: () => token === renderToken,
        onSettled: () => rail.update(elDoc, appliedFormat !== "html"),
      });
    },
  };
})();

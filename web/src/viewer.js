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
  let diagramPass = 0; // unique ids per mermaid draw pass
  let diagrams = []; // {el, code} for the document on screen

  // gfm covers tables, strikethrough, task lists and autolinks. Footnotes are a
  // GitHub extension on top of that, so they come from a marked plugin.
  marked.use({ gfm: true, breaks: false, pedantic: false });
  marked.use(markedFootnote());

  // --- helpers --------------------------------------------------------------

  const isDark = () => window.matchMedia("(prefers-color-scheme: dark)").matches;

  function escapeHtml(s) {
    return s.replace(
      /[&<>"]/g,
      (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]
    );
  }

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

  function addHeadingAnchors(root) {
    const seen = new Set();
    const headings = "h1:not(.fm-title), h2:not(.sr-only), h3, h4, h5, h6";
    root.querySelectorAll(headings).forEach((h) => {
      if (!h.id) h.id = slug(h.textContent || "", seen);
      const a = document.createElement("a");
      a.className = "anchor";
      a.href = "#" + h.id;
      a.textContent = "#";
      a.setAttribute("aria-hidden", "true");
      h.insertBefore(a, h.firstChild);
    });
  }

  /** Wrap code blocks in a figure, highlight them, pull out mermaid sources. */
  function decorateCode(root) {
    const diagrams = [];
    root.querySelectorAll("pre > code").forEach((code) => {
      const pre = code.parentElement;
      const lang = (code.className.match(/language-([\w+#.\-]+)/) || [, ""])[1];
      const source = code.textContent || "";

      if (lang === "mermaid") {
        const figure = document.createElement("figure");
        figure.className = "diagram";
        const caption = document.createElement("figcaption");
        const label = document.createElement("span");
        label.className = "lang";
        label.textContent = "mermaid";
        caption.appendChild(label);
        const holder = document.createElement("div");
        holder.className = "mermaid";
        figure.appendChild(caption);
        figure.appendChild(holder);
        pre.replaceWith(figure);
        diagrams.push({ el: holder, code: source });
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
      tag.textContent = lang || "text";
      caption.appendChild(tag);
      figure.appendChild(caption);
      figure.appendChild(pre);

      const copy = document.createElement("button");
      copy.className = "copy";
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
    return diagrams;
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
   * A `srcset` is a comma-separated list of `url [descriptor]`, and a URL in it
   * may not contain a comma, so splitting on one is safe.
   */
  function resolveSrcset(value) {
    return value
      .split(",")
      .map((candidate) => {
        const parts = candidate.trim().split(/\s+/);
        if (!parts[0]) return "";
        parts[0] = resolveURL(parts[0]);
        return parts.join(" ");
      })
      .filter(Boolean)
      .join(", ");
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

  // --- mermaid (loaded only when a document actually uses it) --------------

  let mermaidReady = null;

  function ensureMermaid() {
    if (mermaidReady) return mermaidReady;
    mermaidReady = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = "mermaid.js";
      s.onload = resolve;
      s.onerror = () => reject(new Error("could not load mermaid"));
      document.head.appendChild(s);
    });
    return mermaidReady;
  }

  async function drawDiagrams(token) {
    if (!diagrams.length) return;
    const pass = ++diagramPass;
    try {
      await ensureMermaid();
    } catch (e) {
      diagrams.forEach((d) => {
        d.el.className = "error";
        d.el.textContent = e.message;
      });
      return;
    }
    if (token !== renderToken) return;
    // Drive mermaid from the document's own palette so diagrams don't look
    // like they came from a different app.
    const css = getComputedStyle(document.body);
    const cssVar = (name) => css.getPropertyValue(name).trim();
    const palette = readPalette();
    const { accent, text, surface, divider } = palette;
    try {
      window.mermaid.initialize({
        startOnLoad: false,
        securityLevel: "strict",
        theme: "base",
        fontFamily: css.fontFamily,
        flowchart: { curve: "basis", padding: 10, nodeSpacing: 34, rankSpacing: 46 },
        themeVariables: {
          darkMode: isDark(),
          background: "transparent",
          primaryColor: surface,
          primaryTextColor: text,
          primaryBorderColor: accent,
          secondaryColor: surface,
          tertiaryColor: surface,
          lineColor: accent,
          textColor: text,
          nodeBorder: accent,
          clusterBorder: divider,
          edgeLabelBackground: "transparent",
          fontSize: "13px",
        },
      });
    } catch (error) {
      // Never fail silently: a bad token kills every diagram in one go.
      diagrams.forEach((d) => {
        d.el.innerHTML =
          '<div class="error">Mermaid setup: ' +
          escapeHtml(String((error && error.message) || error)) +
          "</div>";
      });
      return;
    }
    for (let i = 0; i < diagrams.length; i++) {
      if (token !== renderToken) return;
      const d = diagrams[i];
      try {
        const out = await window.mermaid.render("mmd-" + pass + "-" + i, d.code);
        if (token !== renderToken) return;
        d.el.innerHTML = out.svg;
        tintDiagram(d.el, palette);
      } catch (e) {
        d.el.innerHTML =
          '<div class="error">Mermaid: ' + escapeHtml(String((e && e.message) || e)) + "</div>";
      }
    }
    // Diagrams change the height of the page, so the outline's offsets are stale.
    if (token === renderToken) rail.update(elDoc);
  }

  /**
   * Resolve the theme tokens to plain opaque rgb() strings for mermaid.
   *
   * Two things get in the way. getComputedStyle leaves color-mix() unresolved,
   * and the Vellum and Colophon themes are built from it; and once resolved,
   * WebKit reports colours as `color(srgb …)`, which mermaid's colour parser
   * rejects outright. So each token is painted onto a 1×1 canvas over the page
   * background and read back as bytes — which also flattens the semi-transparent
   * tokens into what the reader actually sees.
   */
  function readPalette() {
    const probe = document.createElement("span");
    probe.style.display = "none";
    document.body.appendChild(probe);
    const canvas = document.createElement("canvas");
    canvas.width = 1;
    canvas.height = 1;
    const ctx = canvas.getContext("2d", { willReadFrequently: true });

    const computed = (token) => {
      probe.style.color = "";
      probe.style.color = `var(${token})`;
      return getComputedStyle(probe).color;
    };

    const flatten = (token, base, fallback) => {
      const value = computed(token);
      if (!value || !ctx) return fallback;
      ctx.clearRect(0, 0, 1, 1);
      if (base) {
        ctx.fillStyle = base;
        ctx.fillRect(0, 0, 1, 1);
      }
      ctx.fillStyle = value;
      ctx.fillRect(0, 0, 1, 1);
      const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data;
      return a === 0 ? fallback : `rgb(${r}, ${g}, ${b})`;
    };

    const bg = flatten("--bg", "#ffffff", "#f8f4f4");
    const palette = {
      bg,
      accent: flatten("--accent", bg, "#c28d41"),
      text: flatten("--text", bg, "#2d2b2b"),
      surface: flatten("--surface", bg, "#eae7e7"),
      divider: flatten("--divider", bg, "#d7d3d3"),
    };
    probe.remove();
    return palette;
  }

  /**
   * Mermaid bakes colours into its SVG. The design wants nodes drawn as stroke
   * on nothing — no fills — so the output is repainted from the tokens.
   */
  function tintDiagram(host, palette) {
    const svg = host.querySelector("svg");
    if (!svg) return;
    svg.removeAttribute("height");
    svg.style.maxWidth = "100%";
    svg.style.height = "auto";

    const accent = palette.accent;
    const text = palette.text;

    host.querySelectorAll(".node rect, .node path, .node polygon, .node circle").forEach((el) => {
      el.setAttribute("rx", "4");
      el.setAttribute("ry", "4");
      el.style.fill = "transparent";
      el.style.stroke = accent;
      el.style.strokeWidth = "1px";
    });
    host
      .querySelectorAll(
        ".nodeLabel, .nodeLabel *, .node foreignObject div, .node text, .node tspan"
      )
      .forEach((el) => {
        el.style.color = text;
        el.style.fill = text;
        el.style.background = "transparent";
      });
    host.querySelectorAll(".edgePath path, .flowchart-link, .edgePaths path").forEach((el) => {
      el.style.stroke = accent;
      el.style.fill = "none";
    });
    host.querySelectorAll("marker path, marker polygon, .arrowheadPath").forEach((el) => {
      el.style.fill = accent;
      el.style.stroke = accent;
    });
    host.querySelectorAll(".edgeLabel, .edgeLabel *").forEach((el) => {
      el.style.background = "transparent";
      el.style.backgroundColor = "transparent";
      el.style.color = text;
      el.style.fill = text;
      el.style.fontStyle = "italic";
      el.style.fontSize = "11.5px";
    });
  }

  // --- appearance -----------------------------------------------------------

  const rail = createRail(post);
  elEmpty.addEventListener("click", () => post({ action: "openPanel" }));

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
    const keepY = samePage ? window.scrollY : 0;
    current = { path: payload.path || "", dir: payload.dir || "" };

    if (!payload.path) {
      elDoc.hidden = true;
      elEmpty.hidden = false;
      return;
    }
    elEmpty.hidden = true;
    elDoc.hidden = false;

    if (payload.error) {
      elDoc.innerHTML = '<div class="error">' + escapeHtml(payload.error) + "</div>";
      elDoc.classList.add("ready");
      return;
    }

    applyTheme(payload.theme);
    applySize(payload.size);
    applyAlignment(payload.alignment);
    applyMeasure(payload.measure);

    // Frontmatter is a markdown convention, so an HTML file has none — and
    // splitting one anyway would eat any file that happened to start with `---`.
    const isHtml = payload.format === "html";
    // An unrecognised format renders as markdown, and for an HTML file that is
    // the exact bug this field exists to prevent — so it must not be silent.
    if (payload.format !== "html" && payload.format !== "markdown") {
      console.error("mdview: unknown payload format " + JSON.stringify(payload.format));
    }
    appliedFormat = isHtml ? "html" : "markdown";
    const split = isHtml
      ? { body: payload.markdown || "", fields: [] }
      : splitFrontmatter(payload.markdown || "");

    // The titlebar's word count and the fields for its disclosure. The parser
    // lives here rather than in Swift, which would be two implementations to
    // keep in step. Separators are space and newline — a tab deliberately is not
    // one, so `a\tb` stays one word, and tools/wordcount-tests.js pins it. Title
    // and subtitle are left out, already being on the page as the document's own
    // head.
    const postCount = (words) =>
      post({ action: "frontmatter", words, fields: panelFields(split.fields) });

    // Markdown source is its own prose, so it is counted before anything is
    // parsed — which is why this message has always gone first: a throw in
    // marked or DOMPurify still leaves the titlebar a count and its fields.
    //
    // HTML source is not prose. Counting it raw makes a word of every tag, and
    // counting it cleverly is worse: which elements reach the screen is
    // DOMPurify's decision to make, not one to reimplement here, and a word
    // boundary is the difference between `<li>a</li><li>b</li>` — two words —
    // and `a<em>b</em>c`, which is one. Both answers live in the rendered
    // document and nowhere else, so an HTML count waits for one. Nothing is lost
    // by waiting: an HTML file has no fields, and a render that throws leaves
    // nothing to count anyway.
    if (!isHtml) postCount(countWords(split.body));

    // An HTML file already *is* the markup, so the markdown parser is skipped.
    // What it damages is block-level: HTML is indented, and four spaces of
    // indent is a markdown code block, so nested elements come out as
    // `<pre><code>&lt;p&gt;…`. Text sitting between HTML blocks is parsed as
    // markdown too, so a `~~a~~` there turns into a strikethrough.
    //
    // The sanitiser is not what changes. Both formats go through it, which is
    // why skipping the parser cannot also skip the stripping of <script>.
    const dirty = isHtml ? split.body : marked.parse(split.body);
    elDoc.innerHTML = DOMPurify.sanitize(dirty, { ADD_ATTR: ["target"] });

    // Here, and not further down: innerText is what a reader would select, so it
    // breaks at a block edge and not inside a phrase — the distinction a
    // source-level count cannot make. And it must be read before the decorations
    // below, each of which adds text of its own: a copy button says "Copy", a
    // heading grows an anchor.
    if (isHtml) postCount(countWords(elDoc.innerText || elDoc.textContent || ""));

    if (split.fields.length && payload.showFrontmatter !== false) {
      const firstHeading = elDoc.querySelector("h1");
      const header = frontmatterHeader(split.fields, firstHeading && firstHeading.textContent);
      if (header) elDoc.insertBefore(header, elDoc.firstChild);
    }

    addHeadingAnchors(elDoc);
    decorateAlerts(elDoc);
    diagrams = decorateCode(elDoc);
    wrapTables(elDoc);
    // Must stay after the sanitize above: resolveURL returns scheme-carrying
    // hrefs unchanged, so DOMPurify is what removes `javascript:` ones.
    resolveLocalPaths(elDoc);
    markTaskItems(elDoc);

    // Restore position without animating there.
    const root = document.documentElement;
    const behavior = root.style.scrollBehavior;
    root.style.scrollBehavior = "auto";
    window.scrollTo(0, keepY);
    requestAnimationFrame(() => {
      root.style.scrollBehavior = behavior;
    });

    elDoc.classList.add("ready");
    // getBoundingClientRect forces layout, so heading offsets are already real —
    // no need to wait for a frame, which never arrives when the window is
    // offscreen and rAF is throttled.
    rail.update(elDoc);
    // The find bar's ranges point into the document that was just replaced.
    find.refresh();
    drawDiagrams(token);
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
      // Which parser the last render used. Asserting this is how a test knows
      // the HTML branch was taken, rather than inferring it from the damage
      // markdown would have done.
      format: () => appliedFormat,
      keyboardScrollBehavior: KEYBOARD_SCROLL_BEHAVIOR,
      // What the find bar has found. A custom highlight is in neither computed
      // style nor the selection, so this is the only way to see it.
      findState: () => find.state(),
    },
    /** Called by the app when the system appearance changes. */
    refreshDiagrams() {
      if (diagrams.length) drawDiagrams(renderToken);
    },
  };
})();

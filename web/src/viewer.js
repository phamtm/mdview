/* MDView renderer. Swift hands us {markdown, path, dir}; we turn it into DOM,
   post-process it, and keep the scroll position stable across live reloads.

   Bundled by web/build.mjs into Resources/bundle.js. */
import { marked } from "marked";
import markedFootnote from "marked-footnote";
import hljs from "highlight.js/lib/common";
import DOMPurify from "dompurify";
import { createRail } from "./rail.js";

(function () {
  "use strict";

  const bridge =
    window.webkit && window.webkit.messageHandlers ? window.webkit.messageHandlers.mdview : null;
  const post = (msg) => {
    if (bridge) bridge.postMessage(msg);
  };

  const elDoc = document.getElementById("doc");
  const elEmpty = document.getElementById("empty");
  const elBar = document.getElementById("findbar");
  const elFind = document.getElementById("findinput");

  let current = { path: "", dir: "" };
  let renderToken = 0; // guards async mermaid work against a newer render
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

  // --- frontmatter ----------------------------------------------------------

  /** Split a leading `---` (YAML) or `+++` (TOML) block off the document. */
  function splitFrontmatter(text) {
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
  function countWords(text) {
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
   * Builds the header shown above the document: the title, and a subtitle if
   * there is one. The remaining fields go to the titlebar disclosure — showing
   * them in both places at once just duplicates the metadata.
   * Values are set as text, never HTML.
   */
  function frontmatterHeader(fields, firstBodyHeading) {
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

  function resolveLocalPaths(root) {
    root.querySelectorAll("img[src]").forEach((img) => {
      img.src = resolveURL(img.getAttribute("src"));
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
      // Never fail silently: a bad token used to kill every diagram at once.
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

    const split = splitFrontmatter(payload.markdown || "");

    // The titlebar disclosure is drawn by Swift, but the parser lives here —
    // duplicating it there would be two implementations to keep in step.
    //
    // Sent before anything is rendered, and it depends on nothing below: a throw
    // in marked or DOMPurify would otherwise leave the titlebar with no count and
    // no fields at all, which is a failure mode Swift-local counting never had.
    post({
      action: "frontmatter",
      // The titlebar's word count, of the body only. Swift used to count the raw
      // file, frontmatter included; it cannot count the body without a second
      // frontmatter parser, which is the thing this message exists to avoid.
      // Separators are space and newline, exactly as Swift had them — a tab is
      // deliberately not one, so `a\tb` stays one word. tools/wordcount-tests.js
      // pins that.
      words: countWords(split.body),
      // Title and subtitle are already on the page as the document's own head.
      fields: split.fields
        .filter(([name]) => !DOCUMENT_FIELDS.includes(name.toLowerCase()))
        .map(([name, value]) => ({
          name,
          values: Array.isArray(value) ? value : [value],
          isList: Array.isArray(value),
        })),
    });

    const dirty = marked.parse(split.body);
    elDoc.innerHTML = DOMPurify.sanitize(dirty, { ADD_ATTR: ["target"] });

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
    drawDiagrams(token);
  }

  // --- find bar ------------------------------------------------------------

  function openFind() {
    elBar.hidden = false;
    elFind.focus();
    elFind.select();
  }

  function closeFind() {
    elBar.hidden = true;
    elBar.classList.remove("nomatch");
    const sel = window.getSelection();
    if (sel) sel.removeAllRanges();
    window.focus();
  }

  function step(backwards) {
    const q = elFind.value;
    if (!q) {
      elBar.classList.remove("nomatch");
      return;
    }
    const found = window.find(q, false, backwards, true, false, false, false);
    elBar.classList.toggle("nomatch", !found);
  }

  elFind.addEventListener("input", () => step(false));
  elFind.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      step(e.shiftKey);
    } else if (e.key === "Escape") {
      e.preventDefault();
      closeFind();
    }
  });
  document.getElementById("findnext").addEventListener("click", () => step(false));
  document.getElementById("findprev").addEventListener("click", () => step(true));
  document.getElementById("findclose").addEventListener("click", closeFind);
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape" && !elBar.hidden) closeFind();
  });

  elEmpty.addEventListener("click", () => post({ action: "openPanel" }));

  window.mdview = {
    render,
    openFind,
    /** The contents panel in the chrome asks for a jump by index. */
    scrollToHeading(index) {
      rail.jumpTo(Number(index));
    },
    // Exposed so the test harness can exercise the parser and the word count
    // directly.
    _internals: { splitFrontmatter, parseFields, countWords },
    /** Called by the app when the system appearance changes. */
    refreshDiagrams() {
      if (diagrams.length) drawDiagrams(renderToken);
    },
  };
})();

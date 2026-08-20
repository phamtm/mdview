/* MDView renderer. Swift hands us {markdown, path, dir}; we turn it into DOM,
   post-process it, and keep the scroll position stable across live reloads.

   Bundled by web/build.mjs into Resources/bundle.js. */
import { marked } from "marked";
import markedFootnote from "marked-footnote";
import hljs from "highlight.js/lib/common";
import DOMPurify from "dompurify";

(function () {
  "use strict";

  const bridge = window.webkit && window.webkit.messageHandlers
    ? window.webkit.messageHandlers.mdview : null;
  const post = (msg) => { if (bridge) bridge.postMessage(msg); };

  const elDoc = document.getElementById("doc");
  const elEmpty = document.getElementById("empty");
  const elBar = document.getElementById("findbar");
  const elFind = document.getElementById("findinput");

  let current = { path: "", dir: "" };
  let renderToken = 0;    // guards async mermaid work against a newer render
  let diagramPass = 0;    // unique ids per mermaid draw pass
  let diagrams = [];      // {el, code} for the document on screen

  // gfm covers tables, strikethrough, task lists and autolinks. Footnotes are a
  // GitHub extension on top of that, so they come from a marked plugin.
  marked.use({ gfm: true, breaks: false, pedantic: false });
  marked.use(markedFootnote());

  if (localStorage.getItem("serif") === "1") document.body.classList.add("serif");

  // --- helpers --------------------------------------------------------------

  const isDark = () => window.matchMedia("(prefers-color-scheme: dark)").matches;

  function escapeHtml(s) {
    return s.replace(/[&<>"]/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }

  function encodeSegments(path) {
    return path.split("/").map((seg) => {
      try { return encodeURIComponent(decodeURIComponent(seg)); }
      catch (_) { return encodeURIComponent(seg); }
    }).join("/");
  }

  /** Turn a markdown-relative path into something WebKit can load. */
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
    let base = text.toLowerCase().trim()
      .replace(/[^\w\s\-]/g, "")
      .replace(/\s+/g, "-") || "section";
    let id = base, n = 1;
    while (seen.has(id)) { id = base + "-" + (++n); }
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

  function unquote(value) {
    return value.trim().replace(/,$/, "").trim().replace(/^(['"])([\s\S]*)\1$/, "$2").trim();
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
      if (!match) continue;                       // indented sub-keys, etc.
      const key = match[1];
      const value = match[2].trim();

      if (!value) {
        const items = [];
        while (i + 1 < lines.length && /^\s*-\s+/.test(lines[i + 1])) {
          items.push(unquote(lines[++i].replace(/^\s*-\s+/, "")));
        }
        if (items.length) fields.push([key, items.filter(Boolean)]);
        continue;                                 // a bare key holds a nested map
      }
      if (/^\[[\s\S]*\]$/.test(value)) {
        fields.push([key, value.slice(1, -1).split(",").map(unquote).filter(Boolean)]);
      } else {
        fields.push([key, unquote(value)]);
      }
    }
    return fields;
  }

  /** Builds the header shown above the document. Values are set as text, never HTML. */
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

    if (rest.length) {
      const list = document.createElement("dl");
      list.className = "fm-fields";
      for (const [key, value] of rest) {
        const dt = document.createElement("dt");
        dt.textContent = key;
        const dd = document.createElement("dd");
        if (Array.isArray(value)) {
          for (const item of value) {
            const pill = document.createElement("span");
            pill.className = "fm-pill";
            pill.textContent = item;
            dd.appendChild(pill);
          }
        } else {
          dd.textContent = value;
        }
        list.appendChild(dt);
        list.appendChild(dd);
      }
      header.appendChild(list);
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
      const match = /^\s*\[!(note|tip|important|warning|caution)\]\s*/i.exec(first.textContent || "");
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
        const holder = document.createElement("div");
        holder.className = "mermaid";
        pre.replaceWith(holder);
        diagrams.push({ el: holder, code: source });
        return;
      }

      const figure = document.createElement("figure");
      figure.className = "code";
      pre.replaceWith(figure);
      figure.appendChild(pre);

      if (lang) {
        const tag = document.createElement("span");
        tag.className = "lang";
        tag.textContent = lang;
        figure.appendChild(tag);
      }

      const copy = document.createElement("button");
      copy.className = "copy";
      copy.type = "button";
      copy.textContent = "Copy";
      copy.addEventListener("click", () => {
        post({ action: "copyText", text: source });
        copy.textContent = "Copied";
        copy.classList.add("done");
        setTimeout(() => { copy.textContent = "Copy"; copy.classList.remove("done"); }, 1400);
      });
      figure.appendChild(copy);

      if (lang && hljs.getLanguage(lang)) {
        try { hljs.highlightElement(code); } catch (_) { /* leave plain */ }
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
      if (href && href.startsWith("#")) return;   // in-page anchor, leave alone
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
      diagrams.forEach((d) => { d.el.className = "error"; d.el.textContent = e.message; });
      return;
    }
    if (token !== renderToken) return;
    // Drive mermaid from the document's own palette so diagrams don't look
    // like they came from a different app.
    const css = getComputedStyle(document.body);
    const cssVar = (name) => css.getPropertyValue(name).trim();
    window.mermaid.initialize({
      startOnLoad: false,
      securityLevel: "strict",
      theme: "base",
      fontFamily: css.fontFamily,
      themeVariables: {
        darkMode: isDark(),
        background: cssVar("--bg"),
        primaryColor: cssVar("--bg-soft"),
        primaryTextColor: cssVar("--fg"),
        primaryBorderColor: cssVar("--rule-strong"),
        secondaryColor: cssVar("--bg-code"),
        tertiaryColor: cssVar("--bg-soft"),
        lineColor: cssVar("--fg-faint"),
        textColor: cssVar("--fg"),
        mainBkg: cssVar("--bg-soft"),
        nodeBorder: cssVar("--rule-strong"),
        clusterBkg: cssVar("--bg-code"),
        clusterBorder: cssVar("--rule-soft"),
        edgeLabelBackground: cssVar("--bg"),
        fontSize: "14px",
      },
    });
    for (let i = 0; i < diagrams.length; i++) {
      if (token !== renderToken) return;
      const d = diagrams[i];
      try {
        const out = await window.mermaid.render("mmd-" + pass + "-" + i, d.code);
        if (token !== renderToken) return;
        d.el.innerHTML = out.svg;
      } catch (e) {
        d.el.innerHTML = '<div class="error">Mermaid: ' +
          escapeHtml(String((e && e.message) || e)) + "</div>";
      }
    }
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

    const split = splitFrontmatter(payload.markdown || "");
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
    resolveLocalPaths(elDoc);
    markTaskItems(elDoc);

    // Restore position without animating there.
    const root = document.documentElement;
    const behavior = root.style.scrollBehavior;
    root.style.scrollBehavior = "auto";
    window.scrollTo(0, keepY);
    requestAnimationFrame(() => { root.style.scrollBehavior = behavior; });

    elDoc.classList.add("ready");
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
    if (!q) { elBar.classList.remove("nomatch"); return; }
    const found = window.find(q, false, backwards, true, false, false, false);
    elBar.classList.toggle("nomatch", !found);
  }

  elFind.addEventListener("input", () => step(false));
  elFind.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); step(e.shiftKey); }
    else if (e.key === "Escape") { e.preventDefault(); closeFind(); }
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
    // Exposed so the test harness can exercise the parser directly.
    _internals: { splitFrontmatter, parseFields },
    /** Called by the app when the system appearance changes. */
    refreshDiagrams() {
      if (diagrams.length) drawDiagrams(renderToken);
    },
    toggleFont() {
      const on = document.body.classList.toggle("serif");
      localStorage.setItem("serif", on ? "1" : "0");
    },
  };
})();

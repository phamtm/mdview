/* Mermaid diagrams: the figure that replaces a ```mermaid block, the library
   injected on demand, and the drawing pass that repaints mermaid's SVG to
   match the app's palette.

   Own module because it is the largest single concern in the page (~350 lines)
   and the only one that is asynchronous against a moving document — a render
   can replace the DOM while a draw is in flight, which is what the isCurrent
   guard threads through every await.
 */

import { escapeHtml } from "./util.js";

const isDark = () => window.matchMedia("(prefers-color-scheme: dark)").matches;

export function createDiagrams() {
  // The library is loaded only when a document actually uses it: ~10x the
  // size of everything else in the bundle, so it ships as its own file and is
  // injected on first draw.
  let libraryReady = null;
  let passCounter = 0; // unique ids per draw pass
  let figures = []; // {el, code} for the document on screen

  /** Called once per render, before any code block is walked. */
  function reset() {
    figures = [];
  }

  /**
   * The figure that replaces one ```mermaid block. The caller swaps it into
   * the DOM while walking code blocks; the holder keeps a reserved height so
   * the page does not jump when the SVG arrives (asynchronously), and fades
   * it in — but only on a page that can animate: a hidden page's clocks do
   * not tick, and the fade would freeze at opacity 0. See viewer.js render().
   */
  function figure(source) {
    const fig = document.createElement("figure");
    fig.className = "diagram";
    const caption = document.createElement("figcaption");
    const label = document.createElement("span");
    label.className = "lang";
    label.setAttribute("data-chrome", "");
    label.textContent = "mermaid";
    caption.appendChild(label);
    const holder = document.createElement("div");
    holder.className = "mermaid";
    holder.style.minHeight = "80px";
    holder.classList.toggle("fade", !document.hidden);
    fig.appendChild(caption);
    fig.appendChild(holder);
    figures.push({ el: holder, code: source });
    return fig;
  }

  function ensureMermaid() {
    if (libraryReady) return libraryReady;
    libraryReady = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = "mermaid.js";
      s.onload = resolve;
      s.onerror = () => reject(new Error("could not load mermaid"));
      document.head.appendChild(s);
    });
    return libraryReady;
  }

  /**
   * Draws every figure collected during this render, in order.
   *
   * `isCurrent` is consulted between awaits; when a newer render has replaced
   * the document, the pass abandons rather than drawing into nodes that are
   * gone. `onSettled` runs once after the last diagram lands, still current —
   * diagrams change the height of the page, so the caller re-reads whatever
   * geometry depends on it there (the outline's offsets).
   *
   * Never fails silently: an error marks every diagram it kills, in place.
   */
  async function draw({ isCurrent = () => true, onSettled } = {}) {
    if (!figures.length) return;
    const pass = ++passCounter;
    try {
      await ensureMermaid();
    } catch (e) {
      figures.forEach((d) => {
        d.el.className = "error";
        d.el.textContent = e.message;
      });
      return;
    }
    if (!isCurrent()) return;
    // Drive mermaid from the document's own palette so diagrams don't look
    // like they came from a different app.
    const css = getComputedStyle(document.body);
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
      // A bad token kills every diagram in one go.
      figures.forEach((d) => {
        d.el.innerHTML =
          '<div class="error">Mermaid setup: ' +
          escapeHtml(String((error && error.message) || error)) +
          "</div>";
      });
      return;
    }
    for (let i = 0; i < figures.length; i++) {
      if (!isCurrent()) return;
      const d = figures[i];
      try {
        const out = await window.mermaid.render("mmd-" + pass + "-" + i, d.code);
        if (!isCurrent()) return;
        d.el.innerHTML = out.svg;
        tint(d.el, palette);
      } catch (e) {
        d.el.innerHTML =
          '<div class="error">Mermaid: ' + escapeHtml(String((e && e.message) || e)) + "</div>";
      }
    }
    if (isCurrent() && onSettled) onSettled();
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
  function tint(host, palette) {
    const svg = host.querySelector("svg");
    if (!svg) return;
    svg.removeAttribute("height");
    svg.style.maxWidth = "100%";
    svg.style.height = "auto";
    host.style.minHeight = "";

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

  return { reset, figure, draw };
}

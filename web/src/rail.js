/* The tick rail: a passive position indicator down the left of the document.
 *
 * Ticks are sized by heading level and swell under the pointer; hovering one
 * names its section. Clicking jumps. The rail is an indicator only — the
 * navigable outline is a panel in the chrome, and this reports the headings to
 * it.
 */

import { KEYBOARD_SCROLL_BEHAVIOR, smoothBehavior } from "./motion.js";

const SNIPPET_CHARS = 116;
/** Tick length by heading level, before any hover swell. */
const TICK_WIDTH = { 1: 26, 2: 17, 3: 11 };
const SCROLL_OFFSET = 56;

function element(tag, className) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  return node;
}

/**
 * @param {(message: object) => void} post sends the outline, and the current
 *   section as it changes, to the app.
 */
export function createRail(post) {
  /** Whether the document being shown has an outline at all. See update(). */
  let outlined = true;
  const zone = element("div", "rail-zone");
  const ticks = element("div", "rail-ticks");
  const card = element("div", "rail-card");
  card.hidden = true;
  zone.append(ticks, card);
  document.body.appendChild(zone);

  let headings = [];
  let current = -1;
  let hovered = -1;

  /**
   * Ticks nearest the pointer grow, with a gaussian falloff, so the rail reads
   * as one object responding rather than a row of independent marks.
   */
  function paintTicks() {
    const marks = ticks.children;
    for (let i = 0; i < marks.length; i++) {
      const heading = headings[i];
      const base = TICK_WIDTH[heading.level] || TICK_WIDTH[3];
      const distance = hovered < 0 ? 99 : Math.abs(i - hovered);
      const swell = Math.exp(-(distance * distance) / 2.6);
      const bar = marks[i].firstChild;
      bar.style.width = `${Math.round(base + swell * 18)}px`;
      bar.style.height = `${(2 + swell * 1.4).toFixed(1)}px`;
      bar.classList.toggle("current", i === current);
      bar.style.opacity = i === current ? "1" : String((24 + swell * 46) / 100);
    }
  }

  /** Where `index` lands: the heading, with room above it to read as a heading. */
  function landingFor(index) {
    return Math.max(0, headings[index].top - SCROLL_OFFSET);
  }

  /**
   * Animated by default, for a click: that is one jump at a time and worth
   * following with the eye. `step` passes `KEYBOARD_SCROLL_BEHAVIOR` instead,
   * which is "instant" — a keyboard walk is repeated, and a smooth scroll still
   * in flight makes the next press re-aim from wherever the animation had got
   * to rather than from the heading just landed on.
   *
   * Under prefers-reduced-motion the default is instant too: a glide is exactly
   * what the reader asked not to be given. See ./motion.js.
   *
   * Note "auto" is not the way to ask for that: it inherits `scroll-behavior`
   * from the stylesheet, which is `smooth`, rather than overriding it. See
   * ./motion.js.
   */
  function jumpTo(index, behavior = smoothBehavior()) {
    if (!headings[index]) return;
    window.scrollTo({ top: landingFor(index), behavior });
  }

  function showCard(index) {
    const heading = headings[index];
    if (!heading) return;
    card.innerHTML = "";
    const title = element("div", "rail-card-title");
    title.textContent = heading.title;
    const snippet = element("div", "rail-card-snippet");
    snippet.textContent = heading.snippet;
    card.append(title, snippet);
    card.hidden = false;

    // Position against the zone, which is what the card is absolute to.
    // offsetTop would be relative to the ticks container instead, which is
    // itself centred in the zone — that put the card up at the window's top.
    const mark = ticks.children[index];
    const zoneBox = zone.getBoundingClientRect();
    const markBox = mark.getBoundingClientRect();
    const centre = markBox.top + markBox.height / 2 - zoneBox.top;
    // Keep it on screen for headings near either end.
    const half = card.offsetHeight / 2;
    const lowest = zoneBox.height - half - 12;
    card.style.top = `${Math.min(Math.max(centre, half + 12), Math.max(lowest, half + 12))}px`;
  }

  function hideCard() {
    card.hidden = true;
  }

  zone.addEventListener("mouseleave", () => {
    hovered = -1;
    hideCard();
    paintTicks();
  });

  /** Reads the outline out of the rendered document. */
  function readOutline(root) {
    // Not `:not(.sr-only)`: the heading to leave out is the one the viewer added,
    // not one whose class happens to match. See markChrome() in viewer.js.
    const selector = "h1:not([data-chrome]), h2:not([data-chrome]), h3:not([data-chrome])";
    return Array.from(root.querySelectorAll(selector)).map((node) => {
      let next = node.nextElementSibling;
      while (next && !/^(P|UL|OL|BLOCKQUOTE)$/.test(next.tagName)) next = next.nextElementSibling;
      const text = ((next && next.textContent) || "").trim();
      return {
        level: Number(node.tagName.slice(1)),
        title: (node.textContent || "").replace(/^#/, "").trim(),
        snippet: text
          ? text.slice(0, SNIPPET_CHARS) + (text.length > SNIPPET_CHARS ? "…" : "")
          : "",
        top: node.getBoundingClientRect().top + window.scrollY,
      };
    });
  }

  function buildTicks() {
    ticks.innerHTML = "";
    headings.forEach((_, index) => {
      const slot = element("div", "rail-tick");
      slot.appendChild(element("div", "rail-bar"));
      slot.addEventListener("mouseenter", () => {
        hovered = index;
        paintTicks();
        showCard(index);
      });
      slot.addEventListener("mouseleave", hideCard);
      slot.addEventListener("click", () => jumpTo(index));
      ticks.appendChild(slot);
    });
  }

  function trackScroll() {
    let next = headings.length ? 0 : -1;
    headings.forEach((heading, index) => {
      if (heading.top - 120 <= window.scrollY) next = index;
    });
    if (next !== current) {
      current = next;
      paintTicks();
      // The panel in the chrome highlights the same section.
      post({ action: "outlinePosition", index: current });
    }
  }

  window.addEventListener("scroll", trackScroll, { passive: true });
  // A window drag fires resize continuously, and each pass re-measures every
  // heading — a full layout read per event. Coalesced to one per frame.
  let resizePending = false;
  window.addEventListener("resize", () => {
    if (resizePending) return;
    resizePending = true;
    requestAnimationFrame(() => {
      resizePending = false;
      headings = outlined ? readOutline(document.getElementById("doc")) : [];
      trackScroll();
    });
  });

  return {
    /**
     * Called after every render.
     *
     * `hasOutline` false means this document has no outline of its own — an HTML
     * file, whose headings are as likely to be a nav bar or a page footer as
     * they are sections. The rail hides and the contents panel is told there is
     * nothing, rather than being left showing the last document's headings.
     */
    update(root, hasOutline = true) {
      outlined = hasOutline;
      headings = hasOutline ? readOutline(root) : [];
      zone.hidden = !hasOutline || headings.length < 2;
      buildTicks();
      current = -1;
      trackScroll();
      paintTicks();
      post({
        action: "outline",
        headings: headings.map(({ level, title }) => ({ level, title })),
      });
    },

    /** Called by the app when a row in the contents panel is clicked. */
    jumpTo,

    /**
     * The heading after the reader's position (+1) or before it (-1).
     *
     * Measured against where `jumpTo` would land, so pressing `n` twice moves
     * twice; the 1px slack absorbs a fractional scroll position. Uses the same
     * list the rail and the contents panel draw from, so all three agree on what
     * a heading is.
     *
     * At either end it does nothing — "nothing", not "the nearest heading":
     * past the final heading, aiming at the last one is a jump *backwards*, which
     * throws the reader up the page instead of leaving them where they are.
     */
    step(direction) {
      if (!headings.length) return;
      const y = window.scrollY;
      let target = -1;
      if (direction > 0) {
        target = headings.findIndex((_, index) => landingFor(index) > y + 1);
      } else {
        headings.forEach((_, index) => {
          if (landingFor(index) < y - 1) target = index;
        });
      }
      if (target < 0) return;
      jumpTo(target, KEYBOARD_SCROLL_BEHAVIOR);
    },
  };
}

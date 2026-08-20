/* The contents rail: a column of tick marks down the left of the document.
 *
 * Three states, per the design:
 *   collapsed — ticks only, sized by heading level, swelling under the pointer
 *   hovered   — the tick under the pointer names its section in a card
 *   expanded  — after dwelling in the rail zone, the full contents panel; the
 *               pin keeps it open and the column shifts right to make room
 */

const DWELL_MS = 3000;
const SNIPPET_CHARS = 116;
/** Tick length by heading level, before any hover swell. */
const TICK_WIDTH = { 1: 26, 2: 17, 3: 11 };
const SCROLL_OFFSET = 56;

function element(tag, className) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  return node;
}

export function createRail() {
  const zone = element("div", "rail-zone");
  const ticks = element("div", "rail-ticks");
  const card = element("div", "rail-card");
  const panel = element("div", "rail-panel");
  card.hidden = true;
  panel.hidden = true;
  zone.append(ticks, card, panel);
  document.body.appendChild(zone);

  let headings = [];
  let current = -1;
  let hovered = -1;
  let expanded = false;
  let pinned = false;
  let dwellTimer = null;

  // --- geometry -------------------------------------------------------------

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

  function paintPanel() {
    const rows = panel.querySelectorAll(".rail-row");
    rows.forEach((row, index) => row.classList.toggle("current", index === current));
  }

  function jumpTo(index) {
    const heading = headings[index];
    if (!heading) return;
    window.scrollTo({ top: Math.max(0, heading.top - SCROLL_OFFSET), behavior: "smooth" });
  }

  // --- states ---------------------------------------------------------------

  function setExpanded(next) {
    expanded = next;
    panel.hidden = !next;
    ticks.hidden = next;
    if (next) hideCard();
    zone.classList.toggle("expanded", next);
    document.body.classList.toggle("rail-pinned", next && pinned);
  }

  function showCard(index) {
    const heading = headings[index];
    if (!heading || expanded) return;
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

  zone.addEventListener("mouseenter", () => {
    clearTimeout(dwellTimer);
    // Dwelling, not passing through: the rail only opens if you stay in it.
    dwellTimer = setTimeout(() => setExpanded(true), DWELL_MS);
  });

  zone.addEventListener("mouseleave", () => {
    clearTimeout(dwellTimer);
    hovered = -1;
    hideCard();
    paintTicks();
    if (!pinned) setExpanded(false);
  });

  // --- building -------------------------------------------------------------

  /** Reads the outline out of the rendered document. */
  function readOutline(root) {
    const selector = "h1:not(.sr-only), h2:not(.sr-only), h3:not(.sr-only)";
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

  function buildPanel() {
    panel.innerHTML = "";
    const head = element("div", "rail-panel-head");
    const label = element("div", "rail-panel-label");
    label.textContent = "Contents";
    const pin = element("button", "rail-pin");
    pin.type = "button";
    pin.title = "Keep open";
    pin.innerHTML =
      '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
      'stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">' +
      '<path d="M12 17v5"></path>' +
      '<path d="M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 ' +
      "0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 " +
      '2 0 0 0 0 4 1 1 0 0 1 1 1z"></path></svg>';
    pin.addEventListener("click", () => {
      pinned = !pinned;
      pin.classList.toggle("pinned", pinned);
      document.body.classList.toggle("rail-pinned", pinned);
      if (!pinned) setExpanded(false);
    });
    pin.classList.toggle("pinned", pinned);
    head.append(label, pin);
    panel.appendChild(head);

    headings.forEach((heading, index) => {
      const row = element("div", `rail-row level-${heading.level}`);
      row.appendChild(element("span", "rail-row-tick"));
      const title = element("span", "rail-row-title");
      title.textContent = heading.title;
      row.appendChild(title);
      row.addEventListener("click", () => {
        jumpTo(index);
        if (!pinned) setExpanded(false);
      });
      panel.appendChild(row);
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
      paintPanel();
    }
  }

  window.addEventListener("scroll", trackScroll, { passive: true });
  window.addEventListener("resize", () => {
    headings = readOutline(document.getElementById("doc"));
    trackScroll();
  });

  return {
    /** Called after every render. */
    update(root) {
      headings = readOutline(root);
      zone.hidden = headings.length < 2;
      buildTicks();
      buildPanel();
      current = -1;
      trackScroll();
      paintTicks();
    },
  };
}

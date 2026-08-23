/* Where the reader is, kept so nothing can lose it.

   Three concerns that all answer the same question:

   - Within a session, each document's exact scroll offset, so leaving a file
     and coming back lands on the same pixel.
   - Across launches, Swift keeps its own map; it arrives as payload.resumeY
     and is used only when the page has no memory of its own.
   - A live reload must not drift: restoring a raw pixel offset against
     re-laid-out content slides the reader off their sentence when anything
     above the viewport changed. Anchoring to the nearest heading above,
     plus the distance into that section, survives exactly those edits.

   Also owns reporting settled positions to Swift (debounced), which is what
   makes the cross-launch half possible at all.
 */

/** @param {(message: object) => void} post sends positions to the app. */
export function createReadingPosition(post) {
  /** Exact offsets for this session, by path, most recent first-out. */
  const session = new Map();
  /** Debounce timer for the position reports. */
  let reportTimer = 0;

  /**
   * Records where the reader was in the document being left. Call before
   * switching, while the old DOM — and its scroll offset — still stand.
   */
  function depart(path) {
    if (!path) return;
    session.set(path, window.scrollY);
    // Bounded: a long session visiting hundreds of files should not grow it.
    if (session.size > 64) session.delete(session.keys().next().value);
  }

  /**
   * Where to land in `path`: this session's memory first (pixel-exact for the
   * DOM it measured), else Swift's cross-launch position, else the top.
   */
  function arrivalY(path, resumeY) {
    if (!path) return 0;
    if (session.has(path)) return session.get(path);
    const resume = Number(resumeY);
    return Number.isFinite(resume) && resume > 0 ? resume : 0;
  }

  /**
   * Where the reader is, as an anchor rather than a pixel offset.
   *
   * The nearest heading above the viewport plus the distance into its section
   * is stable under edits above the fold. Also captured here: which <details>
   * are open. They are the one interactive state in a rendered document, and
   * a full innerHTML replacement resets them, which made every save fold the
   * section the reader had opened.
   */
  function captureAnchor(root) {
    const headings = root.querySelectorAll("h1, h2, h3, h4, h5, h6");
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
    root.querySelectorAll("details").forEach((d, at) => {
      if (d.open) open.push(at);
    });
    return { index, offset, open };
  }

  /** Re-opens the <details> the previous DOM had open, by their position. */
  function restoreDetails(root, open) {
    if (!open.length) return;
    const details = root.querySelectorAll("details");
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
  function restoreScroll(root, anchor) {
    const headings = root.querySelectorAll("h1, h2, h3, h4, h5, h6");
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

  /**
   * Tells Swift where the reader settles, so the position survives a relaunch
   * (it comes back as payload.resumeY). Only has to be roughly current, hence
   * the debounce; within a session `depart`/`arrivalY` are exact without it.
   *
   * @param {() => string} getPath the path of the document on screen now.
   */
  function reportWhile(getPath) {
    window.addEventListener(
      "scroll",
      () => {
        if (!getPath()) return;
        clearTimeout(reportTimer);
        reportTimer = setTimeout(() => {
          const path = getPath();
          if (!path) return;
          post({ action: "scrollPosition", path, y: Math.round(window.scrollY) });
        }, 350);
      },
      { passive: true }
    );
  }

  return { depart, arrivalY, captureAnchor, restoreDetails, restoreScroll, reportWhile };
}

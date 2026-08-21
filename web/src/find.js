/* The in-page find bar.
 *
 * window.find() is non-standard but is what WebKit gives us; it moves the real
 * selection, so the match is visible without highlighting machinery of our own.
 */

/** Owns the bar's elements and its keys; returns the two commands the app sends. */
export function createFindBar() {
  const bar = document.getElementById("findbar");
  const field = document.getElementById("findinput");

  function open() {
    bar.hidden = false;
    field.focus();
    field.select();
  }

  function close() {
    // Blur before hiding, so the focusout handler always fires and the app's
    // plain-key shortcuts come back. Hiding a focused element ought to blur it
    // anyway, but if it ever did not, every plain key would stay disabled.
    field.blur();
    bar.hidden = true;
    bar.classList.remove("nomatch");
    const selection = window.getSelection();
    if (selection) selection.removeAllRanges();
    window.focus();
  }

  function step(backwards) {
    const query = field.value;
    if (!query) {
      bar.classList.remove("nomatch");
      return;
    }
    const found = window.find(query, false, backwards, true, false, false, false);
    bar.classList.toggle("nomatch", !found);
  }

  field.addEventListener("input", () => step(false));
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

  return { open, close };
}

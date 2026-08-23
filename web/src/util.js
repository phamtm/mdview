/* Helpers small enough to share, too small to argue about. */

/**
 * Escapes the four characters that carry meaning inside HTML text, for
 * interpolating untrusted strings into an innerHTML assignment.
 */
export function escapeHtml(s) {
  return s.replace(
    /[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]
  );
}

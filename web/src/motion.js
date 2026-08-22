/* How the keyboard moves the page.
 *
 * One constant, because the trap here is easy to walk back into. `style.css`
 * sets `html { scroll-behavior: smooth }`, and in CSSOM-View `behavior: "auto"`
 * does *not* mean "no animation" — it defers to that computed value. Only
 * `"instant"` overrides it. Passing "auto" from a keyboard handler therefore
 * animates every motion, and because a smooth scroll retargets from wherever
 * the animation has got to, repeated presses lose most of their travel: five
 * rapid `j` presses settled 1334px of the 2000 they asked for, and five rapid
 * `n` presses landed on the second heading instead of the fifth.
 *
 * Mouse-driven jumps deliberately keep the animation — clicking a rail tick or
 * a contents row is one jump the eye can follow — so they use `jumpTo`'s
 * "smooth" default and must not be changed to this.
 *
 * Unless the reader asked the system for reduced motion, in which case every
 * scroll is instant too: `prefers-reduced-motion` is a request not to be moved
 * around, and a smooth glide is exactly that. Keyboard motion needs no switch —
 * it already jumps. Read at call time rather than once at import, so flipping
 * the setting takes effect without a reload.
 */
export const KEYBOARD_SCROLL_BEHAVIOR = "instant";

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

/** What a mouse-driven, eye-followable jump should use right now. */
export function smoothBehavior() {
  return reduceMotion.matches ? KEYBOARD_SCROLL_BEHAVIOR : "smooth";
}

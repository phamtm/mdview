/* The two wire contracts between Swift and the page, written down where the
   page can point at them.

   These are documentation with editor support (hover a payload field and the
   shape appears), not a type checker — esbuild strips all of it. What actually
   keeps the two sides honest is the pair of scripts: check-payload (for
   RenderPayload) and check-commands (for AppCommand) in tools/. Change a shape
   there or in Sources/ and the suite says so.

   Page → Swift messages are the `action` union below; every one is handled in
   ViewerWebView.Coordinator.userContentController.
 */

/**
 * What Swift hands the page for one render. Mirrors RenderPayload.swift.
 *
 * @typedef {object} RenderPayload
 * @property {string} markdown raw file contents
 * @property {string} path absolute path of the file
 * @property {string} dir its folder, for resolving relative links
 * @property {string} error load error text, empty when the file read fine
 * @property {"markdown"|"html"} format which parser to run
 * @property {boolean} showFrontmatter whether the document's head is shown
 * @property {string} theme "paper" | "vellum" | "night" | anything = system
 * @property {string} size "small" | "regular" | "large"
 * @property {string} alignment "left" | "justify"
 * @property {number} measure column width in px
 * @property {number} [resumeY] reading position from an earlier launch;
 *   omitted unless this file has one
 */

/**
 * One message posted to webkit.messageHandlers.mdview.
 *
 * @typedef {object} PageMessage
 * @property {string} action
 *   "frontmatter" — fields for the titlebar disclosure, plus `words`
 *   "outline" — headings for the contents panel
 *   "outlinePosition" — which heading the reader is on (`index`)
 *   "pageFocus" — whether a page input has the keyboard (`focused`)
 *   "scrollPosition" — where reading settled (`path`, `y`), for persistence
 *   "copyText" — code-copy button (`text`)
 *   "openPanel" — the empty state's click-me asked for the open panel
 */

/**
 * One command from Swift, run by window.mdview.dispatch.
 *
 * @typedef {object} AppCommand
 * @property {string} command one of the keys in viewer.js COMMANDS:
 *   openFind, dismissFind, scrollToHeading, scrollHalfPage, scrollToEdge,
 *   stepHeading, refreshDiagrams
 * @property {object} [args] e.g. `{index}` or `{direction: 1|-1}`
 */

/* Runs against the loaded viewer page: pins the separators the titlebar's word
   count treats as word breaks. Returns JSON with a list of failures.

   The count moved from Swift to the page, and Swift's predicate was specific: a
   space or a `Character.isNewline`, and deliberately *not* a tab — so `a\tb` is
   one word. Something like /\S+/g reads as the same thing and counts
   differently, which is what these cases exist to catch.

   Separators are written as \u escapes on purpose: half of them are invisible. */
(function () {
  const { countWords } = window.mdview._internals;
  const failures = [];
  const eq = (label, got, want) => {
    if (got !== want) {
      failures.push(label + ": got " + JSON.stringify(got) + " want " + JSON.stringify(want));
    }
  };

  // Separators: a space, and every newline Swift counted as one.
  eq("space", countWords("a b"), 2);
  eq("newline", countWords("a\nb"), 2);
  eq("crlf", countWords("a\r\nb"), 2);
  eq("cr alone", countWords("a\rb"), 2);
  eq("vertical tab U+000B", countWords("a\u000bb"), 2);
  eq("form feed U+000C", countWords("a\u000cb"), 2);
  eq("next line U+0085", countWords("a\u0085b"), 2);
  eq("line separator U+2028", countWords("a\u2028b"), 2);
  eq("paragraph separator U+2029", countWords("a\u2029b"), 2);

  // Not separators, however much they look like whitespace.
  eq("tab is not a separator", countWords("a\tb"), 1);
  eq("nbsp is not a separator", countWords("a\u00a0b"), 1);

  // Runs collapse, and nothing but separators is no words at all.
  eq("repeated separators", countWords("a  \n b"), 2);
  eq("leading and trailing space", countWords("  a b  "), 2);
  eq("empty string", countWords(""), 0);
  eq("whitespace only", countWords("  \r\n "), 0);

  return JSON.stringify({ failures });
})()

/* Runs against the loaded viewer page: exercises the frontmatter parser on the
   shapes real documents use. Returns JSON with a list of failures. */
(function () {
  const { splitFrontmatter } = window.mdview._internals;
  const failures = [];
  const eq = (label, got, want) => {
    if (JSON.stringify(got) !== JSON.stringify(want)) {
      failures.push(label + ": got " + JSON.stringify(got) + " want " + JSON.stringify(want));
    }
  };

  // YAML block, scalars and both list styles
  let out = splitFrontmatter("---\ntitle: Hello\ndate: 2026-08-18\ntags: [a, b]\nauthors:\n  - Ann\n  - Bo\n---\n# Body\n");
  eq("yaml fields", out.fields, [["title", "Hello"], ["date", "2026-08-18"], ["tags", ["a", "b"]], ["authors", ["Ann", "Bo"]]]);
  eq("yaml body", out.body, "# Body\n");

  // quotes stripped, comments and blank lines ignored
  out = splitFrontmatter('---\n# a comment\ntitle: "Quoted: with colon"\n\nslug: \'single\'\n---\nbody\n');
  eq("quoted values", out.fields, [["title", "Quoted: with colon"], ["slug", "single"]]);

  // TOML delimiters and = separator
  out = splitFrontmatter('+++\ntitle = "Toml doc"\nweight = 3\n+++\nbody\n');
  eq("toml fields", out.fields, [["title", "Toml doc"], ["weight", "3"]]);

  // nested maps are skipped, not guessed at; siblings still parse
  out = splitFrontmatter("---\nauthor:\n  name: Ann\n  email: a@b.c\nstatus: draft\n---\nbody\n");
  eq("nested map skipped", out.fields, [["status", "draft"]]);

  // no frontmatter: document untouched
  out = splitFrontmatter("# Just a heading\n\n---\n\nA horizontal rule above.\n");
  eq("no frontmatter fields", out.fields, []);
  eq("no frontmatter body", out.body, "# Just a heading\n\n---\n\nA horizontal rule above.\n");

  // a rule on the first line is not frontmatter
  out = splitFrontmatter("---\n\nnot frontmatter, just a rule\n");
  eq("leading rule is not frontmatter", out.fields, []);

  // frontmatter with nothing after it
  out = splitFrontmatter("---\ntitle: Only meta\n---\n");
  eq("meta only fields", out.fields, [["title", "Only meta"]]);
  eq("meta only body", out.body, "");

  // CRLF line endings
  out = splitFrontmatter("---\r\ntitle: Windows\r\n---\r\nbody\r\n");
  eq("crlf fields", out.fields, [["title", "Windows"]]);

  return JSON.stringify({ failures });
})()

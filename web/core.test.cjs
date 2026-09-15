const assert = require("node:assert/strict");
const { test } = require("node:test");
const core = require("./core.js");
const katex = require("./vendor/katex/katex.min.js");
const { marked } = require("./vendor/marked/marked.umd.js");

test("all four delimiter forms survive Markdown parsing, including multiline aligned math", () => {
  const input = String.raw`# Formula $e^{i\pi}+1=0$
\[\begin{aligned}a &= b \\
c &= d\end{aligned}\]
Inline \(x^2\) and $$\frac{1}{2}$$.`;
  const result = core.tokenizeMath(input);
  assert.equal(result.formulas.length, 4);
  assert.deepEqual(result.formulas.map(item => item.display), [false, true, false, true]);
  const html = marked.parse(result.markdown);
  for (const formula of result.formulas) {
    assert.ok(html.includes(formula.token));
    assert.match(katex.renderToString(formula.tex, { displayMode: formula.display, trust: false }), /class="katex/);
  }
});

test("code fences and code spans do not turn into math", () => {
  const source = 'Code `$x$`, ``a ` $y$``.\n```latex\n$$z$$\n```\n~~~\n\\[q\\]\n~~~\n$real$';
  const result = core.tokenizeMath(source);
  assert.deepEqual(result.formulas.map(item => item.tex), ["real"]);
  assert.ok(result.markdown.includes('```latex\n$$z$$\n```'));
  const quoted = core.tokenizeMath('> ```latex\n> $$z$$\n> ```\n$x$');
  assert.deepEqual(quoted.formulas.map(item => item.tex), ["x"]);
});

test("currency, escaped dollars and unterminated math remain ordinary text", () => {
  const source = String.raw`Costs $5, $10 and $20.00. Range $5-$10. Literal \$x\$. An incomplete $$x. Normal $a+b$.`;
  const result = core.tokenizeMath(source);
  assert.deepEqual(result.formulas.map(item => item.tex), ["a+b"]);
  assert.ok(result.markdown.includes("Costs $5, $10"));
});

test("strips CSI, OSC hyperlinks, and terminal control characters", () => {
  const input = "\x1b[31mRed\x1b[0m \x1b]8;;https://example.com\x07link\x1b]8;;\x1b\\\r\n$ok$\x00";
  assert.equal(core.normalizeInput(input), "Red link\n$ok$");
  assert.equal(core.normalizeInput("\x1b]8;;https://example.com\x1b\\keep this\x1b]8;;\x1b\\"), "keep this");
});

test("multiline single-dollar prose is not consumed as math", () => {
  const result = core.tokenizeMath("price $5 today\nprice $8 tomorrow\n$x+y$");
  assert.deepEqual(result.formulas.map(item => item.tex), ["x+y"]);
});

test("bare formula mode treats the entire selection as one formula", () => {
  const input = String.raw`\frac{a}{b}`;
  assert.equal(core.looksLikeBareTex(input), true);
  assert.equal(core.tokenizeMath(input, "tex").formulas[0].tex, input);
  assert.equal(core.tokenizeMath("", "tex").formulas.length, 0);
});

test("placeholder-like user text cannot collide with generated tokens", () => {
  const result = core.tokenizeMath("MATHPEEKPLACEHOLDER0END $x$");
  assert.equal(result.formulas[0].token, "MATHPEEKPLACEHOLDERX0END");
});

test("untrusted raw HTML is escaped and KaTeX cannot generate trusted HTML", () => {
  const renderer = new marked.Renderer();
  renderer.html = token => core.escapeHtml(token.text);
  const html = marked.parse('<script>alert(1)</script>\n<img src=x onerror=alert(1)>', { renderer });
  assert.ok(!html.includes("<script>"));
  assert.ok(!html.includes("<img"));
  const formula = katex.renderToString(String.raw`\href{javascript:alert(1)}{x}`, { trust: false });
  assert.ok(!formula.includes('href="javascript:'));
});

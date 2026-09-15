(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.MathPeekCore = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  function normalizeInput(value) {
    return String(value == null ? "" : value)
      .replace(/\x1b\][\s\S]*?(?:\x07|\x1b\\)/g, "")
      .replace(/\x1b[P^_][\s\S]*?\x1b\\/g, "")
      .replace(/(?:\x1b\[|\x9b)[0-?]*[ -/]*[@-~]/g, "")
      .replace(/\x1b[@-_]/g, "")
      .replace(/\r\n?/g, "\n")
      .replace(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/g, "");
  }

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c];
    });
  }

  function escapedAt(source, index) {
    let slashes = 0;
    for (let i = index - 1; i >= 0 && source[i] === "\\"; i--) slashes++;
    return slashes % 2 === 1;
  }

  function findClosing(source, delimiter, from, singleDollar) {
    for (let at = source.indexOf(delimiter, from); at !== -1; at = source.indexOf(delimiter, at + delimiter.length)) {
      if (escapedAt(source, at)) continue;
      // A rejected nearest dollar ends this candidate; searching farther swallows currency prose.
      if (singleDollar && (/\s/.test(source[at - 1]) || /[\d$]/.test(source[at + 1] || "") || source[at - 1] === "$")) return -1;
      return at;
    }
    return -1;
  }

  function tokenizeMath(value, mode) {
    const source = normalizeInput(value);
    let prefix = "MATHPEEKPLACEHOLDER";
    while (source.includes(prefix)) prefix += "X";
    const formulas = [];
    function stash(tex, display) {
      const token = prefix + formulas.length + "END";
      formulas.push({ tex: tex.trim(), display: display, token: token });
      return token;
    }
    if (mode === "tex") return { source: source, markdown: source.trim() ? stash(source, true) : "", formulas: formulas, prefix: prefix };

    let markdown = "";
    let i = 0;
    while (i < source.length) {
      const lineStart = i === 0 || source[i - 1] === "\n";
      if (lineStart) {
        const fence = /^((?: {0,3}>[ \t]?)* {0,3})(`{3,}|~{3,})[^\n]*(?:\n|$)/.exec(source.slice(i));
        if (fence) {
          const marker = fence[2][0];
          const length = fence[2].length;
          let end = i + fence[0].length;
          while (end < source.length) {
            const nextNewline = source.indexOf("\n", end);
            const lineEnd = nextNewline === -1 ? source.length : nextNewline + 1;
            const line = source.slice(end, lineEnd);
            const close = new RegExp("^(?: {0,3}>[ \\t]?)* {0,3}" + marker + "{" + length + ",}[ \\t]*(?:\\n|$)");
            end = lineEnd;
            if (close.test(line)) break;
          }
          markdown += source.slice(i, end);
          i = end;
          continue;
        }
      }
      if (source[i] === "`" && !escapedAt(source, i)) {
        const run = /^`+/.exec(source.slice(i))[0];
        let end = source.indexOf(run, i + run.length);
        while (end !== -1 && (source[end - 1] === "`" || source[end + run.length] === "`")) end = source.indexOf(run, end + run.length);
        if (end !== -1) {
          markdown += source.slice(i, end + run.length);
          i = end + run.length;
          continue;
        }
      }

      let opening = "";
      let closing = "";
      let display = false;
      if (!escapedAt(source, i)) {
        if (source.startsWith("$$", i)) { opening = closing = "$$"; display = true; }
        else if (source.startsWith("\\[", i)) { opening = "\\["; closing = "\\]"; display = true; }
        else if (source.startsWith("\\(", i)) { opening = "\\("; closing = "\\)"; }
        else if (source[i] === "$" && source[i + 1] && !/\s/.test(source[i + 1]) && source[i - 1] !== "$" && !/[\w]/.test(source[i - 1] || "")) { opening = closing = "$"; }
      }
      if (opening) {
        const end = findClosing(source, closing, i + opening.length, opening === "$");
        const body = end === -1 ? "" : source.slice(i + opening.length, end);
        if (end !== -1 && body.trim() && !(opening === "$" && /\n/.test(body))) {
          markdown += stash(body, display);
          i = end + closing.length;
          continue;
        }
      }
      markdown += source[i++];
    }
    return { source: source, markdown: markdown, formulas: formulas, prefix: prefix };
  }

  function looksLikeBareTex(value) {
    const source = normalizeInput(value).trim();
    return !/(\$|\\\[|\\\(|```)/.test(source) && /\\(?:frac|dfrac|tfrac|sum|prod|int|lim|begin|sqrt|mathbb|mathbf|nabla|partial)\b/.test(source);
  }

  return { normalizeInput: normalizeInput, tokenizeMath: tokenizeMath, escapeHtml: escapeHtml, looksLikeBareTex: looksLikeBareTex };
});

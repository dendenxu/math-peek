(function () {
  "use strict";
  const native = window.webkit.messageHandlers.hover;
  const node = document.getElementById("formula");
  const hint = document.getElementById("hint");
  for (const font of ["16px KaTeX_Main", "italic 16px KaTeX_Math", "16px KaTeX_Size1", "16px KaTeX_Size2"]) {
    document.fonts.load(font).catch(function () {});
  }
  window.previewFormula = function (text) {
    let tex = String(text).trim();
    const pairs = [["$$", "$$"], ["\\[", "\\]"], ["\\(", "\\)"], ["$", "$"]];
    for (const [open, close] of pairs) {
      if (tex.startsWith(open) && tex.endsWith(close)) {
        tex = tex.slice(open.length, -close.length);
        break;
      }
    }
    node.className = "";
    try {
      window.katex.render(tex, node, { displayMode: true, trust: false, throwOnError: true,
        strict: "ignore", maxExpand: 1000, maxSize: 20, output: "htmlAndMathml" });
      hint.textContent = "移开鼠标收起 · Control + Command + M 打开阅读窗口";
    } catch (error) {
      node.className = "error";
      node.textContent = tex;
      hint.textContent = "部分语法暂不支持；已保留原文";
    }
    function measure() {
      const card = document.getElementById("card");
      // Measure unconstrained content first; measuring inside the old narrow panel clips long formulas.
      card.style.width = "max-content";
      node.style.width = "max-content";
      node.style.maxWidth = "none";
      node.style.maxHeight = "none";
      node.style.overflow = "visible";
      const expression = node.querySelector(".katex-display") || node;
      const naturalWidth = Math.ceil(Math.max(node.scrollWidth, expression.scrollWidth, expression.getBoundingClientRect().width));
      const naturalHeight = Math.ceil(Math.max(node.scrollHeight, expression.scrollHeight, expression.getBoundingClientRect().height));
      const width = Math.max(200, Math.min(760, naturalWidth + 40));
      card.style.width = width + "px";
      node.style.width = "auto";
      node.style.maxWidth = "100%";
      node.style.maxHeight = "380px";
      node.style.overflow = naturalWidth > width - 38 || naturalHeight > 380 ? "auto" : "visible";
      const height = Math.ceil(Math.max(card.scrollHeight, card.getBoundingClientRect().height)) + 2;
      native.postMessage({ action: "size", width: width, height: height });
    }
    measure();
    document.fonts.ready.then(measure);
  };
  native.postMessage({ action: "ready" });
})();

(function () {
  "use strict";
  const core = window.MathPeekCore;
  const source = document.getElementById("source");
  const preview = document.getElementById("preview");
  const mode = document.getElementById("mode-select");
  const follow = document.getElementById("follow-toggle");
  const status = document.getElementById("status");
  const hoverStatus = document.getElementById("hover-status");
  const hoverStatusRow = document.getElementById("hover-status-row");
  const hoverPermissionButton = document.getElementById("hover-permission-button");
  const setupPanel = document.getElementById("setup-panel");
  const setupButton = document.getElementById("show-setup-button");
  const setupHover = document.getElementById("setup-hover-toggle");
  const setupLogin = document.getElementById("setup-login-toggle");
  const workspace = document.getElementById("workspace");
  const native = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.native;
  let lastLabel = "";
  let lastDescription = "";
  let renderTimer;
  let sourceOpen = !window.matchMedia("(max-width: 760px)").matches;
  let setupExplicitlyShown = false;
  let setupExplicitlyHidden = false;
  let setupState = null;

  const sample = String.raw`# 让公式回到纸上

终端负责工作，这里负责把思路看清楚。来自 SSH、tmux 或本地会话的文字，都可以粘贴到左侧。

## 从一个熟悉的公式开始

行内公式像 $e^{i\pi} + 1 = 0$ 这样自然地嵌进文字。复杂表达式则单独展开：

$$
\mathcal{L}(\theta)
= -\mathbb{E}_{x \sim p_{\mathrm{data}}}
\left[\log p_{\theta}(x)\right]
+ \lambda\,\lVert\theta\rVert_2^2
$$

## 矩阵、多行推导，也没问题

\[
\begin{aligned}
\nabla_\theta \mathcal{L}
&= \frac{1}{N}\sum_{i=1}^{N}\nabla_\theta\ell(x_i;\theta) \\
\theta_{t+1} &= \theta_t - \eta_t\nabla_\theta\mathcal{L}
\end{aligned}
\]

以及 \( A = \begin{pmatrix} 1 & 2 \\ 3 & 4 \end{pmatrix} \)。

> 复制的是没有分隔符的一段公式？把右上角内容切换成「纯 LaTeX 公式」。

代码里的终端变量和金额 $5、$10 会保留原样。
`;

  function post(action, extra) {
    if (!native) return false;
    native.postMessage(Object.assign({ action: action }, extra || {}));
    return true;
  }

  function setStatus(text) { status.textContent = String(text || "就绪"); }

  function setHoverStatus(message, trusted) {
    hoverStatus.textContent = String(message || "悬停状态检查中");
    hoverStatusRow.dataset.trusted = trusted === true ? "true" : trusted === false ? "false" : "unknown";
    hoverPermissionButton.hidden = trusted !== false || !native;
    if (setupState && typeof trusted === "boolean") {
      setSetupState(Object.assign({}, setupState, { trusted: trusted }));
    }
  }

  function updateSetupVisibility() {
    const visible = Boolean(native) && !setupExplicitlyHidden && (setupExplicitlyShown || !setupState || !setupState.setupComplete);
    setupPanel.hidden = !visible;
    setupButton.setAttribute("aria-expanded", String(visible));
    document.querySelector(".app-shell").classList.toggle("setup-visible", visible);
  }

  function setSetupState(value) {
    const state = value && typeof value === "object" ? value : {};
    setupState = {
      trusted: state.trusted === true,
      hoverEnabled: state.hoverEnabled === true,
      hoverApplicationCount: Number.isInteger(state.hoverApplicationCount) ? state.hoverApplicationCount : 1,
      hoverApplications: Array.isArray(state.hoverApplications) ? state.hoverApplications.filter(function (app) {
        return app && typeof app.name === "string" && typeof app.bundleIdentifier === "string";
      }) : [],
      loginEnabled: state.loginEnabled === true,
      loginNeedsApproval: state.loginNeedsApproval === true,
      setupComplete: state.setupComplete === true,
      setupError: typeof state.setupError === "string" ? state.setupError : ""
    };
    setupHover.checked = setupState.hoverEnabled;
    setupLogin.checked = setupState.loginEnabled || setupState.loginNeedsApproval;
    setupHover.disabled = !native;
    setupLogin.disabled = !native;
    document.getElementById("setup-permission-button").hidden = setupState.trusted;
    document.getElementById("setup-permission-status").textContent = setupState.trusted ? "已允许。终端文字仅在本机处理。" : "在系统设置的「辅助功能」中允许 Math Peek。若开关已开但这里仍提示未授权，请移除旧条目，再添加当前安装的 Math Peek.app 并开启。";
    const terminalNames = setupState.hoverApplications.map(function (app) { return app.name; });
    document.getElementById("setup-terminals-status").textContent = setupState.hoverApplicationCount === 0
      ? "尚未启用终端。添加应用，或在菜单栏 Terminal Apps 中勾选已有终端。"
      : "已启用 " + setupState.hoverApplicationCount + " 个终端" + (terminalNames.length ? "：" + terminalNames.join("、") : "") + "。";
    document.getElementById("setup-login-status").textContent = setupState.loginNeedsApproval ? "等待系统批准：请在「登录项与扩展」中允许 Math Peek。" : setupState.loginEnabled ? "已开启。下次登录时在后台运行。" : "登录后在后台运行，无需打开阅读窗口。";
    document.getElementById("setup-progress").textContent = !setupState.trusted ? "需要辅助功能权限" : setupState.hoverApplicationCount === 0 ? "尚未启用终端应用" : !setupState.hoverEnabled ? "悬停预览已暂停" : setupState.loginNeedsApproval ? "登录启动等待批准" : "已就绪";
    document.getElementById("setup-note").textContent = !setupState.trusted ? "可先在后台运行；允许辅助功能访问后，悬停预览才会生效。" : !setupState.hoverEnabled ? "悬停预览当前已关闭，可随时从菜单栏开启。" : setupState.hoverApplicationCount === 0 ? "点击「添加终端」，选择你的终端应用即可启用。" : "设置已生效。完成后切回终端，把鼠标停在公式上即可。";
    document.getElementById("setup-error").textContent = setupState.setupError;
    document.getElementById("setup-error").hidden = !setupState.setupError;
    updateSetupVisibility();
  }

  function showSetup() {
    setupExplicitlyShown = true;
    setupExplicitlyHidden = false;
    updateSetupVisibility();
    setupPanel.scrollIntoView({ block: "start" });
  }

  function hideSetup() {
    setupExplicitlyShown = false;
    setupExplicitlyHidden = true;
    updateSetupVisibility();
  }

  function render() {
    window.clearTimeout(renderTimer);
    const prepared = core.tokenizeMath(source.value, mode.value);
    const renderer = new window.marked.Renderer();
    renderer.html = function (token) { return core.escapeHtml(token.text); };
    renderer.image = function (token) { return "<span>" + core.escapeHtml(token.text || "[图片]") + "</span>"; };
    const html = window.marked.parse(prepared.markdown, { renderer: renderer, gfm: true, breaks: false });
    preview.innerHTML = window.DOMPurify.sanitize(html, {
      USE_PROFILES: { html: true },
      FORBID_TAGS: ["img", "style", "svg", "math", "form", "input", "iframe", "object", "embed", "audio", "video", "source", "link", "meta"],
      FORBID_ATTR: ["style", "src", "srcset", "id", "name"]
    });
    const walker = document.createTreeWalker(preview, NodeFilter.SHOW_TEXT);
    const textNodes = [];
    while (walker.nextNode()) textNodes.push(walker.currentNode);
    const formulaMap = new Map(prepared.formulas.map(function (formula) { return [formula.token, formula]; }));
    const tokenPattern = new RegExp("(" + prepared.prefix + "[0-9]+END)", "g");
    let errors = 0;
    for (const node of textNodes) {
      if (!node.textContent.includes(prepared.prefix)) continue;
      const fragment = document.createDocumentFragment();
      for (const piece of node.textContent.split(tokenPattern)) {
        const formula = formulaMap.get(piece);
        if (!formula) { fragment.appendChild(document.createTextNode(piece)); continue; }
        const span = document.createElement("span");
        try {
          window.katex.render(formula.tex, span, {
            displayMode: formula.display, throwOnError: true, trust: false,
            strict: "ignore", maxExpand: 1000, maxSize: 20, output: "htmlAndMathml"
          });
        } catch (error) {
          errors++;
          span.className = "math-error" + (formula.display ? " display" : "");
          span.textContent = formula.tex;
          span.title = String(error.message || error);
        }
        fragment.appendChild(span);
      }
      node.replaceWith(fragment);
    }
    if (!prepared.source.trim()) preview.innerHTML = '<p class="empty-state">把一段带公式的文字放进来，就能开始阅读。</p>';
    document.getElementById("character-count").textContent = prepared.source.length.toLocaleString() + " 字符";
    document.getElementById("formula-count").textContent = prepared.formulas.length + " 个公式";
    const description = errors ? errors + " 个公式暂不支持，已保留原文；悬停查看原因" : "已渲染 " + prepared.formulas.length + " 个公式";
    const hint = mode.value === "markdown" && prepared.formulas.length === 0 && core.looksLikeBareTex(prepared.source) ? " · 可切换为「纯 LaTeX 公式」" : "";
    lastDescription = description + hint;
    setStatus((lastLabel ? lastLabel + " · " : "") + lastDescription);
  }

  function setContent(value, label) {
    const normalized = core.normalizeInput(value);
    lastLabel = label || "";
    if (source.value === normalized && lastDescription) {
      setStatus((lastLabel ? lastLabel + " · " : "") + lastDescription);
      return;
    }
    source.value = normalized;
    render();
  }

  function setFollow(enabled) { follow.checked = Boolean(enabled); }

  function stopFollowing() {
    if (!follow.checked) return;
    follow.checked = false;
    post("follow", { enabled: false });
  }

  async function paste() {
    stopFollowing();
    if (post("paste")) return;
    try {
      if (!navigator.clipboard || !navigator.clipboard.readText) throw new Error("Clipboard unavailable");
      setContent(await navigator.clipboard.readText(), "剪贴板");
    } catch (_) {
      sourceOpen = true;
      updateSourceVisibility();
      source.focus();
      setStatus("请在源码区按 ⌘V 粘贴；浏览器未开放直接读取剪贴板");
    }
  }

  function updateSourceVisibility() {
    const small = window.matchMedia("(max-width: 760px)").matches;
    workspace.classList.toggle("source-hidden", !small && !sourceOpen);
    workspace.classList.toggle("mobile-source-open", small && sourceOpen);
    document.getElementById("source-toggle").textContent = sourceOpen ? "隐藏源码" : "显示源码";
    document.getElementById("source-toggle").setAttribute("aria-expanded", String(sourceOpen));
  }

  source.addEventListener("input", function () {
    stopFollowing();
    lastLabel = "编辑中";
    window.clearTimeout(renderTimer);
    renderTimer = window.setTimeout(render, 130);
  });
  mode.addEventListener("change", render);
  document.getElementById("paste-button").addEventListener("click", paste);
  document.getElementById("capture-button").addEventListener("click", function () { post("capture"); });
  hoverPermissionButton.addEventListener("click", function () { post("hoverPermission"); });
  document.getElementById("setup-permission-button").addEventListener("click", function () { post("hoverPermission"); });
  document.getElementById("setup-add-terminal-button").addEventListener("click", function () { post("addTerminal"); });
  setupButton.addEventListener("click", function () {
    if (setupPanel.hidden) { if (!post("showSetup")) showSetup(); }
    else if (!post("openReader")) hideSetup();
  });
  document.getElementById("open-reader-button").addEventListener("click", function () { if (!post("openReader")) hideSetup(); });
  setupHover.addEventListener("change", function () { post("setHover", { enabled: setupHover.checked }); });
  setupLogin.addEventListener("change", function () { post("setLogin", { enabled: setupLogin.checked }); });
  document.getElementById("finish-setup-button").addEventListener("click", function () {
    setupExplicitlyShown = false;
    post("finishSetup");
  });
  follow.addEventListener("change", function () { post("follow", { enabled: follow.checked }); });
  document.getElementById("source-toggle").addEventListener("click", function () { sourceOpen = !sourceOpen; updateSourceVisibility(); });
  document.getElementById("sample-button").addEventListener("click", function () { stopFollowing(); mode.value = "markdown"; setContent(sample, "示例"); render(); });
  window.addEventListener("resize", updateSourceVisibility);
  document.addEventListener("keydown", function (event) {
    if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "v" && event.target !== source) {
      event.preventDefault();
      paste();
    }
  });

  if (!native) {
    document.getElementById("capture-button").hidden = true;
    document.getElementById("follow-control").hidden = true;
    setupButton.hidden = true;
    setHoverStatus("悬停预览仅在 Math Peek 桌面应用中可用。");
  }
  window.mathPeek = { setContent: setContent, setStatus: setStatus, setFollow: setFollow, setHoverStatus: setHoverStatus, setSetupState: setSetupState, showSetup: showSetup, hideSetup: hideSetup, render: render };
  updateSetupVisibility();
  updateSourceVisibility();
  setContent(sample, "示例");
  post("ready");
})();

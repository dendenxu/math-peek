import AppKit
import Carbon
import WebKit
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers
import TerminalBridge

extension MathPeek {
    func ensureWindow() {
        guard launched, window == nil else { return }
        // Background hover uses native views only. Load WebKit when the user
        // explicitly opens the reader or needs first-run setup.
        let controller = WKUserContentController()
        controller.add(self, name: "native")
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Math Peek"
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.minSize = NSSize(width: 540, height: 400)
        window.contentView = web
        window.delegate = self
        window.setFrameAutosaveName("MathPeekPreview")
        window.center()
        let page = resources.appendingPathComponent("web/index.html")
        web.loadFileURL(page, allowingReadAccessTo: resources.appendingPathComponent("web"))
    }

    @objc func show() {
        showingSetup = false
        guard launched else { pendingPresentation = .reader; return }
        ensureWindow()
        if ready { call("hideSetup", []) }
        window?.setContentSize(NSSize(width: 1100, height: 760))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSetup() {
        showingSetup = true
        guard launched else { pendingPresentation = .setup; return }
        ensureWindow()
        refreshSetupState(force: true)
        if ready { call("showSetup", []) }
        window?.setContentSize(NSSize(width: 760, height: 620))
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func finishSetup() {
        defaults.set(true, forKey: "setupComplete")
        showingSetup = false
        refreshSetupState(force: true)
        window.performClose(nil)
    }

    @objc func paste() {
        setFollow(false)
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            show()
            status("剪贴板里还没有文字。先复制包含公式的一段内容。")
            return
        }
        setContent(text, label: "剪贴板")
        show()
    }

    @objc func capture() {
        setFollow(false)
        captureTerminal(following: false)
    }

    func setContent(_ text: String, label: String) {
        guard text.utf8.count <= inputLimit else {
            status("内容超过 2 MB，请缩小选区。")
            return
        }
        if ready {
            call("setContent", [text, label])
        } else {
            pending = (text, label)
            pendingStatus = nil
        }
    }

    func status(_ text: String) {
        if ready { call("setStatus", [text]) } else { pendingStatus = text }
    }

    func call(_ method: String, _ arguments: [Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.fragmentsAllowed]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.mathPeek.\(method)(...\(json))", completionHandler: nil)
    }

    func setFollow(_ enabled: Bool) {
        captureGeneration += 1
        captureRequest = nil
        followTimer?.invalidate()
        followTimer = nil
        followTarget = enabled ? preferredTerminal() : nil
        if ready { call("setFollow", [enabled]) }
        if enabled {
            followTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.captureTerminal(following: true)
            }
            captureTerminal(following: true)
        }
    }

    func captureTerminal(following: Bool) {
        guard !following || captureRequest == nil else { return }
        // Resolve the terminal before activating the reader, which changes the frontmost app.
        let target = following ? followTarget : preferredTerminal()
        if !following { show() }
        guard let target else {
            setFollow(false)
            status("请先聚焦已启用的终端窗口，再按 Control-Command-M；也可以复制后粘贴预览。")
            return
        }
        let generation = captureGeneration
        let request = UUID()
        captureRequest = request
        status(following ? "正在跟随 \(target.displayName) 可见内容…" : "正在读取 \(target.displayName) 选区或可见内容…")
        captureQueue.async { [weak self] in
            // Superseded requests waiting on the serial AX queue need no terminal access.
            let current = DispatchQueue.main.sync { self?.captureRequest == request }
            guard current else { return }
            let result = Result { try TerminalCapture().read(target, selectionFirst: !following) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.captureRequest == request else { return }
                self.captureRequest = nil
                guard self.captureGeneration == generation,
                      self.hoverApplications.enabledBundleIdentifiers.contains(target.bundleIdentifier),
                      !following || self.followTimer != nil else { return }
                guard AXIsProcessTrusted() else {
                    self.setFollow(false)
                    self.status(TerminalCaptureError.permission.localizedDescription)
                    return
                }
                switch result {
                case .success(let captured):
                    if captured.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.status("\(target.displayName) 当前没有可读取的文字。")
                    } else {
                        self.setContent(captured.text, label: "\(target.displayName) \(captured.isSelection ? "选区" : "可见内容")")
                    }
                case .failure(let error):
                    self.setFollow(false)
                    self.status("读取 \(target.displayName) 失败：\(error.localizedDescription)")
                }
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        switch action {
        case "ready":
            ready = true
            refreshSetupState(force: true)
            call(showingSetup ? "showSetup" : "hideSetup", [])
            if let (text, label) = pending { setContent(text, label: label); pending = nil }
            call("setFollow", [followTimer != nil])
            call("setHoverStatus", [hoverStatus, AXIsProcessTrusted()])
            if let message = pendingStatus { status(message); pendingStatus = nil }
            if !hotkeyAvailable { status("全局快捷键 Control-Command-M 已被占用；可使用菜单栏里的粘贴预览。") }
        case "paste": paste()
        case "capture": capture()
        case "addTerminal": addHoverApplication()
        case "follow": setFollow(body["enabled"] as? Bool ?? false)
        case "hoverPermission": allowHover()
        case "setHover": setHover(body["enabled"] as? Bool ?? false)
        case "setLogin": setLogin(body["enabled"] as? Bool ?? false)
        case "finishSetup": finishSetup()
        case "openReader": show()
        case "showSetup": showSetup()
        default: break
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "mathpeek" {
                if url.host == "connect-ghostty" {
                    if let request = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "request" })?.value, GhosttyConnectionFiles.validName(request) {
                        if launched { connectGhostty(request) }
                        else if pendingGhosttyRequests.count < 8 { pendingGhosttyRequests.append(request) }
                    }
                    continue
                }
                if url.host == "connect-cmux" {
                    if let request = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                        .first(where: { $0.name == "request" })?.value {
                        if launched { connectCmux(request) }
                        else {
                            if let previous = pendingCmuxRequest, previous != request {
                                cmuxConnectionQueue.async { _ = try? CmuxConnectionStore.consume(previous) }
                            }
                            pendingCmuxRequest = request
                        }
                    }
                    continue
                }
                if !launched, url.host == "capture" || url.host == "follow" {
                    // Launch Services may deliver the URL before discovery and hover setup.
                    pendingTerminalAction = url.host == "capture" ? .capture : .follow
                    pendingTerminalApplication = NSWorkspace.shared.frontmostApplication
                    continue
                }
                switch url.host {
                case "paste": paste()
                case "capture": capture()
                case "follow": setFollow(true); show()
                case "setup": showSetup()
                default: show()
                }
                continue
            }
            guard url.isFileURL else { continue }
            show()
            do {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= inputLimit else { status("文件超过 2 MB，请选择较小的文本文件。"); continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                setFollow(false)
                setContent(text, label: url.lastPathComponent)
                let requestDirectory = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Caches/Math Peek/Requests").standardizedFileURL
                if url.deletingLastPathComponent().standardizedFileURL == requestDirectory,
                   url.lastPathComponent.hasPrefix("math-peek-") {
                    try? FileManager.default.removeItem(at: url)
                }
            } catch { status("无法读取文件：\(error.localizedDescription)") }
        }
    }

    @objc func previewSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string) else { return }
        setFollow(false)
        setContent(text, label: "选中文字")
        show()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Pasted links never navigate the privileged native webview or fetch remote content.
        if navigationAction.navigationType == .linkActivated {
            decisionHandler(.cancel)
            status("预览中的链接不会自动打开。")
        } else {
            let url = navigationAction.request.url
            decisionHandler(url?.isFileURL == true || url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }

    func windowWillClose(_ notification: Notification) { setFollow(false) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSetup(); return true }
}

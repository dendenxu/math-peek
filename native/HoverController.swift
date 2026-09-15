import AppKit
import ApplicationServices
import WebKit

final class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class HoverController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var enabled = true
    var timer: Timer?
    var panel: HoverPanel!
    var web: WKWebView!
    var ready = false
    var pendingFormula: String?
    var lastPoint = NSPoint.zero
    var lastMovement = Date()
    var lastRead = Date.distantPast
    var reading = false
    var generation = 0
    var lastReadGeneration = -1
    var lastPopupLatencyMS = 0.0
    var formula = ""
    var anchor = NSPoint.zero
    var report: ((String) -> Void)?
    var lastDiagnostic = ""
    var lastTrust: Bool?
    let resources: URL
    let system = AXUIElementCreateSystemWide()

    init(resources: URL, enabled: Bool = true, report: @escaping (String) -> Void) {
        self.resources = resources
        self.enabled = enabled
        self.report = report
        super.init()
        AXUIElementSetMessagingTimeout(system, 0.6)
        let content = WKUserContentController()
        content.add(self, name: "hover")
        let config = WKWebViewConfiguration()
        config.userContentController = content
        web = WKWebView(frame: .zero, configuration: config)
        web.underPageBackgroundColor = .clear
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        panel = HoverPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 150),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let backdrop = NSVisualEffectView(frame: panel.contentView!.bounds)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.layer?.masksToBounds = true
        web.frame = backdrop.bounds
        web.autoresizingMask = [.width, .height]
        backdrop.addSubview(web)
        panel.contentView = backdrop
        web.loadFileURL(resources.appendingPathComponent("web/hover.html"),
                        allowingReadAccessTo: resources.appendingPathComponent("web"))
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in self?.tick() }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            diagnose("permission-required")
            report?("悬停预览需要在 macOS 系统设置 → 隐私与安全性 → 辅助功能中允许 Math Peek。")
        } else {
            diagnose("enabled")
            report?("悬停已开启：鼠标移到 iTerm2 公式上即可预览。")
        }
    }

    func diagnose(_ stage: String) {
        guard Bundle.main.bundleIdentifier == "local.mathpeek.preview" else { return }
        guard stage != lastDiagnostic else { return }
        lastDiagnostic = stage
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Math Peek")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let state: [String: Any] = ["stage": stage, "trusted": AXIsProcessTrusted(), "enabled": enabled, "last_popup_latency_ms": Int(lastPopupLatencyMS),
                                    "time": ISO8601DateFormatter().string(from: Date()), "pid": ProcessInfo.processInfo.processIdentifier]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            let target = directory.appendingPathComponent("hover-status.json")
            try? data.write(to: target, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        generation += 1
        if value { requestPermission() } else { hide() }
    }

    func hide() {
        panel.orderOut(nil)
        formula = ""
        pendingFormula = nil
    }

    func tick() {
        let trusted = AXIsProcessTrusted()
        if lastTrust != trusted {
            lastTrust = trusted
            report?(trusted ? "悬停已开启：鼠标移到 iTerm2 公式上即可预览。" : "悬停尚未生效：请在 macOS 辅助功能中允许 Math Peek。")
        }
        guard enabled, trusted else { diagnose(enabled ? "permission-required" : "disabled"); hide(); return }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.googlecode.iterm2" else { diagnose("waiting-for-iterm"); hide(); return }
        let point = NSEvent.mouseLocation
        if panel.isVisible && panel.frame.insetBy(dx: -8, dy: -8).contains(point) { return }
        if hypot(point.x - lastPoint.x, point.y - lastPoint.y) > 2 {
            lastPoint = point
            lastMovement = Date()
            generation += 1
        }
        guard Date().timeIntervalSince(lastRead) > 0.016,
              lastReadGeneration != generation || Date().timeIntervalSince(lastRead) > 0.8,
              !reading, NSEvent.pressedMouseButtons == 0,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == "com.googlecode.iterm2" else {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.googlecode.iterm2" { hide() }
            return
        }
        lastRead = Date()
        lastReadGeneration = generation
        reading = true
        let version = generation
        let mousePoint = CGEvent(source: nil)?.location ?? CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        let processID = front.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.readFormula(at: mousePoint, pid: processID)
            DispatchQueue.main.async {
                self.reading = false
                guard self.enabled, version == self.generation,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return }
                guard let result else { self.hide(); return }
                if self.formula != result || !self.panel.isVisible {
                    self.formula = result
                    self.anchor = point
                    self.present(result)
                }
            }
        }
    }

    func readFormula(at point: CGPoint, pid: pid_t) -> String? {
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        guard hitError == .success, var element = hit else { diagnose("ax-hit-error-\(hitError.rawValue)"); return nil }
        var owner: pid_t = 0
        AXUIElementGetPid(element, &owner)
        guard owner == pid else { diagnose("mouse-outside-iterm"); return nil }
        for _ in 0..<8 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if role as? String == kAXTextAreaRole { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { diagnose("no-text-area"); return nil }
            element = parent as! AXUIElement
        }
        AXUIElementSetMessagingTimeout(element, 0.6)
        // Reading AXValue refreshes iTerm2's index map; AX offsets are UTF-16.
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let text = raw as? String, !text.isEmpty else { diagnose("empty-ax-text"); return nil }
        var coordinate = point
        guard let parameter = AXValueCreate(.cgPoint, &coordinate) else { return nil }
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForPositionParameterizedAttribute as CFString,
                                                         parameter, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { diagnose("no-range-for-position"); return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.length > 0 else { diagnose("empty-character-range"); return nil }
        var boundsValue: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                      rangeValue, &boundsValue) == .success,
           let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() {
            var bounds = CGRect.zero
            if AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds),
               !bounds.insetBy(dx: -2, dy: -2).contains(point) { diagnose("character-bounds-mismatch"); return nil }
        }
        let nsText = text as NSString
        guard range.location >= 0, range.location < nsText.length else { return nil }
        // Restrict processing to nearby content. Keep complete UTF-16 characters at the edges.
        let start = max(0, range.location - 32768)
        let end = min(nsText.length, range.location + 32768)
        let contextRange = nsText.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: end - start))
        let context = nsText.substring(with: contextRange).replacingOccurrences(of: "\0", with: " ")
        let before = nsText.substring(with: NSRange(location: contextRange.location, length: range.location - contextRange.location))
        let offset = before.unicodeScalars.count
        guard let formula = HoverMath.extract(text: context, offset: offset) else { diagnose("no-complete-formula"); return nil }
        diagnose("formula-found")
        return formula
    }

    func present(_ text: String) {
        guard ready else { pendingFormula = text; return }
        guard let json = try? JSONSerialization.data(withJSONObject: [text]),
              let encoded = String(data: json, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.previewFormula(...\(encoded))", completionHandler: nil)
    }

    func resizeAndShow(width: CGFloat, height: CGFloat) {
        guard enabled, !formula.isEmpty else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let w = min(max(200, width), min(760, visible.width - 24))
        let h = min(max(48, height), min(460, visible.height - 24))
        var x = anchor.x + 18
        var y = anchor.y - h - 20
        if x + w > visible.maxX - 12 { x = visible.maxX - w - 12 }
        if y < visible.minY + 12 { y = min(anchor.y + 24, visible.maxY - h - 12) }
        panel.setFrame(NSRect(x: max(visible.minX + 12, x), y: y, width: w, height: h), display: true, animate: false)
        panel.orderFrontRegardless()
        lastPopupLatencyMS = Date().timeIntervalSince(lastMovement) * 1000
        diagnose("popup-visible")
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        if body["action"] as? String == "ready" {
            ready = true
            if let text = pendingFormula { pendingFormula = nil; present(text) }
        } else if body["action"] as? String == "size",
                  let height = body["height"] as? Double, let width = body["width"] as? Double {
            resizeAndShow(width: width, height: height)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true && navigationAction.navigationType != .linkActivated ? .allow : .cancel)
    }
}

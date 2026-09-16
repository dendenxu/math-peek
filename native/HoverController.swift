import AppKit
import ApplicationServices

class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class HoverController: NSObject {
    var enabled = true
    var timer: Timer?
    var panel: HoverPanel!
    var formulaView: FormulaView!
    var lastPoint = NSPoint.zero
    var lastMovement = Date()
    var lastRead = Date.distantPast
    var reading = false
    var generation = 0
    var lastReadGeneration = -1
    var trackingPID: pid_t?
    var lastPopupLatencyMS = 0.0
    var formula = ""
    var anchor = NSPoint.zero
    var report: ((String) -> Void)?
    var lastDiagnostic = ""
    var lastTrust: Bool?
    private(set) var allowedBundleIdentifiers: Set<String>
    private(set) var captureIssue: String?
    let cmuxSource = CmuxHoverSource()
    private var cmuxInputMonitor: Any?
    private var cmuxResumeAfter = Date.distantPast
    private let diagnosticWriter = DiagnosticWriter(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Math Peek/hover-status.json"))
    let resources: URL
    let system = AXUIElementCreateSystemWide()

    init(resources: URL, enabled: Bool = true,
         allowedBundleIdentifiers: Set<String> = ["com.googlecode.iterm2"],
         report: @escaping (String) -> Void) {
        self.resources = resources
        self.enabled = enabled
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
        self.report = report
        super.init()
        AXUIElementSetMessagingTimeout(system, 0.6)
        panel = HoverPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 34),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let backdrop = NSVisualEffectView(frame: panel.contentView!.bounds)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        let cornerRadius: CGFloat = 10
        let maskSize = NSSize(width: cornerRadius * 2 + 1, height: cornerRadius * 2 + 1)
        let materialMask = NSImage(size: maskSize, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        materialMask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                             bottom: cornerRadius, right: cornerRadius)
        materialMask.resizingMode = .stretch
        // Behind-window material and its shadow need an explicit mask;
        // layer clipping below only rounds the border and ordinary subviews.
        backdrop.maskImage = materialMask
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = cornerRadius
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor(srgbRed: 80 / 255, green: 80 / 255, blue: 80 / 255, alpha: 1).cgColor
        let tint = NSView(frame: backdrop.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedWhite: 12 / 255, alpha: 0.14).cgColor
        tint.autoresizingMask = [.width, .height]
        backdrop.addSubview(tint)
        formulaView = FormulaView(frame: backdrop.bounds)
        // render() sizes the view before the panel changes. Autoresizing here
        // would apply the panel's size delta a second time and clip smaller math.
        formulaView.autoresizingMask = []
        backdrop.addSubview(formulaView)
        panel.contentView = backdrop
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in self?.tick() }
        cmuxInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown]) { [weak self] _ in
            guard let self, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.cmuxterm.app" else { return }
            self.generation += 1
            self.hide()
            self.cmuxResumeAfter = Date().addingTimeInterval(0.08)
        }
    }

    deinit {
        if let cmuxInputMonitor { NSEvent.removeMonitor(cmuxInputMonitor) }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            diagnose("permission-required")
            report?("悬停预览需要在 macOS 系统设置 → 隐私与安全性 → 辅助功能中允许 Math Peek。")
        } else {
            diagnose("enabled")
            report?("悬停已开启：鼠标移到已添加终端的公式上即可预览。")
        }
    }

    func diagnose(_ stage: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.diagnose(stage) }
            return
        }
        guard stage != lastDiagnostic else { return }
        lastDiagnostic = stage
        let previousIssue = captureIssue
        switch stage {
        case "no-range-for-position":
            captureIssue = "Terminal does not expose pointer-to-text mapping"
        case "no-text-area":
            captureIssue = "No accessible terminal text under pointer"
        case "empty-ax-text":
            captureIssue = "Terminal does not expose visible text"
        case "cmux-connection-required":
            captureIssue = "cmux: run math-peek connect cmux in a local pane"
        case "cmux-connection-unavailable":
            captureIssue = "cmux connection unavailable; reconnect from a local pane"
        case "cmux-no-geometry", "cmux-grid-unavailable":
            captureIssue = "cmux does not provide a usable viewport grid"
        default:
            captureIssue = nil
        }
        if captureIssue != previousIssue {
            if stage == "cmux-connection-required" {
                report?("请在 cmux 的本地终端中运行 math-peek connect cmux；连接后无需刷新或重启。")
            } else if stage == "cmux-connection-unavailable" {
                report?("cmux 连接暂不可用。确认 cmux 正在运行；若持续失败，请在本地窗格重新运行 math-peek connect cmux。")
            } else if stage == "cmux-no-geometry" || stage == "cmux-grid-unavailable" {
                report?("cmux 没有返回可用的字符网格或位置；请检查版本，并在普通终端窗格内尝试。")
            } else if stage == "no-range-for-position" {
                report?("此终端没有提供鼠标到文字的位置映射，无法自动悬停预览。")
            } else if stage == "no-text-area" {
                report?("鼠标所在位置没有可读取的终端文字；应用需要提供系统辅助功能文本接口。")
            } else if stage == "empty-ax-text" {
                report?("此终端没有提供可读取的可见文字，暂时无法自动悬停预览。可选中文字后使用阅读窗口。")
            } else {
                report?(!enabled ? "悬停预览已暂停。" : !AXIsProcessTrusted()
                    ? "悬停尚未生效：请在 macOS 辅助功能中允许 Math Peek。"
                    : allowedBundleIdentifiers.isEmpty ? "请在 Terminal Apps 菜单中添加或启用终端应用。"
                    : "悬停已开启：鼠标移到已添加终端的公式上即可预览。")
            }
        }
        guard Bundle.main.bundleIdentifier == "local.mathpeek.preview" else { return }
        let state: [String: Any] = ["stage": stage, "trusted": AXIsProcessTrusted(), "enabled": enabled, "last_popup_latency_ms": Int(lastPopupLatencyMS),
                                    "renderer": "swiftmath", "popup_width": Int(panel.frame.width), "popup_height": Int(panel.frame.height),
                                    "time": ISO8601DateFormatter().string(from: Date()), "pid": ProcessInfo.processInfo.processIdentifier]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
            diagnosticWriter.write(data)
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        generation += 1
        lastRead = .distantPast
        if value { requestPermission() } else { hide() }
    }

    func setAllowedApplications(_ identifiers: Set<String>) {
        guard identifiers != allowedBundleIdentifiers else { return }
        allowedBundleIdentifiers = identifiers
        captureIssue = nil
        lastDiagnostic = ""
        trackingPID = nil
        generation += 1
        lastRead = .distantPast
        lastReadGeneration = -1
        hide()
    }

    private func allows(_ application: NSRunningApplication) -> Bool {
        application.bundleIdentifier.map { allowedBundleIdentifiers.contains($0) } ?? false
    }

    func hide() {
        if !formula.isEmpty || reading { generation += 1 }
        panel.orderOut(nil)
        formula = ""
    }

    func tick() {
        let trusted = AXIsProcessTrusted()
        if lastTrust != trusted {
            lastTrust = trusted
            report?(trusted ? "悬停已开启：鼠标移到已添加终端的公式上即可预览。" : "悬停尚未生效：请在 macOS 辅助功能中允许 Math Peek。")
        }
        guard enabled, trusted,
              let front = NSWorkspace.shared.frontmostApplication,
              allows(front) else {
            diagnose(!enabled ? "disabled" : !trusted ? "permission-required" : "waiting-for-terminal")
            if trackingPID != nil {
                trackingPID = nil
                generation += 1
            }
            hide()
            return
        }
        if trackingPID != front.processIdentifier {
            trackingPID = front.processIdentifier
            generation += 1
            lastRead = .distantPast
        }
        if front.bundleIdentifier == "com.cmuxterm.app", Date() < cmuxResumeAfter { return }
        let point = NSEvent.mouseLocation
        if hypot(point.x - lastPoint.x, point.y - lastPoint.y) > 2 {
            lastPoint = point
            lastMovement = Date()
            generation += 1
        }
        guard Date().timeIntervalSince(lastRead) > 0.016,
              lastReadGeneration != generation || Date().timeIntervalSince(lastRead) > 0.8,
              !reading, NSEvent.pressedMouseButtons == 0 else { return }
        lastRead = Date()
        lastReadGeneration = generation
        reading = true
        let version = generation
        let mousePoint = CGEvent(source: nil)?.location ?? CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        let processID = front.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.readFormula(at: mousePoint, pid: processID, generation: version)
            DispatchQueue.main.async {
                self.reading = false
                guard self.enabled, AXIsProcessTrusted(), version == self.generation,
                      let current = NSWorkspace.shared.frontmostApplication,
                      current.processIdentifier == processID, self.allows(current) else { return }
                guard let result else { self.hide(); return }
                if self.formula != result || !self.panel.isVisible {
                    self.formula = result
                    self.anchor = point
                    self.present(result)
                }
            }
        }
    }

    func readFormula(at point: CGPoint, pid: pid_t, generation version: Int? = nil) -> String? {
        func diagnose(_ stage: String) {
            if let version {
                DispatchQueue.main.async {
                    guard version == self.generation, self.enabled,
                          let front = NSWorkspace.shared.frontmostApplication,
                          front.processIdentifier == pid, self.allows(front) else { return }
                    self.diagnose(stage)
                }
            } else {
                self.diagnose(stage)
            }
        }
        // Hit-test the terminal directly so the preview cannot intercept the hit.
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.6)
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit)
        guard hitError == .success, var element = hit else { diagnose("ax-hit-error-\(hitError.rawValue)"); return nil }
        var owner: pid_t = 0
        AXUIElementGetPid(element, &owner)
        guard owner == pid else { diagnose("mouse-outside-terminal"); return nil }
        var foundTextArea = false
        for _ in 0..<8 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if subrole as? String == kAXSecureTextFieldSubrole { return nil }
            if role as? String == kAXTextAreaRole || role as? String == kAXStaticTextRole {
                foundTextArea = true
                break
            }
            if role as? String == kAXTextFieldRole { return nil }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID(),
                  !CFEqual(element, parent) else { break }
            element = parent as! AXUIElement
        }
        guard foundTextArea else { diagnose("no-text-area"); return nil }
        AXUIElementSetMessagingTimeout(element, 0.6)
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.cmuxterm.app" {
            let result = cmuxSource.read(at: point, element: element, pid: pid)
            diagnose(result.stage)
            return result.formula
        }
        // Reading AXValue refreshes iTerm2's index map; AX offsets are UTF-16.
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let text = raw as? String, !text.isEmpty else { diagnose("empty-ax-text"); return nil }
        var coordinate = point
        guard let parameter = AXValueCreate(.cgPoint, &coordinate) else { return nil }
        var rangeValue: CFTypeRef?
        let rangeError = AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForPositionParameterizedAttribute as CFString,
                                                                    parameter, &rangeValue)
        if rangeError != .success || rangeValue.map({ CFGetTypeID($0) != AXValueGetTypeID() }) != false {
            if let located = accessibilityRange(at: point, element: element, text: text as NSString) {
                var found = CFRange(location: located.location, length: located.length)
                rangeValue = AXValueCreate(.cfRange, &found)
            } else {
                diagnose("no-range-for-position")
                return nil
            }
        }
        guard let rangeValue else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.length > 0 else { diagnose("empty-character-range"); return nil }
        var boundsValue: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                      rangeValue, &boundsValue) == .success,
           let boundsValue, CFGetTypeID(boundsValue) == AXValueGetTypeID() {
            var bounds = CGRect.zero
            if AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds),
               !bounds.insetBy(dx: -2, dy: -2).contains(point),
               !(NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.googlecode.iterm2" &&
                 matchesWrappedCell(element, text: text as NSString, range: range, point: point)) {
                diagnose("character-bounds-mismatch")
                return nil
            }
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

    private func accessibilityRange(at point: CGPoint, element: AXUIElement, text: NSString) -> NSRange? {
        var visibleValue: CFTypeRef?
        var visible: NSRange?
        if AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, &visibleValue) == .success,
           let visibleValue, CFGetTypeID(visibleValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(visibleValue as! AXValue, .cfRange, &range) {
                visible = NSRange(location: range.location, length: range.length)
            }
        }
        return HoverTextPosition.range(at: point, text: text, visibleRange: visible) { range in
            var requested = CFRange(location: range.location, length: range.length)
            guard let value = AXValueCreate(.cfRange, &requested) else { return nil }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                              value, &result) == .success,
                  let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
            var bounds = CGRect.zero
            return AXValueGetValue(result as! AXValue, .cgRect, &bounds) ? bounds : nil
        }
    }

    private func matchesWrappedCell(_ element: AXUIElement, text: NSString, range: CFRange, point: CGPoint) -> Bool {
        guard range.location > 0, range.location < text.length, range.length == 1,
              (0x20...0x7E).contains(text.character(at: range.location)),
              (0x20...0x7E).contains(text.character(at: range.location - 1)) else { return false }
        var previous = CFRange(location: range.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &previous) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        var bounds = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &bounds), bounds.width > 0,
              bounds.height > 0, bounds.width < bounds.height * 2 else { return false }
        // iTerm2 may report a wrap-spanning rectangle for the last ASCII cell.
        // The preceding cell supplies its actual position without relaxing pane bounds.
        return bounds.offsetBy(dx: bounds.width, dy: 0).insetBy(dx: -2, dy: -2).contains(point)
    }

    func present(_ text: String) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = formulaView.render(text, maxSize: NSSize(width: min(760, visible.width - 24),
                                                           height: min(460, visible.height - 24)))
        resizeAndShow(width: size.width, height: size.height)
    }

    func resizeAndShow(width: CGFloat, height: CGFloat) {
        guard enabled, !formula.isEmpty else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let w = min(max(40, width), min(760, visible.width - 24))
        let h = min(max(34, height), min(460, visible.height - 24))
        var x = anchor.x + 18
        var y = anchor.y - h - 20
        if x + w > visible.maxX - 12 { x = visible.maxX - w - 12 }
        if y < visible.minY + 12 { y = min(anchor.y + 24, visible.maxY - h - 12) }
        panel.setFrame(NSRect(x: max(visible.minX + 12, x), y: y, width: w, height: h), display: true, animate: false)
        panel.orderFrontRegardless()
        lastPopupLatencyMS = Date().timeIntervalSince(lastMovement) * 1000
        diagnose("popup-visible")
    }

}

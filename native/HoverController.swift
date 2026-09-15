import AppKit
import ApplicationServices

final class HoverPanel: NSPanel {
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
    let resources: URL
    let system = AXUIElementCreateSystemWide()

    init(resources: URL, enabled: Bool = true, report: @escaping (String) -> Void) {
        self.resources = resources
        self.enabled = enabled
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
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor(srgbRed: 80 / 255, green: 80 / 255, blue: 80 / 255, alpha: 1).cgColor
        let tint = NSView(frame: backdrop.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedWhite: 12 / 255, alpha: 0.14).cgColor
        tint.autoresizingMask = [.width, .height]
        backdrop.addSubview(tint)
        formulaView = FormulaView(frame: backdrop.bounds)
        formulaView.autoresizingMask = [.width, .height]
        backdrop.addSubview(formulaView)
        panel.contentView = backdrop
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
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.diagnose(stage) }
            return
        }
        guard stage != lastDiagnostic else { return }
        lastDiagnostic = stage
        guard Bundle.main.bundleIdentifier == "local.mathpeek.preview" else { return }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Math Peek")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let state: [String: Any] = ["stage": stage, "trusted": AXIsProcessTrusted(), "enabled": enabled, "last_popup_latency_ms": Int(lastPopupLatencyMS),
                                    "renderer": "swiftmath", "popup_width": Int(panel.frame.width), "popup_height": Int(panel.frame.height),
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
        lastRead = .distantPast
        if value { requestPermission() } else { hide() }
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
            report?(trusted ? "悬停已开启：鼠标移到 iTerm2 公式上即可预览。" : "悬停尚未生效：请在 macOS 辅助功能中允许 Math Peek。")
        }
        guard enabled, trusted,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == "com.googlecode.iterm2" else {
            diagnose(!enabled ? "disabled" : !trusted ? "permission-required" : "waiting-for-iterm")
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
            let result = self.readFormula(at: mousePoint, pid: processID)
            DispatchQueue.main.async {
                self.reading = false
                guard self.enabled, AXIsProcessTrusted(), version == self.generation,
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
        // Ask iTerm2 directly so the preview cannot intercept accessibility hits.
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.6)
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit)
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
               !bounds.insetBy(dx: -2, dy: -2).contains(point),
               !matchesWrappedCell(element, text: text as NSString, range: range, point: point) {
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

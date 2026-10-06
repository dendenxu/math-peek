import AppKit
import ApplicationServices

final class HoverController: NSObject {
    var enabled = true
    var timer: Timer?
    private let presenter: HoverPresenter
    var panel: HoverPanel { presenter.panel }
    var formulaView: FormulaView { presenter.formulaView }
    var lastPoint = NSPoint.zero
    var lastMovement = Date()
    var lastRead = Date.distantPast
    var reading = false
    var generation = 0
    var lastReadGeneration = -1
    var lastPositionFallbackGeneration = -1
    var trackingPID: pid_t?
    var lastPopupLatencyMS = 0.0
    var formula = ""
    var anchor = NSPoint.zero
    var report: ((String) -> Void)?
    private lazy var diagnostics = HoverDiagnostics { [weak self] message in self?.report?(message) }
    var lastDiagnostic: String { diagnostics.lastStage }
    var lastTrust: Bool?
    private(set) var allowedBundleIdentifiers: Set<String>
    var captureIssue: String? { diagnostics.captureIssue }
    private let terminalSource = TerminalHoverSource()
    var cmuxSource: CmuxHoverSource { terminalSource.cmux }
    var ghosttySource: GhosttyHoverSource { terminalSource.ghostty }
    private var cmuxInputMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var activeApplication: NSRunningApplication?
    private var activeBundleIdentifier: String?
    private var cmuxResumeAfter = Date.distantPast
    private var ghosttyResumeAfter = Date.distantPast
    init(enabled: Bool = true, presenter: HoverPresenter = HoverPresenter(),
         allowedBundleIdentifiers: Set<String> = ["com.googlecode.iterm2"],
         report: @escaping (String) -> Void) {
        self.presenter = presenter
        self.enabled = enabled
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
        self.report = report
        super.init()
        activeApplication = NSWorkspace.shared.frontmostApplication
        activeBundleIdentifier = activeApplication?.bundleIdentifier
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self.activeApplication = application
                self.activeBundleIdentifier = application?.bundleIdentifier
            }
        timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in self?.tick() }
        cmuxInputMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .keyDown, .leftMouseDown]) { [weak self] event in
            guard let self, let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  identifier == "com.cmuxterm.app" || identifier == "com.mitchellh.ghostty" else { return }
            self.generation += 1
            self.hide()
            if identifier == "com.cmuxterm.app" { self.cmuxResumeAfter = Date().addingTimeInterval(0.08) }
            else {
                self.ghosttyResumeAfter = Date().addingTimeInterval(event.type == .keyDown ? 0.55 : 0.08)
                if event.type == .keyDown, event.modifierFlags.contains(.command), [24, 27, 29].contains(event.keyCode),
                   let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
                    self.ghosttySource.invalidateMetrics(pid: pid)
                }
            }
        }
    }

    deinit {
        if let cmuxInputMonitor { NSEvent.removeMonitor(cmuxInputMonitor) }
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
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
        diagnostics.update(stage, context: HoverDiagnostics.Context(
            enabled: enabled, trusted: AXIsProcessTrusted(),
            hasAllowedApplications: !allowedBundleIdentifiers.isEmpty,
            latencyMS: lastPopupLatencyMS, popupSize: panel.frame.size))
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
        diagnostics.reset()
        trackingPID = nil
        terminalSource.invalidate()
        generation += 1
        lastRead = .distantPast
        lastReadGeneration = -1
        hide()
    }

    func hide() {
        if !formula.isEmpty || reading { generation += 1 }
        presenter.hide()
        formula = ""
    }

    func tick() {
        let trusted = AXIsProcessTrusted()
        if lastTrust != trusted {
            lastTrust = trusted
            report?(trusted ? "悬停已开启：鼠标移到已添加终端的公式上即可预览。" : "悬停尚未生效：请在 macOS 辅助功能中允许 Math Peek。")
        }
        guard enabled, trusted, let front = activeApplication,
              let identifier = activeBundleIdentifier, allowedBundleIdentifiers.contains(identifier) else {
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
        if front.bundleIdentifier == "com.mitchellh.ghostty", Date() < ghosttyResumeAfter { return }
        let point = NSEvent.mouseLocation
        if hypot(point.x - lastPoint.x, point.y - lastPoint.y) > 2 {
            lastPoint = point
            lastMovement = Date()
            generation += 1
        }
        let settled = Date().timeIntervalSince(lastMovement) >= 0.08
        let needsPositionFallback = formula.isEmpty && settled && lastPositionFallbackGeneration != generation
        guard Date().timeIntervalSince(lastRead) > 0.016,
              lastReadGeneration != generation || needsPositionFallback || Date().timeIntervalSince(lastRead) > 0.8,
              !reading, NSEvent.pressedMouseButtons == 0 else { return }
        lastRead = Date()
        lastReadGeneration = generation
        reading = true
        let version = generation
        let mousePoint = CGEvent(source: nil)?.location ?? CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
        let processID = front.processIdentifier
        let allowPositionFallback = needsPositionFallback
        if allowPositionFallback { lastPositionFallbackGeneration = generation }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.readFormula(at: mousePoint, pid: processID, generation: version,
                                          allowPositionFallback: allowPositionFallback)
            DispatchQueue.main.async {
                self.reading = false
                guard self.enabled, AXIsProcessTrusted(), version == self.generation,
                      let current = self.activeApplication, current.processIdentifier == processID,
                      let identifier = self.activeBundleIdentifier,
                      self.allowedBundleIdentifiers.contains(identifier) else { return }
                guard let result else { self.hide(); return }
                if self.formula != result || !self.panel.isVisible {
                    self.formula = result
                    self.anchor = point
                    self.present(result)
                }
            }
        }
    }

    func readFormula(at point: CGPoint, pid: pid_t, generation version: Int? = nil,
                     allowPositionFallback: Bool = true) -> String? {
        let result = terminalSource.read(at: point, pid: pid, allowPositionFallback: allowPositionFallback)
        if let version {
            DispatchQueue.main.async { [weak self] in
                guard let self, version == self.generation, self.enabled,
                      let front = self.activeApplication, front.processIdentifier == pid,
                      let identifier = self.activeBundleIdentifier,
                      self.allowedBundleIdentifiers.contains(identifier) else { return }
                self.diagnose(result.stage)
            }
        } else {
            diagnose(result.stage)
        }
        return result.formula
    }

    func present(_ text: String) {
        presenter.present(text, anchor: anchor)
        lastPopupLatencyMS = Date().timeIntervalSince(lastMovement) * 1000
        diagnose("popup-visible")
    }

    func resizeAndShow(width: CGFloat, height: CGFloat) {
        guard enabled, !formula.isEmpty else { return }
        presenter.show(width: width, height: height, anchor: anchor)
        lastPopupLatencyMS = Date().timeIntervalSince(lastMovement) * 1000
        diagnose("popup-visible")
    }

}

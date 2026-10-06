import AppKit
import Carbon
import WebKit
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers
import TerminalBridge

let inputLimit = 2 * 1024 * 1024

final class MathPeek: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    enum Presentation { case reader, setup }
    enum TerminalReaderAction { case capture, follow }
    var pendingPresentation: Presentation?
    var pendingTerminalAction: TerminalReaderAction?
    var pendingTerminalApplication: NSRunningApplication?
    var launched = false
    var window: NSWindow!
    var web: WKWebView!
    var statusItem: NSStatusItem!
    var ready = false
    var pending: (String, String)?
    var pendingStatus: String?
    var followTimer: Timer?
    var captureRequest: UUID?
    var lastTerminalTarget: TerminalCaptureTarget?
    var followTarget: TerminalCaptureTarget?
    let captureQueue = DispatchQueue(label: "local.mathpeek.terminal-capture", qos: .userInitiated)
    var captureGeneration = 0
    var hotkey: EventHotKeyRef?
    var eventHandler: EventHandlerRef?
    var hotkeyAvailable = false
    var hover: HoverController!
    var hoverMenuItem: NSMenuItem!
    var loginMenuItem: NSMenuItem!
    var statusMenuItem: NSMenuItem!
    var hoverApplicationsMenu: NSMenu!
    let hoverApplications = HoverApplications()
    var settingsTimer: Timer?
    var loginStatus: SMAppService.Status = .notRegistered
    var loginStatusReadInFlight = false
    var loginStatusGeneration = 0
    let loginStatusQueue = DispatchQueue(label: "local.mathpeek.login-status", qos: .utility)
    let statusWriter = DiagnosticWriter(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Math Peek/app-status.json"))
    var showingSetup = false
    var setupError = ""
    var lastSetupState = ""
    var hoverStatus = "悬停状态检查中"
    var cmuxStatus = "cmux 尚未连接：在本地窗格运行 math-peek connect cmux。"
    var cmuxConnected = false
    var cmuxRequestGeneration = 0
    var pendingCmuxRequest: String?
    let cmuxConnectionQueue = DispatchQueue(label: "local.mathpeek.cmux-connection", qos: .userInitiated)
    let ghosttyConnectionQueue = DispatchQueue(label: "local.mathpeek.ghostty-connection", qos: .userInitiated)
    var pendingGhosttyRequests: [String] = []
    var ghosttyRequestGeneration = 0
    var ghosttyStatus = "Ghostty 实验悬停：请在每个本地窗格运行 math-peek connect ghostty。"
    let defaults = UserDefaults.standard
    let resources = Bundle.main.resourceURL!

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["hoverEnabled": true, "setupComplete": false])
        if defaults.object(forKey: "autoDiscoverTerminals") == nil {
            defaults.set(!hoverApplications.hasLegacyEmptySelection, forKey: "autoDiscoverTerminals")
        }
        if defaults.bool(forKey: "autoDiscoverTerminals") {
            hoverApplications.discover(TerminalDiscovery.installedApplications())
        }
        setupMenu()
        registerHotkey()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        hover = HoverController(enabled: defaults.bool(forKey: "hoverEnabled"),
                                allowedBundleIdentifiers: hoverApplications.enabledBundleIdentifiers) { [weak self] message in
            guard let self else { return }
            self.hoverStatus = message
            if self.ready { self.call("setHoverStatus", [message, AXIsProcessTrusted()]) }
            self.refreshSetupState()
        }
        launched = true
        for request in pendingGhosttyRequests { connectGhostty(request) }
        pendingGhosttyRequests = []
        if let request = pendingCmuxRequest {
            pendingCmuxRequest = nil
            connectCmux(request)
        } else {
            let version = cmuxRequestGeneration
            cmuxConnectionQueue.async {
                let connection = CmuxConnectionStore.load()
                DispatchQueue.main.async {
                    guard self.cmuxRequestGeneration == version else { return }
                    self.hover.cmuxSource.setConnection(connection)
                    self.cmuxConnected = connection != nil
                    if connection != nil { self.cmuxStatus = "cmux 连接已保存；切回终端即可悬停。" }
                    self.refreshSetupState(force: true)
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(terminalApplicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(terminalApplicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        rememberTerminal(NSWorkspace.shared.frontmostApplication)
        rememberTerminal(pendingTerminalApplication)
        pendingTerminalApplication = nil
        if ProcessInfo.processInfo.arguments.contains("--enable-login") { setLogin(true) }
        refreshLoginStatus()
        refreshSetupState()
        settingsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshLoginStatus()
            self?.refreshSetupState()
        }
        if let action = pendingTerminalAction {
            pendingTerminalAction = nil
            if action == .capture { capture() }
            else { setFollow(true); show() }
        } else if pendingPresentation == .reader {
            show()
        } else if pendingPresentation == .setup || !defaults.bool(forKey: "setupComplete") {
            showSetup()
        }
        pendingPresentation = nil
    }
}

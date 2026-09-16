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
    private enum TerminalReaderAction { case capture, follow }
    var pendingPresentation: Presentation?
    private var pendingTerminalAction: TerminalReaderAction?
    private var pendingTerminalApplication: NSRunningApplication?
    var launched = false
    var window: NSWindow!
    var web: WKWebView!
    var statusItem: NSStatusItem!
    var ready = false
    var pending: (String, String)?
    var pendingStatus: String?
    var followTimer: Timer?
    private var captureRequest: UUID?
    private var lastTerminalTarget: TerminalCaptureTarget?
    private var followTarget: TerminalCaptureTarget?
    private let captureQueue = DispatchQueue(label: "local.mathpeek.terminal-capture", qos: .userInitiated)
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
    private var loginStatus: SMAppService.Status = .notRegistered
    private var loginStatusReadInFlight = false
    private var loginStatusGeneration = 0
    private let loginStatusQueue = DispatchQueue(label: "local.mathpeek.login-status", qos: .utility)
    private let statusWriter = DiagnosticWriter(url: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/Math Peek/app-status.json"))
    var showingSetup = false
    var setupError = ""
    var lastSetupState = ""
    var hoverStatus = "悬停状态检查中"
    var cmuxStatus = "cmux 尚未连接：在本地窗格运行 math-peek connect cmux。"
    var cmuxConnected = false
    private var cmuxRequestGeneration = 0
    private var pendingCmuxRequest: String?
    private let cmuxConnectionQueue = DispatchQueue(label: "local.mathpeek.cmux-connection", qos: .userInitiated)
    private let ghosttyConnectionQueue = DispatchQueue(label: "local.mathpeek.ghostty-connection", qos: .userInitiated)
    private var pendingGhosttyRequests: [String] = []
    private var ghosttyRequestGeneration = 0
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
        hover = HoverController(resources: resources, enabled: defaults.bool(forKey: "hoverEnabled"),
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

    private func ensureWindow() {
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

    func setupMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Math Peek", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        let services = NSMenu()
        let serviceItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        serviceItem.submenu = services
        appMenu.addItem(serviceItem)
        NSApp.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Math Peek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "M∑"
        statusItem.button?.toolTip = "Math Peek - local formula preview"
        let menu = NSMenu()
        menu.delegate = self
        statusMenuItem = NSMenuItem(title: "Checking hover status...", action: nil, keyEquivalent: "")
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        hoverMenuItem = NSMenuItem(title: "Hover Formula Preview", action: #selector(toggleHover), keyEquivalent: "")
        hoverMenuItem.state = .on
        menu.addItem(hoverMenuItem)
        hoverApplicationsMenu = NSMenu(title: "Terminal Apps")
        hoverApplicationsMenu.delegate = self
        let applicationsItem = NSMenuItem(title: "Terminal Apps", action: nil, keyEquivalent: "")
        applicationsItem.submenu = hoverApplicationsMenu
        menu.addItem(applicationsItem)
        rebuildHoverApplicationsMenu()
        menu.addItem(withTitle: "Allow Hover Access...", action: #selector(allowHover), keyEquivalent: "")
        loginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        menu.addItem(loginMenuItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Setup...", action: #selector(showSetup), keyEquivalent: "")
        menu.addItem(withTitle: "Open Reader", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "Preview Clipboard", action: #selector(paste), keyEquivalent: "")
        menu.addItem(withTitle: "Read Terminal Selection / Screen", action: #selector(capture), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        for item in menu.items { item.target = self }
        menu.items.last?.target = NSApp
        statusItem.menu = menu
    }

    func registerHotkey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let app = Unmanaged<MathPeek>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { app.shortcut() }
            return noErr
        }, 1, &spec, context, &eventHandler)
        guard status == noErr else { return }
        let identifier = EventHotKeyID(signature: 0x4D50454B, id: 1)
        hotkeyAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(controlKey | cmdKey), identifier,
                                            GetApplicationEventTarget(), 0, &hotkey) == noErr
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

    func menuWillOpen(_ menu: NSMenu) {
        if menu === hoverApplicationsMenu {
            discoverTerminalApplications(automatically: true)
            rebuildHoverApplicationsMenu()
        }
        refreshSetupState()
    }

    private func discoverTerminalApplications(automatically: Bool) {
        guard !automatically || defaults.bool(forKey: "autoDiscoverTerminals") else { return }
        if hoverApplications.discover(TerminalDiscovery.installedApplications()) {
            updateHoverApplications()
        }
    }

    @objc private func terminalApplicationLaunched(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let identifier = application.bundleIdentifier,
              TerminalDiscovery.knownBundleIdentifiers.contains(identifier) else { return }
        discoverTerminalApplications(automatically: true)
    }

    @objc private func terminalApplicationActivated(_ notification: Notification) {
        rememberTerminal(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    private func rememberTerminal(_ application: NSRunningApplication?) {
        guard let application,
              let target = TerminalCaptureTarget(application, allowedBundleIdentifiers: hoverApplications.enabledBundleIdentifiers) else { return }
        lastTerminalTarget = target
    }

    private func preferredTerminal() -> TerminalCaptureTarget? {
        rememberTerminal(NSWorkspace.shared.frontmostApplication)
        guard let target = lastTerminalTarget,
              let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              application.bundleIdentifier == target.bundleIdentifier else { return nil }
        return TerminalCaptureTarget(application, allowedBundleIdentifiers: hoverApplications.enabledBundleIdentifiers)
    }

    @objc private func toggleAutomaticTerminalDiscovery() {
        defaults.set(!defaults.bool(forKey: "autoDiscoverTerminals"), forKey: "autoDiscoverTerminals")
        discoverTerminalApplications(automatically: true)
        rebuildHoverApplicationsMenu()
        refreshSetupState(force: true)
    }

    @objc private func findInstalledTerminals() {
        discoverTerminalApplications(automatically: false)
    }

    private func rebuildHoverApplicationsMenu() {
        hoverApplicationsMenu.removeAllItems()
        for application in hoverApplications.applications {
            let item = NSMenuItem(title: application.displayName, action: #selector(toggleHoverApplication(_:)), keyEquivalent: "")
            item.representedObject = application.bundleIdentifier
            item.state = application.enabled ? .on : .off
            item.target = self
            hoverApplicationsMenu.addItem(item)
        }
        if !hoverApplications.applications.isEmpty {
            hoverApplicationsMenu.addItem(.separator())
            let remove = NSMenu(title: "Remove Application")
            for application in hoverApplications.applications {
                let item = NSMenuItem(title: application.displayName, action: #selector(removeHoverApplication(_:)), keyEquivalent: "")
                item.representedObject = application.bundleIdentifier
                item.target = self
                remove.addItem(item)
            }
            let removeItem = NSMenuItem(title: "Remove Application", action: nil, keyEquivalent: "")
            removeItem.submenu = remove
            hoverApplicationsMenu.addItem(removeItem)
        }
        let add = NSMenuItem(title: "Add Application...", action: #selector(addHoverApplication), keyEquivalent: "")
        add.target = self
        hoverApplicationsMenu.addItem(add)
        let connect = NSMenuItem(title: "Connect cmux...", action: #selector(showCmuxConnection), keyEquivalent: "")
        connect.target = self
        hoverApplicationsMenu.addItem(connect)
        let disconnect = NSMenuItem(title: "Disconnect cmux", action: #selector(disconnectCmux), keyEquivalent: "")
        disconnect.target = self
        hoverApplicationsMenu.addItem(disconnect)
        let ghosttyConnect = NSMenuItem(title: "Connect Ghostty (Experimental)...", action: #selector(showGhosttyConnection), keyEquivalent: "")
        ghosttyConnect.target = self
        hoverApplicationsMenu.addItem(ghosttyConnect)
        let ghosttyDisconnect = NSMenuItem(title: "Disconnect Ghostty", action: #selector(disconnectGhostty), keyEquivalent: "")
        ghosttyDisconnect.target = self
        hoverApplicationsMenu.addItem(ghosttyDisconnect)
        hoverApplicationsMenu.addItem(.separator())
        let automatic = NSMenuItem(title: "Automatically Find Terminals", action: #selector(toggleAutomaticTerminalDiscovery), keyEquivalent: "")
        automatic.state = defaults.bool(forKey: "autoDiscoverTerminals") ? .on : .off
        automatic.target = self
        hoverApplicationsMenu.addItem(automatic)
        let discover = NSMenuItem(title: "Find Installed Terminals Now", action: #selector(findInstalledTerminals), keyEquivalent: "")
        discover.target = self
        hoverApplicationsMenu.addItem(discover)
    }

    private func updateHoverApplications() {
        hover.setAllowedApplications(hoverApplications.enabledBundleIdentifiers)
        if let target = followTarget, !hoverApplications.enabledBundleIdentifiers.contains(target.bundleIdentifier) {
            setFollow(false)
        }
        if let target = lastTerminalTarget, !hoverApplications.enabledBundleIdentifiers.contains(target.bundleIdentifier) {
            lastTerminalTarget = nil
            captureGeneration += 1
            captureRequest = nil
        }
        rebuildHoverApplicationsMenu()
        refreshSetupState(force: true)
    }

    @objc private func toggleHoverApplication(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        hoverApplications.setEnabled(sender.state != .on, for: identifier)
        updateHoverApplications()
    }

    @objc private func removeHoverApplication(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        hoverApplications.remove(bundleIdentifier: identifier)
        updateHoverApplications()
    }

    @objc private func addHoverApplication() {
        let picker = NSOpenPanel()
        picker.title = "Add a Terminal Application"
        picker.message = "选择终端应用（.app），添加后立即启用，无需刷新或重启。"
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK else { return }
        var added: [String] = []
        for url in picker.urls {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
                  identifier != Bundle.main.bundleIdentifier else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            if hoverApplications.add(bundleIdentifier: identifier, displayName: name) {
                added.append(name)
            }
        }
        updateHoverApplications()
        let alert = NSAlert()
        if added.isEmpty {
            alert.messageText = "未能添加终端应用"
            alert.informativeText = "请选择有效的终端 .app；Math Peek 不能添加自身。"
            alert.runModal()
            return
        }
        alert.messageText = "已启用 \(added.joined(separator: "、"))"
        alert.informativeText = "无需刷新或重启。切回终端，把鼠标停在 $...$、$$...$$ 或 \\[...\\] 中的公式上，即可尝试预览，无需选中文字。\n\n终端需要提供原生文字及字符位置接口。若没有弹出预览，可在菜单顶部查看原因；接口不完整的终端可先选中文字并复制，再使用粘贴预览。"
        if picker.urls.contains(where: { Bundle(url: $0)?.bundleIdentifier == "com.cmuxterm.app" }) {
            alert.informativeText += "\n\ncmux 还需连接一次：在 cmux 的本地终端中运行 math-peek connect cmux。"
        }
        if picker.urls.contains(where: { Bundle(url: $0)?.bundleIdentifier == "com.mitchellh.ghostty" }) {
            alert.informativeText += "\n\nGhostty 实验悬停需在每个本地窗格运行 math-peek connect ghostty。无需刷新；重启 Math Peek 后需重连。适合普通输出，重绘和隐藏文字不可靠，新内容可能延迟约 500 毫秒。"
        }
        if !hover.enabled {
            alert.informativeText += "\n\n悬停预览目前已暂停，请先在菜单中勾选 Hover Formula Preview。"
        }
        if !AXIsProcessTrusted() {
            alert.informativeText += "\n\n请先在系统设置中允许 Math Peek 使用辅助功能。"
            alert.addButton(withTitle: "允许辅助功能")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn { allowHover() }
        } else {
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
    }

    private func refreshLoginStatus() {
        guard !loginStatusReadInFlight else { return }
        loginStatusReadInFlight = true
        let generation = loginStatusGeneration
        // ServiceManagement may wait on system IPC; keep polling off the hover run loop.
        loginStatusQueue.async { [weak self] in
            let status = SMAppService.mainApp.status
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.loginStatusReadInFlight = false
                guard generation == self.loginStatusGeneration else { return }
                if self.loginStatus != status {
                    self.loginStatus = status
                    self.refreshSetupState(force: true)
                }
            }
        }
    }

    func refreshSetupState(force: Bool = false) {
        guard hover != nil else { return }
        let trusted = AXIsProcessTrusted()
        let login = loginStatus
        let applicationCount = hoverApplications.enabledBundleIdentifiers.count
        let summary = !hover.enabled ? "Hover paused" : applicationCount == 0 ? "No terminal apps enabled"
            : !trusted ? "Accessibility permission required" : hover.captureIssue ?? "Hover ready - selected terminal apps"
        statusMenuItem.title = summary
        statusItem.button?.toolTip = "Math Peek - \(summary)"
        hoverMenuItem.state = hover.enabled ? .on : .off
        loginMenuItem.state = login == .enabled ? .on : login == .requiresApproval ? .mixed : .off
        let state: [String: Any] = ["trusted": trusted, "hoverEnabled": hover.enabled,
            "loginEnabled": login == .enabled, "loginNeedsApproval": login == .requiresApproval,
            "setupComplete": defaults.bool(forKey: "setupComplete"), "setupError": setupError,
            "readerLoaded": web != nil, "hoverApplicationCount": applicationCount,
            "hoverApplications": hoverApplications.applications.filter(\.enabled).map {
                ["name": $0.displayName, "bundleIdentifier": $0.bundleIdentifier]
            },
            "autoDiscoverTerminals": defaults.bool(forKey: "autoDiscoverTerminals"),
            "cmuxConnected": cmuxConnected, "cmuxStatus": cmuxStatus,
            "ghosttyConnectedPanes": hover.ghosttySource.connectedCount, "ghosttyStatus": ghosttyStatus]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]),
              let serialized = String(data: data, encoding: .utf8) else { return }
        guard force || serialized != lastSetupState else { return }
        lastSetupState = serialized
        if ready { call("setSetupState", [state]) }
        statusWriter.write(data)
    }

    @objc func toggleLogin() {
        let login = SMAppService.mainApp.status
        setLogin(login != .enabled && login != .requiresApproval)
    }

    func setLogin(_ enabled: Bool) {
        loginStatusGeneration += 1
        setupError = ""
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled && SMAppService.mainApp.status != .requiresApproval {
                    try SMAppService.mainApp.register()
                }
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            setupError = "无法更改登录启动：\(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
        refreshSetupState(force: true)
        if !setupError.isEmpty { showSetup() }
    }

    func shortcut() {
        if let identifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           hoverApplications.enabledBundleIdentifiers.contains(identifier) {
            capture()
        } else {
            paste()
        }
    }

    @objc func toggleHover() {
        setHover(!hover.enabled)
    }

    func setHover(_ enabled: Bool) {
        defaults.set(enabled, forKey: "hoverEnabled")
        hover.setEnabled(enabled)
        refreshSetupState(force: true)
    }

    @objc func allowHover() {
        hover.requestPermission()
        if !AXIsProcessTrusted(), let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Math Peek",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            .credits: NSAttributedString(string: "Native LaTeX hover rendering with SwiftMath. The optional Markdown reader uses KaTeX, marked, and DOMPurify. Control-Command-M opens a selected terminal's selection / screen, or the clipboard in other apps.\nSwiftMath and font licenses are bundled with SwiftMath_SwiftMath.bundle; reader licenses are in Resources/web/vendor.")
        ])
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

    @objc private func showCmuxConnection() {
        showSetup()
        status(cmuxStatus + "\n连接命令：math-peek connect cmux（请在 cmux 本地窗格执行，不是在 SSH 会话中）。")
    }

    @objc private func showGhosttyConnection() {
        showSetup()
        status(ghosttyStatus + "\n在每个 Ghostty 本地窗格运行 math-peek connect ghostty，无需刷新。仅用于普通输出；重绘、隐藏文字可能误识别，新内容有约 500 毫秒缓存。重启 Math Peek、改字体或屏幕缩放后请重连。")
    }

    @objc private func disconnectGhostty() {
        ghosttyRequestGeneration += 1
        hover.ghosttySource.disconnect()
        hover.generation += 1
        hover.hide()
        ghosttyStatus = "Ghostty 已断开。重新连接：在本地窗格运行 math-peek connect ghostty。"
        refreshSetupState(force: true)
    }

    private func connectGhostty(_ name: String) {
        guard GhosttyConnectionFiles.validName(name) else { return }
        let version = ghosttyRequestGeneration
        let connectionVersion = hover.ghosttySource.connectionVersion
        ghosttyStatus = "正在配对 Ghostty 实验悬停，请保持原窗格可见…"
        refreshSetupState(force: true)
        ghosttyConnectionQueue.async {
            var connected = false
            var message: String
            do {
                let request = try GhosttyConnectionFiles.consumeRequest(name)
                try self.hover.ghosttySource.connect(request, expectedGeneration: connectionVersion)
                connected = true
                message = "Connected this Ghostty pane. Hover over a complete formula to preview it."
            } catch { message = String(describing: error) }
            try? GhosttyConnectionFiles.writeReply(GhosttyConnectionReply(connected: connected, message: message), for: name)
            DispatchQueue.main.async {
                guard version == self.ghosttyRequestGeneration else { return }
                self.ghosttyStatus = connected
                    ? "Ghostty 当前窗格已连接（实验模式），无需刷新；仅用于普通输出，新内容可能延迟约 500 毫秒。"
                    : "Ghostty 连接失败：" + message
                if connected {
                    self.hoverApplications.add(bundleIdentifier: "com.mitchellh.ghostty", displayName: "Ghostty")
                    self.updateHoverApplications()
                    self.hover.generation += 1
                    self.hover.lastRead = .distantPast
                }
                self.refreshSetupState(force: true)
            }
        }
    }

    @objc private func disconnectCmux() {
        cmuxRequestGeneration += 1
        let version = cmuxRequestGeneration
        hover.cmuxSource.setConnection(nil)
        hover.generation += 1
        hover.hide()
        cmuxConnected = false
        cmuxStatus = "cmux 已断开；重新连接请在本地窗格运行 math-peek connect cmux。"
        cmuxConnectionQueue.async {
            do { try CmuxConnectionStore.remove() }
            catch {
                DispatchQueue.main.async {
                    guard self.cmuxRequestGeneration == version else { return }
                    self.cmuxStatus = "本次运行已断开 cmux，但钥匙串中的旧连接未能删除。"
                    self.refreshSetupState(force: true)
                }
            }
        }
        refreshSetupState(force: true)
    }

    private func connectCmux(_ request: String) {
        cmuxRequestGeneration += 1
        let version = cmuxRequestGeneration
        cmuxStatus = "正在验证 cmux 连接…"
        refreshSetupState(force: true)
        let processID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.cmuxterm.app").first?.processIdentifier
        cmuxConnectionQueue.async {
            var verified: CmuxSocket.Connection?
            var message = "cmux 连接失败。请确认 cmux 正在运行并更新至支持字符网格的版本，再在新的本地窗格中运行 math-peek connect cmux。"
            do {
                let connection = try CmuxConnectionStore.consume(request)
                guard let processID else { throw CmuxConnectionStore.Failure.invalidRequest }
                let socket = CmuxSocket(connection: connection, expectedPID: processID)
                let capabilities = try socket.call(.systemCapabilities)
                guard let methods = capabilities["methods"] as? [String],
                      Set(["debug.terminals", "pane.list", "mobile.terminal.replay"]).isSubset(of: Set(methods)),
                      let terminals = try socket.call(.debugTerminals)["terminals"] as? [[String: Any]],
                      terminals.count <= 256 else {
                    throw CmuxConnectionStore.Failure.invalidRequest
                }
                let candidates = terminals.filter { item in
                    ["workspace_selected", "surface_selected_in_pane", "runtime_surface_ready",
                     "window_visible", "hosted_view_visible_in_ui"].allSatisfy { item[$0] as? Bool == true }
                }.sorted { ($0["window_key"] as? Bool == true ? 1 : 0) > ($1["window_key"] as? Bool == true ? 1 : 0) }
                let deadline = ProcessInfo.processInfo.systemUptime + 0.8
                var validGrid = false
                for terminal in candidates.prefix(8) {
                    guard ProcessInfo.processInfo.systemUptime < deadline else { break }
                    guard let rawWindow = terminal["window_id"] as? String, let window = UUID(uuidString: rawWindow)?.uuidString,
                          let rawWorkspace = terminal["workspace_id"] as? String, let workspace = UUID(uuidString: rawWorkspace)?.uuidString,
                          let rawPane = terminal["pane_id"] as? String, let pane = UUID(uuidString: rawPane)?.uuidString,
                          let rawSurface = terminal["surface_id"] as? String, let surface = UUID(uuidString: rawSurface)?.uuidString else { continue }
                    let target = CmuxHoverSource.Surface(windowID: window, workspaceID: workspace, paneID: pane,
                        surfaceID: surface, windowFrame: .zero, hostedFrame: .zero)
                    guard let panes = try? socket.call(.paneList, params: ["workspace_id": workspace, "window_id": window]),
                          let metrics = CmuxHoverSource.metrics(in: panes, surface: target),
                          let replay = try? socket.call(.mobileTerminalReplay,
                              params: ["workspace_id": workspace, "surface_id": surface, "anchor": "viewport"]),
                          CmuxGrid.decode(result: replay, expectedSurfaceID: surface,
                              expectedColumns: metrics.columns, expectedRows: metrics.rows) != nil else { continue }
                    validGrid = true
                    break
                }
                guard validGrid else { throw CmuxConnectionStore.Failure.invalidRequest }
                try CmuxConnectionStore.save(connection)
                verified = connection
                message = "cmux 连接成功。切回终端，把鼠标停在公式内部即可预览，无需刷新或重启。"
            } catch CmuxConnectionStore.Failure.keychain {
                message = "cmux 接口验证通过，但连接未能存入钥匙串。请在钥匙串访问中检查 Math Peek 的连接条目后重试。"
            } catch {}
            DispatchQueue.main.async {
                guard self.cmuxRequestGeneration == version else { return }
                self.cmuxStatus = message
                if let verified {
                    self.hover.cmuxSource.setConnection(verified)
                    self.cmuxConnected = true
                    self.hoverApplications.add(bundleIdentifier: "com.cmuxterm.app", displayName: "cmux")
                    self.updateHoverApplications()
                    self.hover.generation += 1
                    self.hover.lastRead = .distantPast
                }
                self.refreshSetupState(force: true)
                self.status(message)
            }
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
    func applicationWillTerminate(_ notification: Notification) {
        followTimer?.invalidate()
        settingsTimer?.invalidate()
        hover.timer?.invalidate()
        captureGeneration += 1
        captureRequest = nil
        if let hotkey { UnregisterEventHotKey(hotkey) }
    }
}

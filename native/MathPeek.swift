import AppKit
import Carbon
import WebKit
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers

let inputLimit = 2 * 1024 * 1024

final class MathPeek: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    enum Presentation { case reader, setup }
    var pendingPresentation: Presentation?
    var launched = false
    var window: NSWindow!
    var web: WKWebView!
    var statusItem: NSStatusItem!
    var ready = false
    var pending: (String, String)?
    var pendingStatus: String?
    var followTimer: Timer?
    var captureTask: Process?
    var captureExpired = false
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
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(terminalApplicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        if ProcessInfo.processInfo.arguments.contains("--enable-login") { setLogin(true) }
        refreshLoginStatus()
        refreshSetupState()
        settingsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshLoginStatus()
            self?.refreshSetupState()
        }
        if pendingPresentation == .reader {
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
        menu.addItem(withTitle: "Read iTerm2 Selection / Screen", action: #selector(capture), keyEquivalent: "")
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
        picker.message = "Choose an application with accessible terminal text and character positions."
        picker.allowedContentTypes = [.applicationBundle]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK else { return }
        for url in picker.urls {
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
                  identifier != Bundle.main.bundleIdentifier else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            hoverApplications.add(bundleIdentifier: identifier, displayName: name)
        }
        updateHoverApplications()
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
            "autoDiscoverTerminals": defaults.bool(forKey: "autoDiscoverTerminals")]
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
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.googlecode.iterm2" {
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
            .applicationVersion: "1.0",
            .credits: NSAttributedString(string: "Native LaTeX hover rendering with SwiftMath. The optional Markdown reader uses KaTeX, marked, and DOMPurify. Control-Command-M opens an iTerm2 selection / screen, or the clipboard in other apps.\nSwiftMath and font licenses are bundled with SwiftMath_SwiftMath.bundle; reader licenses are in Resources/web/vendor.")
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
        followTimer?.invalidate()
        followTimer = nil
        if ready { call("setFollow", [enabled]) }
        if enabled {
            followTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                self?.captureTerminal(following: true)
            }
            captureTerminal(following: true)
        }
    }

    func captureTerminal(following: Bool) {
        guard captureTask == nil else { return }
        if !following { show() }
        let python = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Math Peek/runtime/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            setFollow(false)
            status("iTerm2 接口未安装；可以先复制内容，再用粘贴预览。")
            return
        }
        let process = Process()
        let generation = captureGeneration
        process.executableURL = python
        process.arguments = [resources.appendingPathComponent("integration/iterm_math_peek.py").path, "--capture"]
        if following { process.arguments?.append("--screen") }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        captureExpired = false
        captureTask = process
        status(following ? "正在跟随 iTerm2 可见内容…" : "正在读取 iTerm2；首次连接可能需要在 iTerm2 里允许脚本访问。")
        do {
            try process.run()
        } catch {
            captureTask = nil
            setFollow(false)
            status("读取失败：\(error.localizedDescription)。也可以复制后粘贴预览。")
            return
        }
        // Drain both pipes while the child runs: terminal selections can exceed pipe capacity.
        DispatchQueue.global(qos: .userInitiated).async {
            let errorBox = DataBox()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errorBox.data = errors.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            group.wait()
            DispatchQueue.main.async {
                self.captureTask = nil
                guard !self.captureExpired, self.captureGeneration == generation else { return }
                let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard process.terminationStatus == 0, let value,
                      let text = value["text"] as? String else {
                    self.setFollow(false)
                    let detail = value?["error"] as? String ?? String(data: errorBox.data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    self.status("读取 iTerm2 失败。可复制文字后按 Control-Command-M。\(detail.prefix(240))")
                    return
                }
                if following && self.followTimer == nil { return }
                if text.isEmpty {
                    self.status("iTerm2 当前没有可读取的文字。")
                } else {
                    let source = value["source"] as? String ?? "iTerm2"
                    self.setContent(text, label: source.contains("selection") ? "iTerm2 选区" : "iTerm2 可见内容")
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self, weak process] in
            guard let self, let process, self.captureTask === process, process.isRunning else { return }
            self.captureExpired = true
            process.terminate()
            self.setFollow(false)
            self.status("读取超时。请在 iTerm2 允许 Math Peek 的 Python API 访问，或复制后粘贴预览。")
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
                switch url.host {
                case "paste": paste()
                case "capture": capture()
                case "follow": show(); setFollow(true)
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
        captureTask?.terminate()
        if let hotkey { UnregisterEventHotKey(hotkey) }
    }
}

final class DataBox: @unchecked Sendable { var data = Data() }

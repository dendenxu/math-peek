import AppKit
import Carbon
import WebKit
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers
import TerminalBridge

extension MathPeek {
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

    func refreshLoginStatus() {
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
}

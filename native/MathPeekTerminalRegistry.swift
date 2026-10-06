import AppKit
import Carbon
import WebKit
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers
import TerminalBridge

extension MathPeek {
    func menuWillOpen(_ menu: NSMenu) {
        if menu === hoverApplicationsMenu {
            discoverTerminalApplications(automatically: true)
            rebuildHoverApplicationsMenu()
        }
        refreshSetupState()
    }

    func discoverTerminalApplications(automatically: Bool) {
        guard !automatically || defaults.bool(forKey: "autoDiscoverTerminals") else { return }
        if hoverApplications.discover(TerminalDiscovery.installedApplications()) {
            updateHoverApplications()
        }
    }

    @objc func terminalApplicationLaunched(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let identifier = application.bundleIdentifier,
              TerminalDiscovery.knownBundleIdentifiers.contains(identifier) else { return }
        discoverTerminalApplications(automatically: true)
    }

    @objc func terminalApplicationActivated(_ notification: Notification) {
        rememberTerminal(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
    }

    func rememberTerminal(_ application: NSRunningApplication?) {
        guard let application,
              let target = TerminalCaptureTarget(application, allowedBundleIdentifiers: hoverApplications.enabledBundleIdentifiers) else { return }
        lastTerminalTarget = target
    }

    func preferredTerminal() -> TerminalCaptureTarget? {
        rememberTerminal(NSWorkspace.shared.frontmostApplication)
        guard let target = lastTerminalTarget,
              let application = NSRunningApplication(processIdentifier: target.processIdentifier),
              application.bundleIdentifier == target.bundleIdentifier else { return nil }
        return TerminalCaptureTarget(application, allowedBundleIdentifiers: hoverApplications.enabledBundleIdentifiers)
    }

    @objc func toggleAutomaticTerminalDiscovery() {
        defaults.set(!defaults.bool(forKey: "autoDiscoverTerminals"), forKey: "autoDiscoverTerminals")
        discoverTerminalApplications(automatically: true)
        rebuildHoverApplicationsMenu()
        refreshSetupState(force: true)
    }

    @objc func findInstalledTerminals() {
        discoverTerminalApplications(automatically: false)
    }

    func rebuildHoverApplicationsMenu() {
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

    func updateHoverApplications() {
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

    @objc func toggleHoverApplication(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        hoverApplications.setEnabled(sender.state != .on, for: identifier)
        updateHoverApplications()
    }

    @objc func removeHoverApplication(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        hoverApplications.remove(bundleIdentifier: identifier)
        updateHoverApplications()
    }

    @objc func addHoverApplication() {
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
}

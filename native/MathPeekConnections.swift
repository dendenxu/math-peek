import AppKit
import Carbon
import WebKit
import ApplicationServices
import ServiceManagement
import UniformTypeIdentifiers
import TerminalBridge

extension MathPeek {
    @objc func showCmuxConnection() {
        showSetup()
        status(cmuxStatus + "\n连接命令：math-peek connect cmux（请在 cmux 本地窗格执行，不是在 SSH 会话中）。")
    }

    @objc func showGhosttyConnection() {
        showSetup()
        status(ghosttyStatus + "\n在每个 Ghostty 本地窗格运行 math-peek connect ghostty，无需刷新。仅用于普通输出；重绘、隐藏文字可能误识别，新内容有约 500 毫秒缓存。重启 Math Peek、改字体或屏幕缩放后请重连。")
    }

    @objc func disconnectGhostty() {
        ghosttyRequestGeneration += 1
        hover.ghosttySource.disconnect()
        hover.generation += 1
        hover.hide()
        ghosttyStatus = "Ghostty 已断开。重新连接：在本地窗格运行 math-peek connect ghostty。"
        refreshSetupState(force: true)
    }

    func connectGhostty(_ name: String) {
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

    @objc func disconnectCmux() {
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

    func connectCmux(_ request: String) {
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
}

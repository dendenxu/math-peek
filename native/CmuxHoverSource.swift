import AppKit
import ApplicationServices

final class CmuxHoverSource {
    struct Result {
        let formula: String?
        let stage: String
    }

    struct Surface: Equatable {
        let windowID: String
        let workspaceID: String
        let paneID: String
        let surfaceID: String
        let windowFrame: CGRect
        let hostedFrame: CGRect
    }

    struct Metrics: Equatable {
        let columns: Int
        let rows: Int
        let cellSize: CGSize
    }

    private let lock = NSLock()
    private var storedConnection: CmuxSocket.Connection?
    private var retryAfter = Date.distantPast

    func setConnection(_ connection: CmuxSocket.Connection?) {
        lock.lock()
        storedConnection = connection
        retryAfter = .distantPast
        lock.unlock()
    }

    func read(at point: CGPoint, element: AXUIElement, pid: pid_t) -> Result {
        lock.lock()
        let connection = storedConnection
        let waiting = Date() < retryAfter
        lock.unlock()
        guard let connection else { return Result(formula: nil, stage: "cmux-connection-required") }
        guard !waiting else { return Result(formula: nil, stage: "cmux-connection-unavailable") }
        var role: CFTypeRef?
        var help: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        AXUIElementCopyAttributeValue(element, kAXHelpAttribute as CFString, &help)
        guard role as? String == kAXTextAreaRole, help as? String == "Terminal content area",
              let area = Self.frame(of: element), area.contains(point) else {
            return Result(formula: nil, stage: "cmux-no-geometry")
        }
        let socket = CmuxSocket(connection: connection, expectedPID: pid)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.18
        func call(_ method: CmuxSocket.Method, _ params: [String: Any] = [:]) throws -> [String: Any] {
            try socket.call(method, params: params, timeout: max(0.001, deadline - ProcessInfo.processInfo.systemUptime))
        }
        do {
            let screenTop = CGDisplayBounds(CGMainDisplayID()).height
            guard let surface = Self.surface(in: try call(.debugTerminals), area: area, screenTop: screenTop),
                  let metrics = Self.metrics(in: try call(.paneList, ["workspace_id": surface.workspaceID,
                      "window_id": surface.windowID]), surface: surface) else {
                return Result(formula: nil, stage: "cmux-no-geometry")
            }
            let params: [String: Any] = ["workspace_id": surface.workspaceID,
                                        "surface_id": surface.surfaceID, "anchor": "viewport"]
            let replay = try call(.mobileTerminalReplay, params)
            guard let grid = CmuxGrid.decode(result: replay, expectedSurfaceID: surface.surfaceID,
                                            expectedColumns: metrics.columns, expectedRows: metrics.rows) else {
                return Result(formula: nil, stage: "cmux-grid-unavailable")
            }
            guard let hit = grid.hit(at: point, in: area, cellSize: metrics.cellSize, allowBlankAdjacentRows: true) else {
                return Result(formula: nil, stage: "no-complete-formula")
            }
            // A resize or pane switch during capture invalidates both the text and its coordinates.
            guard Self.frame(of: element) == area,
                  Self.surface(in: try call(.debugTerminals), area: area, screenTop: screenTop) == surface,
                  Self.metrics(in: try call(.paneList, ["workspace_id": surface.workspaceID,
                      "window_id": surface.windowID]), surface: surface) == metrics,
                  let currentGrid = CmuxGrid.decode(result: try call(.mobileTerminalReplay, params),
                      expectedSurfaceID: surface.surfaceID, expectedColumns: metrics.columns, expectedRows: metrics.rows),
                  grid.sameViewport(as: currentGrid), Self.frame(of: element) == area,
                  ProcessInfo.processInfo.systemUptime < deadline else {
                return Result(formula: nil, stage: "cmux-geometry-changed")
            }
            return Result(formula: hit.formula, stage: "formula-found")
        } catch {
            lock.lock()
            if storedConnection == connection { retryAfter = Date().addingTimeInterval(2) }
            lock.unlock()
            return Result(formula: nil, stage: "cmux-connection-unavailable")
        }
    }

    static func surface(in payload: [String: Any], area: CGRect, screenTop: CGFloat) -> Surface? {
        guard let terminals = payload["terminals"] as? [[String: Any]], terminals.count <= 256 else { return nil }
        let matches = terminals.compactMap { item -> Surface? in
            guard item["workspace_selected"] as? Bool == true,
                  item["surface_selected_in_pane"] as? Bool == true,
                  item["hosted_view_visible_in_ui"] as? Bool == true,
                  item["hosted_view_hidden_or_ancestor_hidden"] as? Bool == false,
                  item["window_visible"] as? Bool == true,
                  item["runtime_surface_ready"] as? Bool == true,
                  let window = rect(item["window_frame"]),
                  let hosted = rect(item["hosted_view_frame_in_window"]),
                  let windowID = uuid(item["window_id"]), let workspaceID = uuid(item["workspace_id"]),
                  let paneID = uuid(item["pane_id"]), let surfaceID = uuid(item["surface_id"]) else { return nil }
            let global = CGRect(x: window.minX + hosted.minX,
                                y: screenTop - window.minY - hosted.maxY,
                                width: hosted.width, height: hosted.height)
            guard global.insetBy(dx: -0.5, dy: -0.5).contains(area) else { return nil }
            return Surface(windowID: windowID, workspaceID: workspaceID, paneID: paneID,
                           surfaceID: surfaceID, windowFrame: window, hostedFrame: global)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    static func metrics(in payload: [String: Any], surface: Surface) -> Metrics? {
        guard uuid(payload["workspace_id"]) == surface.workspaceID,
              uuid(payload["window_id"]) == surface.windowID,
              let panes = payload["panes"] as? [[String: Any]], panes.count <= 256 else { return nil }
        let matches = panes.filter { uuid($0["id"]) == surface.paneID }
        guard matches.count == 1, let pane = matches.first,
              uuid(pane["selected_surface_id"]) == surface.surfaceID,
              let columns = integer(pane["columns"]), (1...256).contains(columns),
              let rows = integer(pane["rows"]), (1...256).contains(rows),
              let width = number(pane["cell_width_points"]), width >= 1, width <= 256,
              let height = number(pane["cell_height_points"]), height >= 1, height <= 256 else { return nil }
        return Metrics(columns: columns, rows: rows, cellSize: CGSize(width: width, height: height))
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = number(value), number >= 0, number <= 65536, number.rounded() == number else { return nil }
        return Int(number)
    }

    private static func uuid(_ value: Any?) -> String? {
        guard let string = value as? String, let uuid = UUID(uuidString: string) else { return nil }
        return uuid.uuidString
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let data = value as? [String: Any], let x = number(data["x"]), let y = number(data["y"]),
              let width = number(data["width"]), let height = number(data["height"]),
              width > 0, height > 0, width <= 32768, height <= 32768,
              abs(x) <= 65536, abs(y) <= 65536 else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

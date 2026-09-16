import AppKit
import ApplicationServices
#if canImport(TerminalBridge)
import TerminalBridge
#endif

final class GhosttyHoverSource {
    struct Result { let formula: String?; let stage: String }
    private struct Font: Equatable { let name: String; let size: CGFloat }
    private struct Snapshot: Equatable {
        let text: String; let area: CGRect; let documentHeight: CGFloat
        let scrollbar: Double; let font: Font?; let scale: CGFloat
    }
    private final class Binding {
        let request: GhosttyConnectionRequest
        let textArea: AXUIElement
        let descriptor: Int32
        let initial: Snapshot
        let lock = NSLock()
        var cachedGrid: GhosttyGrid?
        var cachedText: String?
        var cachedColumns = 0
        var needsReconnect = false // Accessed only under the source lock.
        init(request: GhosttyConnectionRequest, textArea: AXUIElement, descriptor: Int32, initial: Snapshot) {
            self.request = request; self.textArea = textArea; self.descriptor = descriptor; self.initial = initial
        }
        deinit { close(descriptor) }
    }
    private let lock = NSLock()
    private var bindings: [Binding] = []
    private var connectionGeneration = 0

    var connectedCount: Int {
        lock.lock(); defer { lock.unlock() }
        bindings.removeAll { !TerminalProcess.isDirectSession($0.request.session, device: $0.request.ttyDevice, ghostty: $0.request.ghostty) }
        return bindings.count
    }
    var connectionVersion: Int { lock.lock(); defer { lock.unlock() }; return connectionGeneration }

    func disconnect() {
        lock.lock(); defer { lock.unlock() }
        connectionGeneration += 1
        bindings = []
    }

    func invalidateMetrics(pid: pid_t) {
        lock.lock(); defer { lock.unlock() }
        for binding in bindings where binding.request.ghostty.pid == pid { binding.needsReconnect = true }
    }

    func connect(_ request: GhosttyConnectionRequest, expectedGeneration: Int? = nil) throws {
        lock.lock(); let version = connectionGeneration; lock.unlock()
        guard expectedGeneration == nil || expectedGeneration == version else { throw GhosttyConnectionError("Connection cancelled.") }
        guard AXIsProcessTrusted(),
              NSRunningApplication(processIdentifier: request.ghostty.pid)?.bundleIdentifier == "com.mitchellh.ghostty" else {
            throw GhosttyConnectionError("Allow Math Peek in macOS Accessibility and keep the originating Ghostty pane visible.")
        }
        let descriptor = try request.openVerifiedTTY()
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        let app = AXUIElementCreateApplication(request.ghostty.pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        var matched: AXUIElement?
        while ProcessInfo.processInfo.systemUptime < deadline, request.client.isAlive() {
            var queue = (Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { ($0, 0) }
            var visited = 0
            var matches: [AXUIElement] = []
            while !queue.isEmpty, visited < 300, ProcessInfo.processInfo.systemUptime < deadline {
                let (element, depth) = queue.removeFirst(); visited += 1
                AXUIElementSetMessagingTimeout(element, 0.1)
                if Self.attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole {
                    if let text = Self.attribute(element, kAXValueAttribute) as? String, text.utf8.count <= 524_288,
                       text.contains(request.marker), !matches.contains(where: { CFEqual($0, element) }) { matches.append(element) }
                } else if depth < 16 {
                    queue += (Self.attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map { ($0, depth + 1) }
                }
            }
            if matches.count == 1 { matched = matches[0]; break }
            if matches.count > 1 { throw GhosttyConnectionError("Pairing marker matched more than one pane; retry in the original pane.") }
            Thread.sleep(forTimeInterval: 0.12)
        }
        guard let matched, Self.attribute(matched, kAXFocusedAttribute) as? Bool == true,
              let initial = Self.snapshot(matched), initial.text.contains(request.marker),
              TerminalDimensions.read(descriptor) == request.dimensions else {
            throw GhosttyConnectionError("Could not read this pane's marker, font, and geometry. Keep it visible, reduce very large scrollback, and retry.")
        }
        try request.validate()
        guard GhosttyGrid.viewportOffset(rows: request.dimensions.rows,
                cellHeight: CGFloat(request.cellHeightPixels) / initial.scale,
                areaHeight: initial.area.height, documentHeight: initial.documentHeight,
                scrollbar: initial.scrollbar) != nil else {
            throw GhosttyConnectionError("Ghostty's scroll geometry is still changing. Stop scrolling and retry.")
        }
        let binding = Binding(request: request, textArea: matched, descriptor: descriptor, initial: initial)
        transferred = true
        lock.lock(); defer { lock.unlock() }
        guard version == connectionGeneration else { throw GhosttyConnectionError("Connection cancelled.") }
        bindings.removeAll { !TerminalProcess.isDirectSession($0.request.session, device: $0.request.ttyDevice, ghostty: $0.request.ghostty) ||
            ($0.request.ghostty.pid == request.ghostty.pid && CFEqual($0.textArea, matched)) }
        guard bindings.count < 32 else { throw GhosttyConnectionError("Too many connected panes; disconnect Ghostty in the Math Peek menu first.") }
        bindings.append(binding)
    }

    func read(at point: CGPoint, element: AXUIElement, pid: pid_t) -> Result {
        lock.lock()
        let binding = bindings.first { $0.request.ghostty.pid == pid && CFEqual($0.textArea, element) }
        let invalidated = binding?.needsReconnect == true
        lock.unlock()
        guard let binding else { return Result(formula: nil, stage: "ghostty-connection-required") }
        guard !invalidated else { return Result(formula: nil, stage: "ghostty-reconnect-required") }
        binding.lock.lock(); defer { binding.lock.unlock() }
        let start = ProcessInfo.processInfo.systemUptime
        guard binding.request.ghostty.isAlive(),
              TerminalProcess.isDirectSession(binding.request.session, device: binding.request.ttyDevice, ghostty: binding.request.ghostty),
              let dimensions = TerminalDimensions.read(binding.descriptor), let snapshot = Self.snapshot(element),
              snapshot.font == binding.initial.font, snapshot.scale == binding.initial.scale else {
            return Result(formula: nil, stage: "ghostty-reconnect-required")
        }
        guard let cell = Self.cellSize(dimensions: dimensions, snapshot: snapshot, binding: binding) else {
            return Result(formula: nil, stage: "ghostty-reconnect-required")
        }
        if binding.cachedText != snapshot.text || binding.cachedColumns != dimensions.columns {
            binding.cachedText = snapshot.text
            binding.cachedColumns = dimensions.columns
            binding.cachedGrid = GhosttyGrid(text: snapshot.text, columns: dimensions.columns)
        }
        guard let grid = binding.cachedGrid else { return Result(formula: nil, stage: "ghostty-layout-unsupported") }
        guard let formula = grid.formula(at: point, area: snapshot.area, cellSize: cell, rows: dimensions.rows,
                                        documentHeight: snapshot.documentHeight, scrollbar: snapshot.scrollbar) else {
            return Result(formula: nil, stage: "no-complete-formula")
        }
        // Two reads reject geometry changes, not Ghostty's known 500 ms text cache.
        guard ProcessInfo.processInfo.systemUptime - start < 0.18,
              TerminalDimensions.read(binding.descriptor) == dimensions,
              Self.snapshot(element) == snapshot,
              ProcessInfo.processInfo.systemUptime - start < 0.18 else {
            return Result(formula: nil, stage: "ghostty-geometry-changed")
        }
        return Result(formula: formula, stage: "formula-found")
    }

    private static func cellSize(dimensions: TerminalDimensions, snapshot: Snapshot, binding: Binding) -> CGSize? {
        if dimensions == binding.request.dimensions {
            return CGSize(width: CGFloat(binding.request.cellWidthPixels) / snapshot.scale,
                          height: CGFloat(binding.request.cellHeightPixels) / snapshot.scale)
        }
        let widths = (dimensions.widthPixels / (dimensions.columns + 1) + 1)...(dimensions.widthPixels / dimensions.columns)
        let heights = (dimensions.heightPixels / (dimensions.rows + 1) + 1)...(dimensions.heightPixels / dimensions.rows)
        guard widths.count == 1, heights.count <= 32 else { return nil }
        let validHeights = heights.filter { height in
            GhosttyGrid.viewportOffset(rows: dimensions.rows, cellHeight: CGFloat(height) / snapshot.scale,
                areaHeight: snapshot.area.height, documentHeight: snapshot.documentHeight, scrollbar: snapshot.scrollbar) != nil
        }
        guard validHeights.count == 1, let height = validHeights.first else { return nil }
        return CGSize(width: CGFloat(widths.lowerBound) / snapshot.scale, height: CGFloat(height) / snapshot.scale)
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private static func snapshot(_ element: AXUIElement) -> Snapshot? {
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let text = attribute(element, kAXValueAttribute) as? String, !text.isEmpty, text.utf8.count <= 524_288,
              let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &dimensions),
              [origin.x, origin.y, dimensions.width, dimensions.height].allSatisfy(\.isFinite),
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        let area = CGRect(origin: origin, size: dimensions)
        var parent = element
        var scroll: AXUIElement?
        for _ in 0..<8 {
            guard let raw = attribute(parent, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
            parent = raw as! AXUIElement
            if attribute(parent, kAXRoleAttribute) as? String == kAXScrollAreaRole { scroll = parent; break }
        }
        guard let scroll, let content = attribute(scroll, "AXContentSize"), CFGetTypeID(content) == AXValueGetTypeID(),
              let bar = attribute(scroll, kAXVerticalScrollBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let value = attribute(bar as! AXUIElement, kAXValueAttribute) as? Double, value.isFinite, (0...1).contains(value) else { return nil }
        var document = CGSize.zero
        guard AXValueGetValue(content as! AXValue, .cgSize, &document), document.height.isFinite, document.height >= area.height else { return nil }
        var range = CFRange(location: 0, length: 1), attributed: CFTypeRef?
        var fontSignature: Font?
        // Some released Ghostty/macOS combinations advertise this attribute but
        // return AXErrorIllegalArgument. TTY calibration must work without it.
        if let parameter = AXValueCreate(.cfRange, &range),
           AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString,
                                                       parameter, &attributed) == .success,
           let styled = attributed as? NSAttributedString, styled.length > 0 {
            if let font = styled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                fontSignature = Font(name: font.fontName, size: font.pointSize)
            } else if let font = styled.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any],
                      let name = font["AXFontName"] as? String, let size = font["AXFontSize"] as? Double {
                fontSignature = Font(name: name, size: size)
            }
        }
        var display = CGDirectDisplayID(), count: UInt32 = 0
        guard CGGetDisplaysWithPoint(CGPoint(x: area.midX, y: area.midY), 1, &display, &count) == .success,
              count == 1, let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return nil }
        let scale = CGFloat(mode.pixelWidth) / CGFloat(mode.width)
        guard (1...4).contains(scale) else { return nil }
        return Snapshot(text: text, area: area, documentHeight: document.height, scrollbar: value,
                        font: fontSignature, scale: scale)
    }
}

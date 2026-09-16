import AppKit
import ApplicationServices

struct TerminalCaptureTarget: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let displayName: String

    init?(_ application: NSRunningApplication, allowedBundleIdentifiers: Set<String>) {
        guard let identifier = application.bundleIdentifier,
              allowedBundleIdentifiers.contains(identifier), !application.isTerminated else { return nil }
        processIdentifier = application.processIdentifier
        bundleIdentifier = identifier
        displayName = application.localizedName ?? identifier
    }
}

struct CapturedTerminalText {
    let text: String
    let isSelection: Bool
}

enum TerminalCaptureError: LocalizedError {
    case permission, closed, noTextArea, noVisibleRange, tooLarge, timedOut

    var errorDescription: String? {
        switch self {
        case .permission: return "请先在系统设置的辅助功能中允许 Math Peek。"
        case .closed: return "终端已关闭，请重新选择终端窗口。"
        case .noTextArea: return "找不到当前终端面板的可访问文字，请先聚焦要读取的终端面板。"
        case .noVisibleRange: return "此终端没有提供可见文字范围，请选中文字后重试，或复制后粘贴预览。"
        case .tooLarge: return "内容超过 2 MB，请缩小选区。"
        case .timedOut: return "终端读取超时，请重试，或复制后粘贴预览。"
        }
    }
}

enum TerminalCaptureRange {
    static func validated(_ range: CFRange, length: Int) -> NSRange? {
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func substring(_ text: String, range: CFRange) -> String? {
        let string = text as NSString
        guard let range = validated(range, length: string.length) else { return nil }
        func splitsSurrogate(_ index: Int) -> Bool {
            index > 0 && index < string.length && (0xD800...0xDBFF).contains(string.character(at: index - 1))
                && (0xDC00...0xDFFF).contains(string.character(at: index))
        }
        guard !splitsSurrogate(range.location), !splitsSurrogate(NSMaxRange(range)) else { return nil }
        // Never expand a viewport range into characters outside it.
        return string.substring(with: range).replacingOccurrences(of: "\0", with: " ")
    }

    static func spanning(_ first: CFRange, _ last: CFRange, length: Int) -> CFRange? {
        guard let start = validated(first, length: length), let end = validated(last, length: length),
              start.location <= end.location else { return nil }
        return CFRange(location: start.location, length: NSMaxRange(end) - start.location)
    }
}

// All AX calls run on the reader's serial queue, never on the hover/UI run loop.
final class TerminalCapture {
    private let deadline = Date().addingTimeInterval(4)

    func read(_ target: TerminalCaptureTarget, selectionFirst: Bool) throws -> CapturedTerminalText {
        guard AXIsProcessTrusted() else { throw TerminalCaptureError.permission }
        guard let running = NSRunningApplication(processIdentifier: target.processIdentifier),
              !running.isTerminated, running.bundleIdentifier == target.bundleIdentifier else {
            throw TerminalCaptureError.closed
        }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.35)
        guard let element = try focusedTextArea(application) else { throw TerminalCaptureError.noTextArea }
        if selectionFirst, let selection = try attribute(element, kAXSelectedTextAttribute) as? String,
           !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try result(selection, isSelection: true)
        }

        // iTerm2 refreshes its accessibility character indices when AXValue is read.
        let text = try attribute(element, kAXValueAttribute) as? String
        if let value = try attribute(element, kAXVisibleCharacterRangeAttribute), let visible = range(value),
           let captured = try string(element, range: visible, text: text) {
            return try result(captured, isSelection: false)
        }
        guard let text, let visible = try visibleRange(element, textLength: (text as NSString).length),
              let captured = TerminalCaptureRange.substring(text, range: visible) else {
            throw TerminalCaptureError.noVisibleRange
        }
        return try result(captured, isSelection: false)
    }

    private func result(_ text: String, isSelection: Bool) throws -> CapturedTerminalText {
        guard text.utf8.count <= 2 * 1024 * 1024 else { throw TerminalCaptureError.tooLarge }
        return CapturedTerminalText(text: text.replacingOccurrences(of: "\0", with: " "), isSelection: isSelection)
    }

    private func checkDeadline() throws {
        if Date() >= deadline { throw TerminalCaptureError.timedOut }
    }

    private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        try checkDeadline()
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) throws -> CFTypeRef? {
        try checkDeadline()
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
    }

    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func range(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    private func focusedTextArea(_ application: AXUIElement) throws -> AXUIElement? {
        if var focused = element(try attribute(application, kAXFocusedUIElementAttribute)) {
            for _ in 0..<8 {
                let role = try attribute(focused, kAXRoleAttribute) as? String
                if role == kAXTextAreaRole { return focused }
                if role == kAXTextFieldRole || role == kAXSecureTextFieldSubrole { return nil }
                guard role != kAXWindowRole, let parent = element(try attribute(focused, kAXParentAttribute)),
                      !CFEqual(parent, focused) else { break }
                focused = parent
            }
        }
        guard let window = element(try attribute(application, kAXFocusedWindowAttribute)) else { return nil }
        var queue = [(window, 0)]
        var seen = Set<CFHashCode>()
        var candidates: [AXUIElement] = []
        while !queue.isEmpty, seen.count < 160 {
            let (node, depth) = queue.removeFirst()
            guard seen.insert(CFHash(node)).inserted else { continue }
            if try attribute(node, kAXRoleAttribute) as? String == kAXTextAreaRole {
                if try attribute(node, kAXFocusedAttribute) as? Bool == true { return node }
                candidates.append(node)
                continue
            }
            if depth < 12, let children = try attribute(node, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        // Never choose a different split pane merely because it appears first in AXChildren.
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func string(_ element: AXUIElement, range: CFRange, text: String?) throws -> String? {
        guard range.location >= 0, range.length >= 0, range.length <= 2 * 1024 * 1024,
              range.location <= Int.max - range.length else { return nil }
        if let text { return TerminalCaptureRange.substring(text, range: range) }
        var requested = range
        guard let value = AXValueCreate(.cfRange, &requested) else { return nil }
        return try parameterized(element, kAXStringForRangeParameterizedAttribute, value) as? String
    }

    private func frame(_ element: AXUIElement) throws -> CGRect? {
        guard let originValue = try attribute(element, kAXPositionAttribute),
              let sizeValue = try attribute(element, kAXSizeAttribute),
              CFGetTypeID(originValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(originValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func bounds(_ element: AXUIElement, range: CFRange) throws -> CGRect? {
        var requested = range
        guard let parameter = AXValueCreate(.cfRange, &requested),
              let value = try parameterized(element, kAXBoundsForRangeParameterizedAttribute, parameter),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 0 else { return nil }
        return rect
    }

    private func visibleRange(_ textArea: AXUIElement, textLength: Int) throws -> CFRange? {
        guard var viewport = try frame(textArea) else { return nil }
        var ancestor = textArea
        for _ in 0..<8 {
            guard let parent = element(try attribute(ancestor, kAXParentAttribute)), !CFEqual(parent, ancestor) else { break }
            let role = try attribute(parent, kAXRoleAttribute) as? String
            if role == kAXScrollAreaRole || role == kAXWindowRole, let bounds = try frame(parent) {
                viewport = viewport.intersection(bounds)
            }
            if role == kAXWindowRole { break }
            ancestor = parent
        }
        guard !viewport.isNull, viewport.width > 4, viewport.height > 4 else { return nil }
        func edge(_ fromTop: Bool) throws -> CFRange? {
            // A terminal may have padding around its cells; keep probing inside the same pane.
            for inset in [2.0, 6.0, 12.0, 20.0] where inset < viewport.height / 2 {
                for x in [viewport.minX + 2, viewport.midX, viewport.maxX - 2] {
                    var point = CGPoint(x: x, y: fromTop ? viewport.minY + inset : viewport.maxY - inset)
                    guard let value = AXValueCreate(.cgPoint, &point),
                          let found = try range(parameterized(textArea, kAXRangeForPositionParameterizedAttribute, value)),
                          TerminalCaptureRange.validated(found, length: textLength) != nil,
                          let cell = try bounds(textArea, range: found), cell.intersects(viewport) else { continue }
                    if let lineNumber = try parameterized(textArea, kAXLineForIndexParameterizedAttribute, NSNumber(value: found.location)),
                       let lineRange = try range(parameterized(textArea, kAXRangeForLineParameterizedAttribute, lineNumber)),
                       TerminalCaptureRange.validated(lineRange, length: textLength) != nil,
                       let lineBounds = try bounds(textArea, range: lineRange),
                       lineBounds.minY >= viewport.minY - 2, lineBounds.maxY <= viewport.maxY + 2 {
                        return lineRange
                    }
                    // A character at the middle of a line cannot define a complete viewport.
                    if fromTop && x == viewport.minX + 2 || !fromTop && x == viewport.maxX - 2 { return found }
                }
            }
            return nil
        }
        guard let first = try edge(true), let last = try edge(false) else { return nil }
        return TerminalCaptureRange.spanning(first, last, length: textLength)
    }
}

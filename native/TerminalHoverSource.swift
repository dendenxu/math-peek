import AppKit
import ApplicationServices

/// Captures one immutable terminal snapshot, maps a screen point to a source
/// character, and queries the snapshot-level formula index. It never owns UI
/// state, timers, or generations.
final class TerminalHoverSource {
    struct Result {
        let formula: String?
        let stage: String
    }

    let cmux = CmuxHoverSource()
    let ghostty = GhosttyHoverSource()
    private let documents = FormulaDocumentCache()

    func invalidate() { documents.invalidate() }

    func read(at point: CGPoint, pid: pid_t, allowPositionFallback: Bool) -> Result {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.6)
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit)
        guard hitError == .success, var element = hit else {
            return Result(formula: nil, stage: "ax-hit-error-\(hitError.rawValue)")
        }
        var owner: pid_t = 0
        AXUIElementGetPid(element, &owner)
        guard owner == pid else { return Result(formula: nil, stage: "mouse-outside-terminal") }
        var foundTextArea = false
        for _ in 0..<8 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if subrole as? String == kAXSecureTextFieldSubrole {
                return Result(formula: nil, stage: "secure-text-field")
            }
            if role as? String == kAXTextAreaRole || role as? String == kAXStaticTextRole {
                foundTextArea = true
                break
            }
            if role as? String == kAXTextFieldRole {
                return Result(formula: nil, stage: "ordinary-text-field")
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID(), !CFEqual(element, parent) else { break }
            element = parent as! AXUIElement
        }
        guard foundTextArea else { return Result(formula: nil, stage: "no-text-area") }
        AXUIElementSetMessagingTimeout(element, 0.6)

        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        if bundle == "com.cmuxterm.app" {
            let result = cmux.read(at: point, element: element, pid: pid)
            return Result(formula: result.formula, stage: result.stage)
        }
        if bundle == "com.mitchellh.ghostty" {
            let result = ghostty.read(at: point, element: element, pid: pid)
            return Result(formula: result.formula, stage: result.stage)
        }

        // Reading AXValue refreshes iTerm2's UTF-16 index map.
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success,
              let text = raw as? String, !text.isEmpty else {
            return Result(formula: nil, stage: "empty-ax-text")
        }
        let nsText = text as NSString
        var coordinate = point
        guard let pointValue = AXValueCreate(.cgPoint, &coordinate) else {
            return Result(formula: nil, stage: "invalid-pointer")
        }
        var rangeValue: CFTypeRef?
        let rangeError = AXUIElementCopyParameterizedAttributeValue(
            element, kAXRangeForPositionParameterizedAttribute as CFString, pointValue, &rangeValue)
        if rangeError != .success || rangeValue.map({ CFGetTypeID($0) != AXValueGetTypeID() }) != false {
            guard let located = accessibilityRange(at: point, element: element, text: nsText) else {
                return Result(formula: nil, stage: "no-range-for-position")
            }
            var found = CFRange(location: located.location, length: located.length)
            rangeValue = AXValueCreate(.cfRange, &found)
        }
        guard let rangeValue else { return Result(formula: nil, stage: "no-range-for-position") }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.length > 0,
              range.location >= 0, range.location < nsText.length else {
            return Result(formula: nil, stage: "empty-character-range")
        }
        if let bounds = bounds(element, rangeValue), !bounds.insetBy(dx: -2, dy: -2).contains(point),
           !(bundle == "com.googlecode.iterm2" && matchesWrappedCell(element, text: nsText, range: range, point: point)) {
            return Result(formula: nil, stage: "character-bounds-mismatch")
        }

        let start = max(0, range.location - 16_384)
        let end = min(nsText.length, range.location + 16_384)
        let physicalRows = nsText.lineRange(for: NSRange(location: start, length: end - start))
        let contextRange = nsText.rangeOfComposedCharacterSequences(for: physicalRows)
        let context = nsText.substring(with: contextRange).replacingOccurrences(of: "\0", with: " ")
        let prefix = nsText.substring(with: NSRange(
            location: contextRange.location, length: range.location - contextRange.location))
        let directOffset = prefix.unicodeScalars.count
        let clippedTop = contextRange.location == 0
        let clippedBottom = NSMaxRange(contextRange) == nsText.length
        let direct = documents.match(text: context, at: directOffset,
                                     allowsClippedTop: clippedTop, allowsClippedBottom: clippedBottom)

        var fallback: HoverMath.Extraction?
        if direct == nil, allowPositionFallback, bundle == "com.googlecode.iterm2",
           let nearby = HoverTextPosition.nearbyRange(text: nsText, location: range.location),
           let located = accessibilityRange(at: point, element: element, text: nsText, searchRange: nearby),
           located.location >= contextRange.location, located.location < NSMaxRange(contextRange) {
            let before = nsText.substring(with: NSRange(
                location: contextRange.location, length: located.location - contextRange.location))
            fallback = documents.match(text: context, at: before.unicodeScalars.count,
                                       allowsClippedTop: clippedTop, allowsClippedBottom: clippedBottom)
        }
        guard let extraction = direct ?? fallback else {
            return Result(formula: nil, stage: "no-complete-formula")
        }
        return Result(formula: extraction.formula, stage: "formula-found")
    }

    private func accessibilityRange(at point: CGPoint, element: AXUIElement, text: NSString,
                                    searchRange: NSRange? = nil) -> NSRange? {
        var visibleValue: CFTypeRef?
        var visible: NSRange?
        if AXUIElementCopyAttributeValue(element, kAXVisibleCharacterRangeAttribute as CFString, &visibleValue) == .success,
           let visibleValue, CFGetTypeID(visibleValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(visibleValue as! AXValue, .cfRange, &range) {
                visible = NSRange(location: range.location, length: range.length)
            }
        }
        let available: NSRange?
        if let searchRange, let visible {
            let intersection = NSIntersectionRange(searchRange, visible)
            available = intersection.length > 0 ? intersection : nil
        } else {
            available = searchRange ?? visible
        }
        return HoverTextPosition.range(at: point, text: text, visibleRange: available) { range in
            var requested = CFRange(location: range.location, length: range.length)
            guard let value = AXValueCreate(.cfRange, &requested) else { return nil }
            var result: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &result) == .success,
                  let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
            var rectangle = CGRect.zero
            return AXValueGetValue(result as! AXValue, .cgRect, &rectangle) ? rectangle : nil
        }
    }

    private func bounds(_ element: AXUIElement, _ range: CFTypeRef) -> CGRect? {
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, range, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var rectangle = CGRect.zero
        return AXValueGetValue(value as! AXValue, .cgRect, &rectangle) ? rectangle : nil
    }

    private func matchesWrappedCell(_ element: AXUIElement, text: NSString, range: CFRange, point: CGPoint) -> Bool {
        guard range.location > 0, range.location < text.length, range.length == 1,
              (0x20...0x7e).contains(text.character(at: range.location)),
              (0x20...0x7e).contains(text.character(at: range.location - 1)) else { return false }
        var previous = CFRange(location: range.location - 1, length: 1)
        guard let parameter = AXValueCreate(.cfRange, &previous) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return false }
        var rectangle = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &rectangle), rectangle.width > 0, rectangle.height > 0,
              rectangle.width < rectangle.height * 2 else { return false }
        return rectangle.offsetBy(dx: rectangle.width, dy: 0).insetBy(dx: -2, dy: -2).contains(point)
    }
}

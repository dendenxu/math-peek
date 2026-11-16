import AppKit
import CoreText
import SwiftMath

/// Synchronously measures and draws a formula without a web view or helper process.
final class FormulaView: NSView {
    private let math = MTMathUILabel()
    private var bracedMath: BracedFormulaView?
    var mathContent: NSView { bracedMath ?? math }
    private let fallback = NSTextField(wrappingLabelWithString: "")
    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 10
    private let boxInset: CGFloat = 5
    private var boxFrames: [NSRect] = []
    private var boxLineWidth: CGFloat = 0.6
    private static let rowEnvironments = Set("matrix pmatrix bmatrix Bmatrix vmatrix Vmatrix smallmatrix aligned alignedat align align* gather gathered cases array split".split(separator: " ").map(String.init))
    private static let rowDimension = try! NSRegularExpression(pattern: #"^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:pt|em|ex|mm|cm|in|mu)$"#)
    private(set) var error: NSError?
    private(set) var renderedSize = NSSize.zero
    private(set) var renderedBody = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        math.textColor = NSColor(white: 0.94, alpha: 1)
        math.textAlignment = .left
        math.displayErrorInline = false
        fallback.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        fallback.textColor = NSColor(white: 0.88, alpha: 1)
        fallback.backgroundColor = .clear
        fallback.drawsBackground = false
        fallback.isSelectable = false
        fallback.maximumNumberOfLines = 0
        addSubview(math)
        addSubview(fallback)
        fallback.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func render(_ source: String, maxSize: NSSize) -> NSSize {
        let maximum = NSSize(width: max(1, maxSize.width), height: max(1, maxSize.height))
        let available = NSSize(width: max(1, maximum.width - 2 * horizontalPadding),
                               height: max(1, maximum.height - 2 * verticalPadding))
        let parsed = Self.stripDelimiters(source)
        let boxed = Self.unwrappedBoxes(parsed.body)
        math.fontSize = 14
        math.font?.fallbackFont = CTFontCreateWithName(NSFont.systemFont(ofSize: 14).fontName as CFString, 14, nil)
        math.labelMode = parsed.display || boxed.count > 0 ? .display : .text
        // Zero measures without wrapping, but SwiftMath draws using the view's
        // width. Keep both passes unbounded; scale the complete formula below.
        math.preferredMaxLayoutWidth = .greatestFiniteMagnitude
        renderedBody = Self.normalizedRowSpacing(boxed.body)
        bracedMath?.removeFromSuperview()
        bracedMath = BracedFormulaView.make(renderedBody, mode: math.labelMode)
        if let bracedMath { addSubview(bracedMath) }
        math.latex = bracedMath == nil ? Self.normalizedNativeCompatibility(renderedBody) : ""
        error = math.error
        let drawing = mathContent
        var content = drawing.intrinsicContentSize
        var drawingScale: CGFloat = 1
        var boxPadding: CGFloat = 0
        boxFrames.removeAll()
        if error == nil && content.width.isFinite && content.height.isFinite && content.width >= 0 && content.height >= 0 {
            boxPadding = CGFloat(boxed.count) * boxInset
            content.width += 2 * boxPadding
            content.height += 2 * boxPadding
            // SwiftMath clamps glyph sizes to 6 pt. Scale its complete drawing instead
            // of shrinking the font, which can leave long formulas wider than the panel.
            drawingScale = min(1, available.width / max(1, content.width), available.height / max(1, content.height))
            content.width *= drawingScale
            content.height *= drawingScale
            math.isHidden = bracedMath != nil
            fallback.isHidden = true
        } else {
            math.isHidden = true
            bracedMath?.isHidden = true
            fallback.isHidden = false
            fallback.stringValue = parsed.body
            fallback.toolTip = error?.localizedDescription
            // NSTextField adds its own text-cell margins. Measuring only NSString
            // can underestimate the width, wrap the last part, and clip that row.
            let natural = fallback.cell!.cellSize(forBounds: NSRect(
                origin: .zero, size: NSSize(width: available.width, height: .greatestFiniteMagnitude)))
            content = NSSize(width: min(available.width, ceil(natural.width)),
                             height: min(available.height, ceil(natural.height)))
        }
        renderedSize = NSSize(
            width: min(maximum.width, max(40, ceil(content.width) + 2 * horizontalPadding)),
            height: min(maximum.height, max(34, ceil(content.height) + 2 * verticalPadding)))
        setFrameSize(renderedSize)
        let insetX = min(horizontalPadding, max(0, (renderedSize.width - 1) / 2))
        let insetY = min(verticalPadding, max(0, (renderedSize.height - 1) / 2))
        let contentFrame = NSRect(x: insetX, y: insetY,
                                  width: max(1, renderedSize.width - 2 * insetX),
                                  height: max(1, renderedSize.height - 2 * insetY))
        drawing.frame = contentFrame.insetBy(dx: boxPadding * drawingScale, dy: boxPadding * drawingScale)
        drawing.bounds = NSRect(origin: .zero, size: NSSize(
            width: max(1, drawing.frame.width / drawingScale),
            height: max(1, drawing.frame.height / drawingScale)))
        if fallback.isHidden {
            boxLineWidth = 0.6 * drawingScale
            boxFrames = (0..<boxed.count).map { index in
                let inset = CGFloat(index) * boxInset * drawingScale + boxLineWidth / 2
                return contentFrame.insetBy(dx: inset, dy: inset)
            }
        }
        fallback.frame = contentFrame
        drawing.layoutSubtreeIfNeeded()
        needsDisplay = true
        return renderedSize
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        math.textColor?.setStroke()
        for frame in boxFrames {
            let border = NSBezierPath(rect: frame)
            border.lineWidth = boxLineWidth
            border.stroke()
        }
    }

    private static func unwrappedBoxes(_ source: String) -> (body: String, count: Int) {
        var body = source
        var count = 0
        while true {
            let candidate = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.hasPrefix("\\boxed") else { break }
            let characters = Array(candidate)
            var opening = 6
            while opening < characters.count && characters[opening].isWhitespace { opening += 1 }
            guard opening < characters.count, characters[opening] == "{" else { break }
            var depth = 1
            var index = opening + 1
            while index < characters.count && depth > 0 {
                if characters[index] == "\\" {
                    index += 2
                    continue
                }
                if characters[index] == "{" { depth += 1 }
                if characters[index] == "}" { depth -= 1 }
                index += 1
            }
            guard depth == 0, index == characters.count else { break }
            body = String(characters[(opening + 1)..<(index - 1)])
            count += 1
        }
        return (body, count)
    }

    static func normalizedRowSpacing(_ source: String) -> String {
        let characters = Array(source)
        var active: [String] = []
        var depth = 0
        var index = 0
        var result = ""
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                if characters[index + 1] == "\\" {
                    result += "\\\\"
                    index += 2
                    // SwiftMath treats row spacing options as visible math. Keep its
                    // default spacing, removing only valid options at environment level.
                    if depth == 0, let environment = active.last, rowEnvironments.contains(environment) {
                        var opening = index
                        while opening < characters.count && characters[opening].isWhitespace { opening += 1 }
                        if opening < characters.count, characters[opening] == "[",
                           let closing = characters[(opening + 1)...].firstIndex(of: "]") {
                            let value = String(characters[(opening + 1)..<closing])
                            if rowDimension.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
                                index = closing + 1
                            }
                        }
                    }
                    continue
                }
                var end = index + 1
                while end < characters.count, characters[end].isASCII, characters[end].isLetter { end += 1 }
                let command = String(characters[(index + 1)..<end])
                if depth == 0, command == "begin" || command == "end", end < characters.count,
                   characters[end] == "{", let closing = characters[(end + 1)...].firstIndex(of: "}") {
                    let environment = String(characters[(end + 1)..<closing])
                    if command == "begin" { active.append(environment) }
                    else if active.last == environment { active.removeLast() }
                    result += String(characters[index...closing])
                    index = closing + 1
                    continue
                }
                let next = max(index + 2, end)
                result += String(characters[index..<next])
                index = next
                continue
            }
            if character == "{" { depth += 1 }
            else if character == "}" { depth = max(0, depth - 1) }
            result.append(character)
            index += 1
        }
        return result
    }

    /// SwiftMath deliberately implements a smaller command set than KaTeX.
    /// Preserve standard two-argument stacking commands by expressing them as
    /// a compact one-column math table. Middle delimiters use its native sized
    /// delimiter command. These conversions preserve the original source body.
    static func normalizedNativeCompatibility(_ source: String) -> String {
        let characters = Array(source)

        func bracedGroup(at opening: Int) -> (body: String, next: Int)? {
            guard characters.indices.contains(opening), characters[opening] == "{" else { return nil }
            var depth = 1
            var index = opening + 1
            let start = index
            while index < characters.count {
                if characters[index] == "\\", index + 1 < characters.count {
                    index += 2
                    continue
                }
                if characters[index] == "{" { depth += 1 }
                else if characters[index] == "}" {
                    depth -= 1
                    if depth == 0 {
                        return (String(characters[start..<index]), index + 1)
                    }
                }
                index += 1
            }
            return nil
        }

        func skippingWhitespace(from start: Int) -> Int {
            var index = start
            while index < characters.count, characters[index].isWhitespace { index += 1 }
            return index
        }

        var result = ""
        var index = 0
        var groupDepth = 0
        var leftDepths: [Int] = []
        while index < characters.count {
            guard characters[index] == "\\" else {
                if characters[index] == "{" { groupDepth += 1 }
                else if characters[index] == "}" { groupDepth -= 1 }
                result.append(characters[index])
                index += 1
                continue
            }
            if index + 1 < characters.count, characters[index + 1] == "\\" {
                result += "\\\\"
                index += 2
                continue
            }
            var commandEnd = index + 1
            while commandEnd < characters.count, characters[commandEnd].isASCII,
                  characters[commandEnd].isLetter {
                commandEnd += 1
            }
            let command = String(characters[(index + 1)..<commandEnd])
            if command.isEmpty {
                let end = min(index + 2, characters.count)
                result += String(characters[index..<end])
                index = end
                continue
            }
            if command == "left" { leftDepths.append(groupDepth) }
            else if command == "right", leftDepths.last == groupDepth { leftDepths.removeLast() }
            else if command == "middle", leftDepths.last == groupDepth {
                result += "\\bigm"
                index = commandEnd
                continue
            }
            guard command == "underset" || command == "overset" || command == "stackrel" else {
                let end = max(index + 1, commandEnd)
                result += String(characters[index..<end])
                index = end
                continue
            }
            let firstOpening = skippingWhitespace(from: commandEnd)
            guard let first = bracedGroup(at: firstOpening) else {
                result += String(characters[index..<commandEnd])
                index = commandEnd
                continue
            }
            let secondOpening = skippingWhitespace(from: first.next)
            guard let second = bracedGroup(at: secondOpening) else {
                result += String(characters[index..<commandEnd])
                index = commandEnd
                continue
            }
            let annotation = normalizedNativeCompatibility(first.body)
            let base = normalizedNativeCompatibility(second.body)
            if command == "underset" {
                result += "{\\begin{smallmatrix}\\textstyle " + base +
                    "\\\\\\scriptstyle " + annotation + "\\end{smallmatrix}}"
            } else {
                result += "{\\begin{smallmatrix}\\scriptstyle " + annotation +
                    "\\\\\\textstyle " + base + "\\end{smallmatrix}}"
            }
            index = second.next
        }
        return result
    }

    private static func stripDelimiters(_ source: String) -> (body: String, display: Bool) {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        for (opening, closing, display) in [("$$", "$$", true), ("\\[", "\\]", true),
                                             ("\\(", "\\)", false), ("$", "$", false)] {
            if text.hasPrefix(opening) && text.hasSuffix(closing) && text.count >= opening.count + closing.count {
                return (String(text.dropFirst(opening.count).dropLast(closing.count)), display)
            }
        }
        return (text, true)
    }
}

/// Compose brace annotations on the expression's baseline. SwiftMath still
/// measures and draws each math fragment; only the horizontal brace is ours.
final class BracedFormulaView: NSView {
    private let naturalSize: NSSize
    let baseline: CGFloat
    private(set) var curve: NSBezierPath?

    override var intrinsicContentSize: NSSize { naturalSize }

    private init(size: NSSize, baseline: CGFloat) {
        naturalSize = size
        self.baseline = baseline
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(white: 0.94, alpha: 1).setStroke()
        curve?.stroke()
    }

    private enum Part {
        case math(String)
        case brace(body: String, annotation: String?, over: Bool)
    }
    private enum Failure: Error { case unsupported }

    static func make(_ source: String, mode: MTMathUILabelMode) -> BracedFormulaView? {
        guard source.contains("\\underbrace") || source.contains("\\overbrace"),
              let parts = try? split(source), parts.contains(where: {
                  if case .brace = $0 { return true }; return false
              }) else { return nil }
        return try? layout(parts, fontSize: 14, mode: mode, depth: 0)
    }

    private static func split(_ source: String) throws -> [Part] {
        let chars = Array(source)
        func skipSpace(_ start: Int) -> Int {
            var i = start
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            return i
        }
        func group(_ start: Int) throws -> (String, Int) {
            let opening = skipSpace(start)
            guard opening < chars.count, chars[opening] == "{" else { throw Failure.unsupported }
            var depth = 1
            var i = opening + 1
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == "{" { depth += 1 }
                if chars[i] == "}" { depth -= 1 }
                if depth == 0 { return (String(chars[(opening + 1)..<i]), i + 1) }
                i += 1
            }
            throw Failure.unsupported
        }

        var parts: [Part] = []
        var start = 0
        var i = 0
        var depth = 0
        var leftDepth = 0
        while i < chars.count {
            guard chars[i] == "\\" else {
                if chars[i] == "{" { depth += 1 }
                if chars[i] == "}" { depth -= 1 }
                i += 1
                continue
            }
            var end = i + 1
            while end < chars.count, chars[end].isASCII, chars[end].isLetter { end += 1 }
            let command = String(chars[(i + 1)..<end])
            if command == "left" { leftDepth += 1 }
            if command == "right" { leftDepth -= 1 }
            guard command == "underbrace" || command == "overbrace" else {
                i = max(i + 2, end)
                continue
            }
            // Do not split a fraction argument, text group, or paired delimiter.
            // Unsupported contexts retain the normal readable-source fallback.
            guard depth == 0, leftDepth == 0 else { throw Failure.unsupported }
            let (body, next) = try group(end)
            let over = command == "overbrace"
            var after = next
            var annotation: String?
            let script = skipSpace(next)
            if script < chars.count, chars[script] == "_" || chars[script] == "^" {
                guard chars[script] == (over ? "^" : "_") else { throw Failure.unsupported }
                (annotation, after) = try group(script + 1)
            }
            let following = skipSpace(after)
            if following < chars.count, chars[following] == "_" || chars[following] == "^" {
                throw Failure.unsupported
            }
            if start < i { parts.append(.math(String(chars[start..<i]))) }
            parts.append(.brace(body: body, annotation: annotation, over: over))
            i = after
            start = after
        }
        if start < chars.count { parts.append(.math(String(chars[start...]))) }
        return parts
    }

    private static func math(_ source: String, fontSize: CGFloat, mode: MTMathUILabelMode,
                             leadingOperand: Bool, trailingOperand: Bool) throws -> BracedFormulaView {
        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return BracedFormulaView(size: .zero, baseline: 0)
        }
        let label = MTMathUILabel()
        label.fontSize = fontSize
        label.font?.fallbackFont = CTFontCreateWithName(NSFont.systemFont(ofSize: fontSize).fontName as CFString, fontSize, nil)
        label.labelMode = mode
        label.textAlignment = .left
        label.textColor = NSColor(white: 0.94, alpha: 1)
        label.displayErrorInline = false
        label.preferredMaxLayoutWidth = .greatestFiniteMagnitude
        label.latex = FormulaView.normalizedNativeCompatibility(source)
        // Zero-width ordinary atoms stand in for adjacent braced expressions. This
        // lets SwiftMath retain binary-operator spacing at fragment boundaries.
        func operand() -> MTMathAtom {
            MTMathListBuilder.build(fromString: "\\text{\u{200B}}")!.atoms[0]
        }
        if leadingOperand { label.mathList?.insert(operand(), at: 0) }
        if trailingOperand { label.mathList?.add(operand()) }
        let size = label.intrinsicContentSize
        guard label.error == nil, size.width.isFinite, size.height.isFinite,
              size.width >= 0, size.height >= 0 else { throw Failure.unsupported }
        let measured = NSSize(width: size.width, height: max(fontSize / 2, size.height))
        label.frame = NSRect(origin: .zero, size: measured)
        label.layoutSubtreeIfNeeded()
        guard let display = label.displayList else { throw Failure.unsupported }
        let baseline = (measured.height - max(fontSize / 2, display.ascent + display.descent)) / 2 + display.descent
        let view = BracedFormulaView(size: measured, baseline: baseline)
        view.addSubview(label)
        return view
    }

    private static func layout(_ parts: [Part], fontSize: CGFloat, mode: MTMathUILabelMode, depth: Int) throws -> BracedFormulaView {
        guard depth < 32 else { throw Failure.unsupported }
        let fontSize = max(6, fontSize)
        var children: [BracedFormulaView] = []
        for (index, part) in parts.enumerated() {
            switch part {
            case .math(let source):
                let child = try math(source, fontSize: fontSize, mode: mode,
                                     leadingOperand: index > 0, trailingOperand: index + 1 < parts.count)
                if child.naturalSize != .zero { children.append(child) }
            case .brace(let body, let annotation, let over):
                let base = try layout(split(body), fontSize: fontSize, mode: .display, depth: depth + 1)
                let note = try annotation.map { try layout(split($0), fontSize: fontSize * 0.7, mode: .text, depth: depth + 1) }
                children.append(brace(base, note: note, over: over, fontSize: fontSize))
            }
        }
        let baseline = children.map(\.baseline).max() ?? 0
        let ascent = children.map { $0.naturalSize.height - $0.baseline }.max() ?? 0
        var width: CGFloat = 0
        for child in children {
            child.setFrameOrigin(NSPoint(x: width, y: baseline - child.baseline))
            width += child.naturalSize.width
        }
        let view = BracedFormulaView(size: NSSize(width: width, height: ascent + baseline), baseline: baseline)
        children.forEach(view.addSubview)
        return view
    }

    private static func brace(_ base: BracedFormulaView, note: BracedFormulaView?, over: Bool, fontSize: CGFloat) -> BracedFormulaView {
        let stroke = fontSize / 24
        let gap = fontSize * 0.12
        let braceWidth = max(base.naturalSize.width, fontSize * 0.65)
        let braceHeight = fontSize * 0.28
        let width = max(braceWidth + stroke, note?.naturalSize.width ?? 0)
        let bottom = stroke / 2 + (note.map { $0.naturalSize.height + gap } ?? 0)
        let baseY = bottom + braceHeight + gap + stroke / 2
        let height = baseY + base.naturalSize.height
        let view = BracedFormulaView(size: NSSize(width: width, height: height),
                                    baseline: over ? base.baseline : baseY + base.baseline)
        base.setFrameOrigin(NSPoint(x: (width - base.naturalSize.width) / 2, y: over ? 0 : baseY))
        view.addSubview(base)
        if let note {
            note.setFrameOrigin(NSPoint(x: (width - note.naturalSize.width) / 2,
                                        y: over ? height - note.naturalSize.height - stroke / 2 : stroke / 2))
            view.addSubview(note)
        }
        let left = (width - braceWidth) / 2
        let right = left + braceWidth
        let mid = width / 2
        let corner = min(braceHeight, braceWidth / 4)
        let centerY = bottom + braceHeight / 2
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: over ? height - y : y) }
        let path = NSBezierPath()
        path.move(to: point(left, bottom + braceHeight))
        path.curve(to: point(left + corner, centerY), controlPoint1: point(left, centerY), controlPoint2: point(left, centerY))
        path.line(to: point(mid - corner, centerY))
        path.curve(to: point(mid, bottom), controlPoint1: point(mid, centerY), controlPoint2: point(mid, centerY))
        path.curve(to: point(mid + corner, centerY), controlPoint1: point(mid, centerY), controlPoint2: point(mid, centerY))
        path.line(to: point(right - corner, centerY))
        path.curve(to: point(right, bottom + braceHeight), controlPoint1: point(right, centerY), controlPoint2: point(right, centerY))
        path.lineWidth = stroke
        path.lineCapStyle = .round
        view.curve = path
        return view
    }
}

import AppKit
import CoreText
import SwiftMath

/// Synchronously measures and draws a formula without a web view or helper process.
final class FormulaView: NSView {
    private let math = MTMathUILabel()
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
        math.latex = renderedBody
        error = math.error
        var content = math.intrinsicContentSize
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
            math.isHidden = false
            fallback.isHidden = true
        } else {
            math.isHidden = true
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
        math.frame = contentFrame.insetBy(dx: boxPadding * drawingScale, dy: boxPadding * drawingScale)
        math.bounds = NSRect(origin: .zero, size: NSSize(
            width: max(1, math.frame.width / drawingScale),
            height: max(1, math.frame.height / drawingScale)))
        if !math.isHidden {
            boxLineWidth = 0.6 * drawingScale
            boxFrames = (0..<boxed.count).map { index in
                let inset = CGFloat(index) * boxInset * drawingScale + boxLineWidth / 2
                return contentFrame.insetBy(dx: inset, dy: inset)
            }
        }
        fallback.frame = contentFrame
        math.layoutSubtreeIfNeeded()
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

import AppKit
import CoreText
import SwiftMath

/// Synchronously measures and draws a formula without a web view or helper process.
final class FormulaView: NSView {
    private let math = MTMathUILabel()
    private let fallback = NSTextField(wrappingLabelWithString: "")
    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 10
    private(set) var error: NSError?
    private(set) var renderedSize = NSSize.zero

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
        math.fontSize = 14
        math.font?.fallbackFont = CTFontCreateWithName(NSFont.systemFont(ofSize: 14).fontName as CFString, 14, nil)
        math.labelMode = parsed.display ? .display : .text
        math.preferredMaxLayoutWidth = 0
        math.latex = parsed.body
        error = math.error
        var content = math.intrinsicContentSize
        var drawingScale: CGFloat = 1
        if error == nil && content.width.isFinite && content.height.isFinite && content.width >= 0 && content.height >= 0 {
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
            let attributes: [NSAttributedString.Key: Any] = [.font: fallback.font!]
            let natural = (parsed.body as NSString).boundingRect(
                with: available, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
            content = NSSize(width: ceil(natural.width), height: ceil(natural.height))
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
        math.frame = contentFrame
        math.bounds = NSRect(origin: .zero, size: NSSize(
            width: contentFrame.width / drawingScale,
            height: contentFrame.height / drawingScale))
        fallback.frame = contentFrame
        math.layoutSubtreeIfNeeded()
        needsDisplay = true
        return renderedSize
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

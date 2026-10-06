import AppKit

class HoverPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns only hover-window construction, formula rendering, and placement.
/// Capture and parsing generations cannot mutate view geometry directly.
final class HoverPresenter {
    let panel: HoverPanel
    let formulaView: FormulaView

    init(panel suppliedPanel: HoverPanel? = nil) {
        panel = suppliedPanel ?? HoverPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 34),
                                            styleMask: [.borderless, .nonactivatingPanel],
                                            backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let backdrop = NSVisualEffectView(frame: panel.contentView!.bounds)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.appearance = NSAppearance(named: .darkAqua)
        let cornerRadius: CGFloat = 10
        let maskSize = NSSize(width: cornerRadius * 2 + 1, height: cornerRadius * 2 + 1)
        let materialMask = NSImage(size: maskSize, flipped: false) { rectangle in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rectangle, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        materialMask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius,
                                              bottom: cornerRadius, right: cornerRadius)
        materialMask.resizingMode = .stretch
        backdrop.maskImage = materialMask
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = cornerRadius
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = NSColor(srgbRed: 80 / 255, green: 80 / 255, blue: 80 / 255, alpha: 1).cgColor
        let tint = NSView(frame: backdrop.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedWhite: 12 / 255, alpha: 0.14).cgColor
        tint.autoresizingMask = [.width, .height]
        backdrop.addSubview(tint)
        formulaView = FormulaView(frame: backdrop.bounds)
        // FormulaView measures itself. A window resize must not apply the same
        // size delta again and clip a smaller formula after a larger one.
        formulaView.autoresizingMask = []
        backdrop.addSubview(formulaView)
        panel.contentView = backdrop
    }

    func hide() { panel.orderOut(nil) }

    func present(_ text: String, anchor: NSPoint) {
        let visible = screen(at: anchor)
        let size = formulaView.render(text, maxSize: NSSize(
            width: min(760, visible.width - 24), height: min(460, visible.height - 24)))
        show(width: size.width, height: size.height, anchor: anchor)
    }

    func show(width: CGFloat, height: CGFloat, anchor: NSPoint) {
        let visible = screen(at: anchor)
        let width = min(max(40, width), min(760, visible.width - 24))
        let height = min(max(34, height), min(460, visible.height - 24))
        var x = anchor.x + 18
        var y = anchor.y - height - 20
        if x + width > visible.maxX - 12 { x = visible.maxX - width - 12 }
        if y < visible.minY + 12 { y = min(anchor.y + 24, visible.maxY - height - 12) }
        panel.setFrame(NSRect(x: max(visible.minX + 12, x), y: y, width: width, height: height),
                       display: true, animate: false)
        panel.orderFrontRegardless()
    }

    private func screen(at anchor: NSPoint) -> NSRect {
        (NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main)?.visibleFrame ??
            NSRect(x: 0, y: 0, width: 1200, height: 800)
    }
}

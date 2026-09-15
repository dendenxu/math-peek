import AppKit
import SwiftMath

// Exercise the real presentation path without opening a test window.
final class HiddenHoverPanel: HoverPanel {
    override func orderFrontRegardless() {}
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let hover = HoverController(resources: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                            enabled: true, report: { _ in })
hover.timer?.invalidate()
let hidden = HiddenHoverPanel(contentRect: hover.panel.frame, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
hidden.contentView = hover.panel.contentView
hover.panel = hidden
hover.anchor = NSScreen.main.map { NSPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? .zero

let tall = "$$\\begin{aligned}" + (1...12).map { "x_{\($0)} &= \\frac{\($0)}{2}" }.joined(separator: "\\\\") + "\\end{aligned}$$"
let wide = "$$" + (1...32).map { "\\frac{x_{\($0)}}{\($0)}" }.joined(separator: "+") + "$$"
let sources = ["$x$", tall, "$$\\frac{P}{P+R}$$", "$y$", wide, tall, "$z$",
               "$$\\boxed{K = \\frac{P}{P+R}}$$", tall, "$x$"]
var failed = 0
for (index, source) in sources.enumerated() {
    hover.formula = source
    hover.present(source)
    let parent = hover.panel.contentView!
    parent.layoutSubtreeIfNeeded()
    let label = hover.formulaView.subviews.compactMap { $0 as? MTMathUILabel }.first!
    let pass = hover.formulaView.frame == parent.bounds && hover.formulaView.bounds.size == hover.formulaView.renderedSize
        && hover.formulaView.bounds.contains(label.frame) && hover.formulaView.error == nil
    if !pass { failed += 1 }
    print("\(pass ? "PASS" : "FAIL") panel-transition-\(index): panel=\(parent.bounds.size) content=\(hover.formulaView.frame.size)")
}
print("Result: \(sources.count - failed)/\(sources.count) panel layout checks passed")
exit(failed == 0 ? 0 : 1)

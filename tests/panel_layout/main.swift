import AppKit
import SwiftMath

// Exercise the real presentation path without opening a test window.
final class HiddenHoverPanel: HoverPanel {
    override func orderFrontRegardless() {}
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let hidden = HiddenHoverPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 34),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
let hover = HoverController(enabled: true, presenter: HoverPresenter(panel: hidden), report: { _ in })
hover.timer?.invalidate()
hover.anchor = NSScreen.main.map { NSPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? .zero

let tall = "$$\\begin{aligned}" + (1...12).map { "x_{\($0)} &= \\frac{\($0)}{2}" }.joined(separator: "\\\\") + "\\end{aligned}$$"
let wide = "$$" + (1...32).map { "\\frac{x_{\($0)}}{\($0)}" }.joined(separator: "+") + "$$"
let sigmoid = "$$\n  " + #"S(f_q,f_k)=\operatorname{sigmoid}(f_q^\top f_k)."# + "\n  $$"
let sources = ["$x$", tall, "$$\\frac{P}{P+R}$$", "$y$", wide, tall, "$z$",
               "$$\\boxed{K = \\frac{P}{P+R}}$$", tall, "$x$", sigmoid, tall, sigmoid,
               #"$$\underbrace{\int_r^t v(z_\tau,\tau)\,d\tau}_{\text{位移}}=z_t-z_r$$"#,
               "$x$", #"\boxed{\underbrace{y}_{\text{训练目标}}=x}"#, "$x$"]
var failed = 0
func mathLabels(_ view: NSView) -> [MTMathUILabel] {
    if let label = view as? MTMathUILabel { return [label] }
    return view.subviews.flatMap(mathLabels)
}
for (index, source) in sources.enumerated() {
    hover.formula = source
    hover.present(source)
    let parent = hover.panel.contentView!
    parent.layoutSubtreeIfNeeded()
    let drawing = hover.formulaView.mathContent
    if let bitmap = hover.formulaView.bitmapImageRepForCachingDisplay(in: hover.formulaView.bounds) {
        hover.formulaView.cacheDisplay(in: hover.formulaView.bounds, to: bitmap)
    }
    let pass = hover.formulaView.frame == parent.bounds && hover.formulaView.bounds.size == hover.formulaView.renderedSize
        && hover.formulaView.bounds.contains(drawing.frame) && hover.formulaView.error == nil && !drawing.isHidden
        && mathLabels(drawing).allSatisfy { label in
            guard let display = label.displayList else { return false }
            return display.width <= label.bounds.width + 1 && display.ascent + display.descent <= label.bounds.height + 1
        }
    if !pass { failed += 1 }
    print("\(pass ? "PASS" : "FAIL") panel-transition-\(index): panel=\(parent.bounds.size) content=\(hover.formulaView.frame.size)")
}
let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
hover.formula = ""
hover.lastMovement = now.addingTimeInterval(-1)
hover.lastRead = now.addingTimeInterval(-0.1)
hover.lastPositionFallbackGeneration = hover.generation
var checked = sources.count
func checkRetry(_ condition: Bool, _ name: String) {
    checked += 1
    if !condition { failed += 1 }
    print("\(condition ? "PASS" : "FAIL") \(name)")
}
checkRetry(!hover.shouldTryPositionFallback(at: now), "failed-position-fallback-does-not-busy-retry")
checkRetry(hover.shouldTryPositionFallback(at: now.addingTimeInterval(1)),
           "failed-position-fallback-retries-after-refresh-without-mouse-movement")
hover.formula = "$x$"
checkRetry(!hover.shouldTryPositionFallback(at: now.addingTimeInterval(1)), "visible-formula-needs-no-fallback")
hover.formula = ""
hover.lastMovement = now
checkRetry(!hover.shouldTryPositionFallback(at: now), "moving-pointer-waits-before-bounds-fallback")
hover.lastMovement = now.addingTimeInterval(-1)
hover.generation += 1
checkRetry(hover.shouldTryPositionFallback(at: now), "new-pointer-position-can-retry-immediately")

print("Result: \(checked - failed)/\(checked) panel layout and retry checks passed")
exit(failed == 0 ? 0 : 1)

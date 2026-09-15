import AppKit
import SwiftMath

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let view = FormulaView(frame: .zero)
var checked = 0
var failed = 0

func check(_ condition: Bool, _ name: String) {
    checked += 1
    if !condition { failed += 1 }
    print("\(condition ? "PASS" : "FAIL") \(name)")
}

guard let label = view.subviews.compactMap({ $0 as? MTMathUILabel }).first,
      let fallback = view.subviews.compactMap({ $0 as? NSTextField }).first else {
    print("FAIL: FormulaView does not contain its native math and fallback views")
    exit(1)
}

struct Sample {
    let name: String
    let source: String
    let body: String
    let maximum: NSSize
}
let standard = NSSize(width: 760, height: 460)
let aligned = "\\begin{aligned}a &= b+c \\\\ x &= \\sqrt{\\frac{1}{2}}\\end{aligned}"
let matrix = "\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}"
let long = (1...45).map { "\\frac{x_{\($0)}^2+1}{\($0)}" }.joined(separator: "+")
let tall = "\\begin{aligned}" + (1...24).map { "x_{\($0)} &= \\frac{\($0)}{2}" }.joined(separator: "\\\\") + "\\end{aligned}"
let samples = [
    Sample(name: "inline", source: "$e^{i\\pi}+1=0$", body: "e^{i\\pi}+1=0", maximum: standard),
    Sample(name: "inline-parentheses", source: "\\(x^2+y^2=1\\)", body: "x^2+y^2=1", maximum: standard),
    Sample(name: "fraction", source: "$$\\frac{1}{2}+\\sum_{i=1}^{n}i^2$$", body: "\\frac{1}{2}+\\sum_{i=1}^{n}i^2", maximum: standard),
    Sample(name: "multiline-aligned", source: "\\[" + aligned + "\\]", body: aligned, maximum: standard),
    Sample(name: "matrix", source: matrix, body: matrix, maximum: standard),
    Sample(name: "long-expression", source: "$$" + long + "$$", body: long, maximum: standard),
    Sample(name: "long-expression-narrow-screen", source: long, body: long, maximum: NSSize(width: 280, height: 200)),
    Sample(name: "many-aligned-rows", source: tall, body: tall, maximum: NSSize(width: 360, height: 180)),
    Sample(name: "small-available-space", source: "\\sqrt{\\frac{1}{2}}", body: "\\sqrt{\\frac{1}{2}}", maximum: NSSize(width: 64, height: 48)),
]

for sample in samples {
    let began = Date()
    let size = view.render(sample.source, maxSize: sample.maximum)
    let elapsed = Date().timeIntervalSince(began) * 1000
    let content = label.intrinsicContentSize
    check(view.error == nil && label.error == nil && !label.isHidden && fallback.isHidden, "\(sample.name)/native-render")
    check(label.latex == sample.body, "\(sample.name)/source")
    check(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 &&
          size.width <= sample.maximum.width && size.height <= sample.maximum.height, "\(sample.name)/panel-bounds")
    check(content.width <= label.bounds.width + 1 && content.height <= label.bounds.height + 1 &&
          view.bounds.contains(label.frame), "\(sample.name)/content-fits")
    let display = label.displayList
    check(display != nil && display!.width <= label.bounds.width + 1 &&
          display!.ascent + display!.descent <= label.bounds.height + 1, "\(sample.name)/drawn-content-fits")
    print("METRIC \(sample.name): \(String(format: "%.2f", elapsed))ms, panel=\(size), content=\(content), font=\(label.fontSize)")
}

let normal = "$e^{i\\pi}+1=0$"
let first = view.render(normal, maxSize: standard)
_ = view.render(long, maxSize: NSSize(width: 280, height: 100))
let second = view.render(normal, maxSize: standard)
check(first == second && label.fontSize == 14, "large-to-small-restores-font-and-size")
for (name, source) in [("wide", long), ("tall", tall)] {
    _ = view.render(source, maxSize: standard)
    let small = view.render("$x$", maxSize: standard)
    check(small.width <= 40 && small.height <= 34 && label.fontSize == 14 && label.latex == "x",
          "\(name)-to-singleton-shrinks-to-40x34")
}

let malformed = "\\frac{1}{"
let fallbackSize = view.render("$$" + malformed + "$$", maxSize: NSSize(width: 300, height: 150))
check(view.error != nil && label.isHidden && !fallback.isHidden && fallback.stringValue == malformed,
      "malformed-formula-shows-readable-source")
check(fallbackSize.width <= 300 && fallbackSize.height <= 150 && view.bounds.contains(fallback.frame),
      "fallback-fits-panel")
_ = view.render(normal, maxSize: standard)
check(view.error == nil && !label.isHidden && fallback.isHidden, "valid-formula-recovers-after-error")

print("Result: \(checked - failed)/\(checked) native rendering checks passed")
exit(failed == 0 ? 0 : 1)

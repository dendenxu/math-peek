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
let sigmoidBody = #"S(f_q,f_k)=\operatorname{sigmoid}(f_q^\top f_k)."#
let sigmoidSource = "$$\n  " + sigmoidBody + "\n  $$"
let aligned = "\\begin{aligned}a &= b+c \\\\ x &= \\sqrt{\\frac{1}{2}}\\end{aligned}"
let matrix = "\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}"
let long = (1...45).map { "\\frac{x_{\($0)}^2+1}{\($0)}" }.joined(separator: "+")
let tall = "\\begin{aligned}" + (1...24).map { "x_{\($0)} &= \\frac{\($0)}{2}" }.joined(separator: "\\\\") + "\\end{aligned}"
// Preserve the source's omitted operators/subscripts; only transport-damaged
// row separators should be repaired before rendering these complete formulas.
let kalmanSource = #"""
$$
\begin{aligned}
\hat{\mathbf{x}}{t|t-1}
&= \mathbf{A}\hat{\mathbf{x}}{t-1|t-1}

- \mathbf{B}\mathbf{u}{t-1}
  \[8pt]
  \mathbf{P}{t|t-1}
  &= \mathbf{A}\mathbf{P}_{t-1|t-1}\mathbf{A}^{\mathsf T}

- \mathbf{Q}
  \[8pt]
  \mathbf{r}_t
  &= \mathbf{z}t-\mathbf{H}\hat{\mathbf{x}}{t|t-1}
  \[8pt]
  \mathbf{S}t
  &= \mathbf{H}\mathbf{P}{t|t-1}\mathbf{H}^{\mathsf T}

- \mathbf{R}
  \[8pt]
  \mathbf{K}t
  &= \mathbf{P}{t|t-1}\mathbf{H}^{\mathsf T}\mathbf{S}t^{-1}
  \[8pt]
  \hat{\mathbf{x}}{t|t}
  &= \hat{\mathbf{x}}_{t|t-1}+\mathbf{K}_t\mathbf{r}t
  \[8pt]
  \mathbf{P}{t|t}
  &= (\mathbf{I}-\mathbf{K}t\mathbf{H})
  \mathbf{P}{t|t-1}
  (\mathbf{I}-\mathbf{K}_t\mathbf{H})^{\mathsf T}

- \mathbf{K}_t\mathbf{R}\mathbf{K}_t^{\mathsf T}
  \end{aligned}
  $$
"""#
let matricesSource = #"""
# $$
\begin{bmatrix}
\hat p_{t|t-1}\
\hat v_{t|t-1}
\end{bmatrix}

\begin{bmatrix}
1 & \Delta t\
0 & 1
\end{bmatrix}
\begin{bmatrix}
\hat p_{t-1|t-1}\
\hat v_{t-1|t-1}
\end{bmatrix}
+
\begin{bmatrix}
\frac{1}{2}\Delta t^2\
\Delta t
\end{bmatrix}
a_{t-1}
$$
"""#
let markdownStrippedDisplaySource = #"""
[
pvalue_h =
\frac{\sum_q\sum_{k\in pool_h} score[h,q,k]}
{\sum_q\sum_{k\in history} score[h,q,k]}
]
"""#
var samples = [
    Sample(name: "inline", source: "$e^{i\\pi}+1=0$", body: "e^{i\\pi}+1=0", maximum: standard),
    Sample(name: "inline-parentheses", source: "\\(x^2+y^2=1\\)", body: "x^2+y^2=1", maximum: standard),
    Sample(name: "fraction", source: "$$\\frac{1}{2}+\\sum_{i=1}^{n}i^2$$", body: "\\frac{1}{2}+\\sum_{i=1}^{n}i^2", maximum: standard),
    Sample(name: "sigmoid-multiline-source", source: sigmoidSource, body: "\n  " + sigmoidBody + "\n  ", maximum: standard),
    Sample(name: "sigmoid-single-line-source", source: "$$" + sigmoidBody + "$$", body: sigmoidBody, maximum: standard),
    Sample(name: "sigmoid-narrow-panel", source: sigmoidSource, body: "\n  " + sigmoidBody + "\n  ", maximum: NSSize(width: 110, height: 80)),
    Sample(name: "multiline-aligned", source: "\\[" + aligned + "\\]", body: aligned, maximum: standard),
    Sample(name: "matrix", source: matrix, body: matrix, maximum: standard),
    Sample(name: "long-expression", source: "$$" + long + "$$", body: long, maximum: standard),
    Sample(name: "long-expression-narrow-screen", source: long, body: long, maximum: NSSize(width: 280, height: 200)),
    Sample(name: "many-aligned-rows", source: tall, body: tall, maximum: NSSize(width: 360, height: 180)),
    Sample(name: "small-available-space", source: "\\sqrt{\\frac{1}{2}}", body: "\\sqrt{\\frac{1}{2}}", maximum: NSSize(width: 64, height: 48)),
    Sample(name: "boxed-kalman-gain", source: #"$$\boxed{K = \frac{P}{P+R}}$$"#,
           body: #"K = \frac{P}{P+R}"#, maximum: standard),
    Sample(name: "nested-boxes", source: #"\boxed{\boxed{\frac{x}{y}}}"#,
           body: #"\frac{x}{y}"#, maximum: standard),
    Sample(name: "boxed-escaped-braces", source: #"\boxed {\{x\}}"#,
           body: #"\{x\}"#, maximum: standard),
    Sample(name: "boxed-small-space", source: #"\boxed{\frac{x}{y}}"#,
           body: #"\frac{x}{y}"#, maximum: NSSize(width: 50, height: 42)),
    Sample(name: "boxed-aligned-row-spacing", source: #"\boxed{\begin{aligned}a&=b\\[8pt]c&=d\end{aligned}}"#,
           body: #"\begin{aligned}a&=b\\c&=d\end{aligned}"#, maximum: standard),
]

let markdownDisplayExpected = #"""
\[
pvalue_h =
\frac{\sum_q\sum_{k\in pool_h} score[h,q,k]}
{\sum_q\sum_{k\in history} score[h,q,k]}
\]
"""#
let markdownDisplayScalars = Array(markdownStrippedDisplaySource.unicodeScalars)
let markdownDisplayOffsets = markdownDisplayScalars.indices.filter {
    !markdownDisplayScalars[$0].properties.isWhitespace
}
let markdownDisplayExtracted = markdownDisplayOffsets.map {
    HoverMath.extract(text: markdownStrippedDisplaySource, offset: $0)
}
check(!markdownDisplayExtracted.isEmpty && markdownDisplayExtracted.allSatisfy { $0 == markdownDisplayExpected },
      "markdown-stripped-display/extracts-complete-formula-from-every-nonspace-character")
if let formula = markdownDisplayExtracted.first ?? nil {
    let body = String(formula.dropFirst(2).dropLast(2))
    samples.append(Sample(name: "markdown-stripped-display", source: formula, body: body, maximum: standard))
}

let sigmoidScalars = Array(sigmoidSource.unicodeScalars)
check(sigmoidScalars.indices.filter { !sigmoidScalars[$0].properties.isWhitespace }.allSatisfy {
    HoverMath.extract(text: sigmoidSource, offset: $0) == sigmoidSource
}, "sigmoid/extracts-complete-formula-from-every-nonspace-character")

let exactFormulas = [
    ("full-kalman-aligned", kalmanSource, kalmanSource.replacingOccurrences(of: #"\[8pt]"#, with: #"\\[8pt]"#)),
    ("full-multi-matrix", matricesSource, matricesSource.replacingOccurrences(of: "\\\n", with: "\\\\\n")),
]
for (name, source, repaired) in exactFormulas {
    let start = repaired.range(of: "$$")!.lowerBound
    let expected = String(repaired[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    let body = String(expected.dropFirst(2).dropLast(2)).replacingOccurrences(of: #"\\[8pt]"#, with: #"\\"#)
    let scalars = Array(source.unicodeScalars)
    let offsets = scalars.indices.filter { scalars[$0] == "\\" }
    let extracted = offsets.map { HoverMath.extract(text: source, offset: $0) }
    check(!extracted.isEmpty && extracted.allSatisfy { $0 == expected }, "\(name)/extracts-complete-formula-from-every-command")
    if let formula = extracted.first ?? nil {
        samples.append(Sample(name: name, source: formula, body: body, maximum: standard))
        samples.append(Sample(name: name + "-small-screen", source: formula, body: body,
                              maximum: NSSize(width: 360, height: 240)))
    }
}

func tableShapes(_ list: MTMathList?) -> [[Int]] {
    guard let list else { return [] }
    return list.atoms.flatMap { atom -> [[Int]] in
        if let table = atom as? MTMathTable {
            return [table.cells.map(\.count)] + table.cells.flatMap { $0.flatMap(tableShapes) }
        }
        if let inner = atom as? MTInner { return tableShapes(inner.innerList) }
        return []
    }
}

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
    if sample.name.hasPrefix("sigmoid-") {
        // Drawing can trigger a second layout after intrinsic size measurement.
        // Inspect that final display, including on a narrow, scaled panel.
        if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
        } else { check(false, "\(sample.name)/bitmap-render") }
        let drawn = label.displayList
        check(drawn != nil && abs(drawn!.width - content.width) < 0.01 &&
              abs(drawn!.ascent + drawn!.descent - content.height) < 0.01,
              "\(sample.name)/drawing-preserves-measured-single-line-layout")
    }
    if sample.name.hasPrefix("full-kalman-aligned") {
        check(tableShapes(label.mathList) == [Array(repeating: 2, count: 7)], "\(sample.name)/all-seven-aligned-rows")
        check(!label.latex.contains("[8pt]"), "\(sample.name)/spacing-options-are-not-visible-math")
    } else if sample.name.hasPrefix("full-multi-matrix") {
        check(tableShapes(label.mathList) == [[1, 1], [2, 2], [1, 1], [1, 1]], "\(sample.name)/all-four-complete-matrices")
    }
    print("METRIC \(sample.name): \(String(format: "%.2f", elapsed))ms, panel=\(size), content=\(content), font=\(label.fontSize), error=\(String(describing: view.error))")
}

_ = view.render(#"$$\boxed{K = \frac{P}{P+R}}$$"#, maxSize: standard)
if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
    let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
    func opaquePixels(in rect: NSRect) -> Int {
        var count = 0
        for y in max(0, Int(rect.minY * scaleY))..<min(bitmap.pixelsHigh, Int(ceil(rect.maxY * scaleY))) {
            for x in max(0, Int(rect.minX * scaleX))..<min(bitmap.pixelsWide, Int(ceil(rect.maxX * scaleX))) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.1 { count += 1 }
            }
        }
        return count
    }
    check(opaquePixels(in: NSRect(x: 12, y: 10, width: view.bounds.width - 24, height: 2)) > Int(view.bounds.width - 24),
          "boxed-kalman-gain/top-border-pixels")
    check(opaquePixels(in: NSRect(x: 12, y: view.bounds.height - 12, width: view.bounds.width - 24, height: 2)) > Int(view.bounds.width - 24),
          "boxed-kalman-gain/bottom-border-pixels")
    check(opaquePixels(in: label.frame) > 40, "boxed-kalman-gain/formula-pixels-inside-border")
} else {
    check(false, "boxed-kalman-gain/bitmap-render")
}

for source in [#"\text{keep \\[8pt]}"#, #"\begin{aligned}\text{keep \\[8pt]}&=x\end{aligned}"#,
               #"\begin{aligned}{a \\[8pt]}&=x\end{aligned}"#, #"a \\[8pt] b"#,
               #"\begin{aligned}a&=b\\\[8pt]c&=d\end{aligned}"#,
               #"\begin{aligned}a&=b\\[x+y]c&=d\end{aligned}"#] {
    check(FormulaView.normalizedRowSpacing(source) == source, "row-spacing-normalization-preserves-grouped-or-nonspacing-source")
}
let validSpacing = #"\begin{aligned}a&=b\\[8pt]c&=d\\[-0.5em]e&=f\end{aligned}"#
let defaultSpacing = #"\begin{aligned}a&=b\\c&=d\\e&=f\end{aligned}"#
check(FormulaView.normalizedRowSpacing(validSpacing) == defaultSpacing, "valid-row-spacing-options-use-native-default-spacing")

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
for source in [#"\unsupported{K = \frac{P}{P+R}}"#,
               #"\boxed{x}+y"#,
               #"\boxed{\frac{1}{"#,
               String(repeating: #"\unknown{x} "#, count: 12)] {
    _ = view.render(source, maxSize: standard)
    let needed = fallback.cell!.cellSize(forBounds: NSRect(
        origin: .zero, size: NSSize(width: fallback.bounds.width, height: .greatestFiniteMagnitude)))
    check(view.error != nil && fallback.stringValue == source.trimmingCharacters(in: .whitespacesAndNewlines) &&
          needed.height <= fallback.bounds.height && needed.width <= fallback.bounds.width,
          "unsupported-or-malformed-source-is-complete-without-text-cell-clipping")
}
_ = view.render(normal, maxSize: standard)
check(view.error == nil && !label.isHidden && fallback.isHidden, "valid-formula-recovers-after-error")

print("Result: \(checked - failed)/\(checked) native rendering checks passed")
exit(failed == 0 ? 0 : 1)

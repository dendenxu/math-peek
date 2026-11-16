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
let markdownStrippedInlineSource = #"参数 (c_{\mathrm{ref}}) 这样的一句话。"#
let reportedUndersetBody = #"""
  \left(
  R(u),t(u)
  \right)
  =
  \underset{R,t}{\arg\min}
  \sum_v
  w(u,v)
  \left\|
  RX_q(v)+t-X_i(v)
  \right\|_2^2
  """#
let reportedExpectationBody = #"""
v^*(x,t)
=
\mathbb E\!\left[
\epsilon-x_{\mathrm{gt}}
+\lambda(1-2t)\delta
\;\middle|\;
x_t=x,t
\right].
"""#
let reportedDerivativeBody = #"""
D_\theta
=
\underbrace{
\frac{\partial u_\theta}{\partial z_t}\,v_{\mathrm{cond}}
}_{\text{位置输入移动造成的变化}}
+
\underbrace{
\frac{\partial u_\theta}{\partial t}
}_{\text{时间输入前进造成的变化}}
"""#
let reportedDisplacementBody = #"""
\underbrace{\int_r^t v(z_\tau,\tau)\,d\tau}_{\text{把各小段位移加起来}}
=
\underbrace{z_t-z_r}_{\text{总位移}}
"""#
let reportedTargetBody = #"""
\underbrace{y}_{\text{本轮的训练目标}}
=
\operatorname{stopgrad}
\left[
v_{\mathrm{cond}}-(t-r)D_\theta
\right]
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
    Sample(name: "reported-underset-argmin", source: "$$\n" + reportedUndersetBody + "$$",
           body: "\n" + reportedUndersetBody, maximum: standard),
    Sample(name: "reported-conditional-expectation", source: "$$\n" + reportedExpectationBody + "\n$$",
           body: "\n" + reportedExpectationBody + "\n", maximum: standard),
    Sample(name: "reported-underbrace-derivative", source: "$$\n" + reportedDerivativeBody + "\n$$",
           body: "\n" + reportedDerivativeBody + "\n", maximum: standard),
    Sample(name: "reported-underbrace-displacement", source: "$$\n" + reportedDisplacementBody + "\n$$",
           body: "\n" + reportedDisplacementBody + "\n", maximum: standard),
    Sample(name: "reported-underbrace-target", source: "$$\n" + reportedTargetBody + "\n$$",
           body: "\n" + reportedTargetBody + "\n", maximum: standard),
    Sample(name: "underbrace-narrow", source: reportedDerivativeBody, body: reportedDerivativeBody,
           maximum: NSSize(width: 120, height: 55)),
    Sample(name: "boxed-underbrace", source: "\\boxed{" + reportedTargetBody + "}", body: reportedTargetBody,
           maximum: standard),
]

for body in [reportedDerivativeBody, reportedDisplacementBody, reportedTargetBody] {
    let source = "$$\n" + body + "\n$$"
    let document = TerminalFormulaDocument(text: source)
    let scalars = Array(source.unicodeScalars)
    check(scalars.indices.filter { !scalars[$0].properties.isWhitespace }.allSatisfy {
        document.match(at: $0)?.formula == source
    }, "underbrace/extracts-entire-formula-including-Chinese-annotations")
}

let markdownInlineExpected = #"\(c_{\mathrm{ref}}\)"#
let markdownInlineScalars = Array(markdownStrippedInlineSource.unicodeScalars)
let markdownInlineOffsets = markdownInlineScalars.indices.filter { (3...20).contains($0) }
let markdownInlineExtracted = markdownInlineOffsets.map {
    HoverMath.extract(text: markdownStrippedInlineSource, offset: $0)
}
check(!markdownInlineExtracted.isEmpty && markdownInlineExtracted.allSatisfy { $0 == markdownInlineExpected },
      "markdown-stripped-inline/extracts-complete-formula-from-every-character")
if let formula = markdownInlineExtracted.first ?? nil {
    samples.append(Sample(name: "markdown-stripped-inline", source: formula,
                          body: #"c_{\mathrm{ref}}"#, maximum: standard))
}

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

func braceViews(_ view: NSView) -> [BracedFormulaView] {
    let own = (view as? BracedFormulaView).flatMap { $0.curve == nil ? nil : $0 }
    return (own.map { [$0] } ?? []) + view.subviews.flatMap(braceViews)
}

func mathLabels(_ view: NSView) -> [MTMathUILabel] {
    if let label = view as? MTMathUILabel { return [label] }
    return view.subviews.flatMap(mathLabels)
}

func drawingFits(_ view: NSView) -> Bool {
    if let label = view as? MTMathUILabel {
        guard let display = label.displayList else { return false }
        return display.width <= label.bounds.width + 1 && display.ascent + display.descent <= label.bounds.height + 1
    }
    return view.subviews.allSatisfy { view.bounds.insetBy(dx: -1, dy: -1).contains($0.frame) && drawingFits($0) }
}

func checkBraceDrawing(_ brace: BracedFormulaView) {
    guard let curve = brace.curve, let base = brace.subviews.first else {
        check(false, "brace/has-base-and-curve"); return
    }
    let rect = curve.bounds
    check(rect.width >= base.frame.width - 0.01 && abs(rect.midX - base.frame.midX) < 0.01,
          "brace/curve-spans-and-centers-on-the-base")
    check(rect.maxY < base.frame.minY || rect.minY > base.frame.maxY,
          "brace/curve-does-not-overlap-the-base")
    if brace.subviews.count == 2 {
        let note = brace.subviews[1]
        check(abs(note.frame.midX - rect.midX) < 0.01 &&
              (note.frame.maxY < rect.minY || note.frame.minY > rect.maxY),
              "brace/annotation-is-centered-beyond-the-curve")
    }
    let region = rect.insetBy(dx: -0.5, dy: -0.5)
    guard let bitmap = brace.bitmapImageRepForCachingDisplay(in: region) else {
        check(false, "brace/bitmap"); return
    }
    brace.cacheDisplay(in: region, to: bitmap)
    let inkColumns = (0..<bitmap.pixelsWide).filter { x in
        (0..<bitmap.pixelsHigh).contains { y in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 }
    }
    check(inkColumns.count > bitmap.pixelsWide / 2,
          "brace/draws-visible-curve-pixels-across-its-width")
}

for sample in samples {
    let began = Date()
    let size = view.render(sample.source, maxSize: sample.maximum)
    let elapsed = Date().timeIntervalSince(began) * 1000
    let drawing = view.mathContent
    let content = drawing.intrinsicContentSize
    check(view.error == nil && label.error == nil && !drawing.isHidden && fallback.isHidden, "\(sample.name)/native-render")
    check(view.renderedBody == sample.body, "\(sample.name)/source")
    check(size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0 &&
          size.width <= sample.maximum.width && size.height <= sample.maximum.height, "\(sample.name)/panel-bounds")
    check(content.width <= drawing.bounds.width + 1 && content.height <= drawing.bounds.height + 1 &&
          view.bounds.contains(drawing.frame), "\(sample.name)/content-fits")
    check(drawingFits(drawing), "\(sample.name)/drawn-content-fits")
    braceViews(drawing).forEach(checkBraceDrawing)
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
    } else if sample.name == "reported-underset-argmin" {
        check(label.latex.contains(#"\begin{smallmatrix}"#) && label.latex.contains(#"\arg\min"#) &&
              label.latex.contains(#"RX_q(v)+t-X_i(v)"#),
              "reported-underset-argmin/native-compatible-stack-preserves-complete-formula")
    } else if sample.name == "reported-conditional-expectation" {
        let expectation = label.mathList?.atoms.compactMap { $0 as? MTInner }.first
        let separators = expectation?.innerList?.atoms.compactMap { $0 as? MTInner } ?? []
        check(expectation?.leftBoundary?.nucleus == "[" && expectation?.rightBoundary?.nucleus == "]" &&
              separators.count == 1 && separators.first?.leftBoundary?.nucleus == "|",
              "conditional-expectation/preserves-brackets-and-single-condition-bar")
        check(label.mathList?.atoms.first?.superScript?.atoms.first?.nucleus == "*" &&
              expectation?.innerList?.atoms.last?.nucleus == "t" && tableShapes(label.mathList).isEmpty,
              "conditional-expectation/preserves-star-and-final-conditioning-variable-without-spurious-rows")
    } else if sample.name.hasPrefix("reported-underbrace-") {
        let curves = braceViews(drawing)
        check(curves.count == (sample.name.hasSuffix("target") ? 1 : 2), "\(sample.name)/draws-each-brace")
        if let root = drawing as? BracedFormulaView {
            check(curves.allSatisfy {
                abs(root.convert(NSPoint(x: 0, y: $0.baseline), from: $0).y - root.baseline) < 0.01
            }, "\(sample.name)/preserves-the-equation-baseline")
        }
        let annotations = sample.name.hasSuffix("target") ? ["本轮的训练目标"]
            : sample.name.hasSuffix("derivative") ? ["位置输入移动造成的变化", "时间输入前进造成的变化"]
            : ["把各小段位移加起来", "总位移"]
        let rendered = mathLabels(drawing).map(\.latex).joined()
        check(annotations.allSatisfy(rendered.contains), "\(sample.name)/keeps-Chinese-text")
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

let stackCompatibility: [(String, String)] = [
    (#"\underset{x_i}{f_{\theta}(x_i)}"#,
     #"{\begin{smallmatrix}\textstyle f_{\theta}(x_i)\\\scriptstyle x_i\end{smallmatrix}}"#),
    (#"\overset{a+b}{c_d}"#,
     #"{\begin{smallmatrix}\scriptstyle a+b\\\textstyle c_d\end{smallmatrix}}"#),
    (#"\stackrel{!}{=}"#,
     #"{\begin{smallmatrix}\scriptstyle !\\\textstyle =\end{smallmatrix}}"#),
    (#"\underset{x}{\overset{y}{z}}"#,
     #"{\begin{smallmatrix}\textstyle {\begin{smallmatrix}\scriptstyle y\\\textstyle z\end{smallmatrix}}\\\scriptstyle x\end{smallmatrix}}"#),
]
for (source, expected) in stackCompatibility {
    check(FormulaView.normalizedNativeCompatibility(source) == expected,
          "native-compatibility-rewrites-balanced-standard-stack")
}
for source in [#"\underset{x}"#, #"\overset x {y}"#, #"\\underset{x}{y}"#] {
    check(FormulaView.normalizedNativeCompatibility(source) == source,
          "native-compatibility-preserves-malformed-or-row-separator-source")
}

for source in [#"\underbrace{x}_{"#, #"\underbrace{x}^a"#, #"\\underbrace{x}_{a}"#] {
    check(FormulaView.normalizedNativeCompatibility(source) == source,
          "brace-compatibility-preserves-incomplete-or-escaped-commands")
}
for source in [#"\overbrace{x+y}^{\text{sum}}+z"#, #"\underbrace{x+y}"#,
               #"\underbrace{\underbrace{\{x\}}_{a}+y}_{\text{outer}}"#] {
    _ = view.render(source, maxSize: standard)
    check(view.error == nil && view.mathContent is BracedFormulaView && fallback.isHidden,
          "brace-compatibility-handles-nesting-and-balanced-escaped-braces")
    braceViews(view.mathContent).forEach(checkBraceDrawing)
}

let spacingReference = MTMathUILabel()
spacingReference.fontSize = 14
spacingReference.preferredMaxLayoutWidth = .greatestFiniteMagnitude
spacingReference.latex = "x+y"
let sumWidth = spacingReference.intrinsicContentSize.width
for (source, replaced, index) in [(#"\underbrace{x}_{a}+y"#, "x", 1),
                                   (#"x+\underbrace{y}_{a}"#, "y", 0)] {
    spacingReference.latex = replaced
    let expected = sumWidth - spacingReference.intrinsicContentSize.width
    _ = view.render(source, maxSize: standard)
    let parts = view.mathContent.subviews
    check(parts.count == 2 && abs(parts[index].intrinsicContentSize.width - expected) < 0.01,
          "brace/preserves-native-binary-operator-spacing-next-to-\(replaced)")
}

let middleCompatibility: [(String, String)] = [
    (#"\left[a\middle|b\right]"#, #"\left[a\bigm|b\right]"#),
    (#"\left\{a\middle\|b\right\}"#, #"\left\{a\bigm\|b\right\}"#),
    (#"\left(a\middle\vert b\middle\Vert c\right)"#, #"\left(a\bigm\vert b\bigm\Vert c\right)"#),
    (#"\left[a+\left(b\middle/c\right)\middle|d\right]"#,
     #"\left[a+\left(b\bigm/c\right)\bigm|d\right]"#),
]
for (source, expected) in middleCompatibility {
    check(FormulaView.normalizedNativeCompatibility(source) == expected,
          "middle-delimiter/rewrites-only-matched-math-context")
    _ = view.render(source, maxSize: standard)
    check(view.error == nil && !label.isHidden && fallback.isHidden,
          "middle-delimiter/native-render-keeps-whole-expression")
}
for source in [#"\middle|"#, #"\\middle|"#, #"\left[\text{\middle|}\right]"#,
               #"\left[x\right]\middle|"#, #"\left[a\middleword b\right]"#] {
    check(FormulaView.normalizedNativeCompatibility(source) == source,
          "middle-delimiter/preserves-unmatched-escaped-text-and-other-commands")
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

for broken in [#"\underbrace{\frac{1}{"#, #"\underbrace{x}_{\text{截断"#,
               #"\underbrace{x}_{a}+\unknown"#, #"\frac{\underbrace{x}_{a}}{y}"#,
               #"\begin{aligned}a&=\left("#, #"\unsupported{x}"#] {
    _ = view.render(broken, maxSize: standard)
    check(view.error != nil && !fallback.isHidden && braceViews(view).isEmpty, "broken-scroll-fragment/falls-back")
    let recovered = view.render(normal, maxSize: standard)
    check(view.error == nil && !label.isHidden && fallback.isHidden && recovered == first && braceViews(view).isEmpty,
          "broken-scroll-fragment/next-normal-formula-recovers-without-reset")
    _ = view.render("$$\n" + reportedDisplacementBody + "\n$$", maxSize: standard)
    check(view.error == nil && braceViews(view.mathContent).count == 2,
          "broken-scroll-fragment/next-underbrace-formula-recovers-without-reset")
}

print("Result: \(checked - failed)/\(checked) native rendering checks passed")
exit(failed == 0 ? 0 : 1)

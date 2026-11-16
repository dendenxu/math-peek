import Foundation

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { passed += 1 }
    else { failed += 1; print("FAIL \(name)") }
}

func scalarOffset(_ source: String, _ needle: String) -> Int {
    let range = source.range(of: needle)!
    return source[..<range.lowerBound].unicodeScalars.count
}

func assertSameFormula(_ source: String, needles: [String], required: [String], name: String,
                       columnEncoding: TerminalFormulaDocument.ColumnEncoding = .unicode) {
    let document = TerminalFormulaDocument(text: source, columnEncoding: columnEncoding)
    var formulas = Set<String>()
    for needle in needles {
        let start = scalarOffset(source, needle)
        let count = needle.unicodeScalars.count
        for offset in start..<(start + count) {
            if let formula = document.match(at: offset)?.formula { formulas.insert(formula) }
            else { failed += 1; print("FAIL \(name) missing offset \(offset) in \(String(reflecting: needle))") }
        }
    }
    check(formulas.count == 1, "\(name) has one stable formula, got \(formulas)")
    if let formula = formulas.first {
        for fragment in required { check(formula.contains(fragment), "\(name) contains \(String(reflecting: fragment))") }
    }
}

let clippedLoss = #"""
left pane                                                                 │  \mathcal{L}_{FM}
left pane                                                                 │  =
left pane                                                                 │  \mathbb{E}
left pane                                                                 │  \left[
left pane                                                                 │  \left\|
left pane                                                                 │  v_\theta(x_t,t,c)-u_t
left pane                                                                 │  \right\|_2^2
left pane                                                                 │  \right]
left pane                                                                 │  $$
"""#
assertSameFormula(clippedLoss, needles: [#"\mathcal{L}_{FM}"#, #"\mathbb{E}"#, #"v_\theta"#, #"\right\|_2^2"#],
                  required: [#"\mathcal{L}_{FM}"#, #"\mathbb{E}"#, #"v_\theta(x_t,t,c)-u_t"#, #"\right]"#],
                  name: "clipped loss in tmux history")

let clippedAngles = #"""
prose                                                                    │  $$
prose                                                                    │  10^\circ
prose                                                                    │  +
prose                                                                    │  5^\circ/\mathrm{s}\times0.02\,\mathrm{s}
prose                                                                    │  =
prose                                                                    │  10.1^\circ
"""#
assertSameFormula(clippedAngles, needles: [#"10^\circ"#, #"5^\circ"#, #"10.1^\circ"#],
                  required: [#"10^\circ"#, #"5^\circ/\mathrm{s}"#, #"10.1^\circ"#],
                  name: "bottom-clipped angle formula")
let croppedMiddle = TerminalFormulaDocument(text: clippedAngles, allowsClippedTop: false, allowsClippedBottom: false)
check(croppedMiddle.match(at: scalarOffset(clippedAngles, #"5^\circ"#)) == nil,
      "arbitrary performance crop is not treated as a terminal edge")

let complete = #"""
left │  prose
left │  $$
left │  \theta_{t+\Delta t}
left │  \alpha\theta_{\mathrm{gyro}}
left │  +
left │  (1-\alpha)\theta_{\mathrm{acc}}
left │  $$
left │  prose
"""#
assertSameFormula(complete, needles: [#"\theta_{t+\Delta t}"#, #"\alpha\theta"#, #"\theta_{\mathrm{acc}}"#],
                  required: [#"\theta_{t+\Delta t}"#, #"(1-\alpha)\theta_{\mathrm{acc}}"#],
                  name: "complete display dominates fragments")

let reportedTmuxHistory = #"""
普通正文                                                                 │  $$
普通正文                                                                 │  10^\circ
普通正文                                                                 │  +
普通正文                                                                 │  5^\circ/\mathrm{s}\times0.02\,\mathrm{s}
普通正文                                                                 │  =
普通正文                                                                 │  10.1^\circ
普通正文                                                                 │  $$
普通正文                                                                 │  0.98\times10.1^\circ
普通正文                                                                 │  +
普通正文                                                                 │  0.02\times9^\circ
普通正文                                                                 │  =
普通正文                                                                 │  10.078^\circ
普通正文                                                                 │  $$
"""#
assertSameFormula(reportedTmuxHistory,
                  needles: [#"10^\circ"#, #"5^\circ/\mathrm{s}"#, #"10.1^\circ"#],
                  required: [#"10^\circ"#, #"5^\circ/\mathrm{s}\times0.02"#, #"10.1^\circ"#],
                  name: "reported first tmux history block")
assertSameFormula(reportedTmuxHistory,
                  needles: [#"0.98\times10.1"#, #"0.02\times9"#, #"10.078^\circ"#],
                  required: [#"0.98\times10.1^\circ"#, #"0.02\times9^\circ"#, #"10.078^\circ"#],
                  name: "reported second tmux history block")

let reportedUnderset = #"""
context                                                                  │  $$
context                                                                  │  \left(
context                                                                  │  R(u),t(u)
context                                                                  │  \right)
context                                                                  │  =
context                                                                  │  \underset{R,t}{\arg\min}
context                                                                  │  \sum_v
context                                                                  │  w(u,v)
context                                                                  │  \left\|
context                                                                  │  RX_q(v)+t-X_i(v)
context                                                                  │  \right\|_2^2
context                                                                  │  $$
"""#
assertSameFormula(
    reportedUnderset,
    needles: [#"\left("#, #"R(u),t(u)"#, #"\right)"#,
              #"\underset{R,t}{\arg\min}"#, #"\sum_v"#, #"w(u,v)"#,
              #"\left\|"#, #"RX_q(v)+t-X_i(v)"#, #"\right\|_2^2"#],
    required: [#"\left("#, #"R(u),t(u)"#, #"\underset{R,t}{\arg\min}"#,
               #"\sum_v"#, #"RX_q(v)+t-X_i(v)"#, #"\right\|_2^2"#],
    name: "reported underset argmin in tmux history")

let neighbors = #"""
$$x+y$$                                                               │  $$a+b$$
plain                                                                 │  plain
plain                                                                 │  plain
"""#
let neighborDocument = TerminalFormulaDocument(text: neighbors)
check(neighborDocument.match(at: scalarOffset(neighbors, "x+y"))?.formula == "$$x+y$$", "left pane isolation")
check(neighborDocument.match(at: scalarOffset(neighbors, "a+b"))?.formula == "$$a+b$$", "right pane isolation")

// The same terminal cells serialized as normal text and as iTerm AX text.
// Explicit cell widths keep the fixture independent of the production width scan.
let cellRows: [(plain: String, ax: String, width: Int)] = [
    ("中文", "中 文 ", 4),
    ("", "", 0),
    ("一二三四五", "一 二 三 四 五 ", 10),
    ("e\u{301} 中", "e\u{301} 中 ", 4),
    ("🚀 中文", "🚀  中 文 ", 7),
    ("末", "末 ", 2),
    ("结束了", "结 束 了 ", 6),
]
let predictionRows = ["plain", "$$", #"\widehat{x}_0"#, "=",
                      #"\widetilde{x}_t-t\,v_\theta(\widetilde{x}_t,t,c)."#, "$$", "plain"]
let predictionNeedles = [#"\widehat{x}_0"#, #"\widetilde{x}_t-t"#, #"v_\theta"#]
func predictionScreen(padded: Bool) -> String {
    zip(cellRows, predictionRows).map { row, formula in
        (padded ? row.ax : row.plain) + String(repeating: " ", count: 24 - row.width) + "│  " + formula
    }.joined(separator: "\n")
}
let plainPrediction = predictionScreen(padded: false)
let axPrediction = predictionScreen(padded: true)
assertSameFormula(plainPrediction, needles: predictionNeedles, required: predictionNeedles,
                  name: "Unicode tmux columns with changing CJK neighbors")
assertSameFormula(axPrediction, needles: predictionNeedles, required: predictionNeedles,
                  name: "iTerm padded cells with CJK, combining marks and emoji", columnEncoding: .paddedCells)
let paddedDocument = TerminalFormulaDocument(text: axPrediction, columnEncoding: .paddedCells)
let axScalars = Array(axPrediction.unicodeScalars)
let expectedFragments = Set(predictionRows.flatMap { [$0, "  " + $0] })
for needle in predictionNeedles {
    let offset = scalarOffset(axPrediction, needle)
    if let match = paddedDocument.match(at: offset) {
        check(match.sourceRanges.contains { $0.contains(offset) }, "padded source ranges contain hovered offset")
        for range in match.sourceRanges {
            let original = String(String.UnicodeScalarView(axScalars[range]))
            check(!original.contains("│"), "padded source ranges exclude neighboring panes")
            check(expectedFragments.contains(original), "padded source ranges preserve original formula text")
        }
    }
}
check(paddedDocument.match(at: scalarOffset(axPrediction, "一")) == nil,
      "CJK text in neighboring pane never borrows the right formula")

let encodingCache = FormulaDocumentCache()
let predictionOffset = scalarOffset(axPrediction, predictionNeedles[0])
check(encodingCache.match(text: axPrediction, at: predictionOffset) == nil,
      "padded fixture reproduces failure with Unicode columns")
check(encodingCache.match(text: axPrediction, at: predictionOffset, columnEncoding: .paddedCells) != nil,
      "cache includes column encoding for identical source text")
check(encodingCache.match(text: axPrediction, at: predictionOffset) == nil,
      "switching back cannot reuse the padded document")

// Scroll through every row of an earlier formula, including its lone closing
// delimiter. Later complete blocks must retain both delimiters and every hit.
let followingFormulas = ["$$\n\\frac{P}{P+R}\n$$", "$$\nx+y=2\n$$"]
for separator in ["", "Next formula", "Next", "•", "---", "下面这个"] {
    let rows = ["$$", #"\underbrace{"#, #"\frac{x_t}{2}"#, #"}_{\text{old label}}"#, "$$", separator]
        + followingFormulas[0].components(separatedBy: "\n") + [separator]
        + followingFormulas[1].components(separatedBy: "\n")
    for crop in 0...5 {
        let visible = Array(rows.dropFirst(crop))
        for variant in 0...2 {
            let prefixes = visible.indices.map { row -> String in
                guard variant > 0 else { return "" }
                let left = row.isMultiple(of: 2) ? (variant == 2 ? "左 栏 " : "左栏") : "logs"
                return left + String(repeating: " ", count: 16) + "│"
            }
            let source = zip(prefixes, visible).map(+).joined(separator: "\n")
            let document = TerminalFormulaDocument(text: source, columnEncoding: variant == 2 ? .paddedCells : .unicode)
            var rowOffset = 0
            for row in visible.indices {
                let originalRow = row + crop
                let formulaIndex: Int? = (6...8).contains(originalRow) ? 0 : (10...12).contains(originalRow) ? 1 : nil
                if let formulaIndex {
                    let start = rowOffset + prefixes[row].unicodeScalars.count
                    for offset in start..<(start + visible[row].unicodeScalars.count) {
                        let hit = document.match(at: offset)
                        check(hit?.formula == followingFormulas[formulaIndex] && hit?.kind == .delimited,
                              "scroll crop \(crop), gap \(separator), columns \(variant), offset \(offset) preserves complete formula")
                    }
                }
                rowOffset += prefixes[row].unicodeScalars.count + visible[row].unicodeScalars.count + 1
            }
        }
    }
}

let completeAnchor = "$$\nx=1\n$$"
let independentBare = #"\boxed{q=\frac{x}{y}}"#
let orphanThenBare = "$$\nNext\n" + completeAnchor + "\n\n" + independentBare
check(TerminalFormulaDocument(text: orphanThenBare).match(at: scalarOffset(orphanThenBare, independentBare))?.formula == independentBare,
      "orphan closing before a complete block does not suppress later bare math")
let unfinishedAfterAnchor = completeAnchor + "\nUnfinished:\n$$\n" + independentBare
check(TerminalFormulaDocument(text: unfinishedAfterAnchor, allowsClippedBottom: false)
    .match(at: scalarOffset(unfinishedAfterAnchor, independentBare)) == nil,
      "an unresolved opening still protects its own incomplete formula from bare fallback")
let unfinishedWithInline = completeAnchor + "\n$$\ncontext $x$\n" + independentBare
check(TerminalFormulaDocument(text: unfinishedWithInline, allowsClippedBottom: false)
    .match(at: scalarOffset(unfinishedWithInline, independentBare)) == nil,
      "inline math cannot terminate an unresolved display region")
let inlineGap = "$$\nNext $a+b$ formula\n" + followingFormulas[0]
check(TerminalFormulaDocument(text: inlineGap).match(at: scalarOffset(inlineGap, "a+b"))?.formula == "$a+b$",
      "resynchronization still indexes inline math between the orphan and next display")
for fence in ["```", "~~~"] {
    let source = fence + "tex\n" + followingFormulas[0] + "\n" + fence + "\n" + independentBare
    let document = TerminalFormulaDocument(text: source)
    check(document.match(at: scalarOffset(source, #"\frac{P}"#)) == nil, "fenced display delimiters remain inert")
    check(document.match(at: scalarOffset(source, independentBare))?.formula == independentBare,
          "fenced display delimiters do not suppress later bare math")
}

for body in ["abc", "x", "123", #"\text{Next formula}"#, #"abc def! + \frac{1}{2}"#] {
    let expected = "$$\n" + body + "\n$$"
    let source = expected + "\nNext\n" + followingFormulas[0]
    let document = TerminalFormulaDocument(text: source)
    check(document.match(at: 0)?.formula == expected, "resynchronization preserves complete display bodies")
}

for source in [#"$HOME/Applications/Ghostty.app"#, "ordinary prose", "Price $5 and $10", #"print(\"\frac{a}{b}\")"#] {
    let document = TerminalFormulaDocument(text: source)
    for offset in 0..<source.unicodeScalars.count {
        check(document.match(at: offset) == nil, "negative \(String(reflecting: source)) offset \(offset)")
    }
}

let mutationCache = FormulaDocumentCache()
check(mutationCache.match(text: "$$x=1$$", at: 3)?.formula == "$$x=1$$", "cache reads first snapshot")
check(mutationCache.match(text: "$$y=2$$", at: 3)?.formula == "$$y=2$$", "cache replaces changed snapshot")
check(mutationCache.match(text: "ordinary text", at: 3) == nil, "cache never returns a stale formula")
let concurrentCache = FormulaDocumentCache()
let concurrentFailures = NSLock()
var concurrentFailureCount = 0
DispatchQueue.concurrentPerform(iterations: 500) { index in
    let value = index.isMultiple(of: 2) ? "$$x=1$$" : "$$y=2$$"
    let expected = value
    if concurrentCache.match(text: value, at: 3)?.formula != expected {
        concurrentFailures.lock(); concurrentFailureCount += 1; concurrentFailures.unlock()
    }
}
check(concurrentFailureCount == 0, "concurrent snapshots never exchange formula results")

print("Formula document: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)

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

func assertSameFormula(_ source: String, needles: [String], required: [String], name: String) {
    let document = TerminalFormulaDocument(text: source)
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

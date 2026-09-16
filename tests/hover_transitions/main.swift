import AppKit
import ApplicationServices
import Foundation
import SwiftMath

let regression = CommandLine.arguments.contains("--regression")
let fullFormulas = CommandLine.arguments.contains("--full-formulas")
func argumentValue(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < CommandLine.arguments.count, !CommandLine.arguments[index + 1].hasPrefix("--") else {
        print("Missing value for \(name)")
        exit(2)
    }
    return CommandLine.arguments[index + 1]
}
let bundleID = argumentValue("--bundle-id") ?? "com.googlecode.iterm2"
let marker = argumentValue("--marker") ?? (fullFormulas ? "MATHPEEK FULL FORMULA DEMO" : regression ? "MATHPEEK REGRESSION DEMO" : "MATHPEEK HOVER DEMO")

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func demoTextArea(_ window: AXUIElement) -> (AXUIElement, NSString)? {
    guard attribute(window, kAXRoleAttribute) as? String == kAXWindowRole else { return nil }
    var queue = [(window, 0)]
    var visited = 0
    while !queue.isEmpty && visited < 2000 {
        let (element, depth) = queue.removeFirst()
        visited += 1
        if attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole,
           let value = attribute(element, kAXValueAttribute) as? String,
           value.contains(marker), value.contains(fullFormulas ? "END FULL FORMULA" : regression ? "END REGRESSION DEMO" : "Multi-line aligned math:") {
            return (element, value as NSString)
        }
        if depth < 16, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
    }
    return nil
}

func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
func until(_ seconds: TimeInterval, _ predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if predicate() { return true }
        pump(0.008)
    }
    return predicate()
}
func move(_ point: CGPoint) {
    let error = CGWarpMouseCursorPosition(point)
    guard error == .success else { print("FAIL cursor warp: \(error.rawValue)"); exit(1) }
}
struct Sample {
    let name: String
    let point: CGPoint
    let expected: [String]
    let observeOnly: Bool
    var sourceIndex: Int? = nil
}

guard CommandLine.arguments.contains("--run") else {
    print("Ready. This harness does not move the mouse without --run.")
    print("Raise only the isolated \(marker) window, pause installed Math Peek hover, then run this binary with --run.")
    print("Optional --regression selects tests/tmux_regression_demo.py; --occlusion tests a covered target separately.")
    print("Use --bundle-id com.apple.Terminal for Terminal.app; --marker selects a custom isolated fixture marker.")
    exit(0)
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
guard AXIsProcessTrusted() else { print("BLOCKED: probe lacks Accessibility permission"); exit(2) }
guard let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
      NSWorkspace.shared.frontmostApplication?.processIdentifier == terminal.processIdentifier else {
    print("BLOCKED: raise the isolated demo in \(bundleID) first"); exit(2)
}
let root = AXUIElementCreateApplication(terminal.processIdentifier)
AXUIElementSetMessagingTimeout(root, 1)
guard let windowValue = attribute(root, kAXFocusedWindowAttribute), CFGetTypeID(windowValue) == AXUIElementGetTypeID(),
      let (element, text) = demoTextArea(windowValue as! AXUIElement) else {
    print("BLOCKED: focused \(bundleID) window is not the isolated demo; no other windows were read"); exit(2)
}

var recoveredPointIndices = Set<Int>()
func pointAt(_ index: Int) -> CGPoint? {
    func boundsAt(_ offset: Int) -> CGRect? {
        guard offset >= 0, offset < text.length else { return nil }
        var range = CFRange(location: offset, length: 1)
        let parameter = AXValueCreate(.cfRange, &range)!
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &value)
        var bounds = CGRect.zero
        guard error == .success, let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgRect, &bounds), bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }
    func mapsTo(_ point: CGPoint, _ offset: Int) -> Bool {
        var point = point
        let parameter = AXValueCreate(.cgPoint, &point)!
        var value: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForPositionParameterizedAttribute as CFString, parameter, &value)
        var range = CFRange(location: -1, length: 0)
        return error == .success && value != nil && CFGetTypeID(value!) == AXValueGetTypeID() &&
            AXValueGetValue(value as! AXValue, .cfRange, &range) && range.location == offset && range.length > 0
    }
    guard let bounds = boundsAt(index) else { return nil }
    let center = CGPoint(x: bounds.midX, y: bounds.midY)
    if mapsTo(center, index) { return center }
    // iTerm2 can return a rectangle spanning both lines for the final wrap glyph.
    // Recover its cell from a neighboring glyph, then require an exact AX roundtrip.
    for delta in [-1, -2, -3, 1, 2, 3] {
        guard let adjacent = boundsAt(index + delta) else { continue }
        let adjacentCenter = CGPoint(x: adjacent.midX, y: adjacent.midY)
        guard mapsTo(adjacentCenter, index + delta) else { continue }
        let candidate = CGPoint(x: adjacent.midX - CGFloat(delta) * adjacent.width, y: adjacent.midY)
        if mapsTo(candidate, index) {
            recoveredPointIndices.insert(index)
            print("POINT-FIX index=\(index) boundsCenter=\(center) verifiedCell=\(candidate)")
            return candidate
        }
    }
    print("POINT-ERROR index=\(index): no coordinate roundtrips to the requested character")
    return nil
}
func located(_ section: String, _ needle: String) -> NSRange {
    let sectionRange = text.range(of: section, options: .backwards)
    guard sectionRange.location != NSNotFound else { fatalError("missing fixture section: \(section)") }
    let result = text.range(of: needle, range: NSRange(location: NSMaxRange(sectionRange), length: text.length - NSMaxRange(sectionRange)))
    guard result.location != NSNotFound else { fatalError("missing fixture needle: \(needle)") }
    return result
}
func sample(_ name: String, _ section: String, _ needle: String, _ expected: [String], offset: Int = 0, observeOnly: Bool = false) -> Sample {
    let range = located(section, needle)
    guard let point = pointAt(range.location + offset) else { fatalError("missing bounds for \(name)") }
    return Sample(name: name, point: point, expected: expected, observeOnly: observeOnly, sourceIndex: range.location + offset)
}
let inline: Sample
let hardWrap: Sample
let chinese: Sample
var aligned: [Sample] = []
var extraRows: [Sample] = []
var fullFormulaBody: String?
if regression || fullFormulas {
    // Test physical terminal rows, including tmux wraps through LaTeX commands.
    func sectionRows(_ name: String, _ heading: String, _ next: String, _ expected: [String]) -> [Sample] {
        let start = text.range(of: heading, options: .backwards)
        let end = text.range(of: next, options: .backwards)
        guard start.location != NSNotFound, end.location != NSNotFound else { fatalError("missing regression section \(name)") }
        let headingLine = text.lineRange(for: start)
        let endLineStart = text.lineRange(for: end).location
        let column = start.location - headingLine.location
        var cursor = NSMaxRange(headingLine)
        var result: [Sample] = []
        var row = 0
        while cursor < endLineStart {
            let range = text.lineRange(for: NSRange(location: cursor, length: 0))
            let line = text.substring(with: range) as NSString
            guard line.length > column else { cursor = NSMaxRange(range); continue }
            let border = line.range(of: "\u{2502}", range: NSRange(location: column, length: line.length - column)).location
            let limit = border == NSNotFound ? line.length : border
            let content = line.substring(with: NSRange(location: column, length: limit - column)).replacingOccurrences(of: "\0", with: " ") as NSString
            var first = 0
            var last = content.length
            func whitespace(_ index: Int) -> Bool {
                guard let scalar = UnicodeScalar(content.character(at: index)) else { return false }
                return CharacterSet.whitespacesAndNewlines.contains(scalar)
            }
            while first < last && whitespace(first) { first += 1 }
            while last > first && whitespace(last - 1) { last -= 1 }
            // A Markdown heading prefix is outside the formula's hover range.
            if fullFormulas, content.substring(from: first).hasPrefix("# $$") { first += 2 }
            if first < last {
                row += 1
                for (part, offset) in [("start", first), ("middle", (first + last - 1) / 2), ("end", last - 1)] {
                    guard let point = pointAt(cursor + column + offset) else { fatalError("missing AX bounds \(name) row \(row)") }
                    result.append(Sample(name: "\(name)-row\(row)-\(part)", point: point, expected: expected, observeOnly: false, sourceIndex: cursor + column + offset))
                }
                if column + last + 3 < limit, let point = pointAt(cursor + column + last + 3) {
                    result.append(Sample(name: "\(name)-row\(row)-padding", point: point, expected: expected, observeOnly: true, sourceIndex: cursor + column + last + 3))
                }
            }
            cursor = NSMaxRange(range)
        }
        guard !result.isEmpty else { fatalError("no regression rows in \(name)") }
        return result
    }
    if fullFormulas {
        let mode = ["boxed", "matrices", "kalman"].first { (text as String).contains("Fixture mode: \($0)") } ?? "kalman"
        let data = try Data(contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tests/full_formula_fixtures.json"))
        let fixtures = try JSONDecoder().decode([String: String].self, from: data)
        guard let source = fixtures[mode] else { fatalError("missing full formula fixture") }
        guard let complete = HoverMath.extract(text: source, offset: source.unicodeScalars.count / 2) else {
            fatalError("complete reference formula could not be extracted")
        }
        var body = complete.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("# $$") { body = String(body.dropFirst(2)) }
        for (opening, closing) in [("$$", "$$"), ("\\[", "\\]")] {
            if body.hasPrefix(opening) && body.hasSuffix(closing) {
                body = String(body.dropFirst(opening.count).dropLast(closing.count))
                break
            }
        }
        fullFormulaBody = mode == "boxed" ? #"K = \frac{P}{P+R}"# : body
        let environment = mode == "matrices" ? "bmatrix" : "aligned"
        let fragments = mode == "boxed" ? ["K", #"\frac{P}{P+R}"#] : ["\\begin{\(environment)}", "\\end{\(environment)}"]
        aligned = sectionRows("full-\(mode)", "Full formula:", "END FULL FORMULA", fragments)
        inline = sample("tiny-reset", "Tiny reset:", "$x$", ["$x$"])
        hardWrap = aligned[0]
        chinese = aligned[aligned.count / 2]
    } else {
    let velocity = ["v_{\\mathrm{pred}}", "v_{\\mathrm{prev}}", "a_{\\mathrm{world}}", "\\Delta t"]
    let delimited = sectionRows("delimited-velocity", "Delimited velocity:", "Raw velocity (tmux wraps this line):", velocity)
    let raw = sectionRows("raw-velocity", "Raw velocity (tmux wraps this line):", "One-column matrix (single slash rows):", velocity)
    let matrix = sectionRows("single-slash-matrix", "One-column matrix (single slash rows):", "Aligned (broken spacing command):", ["\\begin{bmatrix}", "v_x \\\\ v_y \\\\ v_z", "\\end{bmatrix}"])
    aligned = sectionRows("broken-spacing-aligned", "Aligned (broken spacing command):", "END REGRESSION DEMO", ["\\begin{aligned}", "p_{\\mathrm{pred}}", "v_{\\mathrm{pred}}", "a_{\\mathrm{world}}", "\\\\[8pt]", "R(q)", "\\end{aligned}"])
    inline = delimited[1]
    hardWrap = raw[1]
    chinese = matrix[1]
    extraRows = delimited + raw + matrix
    }
} else {
    let alignedExpected = ["\\begin{aligned}", "a &= b+c", "\\sqrt{\\frac{1}{2}}", "\\end{aligned}"]
    inline = sample("inline", "Inline:", "\\pi", ["$e^{i\\pi}+1=0$"])
    hardWrap = sample("hard-wrap", "Hard-wrapped command, as seen through tmux:", "c{1}{2}", ["\\frac{1}{2}", "\\sum_{i=1}^{n}"])
    chinese = sample("Chinese", "Chinese context:", "x^2+y^2", ["$x^2+y^2=1$"])
    for (row, needle) in [("open", "\\["), ("begin", "\\begin{aligned}"), ("row-a", "a &= b+c \\\\"), ("row-x", "x &= \\sqrt{\\frac{1}{2}}"), ("end", "\\end{aligned}"), ("close", "\\]")] {
        let length = (needle as NSString).length
        for (position, offset) in [("start", 0), ("middle", length / 2), ("end", length - 1)] {
            aligned.append(sample("aligned-\(row)-\(position)", "Multi-line aligned math:", needle, alignedExpected, offset: offset))
        }
        aligned.append(sample("aligned-\(row)-padding", "Multi-line aligned math:", needle, alignedExpected, offset: length + 3, observeOnly: true))
    }
}
let primaryAligned = aligned[min(12, aligned.count - 1)]

let resources = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let hover = HoverController(resources: resources, enabled: false, allowedBundleIdentifiers: [bundleID],
                            report: { print("controller: \($0)") })
hover.timer?.invalidate()
let originalPoint = CGEvent(source: nil)?.location ?? inline.point
var failed = 0
var checked = 0
func correct(_ value: String, _ expected: [String]) -> Bool {
    // TeX treats ordinary newlines as whitespace; keep all backslashes intact.
    let normalized = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return expected.allSatisfy { fragment in
        normalized.contains(fragment.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression))
    } && !value.contains("z=99") && !value.contains("\u{2502}")
}
var checkedRecoveredIndices = Set<Int>()
for target in extraRows + aligned {
    guard !target.observeOnly, let index = target.sourceIndex, recoveredPointIndices.contains(index),
          checkedRecoveredIndices.insert(index).inserted else { continue }
    for attempt in 1...5 {
        let result = hover.readFormula(at: target.point, pid: terminal.processIdentifier)
        let pass = result.map { correct($0, target.expected) } ?? false
        checked += 1
        if !pass { failed += 1 }
        print("\(pass ? "PASS" : "FAIL") wrapped-cell-direct-\(attempt): index=\(index) point=\(target.point) stage=\(hover.lastDiagnostic) formula=\(String(reflecting: result))")
    }
}
hover.enabled = true
hover.timer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in hover.tick() }
func nativeRendering() -> (source: String, valid: Bool, size: NSSize) {
    var queue = hover.panel.contentView.map { [$0] } ?? []
    while !queue.isEmpty {
        let view = queue.removeFirst()
        if let label = view as? MTMathUILabel {
            let size = label.intrinsicContentSize
            let display = label.displayList
            let fits = size.width <= label.bounds.width + 1 && size.height <= label.bounds.height + 1 &&
                display != nil && display!.width <= label.bounds.width + 1 && display!.ascent + display!.descent <= label.bounds.height + 1
            let parentFits = hover.formulaView.frame == hover.panel.contentView?.bounds &&
                hover.formulaView.bounds.contains(label.frame)
            return (label.latex, !label.isHidden && label.error == nil && fits && parentFits, size)
        }
        queue.append(contentsOf: view.subviews)
    }
    return ("", false, .zero)
}
func diagnoseFailure(_ target: Sample) {
    var point = target.point
    let parameter = AXValueCreate(.cgPoint, &point)!
    var rangeValue: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForPositionParameterizedAttribute as CFString, parameter, &rangeValue)
    var range = CFRange(location: -1, length: 0)
    if let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
        AXValueGetValue(rangeValue as! AXValue, .cfRange, &range)
    }
    func character(_ index: Int?) -> String {
        guard let index, index >= 0, index < text.length else { return "<out-of-range>" }
        return text.substring(with: NSRange(location: index, length: 1))
    }
    let current = CGEvent(source: nil)?.location ?? .zero
    let previousStage = hover.lastDiagnostic
    let direct = hover.readFormula(at: target.point, pid: terminal.processIdentifier)
    print("DIAGNOSTIC \(target.name): target=\(target.point) actual=\(current) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none") sourceIndex=\(target.sourceIndex ?? -1) sourceCharacter=\(String(reflecting: character(target.sourceIndex))) axError=\(error.rawValue) axRange=\(range) axCharacter=\(String(reflecting: character(range.location))) generation=\(hover.generation) readGeneration=\(hover.lastReadGeneration) reading=\(hover.reading) stageBefore=\(previousStage) stageAfterDirect=\(hover.lastDiagnostic) direct=\(String(reflecting: direct))")
}
@discardableResult func visit(_ target: Sample, label: String? = nil) -> Bool {
    let began = Date()
    let previousPoint = CGEvent(source: nil)?.location ?? .zero
    let moved = hypot(previousPoint.x - target.point.x, previousPoint.y - target.point.y) > 2
    move(target.point)
    let updated = until(0.8) {
        (!moved || hover.lastRead >= began) && !hover.reading && hover.panel.isVisible && correct(hover.formula, target.expected)
    }
    let latency = Int(Date().timeIntervalSince(began) * 1000)
    let rendered = nativeRendering()
    let expectedBody = target.expected.map { FormulaView.normalizedRowSpacing($0.trimmingCharacters(in: CharacterSet(charactersIn: "$"))) }
    var pass = updated && rendered.valid && correct(rendered.source, expectedBody)
    if fullFormulas, target.name != "tiny-reset", let expected = fullFormulaBody {
        func compact(_ source: String) -> String { source.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression) }
        pass = pass && compact(rendered.source) == compact(FormulaView.normalizedRowSpacing(expected))
    }
    let status = target.observeOnly ? "OBSERVE" : (pass ? "PASS" : "FAIL")
    if !target.observeOnly { checked += 1; if !pass { failed += 1 } }
    print("\(status) \(label ?? target.name): \(latency)ms visible=\(hover.panel.isVisible) frame=\(hover.panel.frame) contentSize=\(rendered.size) renderedOK=\(rendered.valid) popupLatency=\(hover.lastPopupLatencyMS) formula=\(String(reflecting: hover.formula)) rendered=\(String(reflecting: rendered.source))")
    if !pass && !target.observeOnly { diagnoseFailure(target) }
    return pass
}

for cycle in 1...3 {
    for target in [inline, hardWrap, primaryAligned, chinese, inline] {
        visit(target, label: "cycle-\(cycle)/\(target.name)")
    }
}
for target in extraRows + aligned {
    visit(inline, label: "reset-before-\(target.name)")
    visit(target)
}
visit(primaryAligned, label: "stable-start")
let stableFrame = hover.panel.frame
let stablePopupLatency = hover.lastPopupLatencyMS
for target in aligned.filter({ !$0.observeOnly }) {
    visit(target, label: "same-formula/\(target.name)")
}
let stable = stableFrame == hover.panel.frame && stablePopupLatency == hover.lastPopupLatencyMS
checked += 1
if !stable { failed += 1 }
print("\(stable ? "PASS" : "FAIL") same-formula-frame-and-presentation-timestamp-stable")

if CommandLine.arguments.contains("--occlusion") {
    visit(inline, label: "occlusion-start")
    let point = primaryAligned.point
    let screenHeight = NSScreen.screens.first?.frame.height ?? 0
    hover.panel.setFrameOrigin(NSPoint(x: point.x - 30, y: screenHeight - point.y - 30))
    visit(primaryAligned, label: "target-covered-by-old-popup")
}

visit(inline, label: "before-app-revocation")
hover.setAllowedApplications([])
let revokedImmediately = !hover.panel.isVisible && hover.formula.isEmpty
pump(0.1)
hover.tick()
pump(0.1)
let revokedStaysHidden = revokedImmediately && !hover.panel.isVisible && hover.formula.isEmpty
checked += 1
if !revokedStaysHidden { failed += 1 }
print("\(revokedStaysHidden ? "PASS" : "FAIL") removing-app-immediately-hides-and-prevents-reappearance")
hover.setAllowedApplications([bundleID])
visit(inline, label: "restoring-app-resumes-hover")

hover.timer?.invalidate()
hover.hide()
move(inline.point)
pump(0.03)
hover.lastRead = .distantPast
hover.lastReadGeneration = -1
hover.tick()
let readStarted = hover.reading
hover.hide()
pump(0.8)
let stayedHidden = readStarted && !hover.panel.isVisible && hover.formula.isEmpty
checked += 1
if !stayedHidden { failed += 1 }
print("\(stayedHidden ? "PASS" : "FAIL") late-read-after-hide: readStarted=\(readStarted), visible=\(hover.panel.isVisible), formula=\(String(reflecting: hover.formula))")
hover.lastRead = .distantPast
hover.lastReadGeneration = -1
hover.tick()
let revokedReadStarted = hover.reading
hover.setAllowedApplications([])
pump(0.8)
let revokedReadStaysHidden = revokedReadStarted && !hover.panel.isVisible && hover.formula.isEmpty
checked += 1
if !revokedReadStaysHidden { failed += 1 }
print("\(revokedReadStaysHidden ? "PASS" : "FAIL") late-read-after-app-revocation: readStarted=\(revokedReadStarted), visible=\(hover.panel.isVisible), formula=\(String(reflecting: hover.formula))")
hover.enabled = false
hover.hide()
move(originalPoint)
print("Result: \(checked - failed)/\(checked) transition checks passed; padding rows are observational.")
exit(failed == 0 ? 0 : 1)

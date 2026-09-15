import AppKit
import ApplicationServices
import Foundation

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

func demoTextArea(_ application: AXUIElement) -> (AXUIElement, NSString)? {
    var queue = [(application, 0)]
    var visited = 0
    while !queue.isEmpty && visited < 2000 {
        let (element, depth) = queue.removeFirst()
        visited += 1
        if attribute(element, kAXRoleAttribute) as? String == kAXTextAreaRole,
           let value = attribute(element, kAXValueAttribute) as? String,
           value.contains("MATHPEEK HOVER DEMO"),
           value.contains("Multi-line aligned math:") {
            return (element, value as NSString)
        }
        if depth < 16, let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
    }
    return nil
}

struct Sample {
    let name: String
    let section: String
    let needle: String
    let expected: [String]
}

let samples = [
    Sample(name: "inline", section: "Inline:", needle: "\\pi", expected: ["$e^{i\\pi}+1=0$"]),
    Sample(name: "hard-wrap", section: "Hard-wrapped command, as seen through tmux:", needle: "c{1}{2}", expected: ["\\frac{1}{2}", "\\sum_{i=1}^{n}"]),
    Sample(name: "aligned", section: "Multi-line aligned math:", needle: "\\sqrt", expected: ["\\begin{aligned}", "\\sqrt{\\frac{1}{2}}", "\\end{aligned}"]),
    Sample(name: "Chinese context", section: "Chinese context:", needle: "x^2+y^2", expected: ["$x^2+y^2=1$"]),
]

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
print("AX trusted: \(AXIsProcessTrusted())")
guard AXIsProcessTrusted() else {
    print("BLOCKED: this probe has no Accessibility permission; no prompt was opened.")
    exit(2)
}
guard let iterm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.googlecode.iterm2").first else {
    print("BLOCKED: iTerm2 is not running.")
    exit(2)
}
let root = AXUIElementCreateApplication(iterm.processIdentifier)
AXUIElementSetMessagingTimeout(root, 1)
guard let (element, text) = demoTextArea(root) else {
    print("BLOCKED: the isolated MATHPEEK HOVER DEMO text area was not found.")
    exit(2)
}
print("Found isolated demo AXTextArea; UTF-16 length: \(text.length)")
if CommandLine.arguments.contains("--raise-demo") {
    var ancestor = element
    var demoWindow: AXUIElement?
    for _ in 0..<12 {
        if attribute(ancestor, kAXRoleAttribute) as? String == kAXWindowRole {
            demoWindow = ancestor
            break
        }
        guard let parent = attribute(ancestor, kAXParentAttribute),
              CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
        ancestor = parent as! AXUIElement
    }
    guard let demoWindow else {
        print("BLOCKED: the isolated demo's enclosing window was not found.")
        exit(2)
    }
    let firstRaise = AXUIElementPerformAction(demoWindow, kAXRaiseAction as CFString)
    iterm.activate(options: [.activateIgnoringOtherApps])
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let secondRaise = AXUIElementPerformAction(demoWindow, kAXRaiseAction as CFString)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    print("Raised isolated demo window: \(firstRaise.rawValue), \(secondRaise.rawValue)")
}
let resources = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Applications/Math Peek.app/Contents/Resources")
let hover = HoverController(resources: resources, report: { print("controller: \($0)") })
hover.timer?.invalidate()
hover.enabled = false
var passed = 0
var popupSample: (String, CGPoint)?
var dumpedOffsets: [String: Int] = [:]
for sample in samples {
    let section = text.range(of: sample.section, options: .backwards)
    guard section.location != NSNotFound else {
        print("FAIL \(sample.name): fixture section missing")
        continue
    }
    let located = text.range(of: sample.needle, range: NSRange(location: NSMaxRange(section), length: text.length - NSMaxRange(section)))
    guard located.location != NSNotFound else {
        print("FAIL \(sample.name): needle missing from isolated demo")
        continue
    }
    dumpedOffsets[sample.name] = (text.substring(to: located.location)).unicodeScalars.count
    var requested = CFRange(location: located.location, length: 1)
    let parameter = AXValueCreate(.cfRange, &requested)!
    var boundsValue: CFTypeRef?
    let boundsError = AXUIElementCopyParameterizedAttributeValue(
        element, kAXBoundsForRangeParameterizedAttribute as CFString, parameter, &boundsValue)
    var bounds = CGRect.zero
    guard boundsError == .success, let boundsValue,
          CFGetTypeID(boundsValue) == AXValueGetTypeID(),
          AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds),
          bounds.width > 0, bounds.height > 0 else {
        print("FAIL \(sample.name): AXBoundsForRange error=\(boundsError.rawValue), bounds=\(bounds)")
        continue
    }
    var point = CGPoint(x: bounds.midX, y: bounds.midY)
    let pointParameter = AXValueCreate(.cgPoint, &point)!
    var foundRangeValue: CFTypeRef?
    let rangeError = AXUIElementCopyParameterizedAttributeValue(
        element, kAXRangeForPositionParameterizedAttribute as CFString, pointParameter, &foundRangeValue)
    var found = CFRange(location: -1, length: 0)
    if let foundRangeValue, CFGetTypeID(foundRangeValue) == AXValueGetTypeID() {
        AXValueGetValue(foundRangeValue as! AXValue, .cfRange, &found)
    }
    var hit: AXUIElement?
    let hitError = AXUIElementCopyElementAtPosition(hover.system, Float(point.x), Float(point.y), &hit)
    var owner: pid_t = 0
    if let hit { AXUIElementGetPid(hit, &owner) }
    let role = hit.flatMap { attribute($0, kAXRoleAttribute) as? String } ?? "unknown"
    let ownerBundle = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier ?? "unknown"
    let sameElement = hit.map { CFEqual($0, element) } ?? false
    let hitDemo = (hit.flatMap { attribute($0, kAXValueAttribute) as? String } ?? "").contains("MATHPEEK HOVER DEMO")
    print("\(sample.name): index=\(located.location), bounds=\(bounds), point=\(point), rangeError=\(rangeError.rawValue), returnedRange=\(found), hitError=\(hitError.rawValue), hitRole=\(role), hitApp=\(ownerBundle), targetPIDMatches=\(owner == iterm.processIdentifier), sameElement=\(sameElement), hitDemo=\(hitDemo)")
    let captureStarted = Date()
    let result = hover.readFormula(at: point, pid: iterm.processIdentifier)
    print("Capture time: \(Int(Date().timeIntervalSince(captureStarted) * 1000)) ms")
    let correct = result.map { formula in
        sample.expected.allSatisfy(formula.contains) && !formula.contains("z=99") && !formula.contains("│")
    } ?? false
    if correct { passed += 1 }
    if correct, sample.name == "aligned", let result { popupSample = (result, point) }
    // Result content is printed only after locating the explicit demo fixture.
    print("\(correct ? "PASS" : "FAIL") \(sample.name): \(String(reflecting: result))")
}
print("Result: \(passed)/\(samples.count) live AX hover extractions passed")
if CommandLine.arguments.contains("--dump") {
    let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/demo-ax.json")
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: ["text": text as String, "offsets": dumpedOffsets], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: destination, options: .atomic)
    print("Dumped isolated demo AXValue and codepoint offsets to \(destination.path)")
}
if CommandLine.arguments.contains("--live"), let (_, point) = popupSample {
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 10, y: 10), mouseButton: .left)?.post(tap: .cghidEventTap)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    RunLoop.main.run(until: Date().addingTimeInterval(1))
    let liveApp = NSRunningApplication.runningApplications(withBundleIdentifier: "local.mathpeek.preview").first
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let popup = windows.first { row in
        (row[kCGWindowOwnerPID as String] as? Int32) == liveApp?.processIdentifier &&
        (row[kCGWindowLayer as String] as? Int ?? 0) > 0
    }
    print("Actual installed app hover popup: \(popup != nil)")
    if let id = popup?[kCGWindowNumber as String] as? Int {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(id), "/tmp/math-peek-live-hover.png"]
        try capture.run()
        capture.waitUntilExit()
    }
}
if CommandLine.arguments.contains("--show"), let (result, point) = popupSample {
    hover.enabled = true
    hover.formula = result
    hover.anchor = NSPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    hover.present(result)
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    print("Popup visible: \(hover.panel.isVisible); renderer ready: \(hover.ready)")
    if hover.panel.isVisible {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-l", String(hover.panel.windowNumber), "/tmp/math-peek-hover-smoke.png"]
        try capture.run()
        capture.waitUntilExit()
    }
}
exit(passed == samples.count ? 0 : 1)

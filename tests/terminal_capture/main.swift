import AppKit
import ApplicationServices

var checks = 0
var failures = 0
func check(_ condition: Bool, _ name: String) {
    checks += 1
    if !condition { failures += 1; print("FAIL \(name)") }
}
func argument(_ flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag), index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

let text = "offscreen history\nvisible $x^2$\nprivate later output"
let viewport = (text as NSString).range(of: "visible $x^2$\n")
check(TerminalCaptureRange.substring(text, range: CFRange(location: viewport.location, length: viewport.length)) == "visible $x^2$\n",
      "viewport does not include preceding or following terminal history")
check(TerminalCaptureRange.substring("a\u{1F680}b", range: CFRange(location: 1, length: 2)) == "\u{1F680}", "AX UTF-16 offsets preserve supplementary characters")
check(TerminalCaptureRange.substring("a\u{1F680}b", range: CFRange(location: 2, length: 1)) == nil, "range cannot split a surrogate pair")
check(TerminalCaptureRange.substring("ab\0cd", range: CFRange(location: 0, length: 5)) == "ab cd", "empty terminal cells become spaces")
check(TerminalCaptureRange.substring(text, range: CFRange(location: -1, length: 1)) == nil, "negative AX range rejected")
check(TerminalCaptureRange.substring(text, range: CFRange(location: 1, length: Int.max)) == nil, "overflowing AX range rejected")
check(TerminalCaptureRange.substring(text, range: CFRange(location: Int.max, length: 1)) == nil, "out of bounds AX range rejected")
check(TerminalCaptureRange.substring("", range: CFRange(location: 0, length: 0)) == "", "empty viewport remains empty")
let combined = TerminalCaptureRange.spanning(CFRange(location: 10, length: 5), CFRange(location: 24, length: 8), length: 50)
check(combined?.location == 10 && combined?.length == 22, "viewport spans first and last visible line only")
check(TerminalCaptureRange.spanning(CFRange(location: 20, length: 1), CFRange(location: 10, length: 1), length: 50) == nil,
      "reversed or stale viewport positions rejected")
check(TerminalCaptureRange.spanning(CFRange(location: 0, length: 1), CFRange(location: 49, length: 2), length: 50) == nil,
      "viewport end beyond retained terminal text rejected")

if let bundle = argument("--bundle-id"), let marker = argument("--marker") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard AXIsProcessTrusted() else {
        print("BLOCKED: capture test lacks Accessibility permission; no permission prompt was opened")
        exit(2)
    }
    guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier,
          let target = TerminalCaptureTarget(running, allowedBundleIdentifiers: [bundle]) else {
        print("BLOCKED: raise the isolated capture fixture in \(bundle)")
        exit(2)
    }
    do {
        let start = Date()
        let capture = try TerminalCapture().read(target, selectionFirst: !CommandLine.arguments.contains("--screen"))
        check(capture.text.contains(marker), "native AX capture contains the isolated fixture marker")
        if CommandLine.arguments.contains("--expect-selection") {
            check(capture.isSelection, "selection takes priority over viewport")
        }
        if let absent = argument("--absent") {
            check(!capture.text.contains(absent), "offscreen fixture marker is excluded")
        }
        print("Native capture: \(capture.text.utf8.count) bytes, selection=\(capture.isSelection), \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    } catch {
        check(false, "native AX capture: \(error.localizedDescription)")
    }
}
print("Terminal capture: \(checks - failures)/\(checks) passed")
exit(failures == 0 ? 0 : 1)

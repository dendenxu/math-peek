import AppKit
import ApplicationServices
import Darwin

// Opt-in research probe. All terminal output and captured AX text belong to its own fixture.
let marker = "MATH PEEK OWNED GHOSTTY RESEARCH"
let formulaA = #"Formula: \boxed{K = \frac{P}{P+R}}"#
let formulaB = #"Formula: \boxed{K = \frac{Q}{Q+R}}"#
func writeJSON(_ value: Any, _ url: URL) throws {
  try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    .write(to: url, options: .atomic)
}
func pause(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func fail(_ message: String) -> Never {
  fputs("\(message)\n", stderr)
  exit(1)
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func element(_ value: CFTypeRef?) -> AXUIElement? {
  guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
  return (value as! AXUIElement)
}
func size(_ value: CFTypeRef?) -> CGSize? {
  guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
  var result = CGSize.zero
  return AXValueGetValue(value as! AXValue, .cgSize, &result) ? result : nil
}

func runFixture(_ root: URL) throws {
  try writeJSON(["started": true, "pid": getpid()], root.appendingPathComponent("started.json"))
  var original = termios()
  guard tcgetattr(STDIN_FILENO, &original) == 0 else { fail("Fixture needs its own terminal") }
  var raw = original
  cfmakeraw(&raw)
  tcsetattr(STDIN_FILENO, TCSANOW, &raw)
  defer { tcsetattr(STDIN_FILENO, TCSANOW, &original) }
  func output(_ text: String) {
    print(text, terminator: "")
    fflush(stdout)
  }
  func cellSize() -> [Int] {
    output("\u{1b}[16t")
    var answer = [UInt8]()
    let deadline = Date().addingTimeInterval(0.3)
    while Date() < deadline {
      var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      if poll(&descriptor, 1, 10) > 0 {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count > 0 { answer += buffer.prefix(count) }
        if answer.last == 116 { break }
      }
    }
    let string = String(decoding: answer, as: UTF8.self)
    guard string.hasPrefix("\u{1b}[6;"), string.hasSuffix("t") else { return [] }
    return string.dropFirst(4).dropLast().split(separator: ";").compactMap { Int($0) }
  }
  #if GHOSTTY_ADAPTER_LIVE
  guard let client = TerminalProcess.read(getpid()), let ghostty = TerminalProcess.ghosttyAncestor(of: getpid()),
    let dimensions = TerminalDimensions.read(STDIN_FILENO), let tty = ttyname(STDIN_FILENO) else { fail("Missing local Ghostty terminal") }
  let measuredCell = try GhosttyConnectCommand.cellSize(STDIN_FILENO)
  var ttyMetadata = stat()
  guard fstat(STDIN_FILENO, &ttyMetadata) == 0 else { fail("Missing TTY metadata") }
  let pairing = GhosttyConnectionRequest(client: client, ghostty: ghostty, ttyPath: String(cString: tty),
    ttyDevice: UInt32(bitPattern: ttyMetadata.st_rdev), session: tcgetsid(STDIN_FILENO), dimensions: dimensions,
    cellWidthPixels: measuredCell.width, cellHeightPixels: measuredCell.height)
  try pairing.validate()
  let pairingName = try GhosttyConnectionFiles.writeRequest(pairing)
  defer { GhosttyConnectionFiles.remove(pairingName) }
  try pairingName.write(to: root.appendingPathComponent("pairing.txt"), atomically: true, encoding: .utf8)
  output(marker + "\r\n" + pairing.marker + "\r\n")
  let pairingDeadline = Date().addingTimeInterval(15)
  while (try? String(contentsOf: root.appendingPathComponent("control.txt"), encoding: .utf8)) == "pairing", Date() < pairingDeadline { usleep(10_000) }
  #endif
  var previous = ""
  let fixtureDeadline = Date().addingTimeInterval(120)
  while Date() < fixtureDeadline {
    let current =
      (try? String(contentsOf: root.appendingPathComponent("control.txt"), encoding: .utf8)) ?? ""
    if current != previous, !current.isEmpty {
      previous = current
      if current == "quit" { break }
      if current == "redrawB" {
        output("\u{1b}[2;1H" + formulaB)
      } else {
        output("\u{1b}[0m\u{1b}[3J\u{1b}[2J\u{1b}[H\u{1b}]2;\(marker)\u{7}")
        if current.hasPrefix("history") {
          for row in 0..<160 { output(String(format: "History row %03d\r\n", row)) }
        }
        output(marker + "\r\n")
        if current == "erased-wrap" {
          output(String(repeating: "A", count: 160) + #"\boxed{K = \frac{P}{P+R}}"# + "\r\nEND")
          // EL2 preserves the soft-wrap state of a row, unlike EL0/ECH.
          output(
            "\u{1b}[2;1H\u{1b}[2K" + String(repeating: "A", count: 20) + "\u{1b}[3;1H\u{1b}[2K")
        } else if current == "plain-wrap" {
          output(
            String(repeating: "A", count: 20) + "\r\n" + String(repeating: " ", count: 60)
              + #"\boxed{K = \frac{P}{P+R}}"# + "\r\nEND")
        } else if current == "visibleA" || current == "concealA" {
          output((current == "concealA" ? "\u{1b}[8m" : "") + formulaA + "\u{1b}[0m\r\nEND")
        } else {
          output(#"Euler: $e^{i\pi}+1=0$"# + "\r\n\r\n")
          output(#"Bare: \boxed{K = \frac{P}{P+R}}"# + "\r\n")
          if current.contains("wrap") {
            output(
              String(repeating: "A", count: 95) + #" \boxed{x^2+y^2=z^2} "#
                + String(repeating: "Z", count: 100) + "\r\n")
          }
          output(
            #"Paths: "$HOME/Applications/Ghostty.app" "$HOME/Applications/cmux.app""#
              + "\r\nEND OWNED GHOSTTY RESEARCH\r\n")
        }
      }
      let writtenAt = ProcessInfo.processInfo.systemUptime
      var dimensions = winsize()
      let error = ioctl(STDOUT_FILENO, TIOCGWINSZ, &dimensions)
      let cell = current == "redrawB" ? [] : cellSize()
      try writeJSON(
        [
          "case": current, "pid": getpid(), "writtenAt": writtenAt,
          "rows": Int(dimensions.ws_row), "columns": Int(dimensions.ws_col),
          "width_px": Int(dimensions.ws_xpixel), "height_px": Int(dimensions.ws_ypixel),
          "cell_height_px": cell.first ?? 0, "cell_width_px": cell.last ?? 0,
          "ioctl_error": error,
        ], root.appendingPathComponent("ack.json"))
    }
    usleep(5_000)
  }
}

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fixture" {
  do { try runFixture(URL(fileURLWithPath: CommandLine.arguments[2])) } catch {
    fail(error.localizedDescription)
  }
  exit(0)
}

func runProbe() throws {
  guard CommandLine.arguments.count == 3 else {
    fail("Usage: probe /path/to/isolated/Ghostty.app /path/to/new/output-directory")
  }
  guard AXIsProcessTrusted() else { fail("The invoking tool needs Accessibility permission") }
  let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
  let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
  guard let bundle = Bundle(url: appURL), let bundleID = bundle.bundleIdentifier else {
    fail("Invalid app bundle")
  }
  guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
    fail("Quit this Ghostty bundle first; the probe will not interact with existing windows")
  }
  guard !FileManager.default.fileExists(atPath: root.path) else {
    fail("Output directory must not already exist")
  }
  try FileManager.default.createDirectory(
    at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let previous = NSWorkspace.shared.frontmostApplication
  #if GHOSTTY_INSTALLED_LIVE
  let originalPointer = CGEvent(source: nil)!.location
  var expectedPointer = originalPointer
  var interrupted = false
  guard let installed = NSRunningApplication.runningApplications(withBundleIdentifier: "local.mathpeek.preview")
    .first(where: { $0.bundleURL?.path == NSHomeDirectory() + "/Applications/Math Peek.app" }) else { fail("Installed Math Peek must be running") }
  #endif
  #if GHOSTTY_ADAPTER_LIVE
  let initialCase = "pairing"
  #else
  let initialCase = "short"
  #endif
  try initialCase.write(
    to: root.appendingPathComponent("control.txt"), atomically: true, encoding: .utf8)
  try """
  font-size = 14
  window-padding-x = 0
  window-padding-y = 0
  window-padding-balance = false
  window-width = 80
  window-height = 24
  window-save-state = never
  scrollbar = system
  confirm-close-surface = false
  quit-after-last-window-closed = true
  macos-applescript = true
  """.write(to: root.appendingPathComponent("config"), atomically: true, encoding: .utf8)
  let launcher = Process()
  func shellQuote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
  }
  let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
  let wrapper = root.appendingPathComponent("fixture.sh")
  var connectCommand = ""
  #if GHOSTTY_INSTALLED_LIVE
  let installedCLI = NSHomeDirectory() + "/Applications/Math Peek.app/Contents/MacOS/MathPeekCLI"
  connectCommand = shellQuote(installedCLI) + " connect ghostty 2>"
    + shellQuote(root.appendingPathComponent("connection-error.txt").path) + " || exit 1\n"
  #endif
  try
    ("#!/bin/sh\n" + connectCommand + "exec " + shellQuote(executable) + " --fixture " + shellQuote(root.path)
    + " 2>" + shellQuote(root.appendingPathComponent("fixture-error.txt").path) + "\n")
    .write(to: wrapper, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
  launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  // The owned app creates a fresh local TTY; do not inherit the test runner's
  // tmux/SSH markers into its shell.
  var launchEnvironment = ProcessInfo.processInfo.environment
  for key in ["TMUX", "STY", "SSH_CONNECTION", "SSH_TTY"] { launchEnvironment.removeValue(forKey: key) }
  launcher.environment = launchEnvironment
  launcher.arguments = [
    "-n", "-a", appURL.path, "--args", "--config-default-files=false",
    "--config-file=\(root.appendingPathComponent("config").path)", "-e", wrapper.path,
  ]
  try launcher.run()
  launcher.waitUntilExit()
  guard launcher.terminationStatus == 0 else { fail("Could not launch fixture") }
  var owned: NSRunningApplication?
  for _ in 0..<80 {
    owned = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
      .first { $0.bundleURL?.standardizedFileURL == appURL }
    if owned?.isFinishedLaunching == true { break }
    pause(0.1)
  }
  guard let owned else { fail("Owned app did not start") }
  defer {
    try? "quit".write(
      to: root.appendingPathComponent("control.txt"), atomically: true, encoding: .utf8)
    pause(0.3)
    if !owned.isTerminated { owned.terminate() }
    #if GHOSTTY_INSTALLED_LIVE
    if !interrupted { CGWarpMouseCursorPosition(originalPointer); previous?.activate(options: []) }
    #else
    previous?.activate(options: [])
    #endif
  }
  owned.activate(options: [])
  let app = AXUIElementCreateApplication(owned.processIdentifier)
  AXUIElementSetMessagingTimeout(app, 0.25)
  var textArea: AXUIElement?
  for _ in 0..<80 {
    var queue = (attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).map { ($0, 0) }
    var visited = 0
    while !queue.isEmpty, visited < 300 {
      visited += 1
      let (node, depth) = queue.removeFirst()
      if attribute(node, kAXRoleAttribute) as? String == kAXTextAreaRole,
        let value = attribute(node, kAXValueAttribute) as? String, value.contains(marker)
      {
        textArea = node
        break
      }
      if depth < 15 {
        queue += (attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? []).map {
          ($0, depth + 1)
        }
      }
    }
    if textArea != nil { break }
    pause(0.1)
  }
  guard let textArea else {
    throw NSError(
      domain: "Probe", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "Owned fixture text area missing"])
  }
  #if GHOSTTY_INSTALLED_LIVE
  func popupVisible() -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.contains { ($0[kCGWindowOwnerPID as String] as? Int) == Int(installed.processIdentifier) &&
      ($0[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.floatingWindow)) &&
      ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0 }
  }
  func verifyPopup(_ point: CGPoint, expected: Bool, blank: CGPoint) throws {
    func checkInteraction() throws {
      let mouse = CGEvent(source: nil)!.location
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == owned.processIdentifier,
        hypot(mouse.x - expectedPointer.x, mouse.y - expectedPointer.y) < 3 else {
        interrupted = true
        throw NSError(domain: "Installed probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "User interaction; stopping the owned-window test"])
      }
    }
    func move(_ point: CGPoint) { CGWarpMouseCursorPosition(point); expectedPointer = point }
    try checkInteraction()
    move(blank); pause(0.12); try checkInteraction()
    guard !popupVisible() else { throw NSError(domain: "Installed popup did not hide", code: 2) }
    let start = ProcessInfo.processInfo.systemUptime
    move(point)
    var visible = false
    repeat {
      pause(0.01); try checkInteraction(); visible = popupVisible()
      if visible { break }
    } while ProcessInfo.processInfo.systemUptime - start < (expected ? 1 : 0.25)
    print("Installed popup", expected == visible ? "PASS" : "FAIL", "expected", expected, "ms", (ProcessInfo.processInfo.systemUptime - start) * 1000)
    guard visible == expected else { throw NSError(domain: "Installed popup", code: 3) }
  }
  #endif
  #if GHOSTTY_ADAPTER_LIVE
  let hoverSource = GhosttyHoverSource()
  let pairingName = try String(contentsOf: root.appendingPathComponent("pairing.txt"), encoding: .utf8)
  try hoverSource.connect(GhosttyConnectionFiles.consumeRequest(pairingName))
  guard hoverSource.connectedCount == 1 else { fail("Production adapter did not retain the binding") }
  guard hoverSource.read(at: .zero, element: app, pid: owned.processIdentifier).stage == "ghostty-connection-required" else { fail("Binding leaked to a different AX element") }
  print("Production adapter paired the exact AX text area and local TTY")
  #endif
  var scrollArea: AXUIElement?
  var ancestor = textArea
  for _ in 0..<10 {
    guard let parent = element(attribute(ancestor, kAXParentAttribute)) else { break }
    if attribute(parent, kAXRoleAttribute) as? String == kAXScrollAreaRole {
      scrollArea = parent
      break
    }
    ancestor = parent
  }
  guard let scrollArea else { throw NSError(domain: "Probe", code: 2) }
  func command(_ name: String) throws -> [String: Any] {
    try name.write(
      to: root.appendingPathComponent("control.txt"), atomically: true, encoding: .utf8)
    for _ in 0..<200 {
      if let data = try? Data(contentsOf: root.appendingPathComponent("ack.json")),
        let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        value["case"] as? String == name
      {
        return value
      }
      pause(0.005)
    }
    throw NSError(
      domain: "Probe", code: 3,
      userInfo: [NSLocalizedDescriptionKey: "Fixture did not acknowledge \(name)"])
  }
  func snapshot() throws -> [String: Any] {
    func read(_ node: AXUIElement, _ key: String) throws -> CFTypeRef {
      var value: CFTypeRef?
      let error = AXUIElementCopyAttributeValue(node, key as CFString, &value)
      guard error == .success, let value else {
        throw NSError(
          domain: "Probe", code: 4,
          userInfo: [NSLocalizedDescriptionKey: "\(key) failed: \(error.rawValue)"])
      }
      return value
    }
    let start = ProcessInfo.processInfo.systemUptime
    guard let text = try read(textArea, kAXValueAttribute) as? String,
      text.contains(marker), text.utf8.count <= 2 * 1024 * 1024,
      let view = size(try read(textArea, kAXSizeAttribute)), view.width > 0, view.height > 0,
      let document = size(try read(scrollArea, "AXContentSize")), document.height >= view.height,
      let scrollbar = element(try read(scrollArea, kAXVerticalScrollBarAttribute)),
      let scrollValue = try read(scrollbar, kAXValueAttribute) as? Double,
      scrollValue.isFinite, (0...1).contains(scrollValue)
    else {
      throw NSError(
        domain: "Probe", code: 5,
        userInfo: [NSLocalizedDescriptionKey: "Invalid fixture text or AX geometry"])
    }
    var origin = CGPoint.zero
    let position = try read(textArea, kAXPositionAttribute)
    guard CFGetTypeID(position) == AXValueGetTypeID(),
      AXValueGetValue(position as! AXValue, .cgPoint, &origin)
    else { throw NSError(domain: "Probe", code: 6) }
    let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
    let scale =
      NSScreen.screens.first {
        CGRect(
          x: $0.frame.minX, y: screenTop - $0.frame.maxY,
          width: $0.frame.width, height: $0.frame.height
        ).contains(origin)
      }?.backingScaleFactor ?? 0
    guard scale > 0 else { throw NSError(domain: "Probe", code: 7) }
    return [
      "text": text, "utf16_count": text.utf16.count,
      "logical_lines": text.components(separatedBy: "\n").count,
      "view_width": view.width, "view_height": view.height,
      "view_x": origin.x, "view_y": origin.y, "scale": scale,
      "document_height": document.height,
      "scrollbar": scrollValue,
      "read_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
    ]
  }
  var report: [String: Any] = [
    "schema_version": 1,
    "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?",
    "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?", "cases": [],
  ]
  var cases = [[String: Any]]()
  for name in ["short", "history", "wrap", "history-wrap", "erased-wrap", "plain-wrap"] {
    let ack = try command(name)
    guard ack["columns"] as? Int == 80, ack["ioctl_error"] as? Int == 0,
      (ack["cell_width_px"] as? Int ?? 0) > 0, (ack["cell_height_px"] as? Int ?? 0) > 0
    else {
      throw NSError(
        domain: "Probe", code: 8,
        userInfo: [
          NSLocalizedDescriptionKey:
            "Static fixtures require an 80-column grid and a valid CSI 16 response"
        ])
    }
    pause(0.65)
    let sample = try snapshot()
    #if GHOSTTY_ADAPTER_LIVE || GHOSTTY_INSTALLED_LIVE
    let expectedRows: [String: (Int, Int)] = ["short": (1, 3), "history": (18, 20), "wrap": (1, 3), "history-wrap": (15, 17)]
    if let (euler, bare) = expectedRows[name] {
      let scale = sample["scale"] as! CGFloat
      let cellWidth = CGFloat(ack["cell_width_px"] as! Int) / scale
      let cellHeight = CGFloat(ack["cell_height_px"] as! Int) / scale
      var hits: [(Int, Int, String?)] = [(euler, 10, #"$e^{i\pi}+1=0$"#), (bare, 14, #"\boxed{K = \frac{P}{P+R}}"#)]
      if name == "wrap" || name == "history-wrap" { hits.append((name == "wrap" ? 5 : 19, 20, #"\boxed{x^2+y^2=z^2}"#)) }
      let pathRow = name == "short" ? 4 : name == "wrap" ? 7 : 21
      hits += [(pathRow, 18, nil), (pathRow, 57, nil), (23, 10, nil)]
      for (row, column, formula) in hits {
        let point = CGPoint(x: sample["view_x"] as! CGFloat + (CGFloat(column) + 0.5) * cellWidth,
                            y: sample["view_y"] as! CGFloat + (CGFloat(row) + 0.5) * cellHeight)
        #if GHOSTTY_ADAPTER_LIVE
        let readStart = ProcessInfo.processInfo.systemUptime
        let result = hoverSource.read(at: point, element: textArea, pid: owned.processIdentifier)
        guard result.formula == formula else { throw NSError(domain: "Adapter", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) row \(row) failed: \(result.stage)"]) }
        print("Adapter hit", name, row, result.formula ?? "none", "ms", (ProcessInfo.processInfo.systemUptime - readStart) * 1000)
        #else
        try verifyPopup(point, expected: formula != nil, blank: CGPoint(x: sample["view_x"] as! CGFloat + 5, y: sample["view_y"] as! CGFloat + 5))
        #endif
      }
    } else {
      let point = CGPoint(x: sample["view_x"] as! CGFloat + 60.5 * 8.5, y: sample["view_y"] as! CGFloat + 2.5 * 18.5)
      #if GHOSTTY_ADAPTER_LIVE
      let result = hoverSource.read(at: point, element: textArea, pid: owned.processIdentifier)
      guard result.formula == nil, result.stage == "ghostty-layout-unsupported" else { throw NSError(domain: "Adapter", code: 2) }
      print("Adapter rejected known ambiguous indented wrap", name)
      #else
      try verifyPopup(point, expected: false, blank: CGPoint(x: sample["view_x"] as! CGFloat + 5, y: sample["view_y"] as! CGFloat + 5))
      #endif
    }
    #endif
    cases.append(["case": name, "fixture": ack, "ax": sample])
    print(
      name, "lines", sample["logical_lines"]!, "height", sample["document_height"]!, "scroll",
      sample["scrollbar"]!, "read_ms", sample["read_ms"]!)
  }
  _ = try command("visibleA")
  pause(0.65)
  let normal = try snapshot()
  guard (normal["text"] as? String)?.contains(formulaA) == true else {
    throw NSError(
      domain: "Probe", code: 9,
      userInfo: [NSLocalizedDescriptionKey: "Formula A did not arrive before the redraw baseline"])
  }
  let change = try command("redrawB")
  let writtenAt = change["writtenAt"] as! Double
  var samples = [[String: Any]]()
  for target in [0.0, 20.0, 100.0, 300.0, 520.0, 650.0] {
    let remaining = target / 1000 - (ProcessInfo.processInfo.systemUptime - writtenAt)
    if remaining > 0 { pause(remaining) }
    var sample = try snapshot()
    sample["after_write_ms"] = (ProcessInfo.processInfo.systemUptime - writtenAt) * 1000
    samples.append(sample)
    print(
      "redraw", sample["after_write_ms"]!, "has_old",
      (sample["text"] as! String).contains(formulaA), "has_new",
      (sample["text"] as! String).contains(formulaB))
  }
  _ = try command("concealA")
  pause(0.65)
  let concealed = try snapshot()
  guard (concealed["text"] as? String)?.contains(formulaA) == true else {
    throw NSError(
      domain: "Probe", code: 10,
      userInfo: [
        NSLocalizedDescriptionKey: "Concealed fixture text was not available; comparison skipped"
      ])
  }
  report["cases"] = cases
  report["redraw"] = samples
  report["visible"] = normal
  report["concealed"] = concealed
  report["visible_and_concealed_same_text"] =
    normal["text"] as? String == concealed["text"] as? String
  try writeJSON(report, root.appendingPathComponent("report.json"))
  print("Concealed text indistinguishable:", report["visible_and_concealed_same_text"]!)

  // Scroll only the probe-owned terminal through Ghostty's supported action interface.
  _ = try command("history")
  pause(0.65)
  let scroll = Process()
  scroll.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  let appleScriptPath = appURL.path.replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
  scroll.arguments = [
    "-e",
    "tell application \"\(appleScriptPath)\" to perform action \"scroll_to_row:80\" on first terminal",
  ]
  let scrollOutput = Pipe()
  scroll.standardOutput = scrollOutput
  scroll.standardError = scrollOutput
  try scroll.run()
  let scrollDeadline = Date().addingTimeInterval(3)
  while scroll.isRunning, Date() < scrollDeadline { pause(0.05) }
  if scroll.isRunning {
    scroll.terminate()
    pause(0.2)
    if scroll.isRunning { kill(scroll.processIdentifier, SIGKILL) }
  }
  scroll.waitUntilExit()
  pause(0.2)
  report["scroll_to_row_80"] = ["exit_status": scroll.terminationStatus, "ax": try snapshot()]

  if let window = element(attribute(textArea, kAXWindowAttribute)) {
    let originalSize = size(attribute(window, kAXSizeAttribute)) ?? .zero
    var changedSize = CGSize(width: originalSize.width + 23, height: originalSize.height + 19)
    if let value = AXValueCreate(.cgSize, &changedSize) {
      let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
      pause(0.2)
      let ack = try command("history-resize")
      pause(0.65)
      report["resize"] = ["set_size_status": result.rawValue, "fixture": ack, "ax": try snapshot()]
      #if GHOSTTY_ADAPTER_LIVE
      let resized = try snapshot()
      let point = CGPoint(x: resized["view_x"] as! CGFloat + 14.5 * 8.5, y: resized["view_y"] as! CGFloat + 21.5 * 18.5)
      let hit = hoverSource.read(at: point, element: textArea, pid: owned.processIdentifier)
      guard hit.formula == #"\boxed{K = \frac{P}{P+R}}"# else { throw NSError(domain: "Adapter resize", code: 3, userInfo: [NSLocalizedDescriptionKey: hit.stage]) }
      hoverSource.invalidateMetrics(pid: owned.processIdentifier)
      guard hoverSource.read(at: point, element: textArea, pid: owned.processIdentifier).stage == "ghostty-reconnect-required" else { throw NSError(domain: "Adapter font invalidation", code: 4) }
      print("Adapter revalidated resize and suspended after font-change invalidation")
      #endif
    }
  }
  try writeJSON(report, root.appendingPathComponent("report.json"))
  print("Report:", root.appendingPathComponent("report.json").path)
  #if GHOSTTY_ADAPTER_LIVE
  try "quit".write(to: root.appendingPathComponent("control.txt"), atomically: true, encoding: .utf8)
  let closeDeadline = Date().addingTimeInterval(3)
  while hoverSource.connectedCount != 0, Date() < closeDeadline { pause(0.05) }
  guard hoverSource.connectedCount == 0 else { throw NSError(domain: "Adapter close", code: 5) }
  print("Adapter released the closed pane binding")
  #endif
}

do { try runProbe() } catch { fail(error.localizedDescription) }

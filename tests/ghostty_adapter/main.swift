import Foundation
import CoreGraphics
import Darwin

var passed = 0, failed = 0
func check(_ value: @autoclosure () -> Bool, _ name: String) {
    if value() { passed += 1 } else { failed += 1; print("FAIL \(name)") }
}
func rejects(_ name: String, _ action: () throws -> Void) {
    do { try action(); check(false, name) } catch { check(true, name) }
}
let boxed = #"\boxed{K = \frac{P}{P+R}}"#
func hit(_ grid: GhosttyGrid?, row: Int, column: Int, rows: Int = 24, total: Int = 24,
         scroll: Double = 0, padding: CGSize = .zero) -> String? {
    grid?.formula(at: CGPoint(x: 100 + (CGFloat(column) + 0.5) * 8.5, y: 200 + (CGFloat(row) + 0.5) * 18.5),
        area: CGRect(x: 100, y: 200, width: CGFloat(grid!.columns) * 8.5 + padding.width,
                     height: CGFloat(rows) * 18.5 + padding.height),
        cellSize: CGSize(width: 8.5, height: 18.5), rows: rows,
        documentHeight: CGFloat(total) * 18.5 + padding.height, scrollbar: scroll)
}
let source = "Header\nEuler: $e^{i\\pi}+1=0$\n\nBare: " + boxed + "\n"
let grid = GhosttyGrid(text: source, columns: 80)
check(hit(grid, row: 1, column: 10) == #"$e^{i\pi}+1=0$"#, "Euler hover")
check(hit(grid, row: 3, column: 12) == boxed, "bare boxed hover")
let strippedInline = GhosttyGrid(text: #"value: (c_{\mathrm{ref}})"#, columns: 80)
check(hit(strippedInline, row: 0, column: 12) == #"\(c_{\mathrm{ref}}\)"#,
      "Markdown-stripped inline delimiters retain their original grid range")
let strippedDisplay = GhosttyGrid(text: "[\nx = \\frac{1}{2}\n]", columns: 80)
let strippedDisplayFormula = hit(strippedDisplay, row: 1, column: 6)
check(strippedDisplayFormula?.hasPrefix("\\[") == true && strippedDisplayFormula?.hasSuffix("\\]") == true,
      "Markdown-stripped display delimiters retain their original grid range")
for body in ["i", "x_i", "x^2", "W^Q_l", "W_{Q,video}", #"c_{\mathrm{ref}}"#,
             #"10.6^\circ"#, "x+y", #"\frac{a}{b}"#] {
    let source = "value: (" + body + ")"
    let matrixGrid = GhosttyGrid(text: source, columns: 80)
    check(hit(matrixGrid, row: 0, column: 8 + body.count / 2) == "\\(" + body + "\\)",
          "stripped inline matrix: \(body)")
}
for body in ["W_{Q,video}", #"c_{\mathrm{ref}}"#, "T^{-1}", #"\frac{a}{b}"#] {
    let source = "(" + body + ")"
    let braces = source.enumerated().filter { "{}".contains($0.element) }.map(\.offset)
    let braceGrid = GhosttyGrid(text: source, columns: 80)
    for column in braces {
        check(hit(braceGrid, row: 0, column: column) == "\\(" + body + "\\)",
              "brace cell maps to complete formula: \(body) column \(column)")
    }
}
for body in ["x_i = y^2", #"\frac{a}{b}"#, #"h_i' = h_i+\n\operatorname{Attention}(z)_i"#] {
    let source = "› [\n" + body + "\n]"
    let rows = source.components(separatedBy: "\n").count
    let matrixGrid = GhosttyGrid(text: source, columns: 80)
    check(hit(matrixGrid, row: 1, column: max(1, body.components(separatedBy: "\n")[0].count / 2), rows: rows, total: rows)?.hasPrefix("\\[") == true,
          "stripped display matrix: \(body)")
}
check(hit(grid, row: 2, column: 12) == nil, "blank line does not borrow formula")
check(hit(grid, row: 23, column: 12) == nil, "omitted blank tail")
check(hit(grid, row: 3, column: 12, padding: CGSize(width: 2, height: 2)) == boxed, "small unknown padding agrees on formula")
check(hit(grid, row: 3, column: 12, padding: CGSize(width: 0, height: 17)) == nil, "different possible rows are rejected")
let paths = #""$HOME/Applications/Ghostty.app" "$HOME/Applications/cmux.app""#
let pathGrid = GhosttyGrid(text: paths + "\n" + boxed, columns: 80)
for column in paths.indices { check(hit(pathGrid, row: 0, column: paths.distance(from: paths.startIndex, to: column)) == nil, "path cell") }
check(hit(pathGrid, row: 1, column: 4) == boxed, "formula after paths")
let cjk = GhosttyGrid(text: "\u{4e2d}\u{6587}: " + boxed, columns: 80)
check(hit(cjk, row: 0, column: 8) == boxed, "known CJK width before formula")
let wideWrap = GhosttyGrid(text: String(repeating: "a", count: 79) + "\u{4e2d}" + "$x$", columns: 80)
check(hit(wideWrap, row: 1, column: 3) == "$x$", "wide glyph moves off final column")
check(hit(wideWrap, row: 0, column: 79) == nil, "wide spacer has no source")
let unknownShort = GhosttyGrid(text: "\u{1f600} prompt\n" + boxed, columns: 80)
check(hit(unknownShort, row: 1, column: 5) == boxed, "short emoji context retains row count")
check(hit(unknownShort, row: 0, column: 1) == nil, "unknown glyph line has no inferred hit columns")
let unknownWrap = GhosttyGrid(text: String(repeating: "a", count: 90) + "\u{2019} tail\n" + boxed, columns: 80)
check(hit(unknownWrap, row: 2, column: 6) == boxed, "all possible unknown widths agree on row count")
check(GhosttyGrid(text: String(repeating: "a", count: 79) + "\u{2019}\n" + boxed, columns: 80) == nil, "ambiguous wrap count rejected")
let ambiguous = "HEADER\n" + String(repeating: "A", count: 20) + "\n" + String(repeating: " ", count: 60) + boxed + "\nEND"
check(GhosttyGrid(text: ambiguous, columns: 80) == nil, "known erased-wrap false hit is rejected conservatively")
let wrapped = GhosttyGrid(text: String(repeating: "a", count: 95) + " " + boxed, columns: 80)
check(hit(wrapped, row: 1, column: 20) == boxed, "ordinary soft-wrapped boxed formula")
let history = GhosttyGrid(text: (0..<160).map { "history \($0)" }.joined(separator: "\n") + "\n" + source, columns: 80)
check(hit(history, row: 19, column: 10, total: 166, scroll: 1) == #"$e^{i\pi}+1=0$"#, "history scroll offset")
check(hit(history, row: 19, column: 10, total: 166, scroll: 0.5001) == nil, "fractional scroll offset")
check(GhosttyGrid(text: "$x$\u{1b}[8m", columns: 80) == nil, "raw controls rejected")
check(GhosttyGrid(text: String(repeating: "x", count: 524_289), columns: 80) == nil, "text bound")
check(GhosttyGrid(text: "x", columns: Int.max) == nil, "dimension bound")

for value in ["\u{1b}[6;37;17t", "\u{1b}[6;20;10t"] {
    check(GhosttyConnectCommand.parseCellReport(Array(value.utf8)) != nil, "cell reply parsed")
}
for value in ["", "37;17", "\u{1b}[4;37;17t", "\u{1b}[6;0;17t", "\u{1b}[6;-37;17t", "\u{1b}[6;37;17;1t", "x\u{1b}[6;37;17t", "\u{1b}[6;37;17tx"] {
    check(GhosttyConnectCommand.parseCellReport(Array(value.utf8)) == nil, "malformed cell reply rejected")
}
check(TerminalProcess.read(getpid())?.isAlive() == true, "process start identity")
check(TerminalProcess.read(-1) == nil, "invalid process rejected")
check(TerminalProcess.ghosttyAncestor(of: getpid()) == nil, "test process does not manufacture a Ghostty ancestor")

let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("math-peek-ghostty-tests-" + UUID().uuidString)
let directory = root.appendingPathComponent("requests")
try manager.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
defer { try? manager.removeItem(at: root) }
let process = TerminalProcess.read(getpid())!
let request = GhosttyConnectionRequest(client: process, ghostty: process, ttyPath: "/dev/ttys999",
    ttyDevice: 0, session: getpid(), dimensions: TerminalDimensions(columns: 80, rows: 24, widthPixels: 1360, heightPixels: 888),
    cellWidthPixels: 17, cellHeightPixels: 37)
rejects("unrelated process cannot pair") { try request.validate() }
let name = try GhosttyConnectionFiles.writeRequest(request, in: directory)
check(GhosttyConnectionFiles.validName(name), "private request name")
let consumed = try GhosttyConnectionFiles.consumeRequest(name, in: directory)
check(consumed.nonce == request.nonce, "request round trip")
rejects("one-shot request") { _ = try GhosttyConnectionFiles.consumeRequest(name, in: directory) }
try GhosttyConnectionFiles.writeReply(GhosttyConnectionReply(connected: true, message: "paired"), for: name, in: directory)
rejects("reply cannot overwrite existing message") { try GhosttyConnectionFiles.writeReply(GhosttyConnectionReply(connected: false, message: "wrong"), for: name, in: directory) }
let reply = try GhosttyConnectionFiles.consumeReply(for: name, in: directory)
let replayedReply = try GhosttyConnectionFiles.consumeReply(for: name, in: directory)
check(reply?.connected == true, "reply round trip")
check(replayedReply == nil, "reply consumed once")
for invalid in ["../" + name, name + "/x", "ghostty-invalid.json", "cmux-ABCDEF.json"] {
    check(!GhosttyConnectionFiles.validName(invalid), "invalid file name")
    rejects("invalid file access") { _ = try GhosttyConnectionFiles.consumeRequest(invalid, in: directory) }
}
let file = directory.appendingPathComponent(name)
try Data("private".utf8).write(to: root.appendingPathComponent("other"))
try manager.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("other"))
rejects("request symlink") { _ = try GhosttyConnectionFiles.consumeRequest(name, in: directory) }
try manager.removeItem(at: file)
for (mode, contents) in [(0o644, Data("{}".utf8)), (0o600, Data(repeating: 65, count: 8193))] {
    try contents.write(to: file)
    try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    rejects("file permissions and size checked") { _ = try GhosttyConnectionFiles.consumeRequest(name, in: directory) }
    try manager.removeItem(at: file)
}
try Data("{}".utf8).write(to: file)
try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
rejects("malformed request consumed") { _ = try GhosttyConnectionFiles.consumeRequest(name, in: directory) }
check(!manager.fileExists(atPath: file.path), "malformed one-shot file removed")
print("Ghostty adapter: \(passed) passed, \(failed) failed")
if failed > 0 { exit(1) }

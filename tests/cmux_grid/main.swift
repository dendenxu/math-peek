import Foundation
import CoreGraphics

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { passed += 1; print("PASS \(name)") }
    else { failed += 1; print("FAIL \(name)") }
}

let surfaceID = "7FFBECA9-535E-4335-B30C-E314A1AD80A7"
func span(_ text: String, row: Int = 0, column: Int = 0, width: Int? = nil) -> [String: Any] {
    var value: [String: Any] = ["row": row, "column": column, "style_id": 0, "text": text]
    if let width { value["cell_width"] = width }
    return value
}
func reply(_ spans: [[String: Any]], columns: Int = 80, rows: Int = 2) -> [String: Any] {
    ["surface_id": surfaceID, "workspace_id": "7EC1733F-C02D-49F6-B56D-769270C427DE",
     "seq": 7, "columns": columns, "rows": rows,
     "render_grid": ["format": "cmux.render-grid.v1", "surface_id": surfaceID,
                     "state_seq": 7, "render_epoch": "epoch-1", "render_revision": 12,
                     "columns": columns, "rows": rows, "full": true, "anchor": "viewport",
                     "cleared_rows": [], "active_screen": "primary", "styles": [["id": 0]],
                     "row_spans": spans]]
}
func decode(_ value: [String: Any], columns: Int = 80, rows: Int = 2) -> CmuxGrid? {
    // Exercise the NSNumber representations a socket JSON response produces.
    guard let data = try? JSONSerialization.data(withJSONObject: value),
          let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return CmuxGrid.decode(result: decoded, expectedSurfaceID: surfaceID,
                           expectedColumns: columns, expectedRows: rows)
}
func alteredFrame(_ value: [String: Any], _ key: String, _ replacement: Any) -> [String: Any] {
    var value = value
    var frame = value["render_grid"] as! [String: Any]
    frame[key] = replacement
    value["render_grid"] = frame
    return value
}
let cell = CGSize(width: 10, height: 20)
let area = CGRect(x: 100, y: 200, width: 800, height: 40)
func point(_ column: CGFloat, _ row: CGFloat = 0) -> CGPoint {
    CGPoint(x: 100 + (column + 0.5) * 10, y: 200 + (row + 0.5) * 20)
}

let boxed = #"\boxed{K = \frac{P}{P+R}}"#
let base = reply([span("answer: " + boxed, width: 8 + boxed.count)])
let grid = decode(base)!
check(grid.sameViewport(as: decode(alteredFrame(base, "render_revision", 13))!),
      "capture revision can advance without changing viewport")
check(!grid.sameViewport(as: decode(alteredFrame(base, "render_epoch", "epoch-2"))!),
      "producer restart invalidates otherwise identical viewport")
check(!grid.sameViewport(as: decode(reply([span("answer: " + boxed, row: 1, width: 8 + boxed.count)]))!),
      "scrolling identical text to another row invalidates viewport")
check(!grid.sameViewport(as: decode(reply([span("answer: " + boxed.replacingOccurrences(of: "K", with: "Q"),
                                                  width: 8 + boxed.count)]))!),
      "same-sized output changes invalidate viewport")
check(grid.hit(at: point(14), in: area, cellSize: cell)?.formula == boxed,
      "bare boxed formula inside prose is retained in full")
check(grid.hit(at: point(2), in: area, cellSize: cell) == nil, "prose is not formula")
check(grid.hit(at: point(65), in: area, cellSize: cell) == nil, "unused cells are not formula")
check(grid.hit(at: point(14, 1), in: area, cellSize: cell) == nil, "empty viewport row is not formula")
check(grid.hit(at: point(14), in: area, cellSize: cell,
               expectedGeneration: grid.generation) != nil, "matching viewport generation")
for generation in [CmuxGrid.Generation(surfaceID: surfaceID, epoch: "epoch-2", revision: 12),
                   CmuxGrid.Generation(surfaceID: surfaceID, epoch: "epoch-1", revision: 13),
                   CmuxGrid.Generation(surfaceID: UUID().uuidString, epoch: "epoch-1", revision: 12)] {
    check(grid.hit(at: point(14), in: area, cellSize: cell, expectedGeneration: generation) == nil,
          "stale epoch, revision, or surface is rejected")
}

let padded = CGRect(x: 100, y: 200, width: 806, height: 46)
check(grid.hit(at: point(14), in: padded, cellSize: cell)?.formula == boxed,
      "formula interior is safe for every possible padding placement")
check(grid.hit(at: point(7.9), in: padded, cellSize: cell) == nil,
      "uncertain boundary shared with prose is rejected")
check(grid.hit(at: CGPoint(x: 103, y: 210), in: padded, cellSize: cell) == nil,
      "possible left padding is rejected")
check(grid.hit(at: CGPoint(x: 245, y: 203), in: padded, cellSize: cell) == nil,
      "possible top padding is rejected")
check(grid.hit(at: point(14), in: CGRect(x: 100, y: 200, width: 806, height: 60), cellSize: cell) == nil,
      "large vertical slack cannot silently choose one row")
check(grid.hit(at: point(14), in: CGRect(x: 100, y: 200, width: 799, height: 40), cellSize: cell) == nil,
      "clipped renderer is rejected")
check(grid.hit(at: point(14), in: area, cellSize: CGSize(width: 0, height: 20)) == nil,
      "zero cell size is rejected")
check(grid.hit(at: CGPoint(x: CGFloat.nan, y: 210), in: area, cellSize: cell) == nil,
      "nonfinite pointer cannot convert to integer")
check(grid.hit(at: point(14), in: CGRect(x: 100, y: 200, width: CGFloat.infinity, height: 40), cellSize: cell) == nil,
      "nonfinite geometry is rejected")
check(grid.hit(at: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 210), in: area, cellSize: cell) == nil,
      "overflowing coordinate is rejected")

let repeated = #"\(x\)\(x\)"#
let repeatedGrid = decode(reply([span(repeated, width: repeated.count)]))!
let first = repeatedGrid.hit(at: point(2), in: area, cellSize: cell)
let second = repeatedGrid.hit(at: point(7), in: area, cellSize: cell)
check(first?.formula == second?.formula && first?.scalarRange != second?.scalarRange,
      "identical formulas retain distinct source identities")
check(repeatedGrid.hit(at: point(5), in: CGRect(x: 100, y: 200, width: 820, height: 40), cellSize: cell) == nil,
      "padding uncertainty spanning two identical formulas is rejected")

let paths = #""$HOME/Applications/Ghostty.app" "$HOME/Applications/cmux.app""#
let pathGrid = decode(reply([span(paths, width: paths.count)]))!
check(pathGrid.hit(at: point(16), in: area, cellSize: cell) == nil, "quoted HOME paths remain non-math")

let unicode = "\u{1F600} " + boxed
let unicodeGrid = decode(reply([span(unicode, width: 3 + boxed.count)]))!
check(unicodeGrid.hit(at: point(10), in: area, cellSize: cell)?.formula == boxed,
      "single wide grapheme before formula uses authoritative total width")
let combining = "e\u{301} " + boxed
let combiningGrid = decode(reply([span(combining, width: 2 + boxed.count)]))!
check(combiningGrid.hit(at: point(8), in: area, cellSize: cell)?.formula == boxed,
      "combining character keeps scalar offsets separate from grid columns")
let wideMath = "$x+\u{1F600}$"
let wideMathGrid = decode(reply([span(wideMath, width: 6)]))!
check(wideMathGrid.hit(at: point(3), in: area, cellSize: cell)?.formula == wideMath &&
      wideMathGrid.hit(at: point(4), in: area, cellSize: cell)?.formula == wideMath,
      "both cells of one wide grapheme map to the complete formula")
let unknowns = "\u{4E2D}\u{6587} " + boxed
let unknownGrid = decode(reply([span(unknowns, width: 5 + boxed.count)]))!
check(unknownGrid.hit(at: point(13), in: area, cellSize: cell)?.formula == boxed,
      "ASCII suffix is located from a span's authoritative end")
check(unknownGrid.hit(at: point(1), in: area, cellSize: cell) == nil,
      "ambiguous Unicode widths are not guessed")
let ambiguousMath = "$\u{03B1}+\u{03B2}$"
let ambiguousGrid = decode(reply([span(ambiguousMath, width: 7)]))!
check(ambiguousGrid.hit(at: point(2), in: area, cellSize: cell) == nil,
      "span total cannot determine individual ambiguous character widths")
check(decode(reply([span(unicode)])) == nil, "missing width for Unicode span is rejected")
check(decode(reply([span("abc", width: 4)])) == nil, "mismatched ASCII width is rejected")
check(decode(reply([span("a\tb", width: 3)])) == nil, "tab control cannot invent grid geometry")
check(decode(reply([span("a\nb", width: 3)])) == nil, "embedded newline cannot invent rows")
check(decode(reply([span("\u{301}", width: 1)])) == nil, "orphan combining mark is rejected")

let styled = decode(reply([span("$x", column: 2, width: 2), span("+y$", column: 4, width: 3)]))!
check(styled.hit(at: point(5), in: area, cellSize: cell)?.formula == "$x+y$",
      "style changes do not split a formula")
let blankGap = decode(reply([span("$x", column: 2, width: 2), span("+y$", column: 5, width: 3)]))!
check(blankGap.hit(at: point(4), in: area, cellSize: cell)?.formula == "$x +y$",
      "omitted blank cell inside delimiters remains a space")
check(decode(reply([span("$x$", width: 3), span("bad", column: 1, width: 3)])) == nil,
      "overlapping spans are rejected")
check(decode(reply([span("x", column: 80, width: 1)])) == nil, "out-of-grid column is rejected")
check(decode(reply([span("x", row: 2, width: 1)])) == nil, "out-of-grid row is rejected")
check(decode(reply([span("x", column: 79, width: Int.max)])) == nil,
      "overflowing span width is rejected before addition")

let hiddenGrid = decode(alteredFrame(base, "styles", [["id": 0, "invisible": true]]))!
check(!grid.sameViewport(as: hiddenGrid), "concealment changes invalidate viewport")
check(hiddenGrid.hit(at: point(14), in: area, cellSize: cell) == nil,
      "concealed terminal text cannot produce a visible preview")
var hiddenPart = span("secret", column: 3, width: 6)
hiddenPart["style_id"] = 1
let partiallyHidden = decode(alteredFrame(reply([span("$a+", width: 3), hiddenPart,
                                                 span("$", column: 9, width: 1),
                                                 span("$x$", row: 1, width: 3)]),
                                        "styles", [["id": 0], ["id": 1, "invisible": true]]))!
check(partiallyHidden.hit(at: point(1), in: area, cellSize: cell) == nil,
      "formula spanning a concealed style is rejected even on its visible part")
check(partiallyHidden.hit(at: point(1, 1), in: area, cellSize: cell)?.formula == "$x$",
      "concealment does not suppress unrelated visible formulas")
check(decode(alteredFrame(base, "styles", [["id": 1]])) == nil,
      "unknown style reference is rejected")
check(decode(alteredFrame(base, "styles", [["id": 0, "invisible": 1]])) == nil,
      "non-Boolean concealment flag is rejected")

let spacedReply = reply([span("answer: " + boxed, row: 1, width: 8 + boxed.count)], rows: 3)
let spacedGrid = decode(spacedReply, rows: 3)!
let spacedArea = CGRect(x: 100, y: 200, width: 806, height: 75)
check(spacedGrid.hit(at: point(14, 1), in: spacedArea, cellSize: cell) == nil,
      "exact mode does not silently expand a formula into adjacent blank lines")
check(spacedGrid.hit(at: point(14, 1), in: spacedArea, cellSize: cell,
                     allowBlankAdjacentRows: true)?.formula == boxed,
      "explicit target expansion makes line center usable with large sub-row padding")
check(spacedGrid.hit(at: point(7.9, 1), in: spacedArea, cellSize: cell,
                     allowBlankAdjacentRows: true) == nil,
      "blank-row expansion does not loosen horizontal prose boundaries")
check(spacedGrid.hit(at: point(14, 1), in: CGRect(x: 100, y: 200, width: 806, height: 80), cellSize: cell,
                     allowBlankAdjacentRows: true) == nil,
      "blank-row expansion refuses padding of an entire row or more")
let empty = decode(reply([], rows: 3), rows: 3)!
check(empty.hit(at: point(14, 1), in: spacedArea, cellSize: cell,
               allowBlankAdjacentRows: true) == nil,
      "expanded hover still requires an actual formula row")
for otherRow in [span("code", row: 0, width: 4), span(paths, row: 0, width: paths.count),
                 span("$x$", row: 0, column: 50, width: 3),
                 span("answer: " + boxed, row: 0, width: 8 + boxed.count)] {
    let neighbor = decode(reply([otherRow, span("answer: " + boxed, row: 1, width: 8 + boxed.count)], rows: 3), rows: 3)!
    check(neighbor.hit(at: point(14, 1), in: spacedArea, cellSize: cell,
                       allowBlankAdjacentRows: true) == nil,
          "expanded hover cannot cross a nonblank code, path, or formula row")
}
var hiddenBlank = span(" ", row: 0, width: 1)
hiddenBlank["style_id"] = 1
let hiddenNeighbor = decode(alteredFrame(reply([hiddenBlank,
                                                span("answer: " + boxed, row: 1, width: 8 + boxed.count)], rows: 3),
                                       "styles", [["id": 0], ["id": 1, "invisible": true]]), rows: 3)!
check(hiddenNeighbor.hit(at: point(14, 1), in: spacedArea, cellSize: cell,
                         allowBlankAdjacentRows: true) == nil,
      "concealed neighboring row is never treated as empty")

for (key, value) in [("format", "unknown" as Any), ("anchor", "screen" as Any),
                     ("full", false as Any), ("full", 1 as Any),
                     ("render_epoch", "" as Any), ("render_revision", 0 as Any),
                     ("render_revision", true as Any), ("cleared_rows", [0] as Any),
                     ("columns", 81 as Any), ("columns", true as Any),
                     ("surface_id", UUID().uuidString as Any)] {
    check(decode(alteredFrame(base, key, value)) == nil, "invalid snapshot field \(key) is rejected")
}
var wrongOuter = base
wrongOuter["surface_id"] = UUID().uuidString
check(decode(wrongOuter) == nil, "outer response surface must match requested surface")
wrongOuter = base
wrongOuter["rows"] = 3
check(decode(wrongOuter) == nil, "outer response dimensions must match grid")
check(decode(base, columns: 81) == nil, "geometry dimensions must match snapshot")
check(decode(reply([], columns: Int.max, rows: Int.max), columns: Int.max, rows: Int.max) == nil,
      "huge dimensions are rejected without multiplying")
check(decode(reply([span(String(repeating: "x", count: 262_145), width: 1)])) == nil,
      "oversized payload is rejected")

// Exhaust a set of actual padding placements: every accepted point must hit
// the same formula even when all available slack is placed on either side.
var disagreement = false
var accepted = 0
for dx in 0..<360 {
    for dy in 0..<26 {
        let p = CGPoint(x: 100 + Double(dx) + 0.25, y: 200 + Double(dy) + 0.25)
        guard let hit = grid.hit(at: p, in: padded, cellSize: cell) else { continue }
        accepted += 1
        for left in stride(from: CGFloat(0), through: 6, by: 0.5) {
            for top in stride(from: CGFloat(0), through: 6, by: 0.5) {
                let moved = CGPoint(x: p.x - left, y: p.y - top)
                let actualColumn = Int(floor((moved.x - area.minX) / cell.width))
                let actualRow = Int(floor((moved.y - area.minY) / cell.height))
                if actualRow != 0 || !(8..<(8 + boxed.count)).contains(actualColumn) || hit.formula != boxed {
                    disagreement = true
                }
            }
        }
    }
}
check(accepted > 0 && !disagreement, "accepted region is sound over actual asymmetric padding placements")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)

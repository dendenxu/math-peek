import Foundation
import CoreGraphics

// Research only: append-only ASCII fixtures with independently known zero padding.
// AX text does not expose erased wrap cells, styles, or a rendered-frame generation.
// The append-only contract cannot be established from these inputs on arbitrary terminals.
struct GhosttyASCIIGeometry {
    let text: String
    let columns: Int
    let viewportRows: Int
    let cellSize: CGSize
    let viewport: CGRect
    let totalRows: Int
    let viewportOffset: Int
    let sourceRows: [Range<Int>]

    var inferredBlankRows: Int { totalRows - sourceRows.count }

    init?(text: String, columns: Int, viewportRows: Int, cellSize: CGSize,
          viewport: CGRect, documentHeight: CGFloat, scrollbarValue: Double) {
        let maximumRows = 100_000
        guard columns > 0, columns <= 4096, viewportRows > 0, viewportRows <= 4096,
              text.utf8.count <= 2 * 1024 * 1024,
              [cellSize.width, cellSize.height, viewport.origin.x, viewport.origin.y,
               viewport.size.width, viewport.size.height, documentHeight].allSatisfy({ $0.isFinite }),
              cellSize.width > 0, cellSize.height > 0,
              viewport.size.width > 0, viewport.size.height > 0,
              viewport.maxX.isFinite, viewport.maxY.isFinite,
              abs(viewport.width - CGFloat(columns) * cellSize.width) <= 0.000_001,
              abs(viewport.height - CGFloat(viewportRows) * cellSize.height) <= 0.000_001,
              documentHeight >= viewport.height,
              scrollbarValue.isFinite, (0...1).contains(scrollbarValue) else { return nil }

        let history = Double((documentHeight - viewport.height) / cellSize.height)
        guard history.isFinite, history >= 0, history <= Double(maximumRows - viewportRows),
              abs(history - history.rounded()) <= 0.000_001 else { return nil }
        let historyRows = Int(history.rounded())
        let totalRows = viewportRows + historyRows
        let offset = scrollbarValue * Double(historyRows)
        // A fractional thumb position during live scrolling has no exact terminal row.
        guard abs(offset - offset.rounded()) <= 0.000_001 else { return nil }

        let bytes = Array(text.utf8)
        guard bytes.allSatisfy({ $0 == 10 || (32...126).contains($0) }) else { return nil }
        var sourceRows: [Range<Int>] = []
        var start = 0
        for end in 0...bytes.count where end == bytes.count || bytes[end] == 10 {
            let count = end - start
            // Exactly filling a terminal row leaves wrap pending; it adds no extra row.
            let rowCount = max(1, (count + columns - 1) / columns)
            guard rowCount <= totalRows - sourceRows.count else { return nil }
            for row in 0..<rowCount {
                let lower = start + row * columns
                sourceRows.append(lower..<min(lower + columns, end))
            }
            start = end + 1
        }
        // Under the fixture contract AX may omit a blank viewport tail. Do not use
        // omitted history as an explanation for arbitrarily inconsistent row counts.
        guard totalRows - sourceRows.count <= viewportRows else { return nil }

        self.text = text
        self.columns = columns
        self.viewportRows = viewportRows
        self.cellSize = cellSize
        self.viewport = viewport
        self.totalRows = totalRows
        self.viewportOffset = Int(offset.rounded())
        self.sourceRows = sourceRows
    }

    func sourceOffset(at point: CGPoint) -> Int? {
        guard point.x.isFinite, point.y.isFinite,
              point.x >= viewport.minX, point.x < viewport.maxX,
              point.y >= viewport.minY, point.y < viewport.maxY else { return nil }
        let column = Int(floor((point.x - viewport.minX) / cellSize.width))
        let row = Int(floor((point.y - viewport.minY) / cellSize.height))
        guard column >= 0, column < columns, row >= 0, row < viewportRows else { return nil }
        let physicalRow = viewportOffset + row
        guard physicalRow < sourceRows.count else { return nil }
        let range = sourceRows[physicalRow]
        guard column < range.count else { return nil }
        return range.lowerBound + column
    }

    func formula(at point: CGPoint) -> String? {
        guard let offset = sourceOffset(at: point) else { return nil }
        // Printable ASCII byte offsets are also HoverMath's Unicode scalar offsets.
        return HoverMath.extract(text: text, offset: offset)
    }
}

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { passed += 1; print("PASS \(name)") }
    else { failed += 1; print("FAIL \(name)") }
}

func fixture(_ text: String, columns: Int = 16, rows: Int = 4,
             totalRows: Int? = nil, scroll: Double = 1) -> GhosttyASCIIGeometry? {
    GhosttyASCIIGeometry(text: text, columns: columns, viewportRows: rows,
                        cellSize: CGSize(width: 8, height: 16),
                        viewport: CGRect(x: -120, y: 40, width: columns * 8, height: rows * 16),
                        documentHeight: CGFloat((totalRows ?? rows) * 16), scrollbarValue: scroll)
}

func point(_ model: GhosttyASCIIGeometry, row: Int, column: Int) -> CGPoint {
    CGPoint(x: model.viewport.minX + (CGFloat(column) + 0.5) * model.cellSize.width,
            y: model.viewport.minY + (CGFloat(row) + 0.5) * model.cellSize.height)
}

let short = fixture("$x^2$")!
check(short.totalRows == 4 && short.viewportOffset == 0, "short output has no scrollback offset")
check(short.formula(at: point(short, row: 0, column: 2)) == "$x^2$", "short formula resolves through HoverMath")
check(short.sourceOffset(at: point(short, row: 0, column: 2)) == 2, "source offset uses original text")
check(short.inferredBlankRows == 3, "omitted blank viewport tail is retained as blank cells")
check(short.sourceOffset(at: point(short, row: 0, column: 8)) == nil, "unused part of a short line has no source character")
check(short.formula(at: point(short, row: 3, column: 2)) == nil, "inferred blank tail cannot trigger a formula")
check(short.sourceOffset(at: CGPoint(x: short.viewport.minX, y: short.viewport.minY)) == 0,
      "top-left cell boundary is included")
check(short.sourceOffset(at: CGPoint(x: short.viewport.maxX, y: short.viewport.minY)) == nil,
      "right edge belongs outside the viewport")
check(short.sourceOffset(at: CGPoint(x: short.viewport.minX, y: short.viewport.maxY)) == nil,
      "bottom edge belongs outside the viewport")
check(short.sourceOffset(at: CGPoint(x: short.viewport.minX - 0.1, y: short.viewport.minY)) == nil,
      "negative local coordinates do not clamp to first column")
check(short.sourceOffset(at: CGPoint(x: CGFloat.nan, y: short.viewport.minY)) == nil,
      "nonfinite pointer is rejected")

let empty = fixture("")!
check(empty.sourceRows.count == 1 && empty.inferredBlankRows == 3, "empty text occupies one blank logical row")
check(empty.formula(at: point(empty, row: 0, column: 0)) == nil, "empty text has no hover source")
let blanks = fixture("\n\n$x$\n\n", columns: 8, rows: 6)!
check(blanks.sourceRows.count == 5 && blanks.inferredBlankRows == 1, "leading interior and trailing empty lines are preserved")
check(blanks.formula(at: point(blanks, row: 2, column: 1)) == "$x$", "blank lines retain the formula's physical row")
check(blanks.sourceOffset(at: point(blanks, row: 1, column: 0)) == nil, "newline does not occupy a terminal cell")
let spaces = fixture("  $x$  ")!
check(spaces.sourceOffset(at: point(spaces, row: 0, column: 6)) == 6, "explicit ASCII spaces retain their cell offsets")
check(spaces.formula(at: point(spaces, row: 0, column: 6)) == nil, "space after formula does not borrow formula hit")

let exact = fixture("12345678\n$x$", columns: 8, rows: 3)!
check(exact.sourceRows.count == 2, "exact-width line followed by newline does not double-wrap")
check(exact.formula(at: point(exact, row: 1, column: 1)) == "$x$", "formula immediately follows exact-width hard line")
let pending = fixture("12345678", columns: 8, rows: 1)!
check(pending.sourceRows.count == 1 && pending.sourceOffset(at: point(pending, row: 0, column: 7)) == 7,
      "last column at end of text leaves wrap pending")
let exactNewline = fixture("12345678\n", columns: 8, rows: 2)!
check(exactNewline.sourceRows.count == 2 && exactNewline.sourceRows.last?.isEmpty == true,
      "explicit newline after full row creates exactly one blank next row")
let multiple = fixture("1234567812345678\n$x$", columns: 8, rows: 3)!
check(multiple.formula(at: point(multiple, row: 2, column: 1)) == "$x$", "multiple exact-width wraps add no phantom row")
let over = fixture("123456789\n$x$", columns: 8, rows: 4)!
check(over.sourceOffset(at: point(over, row: 1, column: 0)) == 8, "one character past width starts a real wrapped row")
check(over.formula(at: point(over, row: 2, column: 1)) == "$x$", "hard newline follows the final wrapped row")

let boxed = #"\boxed{K = \frac{P}{P+R}}"#
let wrappedText = String(repeating: "A", count: 14) + " " + boxed
let wrapped = fixture(wrappedText, columns: 16, rows: 4)!
let fractionOffset = (wrappedText as NSString).range(of: "frac").location
check(wrapped.formula(at: point(wrapped, row: fractionOffset / 16, column: fractionOffset % 16)) == boxed,
      "wrapped bare boxed formula uses original unwrapped source")
check(wrapped.formula(at: point(wrapped, row: 0, column: 3)) == nil,
      "prose before wrapped boxed formula is not a formula hit")
let displayed = fixture("$$\\frac{1}{2}+x$$", columns: 8, rows: 3)!
check(displayed.formula(at: point(displayed, row: 1, column: 2)) == #"$$\frac{1}{2}+x$$"#,
      "delimited formula survives a soft wrap through its command")

let pathsText = #""$HOME/Applications/Ghostty.app" "$HOME/Applications/cmux.app""#
let paths = fixture(pathsText + "\n" + boxed, columns: 80, rows: 3)!
check(pathsText.indices.allSatisfy { index in
    let column = pathsText.distance(from: pathsText.startIndex, to: index)
    return paths.formula(at: point(paths, row: 0, column: column)) == nil
}, "quoted HOME app paths are rejected at every source cell")
check(paths.formula(at: point(paths, row: 1, column: 12)) == boxed,
      "valid bare formula next to path output still triggers")

var historyLines = (0..<12).map { String(format: "line%02d", $0) }
historyLines[5] = "$a+b$"
historyLines[10] = "$c+d$"
let historyText = historyLines.joined(separator: "\n")
let bottom = fixture(historyText, columns: 12, rows: 4, totalRows: 12)!
check(bottom.viewportOffset == 8 && bottom.inferredBlankRows == 0, "bottom scrollbar aligns the last viewport rows")
check(bottom.formula(at: point(bottom, row: 2, column: 2)) == "$c+d$", "history formula maps to its visible bottom row")
let middle = fixture(historyText, columns: 12, rows: 4, totalRows: 12, scroll: 0.5)!
check(middle.viewportOffset == 4, "midway thumb maps to an integer physical row")
check(middle.formula(at: point(middle, row: 1, column: 2)) == "$a+b$", "scrolling midway resolves a different source formula")
let top = fixture(historyText, columns: 12, rows: 4, totalRows: 12, scroll: 0)!
check(top.viewportOffset == 0 && top.formula(at: point(top, row: 1, column: 2)) == nil,
      "top viewport cannot borrow a formula from hidden history")
let historyTail = fixture(historyText, columns: 12, rows: 4, totalRows: 14)!
check(historyTail.viewportOffset == 10 && historyTail.inferredBlankRows == 2,
      "document height accounts for omitted blank rows below historical text")
check(historyTail.formula(at: point(historyTail, row: 0, column: 2)) == "$c+d$" &&
      historyTail.formula(at: point(historyTail, row: 3, column: 2)) == nil,
      "history tail blanks do not shift the final formula down")

let measuredText = (0..<167).map { String(format: "row%03d", $0) }.joined(separator: "\n")
let measured = GhosttyASCIIGeometry(text: measuredText, columns: 80, viewportRows: 24,
    cellSize: CGSize(width: 8.5, height: 18.5), viewport: CGRect(x: 20, y: 30, width: 680, height: 444),
    documentHeight: 3089.5, scrollbarValue: 1)!
check(measured.totalRows == 167 && measured.viewportOffset == 143,
      "measured half-point Ghostty geometry recovers 167 total and 143 history rows")
check(measured.sourceOffset(at: point(measured, row: 0, column: 3)) == measured.sourceRows[143].lowerBound + 3,
      "fractional point cell dimensions retain exact ASCII offsets")

func measuredInput(text: String = "$x$", columns: Int = 8, rows: Int = 4,
                   cell: CGSize = CGSize(width: 8, height: 16),
                   viewport: CGRect = CGRect(x: 0, y: 0, width: 64, height: 64),
                   documentHeight: CGFloat = 64, scroll: Double = 1) -> GhosttyASCIIGeometry? {
    GhosttyASCIIGeometry(text: text, columns: columns, viewportRows: rows, cellSize: cell,
                        viewport: viewport, documentHeight: documentHeight, scrollbarValue: scroll)
}

check(fixture(historyText, columns: 12, rows: 4, totalRows: 12, scroll: 0.51) == nil,
      "fractional row offset is rejected rather than rounded to neighboring formula")
check(measuredInput(documentHeight: 64.5) == nil, "fractional document row count is inconsistent")
check(measuredInput(documentHeight: 63) == nil, "document shorter than viewport is rejected")
check(measuredInput(columns: 7) == nil, "column count must match independently known zero-padding width")
check(measuredInput(rows: 3) == nil, "row count must match independently known zero-padding height")
check(measuredInput(viewport: CGRect(x: 0, y: 0, width: 65, height: 64)) == nil,
      "nonzero or unexplained padding is outside the fixture model")
check(fixture("1\n2\n3\n4\n5", rows: 4) == nil, "text with more physical rows than document is rejected")
check(fixture("123456789", columns: 8, rows: 1) == nil, "wrapped text cannot overflow declared physical rows")
check(fixture("$x$", rows: 4, totalRows: 6) == nil,
      "missing rows exceeding a viewport are not silently invented as blank history")
for value in [-0.01, 1.01, Double.nan, Double.infinity] {
    check(measuredInput(scroll: value) == nil, "invalid normalized scrollbar is rejected: \(value)")
}
for text in ["\u{4E2D}$x$", "\u{1F600}$x$", "e\u{301}$x$", "\t$x$", "\r$x$", "\u{1B}[8m$x$", "\0$x$"] {
    check(measuredInput(text: text) == nil, "non-ASCII or control text is not assigned guessed widths: \(text.debugDescription)")
}
check(measuredInput(columns: 0) == nil && measuredInput(rows: 0) == nil, "empty dimensions are rejected")
check(measuredInput(columns: Int.max) == nil && measuredInput(rows: Int.max) == nil,
      "extreme dimensions are rejected before arithmetic")
check(measuredInput(cell: CGSize(width: 0, height: 16)) == nil, "zero cell width is rejected")
check(measuredInput(cell: CGSize(width: 8, height: CGFloat.infinity)) == nil, "infinite cell height is rejected")
check(measuredInput(documentHeight: CGFloat.nan) == nil, "nonfinite document height is rejected")
check(measuredInput(viewport: CGRect(x: CGFloat.infinity, y: 0, width: 64, height: 64)) == nil,
      "nonfinite viewport origin is rejected")
check(measuredInput(documentHeight: 16 * 100_001) == nil, "history reconstruction has a fixed row limit")
check(measuredInput(text: String(repeating: "a", count: 2 * 1024 * 1024 + 1)) == nil,
      "text reconstruction has a fixed byte limit")

struct LiveReport: Decodable {
    struct Case: Decodable {
        struct Fixture: Decodable, Equatable {
            let rows: Int
            let columns: Int
            let widthPx: Int
            let heightPx: Int
            let cellWidthPx: Int
            let cellHeightPx: Int
            let ioctlError: Int
        }
        struct AX: Decodable, Equatable {
            let text: String
            let documentHeight: Double
            let viewWidth: Double
            let viewHeight: Double
            let scrollbar: Double
            let scale: Double?
            let viewX: Double?
            let viewY: Double?
        }
        let name: String
        let fixture: Fixture
        let ax: AX
        enum CodingKeys: String, CodingKey {
            case name = "case"
            case fixture, ax
        }
    }
    struct Auxiliary: Decodable {
        let ax: Case.AX
        let fixture: Case.Fixture?
        let exitStatus: Int?
        let setSizeStatus: Int?
    }
    let cases: [Case]
    let scrollToRow80: Auxiliary?
    let resize: Auxiliary?
}

func reconstruct(_ ax: LiveReport.Case.AX, fixture: LiveReport.Case.Fixture) -> GhosttyASCIIGeometry? {
    let scale = ax.scale ?? Double(fixture.widthPx) / ax.viewWidth
    guard fixture.ioctlError == 0, scale.isFinite, scale > 0 else { return nil }
    return GhosttyASCIIGeometry(text: ax.text, columns: fixture.columns, viewportRows: fixture.rows,
        cellSize: CGSize(width: Double(fixture.cellWidthPx) / scale, height: Double(fixture.cellHeightPx) / scale),
        viewport: CGRect(x: ax.viewX ?? 0, y: ax.viewY ?? 0, width: ax.viewWidth, height: ax.viewHeight),
        documentHeight: ax.documentHeight, scrollbarValue: ax.scrollbar)
}

func validateLiveReport(_ path: String) throws {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    let report = try decoder.decode(LiveReport.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    // These expectations describe the owned, zero-padding, 80-column fixtures only.
    // Other cases in the report are deliberately not assigned guessed expectations.
    let expected: [(name: String, total: Int, offset: Int, euler: Int, bare: Int, wrap: Int?, paths: Int)] = [
        ("short", 24, 0, 1, 3, nil, 4),
        ("history", 167, 143, 18, 20, nil, 21),
        ("wrap", 24, 0, 1, 3, 5, 7),
        ("history-wrap", 170, 146, 15, 17, 19, 21)
    ]
    for wanted in expected {
        let matches = report.cases.filter { $0.name == wanted.name }
        check(matches.count == 1, "live \(wanted.name): report identifies exactly one fixture")
        guard matches.count == 1, let sample = matches.first else { continue }
        let ax = sample.ax
        let fixture = sample.fixture
        let scaleX = Double(fixture.widthPx) / ax.viewWidth
        let scaleY = Double(fixture.heightPx) / ax.viewHeight
        let scale = ax.scale ?? scaleX
        let fixtureMatches = fixture.ioctlError == 0 && fixture.columns == 80 && fixture.rows == 24 &&
            scale.isFinite && scale > 0 && abs(scaleX - scale) < 0.000_001 && abs(scaleY - scale) < 0.000_001
        check(fixtureMatches, "live \(wanted.name): native grid and backing scale match owned fixture")
        guard fixtureMatches else { continue }
        let candidate = reconstruct(ax, fixture: fixture)
        check(candidate != nil, "live \(wanted.name): captured text and geometry reconstruct")
        guard let model = candidate else { continue }
        check(model.totalRows == wanted.total && model.viewportOffset == wanted.offset,
              "live \(wanted.name): total rows and viewport offset match fixture")

        func checkFormula(_ formula: String, row: Int, column: Int, label: String) {
            let range = (ax.text as NSString).range(of: formula)
            check(range.location != NSNotFound, "live \(wanted.name): \(label) source is present")
            guard range.location != NSNotFound else { return }
            let hits = (0..<range.length).allSatisfy { index in
                let location = point(model, row: row + (column + index) / model.columns,
                                     column: (column + index) % model.columns)
                return model.sourceOffset(at: location) == range.location + index && model.formula(at: location) == formula
            }
            check(hits, "live \(wanted.name): every \(label) source cell maps to exact formula")
        }
        checkFormula(#"$e^{i\pi}+1=0$"#, row: wanted.euler, column: 7, label: "Euler")
        checkFormula(boxed, row: wanted.bare, column: 6, label: "bare boxed")
        if let row = wanted.wrap {
            checkFormula(#"\boxed{x^2+y^2=z^2}"#, row: row, column: 16, label: "wrapped boxed")
        }
        let paths = "Paths: " + pathsText
        let pathsRange = (ax.text as NSString).range(of: paths)
        check(pathsRange.location != NSNotFound, "live \(wanted.name): expected path line is present")
        if pathsRange.location != NSNotFound {
            check((0..<pathsRange.length).allSatisfy { column in
                let location = point(model, row: wanted.paths, column: column)
                return model.sourceOffset(at: location) == pathsRange.location + column && model.formula(at: location) == nil
            }, "live \(wanted.name): path cells map correctly without formula previews")
        }
        check(model.sourceOffset(at: point(model, row: model.viewportRows - 1, column: 0)) == nil,
              "live \(wanted.name): final blank viewport row has no source")
    }

    if let scrolled = report.scrollToRow80 {
        check(scrolled.exitStatus == 0, "live scroll: native scroll-to-row command succeeded")
        let histories = report.cases.filter { $0.name == "history" }
        if histories.count == 1, let history = histories.first,
           let model = reconstruct(scrolled.ax, fixture: history.fixture) {
            check(model.totalRows == 167 && model.viewportOffset == 80,
                  "live scroll: normalized thumb resolves exactly to physical row 80")
            check((0..<24).allSatisfy { row in
                let line = String(format: "History row %03d", row + 80)
                let range = (model.text as NSString).range(of: line)
                return range.location != NSNotFound && (0..<range.length).allSatisfy { column in
                    model.sourceOffset(at: point(model, row: row, column: column)) == range.location + column
                } && model.formula(at: point(model, row: row, column: 0)) == nil
            }, "live scroll: all 24 visible history lines retain exact source positions")
        } else {
            check(false, "live scroll: matching history fixture and reconstruction are required")
        }
    }

    if let resized = report.resize {
        check(resized.setSizeStatus == 0, "live resize: native window resize succeeded")
        if let fixture = resized.fixture, let scale = resized.ax.scale, scale.isFinite, scale > 0 {
            let residualWidth = resized.ax.viewWidth - Double(fixture.columns) * Double(fixture.cellWidthPx) / scale
            let residualHeight = resized.ax.viewHeight - Double(fixture.rows) * Double(fixture.cellHeightPx) / scale
            check(fixture.columns == 82 && fixture.rows == 25 && residualWidth == 6 && residualHeight == 0.5,
                  "live resize: measured viewport has 6 by 0.5 points of residual space")
            check(reconstruct(resized.ax, fixture: fixture) == nil,
                  "live resize: zero-padding model rejects residual space without guessing its placement")
        } else {
            check(false, "live resize: fixture dimensions and measured backing scale are required")
        }
    }

    let erased = report.cases.filter { $0.name == "erased-wrap" }
    let plain = report.cases.filter { $0.name == "plain-wrap" }
    if !erased.isEmpty || !plain.isEmpty {
        check(erased.count == 1 && plain.count == 1, "known limitation: paired erase and plain fixtures are present")
        if erased.count == 1, plain.count == 1, let erased = erased.first, let plain = plain.first {
            let expectedText = "MATH PEEK OWNED GHOSTTY RESEARCH\n" + String(repeating: "A", count: 20) +
                "\n" + String(repeating: " ", count: 60) + boxed + "\nEND"
            check(erased.ax.text == expectedText && plain.ax.text == expectedText,
                  "known limitation: cursor-edited and append-only screens export identical plaintext")
            check(erased.ax == plain.ax && erased.fixture == plain.fixture,
                  "known limitation: every native geometry input is identical despite different formula positions")
            let erasedModel = reconstruct(erased.ax, fixture: erased.fixture)
            let plainModel = reconstruct(plain.ax, fixture: plain.fixture)
            check(erasedModel != nil && plainModel != nil,
                  "known limitation: consistency checks accept both indistinguishable exports")
            if let erasedModel, let plainModel {
                let range = (expectedText as NSString).range(of: boxed)
                check(erasedModel.sourceOffset(at: point(erasedModel, row: 2, column: 60)) == range.location &&
                      plainModel.sourceOffset(at: point(plainModel, row: 2, column: 60)) == range.location,
                      "known limitation: both models place formula start at row 2 column 60")
                // The owned erased fixture places the real backslash at row 3, column 0;
                // row 2 is entirely blank. These passing checks document a false hit.
                check(erasedModel.formula(at: point(erasedModel, row: 2, column: 60)) == boxed,
                      "known limitation: erased fixture produces a formula hit on an actually blank row")
                check(erasedModel.sourceOffset(at: point(erasedModel, row: 3, column: 0)) == range.location + 20 &&
                      erasedModel.sourceOffset(at: point(erasedModel, row: 3, column: 0)) != range.location,
                      "known limitation: actual erased formula start is mapped 20 characters too far into source")
                check(plainModel.sourceOffset(at: point(plainModel, row: 3, column: 0)) == range.location + 20,
                      "known limitation: the same offset is correct for the append-only counterpart")
            }
        }
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if !arguments.isEmpty {
    if arguments.count == 2 && arguments[0] == "--report" {
        do { try validateLiveReport(arguments[1]) }
        catch { check(false, "live report could not be read: \(error)") }
    } else {
        check(false, "usage: ghostty-geometry-research-tests [--report path]")
    }
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)

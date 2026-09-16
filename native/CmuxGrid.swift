import Foundation
import CoreGraphics

/// A full, viewport-anchored cmux render-grid snapshot. No terminal state is changed.
struct CmuxGrid {
    struct Generation: Equatable {
        let surfaceID: String
        let epoch: String
        let revision: UInt64
    }

    struct Hit {
        let formula: String
        let scalarRange: Range<Int>
        let bounds: CGRect
    }

    let generation: Generation
    let columns: Int
    let rows: Int
    private let text: String
    private let scalars: [Unicode.Scalar]
    private let cells: [Range<Int>?]
    private let hiddenRanges: [Range<Int>]
    private let blankRows: [Bool]

    private struct Span {
        let row: Int
        let column: Int
        let width: Int
        let characters: [[Unicode.Scalar]]
        let narrow: [Bool]
        let hidden: Bool
    }

    func sameViewport(as other: CmuxGrid) -> Bool {
        generation.surfaceID == other.generation.surfaceID && generation.epoch == other.generation.epoch &&
            columns == other.columns && rows == other.rows && text == other.text &&
            cells == other.cells && hiddenRanges == other.hiddenRanges
    }

    static func decode(result: [String: Any], expectedSurfaceID: String,
                       expectedColumns: Int, expectedRows: Int) -> CmuxGrid? {
        guard let expectedID = UUID(uuidString: expectedSurfaceID),
              let resultID = result["surface_id"] as? String,
              UUID(uuidString: resultID) == expectedID,
              let frame = result["render_grid"] as? [String: Any],
              frame["format"] as? String == "cmux.render-grid.v1",
              frame["anchor"] as? String == "viewport", isTrue(frame["full"]),
              let surfaceID = frame["surface_id"] as? String,
              UUID(uuidString: surfaceID) == expectedID,
              let columns = integer(frame["columns"]), let rows = integer(frame["rows"]),
              columns > 0, columns <= 1_024, rows > 0, rows <= 512,
              columns <= 65_536 / rows,
              columns == expectedColumns, rows == expectedRows,
              integer(result["columns"]) == columns, integer(result["rows"]) == rows,
              let epoch = frame["render_epoch"] as? String, !epoch.isEmpty,
              epoch.utf8.count <= 128,
              let revisionNumber = number(frame["render_revision"]),
              let revision = UInt64(revisionNumber.stringValue), revision > 0,
              let rawSpans = frame["row_spans"] as? [[String: Any]],
              rawSpans.count <= columns * rows else { return nil }
        if let cleared = frame["cleared_rows"],
           (cleared as? [Any])?.isEmpty != true { return nil }

        guard let styles = frame["styles"] as? [[String: Any]], !styles.isEmpty,
              styles.count <= columns * rows + 1 else { return nil }
        var hiddenStyles: [Int: Bool] = [:]
        for style in styles {
            guard let id = integer(style["id"]), id >= 0, id <= 65_536,
                  hiddenStyles[id] == nil else { return nil }
            if let rawHidden = style["invisible"] {
                guard let hidden = boolean(rawHidden) else { return nil }
                hiddenStyles[id] = hidden
            } else {
                hiddenStyles[id] = false
            }
        }

        var spans: [Span] = []
        var totalBytes = 0
        for raw in rawSpans {
            guard let row = integer(raw["row"]), (0..<rows).contains(row),
                  let column = integer(raw["column"]), (0..<columns).contains(column),
                  let styleID = integer(raw["style_id"]), let hidden = hiddenStyles[styleID],
                  let value = raw["text"] as? String, !value.isEmpty,
                  value.utf8.count <= 262_144 - totalBytes else { return nil }
            totalBytes += value.utf8.count
            let characters = value.map { Array($0.unicodeScalars) }
            guard !characters.isEmpty, characters.count <= columns,
                  characters.allSatisfy(validCharacter) else { return nil }
            let narrow = characters.map(isNarrow)
            let width: Int
            if let suppliedWidth = raw["cell_width"] {
                guard let parsed = integer(suppliedWidth) else { return nil }
                width = parsed
            } else {
                guard narrow.allSatisfy({ $0 }) else { return nil }
                width = characters.count
            }
            guard width >= characters.count, width <= columns - column,
                  !narrow.allSatisfy({ $0 }) || width == characters.count else { return nil }
            spans.append(Span(row: row, column: column, width: width,
                              characters: characters, narrow: narrow, hidden: hidden))
        }
        spans.sort { $0.row == $1.row ? $0.column < $1.column : $0.row < $1.row }

        var scalars: [Unicode.Scalar] = []
        var cells = [Range<Int>?](repeating: nil, count: columns * rows)
        var hiddenRanges: [Range<Int>] = []
        var blankRows: [Bool] = []
        var nextSpan = 0
        for row in 0..<rows {
            let rowStart = scalars.count
            var hasHiddenText = false
            var column = 0
            func appendBlanks(until end: Int) {
                while column < end {
                    let offset = scalars.count
                    scalars.append(" ")
                    cells[row * columns + column] = offset..<(offset + 1)
                    column += 1
                }
            }
            while nextSpan < spans.count, spans[nextSpan].row == row {
                let span = spans[nextSpan]
                guard span.column >= column else { return nil }
                appendBlanks(until: span.column)
                let spanStart = scalars.count
                var ranges: [Range<Int>] = []
                for character in span.characters {
                    let start = scalars.count
                    scalars.append(contentsOf: character)
                    ranges.append(start..<scalars.count)
                }
                if span.hidden {
                    hiddenRanges.append(spanStart..<scalars.count)
                    hasHiddenText = true
                }
                let unknown = span.narrow.indices.filter { !span.narrow[$0] }
                if unknown.count <= 1 {
                    var cell = span.column
                    for index in ranges.indices {
                        let width = span.narrow[index] ? 1 : span.width - (ranges.count - 1)
                        for occupied in cell..<(cell + width) {
                            cells[row * columns + occupied] = ranges[index]
                        }
                        cell += width
                    }
                } else {
                    // A span supplies only its TOTAL width. Preserve the known ASCII
                    // prefix/suffix, but never guess widths between Unicode graphemes.
                    for index in 0..<unknown.first! {
                        cells[row * columns + span.column + index] = ranges[index]
                    }
                    for index in (unknown.last! + 1)..<ranges.count {
                        let cell = span.column + span.width - (ranges.count - index)
                        cells[row * columns + cell] = ranges[index]
                    }
                }
                column = span.column + span.width
                nextSpan += 1
            }
            appendBlanks(until: columns)
            blankRows.append(!hasHiddenText && scalars[rowStart...].allSatisfy { $0 == " " })
            if row + 1 < rows { scalars.append("\n") }
            guard scalars.count <= 131_072 else { return nil }
        }
        return CmuxGrid(generation: Generation(surfaceID: expectedID.uuidString,
                                                epoch: epoch, revision: revision),
                        columns: columns, rows: rows,
                        text: String(String.UnicodeScalarView(scalars)),
                        scalars: scalars, cells: cells, hiddenRanges: hiddenRanges, blankRows: blankRows)
    }

    /// Coordinates are AX screen points (top-left origin). The caller must also
    /// discard the snapshot when its surface, viewport, or geometry changes.
    func hit(at point: CGPoint, in area: CGRect, cellSize: CGSize,
             expectedGeneration: Generation? = nil, allowBlankAdjacentRows: Bool = false) -> Hit? {
        guard expectedGeneration == nil || expectedGeneration == generation,
              [point.x, point.y, area.origin.x, area.origin.y, area.width, area.height,
               cellSize.width, cellSize.height].allSatisfy({ $0.isFinite }),
              area.width > 0, area.height > 0, area.width <= 65_536, area.height <= 65_536,
              cellSize.width >= 0.5, cellSize.height >= 0.5,
              cellSize.width <= 512, cellSize.height <= 512 else { return nil }
        let slackX = area.width - CGFloat(columns) * cellSize.width
        let slackY = area.height - CGFloat(rows) * cellSize.height
        guard slackX >= 0, slackY >= 0,
              let possibleColumns = possibleCells(position: point.x - area.minX,
                                                   cellSize: cellSize.width, slack: slackX, count: columns),
              let possibleRows = possibleCells(position: point.y - area.minY,
                                                cellSize: cellSize.height, slack: slackY, count: rows),
              possibleColumns.count <= 64 / possibleRows.count else { return nil }
        var ranges: [Range<Int>] = []
        for row in possibleRows {
            // Optional target expansion into a neighboring EMPTY line. This is
            // bounded to less than one row and never skips blanks in a code row.
            if allowBlankAdjacentRows && slackY < cellSize.height && possibleRows.count <= 2 && blankRows[row] {
                continue
            }
            for column in possibleColumns {
                guard let range = cells[row * columns + column] else { return nil }
                ranges.append(range)
            }
        }
        guard let first = ranges.first,
              let formula = HoverMath.extract(text: text, offset: first.lowerBound),
              let sourceRange = exactFormulaRange(formula, containing: first),
              !hiddenRanges.contains(where: { $0.overlaps(sourceRange) }),
              ranges.allSatisfy({ sourceRange.lowerBound <= $0.lowerBound && $0.upperBound <= sourceRange.upperBound }) else {
            return nil
        }
        // Union bounds are only a popup anchor. Every nonblank target is checked
        // against all padding origins, including origins at both ends.
        let bounds = CGRect(x: area.minX + CGFloat(possibleColumns.lowerBound) * cellSize.width,
                            y: area.minY + CGFloat(possibleRows.lowerBound) * cellSize.height,
                            width: CGFloat(possibleColumns.count) * cellSize.width + slackX,
                            height: CGFloat(possibleRows.count) * cellSize.height + slackY)
        return Hit(formula: formula, scalarRange: sourceRange, bounds: bounds)
    }

    private func possibleCells(position: CGFloat, cellSize: CGFloat,
                               slack: CGFloat, count: Int) -> Range<Int>? {
        guard position.isFinite, position >= slack,
              position < CGFloat(count) * cellSize else { return nil }
        let first = Int(floor((position - slack) / cellSize))
        let last = Int(floor(position / cellSize))
        guard first >= 0, last < count, first <= last else { return nil }
        return first..<(last + 1)
    }

    private func exactFormulaRange(_ formula: String, containing cell: Range<Int>) -> Range<Int>? {
        let needle = Array(formula.unicodeScalars)
        guard !needle.isEmpty, needle.count <= 4_096, needle.count <= scalars.count else { return nil }
        let lower = max(0, cell.upperBound - needle.count)
        let upper = min(cell.lowerBound, scalars.count - needle.count)
        guard lower <= upper else { return nil }
        var match: Range<Int>?
        for start in lower...upper where scalars[start] == needle[0] {
            let range = start..<(start + needle.count)
            if scalars[range].elementsEqual(needle) {
                guard match == nil else { return nil }
                match = range
            }
        }
        return match
    }

    private static func validCharacter(_ scalars: [Unicode.Scalar]) -> Bool {
        guard !scalars.isEmpty, scalars.count <= 32,
              !scalars.contains(where: { $0.properties.generalCategory == .control || $0 == "\n" || $0 == "\r" }),
              let first = scalars.first,
              ![Unicode.GeneralCategory.nonspacingMark, .spacingMark, .enclosingMark, .format].contains(first.properties.generalCategory) else {
            return false
        }
        return true
    }

    private static func isNarrow(_ scalars: [Unicode.Scalar]) -> Bool {
        guard let first = scalars.first, (0x20...0x7e).contains(first.value) else { return false }
        return scalars.dropFirst().allSatisfy {
            $0.value != 0xfe0f && $0.value != 0x20e3 &&
                [.nonspacingMark, .spacingMark, .enclosingMark].contains($0.properties.generalCategory)
        }
    }

    private static func number(_ value: Any?) -> NSNumber? {
        guard let value = value as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return value
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).flatMap { Int($0.stringValue) }
    }

    private static func isTrue(_ value: Any?) -> Bool {
        boolean(value) == true
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }
}

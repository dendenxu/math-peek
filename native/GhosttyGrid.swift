import Foundation
import CoreGraphics

// Experimental reconstruction of ordinary output. Ghostty flattens cursor-edited
// rows; this cannot establish that arbitrary TUI output matches the displayed grid.
struct GhosttyGrid {
    let text: String
    let columns: Int
    private let scalars: [Unicode.Scalar]
    private let cells: [[Int?]]
    var physicalRows: Int { cells.count }

    init?(text: String, columns: Int) {
        guard (2...1024).contains(columns), text.utf8.count <= 524_288 else { return nil }
        let scalars = Array(text.unicodeScalars)
        guard !scalars.contains(where: { $0 != "\n" && $0.properties.generalCategory == .control }) else { return nil }
        var rows: [[Int?]] = []
        var offset = 0
        for line in text.components(separatedBy: "\n") {
            let characters = line.map { Array($0.unicodeScalars) }
            let widths = characters.map(Self.width)
            let scalarCount = characters.reduce(0) { $0 + $1.count }
            if widths.contains(where: { $0 == nil }) {
                // Retain rows only if every plausible width agrees on the wrap
                // count. Never expose guessed character positions within this line.
                let maximumWidth = zip(characters, widths).reduce(0) { $0 + ($1.1 ?? $1.0.count * 2) }
                if maximumWidth <= columns { rows.append([]) }
                else {
                    guard zip(characters, widths).allSatisfy({ $0.1 != nil || $0.0.count == 1 }), characters.count <= 32_768 else { return nil }
                    var positions: Set<Int> = [0]
                    for width in widths {
                        var next: Set<Int> = []
                        for position in positions {
                            let row = position / (columns + 1), column = position % (columns + 1)
                            for candidate in width.map({ [$0] }) ?? [0, 1, 2] {
                                if candidate == 0 { next.insert(position) }
                                else if column + candidate > columns { next.insert((row + 1) * (columns + 1) + candidate) }
                                else { next.insert(row * (columns + 1) + column + candidate) }
                            }
                        }
                        guard next.count <= 64 else { return nil }
                        positions = next
                    }
                    let counts = Set(positions.map { $0 / (columns + 1) + 1 })
                    guard counts.count == 1, let count = counts.first else { return nil }
                    rows.append(contentsOf: repeatElement([], count: count))
                }
                guard rows.count <= 32_768 else { return nil }
                offset += scalarCount + 1
                continue
            }
            let lineWidth = widths.reduce(0) { $0 + $1! }
            // Flattened blank wrapped rows can masquerade as an indented line.
            // Reject this known ambiguous pattern instead of previewing blank space.
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            guard leadingSpaces == 0 || lineWidth <= columns else { return nil }
            var row: [Int?] = []
            for (character, optionalWidth) in zip(characters, widths) {
                let width = optionalWidth!
                if row.count == columns || row.count + width > columns {
                    rows.append(row)
                    row = []
                }
                row.append(contentsOf: repeatElement(Optional(offset), count: width))
                offset += character.count
            }
            rows.append(row)
            offset += 1
            guard rows.count <= 32_768 else { return nil }
        }
        guard rows.count <= 32_768 else { return nil }
        self.text = text; self.columns = columns; self.scalars = scalars; cells = rows
    }

    private static func width(_ scalars: [Unicode.Scalar]) -> Int? {
        guard let first = scalars.first else { return nil }
        guard scalars.dropFirst().allSatisfy({ $0.properties.generalCategory == .nonspacingMark &&
            $0.value != 0xfe0f && $0.value != 0xfe0e && $0.value != 0x20e3 }) else { return nil }
        if (0x20...0x7e).contains(first.value) { return 1 }
        // Unambiguous wide CJK ranges; ambiguous-width symbols and emoji are not
        // assigned guessed columns. Ghostty may configure their width differently.
        if (0x4e00...0x9fff).contains(first.value) || (0x3400...0x4dbf).contains(first.value) ||
           (0x3041...0x3096).contains(first.value) || (0x30a1...0x30fa).contains(first.value) ||
           (0xac00...0xd7a3).contains(first.value) || (0xff01...0xff60).contains(first.value) ||
           (0x3000...0x303e).contains(first.value) { return 2 }
        return nil
    }

    static func viewportOffset(rows: Int, cellHeight: CGFloat, areaHeight: CGFloat,
                               documentHeight: CGFloat, scrollbar: Double) -> (total: Int, offset: Int)? {
        guard (2...512).contains(rows), cellHeight.isFinite, cellHeight > 0,
              areaHeight.isFinite, areaHeight > 0, documentHeight.isFinite,
              documentHeight >= areaHeight, scrollbar.isFinite, (0...1).contains(scrollbar) else { return nil }
        let history = (documentHeight - areaHeight) / cellHeight
        guard history >= 0, history <= 32_768 - CGFloat(rows), abs(history - history.rounded()) < 0.005 else { return nil }
        let offset = Double(history.rounded()) * scrollbar
        guard abs(offset - offset.rounded()) < 0.005 else { return nil }
        return (rows + Int(history.rounded()), Int(offset.rounded()))
    }

    func formula(at point: CGPoint, area: CGRect, cellSize: CGSize, rows: Int,
                 documentHeight: CGFloat, scrollbar: Double) -> String? {
        guard [point.x, point.y, area.minX, area.minY, area.width, area.height,
               cellSize.width, cellSize.height].allSatisfy(\.isFinite),
              (0.5...512).contains(cellSize.width), (0.5...1024).contains(cellSize.height),
              let viewport = Self.viewportOffset(rows: rows, cellHeight: cellSize.height, areaHeight: area.height,
                                                documentHeight: documentHeight, scrollbar: scrollbar),
              cells.count <= viewport.total, viewport.total - cells.count <= rows else { return nil }
        func candidates(_ position: CGFloat, _ step: CGFloat, _ slack: CGFloat, _ count: Int) -> Range<Int>? {
            guard slack >= -0.01, slack <= step * 2, position >= max(0, slack), position < CGFloat(count) * step else { return nil }
            let first = Int(floor((position - max(0, slack)) / step)), last = Int(floor(position / step))
            guard first >= 0, first <= last, last < count else { return nil }
            return first..<(last + 1)
        }
        guard let columnRange = candidates(point.x - area.minX, cellSize.width,
                                           area.width - CGFloat(columns) * cellSize.width, columns),
              let rowRange = candidates(point.y - area.minY, cellSize.height,
                                        area.height - CGFloat(rows) * cellSize.height, rows) else { return nil }
        var offsets: [Int] = []
        for row in rowRange {
            let physical = row + viewport.offset
            guard physical < cells.count else { return nil }
            for column in columnRange {
                guard column < cells[physical].count, let source = cells[physical][column] else { return nil }
                offsets.append(source)
            }
        }
        guard let first = offsets.first else { return nil }
        let start = max(0, first - 16_384), end = min(scalars.count, first + 16_384)
        let context = String(String.UnicodeScalarView(scalars[start..<end]))
        guard let formula = HoverMath.extract(text: context, offset: first - start) else { return nil }
        let needle = Array(formula.unicodeScalars)
        let lower = max(start, first - needle.count + 1), upper = min(first, end - needle.count)
        guard lower <= upper else { return nil }
        var matchingRange: Range<Int>?
        for index in lower...upper where scalars[index] == needle.first {
            let range = index..<(index + needle.count)
            if scalars[range].elementsEqual(needle) {
                guard matchingRange == nil else { return nil }
                matchingRange = range
            }
        }
        guard let range = matchingRange, offsets.allSatisfy(range.contains) else { return nil }
        return formula
    }
}

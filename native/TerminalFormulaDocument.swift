import Foundation

/// Immutable terminal text plus a deterministic set of logical pane documents.
/// Pane reconstruction is performed once for the snapshot; formula lookup never
/// reparses a different slice merely because the pointer moved to another row.
final class TerminalFormulaDocument {
    private struct PaneKey: Hashable {
        let firstRow: Int
        let lastRow: Int
        let leftColumn: Int?
        let rightColumn: Int?
    }

    private struct Row {
        let start: Int
        let end: Int
        let borders: [Int: Int]? // terminal column -> scalar index
    }

    private struct PaneRecord {
        let index: HoverMath.Index
        let sourceOffsets: [Int?]
        let projectedBySource: [Int: Int]
    }

    private let text: String
    private let scalars: [Unicode.Scalar]
    private let rows: [Row]
    private let scalarRows: [Int]
    private let wholeIndex: HoverMath.Index
    private let allowsClippedTop: Bool
    private let allowsClippedBottom: Bool
    private var panes: [PaneKey: PaneRecord] = [:]
    private var paneBySource: [Int: PaneKey] = [:]
    private let lock = NSLock()

    init(text: String, allowsClippedTop: Bool = true, allowsClippedBottom: Bool = true) {
        self.text = text
        self.allowsClippedTop = allowsClippedTop
        self.allowsClippedBottom = allowsClippedBottom
        scalars = Array(text.unicodeScalars)
        var builtRows: [Row] = []
        var rowForScalar = [Int](repeating: 0, count: scalars.count)
        var start = 0
        for position in 0...scalars.count where position == scalars.count || scalars[position] == "\n" {
            let end = position > start && scalars[position - 1] == "\r" ? position - 1 : position
            let rowNumber = builtRows.count
            if start < position {
                for index in start..<position { rowForScalar[index] = rowNumber }
            }
            builtRows.append(Row(start: start, end: end, borders: Self.borders(in: scalars, range: start..<end)))
            start = position + 1
        }
        rows = builtRows
        scalarRows = rowForScalar
        wholeIndex = HoverMath.makeIndex(text: text, panePadding: false,
                                         allowsClippedTop: allowsClippedTop,
                                         allowsClippedBottom: allowsClippedBottom)
    }

    func match(at sourceOffset: Int) -> HoverMath.Extraction? {
        guard scalars.indices.contains(sourceOffset) else { return nil }
        lock.lock()
        let cachedKey = paneBySource[sourceOffset]
        lock.unlock()
        if let key = cachedKey ?? paneKey(at: sourceOffset) {
            lock.lock()
            let pane: PaneRecord
            if let cached = panes[key] {
                pane = cached
            } else {
                guard let projection = makeProjection(key) else { lock.unlock(); return nil }
                let created = HoverMath.makeIndex(
                    text: projection.text, panePadding: true,
                    // A stable tmux pane segment is itself a validated logical
                    // viewport. Horizontal splits and junction rows may end it
                    // inside the enclosing AX string without making that edge
                    // an arbitrary character crop.
                    allowsClippedTop: allowsClippedTop,
                    allowsClippedBottom: allowsClippedBottom)
                var projectedBySource: [Int: Int] = [:]
                for (projected, original) in projection.sourceOffsets.enumerated() {
                    if let original { projectedBySource[original] = projected }
                }
                pane = PaneRecord(index: created, sourceOffsets: projection.sourceOffsets,
                                  projectedBySource: projectedBySource)
                panes[key] = pane
                for original in projectedBySource.keys { paneBySource[original] = key }
            }
            lock.unlock()
            if let offset = pane.projectedBySource[sourceOffset],
               let block = pane.index.block(containing: offset),
               let ranges = Self.originalRanges(for: block.range, offsets: pane.sourceOffsets),
               !ranges.isEmpty {
                return HoverMath.Extraction(formula: block.formula, sourceRanges: ranges, kind: block.kind)
            }
            // A reliable pane was identified. Never fall through to the whole
            // terminal buffer, where a neighboring pane could manufacture a hit.
            return nil
        }
        guard let block = wholeIndex.block(containing: sourceOffset) else { return nil }
        return HoverMath.Extraction(formula: block.formula, sourceRanges: [block.range], kind: block.kind)
    }

    private func paneKey(at offset: Int) -> PaneKey? {
        guard scalarRows.indices.contains(offset) else { return nil }
        let cursorRow = scalarRows[offset]
        guard rows.indices.contains(cursorRow), let current = rows[cursorRow].borders, !current.isEmpty,
              offset < rows[cursorRow].end, !current.values.contains(offset) else { return nil }
        let left = current.filter { $0.value < offset }.keys.max()
        let right = current.filter { $0.value > offset }.keys.min()

        func compatible(_ row: Int) -> Bool {
            guard rows.indices.contains(row), let borders = rows[row].borders,
                  left == nil || borders[left!] != nil, right == nil || borders[right!] != nil else { return false }
            return !borders.keys.contains { column in
                (left == nil || column > left!) && (right == nil || column < right!)
            }
        }

        var first = cursorRow
        var last = cursorRow
        while first > 0 && compatible(first - 1) { first -= 1 }
        while last + 1 < rows.count && compatible(last + 1) { last += 1 }
        guard last - first + 1 >= 3 else { return nil }
        return PaneKey(firstRow: first, lastRow: last, leftColumn: left, rightColumn: right)
    }

    private func makeProjection(_ key: PaneKey) -> (text: String, sourceOffsets: [Int?])? {
        var projected: [Unicode.Scalar] = []
        var offsets: [Int?] = []
        for rowIndex in key.firstRow...key.lastRow {
            guard let borders = rows[rowIndex].borders else { return nil }
            let begin = key.leftColumn.flatMap { borders[$0] }.map { $0 + 1 } ?? rows[rowIndex].start
            let end = key.rightColumn.flatMap { borders[$0] } ?? rows[rowIndex].end
            guard begin <= end else { return nil }
            projected.append(contentsOf: scalars[begin..<end])
            offsets.append(contentsOf: (begin..<end).map(Optional.some))
            if rowIndex < key.lastRow {
                projected.append("\n")
                offsets.append(nil)
            }
        }
        return (String(String.UnicodeScalarView(projected)), offsets)
    }

    private static func borders(in text: [Unicode.Scalar], range: Range<Int>) -> [Int: Int]? {
        var result: [Int: Int] = [:]
        var column = 0
        for index in range {
            let scalar = text[index]
            let value = scalar.value
            if scalar == "\t" || value == 0x200c || value == 0x200d || value == 0xfe0e || value == 0xfe0f ||
               (0x1f3fb...0x1f3ff).contains(value) || (0x1f1e6...0x1f1ff).contains(value) { return nil }
            let name = scalar.properties.name ?? ""
            if (0x2500...0x257f).contains(value),
               name.contains("VERTICAL") || name.contains("UP") && name.contains("DOWN") {
                result[column] = index
            }
            column += cellWidth(scalar)
        }
        return result
    }

    private static func cellWidth(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format: return 0
        default: break
        }
        let value = scalar.value
        if (0x1100...0x115f).contains(value) || value == 0x2329 || value == 0x232a ||
           (0x2e80...0xa4cf).contains(value) && value != 0x303f ||
           (0xac00...0xd7a3).contains(value) || (0xf900...0xfaff).contains(value) ||
           (0xfe10...0xfe19).contains(value) || (0xfe30...0xfe6f).contains(value) ||
           (0xff01...0xff60).contains(value) || (0xffe0...0xffe6).contains(value) ||
           (0x1f300...0x1faff).contains(value) || (0x20000...0x3fffd).contains(value) ||
           scalar.properties.isEmojiPresentation { return 2 }
        return 1
    }

    private static func originalRanges(for range: Range<Int>, offsets: [Int?]) -> [Range<Int>]? {
        guard range.lowerBound >= 0, range.upperBound <= offsets.count else { return nil }
        var result: [Range<Int>] = []
        for projected in range {
            guard let original = offsets[projected] else { continue }
            if let last = result.last, last.upperBound == original {
                result[result.count - 1] = last.lowerBound..<(original + 1)
            } else {
                result.append(original..<(original + 1))
            }
        }
        return result
    }
}

/// Snapshot-level cache. Speed comes only from reusing a fully parsed immutable
/// document; it never accepts a less complete formula than the normal path.
final class FormulaDocumentCache {
    private let lock = NSLock()
    private var text: String?
    private var clippedTop = false
    private var clippedBottom = false
    private var document: TerminalFormulaDocument?

    func match(text newText: String, at offset: Int,
               allowsClippedTop: Bool = true, allowsClippedBottom: Bool = true) -> HoverMath.Extraction? {
        lock.lock()
        let current: TerminalFormulaDocument
        if text == newText, clippedTop == allowsClippedTop, clippedBottom == allowsClippedBottom, let document {
            current = document
        } else {
            current = TerminalFormulaDocument(text: newText, allowsClippedTop: allowsClippedTop,
                                              allowsClippedBottom: allowsClippedBottom)
            text = newText
            clippedTop = allowsClippedTop
            clippedBottom = allowsClippedBottom
            document = current
        }
        lock.unlock()
        return current.match(at: offset)
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        text = nil
        document = nil
    }
}

import Foundation

/// Terminal math extraction using Unicode scalar offsets; no helper process.
enum HoverMath {
    static func extract(text: String, offset: Int) -> String? {
        let input = Array(text.unicodeScalars)
        guard offset >= 0, offset < input.count else { return nil }
        let pane = project(input, offset)
        let source = pane?.text ?? input
        let cursor = pane?.offset ?? offset
        guard let range = expression(source, cursor, padding: pane != nil) else { return nil }
        return repair(Array(source[range]), padding: pane != nil)
    }

    private typealias Scalars = [Unicode.Scalar]
    private struct Pane { let text: Scalars; let offset: Int }
    private struct Row { let start: Int; let end: Int }
    private struct Border: Equatable { let column: Int; let index: Int }
    private static let commands = Set("""
    frac dfrac tfrac sqrt sum prod coprod int iint iiint oint lim limits nolimits
    infty partial nabla cdot times div pm mp le leq ge geq ne neq approx equiv sim
    simeq cong propto in notin subset subseteq supset supseteq cup cap setminus
    forall exists nexists neg land lor implies iff to mapsto rightarrow leftarrow
    leftrightarrow Rightarrow Leftarrow Leftrightarrow longrightarrow longleftarrow
    longleftrightarrow Longrightarrow Longleftarrow Longleftrightarrow uparrow
    downarrow alpha beta gamma delta epsilon varepsilon zeta eta theta vartheta
    iota kappa lambda mu nu xi pi varpi rho varrho sigma varsigma tau upsilon phi
    varphi chi psi omega Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega
    mathbb mathbf mathrm mathit mathcal mathscr mathsf mathtt boldsymbol operatorname
    text textrm textbf textit begin end left right middle overline underline
    overbrace underbrace hat widehat bar vec dot ddot dots ldots cdots vdots ddots
    sin cos tan cot sec csc arcsin arccos arctan sinh cosh tanh log ln exp min max
    arg det gcd Pr binom dbinom tbinom overset underset substack cases vphantom
    hphantom phantom displaystyle textstyle scriptstyle scriptscriptstyle
    big Big bigg Bigg bigl bigr Bigl Bigr biggl biggr Biggl Biggr langle rangle
    lvert rvert lVert rVert vert Vert lceil rceil lfloor rfloor ell hbar emptyset
    varnothing Re Im bmod pmod mod stackrel cancel bcancel xcancel boxed color
    textcolor underbracket overbracket bracevert choose atop not accentset
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    private static let commandPrefixes: Set<String> = {
        Set(commands.flatMap { command in (1...command.count).map { String(command.prefix($0)) } })
    }()

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        String(String.UnicodeScalarView(scalars))
    }
    private static func string(_ scalars: Scalars) -> String { string(scalars[...]) }
    private static func letter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(scalar.value) || (97...122).contains(scalar.value)
    }
    private static func newline(_ scalar: Unicode.Scalar) -> Bool { scalar == "\n" || scalar == "\r" }
    private static func escaped(_ text: Scalars, _ index: Int) -> Bool {
        var i = index - 1
        while i >= 0 && text[i] == "\\" { i -= 1 }
        return (index - i - 1) % 2 == 1
    }
    private static func matches(_ text: Scalars, _ token: Scalars, at index: Int) -> Bool {
        guard index >= 0, index + token.count <= text.count else { return false }
        return text[index..<(index + token.count)].elementsEqual(token)
    }
    private static func find(_ text: Scalars, _ token: Scalars, from start: Int, limit: Int) -> Int? {
        guard !token.isEmpty, start <= limit - token.count else { return nil }
        for i in start...(limit - token.count) where matches(text, token, at: i) { return i }
        return nil
    }
    private static func acrossWrap(_ text: Scalars, _ position: Int, step: Int, padding: Bool) -> Unicode.Scalar? {
        var i = position
        if padding && step == 1 && i >= 0 && i < text.count {
            var end = i
            while end < text.count && text[end] == " " { end += 1 }
            if end < text.count && newline(text[end]) { i = end }
        }
        while i >= 0 && i < text.count && newline(text[i]) {
            i += step
            if padding && step == -1 {
                while i >= 0 && text[i] == " " { i -= 1 }
            }
        }
        return i >= 0 && i < text.count ? text[i] : nil
    }

    private static func closing(_ text: Scalars, opening: Scalars, closing: Scalars,
                                start: Int, padding: Bool) -> Int? {
        let inline = opening == ["$"] || opening == ["\\", "("]
        let limit = min(text.count, start + opening.count + (inline ? 2048 : 16384) + closing.count)
        var position = start + opening.count
        while let end = find(text, closing, from: position, limit: limit) {
            if escaped(text, end) { position = end + closing.count; continue }
            if opening == ["$"] {
                guard let before = acrossWrap(text, end - 1, step: -1, padding: padding),
                      !before.properties.isWhitespace, before != "$" else { return nil }
                if end + 1 < text.count {
                    let after = text[end + 1]
                    if after == "$" || after.properties.numericType == .decimal || after.properties.numericType == .digit {
                        return nil
                    }
                }
            }
            let body = text[(start + opening.count)..<end]
            guard body.contains(where: { !$0.properties.isWhitespace }),
                  body.reduce(0, { $0 + ($1 == "\n" ? 1 : 0) }) < (inline ? 12 : 80),
                  !body.contains(where: { (0x2500...0x257F).contains($0.value) || $0 == "`" }) else { return nil }
            return end
        }
        return nil
    }

    private static func lineEnd(_ text: Scalars, _ start: Int) -> Int {
        var i = start
        while i < text.count && text[i] != "\n" { i += 1 }
        return i < text.count ? i + 1 : i
    }
    private static func fencePrefix(_ text: Scalars, _ start: Int) -> Int {
        var i = start
        while true {
            var spaces = 0
            while i < text.count && text[i] == " " && spaces < 3 { i += 1; spaces += 1 }
            if i < text.count && text[i] == ">" {
                i += 1
                if i < text.count && (text[i] == " " || text[i] == "\t") { i += 1 }
            } else { return i }
        }
    }
    private static func skipFence(_ text: Scalars, _ start: Int) -> Int? {
        let markerStart = fencePrefix(text, start)
        guard markerStart < text.count, text[markerStart] == "`" || text[markerStart] == "~" else { return nil }
        let marker = text[markerStart]
        var markerEnd = markerStart
        while markerEnd < text.count && text[markerEnd] == marker { markerEnd += 1 }
        let count = markerEnd - markerStart
        guard count >= 3 else { return nil }
        var next = lineEnd(text, markerEnd)
        while next < text.count {
            var i = fencePrefix(text, next)
            let begin = i
            while i < text.count && text[i] == marker { i += 1 }
            if i - begin >= count {
                while i < text.count && (text[i] == " " || text[i] == "\t") { i += 1 }
                if i < text.count && text[i] == "\r" { i += 1 }
                if i == text.count || text[i] == "\n" { return lineEnd(text, i) }
            }
            next = lineEnd(text, next)
        }
        return text.count
    }
    private static func skipCode(_ text: Scalars, _ start: Int) -> Int? {
        var end = start
        while end < text.count && text[end] == "`" { end += 1 }
        let marker = Array(text[start..<end])
        while let match = find(text, marker, from: end, limit: text.count) {
            let after = match + marker.count
            if (match == 0 || text[match - 1] != "`") && (after == text.count || text[after] != "`") {
                return after
            }
            end = after
        }
        return nil
    }
    private static func expression(_ text: Scalars, _ offset: Int, padding: Bool) -> Range<Int>? {
        var i = 0
        while i < text.count && i <= offset {
            if (i == 0 || text[i - 1] == "\n"), let end = skipFence(text, i) { i = end; continue }
            if text[i] == "`", !escaped(text, i), let end = skipCode(text, i) { i = end; continue }
            var opening: Scalars = []
            var close: Scalars = []
            if !escaped(text, i) {
                if matches(text, ["$", "$"], at: i) { opening = ["$", "$"]; close = opening }
                else if matches(text, ["\\", "["], at: i) { opening = ["\\", "["]; close = ["\\", "]"] }
                else if matches(text, ["\\", "("], at: i) { opening = ["\\", "("]; close = ["\\", ")"] }
                else if text[i] == "$", let after = acrossWrap(text, i + 1, step: 1, padding: padding),
                        !after.properties.isWhitespace {
                    let before: Unicode.Scalar? = i > 0 ? text[i - 1] : nil
                    let word = before.map { letter($0) || (48...57).contains($0.value) || $0 == "_" } ?? false
                    if before != "$" && !word { opening = ["$"]; close = opening }
                }
            }
            if !opening.isEmpty {
                if let end = closing(text, opening: opening, closing: close, start: i, padding: padding) {
                    let after = end + close.count
                    if i <= offset && offset < after { return i..<after }
                    i = after
                } else { i += opening.count }
            } else { i += 1 }
        }
        return nil
    }

    private static func repair(_ text: Scalars, padding: Bool) -> String {
        var output: Scalars = []
        var previous = 0
        var start = 0
        while start + 1 < text.count {
            defer { start += 1 }
            guard start >= previous, text[start] == "\\", letter(text[start + 1]), !escaped(text, start) else { continue }
            var end = start + 1
            while end < text.count && letter(text[end]) { end += 1 }
            var command = string(text[(start + 1)..<end])
            if commands.contains(command) { continue }
            for _ in 0..<3 {
                var fragment = end
                if padding { while fragment < text.count && text[fragment] == " " { fragment += 1 } }
                if fragment < text.count && text[fragment] == "\r" { fragment += 1 }
                guard fragment < text.count && text[fragment] == "\n" else { break }
                fragment += 1
                var finish = fragment
                while finish < text.count && letter(text[finish]) { finish += 1 }
                guard finish > fragment else { break }
                command += string(text[fragment..<finish])
                end = finish
                if commands.contains(command) {
                    output.append(contentsOf: text[previous..<start])
                    output.append("\\")
                    output.append(contentsOf: command.unicodeScalars)
                    previous = end
                    break
                }
                if !commandPrefixes.contains(command) { break }
            }
        }
        output.append(contentsOf: text[previous...])
        return string(output)
    }

    private static func width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format: return 0
        default: break
        }
        let v = scalar.value
        // East Asian wide/full-width ranges and ordinary wide emoji. Ambiguous
        // characters remain one cell, matching iTerm2's default setting.
        if (0x1100...0x115F).contains(v) || v == 0x2329 || v == 0x232A ||
            (0x2E80...0xA4CF).contains(v) && v != 0x303F ||
            (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v) ||
            (0xFE10...0xFE19).contains(v) || (0xFE30...0xFE6F).contains(v) ||
            (0xFF01...0xFF60).contains(v) || (0xFFE0...0xFFE6).contains(v) ||
            (0x1F300...0x1FAFF).contains(v) || (0x20000...0x3FFFD).contains(v) ||
            scalar.properties.isEmojiPresentation { return 2 }
        return 1
    }
    private static func project(_ text: Scalars, _ offset: Int) -> Pane? {
        var rows: [Row] = []
        var start = 0
        var cursorRow: Int?
        for i in 0...text.count where i == text.count || text[i] == "\n" {
            let end = i > start && text[i - 1] == "\r" ? i - 1 : i
            if start <= offset && offset < (i == text.count ? i : i + 1) { cursorRow = rows.count }
            rows.append(Row(start: start, end: end))
            start = i + 1
        }
        guard let cursorRow else { return nil }
        var cache: [Int: [Border]] = [:]
        var rejected = Set<Int>()
        func layout(_ rowIndex: Int) -> [Border]? {
            if let found = cache[rowIndex] { return found }
            if rejected.contains(rowIndex) { return nil }
            let row = rows[rowIndex]
            var column = 0
            var borders: [Border] = []
            for i in row.start..<row.end {
                let scalar = text[i], v = scalar.value
                if scalar == "\t" || v == 0x200C || v == 0x200D || v == 0xFE0E || v == 0xFE0F ||
                    (0x1F3FB...0x1F3FF).contains(v) || (0x1F1E6...0x1F1FF).contains(v) {
                    rejected.insert(rowIndex)
                    return nil
                }
                if v == 0x2502 || v == 0x2503 || v == 0x2551 { borders.append(Border(column: column, index: i)) }
                column += width(scalar)
            }
            cache[rowIndex] = borders
            return borders
        }
        guard let borders = layout(cursorRow), !borders.isEmpty,
              offset < rows[cursorRow].end, !borders.contains(where: { $0.index == offset }) else { return nil }
        let columns = borders.map(\.column)
        let left = borders.last(where: { $0.index < offset })?.column
        let right = borders.first(where: { $0.index > offset })?.column
        func same(_ row: Int) -> Bool { layout(row)?.map(\.column) == columns }
        var first = cursorRow, last = cursorRow
        while first > 0 && same(first - 1) { first -= 1 }
        while last + 1 < rows.count && same(last + 1) { last += 1 }
        guard last - first + 1 >= 3 else { return nil }
        var projected: Scalars = []
        var projectedOffset = 0
        for index in first...last {
            guard let rowLayout = layout(index) else { return nil }
            let begin = left.flatMap { c in rowLayout.first(where: { $0.column == c })?.index }.map { $0 + 1 } ?? rows[index].start
            let end = right.flatMap { c in rowLayout.first(where: { $0.column == c })?.index } ?? rows[index].end
            if index == cursorRow { projectedOffset = projected.count + offset - begin }
            projected.append(contentsOf: text[begin..<end])
            if index < last { projected.append("\n") }
        }
        return Pane(text: projected, offset: projectedOffset)
    }
}

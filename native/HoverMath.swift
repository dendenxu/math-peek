import Foundation

/// Terminal math extraction using Unicode scalar offsets; no helper process.
enum HoverMath {
    struct Extraction {
        let formula: String
        let sourceRanges: [Range<Int>]
    }

    static func extract(text: String, offset: Int) -> String? {
        match(text: text, offset: offset)?.formula
    }

    static func match(text: String, offset: Int) -> Extraction? {
        let input = Array(text.unicodeScalars)
        guard offset >= 0, offset < input.count else { return nil }
        let pane = project(input, offset)
        let source = pane?.text ?? input
        let cursor = pane?.offset ?? offset
        let delimited = expression(source, cursor, padding: pane != nil)
        guard let range = delimited ?? bare(source, cursor) else { return nil }
        let repaired = repairRows(repair(Array(source[range]), padding: pane != nil, continuationIndent: delimited == nil))
        let sourceRanges = pane.map { originalRanges(for: range, offsets: $0.sourceOffsets) } ?? [range]
        guard !sourceRanges.isEmpty else { return nil }
        return Extraction(formula: normalizeMarkdownDelimiters(repaired), sourceRanges: sourceRanges)
    }

    private typealias Scalars = [Unicode.Scalar]
    private struct Pane { let text: Scalars; let offset: Int; let sourceOffsets: [Int?] }
    private struct Row { let start: Int; let end: Int }
    private struct Border: Equatable { let column: Int; let index: Int }
    private static let verticalBorders = Set((0x2500...0x257F).compactMap(Unicode.Scalar.init).filter {
        let name = $0.properties.name ?? ""
        return name.contains("VERTICAL") || name.contains("UP") && name.contains("DOWN")
    })
    private static let commands = Set("""
    frac dfrac tfrac sqrt sum prod coprod int iint iiint oint lim limits nolimits
    infty partial nabla cdot times div pm mp le leq ge geq ne neq approx equiv sim circ
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
    textcolor underbracket overbracket bracevert choose atop not accentset quad qquad
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    private static let commandPrefixes: Set<String> = {
        Set(commands.flatMap { command in (1...command.count).map { String(command.prefix($0)) } })
    }()
    private static let rowEnvironments = Set("matrix pmatrix bmatrix Bmatrix vmatrix Vmatrix smallmatrix aligned alignedat align align* gather gathered cases array split".split(separator: " ").map(String.init))
    private static let textArguments = Set("text textrm textbf textit textsf texttt textnormal mbox hbox mathrm operatorname mathsf mathbf mathit mathbb mathcal".split(separator: " ").map(String.init))

    private static func regex(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        (try? NSRegularExpression(pattern: pattern).matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))) ?? []
    }
    private static func replace(_ pattern: String, _ text: String, with replacement: String) -> String {
        (try? NSRegularExpression(pattern: pattern).stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: replacement)) ?? text
    }
    private static func escapedString(_ text: String, at offset: Int) -> Bool {
        (text as NSString).substring(to: offset).reversed().prefix(while: { $0 == "\\" }).count % 2 == 1
    }
    private static func repairRows(_ text: String) -> String {
        var active: [String] = []
        var depth = 0
        return text.components(separatedBy: "\n").map { original in
            var row = original
            let rowDepth = depth
            depth += braceBalance(original)
            func depthAt(_ offset: Int) -> Int { rowDepth + braceBalance((original as NSString).substring(to: offset)) }
            for match in regex(#"\\(begin|end)\{([^{}]+)\}"#, row) where !escapedString(row, at: match.range.location) {
                let operation = (row as NSString).substring(with: match.range(at: 1))
                let environment = (row as NSString).substring(with: match.range(at: 2))
                if operation == "begin" { active.append(environment) }
                else if active.last == environment { active.removeLast() }
            }
            guard active.contains(where: { rowEnvironments.contains($0) }) else { return row }
            if let spacing = regex(#"\\\[([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:pt|em|ex|mm|cm|in|mu))\]\s*$"#, row).first,
               depthAt(spacing.range.location) == 0,
               !escapedString(row, at: spacing.range.location) {
                row = (row as NSString).replacingCharacters(in: NSRange(location: spacing.range.location, length: 0), with: "\\")
            } else if let ending = regex(#"\\[ \t\r]*$"#, row).first,
                      depthAt(ending.range.location) == 0,
                      !escapedString(row, at: ending.range.location),
                      active.contains(where: { $0.hasSuffix("matrix") }) || regex("&", row).contains(where: { !escapedString(row, at: $0.range.location) }) {
                row = (row as NSString).replacingCharacters(in: NSRange(location: ending.range.location, length: 0), with: "\\")
            }
            return row
        }.joined(separator: "\n")
    }

    private static func displayContainsProse(_ source: Scalars, padding: Bool) -> Bool {
        // Inspect repaired commands so a tmux wrap inside \text cannot expose
        // its argument as apparent prose and discard the surrounding formula.
        let body = Array(repair(source, padding: padding).unicodeScalars)
        var masked = body
        var index = 0
        while index < body.count {
            defer { index += 1 }
            guard body[index] == "\\", !escaped(body, index) else { continue }
            var nameEnd = index + 1
            while nameEnd < body.count && letter(body[nameEnd]) { nameEnd += 1 }
            guard textArguments.contains(string(body[(index + 1)..<nameEnd])) else { continue }
            var start = nameEnd
            while start < body.count && body[start].properties.isWhitespace { start += 1 }
            guard start < body.count && body[start] == "{" else { continue }
            var depth = 1
            var end = start + 1
            while end < body.count && depth != 0 {
                if !escaped(body, end) { depth += body[end] == "{" ? 1 : body[end] == "}" ? -1 : 0 }
                end += 1
            }
            if depth == 0 {
                for position in index..<end where !newline(masked[position]) { masked[position] = " " }
                index = end - 1
            }
        }
        let prose = replace(#"\\[A-Za-z]+"#, string(masked), with: "x")
        return !regex(#"(?m)^[ \t]{0,3}#{1,6}(?:[ \t]|$)|^[ \t]*(?:[A-Za-z]{3,}(?:[ \t]+[A-Za-z]+)+[.?:]|[A-Za-z]{3,}:)[ \t]*$|[\u3400-\u9fff]{2,}"#, prose).isEmpty
    }

    private static func bareSource(_ candidate: String) -> Bool {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, candidate.unicodeScalars.count <= 2048,
              !candidate.contains(where: { "`$\"';@#".contains($0) }),
              !candidate.unicodeScalars.contains(where: { (0x2500...0x257F).contains($0.value) }) else { return false }
        let scalars = Array(candidate.unicodeScalars)
        var depth = 0
        for index in scalars.indices where !escaped(scalars, index) {
            if scalars[index] == "{" { depth += 1 }
            else if scalars[index] == "}" { depth -= 1 }
            else if scalars[index] == "|" && depth <= 0 { return false }
        }
        var reduced = replace(#"\\(?:text|textrm|mathrm|operatorname|mathbb|mathbf|mathit|mathcal|mathsf|mathtt)\{[^{}]*\}"#, candidate, with: "x")
        reduced = replace(#"\\[A-Za-z]+"#, reduced, with: "x")
        guard regex(#"[A-Za-z]{3,}|[^\x00-\x7f]"#, reduced).isEmpty,
              regex(#"\b(?:if|for|in|let|var|fn|def|return|echo|print|const)\b"#, reduced).isEmpty,
              !regex(#"^[A-Za-z0-9\s\\{}()\[\]=+*/^_.,:!<>?&%|-]+$"#, reduced).isEmpty else { return false }
        return true
    }
    private static func braceBalance(_ text: String) -> Int {
        let scalars = Array(text.unicodeScalars)
        return scalars.indices.reduce(0) { balance, index in
            guard !escaped(scalars, index) else { return balance }
            return balance + (scalars[index] == "{" ? 1 : scalars[index] == "}" ? -1 : 0)
        }
    }
    private static func bareJoin(_ left: String, _ right: String) -> Bool {
        guard bareSource(left), bareSource(right) else { return false }
        if braceBalance(left) > 0 || !regex(#"[=+*/^_({\[,<>-]\s*$"#, left).isEmpty || !regex(#"^\s*[=+*/^_)}\],<>-]"#, right).isEmpty { return true }
        guard let command = regex(#"\\([A-Za-z]+)[ \t\r]*$"#, left).first,
              let rest = regex(#"^[ \t]*([A-Za-z]+)"#, right).first else { return false }
        let prefix = (left as NSString).substring(with: command.range(at: 1))
        let suffix = (right as NSString).substring(with: rest.range(at: 1))
        if commands.contains(prefix), !regex(#"^[ \t]*[A-Za-z][ \t\r]*$"#, right).isEmpty { return true }
        return !commands.contains(prefix) && commands.contains(prefix + suffix)
    }
    private static func bare(_ text: Scalars, _ offset: Int) -> Range<Int>? {
        guard !insideCode(text, offset) else { return nil }
        var start = offset, end = offset
        while start > 0 && text[start - 1] != "\n" { start -= 1 }
        while end < text.count && text[end] != "\n" { end += 1 }
        for _ in 0..<3 {
            guard start > 0 else { break }
            var previous = start - 1
            while previous > 0 && text[previous - 1] != "\n" { previous -= 1 }
            guard bareJoin(string(text[previous..<(start - 1)]), string(text[start..<end])) else { break }
            start = previous
        }
        for _ in 0..<3 {
            guard end < text.count else { break }
            var following = end + 1
            while following < text.count && text[following] != "\n" { following += 1 }
            guard bareJoin(string(text[start..<end]), string(text[(end + 1)..<following])) else { break }
            end = following
        }
        while start < end && text[start].properties.isWhitespace { start += 1 }
        while end > start && text[end - 1].properties.isWhitespace { end -= 1 }
        guard start <= offset, offset < end else { return nil }
        let candidate = repair(Array(text[start..<end]), padding: false, continuationIndent: true)
        guard bareSource(candidate), braceBalance(candidate) == 0,
              regex(#"\\([A-Za-z]+)"#, candidate).contains(where: { commands.contains((candidate as NSString).substring(with: $0.range(at: 1))) }),
              !regex(#"[=+*/^_{}]"#, candidate).isEmpty else { return inlineBoxed(text, offset) }
        return start..<end
    }

    private static func inlineBoxed(_ text: Scalars, _ offset: Int) -> Range<Int>? {
        var index = 0
        let command = Array("\\boxed".unicodeScalars)
        while index <= offset {
            if (index == 0 || text[index - 1] == "\n"), let end = skipFence(text, index) {
                index = end
                continue
            }
            if text[index] == "`", !escaped(text, index), let end = skipCode(text, index) {
                index = end
                continue
            }
            guard matches(text, command, at: index), !escaped(text, index) else { index += 1; continue }
            var opening = index + command.count
            while opening < text.count && text[opening].properties.isWhitespace { opening += 1 }
            guard opening < text.count, text[opening] == "{" else { index += command.count; continue }
            var depth = 1
            var end = opening + 1
            let limit = min(text.count, index + 2048)
            while end < limit && depth > 0 {
                if !escaped(text, end) { depth += text[end] == "{" ? 1 : text[end] == "}" ? -1 : 0 }
                end += 1
            }
            // Do not extract an inner fragment from an unfinished outer box.
            guard depth == 0 else { return nil }
            if index <= offset && offset < end {
                var lineStart = index
                while lineStart > 0 && text[lineStart - 1] != "\n" { lineStart -= 1 }
                let prefix = string(text[lineStart..<index])
                let prefixScalars = Array(prefix.unicodeScalars)
                let quoteCount = prefixScalars.indices.filter { prefixScalars[$0] == "\"" && !escaped(prefixScalars, $0) }.count
                guard quoteCount % 2 == 0, regex(#"^\s*(?:[>$%]\s*)?(?:(?:echo|printf|print|return|const|let|var|def|fn)\b|[A-Za-z_][A-Za-z0-9_]*\s*=)"#, prefix).isEmpty else { return nil }
                let candidate = repair(Array(text[index..<end]), padding: false, continuationIndent: true)
                return bareSource(candidate.replacingOccurrences(of: "'", with: "")) ? index..<end : nil
            }
            index = end
        }
        return nil
    }
    private static func insideCode(_ text: Scalars, _ offset: Int) -> Bool {
        var index = 0
        while index <= offset {
            if (index == 0 || text[index - 1] == "\n"), let end = skipFence(text, index) {
                if offset < end { return true }
                index = end
                continue
            }
            if text[index] == "`", !escaped(text, index), let end = skipCode(text, index) {
                if offset < end { return true }
                index = end
                continue
            }
            index += 1
        }
        return false
    }

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
            // An orphan closing $$ from clipped history must not consume the
            // next opening delimiter across intervening headings or prose.
            if opening == ["$", "$"], displayContainsProse(Array(body), padding: padding) { return nil }
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

    private static func shellVariableEnd(_ text: Scalars, _ start: Int) -> Int? {
        var end = start + 1
        let braced = end < text.count && text[end] == "{"
        if braced { end += 1 }
        let nameStart = end
        guard end < text.count, letter(text[end]) || text[end] == "_" else { return nil }
        while end < text.count && (letter(text[end]) || (48...57).contains(text[end].value) || text[end] == "_") { end += 1 }
        let name = text[nameStart..<end]
        if braced {
            guard end < text.count, text[end] == "}" else { return nil }
            end += 1
        }
        if end < text.count && text[end] == "$" { return nil }
        if end < text.count && text[end] == "/" {
            // A slash can also be division: preserve $x/y$ and $P/R$.
            var pathEnd = end + 1
            while pathEnd < text.count && !text[pathEnd].properties.isWhitespace &&
                    !["\"", "'", "$"].contains(text[pathEnd]) { pathEnd += 1 }
            if pathEnd + 1 < text.count, text[pathEnd] == "$",
               text[pathEnd - 1] == ":" || text[pathEnd - 1] == "/",
               letter(text[pathEnd + 1]) || text[pathEnd + 1] == "_" || text[pathEnd + 1] == "{" {
                return pathEnd
            }
            return pathEnd < text.count && text[pathEnd] == "$" ? nil : pathEnd
        }
        let variable = braced || name.count > 1 && name.allSatisfy { !letter($0) || (65...90).contains($0.value) }
        guard variable, end == text.count || text[end].properties.isWhitespace || text[end] == "\"" || text[end] == "'" else { return nil }
        return end
    }

    private static func isolatedLineToken(_ text: Scalars, _ index: Int, _ token: Unicode.Scalar,
                                          allowHeadingPrefix: Bool = false) -> Bool {
        guard index >= 0, index < text.count, text[index] == token else { return false }
        var start = index
        while start > 0 && !newline(text[start - 1]) { start -= 1 }
        var end = index + 1
        while end < text.count && !newline(text[end]) { end += 1 }
        let prefix = string(text[start..<index])
        let validPrefix = prefix.allSatisfy { $0 == " " || $0 == "\t" } ||
            allowHeadingPrefix && !regex(#"^[ \t]{0,3}#{1,6}[ \t]+$"#, prefix).isEmpty
        return validPrefix &&
            text[(index + 1)..<end].allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private static func stripMarkdownHeadingPrefixes(_ source: String) -> String {
        source.components(separatedBy: "\n").map {
            replace(#"^[ \t]{0,3}#{1,6}[ \t]+"#, $0, with: "")
        }.joined(separator: "\n")
    }

    // Some Markdown renderers consume the backslashes in display delimiters,
    // so `\[` and `\]` arrive through terminal accessibility as standalone
    // `[` and `]` lines. Recognize only a math-shaped, multi-line block; this
    // deliberately excludes ordinary prose and JSON/array formatting.
    private static func markdownDisplayClosing(_ text: Scalars, _ start: Int, padding: Bool) -> Int? {
        guard isolatedLineToken(text, start, "[", allowHeadingPrefix: true) else { return nil }
        let limit = min(text.count, start + 16384)
        var position = start + 1
        while position < limit {
            if text[position] == "`" { return nil }
            if text[position] == "]", isolatedLineToken(text, position, "]") {
                let body = Array(text[(start + 1)..<position])
                let source = stripMarkdownHeadingPrefixes(string(body))
                let cleanedBody = Array(source.unicodeScalars)
                guard body.contains(where: { !$0.properties.isWhitespace }),
                      body.reduce(0, { $0 + (newline($1) ? 1 : 0) }) < 80,
                      !body.contains(where: { (0x2500...0x257F).contains($0.value) }),
                      !source.contains(where: { "`\"';@".contains($0) }),
                      braceBalance(source) == 0, !displayContainsProse(cleanedBody, padding: padding),
                      regex(#"[=+*/^_{}<>]"#, source).first != nil else { return nil }
                let knownCommand = regex(#"\\([A-Za-z]+)"#, source).contains {
                    commands.contains((source as NSString).substring(with: $0.range(at: 1)))
                }
                if !knownCommand {
                    guard regex(#"[A-Za-z]{3,}|[^\x00-\x7f]"#, source).isEmpty,
                          regex(#"\b(?:if|for|in|let|var|fn|def|return|echo|print|const)\b"#, source).isEmpty else { return nil }
                }
                return position
            }
            position += 1
        }
        return nil
    }

    private static func normalizeMarkdownDisplay(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        guard lines.count >= 3, lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "[",
              lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "]" else { return source }
        let body = lines.dropFirst().dropLast().map(stripMarkdownHeadingPrefixes).joined(separator: "\n")
        return "\\[\n" + body + "\n\\]"
    }

    // Markdown can likewise turn `\(x\)` into `(x)` in terminal output.
    // Parentheses are common prose and programming syntax, so only recover a
    // balanced, math-shaped body containing a known TeX command.
    private static func markdownInlineClosing(_ text: Scalars, _ start: Int) -> Int? {
        guard text[start] == "(" else { return nil }
        var lineStart = start
        while lineStart > 0 && !newline(text[lineStart - 1]) { lineStart -= 1 }
        let prefix = string(text[lineStart..<start])
        guard regex(#"[A-Za-z0-9_)\]]$"#, prefix).isEmpty,
              regex(#"\b(?:if|for|while|switch|catch|print|printf|return|func|fn|def)\s*$"#, prefix).isEmpty else { return nil }
        var depth = 1
        var position = start + 1
        let limit = min(text.count, start + 2048)
        while position < limit {
            if text[position] == "`" || newline(text[position]) { return nil }
            if !escaped(text, position) {
                if text[position] == "(" { depth += 1 }
                else if text[position] == ")" {
                    depth -= 1
                    if depth == 0 {
                        let body = string(text[(start + 1)..<position])
                        guard bareSource(body), braceBalance(body) == 0,
                              regex(#"[=+*/^_{}<>]"#, body).first != nil,
                              regex(#"\\([A-Za-z]+)"#, body).contains(where: {
                                  commands.contains((body as NSString).substring(with: $0.range(at: 1)))
                              }) else { return nil }
                        return position
                    }
                }
            }
            position += 1
        }
        return nil
    }

    private static func normalizeMarkdownDelimiters(_ source: String) -> String {
        let display = normalizeMarkdownDisplay(source)
        if display != source { return display }
        guard source.hasPrefix("("), source.hasSuffix(")"), source.count >= 3 else { return source }
        return "\\(" + source.dropFirst().dropLast() + "\\)"
    }

    private static func expression(_ text: Scalars, _ offset: Int, padding: Bool) -> Range<Int>? {
        var i = 0
        while i < text.count && i <= offset {
            if (i == 0 || text[i - 1] == "\n"), let end = skipFence(text, i) { i = end; continue }
            if text[i] == "`", !escaped(text, i), let end = skipCode(text, i) { i = end; continue }
            if text[i] == "$", !escaped(text, i), let end = shellVariableEnd(text, i) {
                // A variable or path prefix is also legal TeX. Keep complete
                // math such as $P/R + Q$ before skipping shell expansions.
                let closingDollar = closing(text, opening: ["$"], closing: ["$"], start: i, padding: padding)
                let crossesQuotedArguments = closingDollar.map {
                    !regex(#"(["'])\s+\1$"#, string(text[(i + 1)..<$0])).isEmpty
                } ?? false
                if closingDollar == nil || closingDollar == end || crossesQuotedArguments { i = end; continue }
            }
            var opening: Scalars = []
            var close: Scalars = []
            if !escaped(text, i) {
                if matches(text, ["$", "$"], at: i) { opening = ["$", "$"]; close = opening }
                else if matches(text, ["\\", "["], at: i) { opening = ["\\", "["]; close = ["\\", "]"] }
                else if matches(text, ["\\", "("], at: i) { opening = ["\\", "("]; close = ["\\", ")"] }
                else if text[i] == "[", let end = markdownDisplayClosing(text, i, padding: padding) {
                    let after = end + 1
                    if i <= offset && offset < after { return i..<after }
                    i = after
                    continue
                }
                else if text[i] == "(", let end = markdownInlineClosing(text, i) {
                    let after = end + 1
                    if i <= offset && offset < after { return i..<after }
                    i = after
                    continue
                }
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

    private static func repair(_ text: Scalars, padding: Bool, continuationIndent: Bool = false) -> String {
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
                if padding || continuationIndent { while fragment < text.count && text[fragment] == " " { fragment += 1 } }
                if fragment < text.count && text[fragment] == "\r" { fragment += 1 }
                guard fragment < text.count && text[fragment] == "\n" else { break }
                fragment += 1
                if continuationIndent { while fragment < text.count && (text[fragment] == " " || text[fragment] == "\t") { fragment += 1 } }
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
    private static func originalRanges(for range: Range<Int>, offsets: [Int?]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for projected in range {
            guard offsets.indices.contains(projected), let original = offsets[projected] else { continue }
            if let last = result.last, last.upperBound == original {
                result[result.count - 1] = last.lowerBound..<(original + 1)
            } else {
                result.append(original..<(original + 1))
            }
        }
        return result
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
                if verticalBorders.contains(scalar) { borders.append(Border(column: column, index: i)) }
                column += width(scalar)
            }
            cache[rowIndex] = borders
            return borders
        }
        guard let borders = layout(cursorRow), !borders.isEmpty,
              offset < rows[cursorRow].end, !borders.contains(where: { $0.index == offset }) else { return nil }
        let left = borders.last(where: { $0.index < offset })?.column
        let right = borders.first(where: { $0.index > offset })?.column
        func same(_ row: Int) -> Bool {
            guard let candidate = layout(row),
                  left == nil || candidate.contains(where: { $0.column == left }),
                  right == nil || candidate.contains(where: { $0.column == right }) else { return false }
            // Ignore other panes' log decorations, but never cross a new border
            // inside the hovered pane.
            return !candidate.contains { border in
                (left == nil || border.column > left!) && (right == nil || border.column < right!)
            }
        }
        var first = cursorRow, last = cursorRow
        while first > 0 && same(first - 1) { first -= 1 }
        while last + 1 < rows.count && same(last + 1) { last += 1 }
        guard last - first + 1 >= 3 else { return nil }
        var projected: Scalars = []
        var sourceOffsets: [Int?] = []
        var projectedOffset = 0
        for index in first...last {
            guard let rowLayout = layout(index) else { return nil }
            let begin = left.flatMap { c in rowLayout.first(where: { $0.column == c })?.index }.map { $0 + 1 } ?? rows[index].start
            let end = right.flatMap { c in rowLayout.first(where: { $0.column == c })?.index } ?? rows[index].end
            if index == cursorRow { projectedOffset = projected.count + offset - begin }
            projected.append(contentsOf: text[begin..<end])
            sourceOffsets.append(contentsOf: (begin..<end).map(Optional.some))
            if index < last {
                projected.append("\n")
                sourceOffsets.append(nil)
            }
        }
        return Pane(text: projected, offset: projectedOffset, sourceOffsets: sourceOffsets)
    }
}

import Foundation

/// Terminal math extraction using Unicode scalar offsets; no helper process.
enum HoverMath {
    private static let compatibilityCache = FormulaDocumentCache()
    enum Kind: Int, Comparable {
        case bare = 0
        case clippedDisplay = 1
        case recovered = 2
        case delimited = 3

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Block: Equatable {
        let formula: String
        let range: Range<Int>
        let kind: Kind
    }

    struct Index {
        fileprivate let blocks: [Block]

        func block(containing offset: Int) -> Block? {
            blocks.filter { $0.range.contains(offset) }.max { left, right in
                if left.kind != right.kind { return left.kind < right.kind }
                if left.range.count != right.range.count { return left.range.count < right.range.count }
                return left.range.lowerBound > right.range.lowerBound
            }
        }
    }

    struct Extraction {
        let formula: String
        let sourceRanges: [Range<Int>]
        let kind: Kind
    }

    static func extract(text: String, offset: Int) -> String? {
        match(text: text, offset: offset)?.formula
    }

    static func match(text: String, offset: Int) -> Extraction? {
        compatibilityCache.match(text: text, at: offset)
    }

    /// Parse an immutable logical terminal document once. Pointer movement only
    /// queries this index; it never changes formula boundaries or completeness.
    static func makeIndex(text: String, panePadding: Bool,
                          allowsClippedTop: Bool = true, allowsClippedBottom: Bool = true) -> Index {
        let source = Array(text.unicodeScalars)
        guard !source.isEmpty else { return Index(blocks: []) }
        var blocks: [Block] = []
        for candidate in delimitedBlocks(source, padding: panePadding) {
            let repaired = repairRows(repair(Array(source[candidate.range]), padding: panePadding))
            blocks.append(Block(formula: normalizeMarkdownDelimiters(repaired),
                                range: candidate.range, kind: candidate.kind))
        }
        blocks.append(contentsOf: clippedDisplayBlocks(
            source, padding: panePadding, existing: blocks,
            allowsTop: allowsClippedTop, allowsBottom: allowsClippedBottom))
        let unresolvedDisplayBoundary = hasUnresolvedDisplayBoundary(source, blocks: blocks)

        // Bare TeX is deliberately last. Probe each physical row once, plus
        // explicit boxed occurrences that may sit inside prose. Any overlap
        // with a stronger block is discarded rather than exposed as a fragment.
        var probes = Set<Int>()
        var rowStart = 0
        for index in 0...source.count where index == source.count || source[index] == "\n" {
            let row = rowStart..<index
            // Every accepted bare formula must ultimately contain a known TeX
            // command. Skip ordinary terminal rows before running regex-heavy
            // joining and classification; wrapped commands are still reached
            // from the row that contains their initial backslash.
            let commandSignal = row.contains { position in
                source[position] == "\\" && !escaped(source, position) &&
                    position + 1 < index && letter(source[position + 1])
            }
            if commandSignal, let first = row.first(where: { !source[$0].properties.isWhitespace }) { probes.insert(first) }
            rowStart = index + 1
        }
        let boxed = Array("\\boxed".unicodeScalars)
        if source.count >= boxed.count {
            for index in 0...(source.count - boxed.count) where matches(source, boxed, at: index) { probes.insert(index) }
        }
        var bareRanges = Set<String>()
        for probe in unresolvedDisplayBoundary ? [] : probes.sorted() {
            guard let range = bare(source, probe) else { continue }
            let repaired = repairRows(repair(Array(source[range]), padding: panePadding, continuationIndent: true))
            let key = "\(range.lowerBound):\(range.upperBound):\(repaired)"
            guard bareRanges.insert(key).inserted,
                  !blocks.contains(where: { $0.kind > .bare && $0.range.overlaps(range) }) else { continue }
            blocks.append(Block(formula: normalizeMarkdownDelimiters(repaired), range: range, kind: .bare))
        }

        // Exact duplicates can arise from repaired terminal rows. Stable source
        // order plus explicit priority makes the index deterministic.
        var seen = Set<String>()
        blocks = blocks.filter { block in
            seen.insert("\(block.kind.rawValue):\(block.range.lowerBound):\(block.range.upperBound):\(block.formula)").inserted
        }.sorted { left, right in
            if left.range.lowerBound != right.range.lowerBound { return left.range.lowerBound < right.range.lowerBound }
            if left.kind != right.kind { return left.kind > right.kind }
            return left.range.count > right.range.count
        }
        return Index(blocks: blocks)
    }

    private static func hasUnresolvedDisplayBoundary(_ text: Scalars, blocks: [Block]) -> Bool {
        guard text.count >= 2 else { return false }
        for index in 0..<(text.count - 1) where matches(text, ["$", "$"], at: index) && !escaped(text, index) {
            var lineStart = index
            while lineStart > 0 && !newline(text[lineStart - 1]) { lineStart -= 1 }
            let prefix = string(text[lineStart..<index])
            // Inline double-dollar math is handled by normal delimiter pairing.
            guard prefix.allSatisfy({ $0 == " " || $0 == "\t" }) else { continue }
            if !blocks.contains(where: { $0.kind > .bare && $0.range.contains(index) }) { return true }
        }
        return false
    }

    private typealias Scalars = [Unicode.Scalar]
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
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, candidate.unicodeScalars.count <= 16_384,
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
        for _ in 0..<80 {
            guard start > 0 else { break }
            var previous = start - 1
            while previous > 0 && text[previous - 1] != "\n" { previous -= 1 }
            guard end - previous <= 16_384 else { break }
            guard bareJoin(string(text[previous..<(start - 1)]), string(text[start..<end])) else { break }
            start = previous
        }
        for _ in 0..<80 {
            guard end < text.count else { break }
            var following = end + 1
            while following < text.count && text[following] != "\n" { following += 1 }
            guard following - start <= 16_384 else { break }
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
            allowHeadingPrefix && !regex(#"^[ \t]{0,3}(?:#{1,6}|[>›•])[ \t]+$"#, prefix).isEmpty
        return validPrefix &&
            text[(index + 1)..<end].allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private static func knownCommand(in source: String) -> Bool {
        regex(#"\\([A-Za-z]+)"#, source).contains {
            commands.contains((source as NSString).substring(with: $0.range(at: 1)))
        }
    }

    private static func compactScriptSource(_ source: String) -> Bool {
        !regex(#"^[A-Za-z](?:(?:\^|_)(?:[A-Za-z0-9]|\{[A-Za-z0-9,+*/.-]+\})){1,2}$"#, source).isEmpty
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
                      !source.contains(where: { "`\";@".contains($0) }),
                      braceBalance(source) == 0, !displayContainsProse(cleanedBody, padding: padding) else { return nil }
                let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
                let command = knownCommand(in: source)
                let simpleAtom = !regex(#"^(?:[A-Za-z]|[0-9]+(?:\.[0-9]+)?)$"#, trimmed).isEmpty
                let compactScripts = compactScriptSource(trimmed)
                let explicitStructure = regex(#"[=+*/^_{}<>]"#, source).first != nil
                guard command || simpleAtom || compactScripts || explicitStructure else { return nil }
                if !command && !simpleAtom && !compactScripts {
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
                        let command = knownCommand(in: body)
                        let compactScripts = compactScriptSource(body)
                        let singleVariable = !regex(#"^[A-Za-z]$"#, body).isEmpty
                        let scalarAtom = !regex(#"^(?:[0-9]+(?:\.[0-9]+)?|[\u0370-\u03ff])$"#, body).isEmpty
                        let primeAtom = !regex(#"^[A-Za-z](?:')+$"#, body).isEmpty
                        let functionNotation = !regex(
                            #"^[A-Za-z](?:_[A-Za-z0-9]|_\{[A-Za-z0-9,]+\})?\([^()\s]+\)(?:[A-Za-z](?:_[A-Za-z0-9]|_\{[A-Za-z0-9,]+\})?)?$"#,
                            body).isEmpty
                        let explicitStructure = bareSource(body) &&
                            regex(#"[=+*/^_{}<>]"#, body).first != nil
                        guard braceBalance(body) == 0,
                              (command && bareSource(body) || compactScripts ||
                               singleVariable || scalarAtom || primeAtom || functionNotation ||
                               explicitStructure) else { return nil }
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

    private static func delimitedBlocks(_ text: Scalars, padding: Bool) -> [(range: Range<Int>, kind: Kind)] {
        var result: [(Range<Int>, Kind)] = []
        var index = 0
        while index < text.count {
            if (index == 0 || text[index - 1] == "\n"), let end = skipFence(text, index) { index = end; continue }
            if text[index] == "`", !escaped(text, index), let end = skipCode(text, index) { index = end; continue }
            if text[index] == "$", !escaped(text, index), let end = shellVariableEnd(text, index) {
                let dollar = closing(text, opening: ["$"], closing: ["$"], start: index, padding: padding)
                let quoted = dollar.map { !regex(#"(["'])\s+\1$"#, string(text[(index + 1)..<$0])).isEmpty } ?? false
                if dollar == nil || dollar == end || quoted { index = end; continue }
            }
            var opening: Scalars = []
            var close: Scalars = []
            if !escaped(text, index) {
                if matches(text, ["$", "$"], at: index) { opening = ["$", "$"]; close = opening }
                else if matches(text, ["\\", "["], at: index) { opening = ["\\", "["]; close = ["\\", "]"] }
                else if matches(text, ["\\", "("], at: index) { opening = ["\\", "("]; close = ["\\", ")"] }
                else if text[index] == "[", let end = markdownDisplayClosing(text, index, padding: padding) {
                    let after = end + 1
                    result.append((index..<after, .recovered)); index = after; continue
                }
                else if text[index] == "(", let end = markdownInlineClosing(text, index) {
                    let after = end + 1
                    result.append((index..<after, .recovered)); index = after; continue
                }
                else if text[index] == "$", let after = acrossWrap(text, index + 1, step: 1, padding: padding),
                        !after.properties.isWhitespace {
                    let before: Unicode.Scalar? = index > 0 ? text[index - 1] : nil
                    let word = before.map { letter($0) || (48...57).contains($0.value) || $0 == "_" } ?? false
                    if before != "$" && !word { opening = ["$"]; close = opening }
                }
            }
            if !opening.isEmpty {
                if let end = closing(text, opening: opening, closing: close, start: index, padding: padding) {
                    let after = end + close.count
                    result.append((index..<after, .delimited)); index = after; continue
                }
                index += opening.count
            } else { index += 1 }
        }
        return result
    }

    /// Recover only a formula clipped by the top or bottom of a logical pane.
    /// It must touch a document edge and an unmatched display delimiter; this
    /// never creates a free-floating fragment in the middle of ordinary prose.
    private static func clippedDisplayBlocks(_ text: Scalars, padding: Bool, existing: [Block],
                                             allowsTop: Bool, allowsBottom: Bool) -> [Block] {
        struct Line { let start: Int; let end: Int }
        var lines: [Line] = []
        var start = 0
        for index in 0...text.count where index == text.count || text[index] == "\n" {
            let end = index > start && text[index - 1] == "\r" ? index - 1 : index
            lines.append(Line(start: start, end: end)); start = index + 1
        }
        guard !lines.isEmpty else { return [] }
        func trimmed(_ line: Line) -> Range<Int> {
            var lower = line.start, upper = line.end
            while lower < upper && text[lower].properties.isWhitespace { lower += 1 }
            while upper > lower && text[upper - 1].properties.isWhitespace { upper -= 1 }
            return lower..<upper
        }
        func delimiter(_ line: Line) -> Range<Int>? {
            let range = trimmed(line)
            guard range.count >= 2, matches(text, ["$", "$"], at: range.lowerBound) else { return nil }
            // Terminal copies and bug reports often append prose after the
            // visible closing delimiter. The candidate ends before that prose.
            return range.lowerBound..<(range.lowerBound + 2)
        }
        func strongBody(_ range: Range<Int>) -> String? {
            guard !range.isEmpty, range.count <= 16_384 else { return nil }
            let body = repairRows(repair(Array(text[range]), padding: padding, continuationIndent: true))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty, braceBalance(body) == 0,
                  !displayContainsProse(Array(body.unicodeScalars), padding: padding),
                  knownCommand(in: body), regex(#"[=+*/^_{}<>]|\\(?:left|right|begin|end)"#, body).first != nil else { return nil }
            return body
        }
        let tokens: [(line: Int, range: Range<Int>)] = lines.indices.compactMap { line in
            delimiter(lines[line]).map { (line, $0) }
        }
        var result: [Block] = []
        for (tokenIndex, token) in tokens.enumerated() {
            guard !existing.contains(where: { $0.kind > .bare && $0.range.contains(token.range.lowerBound) }) else { continue }
            let previousLine = tokenIndex > 0 ? tokens[tokenIndex - 1].line : nil
            let nextLine = tokenIndex + 1 < tokens.count ? tokens[tokenIndex + 1].line : nil
            var candidates: [Block] = []

            // Treat this token as a closing delimiter. The visible body begins
            // at the pane edge or immediately after the previous known token.
            if previousLine != nil || allowsTop {
                let lowerLine = (previousLine ?? -1) + 1
                if lowerLine < token.line,
                   let firstContent = (lowerLine..<token.line).first(where: { !trimmed(lines[$0]).isEmpty }) {
                    let bodyRange = lines[firstContent].start..<lines[token.line].start
                    if let body = strongBody(bodyRange) {
                        candidates.append(Block(formula: "$$\n" + body + "\n$$",
                                                range: lines[firstContent].start..<token.range.upperBound,
                                                kind: .clippedDisplay))
                    }
                }
            }

            // Treat this token as an opening delimiter. The visible body ends
            // at the next known token or the pane edge.
            if nextLine != nil || allowsBottom {
                let upperLine = nextLine ?? lines.count
                if token.line + 1 < upperLine,
                   let lastContent = (token.line + 1..<upperLine).reversed().first(where: { !trimmed(lines[$0]).isEmpty }) {
                    let bodyRange = lines[token.line].end..<lines[lastContent].end
                    if let body = strongBody(bodyRange) {
                        candidates.append(Block(formula: "$$\n" + body + "\n$$",
                                                range: token.range.lowerBound..<lines[lastContent].end,
                                                kind: .clippedDisplay))
                    }
                }
            }
            // A delimiter that could plausibly open and close two different
            // formulas is ambiguous; showing neither is safer than a wrong one.
            if candidates.count == 1 { result.append(candidates[0]) }
        }
        return result
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

}

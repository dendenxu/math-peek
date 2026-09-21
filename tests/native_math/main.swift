import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.count == 2, arguments[0] == "--probe" {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8),
          let range = text.range(of: arguments[1]) else {
        print("PROBE needle not found")
        exit(2)
    }
    let offset = text[..<range.lowerBound].unicodeScalars.count
    if let match = HoverMath.match(text: text, offset: offset) {
        print("PROBE formula=" + String(reflecting: match.formula))
        print("PROBE sourceRanges=" + String(describing: match.sourceRanges))
        exit(0)
    }
    print("PROBE no formula at offset \(offset)")
    exit(1)
}

struct Fixture: Decodable {
    let name: String?
    let text: String
    let offset: Int?
    let offsets: [Int]?
    let expected: String?
    let segments: [String]?
}

let path = arguments.first ?? "tests/native_math/fixtures.json"
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
var failures = 0
var checks = 0
let began = Date()
for fixture in fixtures {
    var samples = (fixture.offsets ?? fixture.offset.map({ [$0] }) ?? []).map { ($0, fixture.expected) }
    if let segments = fixture.segments {
        let scalars = Array(fixture.text.unicodeScalars)
        var expectations = [String?](repeating: nil, count: scalars.count)
        for segment in segments {
            let needle = Array(segment.unicodeScalars)
            precondition(!needle.isEmpty && needle.count <= scalars.count, "Invalid segment in \(fixture.name ?? "fixture")")
            var found = false
            for start in 0...(scalars.count - needle.count)
                where scalars[start..<(start + needle.count)].elementsEqual(needle) {
                found = true
                for offset in start..<(start + needle.count) {
                    precondition(expectations[offset] == nil || expectations[offset] == segment,
                                 "Overlapping segments in \(fixture.name ?? "fixture")")
                    expectations[offset] = segment
                }
            }
            precondition(found, "Missing segment in \(fixture.name ?? "fixture")")
        }
        // Check every Unicode scalar, surrounding prose, and both bounds.
        samples += (-1...scalars.count).map { offset in
            (offset, expectations.indices.contains(offset) ? expectations[offset] : nil)
        }
    }
    precondition(!samples.isEmpty, "No offsets in \(fixture.name ?? "fixture")")
    for (offset, expected) in samples {
        checks += 1
        let result = HoverMath.extract(text: fixture.text, offset: offset)
        if result != expected {
            failures += 1
            print("FAIL \(fixture.name ?? "fixture") offset=\(offset): expected \(String(reflecting: expected)), got \(String(reflecting: result))")
        }
    }
}

let splitPaneHeadingSource = #"""
left│  反方向则是：
left│
left│  # [
left│  A_{j\leftarrow i}
left│
left│  \operatorname{softmax}_i
left│  \left(
left│  \frac{
left│  \langle R(p_j)q_j,\ R(p_i)k_i\rangle
left│  }{\sqrt d}
left│  \right)
left│  ]
left│  后文
"""#
let commandRange = splitPaneHeadingSource.range(of: #"\operatorname"#).map {
    splitPaneHeadingSource[..<$0.lowerBound].unicodeScalars.count
}
checks += 1
if let offset = commandRange, let result = HoverMath.extract(text: splitPaneHeadingSource, offset: offset),
   result.hasPrefix("\\["), result.hasSuffix("\\]"),
   result.contains(#"\operatorname{softmax}_i"#), !result.contains("# "), !result.contains("left│") {
    // Complete iTerm2/tmux pane projection with Markdown heading artifacts.
} else {
    failures += 1
    print("FAIL split-pane-markdown-heading-display: expected complete projected formula")
}
let splitPaneInlineSource = #"""
left│  前文
left│
left│  例如，陀螺仪预测身体倾角为 (10.6^\circ)，加速度计估计为 (9^\circ)：
left│
left│  后文
"""#
let inlineRange = splitPaneInlineSource.range(of: #"10.6^\circ"#).map {
    splitPaneInlineSource[..<$0.lowerBound].unicodeScalars.count
}
checks += 1
if let offset = inlineRange,
   HoverMath.extract(text: splitPaneInlineSource, offset: offset) == #"\(10.6^\circ\)"# {
    // Inline recovery also survives iTerm2/tmux pane projection.
} else {
    failures += 1
    print("FAIL split-pane-markdown-inline: expected projected inline formula")
}
let compactScriptSource = "left│  记作 (W^Q_l)，用于 query 投影。\nleft│  后文"
let compactScriptOffset = compactScriptSource.range(of: "W^Q_l").map {
    compactScriptSource[..<$0.lowerBound].unicodeScalars.count
}
checks += 1
if let offset = compactScriptOffset,
   HoverMath.extract(text: compactScriptSource, offset: offset) == #"\(W^Q_l\)"# {
    // Compact superscript/subscript recovery survives pane projection.
} else {
    failures += 1
    print("FAIL split-pane-compact-scripts: expected projected inline formula")
}
let primeBlockSource = #"""
left│  [
left│    h_i' = h_i+
left│    g^{attn}_{l,m_i,\tau_i}\odot
left│    \operatorname{Attention}(z)_i
left│  ]
left│  后文
"""#
let primeBlockOffset = primeBlockSource.range(of: #"\operatorname{Attention}"#).map {
    primeBlockSource[..<$0.lowerBound].unicodeScalars.count
}
checks += 1
if let offset = primeBlockOffset, let formula = HoverMath.extract(text: primeBlockSource, offset: offset),
   formula.hasPrefix("\\["), formula.hasSuffix("\\]"),
   formula.contains("h_i' = h_i+"), formula.contains(#"g^{attn}_{l,m_i,\tau_i}\odot"#),
   formula.contains(#"\operatorname{Attention}(z)_i"#) {
    // TeX prime does not make a confirmed display block fall back to one line.
} else {
    failures += 1
    print("FAIL split-pane-prime-display: expected all display rows")
}
let reportedBlocks: [(String, String, [String])] = [
    (#"""
› [
  96768=3\text{ 个模态}\times6\text{ 组参数}\times5376
  ]
"""#, #"96768=3\text"#, ["96768", #"3\text{ 个模态}"#, #"5376"#]),
    (#"""
# [
\theta_{\text{gyro}}

\theta_t+\omega_t\Delta t
]
"""#, #"\omega_t"#, [#"\theta_{\text{gyro}}"#, #"\theta_t+\omega_t\Delta t"#]),
    (#"""
# [
\theta_{t+\Delta t}

\alpha\theta_{\text{gyro}}
+
(1-\alpha)\theta_{\text{acc}}
]
"""#, #"\theta_{t+"#, [#"\theta_{t+\Delta t}"#, #"(1-\alpha)\theta_{\text{acc}}"#]),
    (#"""
# [
96768

3\text{ 种模态}
\times
6\text{ 组参数}
\times
5376\text{ 维}
]
"""#, #"5376\text"#, ["96768", #"3\text{ 种模态}"#, #"5376\text{ 维}"#]),
]
for (index, item) in reportedBlocks.enumerated() {
    let offset = item.0.range(of: item.1).map { item.0[..<$0.lowerBound].unicodeScalars.count }
    checks += 1
    if let offset, let formula = HoverMath.extract(text: item.0, offset: offset),
       formula.hasPrefix("\\["), formula.hasSuffix("\\]"),
       item.2.allSatisfy(formula.contains) {
        // Preserve every row from the exact reported formula block.
    } else {
        failures += 1
        print("FAIL exact-reported-display-\(index): expected all display rows")
    }
}

let inlineMatrix = [
    "i", "j", "42", "3.14", "α", "x'", "x_i", "x^2", "T^{-1}",
    "W^Q_l", "W_{Q,video}", "W_{Q,audio}",
    #"c_{\mathrm{ref}}"#, #"10.6^\circ"#, #"\theta_{\text{acc}}"#,
    "x+y", "a/b", #"\frac{a}{b}"#, "f(x)", "R(p_i)q_i", #"\langle x,y\rangle"#,
]
for body in inlineMatrix {
    let expected = "\\(" + body + "\\)"
    for (prefix, suffix) in [("", ""), ("中文说明 " , " 后文"), ("> " , "。")] {
        let source = prefix + "(" + body + ")" + suffix
        let formulaStart = prefix.unicodeScalars.count
        for offset in formulaStart..<(formulaStart + body.unicodeScalars.count + 2) {
            checks += 1
            if HoverMath.extract(text: source, offset: offset) != expected {
                failures += 1
                print("FAIL inline-matrix \(String(reflecting: body)) prefix=\(String(reflecting: prefix)) offset=\(offset)")
                break
            }
        }
    }
    let projected = "left│  前文\nleft│  (" + body + ")\nleft│  后文"
    let projectedStart = projected.range(of: body).map { projected[..<$0.lowerBound].unicodeScalars.count }!
    checks += 1
    if HoverMath.extract(text: projected, offset: projectedStart) != expected {
        failures += 1
        print("FAIL inline-matrix projected \(String(reflecting: body))")
    }
}
let parentheticalNonMath = [
    "ordinary words", "foo_bar", "foo.bar", "v1.2.3", "https://example.com",
    "hello-world", "path/to/file", "key:value", "a sentence",
]
for body in parentheticalNonMath {
    let source = "Context (" + body + ") afterward"
    let offset = "Context (".unicodeScalars.count + body.unicodeScalars.count / 2
    checks += 1
    if HoverMath.extract(text: source, offset: offset) != nil {
        failures += 1
        print("FAIL parenthetical-negative-matrix \(String(reflecting: body))")
    }
}
for source in ["f(i)", "print(x_i)", "if (x^2)", "lookup(W_{Q,video})"] {
    checks += 1
    if HoverMath.extract(text: source, offset: source.unicodeScalars.count / 2) != nil {
        failures += 1
        print("FAIL call-negative-matrix \(String(reflecting: source))")
    }
}

let displayMatrix: [(body: String, required: [String])] = [
    ("x", ["x"]),
    ("x_i = y^2", ["x_i", "y^2"]),
    (#"\frac{a}{b}"#, [#"\frac{a}{b}"#]),
    (#"\begin{bmatrix}a&b\\c&d\end{bmatrix}"#, [#"\begin{bmatrix}"#, #"\end{bmatrix}"#]),
    (#"A_{i\leftarrow j}\n\operatorname{softmax}_j\n\left(\n\frac{\n\langle R(p_i)q_i,\ R(p_j)k_j\rangle\n}{\sqrt d}\n\right)"#,
     [#"A_{i\leftarrow j}"#, #"\operatorname{softmax}_j"#, #"\sqrt d"#]),
    (#"\theta_{t+\Delta t}\n\alpha\theta_{\text{gyro}}\n+\n(1-\alpha)\theta_{\text{acc}}"#,
     [#"\theta_{t+\Delta t}"#, #"\theta_{\text{acc}}"#]),
    (#"96768=3\text{ 个模态}\times6\text{ 组参数}\times5376"#, ["96768", "5376"]),
    (#"h_i' = h_i+\ng^{attn}_{l,m_i,\tau_i}\odot\n\operatorname{Attention}(z)_i"#,
     ["h_i'", #"\operatorname{Attention}"#]),
]
for (bodyIndex, item) in displayMatrix.enumerated() {
    for opener in ["[", "# [", "› [", "> [", "• ["] {
        let source = opener + "\n" + item.body + "\n]"
        let offset = opener.unicodeScalars.count + 1 + item.body.unicodeScalars.count / 2
        checks += 1
        if let formula = HoverMath.extract(text: source, offset: offset),
           formula.hasPrefix("\\["), formula.hasSuffix("\\]"),
           item.required.allSatisfy(formula.contains) {
        } else {
            failures += 1
            print("FAIL display-matrix body=\(bodyIndex) opener=\(String(reflecting: opener))")
        }
        let projected = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "left│  " + $0 }.joined(separator: "\n") + "\nleft│  后文"
        let projectedOffset = projected.range(of: item.required[0]).map {
            projected[..<$0.lowerBound].unicodeScalars.count
        }!
        checks += 1
        if let formula = HoverMath.extract(text: projected, offset: projectedOffset),
           formula.hasPrefix("\\["), formula.hasSuffix("\\]"),
           item.required.allSatisfy(formula.contains) {
        } else {
            failures += 1
            print("FAIL display-matrix projected body=\(bodyIndex) opener=\(String(reflecting: opener))")
        }
    }
}
print("Native hover parser: \(checks - failures)/\(checks) passed in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
exit(failures == 0 ? 0 : 1)

import Foundation

struct Fixture: Decodable {
    let name: String?
    let text: String
    let offset: Int?
    let offsets: [Int]?
    let expected: String?
    let segments: [String]?
}

let path = CommandLine.arguments.dropFirst().first ?? "tests/native_math/fixtures.json"
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
print("Native hover parser: \(checks - failures)/\(checks) passed in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
exit(failures == 0 ? 0 : 1)

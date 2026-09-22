import Foundation
import CoreGraphics

var passed = 0
var failed = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    if condition() { passed += 1; print("PASS \(name)") }
    else { failed += 1; print("FAIL \(name)") }
}

let text = "ab\ncdef" as NSString
func gridBounds(_ range: NSRange) -> CGRect? {
    guard range.location >= 0, NSMaxRange(range) <= text.length else { return nil }
    var rectangle = CGRect.null
    for index in range.location..<NSMaxRange(range) where index != 2 {
        let row = index < 2 ? 0 : 1
        let column = index < 2 ? index : index - 3
        rectangle = rectangle.union(CGRect(x: column * 10, y: row * 20, width: 10, height: 18))
    }
    return rectangle.isNull ? nil : rectangle
}
check(HoverTextPosition.range(at: CGPoint(x: 25, y: 25), text: text, visibleRange: nil,
                             bounds: gridBounds) == NSRange(location: 5, length: 1), "bounds-only second-row character")
check(HoverTextPosition.range(at: CGPoint(x: 35, y: 5), text: text, visibleRange: nil,
                             bounds: gridBounds) == nil, "reject union rectangle's empty space")
check(HoverTextPosition.range(at: CGPoint(x: 5, y: 5), text: text,
                             visibleRange: NSRange(location: 3, length: 4), bounds: gridBounds) == nil,
      "do not search outside visible range")
check(HoverTextPosition.range(at: .zero, text: text, visibleRange: NSRange(location: Int.max, length: 2),
                             bounds: gridBounds) == nil, "invalid range does not overflow")
var queries = 0
check(HoverTextPosition.range(at: .zero, text: text, visibleRange: nil, bounds: { _ in
    queries += 1
    return nil
}) == nil && queries == 1, "unsupported bounds stops immediately")

let emoji = "a\u{1F600}b" as NSString
check(HoverTextPosition.range(at: CGPoint(x: 15, y: 5), text: emoji, visibleRange: nil, bounds: { range in
    switch range.location {
    case 0: return CGRect(x: 0, y: 0, width: range.length == 1 ? 10 : 40, height: 10)
    case 1: return CGRect(x: 10, y: 0, width: range.length == 2 ? 20 : 30, height: 10)
    case 3: return CGRect(x: 30, y: 0, width: 10, height: 10)
    default: return nil
    }
}) == NSRange(location: 1, length: 2), "bounds lookup retains complete UTF-16 character")
check(HoverTextPosition.range(at: .zero, text: emoji,
                             visibleRange: NSRange(location: 2, length: 1), bounds: { _ in .zero }) == nil,
      "visible range cannot split a UTF-16 character")
var boundedQueries = 0
let ambiguous = String(repeating: "x", count: 128) as NSString
check(HoverTextPosition.range(at: CGPoint(x: 5, y: 5), text: ambiguous, visibleRange: nil, bounds: { range in
    boundedQueries += 1
    return range.length == 1 ? nil : CGRect(x: 0, y: 0, width: 10, height: 10)
}) == nil && boundedQueries <= 64, "ambiguous geometry has a fixed request budget")

let formulaText = "prose here\n[\na\\longrightarrow v\\longrightarrow p\n]"
let direct = formulaText.range(of: "prose")!.lowerBound
let fallback = formulaText.range(of: "longrightarrow")!.lowerBound
let directOffset = formulaText[..<direct].unicodeScalars.count
let fallbackOffset = formulaText[..<fallback].unicodeScalars.count
check(HoverTextPosition.formula(direct: nil, text: formulaText, directOffset: directOffset, fallbackOffset: fallbackOffset)?.contains("longrightarrow") == true,
      "failed direct point mapping retries the bounds-located character")
check(HoverTextPosition.formula(direct: "direct", text: formulaText, directOffset: fallbackOffset, fallbackOffset: directOffset) == "direct",
      "successful direct point mapping remains authoritative")
check(HoverTextPosition.formula(direct: nil, text: "ordinary prose", directOffset: 2, fallbackOffset: 5) == nil,
      "fallback point mapping does not manufacture math")

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)

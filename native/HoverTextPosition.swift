import Foundation
import CoreGraphics

enum HoverTextPosition {
    static func formula(direct: String?, text: String, directOffset: Int, fallbackOffset: Int?) -> String? {
        if let direct { return direct }
        guard let fallbackOffset, fallbackOffset != directOffset else { return nil }
        return HoverMath.extract(text: text, offset: fallbackOffset)
    }

    // Some accessible text views provide real character bounds but no point lookup.
    static func range(at point: CGPoint, text: NSString, visibleRange: NSRange?,
                      bounds: (NSRange) -> CGRect?) -> NSRange? {
        let available = visibleRange ?? NSRange(location: 0, length: text.length)
        guard available.location >= 0, available.length > 0,
              available.location <= text.length, available.length <= text.length - available.location,
              available.length <= 131_072, Range(available, in: text as String) != nil else { return nil }
        var pending = [available]
        var remaining = 64
        let deadline = Date().addingTimeInterval(0.08)
        while let range = pending.popLast(), remaining > 0, Date() < deadline {
            remaining -= 1
            guard let rectangle = bounds(range), rectangle.width > 0, rectangle.height > 0,
                  rectangle.insetBy(dx: -1, dy: -1).contains(point) else { continue }
            let character = text.rangeOfComposedCharacterSequence(at: range.location)
            if NSMaxRange(character) >= NSMaxRange(range) {
                return character
            }
            let middle = text.rangeOfComposedCharacterSequence(at: range.location + range.length / 2).location
            let split = middle > range.location ? middle : NSMaxRange(character)
            guard split < NSMaxRange(range) else { continue }
            pending.append(NSRange(location: split, length: NSMaxRange(range) - split))
            pending.append(NSRange(location: range.location, length: split - range.location))
        }
        return nil
    }
}

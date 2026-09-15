import AppKit

// A separate app exercises standard text accessibility without terminal-specific APIs.
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let fixture = #"""
MATHPEEK HOVER DEMO
Move the pointer over any part of a formula; do not select.

Inline: $e^{i\pi}+1=0$

Hard-wrapped command, as seen through tmux:
$$\fra
c{1}{2}+\sum_{i=1}^{n} i^2$$

Multi-line aligned math:
\[
\begin{aligned}
a &= b+c \\
x &= \sqrt{\frac{1}{2}}
\end{aligned}
\]

Chinese context: $x^2+y^2=1$
"""#
let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 1000, height: 650),
                      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
window.title = "Math Peek Isolated AX Fixture"
window.isReleasedWhenClosed = false
let scroll = NSScrollView(frame: window.contentView!.bounds)
scroll.autoresizingMask = [.width, .height]
scroll.hasVerticalScroller = true
let text = NSTextView(frame: scroll.contentView.bounds)
text.isEditable = false
text.isRichText = false
text.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
text.textContainerInset = NSSize(width: 20, height: 20)
text.string = fixture.split(separator: "\n", omittingEmptySubsequences: false)
    .map { String($0).padding(toLength: 90, withPad: " ", startingAt: 0) }.joined(separator: "\n")
text.autoresizingMask = [.width]
text.isVerticallyResizable = true
scroll.documentView = text
window.contentView!.addSubview(scroll)
window.makeKeyAndOrderFront(nil)
window.makeFirstResponder(text)
application.activate()
application.run()

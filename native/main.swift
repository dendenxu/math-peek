import AppKit

let app = NSApplication.shared
let delegate = MathPeek()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()

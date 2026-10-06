import Foundation

var rows: [String] = []
for index in 0..<360 {
    if index % 18 == 0 {
        rows += ["$$", "x_{\(index)}=\\frac{a_{\(index)}}{b_{\(index)}}+\\theta_{\\mathrm{acc}}", "$$"]
    } else {
        rows.append("ordinary terminal log row \(index) result completed without mathematical content")
    }
}
let source = rows.joined(separator: "\n")
let needle = #"\theta_{\mathrm{acc}}"#
let range = source.range(of: needle)!
let offset = source[..<range.lowerBound].unicodeScalars.count

let buildStart = ProcessInfo.processInfo.systemUptime
let document = TerminalFormulaDocument(text: source)
let buildMS = (ProcessInfo.processInfo.systemUptime - buildStart) * 1000
guard document.match(at: offset)?.formula.contains(needle) == true else {
    print("FAIL performance fixture did not return complete formula")
    exit(1)
}
let lookupStart = ProcessInfo.processInfo.systemUptime
for _ in 0..<10_000 {
    guard document.match(at: offset)?.formula.contains(needle) == true else {
        print("FAIL cached lookup changed result")
        exit(1)
    }
}
let lookupMS = (ProcessInfo.processInfo.systemUptime - lookupStart) * 1000
let cache = FormulaDocumentCache()
_ = cache.match(text: source, at: offset)
let cacheStart = ProcessInfo.processInfo.systemUptime
for _ in 0..<10_000 { _ = cache.match(text: source, at: offset) }
let cacheMS = (ProcessInfo.processInfo.systemUptime - cacheStart) * 1000

print(String(format: "Formula performance: build %.2f ms, 10k index lookups %.2f ms, 10k cache lookups %.2f ms, %d scalars",
             buildMS, lookupMS, cacheMS, source.unicodeScalars.count))
guard buildMS < 250, lookupMS < 250, cacheMS < 250 else {
    print("FAIL formula document performance exceeded fixed safety budget")
    exit(1)
}

let paneRows = rows.map { $0.padding(toLength: 96, withPad: " ", startingAt: 0) + "│  " + $0 }.joined(separator: "\n")
let paneNeedle = paneRows.range(of: needle)!
let paneOffset = paneRows[..<paneNeedle.lowerBound].unicodeScalars.count
let paneDocument = TerminalFormulaDocument(text: paneRows)
guard paneDocument.match(at: paneOffset)?.formula.contains(needle) == true else {
    print("FAIL pane performance fixture did not return complete formula")
    exit(1)
}
let paneStart = ProcessInfo.processInfo.systemUptime
for _ in 0..<10_000 { _ = paneDocument.match(at: paneOffset) }
let paneMS = (ProcessInfo.processInfo.systemUptime - paneStart) * 1000
print(String(format: "Formula performance: 10k cached tmux-pane lookups %.2f ms", paneMS))
guard paneMS < 250 else { print("FAIL cached tmux-pane lookups exceeded safety budget"); exit(1) }

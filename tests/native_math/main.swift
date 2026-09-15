import Foundation

struct Fixture: Decodable {
    let name: String?
    let text: String
    let offset: Int
    let expected: String?
}

let path = CommandLine.arguments.dropFirst().first ?? "tests/native_math/fixtures.json"
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
var failures = 0
let began = Date()
for fixture in fixtures {
    let result = HoverMath.extract(text: fixture.text, offset: fixture.offset)
    if result != fixture.expected {
        failures += 1
        print("FAIL \(fixture.name ?? "fixture") offset=\(fixture.offset): expected \(String(reflecting: fixture.expected)), got \(String(reflecting: result))")
    }
}
print("Native hover parser: \(fixtures.count - failures)/\(fixtures.count) passed in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
exit(failures == 0 ? 0 : 1)

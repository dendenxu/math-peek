import Foundation

struct Fixture: Decodable {
    let name: String?
    let text: String
    let offset: Int?
    let offsets: [Int]?
    let expected: String?
}

let path = CommandLine.arguments.dropFirst().first ?? "tests/native_math/fixtures.json"
let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
var failures = 0
var checks = 0
let began = Date()
for fixture in fixtures {
    for offset in fixture.offsets ?? fixture.offset.map({ [$0] }) ?? [] {
        checks += 1
        let result = HoverMath.extract(text: fixture.text, offset: offset)
        if result != fixture.expected {
            failures += 1
            print("FAIL \(fixture.name ?? "fixture") offset=\(offset): expected \(String(reflecting: fixture.expected)), got \(String(reflecting: result))")
        }
    }
}
print("Native hover parser: \(checks - failures)/\(checks) passed in \(Int(Date().timeIntervalSince(began) * 1000)) ms")
exit(failures == 0 ? 0 : 1)

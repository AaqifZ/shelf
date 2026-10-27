import Foundation
import ShelfCore

var failures = 0
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    let ok = condition()
    print(ok ? "  ok  \(name)" : "  FAIL \(name)")
    if !ok { failures += 1 }
}

let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("shelf-persistence-\(UUID().uuidString)", isDirectory: true)
defer { try? fm.removeItem(at: root) }
let url = root.appendingPathComponent("config.json")
var sample = Config()
sample.layout = Layout(hidden: ["hidden"], visible: ["visible"])

print("configuration persistence")
let legacy = Data(#"{"layout":{"hidden":["a"],"visible":[]},"options":{"revealOnHover":false}}"#.utf8)
if let decoded = try? JSONDecoder().decode(Config.self, from: legacy) {
    expect(decoded.schemaVersion == 1 && !decoded.options.revealOnHover && decoded.options.revealOnClick, "legacy options retain defaults for new fields")
} else { expect(false, "legacy configuration decodes") }
let future = Data(#"{"schemaVersion":99,"layout":{"hidden":[],"visible":[]}}"#.utf8)
expect((try? JSONDecoder().decode(Config.self, from: future)) == nil, "unknown schema versions are refused")
let duplicates = Data(#"{"layout":{"hidden":["a"],"visible":["a"]}}"#.utf8)
expect((try? JSONDecoder().decode(Config.self, from: duplicates)) == nil, "duplicate layout identities are refused")
expect(ConfigurationFile.load(from: url) == .missing, "a missing file is a first-run state")

switch ConfigurationFile.save(sample, to: url) {
case .success: expect(true, "a valid configuration writes")
case .failure: expect(false, "a valid configuration writes")
}
expect(ConfigurationFile.load(from: url) == .loaded(sample), "a valid configuration reads back exactly")

var replacement = Config()
replacement.layout = Layout(hidden: ["new-hidden"], visible: [])
switch ConfigurationFile.save(replacement, to: url) {
case .success: expect(true, "a valid configuration can replace a valid configuration")
case .failure: expect(false, "a valid configuration can replace a valid configuration")
}
expect(ConfigurationFile.load(from: url) == .loaded(replacement), "a replacement configuration reads back exactly")

let malformed = Data("{ definitely not json".utf8)
do {
    try malformed.write(to: url, options: .atomic)
} catch {
    print("  FAIL test setup could not write malformed file: \(error)")
    failures += 1
}
if case .failed(.malformed(_)) = ConfigurationFile.load(from: url) {
    expect(true, "malformed JSON has a distinct failure")
} else {
    expect(false, "malformed JSON has a distinct failure")
}

switch ConfigurationFile.save(sample, to: url) {
case .success: expect(false, "a malformed configuration is preserved")
case .failure(.invalidExistingFile(_)): expect(true, "a malformed configuration is preserved")
case .failure: expect(false, "a malformed configuration is preserved")
}
expect((try? Data(contentsOf: url)) == malformed, "a refused save does not change the malformed file")

if case .failed(.unreadable(_)) = ConfigurationFile.load(from: root) {
    expect(true, "an unreadable path has a distinct failure")
} else {
    expect(false, "an unreadable path has a distinct failure")
}

print("rotating log")
let log = root.appendingPathComponent("shelf.log")
switch RotatingLogFile.append("first\n", to: log, maximumBytes: 5) {
case .success: expect(true, "the first log entry writes")
case .failure: expect(false, "the first log entry writes")
}
switch RotatingLogFile.append("second\n", to: log, maximumBytes: 5) {
case .success: expect(true, "an oversized log rotates and accepts a new entry")
case .failure: expect(false, "an oversized log rotates and accepts a new entry")
}
let archive = RotatingLogFile.archiveURL(for: log)
expect((try? String(contentsOf: archive, encoding: .utf8)) == "first\n", "rotation preserves the previous log as .1")
expect((try? String(contentsOf: log, encoding: .utf8)) == "second\n", "rotation starts a new active log")
switch RotatingLogFile.append("third\n", to: log, maximumBytes: 5) {
case .success: expect(true, "a later rotation replaces the old archive")
case .failure: expect(false, "a later rotation replaces the old archive")
}
expect((try? String(contentsOf: archive, encoding: .utf8)) == "second\n", "the archive holds the most recent full log")
expect((try? String(contentsOf: log, encoding: .utf8)) == "third\n", "the active log keeps the latest entry")

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

import AppKit

// Test 1: a menu bar icon that comes and goes, like a timer app.
// Usage: ShelfChurn <path to shelf> [cycles]
// 1. Shows the icon and tells shelf it belongs in Visible.
// 2. Then N times: remove it, check; show it again, time how long until it is back in Visible (fail above 5 s),
//    and check that all four places agree.

let shelf = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "shelf"
let cycles = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 50 : 50
var item: NSStatusItem?

func run(_ args: [String]) -> (Int32, String) {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: shelf)
    p.arguments = args
    p.standardOutput = pipe
    try? p.run()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
}

func show() {
    let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    s.autosaveName = "shelf-churn"
    s.button?.image = NSImage(systemSymbolName: "testtube.2", accessibilityDescription: "shelf test")
    s.button?.imagePosition = .imageLeading
    s.button?.title = " shelf test"
    let menu = NSMenu()
    menu.addItem(withTitle: "ShelfChurn test icon", action: nil, keyEquivalent: "")
    s.menu = menu
    item = s
}

func hide() {
    if let item { NSStatusBar.system.removeStatusItem(item) }
    item = nil
}

func sectionOfChurn() -> String {
    let (_, out) = run(["list"])
    return out.split(separator: "\n").first { $0.contains("/shelf-churn") }.map { String($0.split(separator: " ")[0]) } ?? "absent"
}

/// The test runs on a background thread. The main thread stays free, like a real app's:
/// macOS needs the owning app's main thread to start a drag of its icon. (A first version blocked
/// the main thread on `shelf list`, and its icon could not be moved, by shelf or by a person.)
func pump(_ seconds: Double) { Thread.sleep(forTimeInterval: seconds) }
func onMain(_ body: @escaping () -> Void) { DispatchQueue.main.sync(execute: body) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
DispatchQueue.global().async {
    setvbuf(stdout, nil, _IOLBF, 0)
    onMain(show); pump(2.5)
    let (_, list) = run(["list"])
    guard let id = list.split(separator: "\n").first(where: { $0.contains("/shelf-churn") })?.split(separator: " ").filter({ !$0.isEmpty })[3] else {
        print("FAIL: shelf never saw the churn icon"); exit(1)
    }
    _ = run(["place", "visible", String(id)]); pump(2.5)
    print("churn icon \(id) placed: \(sectionOfChurn())")

    var pass = 0
    var latencies: [Double] = []
    for n in 1...cycles {
        onMain(hide); pump(1.2)
        let (offCode, offOut) = run(["check"])
        onMain(show)
        // How long until it is back in Visible? Perfect = within a second or two. Fail above 5 s.
        let t0 = Date()
        var section = "absent"
        while Date().timeIntervalSince(t0) < 8 {
            pump(0.1)
            section = sectionOfChurn()
            if section == "visible" { break }
        }
        let secs = Date().timeIntervalSince(t0)
        latencies.append(secs)
        pump(0.5)
        let (onCode, onOut) = run(["check"])
        let ok = offCode == 0 && onCode == 0 && section == "visible" && secs <= 5
        if ok { pass += 1 }
        print("\(n)/\(cycles) \(ok ? "ok" : "FAIL") back in \(String(format: "%.1f", secs)) s section=\(section)\(offCode == 0 ? "" : " off-check: \(offOut.trimmingCharacters(in: .newlines))")\(onCode == 0 ? "" : " on-check: \(onOut.trimmingCharacters(in: .newlines))")")
    }
    onMain(hide)
    let sorted = latencies.sorted()
    print(String(format: "RESULT %d/%d  back-in-place time: median %.1f s, worst %.1f s", pass, cycles, sorted[sorted.count / 2], sorted.last ?? 0))
    exit(pass == cycles ? 0 : 1)
}
app.run()

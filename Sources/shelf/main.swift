import AppKit
import ShelfCore

// One binary: `shelf run` is the app (started by launchd), everything else is the CLI.

let usage = """
shelf: menu bar icons stay where you put them.

  shelf list              every icon now, left to right, with its section
  shelf check             compare menu bar, shelf bar, settings window and memory (exit 1 on a problem)
  shelf use shelf|ice     switch which menu bar manager runs (one at a time)
  shelf settings          open the settings window
  shelf open | close      open or close the shelf bar
  shelf click <id>        click an icon from the shelf bar
  shelf place hidden|visible <id> [before <id>]
  shelf restart           restart the app
Files: ~/.shelf/config.json (memory), state.json, shelf.log, check.log
"""

let label = "com.aaqifz.shelf"
let agentPlist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
let args = Array(CommandLine.arguments.dropFirst())

func send(_ command: String) {
    DistributedNotificationCenter.default().postNotificationName(.shelfCommand, object: command, userInfo: nil, deliverImmediately: true)
    print("sent: \(command)")
}

@discardableResult
func sh(_ path: String, _ arguments: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { print("could not run \(path): \(error.localizedDescription)"); return 127 }
    p.waitUntilExit()
    return p.terminationStatus
}

/// Any other process running this same executable name (the app, bundled or a dev build).
func shelfIsRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains {
        $0.processIdentifier != getpid() && $0.executableURL?.lastPathComponent == "shelf"
    }
}

func list(debug: Bool) {
    let scanner = Scanner()
    let icons = scanner.scan()
    let s = Planner.sections(icons.map(\.id))
    for i in icons {
        let section = IDs.isAnchor(i.id) ? "shelf" : (s?.hidden.contains(i.id) == true ? "hidden" : (s == nil ? "?" : "visible"))
        print(String(format: "%-8@ %7.0f %5.0f  %@  %@", section, i.x, i.width, i.id, i.label))
    }
    if let reason = scanner.pauseReason { print("(paused: \(reason))") }
    else if s == nil { print("(shelf is not running: no divider in the menu bar)") }
    if debug { print(scanner.debugReport()) }
}

/// Runs the check up to 3 times, a second apart: a scan can catch the app mid-update.
func check(log: Bool, quiet: Bool) -> Int32 {
    var problems: [String] = []
    for attempt in 0..<3 {
        if attempt > 0 { usleep(1_000_000) }
        let scanner = Scanner()
        let reality = scanner.scan().map(\.id)
        if let reason = scanner.pauseReason {
            if attempt < 2 { continue }
            let liveness = Check.livenessProblems(state: Store.loadState())
            let running = shelfIsRunning()
            let line = !running ? "PROBLEM: shelf is not running" :
                (liveness.isEmpty ? "PAUSED: \(reason)" : "PROBLEM: " + liveness.joined(separator: "; "))
            if log { Store.log(line, to: Store.checkLogURL) }
            if !quiet { print(line) }
            return running && liveness.isEmpty ? 3 : 1
        }
        let layout: Layout
        switch Store.loadConfig() {
        case .missing: layout = Layout()
        case .loaded(let saved): layout = saved.layout
        case .failed(let problem):
            let line = "PROBLEM: saved layout \(problem)"
            if log { Store.log(line, to: Store.checkLogURL) }
            if !quiet { print(line) }
            return 1
        }
        problems = Check.problems(reality: reality, state: Store.loadState(), layout: layout)
        if problems.isEmpty { break }
    }
    let line = problems.isEmpty ? "OK" : "PROBLEM: " + problems.joined(separator: "; ")
    if log { Store.log(line, to: Store.checkLogURL) }
    if !quiet || !problems.isEmpty { print(line) }
    return problems.isEmpty ? 0 : 1
}

/// First switch from Ice: copy Ice's layout so nothing moves. Left of Ice's hidden divider = hidden.
@discardableResult
func importFromIce() -> Bool {
    switch Store.loadConfig() {
    case .loaded: return true
    case .failed(let problem): print("saved layout is preserved: \(problem)"); return false
    case .missing: break
    }
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.jordanbaird.Ice").isEmpty else { return true }
    let scanner = Scanner(importingIce: true)
    let ids = scanner.scan().map(\.id)
    guard scanner.pauseReason == nil else {
        print("cannot import Ice's layout: \(scanner.pauseReason ?? "unknown observation")")
        return false
    }
    guard let i = ids.firstIndex(of: "com.jordanbaird.Ice/Ice.ControlItem.Hidden") else {
        print("Ice's hidden divider is unavailable; Shelf has not taken over")
        return false
    }
    let isIce = { (id: String) in id.hasPrefix("com.jordanbaird.Ice/") }
    var config = Config()
    config.layout = Layout(hidden: ids[..<i].filter { !isIce($0) && !IDs.isFixed($0) },
                           visible: ids[(i + 1)...].filter { !isIce($0) && !IDs.isFixed($0) })
    guard Store.save(config) else { print("could not save the imported layout; see ~/.shelf/shelf.log"); return false }
    print("copied Ice's layout: \(config.layout.hidden.count) hidden, \(config.layout.visible.count) visible")
    return true
}

func use(_ which: String) -> Int32 {
    let domain = "gui/\(getuid())"
    switch which {
    case "shelf":
        // The app imports after permission setup, before it quits Ice.
        // Ice keeps running until shelf has its permissions; shelf quits Ice itself once it can take over.
        guard sh("/bin/launchctl", ["enable", "\(domain)/\(label)"]) == 0 else { return 1 }
        if sh("/bin/launchctl", ["bootstrap", domain, agentPlist.path]) != 0 {
            guard sh("/bin/launchctl", ["kickstart", "-k", "\(domain)/\(label)"]) == 0 else { return 1 }
        }
        print("shelf is starting. It takes over from Ice once it has Accessibility and Screen Recording.")
        print("If it needs them, a ⚠︎ icon appears in the menu bar with buttons to the right settings.")
        print("Switch back any time: shelf use ice")
    case "ice":
        sh("/bin/launchctl", ["bootout", "\(domain)/\(label)"])
        sh("/bin/launchctl", ["disable", "\(domain)/\(label)"])
        sh("/usr/bin/open", ["-b", "com.jordanbaird.Ice"])
        print("Ice is on. shelf is off (its memory stays in ~/.shelf). Switch again: shelf use shelf")
    default:
        print(usage); return 2
    }
    return 0
}

switch args.first {
case "run":
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
case "list": list(debug: args.contains("--debug"))
case "check": exit(check(log: args.contains("--log"), quiet: args.contains("--quiet")))
case "use" where args.count > 1: exit(use(args[1]))
case "settings", "open", "close", "refresh":
    guard shelfIsRunning() else { print("shelf is not running (shelf use shelf)"); exit(1) }
    send(args[0])
case "click" where args.count > 1: send("click \(args[1])")
case "place" where args.count > 2: send("place " + args[1...].joined(separator: " "))
case "import-ice": exit(importFromIce() ? 0 : 1)
case "snapshot-bar" where args.count > 1: exit(MainActor.assumeIsolated { snapshotBar(to: args[1]) })
case "restart": sh("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/\(label)"]); print("restarted")
default: print(usage)
}

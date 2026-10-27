import AppKit
import ShelfCore

/// Builds the live list of icons: window list for position, Accessibility for the owning app.
/// Matching is by frame centre. Each window is matched once, then remembered by window id and name:
/// a new name means a new match.
final class Scanner {
    private struct Owner { var pid: pid_t; var bundle: String; var label: String }
    private struct AXItem { var owner: Owner; var frame: CGRect }

    private var owners: [CGWindowID: (owner: Owner, name: String?)] = [:]
    /// Windows not matched yet: how many tries, and when to try again (1, 2, 4, 8, then every 15 s). Never given up:
    /// some apps create their icon on demand, so "no match now" says nothing about later.
    private var misses: [CGWindowID: (count: Int, next: Date)] = [:]
    private var suffixes: [CGWindowID: Int] = [:]
    var log: (String) -> Void = { _ in }

    private(set) var pauseReason: String? = "no observation yet"
    private(set) var displayBounds: CGRect?
    private var topology = ""
    private var settledAfter = Date.distantPast
    private var activeDisplayID: UInt32?
    private let requireSettledTopology: Bool
    private let importingIce: Bool

    init(requireSettledTopology: Bool = false, importingIce: Bool = false) {
        self.requireSettledTopology = requireSettledTopology
        self.importingIce = importingIce
    }

    /// Current icons on the display that holds the real shelf icon, left to right.
    func scan() -> [Icon] {
        displayBounds = nil
        guard CGPreflightScreenCaptureAccess(), AXIsProcessTrusted() else {
            pauseReason = "Accessibility or Screen Recording permission is unavailable"
            return []
        }
        let ids = WindowServer.menuBarWindowIDs()
        let info = WindowServer.info(ids)
        let mainMenuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            pauseReason = "display list is unavailable"; return []
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            pauseReason = "display list changed during scan"; return []
        }
        let displays = displayIDs.prefix(Int(count)).map { DisplaySelection.Display(id: $0, frame: CGDisplayBounds($0)) }
        let signature = displays.sorted { $0.id < $1.id }.map { "\($0.id):\($0.frame)" }.joined(separator: "|")
        if signature != topology {
            topology = signature
            owners.removeAll(); misses.removeAll()
            settledAfter = Date().addingTimeInterval(1)
        }
        let resting = ids.compactMap { id -> (CGWindowID, WindowServer.Info)? in
            guard let i = info[id], i.level != mainMenuLevel, i.frame.width > 0 else { return nil }
            return (id, i)
        }
        let selection: DisplaySelection.Selection
        switch DisplaySelection.select(windows: resting.map { .init(id: $0.0, name: $0.1.name, frame: $0.1.frame) }, displays: displays,
                                       anchorName: importingIce ? "Ice.ControlItem.Visible" : "shelf.icon",
                                       dividerName: importingIce ? "Ice.ControlItem.Hidden" : "shelf.divider") {
        case .success(let selected): selection = selected
        case .failure(let problem):
            pauseReason = problem.rawValue
            return []
        }
        displayBounds = selection.display.frame
        if activeDisplayID != selection.display.id {
            activeDisplayID = selection.display.id
            owners.removeAll(); misses.removeAll()
            settledAfter = Date().addingTimeInterval(1)
        }
        pauseReason = requireSettledTopology && Date() < settledAfter ? "display topology is settling" : nil
        let windows = resting.filter { selection.windows.contains($0.0) && !Self.systemIndicators.contains($0.1.name ?? "") }
        let live = Set(windows.map(\.0))
        let runningApps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let runningPIDs = Set(runningApps.map(\.processIdentifier))
        let controlCenterPID = runningApps.first { $0.bundleIdentifier == IDs.controlCenterBundle }?.processIdentifier
        let windowNames = windows.map { $0.1.name }
        func isKnownControlCenter(_ i: WindowServer.Info) -> Bool {
            controlCenterPID != nil && IDs.canUseControlCenterFallback(i.name, among: windowNames)
        }
        owners = owners.filter { live.contains($0.key) && info[$0.key]?.name == $0.value.name && runningPIDs.contains($0.value.owner.pid) }
        misses = misses.filter { live.contains($0.key) }

        let now = Date()
        let unknown = windows.filter {
            owners[$0.0] == nil && !Self.isShelf($0.1) && (misses[$0.0]?.next ?? .distantPast) <= now
        }
        if !unknown.isEmpty { resolve(unknown) }
        if windows.contains(where: {
            !Self.isShelf($0.1) && !isKnownControlCenter($0.1) && owners[$0.0] == nil
        }) {
            pauseReason = "menu bar ownership is incomplete"
        }

        var icons: [Icon] = []
        for (id, i) in windows.sorted(by: { $0.1.frame.minX < $1.1.frame.minX }) {
            let owner: Owner
            if Self.isShelf(i) { owner = Owner(pid: Self.shelfPID, bundle: IDs.bundle, label: i.name ?? "") }
            else if let o = owners[id] { owner = o.owner }
            else if isKnownControlCenter(i), let pid = controlCenterPID {
                owner = Owner(pid: pid, bundle: IDs.controlCenterBundle, label: i.name ?? "")
            }
            else { continue }  // not matched yet; it joins the list once Accessibility knows it
            let name = i.name ?? owner.label
            icons.append(Icon(id: "\(owner.bundle)/\(name)", windowID: id, pid: owner.pid, bundle: owner.bundle, name: name,
                              label: owner.label, x: i.frame.minX, y: i.frame.minY, width: i.frame.width, height: i.frame.height))
        }
        // Two icons with the same id (rare): each window keeps the number it got when first seen, so a
        // reorder never swaps identities (Codex audit finding 2). A new window takes the lowest free number.
        suffixes = suffixes.filter { live.contains($0.key) }
        for k in icons.indices {
            let base = icons[k].id
            let sameBase = icons.indices.filter { icons[$0].id == base || icons[$0].id.hasPrefix(base + "#") }
            guard sameBase.count > 1 || suffixes[icons[k].windowID] != nil else { continue }
            if suffixes[icons[k].windowID] == nil {
                let taken = Set(sameBase.compactMap { suffixes[icons[$0].windowID] })
                suffixes[icons[k].windowID] = (1...).first { !taken.contains($0) }!
            }
            if let n = suffixes[icons[k].windowID], n > 1 { icons[k].id = base + "#\(n)" }
        }
        return icons
    }

    /// macOS indicators that come and go on their own and cannot be moved (Ice skips the same ones).
    /// AudioVideoModule is the "screen recording / microphone in use" item.
    static let systemIndicators: Set<String> = ["AudioVideoModule", "FaceTime", "screencaptureui", "System Status Item Clone"]

    /// shelf's own two items, known by window name. On macOS 26 the app's NSWindow numbers for its
    /// status items are not the real WindowServer ids (those windows live in Control Center).
    private static func isShelf(_ i: WindowServer.Info) -> Bool { i.name == "shelf.icon" || i.name == "shelf.divider" }
    private static let shelfPID: pid_t = NSRunningApplication.runningApplications(withBundleIdentifier: IDs.bundle).first?.processIdentifier ?? getpid()

    private func resolve(_ windows: [(CGWindowID, WindowServer.Info)]) {
        let items = axItems()
        let apps = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        lastUnmatched = []
        for (id, i) in windows {
            let eligible = items.filter { IDs.ownerFits(windowName: i.name, owner: $0.owner.bundle, apps: apps) }
            let index = DisplaySelection.uniqueMatch(frame: i.frame, candidates: eligible.map(\.frame))
            if let index {
                let match = eligible[index]
                owners[id] = (match.owner, i.name)
            } else {
                lastUnmatched.append((id, i))
                let n = (misses[id]?.count ?? 0) + 1
                misses[id] = (n, Date().addingTimeInterval(min(15, pow(2, Double(n - 1)))))
                if n == 5 { log("no owner found yet for window \(id) (\(i.name ?? "?")); still retrying") }
            }
        }
    }

    /// One pass over running apps' Accessibility "extras menu bar" (their status items), in parallel.
    private func axItems() -> [AXItem] {
        // Every app, every time: an app with no icon now may add one later (no "has no icons" cache).
        let apps = NSWorkspace.shared.runningApplications.filter { $0.processIdentifier != getpid() && !$0.isTerminated }
        var results = [[AXItem]?](repeating: nil, count: apps.count)
        results.withUnsafeMutableBufferPointer { out in
            do {
                DispatchQueue.concurrentPerform(iterations: apps.count) { k in
                    let app = apps[k], pid = app.processIdentifier
                    let el = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(el, 0.25)
                    var bar: CFTypeRef?
                    let err = AXUIElementCopyAttributeValue(el, "AXExtrasMenuBar" as CFString, &bar)
                    guard err == .success, let bar else { return }
                    var kids: CFTypeRef?
                    AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
                    let bundle = app.bundleIdentifier ?? app.localizedName ?? "pid\(pid)"
                    out[k] = ((kids as? [AXUIElement]) ?? []).compactMap { kid in
                        guard let frame = Self.frame(of: kid), frame.width > 0 else { return nil }
                        return AXItem(owner: Owner(pid: pid, bundle: bundle, label: Self.label(of: kid)), frame: frame)
                    }
                }
            }
        }
        lastAX = results.compactMap { $0 }.flatMap { $0 }
        return lastAX
    }

    // MARK: Debug (`shelf list --debug`)

    private var lastAX: [AXItem] = []
    private var lastUnmatched: [(CGWindowID, WindowServer.Info)] = []

    func debugReport() -> String {
        var lines = ["unmatched windows:"]
        for (id, i) in lastUnmatched {
            lines.append(String(format: "  %6d x=%7.0f w=%4.0f name=%@", id, i.frame.minX, i.frame.width, i.name ?? "-"))
            for ax in lastAX.sorted(by: { abs($0.frame.midX - i.frame.midX) < abs($1.frame.midX - i.frame.midX) }).prefix(2) {
                lines.append(String(format: "      nearest AX x=%7.0f w=%4.0f %@ %@", ax.frame.minX, ax.frame.width, ax.owner.bundle, ax.owner.label))
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func frame(of el: AXUIElement) -> CGRect? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXFrame" as CFString, &v) == .success, let v else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil
    }

    private static func label(of el: AXUIElement) -> String {
        for attr in [kAXTitleAttribute, kAXDescriptionAttribute] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success,
               let s = (v as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty { return s }
        }
        return ""
    }
}

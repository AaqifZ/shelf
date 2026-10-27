import AppKit
import ShelfCore

/// The loop: scan the menu bar, compare it with the layout memory, fix drift. Twice a second (a scan costs about 1 ms).
/// Everything here runs on one serial queue, so there is never more than one move in flight.
final class Engine {
    struct Snapshot { var icons: [Icon]; var layout: Layout; var pinned: Set<String>; var pauseReason: String?; var options: Options }

    let queue = DispatchQueue(label: "shelf.engine", qos: .userInitiated)
    private let scanner = Scanner(requireSettledTopology: true)
    private var storageProblem: String?
    private var clickGeneration = 0
    private var config: Config
    private var icons: [Icon] = []
    private var timer: DispatchSourceTimer?
    private let started = Date()

    /// Hidden icons the user clicked from the shelf bar, shown in the menu bar for a moment.
    private var pins: [String: Date] = [:]
    /// The user is ⌘-dragging in the menu bar. When they let go, reality becomes the layout.
    private var arranging = false
    private var arrangedAt: Date?
    /// Retry, loop and fight state, keyed by one concrete status item appearance.
    private var recovery = RecoveryPolicy()

    /// Called on the main queue after every scan.
    var onUpdate: (Snapshot) -> Void = { _ in }

    init(config: Config) {
        self.config = config
        scanner.log = { Store.log($0) }
    }

    func start() {
        queue.async { [self] in
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        }
    }

    // MARK: Inputs from the UI (any thread)

    /// A Settings drag (or `shelf place`). Sent as an edit, not a whole layout, and applied here to the
    /// engine's current layout, so two quick edits never overwrite each other (Codex follow-up F2).
    func place(_ id: String, in section: Section, before: String?) {
        queue.async { [self] in
            var next = config
            next.layout = Planner.place(id, in: section, before: before, layout: config.layout)
            guard save(next) else { publish(); return }
            Store.log("placed \(id) in \(section.rawValue)\(before.map { " before \($0)" } ?? "")")
            tick()
        }
    }

    func setOption(_ key: WritableKeyPath<Options, Bool>, to value: Bool) {
        queue.async { [self] in var next = config; next.options[keyPath: key] = value; _ = save(next); publish() }
    }

    func setArranging(_ on: Bool) {
        // Reveal rejects Shelf's tagged synthetic events before it sends a gesture here.
        queue.async { [self] in
            // Learn only from a whole gesture: a ⌘-mouse-down in the menu bar, then its mouse-up.
            // A stray mouse-up on its own (a late echo of a click) teaches nothing.
            if on { arranging = true; Store.log("user ⌘-drag started") }
            else if arranging { arranging = false; arrangedAt = Date(); Store.log("user ⌘-drag ended") }
        }
    }

    /// Shows a hidden icon in the menu bar and clicks it. It goes back once its menu closes.
    func clickThrough(_ id: String, right: Bool = false) {
        queue.async { [self] in
            clickGeneration += 1
            waitForClick(id, right: right, generation: clickGeneration, deadline: Date().addingTimeInterval(2))
        }
    }

    private func waitForClick(_ id: String, right: Bool, generation: Int, deadline: Date) {
        guard generation == clickGeneration else { return }
        guard Date() < deadline else { Store.log("click: \(id) expired while input remained busy"); return }
        let busy = CGEventSource.buttonState(.combinedSessionState, button: .left) ||
            CGEventSource.buttonState(.combinedSessionState, button: .right) ||
            CGEventSource.buttonState(.combinedSessionState, button: .center) ||
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved) < 0.15
        if busy {
            queue.asyncAfter(deadline: .now() + 0.05) { [self] in
                waitForClick(id, right: right, generation: generation, deadline: deadline)
            }
            return
        }
        performClick(id, right: right)
    }

    private func performClick(_ id: String, right: Bool) {
        guard !arranging && arrangedAt == nil else {
            Store.log("click: \(id) ignored while the user is arranging the menu bar")
            return
        }
        pins[id] = Date()
        icons = scanner.scan()
        guard scanner.pauseReason == nil, storageProblem == nil else {
            pins[id] = nil; publish(); return
        }
        if let icon = icons.first(where: { $0.id == id }) {
            recovery.reset(Appearance(id: id, windowID: icon.windowID))
        }
        reconcile(allowWhileMenuOpen: true)
        icons = scanner.scan()
        guard let icon = icons.first(where: { $0.id == id }) else {
            pins[id] = nil
            Store.log("click: \(id) not found")
            publish()
            return
        }
        guard scanner.pauseReason == nil, let bounds = scanner.displayBounds,
              bounds.contains(CGRect(x: icon.x, y: icon.y, width: icon.width, height: icon.height)) else {
            pins[id] = nil
            Store.log("click: \(id) did not come on screen (x \(Int(icon.x)))")
            publish()
            return
        }
        usleep(50_000)
        if Mover.click(icon, right: right) { Store.log("click: \(id) at x \(Int(icon.x))") }
        else { pins[id] = nil; Store.log("click: \(id) cancelled: target or input changed") }
        publish()
    }

    func refreshNow() { queue.async { [self] in tick() } }

    // MARK: The loop

    private func tick() {
        icons = scanner.scan()
        guard scanner.pauseReason == nil else { publish(); return }
        let ids = icons.map(\.id)
        let layout = config.layout

        // First run with no memory: whatever is in the menu bar now is the layout.
        if layout.hidden.isEmpty && layout.visible.isEmpty, Planner.sections(ids) != nil {
            var next = config
            next.layout = Planner.adopt(actual: ids, into: layout)
            guard save(next) else { publish(); return }
            Store.log("first run: adopted the current menu bar as the layout")
        }

        expirePins()

        // The user just finished a ⌘-drag in the menu bar. Wait a beat for icons to settle, then learn it.
        if let at = arrangedAt, !arranging, Date().timeIntervalSince(at) > 0.8 {
            arrangedAt = nil
            let new = Planner.adopt(actual: ids, into: config.layout, pinned: Set(pins.keys))
            if new != config.layout {
                var next = config; next.layout = new
                guard save(next) else { publish(); return }
                Store.log("learned a ⌘-drag: hidden \(new.hidden.count), visible \(new.visible.count)")
            }
        }

        if !arranging && arrangedAt == nil && Date().timeIntervalSince(started) > 2 {
            reconcile(allowWhileMenuOpen: false)
        }
        publish()
    }

    private func expirePins() {
        guard !pins.isEmpty else { return }
        let menuOpen = WindowServer.menuIsOpen()
        for (id, since) in pins {
            let age = Date().timeIntervalSince(since)
            // Keep it while its menu is open (and at least 1.5 s); never longer than 5 minutes.
            if (age > 1.5 && !menuOpen) || age > 300 {
                pins[id] = nil
                if let icon = icons.first(where: { $0.id == id }) {
                    recovery.reset(Appearance(id: id, windowID: icon.windowID))
                }
                Store.log("unpinned \(id)")
            }
        }
    }

    /// Closed loop: plan, do one move, look again. At most 8 moves per tick.
    private func reconcile(allowWhileMenuOpen: Bool) {
        for _ in 0..<8 {
            guard scanner.pauseReason == nil, storageProblem == nil else { return }
            let ids = icons.map(\.id)
            guard let target = Planner.target(actual: ids, layout: config.layout, pinned: Set(pins.keys)) else { return }
            let now = Date()
            let appearances = Set(icons.map { Appearance(id: $0.id, windowID: $0.windowID) })
            let context = "\(config.layout.hidden)|\(config.layout.visible)"
            recovery.synchronize(active: appearances, context: context, now: now)
            guard let move = Planner.moves(actual: ids, target: target).first(where: { move in
                guard let icon = icons.first(where: { $0.id == move.id }) else { return false }
                return !recovery.isBenched(Appearance(id: icon.id, windowID: icon.windowID), now: now)
            }) else { return }

            // Never fight the person: no moves while a mouse button is down or the mouse just moved,
            // and none while a menu is open (except the move that shows a clicked icon).
            if CGEventSource.buttonState(.combinedSessionState, button: .left) { return }
            if !allowWhileMenuOpen {
                if CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved) < 0.15 { return }
                if WindowServer.menuIsOpen() { return }
            }

            guard let icon = icons.first(where: { $0.id == move.id }),
                  let anchor = icons.first(where: { $0.id == move.anchor }) else { return }
            let outcome = Mover.move(icon, move.side, of: anchor)
            Store.log("move \(move) \(outcome.rawValue)")
            func short(_ ids: [String]) -> String { ids.map { $0.split(separator: "/").first.map { String($0.split(separator: ".").last ?? "") } ?? $0 }.joined(separator: " ") }
            Store.log("  before: \(short(ids))")

            // Landing a slot off is progress: re-plan at once. Only a stuck icon backs off.
            // A slot-off landing is progress: it clears the failure streak (Codex audit finding 5).
            // But three slot-off landings in a row is a loop (2026-10-06: 413 drags in 4 minutes), so back off.
            let appearance = Appearance(id: move.id, windowID: icon.windowID)
            if outcome == .elsewhere {
                if case let .slotOff(count, retryAfter) = recovery.recordSlotOff(appearance, now: now),
                   let retryAfter {
                    Store.log("\(move.id) landed a slot off \(count) times in a row; trying again in \(retryAfter) s")
                }
            } else if outcome == .placed {
                if case let .fight(seconds)? = recovery.recordPlaced(appearance, now: now) {
                    Store.log("\(move.id) keeps going back after moves; leaving this appearance alone for \(seconds / 60) minutes")
                }
            } else if case let .retryAfter(attempt, seconds) = recovery.recordStuck(appearance, now: now) {
                Store.log("\(move.id) did not move (\(attempt) in a row); trying again in \(seconds) s")
            }

            // Wait until the window list shows the change, so the next plan sees the real order.
            let before = ids
            for _ in 0..<10 {
                icons = scanner.scan()
                if icons.map(\.id) != before { break }
                usleep(30_000)
            }
            Store.log("  after:  \(short(icons.map(\.id)))")
        }
    }

    private func publish() {
        let snap = Snapshot(icons: icons, layout: config.layout, pinned: Set(pins.keys), pauseReason: storageProblem ?? scanner.pauseReason, options: config.options)
        DispatchQueue.main.async { self.onUpdate(snap) }
    }

    private func save(_ next: Config) -> Bool {
        guard Store.save(next) else { storageProblem = "layout could not be saved; see shelf.log"; return false }
        config = next
        storageProblem = nil
        return true
    }
}

import AppKit
import ShelfCore

/// The loop: scan the menu bar, compare it with the layout memory, fix drift. Twice a second (a scan costs about 1 ms).
/// Everything here runs on one serial queue, so there is never more than one move in flight.
final class Engine {
    struct Snapshot { var icons: [Icon]; var layout: Layout; var pinned: Set<String> }

    let queue = DispatchQueue(label: "shelf.engine", qos: .userInitiated)
    private let scanner = Scanner()
    private var config: Config
    private var icons: [Icon] = []
    private var timer: DispatchSourceTimer?
    private let started = Date()

    /// Hidden icons the user clicked from the shelf bar, shown in the menu bar for a moment.
    private var pins: [String: Date] = [:]
    /// The user is ⌘-dragging in the menu bar. When they let go, reality becomes the layout.
    private var arranging = false
    private var arrangedAt: Date?
    /// Per appearance (icon id + window): failed moves in a row, and successful moves that did not stay.
    private var failures: [String: Int] = [:]
    private var successes: [String: [Date]] = [:]
    /// Per appearance: moves in a row that landed a slot off. An icon that never lands is a loop, not progress.
    private var slotOffs: [String: Int] = [:]
    /// What the world looked like at the last successful move. A layout change or a click is a reason
    /// to move again, not a fight.
    private var successContext: [String: String] = [:]
    /// Icons to skip until a time: a short back-off after a failed move, a long one after a fight.
    private var benched: [String: Date] = [:]

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
            config.layout = Planner.place(id, in: section, before: before, layout: config.layout)
            Store.save(config)
            Store.log("placed \(id) in \(section.rawValue)\(before.map { " before \($0)" } ?? "")")
            tick()
        }
    }

    func setOptions(_ options: Options) {
        queue.async { [self] in config.options = options; Store.save(config) }
    }

    func setArranging(_ on: Bool) {
        // Signals during or just after shelf's own moves are echoes of them, not the user.
        if Date().timeIntervalSince(Mover.lastPost) < 0.5 { return }
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
            pins[id] = Date()
            icons = scanner.scan()
            reconcile(allowWhileMenuOpen: true)
            icons = scanner.scan()
            guard let icon = icons.first(where: { $0.id == id }) else { Store.log("click: \(id) not found"); return }
            guard icon.x >= 0 else { Store.log("click: \(id) did not come on screen (x \(Int(icon.x)))"); return }
            usleep(50_000)
            Mover.click(icon, right: right)
            Store.log("click: \(id) at x \(Int(icon.x))")
            publish()
        }
    }

    func refreshNow() { queue.async { [self] in tick() } }

    // MARK: The loop

    private func tick() {
        icons = scanner.scan()
        let ids = icons.map(\.id)
        let layout = config.layout

        // First run with no memory: whatever is in the menu bar now is the layout.
        if layout.hidden.isEmpty && layout.visible.isEmpty, Planner.sections(ids) != nil {
            config.layout = Planner.adopt(actual: ids, into: layout)
            Store.save(config)
            Store.log("first run: adopted the current menu bar as the layout")
        }

        expirePins()

        // The user just finished a ⌘-drag in the menu bar. Wait a beat for icons to settle, then learn it.
        if let at = arrangedAt, !arranging, Date().timeIntervalSince(at) > 0.8 {
            arrangedAt = nil
            let new = Planner.adopt(actual: ids, into: config.layout, pinned: Set(pins.keys))
            if new != config.layout {
                config.layout = new
                Store.save(config)
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
                Store.log("unpinned \(id)")
            }
        }
    }

    /// Closed loop: plan, do one move, look again. At most 8 moves per tick.
    private func reconcile(allowWhileMenuOpen: Bool) {
        for _ in 0..<8 {
            let ids = icons.map(\.id)
            guard let target = Planner.target(actual: ids, layout: config.layout, pinned: Set(pins.keys)) else { return }
            let now = Date()
            benched = benched.filter { $0.value > now }
            guard let move = Planner.moves(actual: ids, target: target).first(where: { benched[$0.id] == nil }) else { return }

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
            let key = "\(move.id)#\(icon.windowID)"
            if outcome == .elsewhere {
                failures[key] = nil
                let n = (slotOffs[key] ?? 0) + 1
                slotOffs[key] = n
                if n >= 3 {
                    let wait = min(60, pow(2, Double(n - 3)))  // 1, 2, 4 ... 60 s
                    benched[move.id] = now.addingTimeInterval(wait)
                    Store.log("\(move.id) landed a slot off \(n) times in a row; trying again in \(Int(wait)) s")
                }
            } else {
                if outcome == .placed { slotOffs[key] = nil }
                note(move.id, icon.windowID, ok: outcome == .placed, now: now)
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

    /// A failed move is retried after 1, 2, 4, ... up to 60 seconds, forever: it is usually transient.
    /// A move that works but does not stay (the app puts its icon back) three times in two minutes is a
    /// fight, and shelf leaves that icon alone for 10 minutes. Counted per appearance: an icon that comes
    /// back 40 times a day needs 40 moves, and that is the job.
    private func note(_ id: String, _ window: CGWindowID, ok: Bool, now: Date) {
        let key = "\(id)#\(window)"
        if ok {
            failures[key] = nil
            let context = "\(config.layout.hidden)|\(config.layout.visible)|\(pins.keys.sorted())"
            if successContext[key] != context { successes[key] = []; successContext[key] = context }
            let recent = (successes[key] ?? []).filter { now.timeIntervalSince($0) < 120 } + [now]
            successes[key] = recent
            if recent.count >= 3 {
                benched[id] = now.addingTimeInterval(600)
                successes[key] = []
                Store.log("\(id) keeps going back after moves; leaving it alone for 10 minutes")
            }
        } else {
            let n = (failures[key] ?? 0) + 1
            failures[key] = n
            let wait = min(60, pow(2, Double(n - 1)))  // 1, 2, 4 ... 60 s
            benched[id] = now.addingTimeInterval(wait)
            Store.log("\(id) did not move (\(n) in a row); trying again in \(Int(wait)) s")
        }
    }

    private func publish() {
        let snap = Snapshot(icons: icons, layout: config.layout, pinned: Set(pins.keys))
        DispatchQueue.main.async { self.onUpdate(snap) }
    }
}

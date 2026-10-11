import AppKit
import ShelfCore

/// The one list every view draws from. Lives on the main thread.
/// Views never keep their own copy: when the list changes, every view redraws from it.
final class Model: ObservableObject {
    @Published private(set) var icons: [Icon] = []
    @Published private(set) var layout = Layout()
    @Published private(set) var images: [String: NSImage] = [:]
    @Published var options = Options()
    @Published var lastCheck = "not run yet"
    @Published var barOpen = false
    @Published var settingsOpen = false
    /// Menu bar icons are drawn white on a dark menu bar. Read from the shelf icon's own appearance.
    @Published var menuBarIsDark = true

    private(set) var pinned: Set<String> = []
    let engine: Engine

    /// What each view last drew, for `shelf check`.
    private var barRendered: [String]?
    private var settingsRendered: Layout?

    init(engine: Engine, options: Options) {
        self.engine = engine
        self.options = options
    }

    var sections: (hidden: [Icon], visible: [Icon]) {
        guard let s = Planner.sections(icons.map(\.id)) else { return ([], []) }
        let byID = Dictionary(icons.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return (s.hidden.compactMap { byID[$0] }, s.visible.compactMap { byID[$0] })
    }

    func icon(_ id: String) -> Icon? { icons.first { $0.id == id } }

    func apply(_ snap: Engine.Snapshot) {
        if snap.icons != icons { icons = snap.icons }
        if snap.layout != layout { layout = snap.layout }
        pinned = snap.pinned
        // A picture belongs to a window, not just an id. Drop pictures whose icon is gone or now lives in
        // another window (an app re-created its item). No stale pictures, ever (Codex follow-up F1).
        let windows = Dictionary(icons.map { ($0.id, $0.windowID) }, uniquingKeysWith: { a, _ in a })
        if windows != lastWindows {
            lastWindows = windows
            generation += 1  // a capture already running is now outdated
            if capturing { captureAgain = true }
        }
        let stale = images.keys.filter { imageWindows[$0] != windows[$0] }
        if !stale.isEmpty { for id in stale { images[id] = nil; imageWindows[id] = nil } }
        writeState()
    }

    // MARK: Picture refresh: one owner, one capture at a time (Codex audit finding 3)

    private var refreshOwners: Set<String> = []
    private var refreshTimer: Timer?
    private var capturing = false
    private var captureAgain = false
    private var generation = 0
    private var lastWindows: [String: UInt32] = [:]
    /// The window each picture was taken from.
    private var imageWindows: [String: UInt32] = [:]
    var onImages: () -> Void = {}

    /// The shelf bar and the settings window each say when they need pictures. One timer serves both.
    func needPictures(_ owner: String, _ on: Bool) {
        if on { refreshOwners.insert(owner) } else { refreshOwners.remove(owner) }
        if !refreshOwners.isEmpty, refreshTimer == nil {
            refreshImages()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshImages() }
        } else if refreshOwners.isEmpty {
            refreshTimer?.invalidate(); refreshTimer = nil
        }
    }

    // MARK: Pictures

    /// Captures every icon in two pictures (hidden group, visible group) and crops each one out.
    /// One capture at a time; a request during a capture runs once after it; an outdated result is dropped.
    func refreshImages() {
        if capturing { captureAgain = true; return }
        capturing = true
        generation += 1
        let myGeneration = generation
        let groups = [sections.hidden, sections.visible.filter { $0.bundle != IDs.bundle }]
        DispatchQueue.global(qos: .userInitiated).async {
            var out: [String: (NSImage, UInt32)] = [:]
            for group in groups where !group.isEmpty {
                let union = group.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
                guard let img = WindowServer.capture(group.map(\.windowID)), union.width > 0 else { continue }
                let scale = CGFloat(img.width) / union.width
                for icon in group {
                    let r = CGRect(x: (icon.x - union.minX) * scale, y: (icon.y - union.minY) * scale,
                                   width: icon.width * scale, height: icon.height * scale).integral
                    if let crop = img.cropping(to: r) {
                        out[icon.id] = (NSImage(cgImage: crop, size: NSSize(width: icon.width, height: icon.height)), icon.windowID)
                    }
                }
            }
            DispatchQueue.main.async {
                self.capturing = false
                // Publish only if nothing changed while capturing, and only pictures of the current windows.
                if myGeneration == self.generation {
                    let fresh = out.filter { self.lastWindows[$0.key] == $0.value.1 }
                    self.images = fresh.mapValues(\.0)
                    self.imageWindows = fresh.mapValues(\.1)
                    self.onImages()
                }
                if self.captureAgain { self.captureAgain = false; self.refreshImages() }
            }
        }
    }

    // MARK: Views report what they drew

    func barDrew(_ ids: [String]?) { if barRendered != ids { barRendered = ids; writeState() } }
    func settingsDrew(_ layout: Layout?) { if settingsRendered != layout { settingsRendered = layout; writeState() } }

    /// Writes state.json only when it changed, plus a heartbeat every 10 s (so `shelf check` can tell a hung
    /// app from a quiet one). Encoding and the write happen off the main thread (Codex audit finding 4).
    private var lastWritten: State?
    private let writer = DispatchQueue(label: "shelf.state", qos: .utility)
    private func writeState() {
        let now = Date()
        var state = State(updated: now, icons: icons.map(\.id), bar: barRendered, settings: settingsRendered, pinned: pinned.sorted())
        if let last = lastWritten {
            var same = last; same.updated = now
            if same == state && now.timeIntervalSince(last.updated) < 10 { return }
            if same == state { state.updated = now }
        }
        lastWritten = state
        writer.async { Store.save(state) }
    }

    // MARK: Actions

    func click(_ id: String, right: Bool = false) { engine.clickThrough(id, right: right) }

    /// Settings drag: the engine edits the remembered layout directly (see Planner.place).
    func place(_ id: String, in section: Section, before: String?) {
        engine.place(id, in: section, before: before)
    }

    func setOptions(_ o: Options) { options = o; engine.setOptions(o) }
}

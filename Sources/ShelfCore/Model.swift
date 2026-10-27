import Foundation

/// One menu bar icon as it exists right now.
public struct Icon: Codable, Equatable, Sendable {
    /// Stable across launches: "<bundle id>/<window name>", e.g. "com.knollsoft.Rectangle/Item-0".
    public var id: String
    public var windowID: UInt32
    public var pid: Int32
    public var bundle: String
    /// The status item's window name (its autosave name, e.g. "Item-0", "Clock").
    public var name: String
    /// A human label from Accessibility (title or description), may be empty.
    public var label: String
    /// Window frame in global display coordinates (origin top-left of the main display).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(id: String, windowID: UInt32, pid: Int32, bundle: String, name: String, label: String,
                x: Double, y: Double, width: Double, height: Double) {
        self.id = id; self.windowID = windowID; self.pid = pid; self.bundle = bundle
        self.name = name; self.label = label; self.x = x; self.y = y; self.width = width; self.height = height
    }

    public var maxX: Double { x + width }
    public var midX: Double { x + width / 2 }

    /// A short name for people: the app's last bundle component plus the label when it helps.
    public var displayName: String {
        let app = bundle.split(separator: ".").last.map(String.init) ?? bundle
        return label.isEmpty || label == app ? app : "\(app) · \(label)"
    }
}

public enum Section: String, Codable, Sendable { case hidden, visible }

/// Where each icon belongs, left to right. This is the only thing shelf remembers.
/// Icons that are absent right now stay in the lists, so they land in the same place when they come back.
public struct Layout: Codable, Equatable, Sendable {
    public var hidden: [String]
    public var visible: [String]
    public init(hidden: [String] = [], visible: [String] = []) { self.hidden = hidden; self.visible = visible }

    public func section(of id: String) -> Section? {
        if hidden.contains(id) { return .hidden }
        if visible.contains(id) { return .visible }
        return nil
    }
}

public enum IDs {
    public static let bundle = "com.aaqifz.shelf"
    public static let controlCenterBundle = "com.apple.controlcenter"
    /// The divider: a status item 10,000 points long. Everything left of it is pushed off the screen.
    public static let divider = "\(bundle)/shelf.divider"
    /// The shelf icon: always visible, just right of the divider.
    public static let icon = "\(bundle)/shelf.icon"

    public static func isAnchor(_ id: String) -> Bool { id == divider || id == icon }

    /// Control Center's own icons (Wi-Fi, Battery, ...). macOS keeps them as one block at the right:
    /// another app's icon cannot be dropped among or right of them (verified on macOS 26).
    public static func isSystemBlock(_ id: String) -> Bool { id.hasPrefix("com.apple.controlcenter/") }

    /// WindowServer exposes these immovable macOS items by stable names, but Accessibility does not
    /// always expose matching extras. Scanner also requires the name to be unique before fallback.
    public static func isKnownControlCenterWindow(_ name: String?) -> Bool {
        guard let name else { return false }
        return name == "Clock" || name.hasPrefix("BentoBox")
    }

    public static func canUseControlCenterFallback(_ name: String?, among names: [String?]) -> Bool {
        guard isKnownControlCenterWindow(name), let name else { return false }
        return names.lazy.filter { $0 == name }.count == 1
    }

    /// macOS does not let these move. They stay where they are and are never hidden.
    public static func isFixed(_ id: String) -> Bool {
        id == "com.apple.controlcenter/Clock" || id.hasPrefix("com.apple.controlcenter/BentoBox")
    }

    /// A window named after one app cannot belong to another. On 9 Oct a shelf window named
    /// "com.aaqifz.shelf" sat within 3 px of Rectangle's icon, was taken for Rectangle's, and was moved.
    public static func ownerFits(windowName: String?, owner: String, apps: Set<String>) -> Bool {
        guard let n = windowName, n != owner else { return true }
        return n != bundle && !apps.contains(n)
    }
}

/// macOS 26 draws the menu bar on every display, each with its own status item windows. The real
/// windows sit on one display at a time and follow the user; the other displays get copies, named
/// after the app, its pid, or nothing. On 25 Oct a display left of the main one put both sets at y 0:
/// shelf saw every icon twice and made 121 drags in 5 minutes that could never land.
/// The real windows are one unbroken strip that holds shelf's own icon (a copy is never named "shelf.icon").
public enum Strip {
    public struct Window: Equatable, Sendable {
        public var id: UInt32
        public var minX: Double
        public var maxX: Double
        public init(id: UInt32, minX: Double, maxX: Double) { self.id = id; self.minX = minX; self.maxX = maxX }
    }

    /// The windows edge to edge with `anchor`, when the anchor is on the main display (`mainMinX...mainMaxX`).
    /// None otherwise: shelf manages the main display only, so it waits until the icons come back.
    public static func real(_ windows: [Window], anchor: UInt32?, mainMinX: Double, mainMaxX: Double) -> Set<UInt32> {
        guard let start = windows.first(where: { $0.id == anchor }),
              start.minX >= mainMinX - 1, start.maxX <= mainMaxX + 1 else { return [] }
        var strip: Set<UInt32> = [start.id]
        func touching(_ edge: Double, _ side: KeyPath<Window, Double>) -> Window? {
            windows.filter { !strip.contains($0.id) && abs($0[keyPath: side] - edge) <= 1 }
                .min { abs($0[keyPath: side] - edge) < abs($1[keyPath: side] - edge) }
        }
        var left = start, right = start
        while let w = touching(left.minX, \.maxX) { strip.insert(w.id); left = w }
        while let w = touching(right.maxX, \.minX) { strip.insert(w.id); right = w }
        return strip
    }
}

/// What the running app writes after every change, so `shelf check` can compare it with reality.
public struct State: Codable, Equatable, Sendable {
    public var updated: Date
    /// The app's live list, left to right.
    public var icons: [String]
    /// What the shelf bar last drew, left to right. Nil while the bar is closed.
    public var bar: [String]?
    /// What the settings window last drew. Nil while the window is closed.
    public var settings: Layout?
    /// Icons shown in the menu bar for a moment after a click from the shelf bar.
    public var pinned: [String]
    public var pauseReason: String?

    public init(updated: Date, icons: [String], bar: [String]?, settings: Layout?, pinned: [String], pauseReason: String? = nil) {
        self.updated = updated; self.icons = icons; self.bar = bar; self.settings = settings; self.pinned = pinned
        self.pauseReason = pauseReason
    }
}

/// User options. Small on purpose.
public struct Options: Codable, Equatable, Sendable {
    public var revealOnHover = true
    public var revealOnClick = true
    public var revealOnScroll = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case revealOnHover, revealOnClick, revealOnScroll }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revealOnHover = try values.decodeIfPresent(Bool.self, forKey: .revealOnHover) ?? true
        revealOnClick = try values.decodeIfPresent(Bool.self, forKey: .revealOnClick) ?? true
        revealOnScroll = try values.decodeIfPresent(Bool.self, forKey: .revealOnScroll) ?? true
    }
}

/// Everything in ~/.shelf/config.json.
public struct Config: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var layout = Layout()
    public var options = Options()
    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, layout, options }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values, debugDescription: "unsupported configuration version")
        }
        layout = try values.decode(Layout.self, forKey: .layout)
        options = try values.decodeIfPresent(Options.self, forKey: .options) ?? Options()
        let ids = layout.hidden + layout.visible
        guard Set(ids).count == ids.count, !ids.contains(where: { $0.isEmpty || IDs.isAnchor($0) }) else {
            throw DecodingError.dataCorruptedError(forKey: .layout, in: values, debugDescription: "layout contains duplicate, empty or reserved identities")
        }
    }
}

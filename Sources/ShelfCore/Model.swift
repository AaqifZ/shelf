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
    /// The divider: a status item 10,000 points long. Everything left of it is pushed off the screen.
    public static let divider = "\(bundle)/shelf.divider"
    /// The shelf icon: always visible, just right of the divider.
    public static let icon = "\(bundle)/shelf.icon"

    public static func isAnchor(_ id: String) -> Bool { id == divider || id == icon }

    /// Control Center's own icons (Wi-Fi, Battery, ...). macOS keeps them as one block at the right:
    /// another app's icon cannot be dropped among or right of them (verified on macOS 26).
    public static func isSystemBlock(_ id: String) -> Bool { id.hasPrefix("com.apple.controlcenter/") }

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

    public init(updated: Date, icons: [String], bar: [String]?, settings: Layout?, pinned: [String]) {
        self.updated = updated; self.icons = icons; self.bar = bar; self.settings = settings; self.pinned = pinned
    }
}

/// User options. Small on purpose.
public struct Options: Codable, Equatable, Sendable {
    public var revealOnHover = true
    public var revealOnClick = true
    public var revealOnScroll = true
    public init() {}
}

/// Everything in ~/.shelf/config.json.
public struct Config: Codable, Equatable, Sendable {
    public var layout = Layout()
    public var options = Options()
    public init() {}
}

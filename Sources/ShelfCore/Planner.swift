import Foundation

/// One physical move: put `id` directly left (or right) of `anchor`.
public struct Move: Equatable, Sendable, CustomStringConvertible {
    public enum Side: String, Sendable { case leftOf, rightOf }
    public var id: String
    public var side: Side
    public var anchor: String
    public init(_ id: String, _ side: Side, _ anchor: String) { self.id = id; self.side = side; self.anchor = anchor }
    public var description: String { "\(id) \(side.rawValue) \(anchor)" }
}

/// Pure functions from (reality, memory) to (target, moves). No AppKit, fully tested.
/// All orders are left to right.
public enum Planner {

    /// Splits a left-to-right order at the anchors. Icons between the divider and the shelf icon
    /// count as hidden: that is where a ⌘-drag "onto the shelf" lands.
    public static func sections(_ order: [String]) -> (hidden: [String], visible: [String])? {
        guard Set(order).count == order.count,
              let i = order.firstIndex(of: IDs.icon), let divider = order.firstIndex(of: IDs.divider), divider < i else { return nil }
        let left = order[..<i].filter { !IDs.isAnchor($0) }
        let right = order[(i + 1)...].filter { !IDs.isAnchor($0) }
        return (Array(left), Array(right))
    }

    /// The order the menu bar should have, for the icons present now.
    /// - New icons (not in the layout) go to the far left of hidden.
    /// - Pinned icons (shown for a click) sit just right of the shelf icon.
    /// - Control Center's icons stay one block right of other apps' icons (macOS insists).
    /// - Fixed icons (Clock, Control Center) keep their place at the right end.
    /// Returns nil when shelf's own two items are not both present yet.
    public static func target(actual: [String], layout: Layout, pinned: Set<String> = []) -> [String]? {
        guard actual.contains(IDs.divider), actual.contains(IDs.icon) else { return nil }
        let present = Set(actual)
        var seen = Set<String>()
        func take(_ ids: [String]) -> [String] {
            ids.filter { present.contains($0) && !IDs.isAnchor($0) && !IDs.isFixed($0) && !pinned.contains($0) && seen.insert($0).inserted }
        }
        let hiddenKnown = take(layout.hidden)
        let visibleKnown = take(layout.visible)
        let fresh = take(actual)  // whatever is left is new to shelf
        let pins = actual.filter { pinned.contains($0) && !IDs.isAnchor($0) && !IDs.isFixed($0) }
        let fixed = actual.filter(IDs.isFixed)
        // Visible: other apps first, then Control Center's block, then the fixed items.
        let visibleApps = visibleKnown.filter { !IDs.isSystemBlock($0) }
        let visibleSystem = visibleKnown.filter(IDs.isSystemBlock)
        return fresh + hiddenKnown + [IDs.divider, IDs.icon] + pins + visibleApps + visibleSystem + fixed
    }

    /// The moves that turn `actual` into `target`. Icons on the longest common subsequence (LCS) stay.
    /// Each other icon is anchored on the nearest icon that is already in place: on its right if that
    /// is not a fixed item (macOS refuses drops onto Clock and Control Center), else on its left.
    /// Either way the icon lands between two in-place icons, so every move grows the LCS by one and
    /// the engine's closed loop (do the first move, look again, re-plan) always finishes.
    public static func moves(actual: [String], target: [String]) -> [Move] {
        guard Set(actual) == Set(target), actual != target else { return [] }
        let keep = lcs(actual, target)
        var result: [Move] = []
        for i in stride(from: target.count - 1, through: 0, by: -1) where !keep.contains(target[i]) {
            let right = target[(i + 1)...].first { keep.contains($0) }
            let left = target[..<i].last { keep.contains($0) }
            if let right, !IDs.isFixed(right) { result.append(Move(target[i], .leftOf, right)) }
            else if let left { result.append(Move(target[i], .rightOf, left)) }
            else if let right { result.append(Move(target[i], .leftOf, right)) }
        }
        return result
    }

    /// Applies one move to an order. Used by the tests, and to sanity-check plans.
    public static func apply(_ move: Move, to order: [String]) -> [String] {
        var o = order.filter { $0 != move.id }
        guard let a = o.firstIndex(of: move.anchor) else { return order }
        o.insert(move.id, at: move.side == .leftOf ? a : a + 1)
        return o
    }

    /// The user rearranged the real menu bar: reality becomes the new memory.
    /// Icons that are absent now keep their old section and stay next to their old left neighbour.
    public static func adopt(actual: [String], into old: Layout, pinned: Set<String> = []) -> Layout {
        guard let s = sections(actual) else { return old }
        // A pinned icon is only visiting the visible side. It keeps its remembered section.
        var hidden = s.hidden.filter { !pinned.contains($0) && !IDs.isFixed($0) }
        var visible = s.visible.filter { !pinned.contains($0) && !IDs.isFixed($0) }
        for id in pinned {
            if old.section(of: id) == .visible { visible.insert(id, at: 0) } else { hidden.append(id) }
        }
        let present = Set(actual)
        return Layout(hidden: merge(hidden, absentFrom: old.hidden, present: present),
                      visible: merge(visible, absentFrom: old.visible, present: present))
    }

    /// A Settings drag: edit the remembered layout directly. Reality is not read, so an icon that is only
    /// visiting (shown for a click) keeps its remembered section (Codex audit 2026-10-04, finding 1).
    public static func place(_ id: String, in section: Section, before: String?, layout: Layout) -> Layout {
        guard !IDs.isFixed(id), !IDs.isAnchor(id) else { return layout }
        var hidden = layout.hidden.filter { $0 != id }
        var visible = layout.visible.filter { $0 != id }
        func insert(into list: inout [String]) {
            if let before, before != id, let i = list.firstIndex(of: before) { list.insert(id, at: i) } else { list.append(id) }
        }
        if section == .hidden { insert(into: &hidden) } else { insert(into: &visible) }
        return Layout(hidden: hidden, visible: visible)
    }

    /// Puts each absent id from `old` back after the id that preceded it there (or at the front).
    static func merge(_ now: [String], absentFrom old: [String], present: Set<String>) -> [String] {
        var out = now
        for (i, id) in old.enumerated() where !present.contains(id) && !out.contains(id) {
            let before = old[..<i].last { out.contains($0) }
            if let before, let j = out.firstIndex(of: before) { out.insert(id, at: j + 1) } else { out.insert(id, at: 0) }
        }
        return out
    }

    /// Longest common subsequence of two orders, as a set of ids.
    static func lcs(_ a: [String], _ b: [String]) -> Set<String> {
        let n = a.count, m = b.count
        var t = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var out = Set<String>(), i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] { out.insert(a[i]); i += 1; j += 1 } else if t[i + 1][j] >= t[i][j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }
}

/// Compares the four places that must agree. Empty result = OK.
public enum Check {
    public static func livenessProblems(state: State?, now: Date = Date()) -> [String] {
        guard let state else { return ["no state from the app"] }
        let age = now.timeIntervalSince(state.updated)
        return age > 30 ? ["app has not updated for \(Int(age)) s (hung?)"] : []
    }
    public static func problems(reality: [String], state: State?, layout: Layout, now: Date = Date()) -> [String] {
        var out: [String] = []
        guard let s = Planner.sections(reality) else {
            return ["shelf is not running (its divider and icon are not in the menu bar)"]
        }
        let pinned = Set(state?.pinned ?? [])
        if let target = Planner.target(actual: reality, layout: layout, pinned: pinned), target != reality {
            let wrong = Planner.moves(actual: reality, target: target).map(\.id)
            out.append("menu bar ≠ memory: \(wrong.joined(separator: ", ")) out of place")
        }
        guard let state else { return out + ["no state from the app"] }
        if let reason = state.pauseReason { out.append("app is paused: \(reason)") }
        // The app rewrites its state at least every 10 s. Older than 30 s means it is hung (or gone).
        out += livenessProblems(state: state, now: now)
        if state.icons != reality { out.append("app's live list ≠ menu bar") }
        if let bar = state.bar, bar != s.hidden { out.append("shelf bar ≠ hidden icons") }
        if let settings = state.settings, settings.hidden != s.hidden || settings.visible != s.visible {
            out.append("settings window ≠ menu bar")
        }
        return out
    }
}

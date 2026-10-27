import Foundation

/// One appearance of an icon. A recreated status item has a new window id and starts with clean recovery state.
public struct Appearance: Hashable, Sendable {
    public var id: String
    public var windowID: UInt32

    public init(id: String, windowID: UInt32) {
        self.id = id
        self.windowID = windowID
    }
}

/// The deterministic part of move recovery. The engine owns the clock and performs the actual moves.
public struct RecoveryPolicy: Sendable {
    public enum Event: Equatable, Sendable {
        case retryAfter(attempt: Int, seconds: Int)
        case slotOff(count: Int, retryAfter: Int?)
        case fight(seconds: Int)
    }

    private var failures: [Appearance: Int] = [:]
    private var slotOffs: [Appearance: Int] = [:]
    private var successes: [Appearance: [Date]] = [:]
    private var benches: [Appearance: Date] = [:]
    private var context: String?

    public init() {}

    /// Removes state for status item windows that no longer exist. A new layout context clears all old
    /// recovery state because Shelf is now trying to achieve a different arrangement.
    public mutating func synchronize(active: Set<Appearance>, context newContext: String, now: Date) {
        if context != newContext {
            context = newContext
            failures.removeAll(keepingCapacity: true)
            slotOffs.removeAll(keepingCapacity: true)
            successes.removeAll(keepingCapacity: true)
            benches.removeAll(keepingCapacity: true)
        }
        failures = failures.filter { active.contains($0.key) }
        slotOffs = slotOffs.filter { active.contains($0.key) }
        successes = successes.filter { active.contains($0.key) }
        benches = benches.filter { active.contains($0.key) && $0.value > now }
    }

    public func isBenched(_ appearance: Appearance, now: Date) -> Bool {
        benches[appearance].map { $0 > now } ?? false
    }

    /// Clears recovery state for one appearance after a click or another explicit user action.
    /// Other icons keep their independent retries and fight cooldowns.
    public mutating func reset(_ appearance: Appearance) {
        failures[appearance] = nil
        slotOffs[appearance] = nil
        successes[appearance] = nil
        benches[appearance] = nil
    }

    /// A move that did not lift. Retry after 1, 2, 4 ... 60 seconds.
    public mutating func recordStuck(_ appearance: Appearance, now: Date) -> Event {
        let attempt = (failures[appearance] ?? 0) + 1
        failures[appearance] = attempt
        let seconds = min(60, Self.powerOfTwo(attempt - 1))
        benches[appearance] = now.addingTimeInterval(TimeInterval(seconds))
        return .retryAfter(attempt: attempt, seconds: seconds)
    }

    /// A move landed in another slot. It is progress at first, then backs off if it forms a loop.
    public mutating func recordSlotOff(_ appearance: Appearance, now: Date) -> Event {
        failures[appearance] = nil
        let count = (slotOffs[appearance] ?? 0) + 1
        slotOffs[appearance] = count
        guard count >= 3 else { return .slotOff(count: count, retryAfter: nil) }
        let seconds = min(60, Self.powerOfTwo(count - 3))
        benches[appearance] = now.addingTimeInterval(TimeInterval(seconds))
        return .slotOff(count: count, retryAfter: seconds)
    }

    /// A placed icon that returns three times in two minutes is fighting Shelf. Leave this appearance alone.
    public mutating func recordPlaced(_ appearance: Appearance, now: Date) -> Event? {
        failures[appearance] = nil
        slotOffs[appearance] = nil
        let recent = (successes[appearance] ?? []).filter { now.timeIntervalSince($0) < 120 } + [now]
        successes[appearance] = recent
        guard recent.count >= 3 else { return nil }
        successes[appearance] = []
        benches[appearance] = now.addingTimeInterval(600)
        return .fight(seconds: 600)
    }

    private static func powerOfTwo(_ exponent: Int) -> Int {
        1 << min(max(exponent, 0), 6)
    }
}

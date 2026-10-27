import AppKit
import ShelfCore

/// Moves and clicks other apps' icons with synthesised mouse events.
/// macOS has no API for this. A ⌘-drag aimed at the icon's window is what a person would do,
/// so that is what we send. Posted at the session tap: on macOS 26 posting to the app's pid does nothing.
enum Mover {
    private static let source = CGEventSource(stateID: .hidSystemState)
    /// Undocumented field Ice and Thaw set on move events: the window being dragged.
    private static let windowField = CGEventField(rawValue: 0x33)!
    /// Every event shelf posts carries this, so shelf's own listeners can tell them from the user's.
    static let signature: Int64 = 0x5348_454C_46  // "SHELF"
    /// Last time shelf posted an event. Arranging signals near it are shelf's own.
    private(set) static var lastPost = Date.distantPast

    enum Outcome: String { case placed, elsewhere, stuck }

    /// Puts `icon` directly left or right of `anchor`.
    /// `placed`: it is there. `elsewhere`: it moved but landed in another slot (the engine re-plans at once).
    /// `stuck`: it did not move at all (the engine backs off and retries).
    @discardableResult
    static func move(_ icon: Icon, _ side: Move.Side, of anchor: Icon) -> Outcome {
        guard inputIsIdle(), !IDs.isFixed(icon.id),
              let a = currentFrame(icon), let b = currentFrame(anchor), abs(a.minY - b.minY) <= 1 else { return .stuck }
        // Same geometry as Ice: press at the anchor's edge, release one icon-width over when moving right.
        var start = CGPoint(x: side == .leftOf ? b.minX : b.maxX, y: b.minY)
        var end = start
        switch side {
        case .leftOf: if a.maxX <= b.minX { end.x -= a.width } else { start.x -= 1 }
        case .rightOf: if a.minX <= b.maxX { end.x -= a.width } else { start.x += 1 }
        }
        let revision = movementRevision()
        return withCursorParked {
            if drag(icon, anchor: anchor, from: a, press: start, release: end, side: side) { return .placed }
            guard movementRevision() == revision else { return .stuck }
            guard let a2 = WindowServer.frame(icon.windowID) else { return .stuck }
            guard inputIsIdle() else { return .stuck }
            if a2.origin != a.origin { return .elsewhere }
            // It did not lift. Second grip (Thaw's "source-anchored" move): press on the icon itself.
            if drag(icon, anchor: anchor, from: a2, press: CGPoint(x: a2.midX, y: a2.minY), release: end, side: side) { return .placed }
            return WindowServer.frame(icon.windowID)?.origin != a2.origin ? .elsewhere : .stuck
        }
    }

    private static func drag(_ icon: Icon, anchor: Icon, from a: CGRect, press: CGPoint, release: CGPoint, side: Move.Side) -> Bool {
        let revision = movementRevision()
        post(.leftMouseDown, at: press, window: icon.windowID, pid: icon.pid, command: true, move: true)
        let lifted = waitForChange(icon.windowID, from: a.origin, timeout: 0.3)
        if movementRevision() != revision {
            let current = CGEvent(source: nil)?.location ?? press
            post(.leftMouseUp, at: current, window: icon.windowID, pid: icon.pid, command: false, move: true)
            return false
        }
        let dragOrigin = WindowServer.frame(icon.windowID)?.origin ?? a.origin
        // Two mouse-ups: one is sometimes dropped, which leaves the icon stuck mid-drag (Ice found the same).
        post(.leftMouseUp, at: release, window: anchor.windowID, pid: icon.pid, command: false, move: true)
        post(.leftMouseUp, at: release, window: anchor.windowID, pid: icon.pid, command: false, move: true)
        if lifted { _ = waitForChange(icon.windowID, from: dragOrigin, timeout: 0.3) }
        settle(icon.windowID)
        guard movementRevision() == revision else { return false }
        guard let na = WindowServer.frame(icon.windowID), let nb = WindowServer.frame(anchor.windowID) else { return false }
        return side == .leftOf ? abs(na.maxX - nb.minX) <= 1 : abs(na.minX - nb.maxX) <= 1
    }

    /// Clicks an icon that is on screen.
    @discardableResult
    static func click(_ icon: Icon, right: Bool = false) -> Bool {
        guard inputIsIdle(), let f = currentFrame(icon) else { return false }
        let p = CGPoint(x: f.midX, y: f.midY)
        withCursorParked {
            post(right ? .rightMouseDown : .leftMouseDown, at: p, window: icon.windowID, pid: icon.pid, command: false, move: false)
            post(right ? .rightMouseUp : .leftMouseUp, at: p, window: icon.windowID, pid: icon.pid, command: false, move: false)
        }
        return true
    }

    private static func currentFrame(_ icon: Icon) -> CGRect? {
        guard let frame = WindowServer.frame(icon.windowID),
              abs(frame.minX - icon.x) <= 1, abs(frame.minY - icon.y) <= 1,
              abs(frame.width - icon.width) <= 1, abs(frame.height - icon.height) <= 1 else { return nil }
        return frame
    }

    private static func inputIsIdle() -> Bool {
        !CGEventSource.buttonState(.combinedSessionState, button: .left) &&
        !CGEventSource.buttonState(.combinedSessionState, button: .right) &&
        !CGEventSource.buttonState(.combinedSessionState, button: .center) &&
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved) >= 0.15
    }

    private static func movementRevision() -> [UInt32] {
        [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged].map {
            CGEventSource.counterForEventType(.hidSystemState, eventType: $0)
        }
    }

    private static func post(_ type: CGEventType, at p: CGPoint, window: CGWindowID, pid: pid_t, command: Bool, move: Bool) {
        let button: CGMouseButton = (type == .rightMouseDown || type == .rightMouseUp) ? .right : .left
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        e.flags = command ? .maskCommand : []
        e.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window))
        e.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window))
        e.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
        e.setIntegerValueField(.eventSourceUserData, value: signature)
        lastPost = Date()
        if move { e.setIntegerValueField(windowField, value: Int64(window)) }
        else { e.setIntegerValueField(.mouseEventClickState, value: (type == .leftMouseDown || type == .rightMouseDown) ? 1 : 0) }
        e.post(tap: .cgSessionEventTap)
    }

    /// Waits until the window's origin differs from `old`.
    private static func waitForChange(_ id: CGWindowID, from old: CGPoint, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            usleep(5_000)
            if let now = WindowServer.frame(id)?.origin, now != old { return true }
        }
        return false
    }

    /// Waits until the window rests in the menu bar and stops moving (at most 0.3 s).
    private static func settle(_ id: CGWindowID) {
        let end = Date().addingTimeInterval(0.3)
        var last = WindowServer.frame(id)?.origin
        while Date() < end {
            usleep(10_000)
            let now = WindowServer.frame(id)?.origin
            if now == last { return }
            last = now
        }
    }

    /// Our events move the real cursor. Hide it and put it back afterwards.
    private static func withCursorParked<T>(_ body: () -> T) -> T {
        let saved = CGEvent(source: nil)?.location ?? .zero
        let revision = movementRevision()
        CGDisplayHideCursor(CGMainDisplayID())
        defer {
            // A real mouse movement during the gesture belongs to the user. Do not warp it back.
            if movementRevision() == revision {
                CGWarpMouseCursorPosition(saved)
            }
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
        }
        return body()
    }
}

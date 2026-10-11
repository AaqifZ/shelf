import AppKit
import Carbon.HIToolbox
import ShelfCore

/// Decides when the shelf bar opens and closes: hover, click or scroll on empty menu bar space, or the hotkey.
/// Also tells the engine when the user ⌘-drags in the menu bar, so it learns instead of undoing.
final class Reveal {
    private let model: Model
    private let bar: ShelfBar
    private var monitors: [Any] = []
    private var hoverTimer: Timer?
    private var leaveTimer: Timer?
    private var openedByHover = false
    private var scrollSum: CGFloat = 0
    private var appMenuCache: (pid: pid_t, frame: CGRect, at: Date)?

    init(model: Model, bar: ShelfBar) {
        self.model = model
        self.bar = bar
        bar.onClose = { [weak self] in self?.openedByHover = false }
    }

    func start() {
        let global: [(NSEvent.EventTypeMask, (NSEvent) -> Void)] = [
            (.mouseMoved, { [weak self] _ in self?.mouseMoved() }),
            (.leftMouseDown, { [weak self] e in self?.mouseDown(e) }),
            (.leftMouseUp, { [weak self] e in if !Reveal.isOurs(e) { self?.mouseUp() } }),
            (.scrollWheel, { [weak self] e in self?.scrolled(e) }),
            (.keyDown, { [weak self] e in if e.keyCode == UInt16(kVK_Escape) { self?.bar.close() } }),
        ]
        for (mask, handler) in global {
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { monitors.append(m) }
        }
        // Our own panel gets local events; mouse moves over it must keep a hover-opened bar open.
        if let m = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] e in self?.mouseMoved(); return e }) {
            monitors.append(m)
        }
    }

    // MARK: Events

    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        if bar.isOpen && openedByHover {
            let inside = isInMenuBar(p) || (bar.frame?.insetBy(dx: -12, dy: -12).contains(p) ?? false)
            if inside { leaveTimer?.invalidate(); leaveTimer = nil }
            else if leaveTimer == nil {
                leaveTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in
                    self?.leaveTimer = nil
                    self?.bar.close()
                }
            }
        }
        guard model.options.revealOnHover, !bar.isOpen else { hoverTimer?.invalidate(); hoverTimer = nil; return }
        if isEmptySpace(p) {
            if hoverTimer == nil {
                hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.hoverTimer = nil
                    if self.isEmptySpace(NSEvent.mouseLocation), !CGEventSource.buttonState(.combinedSessionState, button: .left) {
                        self.openedByHover = true
                        self.bar.open()
                    }
                }
            }
        } else {
            hoverTimer?.invalidate(); hoverTimer = nil
        }
    }

    private func mouseDown(_ e: NSEvent) {
        if Self.isOurs(e) { return }
        let p = NSEvent.mouseLocation
        if isInMenuBar(p) && e.modifierFlags.contains(.command) {
            bar.close()
            model.engine.setArranging(true)
            return
        }
        if model.options.revealOnClick && isEmptySpace(p) {
            hoverTimer?.invalidate(); hoverTimer = nil
            if bar.isOpen && openedByHover { openedByHover = false; return }  // a click pins a hover-opened bar
            openedByHover = false
            bar.toggle()
            return
        }
        // A click anywhere else closes the bar (clicks on the bar itself are local, not seen here).
        if bar.isOpen { bar.close() }
    }

    private func mouseUp() { model.engine.setArranging(false) }

    /// Events shelf posted itself (moves and clicks) are not the user.
    static func isOurs(_ e: NSEvent) -> Bool { e.cgEvent?.getIntegerValueField(.eventSourceUserData) == Mover.signature }

    private func scrolled(_ e: NSEvent) {
        guard model.options.revealOnScroll, isInMenuBar(NSEvent.mouseLocation) else { scrollSum = 0; return }
        scrollSum += abs(e.scrollingDeltaY) + abs(e.scrollingDeltaX)
        if scrollSum > 5 { scrollSum = 0; if !bar.isOpen { openedByHover = false; bar.open() } }
    }

    // MARK: Geometry (Cocoa coordinates in, CoreGraphics top-left frames compared)

    private var screen: NSScreen? { NSScreen.screens.first }

    private func isInMenuBar(_ p: NSPoint) -> Bool {
        guard let s = screen else { return false }
        let height = max(s.frame.maxY - s.visibleFrame.maxY, 24)
        return s.frame.contains(p) && p.y >= s.frame.maxY - height
    }

    /// In the menu bar, and not over the app's menus, any icon, or the notch.
    private func isEmptySpace(_ p: NSPoint) -> Bool {
        guard isInMenuBar(p), let s = screen else { return false }
        let x = p.x
        if let left = s.auxiliaryTopLeftArea, let right = s.auxiliaryTopRightArea, x > left.maxX, x < right.minX { return false }
        if x <= appMenuMaxX() { return false }
        for icon in model.icons where icon.id != IDs.divider && icon.maxX > 0 {
            if x >= icon.x && x <= icon.maxX { return false }
        }
        return true
    }

    /// Right edge of the frontmost app's menus (File, Edit, ...). Cached briefly.
    private func appMenuMaxX() -> CGFloat {
        guard let app = NSWorkspace.shared.frontmostApplication else { return 0 }
        let pid = app.processIdentifier
        if let c = appMenuCache, c.pid == pid, Date().timeIntervalSince(c.at) < 2 { return c.frame.maxX }
        var maxX: CGFloat = 0
        let el = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(el, 0.1)
        var bar: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXMenuBarAttribute as CFString, &bar) == .success, let bar {
            var kids: CFTypeRef?
            AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &kids)
            for kid in (kids as? [AXUIElement]) ?? [] {
                var v: CFTypeRef?
                var r = CGRect.zero
                if AXUIElementCopyAttributeValue(kid, "AXFrame" as CFString, &v) == .success, let v, AXValueGetValue(v as! AXValue, .cgRect, &r) {
                    maxX = max(maxX, r.maxX)
                }
            }
        }
        appMenuCache = (pid, CGRect(x: 0, y: 0, width: maxX, height: 24), Date())
        return maxX
    }
}

/// A global hotkey through Carbon, the only public API for one. Default ⌥⌘, (the same as Ice).
final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: Int = kVK_ANSI_Comma, modifiers: Int = optionKey | cmdKey, action: @escaping () -> Void) {
        self.action = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return noErr }
            Unmanaged<Hotkey>.fromOpaque(data).takeUnretainedValue().action()
            return noErr
        }, 1, &type, me, &handler)
        let id = EventHotKeyID(signature: OSType(0x53484C46), id: 1)  // "SHLF"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }
}

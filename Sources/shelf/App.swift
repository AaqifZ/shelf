import AppKit
import ShelfCore

/// The running app: two status items (the divider and the shelf icon), the engine, and the views.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: Engine!
    private var model: Model!
    private var bar: ShelfBar!
    private var reveal: Reveal!
    private var settings: SettingsWindow!
    private var hotkey: Hotkey!
    private var iconItem: NSStatusItem!
    private var dividerItem: NSStatusItem!
    private var checkTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        Store.log("shelf started (pid \(getpid()))")
        seedPositions()
        guard permissionsReady() else { return }
        quitIce()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.quitIce()
        }
        WindowServer.allowCursorHidingInBackground()

        let config = Store.loadConfig() ?? Config()
        engine = Engine(config: config)
        model = Model(engine: engine, options: config.options)
        bar = ShelfBar(model: model)
        reveal = Reveal(model: model, bar: bar)
        settings = SettingsWindow(model: model)
        hotkey = Hotkey { [weak self] in self?.bar.toggle() }

        iconItem = NSStatusBar.system.statusItem(withLength: 28)
        iconItem.autosaveName = "shelf.icon"
        if let b = iconItem.button {
            // The same chevron Ice uses, a touch heavier, with room around it so it is easy to hit.
            let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            b.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "shelf")?.withSymbolConfiguration(config)
            b.target = self
            b.action = #selector(iconClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        dividerItem = NSStatusBar.system.statusItem(withLength: 1)
        dividerItem.autosaveName = "shelf.divider"
        // The divider fills the empty menu bar space, so clicks and scrolls there arrive here, not globally.
        if let b = dividerItem.button {
            b.target = self
            b.action = #selector(emptySpaceClicked)
        }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            if self?.model.options.revealOnScroll == true, abs(e.scrollingDeltaY) + abs(e.scrollingDeltaX) > 2 { self?.bar.open() }
            return e
        }

        model.onImages = { [weak self] in if self?.bar.isOpen == true { self?.bar.layout() } }
        engine.onUpdate = { [weak self] snap in
            guard let self else { return }
            self.model.apply(snap)
            if let a = self.iconItem.button?.effectiveAppearance {
                let dark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if self.model.menuBarIsDark != dark { self.model.menuBarIsDark = dark }
            }
            if self.bar.isOpen { self.bar.layout() }
        }
        reveal.start()

        DistributedNotificationCenter.default().addObserver(forName: .shelfCommand, object: nil, queue: .main) { [weak self] n in
            self?.handle(command: n.object as? String ?? "")
        }

        // Wait until macOS has put both items on screen, then stretch the divider. An item created
        // already 10,000 points long does not fit, and macOS never shows it.
        waitForItems()

        // Test 2: an independent check every hour, written to ~/.shelf/check.log.
        checkTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.runCheck() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.runCheck() }
    }

    /// Stretches the divider once macOS has placed it. An item created 10,000 points long does not fit and is never shown.
    private func waitForItems() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            dividerItem.length = 10_000
            Store.log("divider stretched")
            engine.start()
        }
    }

    @objc private func iconClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Switch back to Ice", action: #selector(switchToIce), keyEquivalent: "").target = self
            iconItem.menu = menu
            iconItem.button?.performClick(nil)
            iconItem.menu = nil
        } else {
            bar.toggle()
        }
    }

    @objc private func emptySpaceClicked() {
        if NSApp.currentEvent?.modifierFlags.contains(.command) == true { return }
        if model.options.revealOnClick { bar.toggle() }
    }

    @objc private func openSettings() { settings.show() }

    @objc private func switchToIce() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["use", "ice"]
        try? p.run()
    }

    private func handle(command: String) {
        let parts = command.split(separator: " ").map(String.init)
        switch parts.first {
        case "settings": settings.show()
        case "open": bar.open()
        case "close": bar.close()
        case "click" where parts.count > 1: model.click(parts[1])
        case "place" where parts.count > 2:  // place hidden|visible <id> [before <id>]
            let before = parts.count > 4 && parts[3] == "before" ? parts[4] : nil
            model.place(parts[2], in: parts[1] == "hidden" ? .hidden : .visible, before: before)
        case "refresh": engine.refreshNow()
        default: Store.log("unknown command: \(command)")
        }
    }

    private func runCheck() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        p.arguments = ["check", "--log", "--quiet"]
        p.terminationHandler = { [weak self] proc in
            let ok = proc.terminationStatus == 0
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            DispatchQueue.main.async { self?.model.lastCheck = ok ? "OK at \(time)" : "PROBLEM at \(time), see ~/.shelf/check.log" }
        }
        try? p.run()
    }

    /// Only one menu bar manager at a time: two would push the same icons around.
    private func quitIce() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: "com.jordanbaird.Ice") {
            Store.log("Ice is running; quitting it (one manager at a time)")
            app.terminate()
        }
    }

    /// Accessibility (to read and move icons) and Screen Recording (icon names and pictures).
    /// Until both are granted, shelf shows a ⚠︎ icon that says so, and Ice keeps running: the menu bar is
    /// never left unmanaged. macOS only applies a new grant after a restart, so shelf exits and launchd starts it again.
    private var waitingItem: NSStatusItem?

    /// A new status item lands at the far left, which on a notched Mac can be off the screen (or inside
    /// Ice's hidden section), and then you never see it. So on first run, ask for the right end, next to
    /// the Clock. Positions are distances from the right edge; macOS keeps them up to date after that.
    private func seedPositions() {
        let d = UserDefaults.standard
        if d.object(forKey: "NSStatusItem Preferred Position shelf.icon") == nil {
            d.set(0, forKey: "NSStatusItem Preferred Position shelf.icon")
            d.set(1, forKey: "NSStatusItem Preferred Position shelf.divider")
        }
    }
    private func permissionsReady() -> Bool {
        let ax = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        let screen = CGPreflightScreenCaptureAccess()
        if !screen { CGRequestScreenCaptureAccess() }
        if ax && screen { return true }
        Store.log("waiting for permissions: accessibility \(ax), screen recording \(screen)")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "shelf.icon"  // the shelf icon's own place, at the right
        item.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "shelf needs permissions")
        let menu = NSMenu()
        menu.addItem(withTitle: "shelf needs two permissions. Switch Shelf on in both:", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Open Accessibility settings", action: #selector(openAccessibility), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Screen Recording settings", action: #selector(openScreenRecording), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "I've switched both on: restart shelf", action: #selector(restart), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Switch back to Ice", action: #selector(switchToIce), keyEquivalent: "").target = self
        item.menu = menu
        waitingItem = item

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() {
                Store.log("permissions granted; restarting")
                exit(0)
            }
        }
        return false
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openScreenRecording() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    @objc private func restart() { exit(0) }  // launchd starts shelf again; a new process sees new grants
}

extension Notification.Name {
    static let shelfCommand = Notification.Name("com.aaqifz.shelf.command")
}

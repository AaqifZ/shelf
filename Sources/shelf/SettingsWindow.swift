import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ShelfCore

/// The settings window: the live layout (drag to rearrange) and three switches.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private let model: Model
    private var window: NSWindow?

    init(model: Model) { self.model = model }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "shelf"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.delegate = self
            w.center()
            window = w
        }
        model.settingsOpen = true
        model.needPictures("settings", true)  // a set: showing again does not add a timer
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.needPictures("settings", false)
        model.settingsOpen = false
        model.settingsDrew(nil)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: Model

    var body: some View {
        let s = model.sections
        VStack(alignment: .leading, spacing: 14) {
            Text("Drag icons between rows. In the menu bar, ⌘-drag an icon just left of the shelf icon to hide it.")
                .font(.callout).foregroundStyle(.secondary)
            Row(title: "Visible", section: .visible, icons: s.visible, model: model)
            Row(title: "Hidden", section: .hidden, icons: s.hidden, model: model)
            Divider()
            Toggle("Show hidden icons when I hover over empty menu bar space", isOn: binding(\.revealOnHover))
            Toggle("… when I click empty menu bar space", isOn: binding(\.revealOnClick))
            Toggle("… when I scroll in the menu bar", isOn: binding(\.revealOnScroll))
            Text("Hotkey ⌥⌘,  ·  Last check: \(model.lastCheck)").font(.caption).foregroundStyle(.secondary)
            if let reason = model.pauseReason { Text("Paused: \(reason)").font(.caption).foregroundStyle(.orange) }
        }
        .padding(20)
        // Wide enough for the widest row, so no icon is ever cut off. Computed from the icons
        // (not measured), which keeps SwiftUI and the window out of a resize loop.
        .frame(width: max(640, rowWidth(s.hidden), rowWidth(s.visible)))
        .onChange(of: s.hidden.map(\.id) + ["|"] + s.visible.map(\.id), initial: true) { _, _ in
            if model.settingsOpen { model.settingsDrew(Layout(hidden: s.hidden.map(\.id), visible: s.visible.map(\.id))) }
        }
        .onChange(of: model.settingsOpen) { _, open in
            if open { model.settingsDrew(Layout(hidden: s.hidden.map(\.id), visible: s.visible.map(\.id))) }
        }
    }

    private func rowWidth(_ icons: [Icon]) -> CGFloat {
        icons.reduce(0) { $0 + CGFloat($1.width) + 8 } + 16 + 24 + 40
    }

    private func binding(_ key: WritableKeyPath<Options, Bool>) -> Binding<Bool> {
        Binding(get: { model.options[keyPath: key] }, set: { model.setOption(key, to: $0) })
    }
}

private struct Row: View {
    let title: String
    let section: ShelfCore.Section
    let icons: [Icon]
    @ObservedObject var model: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            // Right-aligned, like the menu bar itself.
            HStack(spacing: 4) {
                Spacer(minLength: 24)
                ForEach(icons, id: \.id) { icon in
                    IconTile(icon: icon, image: model.images[icon.id])
                        .padding(.horizontal, 2)
                        .opacity(IDs.isFixed(icon.id) ? 0.6 : 1)
                        .help(icon.displayName)
                        .onDrag { NSItemProvider(object: icon.id as NSString) }
                        .onDrop(of: [.text], isTargeted: nil) { drop($0, before: icon.id) }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .trailing)
            // The pictures come from the menu bar (white icons on a dark bar), so the rows look like the menu bar.
            .background(model.menuBarIsDark ? Color(red: 0.13, green: 0.16, blue: 0.22) : Color(white: 0.93),
                        in: RoundedRectangle(cornerRadius: 10))
            .onDrop(of: [.text], isTargeted: nil) { drop($0, before: nil) }
        }
    }

    private func drop(_ providers: [NSItemProvider], before: String?) -> Bool {
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: NSString.self) { obj, _ in
            guard let id = obj as? String else { return }
            DispatchQueue.main.async { model.place(id, in: section, before: before == id ? nil : before) }
        }
        return true
    }
}

import AppKit
import SwiftUI
import ShelfCore

/// The floating bar under the menu bar that shows the hidden icons.
final class ShelfBar {
    private let model: Model
    private let panel: NSPanel
    private let host: NSHostingController<BarView>
    private(set) var isOpen = false
    var onClose: () -> Void = {}

    init(model: Model) {
        self.model = model
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        host = NSHostingController(rootView: BarView(model: model, close: {}))
        host.sizingOptions = []
        panel.contentViewController = host
        host.rootView = BarView(model: model, close: { [weak self] in self?.close() })
    }

    var frame: NSRect? { isOpen ? panel.frame : nil }

    func toggle() { isOpen ? close() : open() }

    func open() {
        guard !isOpen, model.pauseReason == nil, ScreenGeometry.screen(for: model.icon(IDs.icon)) != nil else { return }
        isOpen = true
        model.barOpen = true
        model.barDrew(model.sections.hidden.map(\.id))
        layout()
        panel.orderFrontRegardless()
        // Icons with live text (timers, CPU) keep changing; their pictures refresh while the bar is open.
        model.needPictures("bar", true)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        model.needPictures("bar", false)
        panel.orderOut(nil)
        model.barOpen = false
        model.barDrew(nil)
        onClose()
    }

    /// Right-aligned under the shelf icon, just below the menu bar.
    func layout() {
        guard model.pauseReason == nil, let screen = ScreenGeometry.screen(for: model.icon(IDs.icon)) else { close(); return }
        let size = host.sizeThatFits(in: CGSize(width: screen.frame.width - 16, height: 200))
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        var right = screen.frame.maxX - 8
        if let icon = model.icon(IDs.icon) { right = min(right, icon.maxX + 8) }
        let x = max(screen.frame.minX + 8, right - size.width)
        let y = screen.frame.maxY - max(menuBarHeight, 24) - 6 - size.height
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }
}

private struct BarView: View {
    @ObservedObject var model: Model
    let close: () -> Void

    var body: some View {
        let hidden = model.sections.hidden
        BarContent(hidden: hidden, images: model.images, dark: model.menuBarIsDark,
                   click: { id, right in close(); model.click(id, right: right) })
            .onChange(of: hidden.map(\.id)) { _, ids in if model.barOpen { model.barDrew(ids) } }
    }
}

/// What the shelf bar draws. `shelf snapshot-bar` renders this same view with sample icons.
struct BarContent: View {
    let hidden: [Icon]
    let images: [String: NSImage]
    let dark: Bool
    let click: (String, Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            if hidden.isEmpty {
                Text("No hidden icons").font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            ForEach(hidden, id: \.id) { icon in
                IconTile(icon: icon, image: images[icon.id])
                    .onTapGesture { click(icon.id, false) }
                    .contextMenu {
                        Button("Right-click \(icon.displayName)") { click(icon.id, true) }
                    }
                    .help(icon.displayName)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        // The pictures are taken from the menu bar, so the bar matches the menu bar's appearance.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .environment(\.colorScheme, dark ? .dark : .light)
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .padding(1)
    }
}

/// One icon: its real picture, or its name while the picture is loading.
struct IconTile: View {
    let icon: Icon
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).interpolation(.high)
            } else {
                Text(icon.displayName).font(.system(size: 11)).lineLimit(1).padding(.horizontal, 6)
                    .frame(minWidth: icon.width)
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
    }
}

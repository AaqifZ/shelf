import AppKit
import SwiftUI
import ShelfCore

/// `shelf snapshot-bar <out.png>`: renders the real shelf bar view (BarContent) offscreen with sample icons.
/// Used for the README image. It reads no menu bar, opens no window on screen, and needs no permissions.
@MainActor
func snapshotBar(to path: String) -> Int32 {
    // Neutral sample icons: SF Symbols, drawn the way a dark menu bar draws them (white glyph, 24 pt tall).
    let symbols = ["cloud", "bolt.horizontal", "timer", "paperplane", "keyboard", "music.note", "lock.shield"]
    var icons: [Icon] = []
    var images: [String: NSImage] = [:]
    for (i, symbol) in symbols.enumerated() {
        let id = "sample.\(symbol)/Item-0"
        icons.append(Icon(id: id, windowID: UInt32(i + 1), pid: 0, bundle: "sample.\(symbol)", name: "Item-0",
                          label: "", x: Double(i) * 36, y: 0, width: 36, height: 24))
        images[id] = menuBarGlyph(symbol, size: NSSize(width: 36, height: 24))
    }
    let bar = BarContent(hidden: icons, images: images, dark: true, click: { _, _ in })
    // Transparent around the bar, so the README image can place it under a drawn menu bar.
    let scene = bar.fixedSize().padding(4)

    let renderer = ImageRenderer(content: scene)
    renderer.scale = 3
    guard let cg = renderer.cgImage else { print("snapshot-bar: render failed"); return 1 }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let png = rep.representation(using: .png, properties: [:]) else { return 1 }
    do { try png.write(to: URL(fileURLWithPath: path)) } catch { print("snapshot-bar: \(error)"); return 1 }
    print("wrote \(path)")
    return 0
}

/// A white SF Symbol centered in a menu-bar-sized picture, like the pictures shelf crops from the menu bar.
private func menuBarGlyph(_ symbol: String, size: NSSize) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    return NSImage(size: size, flipped: false) { rect in
        guard let glyph else { return true }
        let g = glyph.size
        glyph.draw(in: NSRect(x: (rect.width - g.width) / 2, y: (rect.height - g.height) / 2, width: g.width, height: g.height))
        return true
    }
}

import AppKit
import ShelfCore

/// AppKit uses a bottom-left origin. WindowServer uses the primary display's top-left origin.
enum ScreenGeometry {
    static func screen(for icon: Icon?) -> NSScreen? {
        guard let icon else { return nil }
        let matching = NSScreen.screens.filter { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            let bounds = CGDisplayBounds(number.uint32Value)
            return abs(bounds.minY - icon.y) <= 1 && icon.x >= bounds.minX - 1 && icon.maxX <= bounds.maxX + 1
        }
        return matching.count == 1 ? matching.first : nil
    }

    static func quartzPoint(_ point: NSPoint) -> CGPoint? {
        guard let primary = NSScreen.screens.first else { return nil }
        return CGPoint(x: point.x, y: primary.frame.maxY - point.y)
    }
}

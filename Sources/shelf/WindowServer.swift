import AppKit

// Private WindowServer calls. Ice and Thaw use the same ones (GPLv3, see NOTICE).
// On macOS 26 every status item window belongs to Control Center, so the window list alone
// cannot say which app owns an icon. Scanner adds that from Accessibility.

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetWindowCount")
private func CGSGetWindowCount(_ cid: Int32, _ target: Int32, _ count: inout Int32) -> CGError
@_silgen_name("CGSGetProcessMenuBarWindowList")
private func CGSGetProcessMenuBarWindowList(_ cid: Int32, _ target: Int32, _ count: Int32,
                                            _ list: UnsafeMutablePointer<CGWindowID>, _ outCount: inout Int32) -> CGError
@_silgen_name("CGSGetScreenRectForWindow")
private func CGSGetScreenRectForWindow(_ cid: Int32, _ wid: CGWindowID, _ rect: inout CGRect) -> CGError
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> CGError

enum WindowServer {
    private static let cid = CGSMainConnectionID()

    /// Window ids of everything in the menu bar, including the bar itself.
    static func menuBarWindowIDs() -> [CGWindowID] {
        var count: Int32 = 0
        guard CGSGetWindowCount(cid, 0, &count) == .success, count > 0 else { return [] }
        var list = [CGWindowID](repeating: 0, count: Int(count))
        guard CGSGetProcessMenuBarWindowList(cid, 0, count, &list, &count) == .success else { return [] }
        return Array(list[..<Int(count)])
    }

    /// Live frame from the WindowServer, top-left origin. Cheap; used while waiting for a move.
    static func frame(_ id: CGWindowID) -> CGRect? {
        var r = CGRect.zero
        return CGSGetScreenRectForWindow(cid, id, &r) == .success ? r : nil
    }

    struct Info { var name: String?; var level: Int; var frame: CGRect }

    static func info(_ ids: [CGWindowID]) -> [CGWindowID: Info] {
        guard let raw = CGWindowListCreateDescriptionFromArray(windowArray(ids)) as? [[String: Any]] else { return [:] }
        var out: [CGWindowID: Info] = [:]
        for w in raw {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b) else { continue }
            out[id] = Info(name: w[kCGWindowName as String] as? String, level: w[kCGWindowLayer as String] as? Int ?? 0, frame: frame)
        }
        return out
    }

    /// One picture of several windows, plus the frame it covers. Works for windows pushed off the screen.
    /// CGWindowListCreateImageFromArray is marked unavailable in Swift since macOS 15 but still works,
    /// and ScreenCaptureKit cannot capture off-screen menu bar items. So we call it by symbol.
    static func capture(_ ids: [CGWindowID]) -> CGImage? {
        guard !ids.isEmpty, let fn = createImageFromArray else { return nil }
        let options: CGWindowImageOption = [.boundsIgnoreFraming, .bestResolution]
        return fn(.null, windowArray(ids), options.rawValue)?.takeRetainedValue()
    }

    private typealias CreateImageFn = @convention(c) (CGRect, CFArray, UInt32) -> Unmanaged<CGImage>?
    private static let createImageFromArray: CreateImageFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImageFromArray") else { return nil }
        return unsafeBitCast(sym, to: CreateImageFn.self)
    }()

    private static func windowArray(_ ids: [CGWindowID]) -> CFArray {
        var ptrs = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        return CFArrayCreate(nil, &ptrs, ptrs.count, nil)
    }

    /// Lets a background app hide the cursor while it moves icons.
    static func allowCursorHidingInBackground() {
        _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    /// True when any menu or popover is open on screen. Moving icons then would close it.
    static func menuIsOpen() -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { ($0[kCGWindowLayer as String] as? Int ?? 0) == Int(CGWindowLevelForKey(.popUpMenuWindow)) }
    }
}

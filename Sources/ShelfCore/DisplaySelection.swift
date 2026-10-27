import Foundation
import CoreGraphics

/// A verified strip can live on any display. All frames use global Quartz points.
public enum DisplaySelection {
    public struct Display: Equatable, Sendable {
        public var id: UInt32
        public var frame: CGRect
        public init(id: UInt32, frame: CGRect) { self.id = id; self.frame = frame }
    }

    public struct Window: Equatable, Sendable {
        public var id: UInt32
        public var name: String?
        public var frame: CGRect
        public init(id: UInt32, name: String?, frame: CGRect) { self.id = id; self.name = name; self.frame = frame }
    }

    public struct Selection: Equatable, Sendable {
        public var display: Display
        public var windows: Set<UInt32>
    }

    public enum Problem: String, Error, Sendable {
        case noAnchor = "shelf icon is unavailable"
        case ambiguousAnchor = "more than one real shelf icon"
        case unknownDisplay = "shelf icon is between displays or displays overlap"
        case ambiguousEdge = "menu bar window edges are ambiguous"
        case noDivider = "the real divider is unavailable"
    }

    public static func select(windows: [Window], displays: [Display],
                              anchorName: String = "shelf.icon", dividerName: String = "shelf.divider") -> Result<Selection, Problem> {
        let anchors = windows.filter { $0.name == anchorName }
        guard let anchor = anchors.first else { return .failure(.noAnchor) }
        guard anchors.count == 1 else { return .failure(.ambiguousAnchor) }
        let screens = displays.filter {
            let f = $0.frame, a = anchor.frame
            return a.width > 0 && a.height > 0 && abs(a.minY - f.minY) <= 1 &&
                a.minX >= f.minX - 1 && a.maxX <= f.maxX + 1
        }
        guard screens.count == 1, let screen = screens.first else { return .failure(.unknownDisplay) }
        let row = windows.filter { $0.frame.width > 0 && $0.frame.height > 0 && abs($0.frame.minY - anchor.frame.minY) <= 1 }
        var selected: Set<UInt32> = [anchor.id]
        var left = anchor, right = anchor
        while true {
            let candidates = row.filter { !selected.contains($0.id) && abs($0.frame.maxX - left.frame.minX) <= 1 }
            guard candidates.count <= 1 else { return .failure(.ambiguousEdge) }
            guard let next = candidates.first else { break }
            selected.insert(next.id); left = next
        }
        while true {
            let candidates = row.filter { !selected.contains($0.id) && abs($0.frame.minX - right.frame.maxX) <= 1 }
            guard candidates.count <= 1 else { return .failure(.ambiguousEdge) }
            guard let next = candidates.first else { break }
            selected.insert(next.id); right = next
        }
        let dividers = row.filter { selected.contains($0.id) && $0.name == dividerName }
        guard dividers.count == 1 else { return .failure(.noDivider) }
        return .success(Selection(display: screen, windows: selected))
    }

    /// Accessibility candidates must agree in both axes. WindowServer and Accessibility can report
    /// different widths for the same status item, so width is not an ownership signal.
    public static func uniqueMatch(frame: CGRect, candidates: [CGRect], tolerance: Double = 3) -> Int? {
        let matches = candidates.indices.filter {
            abs(candidates[$0].midX - frame.midX) <= tolerance &&
                abs(candidates[$0].midY - frame.midY) <= tolerance
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

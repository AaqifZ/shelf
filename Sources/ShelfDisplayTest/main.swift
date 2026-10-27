import Foundation
import CoreGraphics
import ShelfCore

var failures = 0
func expect(_ value: Bool, _ name: String) {
    print(value ? "  ok  \(name)" : "  FAIL \(name)")
    if !value { failures += 1 }
}
typealias D = DisplaySelection.Display
typealias W = DisplaySelection.Window
func strip(x: Double, y: Double, copies: Bool = false) -> [W] {
    [W(id: copies ? 101 : 1, name: copies ? "copy" : "shelf.divider", frame: CGRect(x: x - 10_000, y: y, width: 10_000, height: 24)),
     W(id: copies ? 102 : 2, name: copies ? "copy" : "shelf.icon", frame: CGRect(x: x, y: y, width: 28, height: 24)),
     W(id: copies ? 103 : 3, name: "Item-0", frame: CGRect(x: x + 28, y: y, width: 24, height: 24))]
}
let main = D(id: 1, frame: CGRect(x: 0, y: 0, width: 1470, height: 956))
let arrangements: [(String, CGRect)] = [
    ("left", CGRect(x: -2560, y: 0, width: 2560, height: 1440)),
    ("right", CGRect(x: 1470, y: 0, width: 2560, height: 1440)),
    ("above", CGRect(x: 0, y: -1440, width: 2560, height: 1440)),
    ("below", CGRect(x: 0, y: 956, width: 2560, height: 1440))]
for (name, frame) in arrangements {
    let external = D(id: 2, frame: frame)
    let actual = strip(x: frame.maxX - 100, y: frame.minY)
    let copies = strip(x: 1370, y: 0, copies: true)
    if case .success(let selected) = DisplaySelection.select(windows: actual + copies, displays: [main, external]) {
        expect(selected.display.id == 2 && selected.windows == Set([1, 2, 3]), "real strip on \(name) display excludes copies")
    } else { expect(false, "real strip on \(name) display") }
}
let real = strip(x: 1370, y: 0)
expect({ if case .failure(.noAnchor) = DisplaySelection.select(windows: [], displays: [main]) { return true }; return false }(), "missing anchor pauses")
expect({ if case .failure(.ambiguousAnchor) = DisplaySelection.select(windows: real + [W(id: 99, name: "shelf.icon", frame: real[1].frame)], displays: [main]) { return true }; return false }(), "duplicate real anchors pause")
expect({ if case .failure(.unknownDisplay) = DisplaySelection.select(windows: real, displays: [main, D(id: 2, frame: main.frame)]) { return true }; return false }(), "mirrored display ambiguity pauses")
let collision = W(id: 99, name: "copy", frame: real[2].frame)
expect({ if case .failure(.ambiguousEdge) = DisplaySelection.select(windows: real + [collision], displays: [main]) { return true }; return false }(), "ambiguous touching edges pause")
expect({ if case .failure(.noDivider) = DisplaySelection.select(windows: Array(real.dropFirst()), displays: [main]) { return true }; return false }(), "missing divider pauses")
let frame = CGRect(x: 10, y: 0, width: 24, height: 24)
expect(DisplaySelection.uniqueMatch(frame: frame, candidates: [frame.offsetBy(dx: 0, dy: 100)]) == nil, "owner on another row is rejected")
expect(DisplaySelection.uniqueMatch(frame: frame, candidates: [frame, frame]) == nil, "ambiguous owners are rejected")
expect(DisplaySelection.uniqueMatch(frame: frame, candidates: [frame]) == 0, "one matching owner is accepted")
expect(DisplaySelection.uniqueMatch(frame: frame, candidates: [CGRect(x: 7, y: 0, width: 30, height: 24)]) == 0,
       "matching centres accept different WindowServer and Accessibility widths")
let ice = [W(id: 11, name: "Ice.ControlItem.Hidden", frame: CGRect(x: -8630, y: 0, width: 10_000, height: 24)),
           W(id: 12, name: "Ice.ControlItem.Visible", frame: CGRect(x: 1370, y: 0, width: 28, height: 24))]
if case .success(let selected) = DisplaySelection.select(windows: ice, displays: [main], anchorName: "Ice.ControlItem.Visible", dividerName: "Ice.ControlItem.Hidden") {
    expect(selected.windows == Set([11, 12]), "explicit Ice import accepts a collapsed 10000-point divider")
} else { expect(false, "explicit Ice import accepts a collapsed divider") }
expect(!Check.livenessProblems(state: nil).isEmpty, "an unavailable scan cannot hide missing app state")
let stale = State(updated: Date(timeIntervalSince1970: 0), icons: [], bar: nil, settings: nil, pinned: [])
expect(!Check.livenessProblems(state: stale).isEmpty, "an unavailable scan cannot hide a stale heartbeat")
print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

import Foundation
import ShelfCore

// Run: swift run ShelfSelfTest
var failures = 0
func expect(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    print(ok ? "  ok  \(name)" : "  FAIL \(name) \(detail())")
    if !ok { failures += 1 }
}

let D = IDs.divider, I = IDs.icon, clock = "com.apple.controlcenter/Clock"

/// Runs the engine's closed loop: plan, apply the first move, re-plan. Returns every move made.
func run(_ actual: [String], _ layout: Layout, pinned: Set<String> = []) -> (moves: [Move], result: [String], target: [String]?) {
    guard let target = Planner.target(actual: actual, layout: layout, pinned: pinned) else { return ([], actual, nil) }
    var order = actual, made: [Move] = []
    for _ in 0..<(2 * actual.count) {
        guard let m = Planner.moves(actual: order, target: target).first else { break }
        made.append(m)
        order = Planner.apply(m, to: order)
    }
    return (made, order, target)
}

print("planner")
let layout = Layout(hidden: ["a", "b"], visible: ["timer", "x", "wifi"])

do {
    let steady = ["a", "b", D, I, "timer", "x", "wifi", clock]
    let r = run(steady, layout)
    expect(r.moves.isEmpty, "steady state needs no moves", "\(r.moves)")
}
do {
    // Today's bug: the timer comes back at the far left (hidden). It must go back to visible.
    let r = run(["timer", "a", "b", D, I, "x", "wifi", clock], layout)
    expect(r.moves == [Move("timer", .leftOf, "x")], "returning timer goes back to its visible spot", "\(r.moves)")
    expect(r.result == r.target, "plan reaches target")
}
do {
    // An absent icon needs nothing.
    let r = run(["a", "b", D, I, "x", "wifi", clock], layout)
    expect(r.moves.isEmpty, "absent timer: no moves")
}
do {
    // A new icon that lands among the visible ones goes to hidden.
    let r = run(["a", "b", D, I, "x", "new", "wifi", clock], layout)
    expect(r.target?.first == "new", "new icon targets far left of hidden", "\(String(describing: r.target))")
    expect(r.result == r.target && r.moves.count == 1, "one move hides it", "\(r.moves)")
}
do {
    // First launch: shelf's items appear at the far left, everything looks visible.
    let r = run([D, I, "a", "b", "x", "wifi", clock], layout)
    expect(r.result == ["a", "b", D, I, "x", "wifi", clock], "first launch hides the remembered icons", "\(r.result)")
    expect(r.moves.count == 2, "with two moves", "\(r.moves)")
}
do {
    // A pinned (clicked) hidden icon sits just right of the shelf icon.
    let r = run(["a", "b", D, I, "x", "wifi", clock], layout, pinned: ["a"])
    expect(r.result == ["b", D, I, "a", "x", "wifi", clock], "pinned icon shows next to the shelf icon", "\(r.result)")
}
do {
    // Property: any shuffle reaches its target exactly.
    var rng = SystemRandomNumberGenerator()
    var ok = true
    for _ in 0..<500 {
        let ids = ["a", "b", "c", "d", "e", "timer", "x", "wifi", "new1"].shuffled(using: &rng)
        let actual = (ids + [D, I]).shuffled(using: &rng) + [clock]
        let r = run(actual, Layout(hidden: ["a", "b", "c"], visible: ["timer", "x", "wifi", "d"]))
        if r.result != r.target { ok = false; print("    \(actual) -> \(r.result) vs \(String(describing: r.target))"); break }
        if let t = r.target, !Planner.moves(actual: t, target: t).isEmpty { ok = false }
    }
    expect(ok, "500 random shuffles all reach their target")
}
do {
    expect(Planner.target(actual: ["a", I], layout: layout) == nil, "no plan until both shelf items exist")
}

do {
    // Next to a fixed item (Control Center), anchor on the movable neighbour instead.
    let r = run(["timer", "a", "b", D, I, "x", "wifi", clock], Layout(hidden: ["a", "b"], visible: ["x", "wifi", "timer"]))
    expect(r.moves.first == Move("timer", .rightOf, "wifi"), "never drops onto a fixed item", "\(r.moves)")
    expect(r.result == r.target, "and still reaches target")
}

do {
    // macOS keeps Control Center's icons as a block at the right. "Visible, at the end" means left of them.
    let w = "com.apple.controlcenter/WiFi", bat = "com.apple.controlcenter/Battery"
    let r = run(["churn", "a", D, I, "x", w, bat, clock], Layout(hidden: ["a"], visible: ["x", w, bat, "churn"]))
    expect(r.result == ["a", D, I, "x", "churn", w, bat, clock], "app icons go left of Control Center's block", "\(r.result)")
}

print("adopt (user ⌘-drags in the menu bar)")
do {
    // User drags x onto the shelf (between divider and icon): x becomes hidden. timer is absent and keeps its spot.
    let l = Planner.adopt(actual: ["a", "b", D, "x", I, "wifi", clock], into: layout)
    expect(l == Layout(hidden: ["a", "b", "x"], visible: ["timer", "wifi"]), "drag onto shelf hides, absent timer kept", "\(l)")
}
do {
    let l = Planner.adopt(actual: ["a", "b", D, I, "wifi", "x", clock], into: layout)
    expect(l.visible == ["timer", "wifi", "x"], "reorder visible keeps absent timer before its old neighbour", "\(l)")
}
do {
    // A pinned icon is visiting. Adopt must not move it into visible.
    let l = Planner.adopt(actual: ["b", D, I, "a", "timer", "x", "wifi", clock], into: layout, pinned: ["a"])
    expect(l.hidden.contains("a") && !l.visible.contains("a"), "pinned icon keeps its hidden home", "\(l)")
}

print("settings drag (place)")
do {
    // Codex audit finding 1: "a" is hidden but shown for a click. A Settings drag of "x" must not save "a" as visible.
    let l = Planner.place("x", in: .hidden, before: nil, layout: layout)
    expect(l.hidden == ["a", "b", "x"] && l.visible == ["timer", "wifi"], "drag edits memory, not reality", "\(l)")
    let l2 = Planner.place("b", in: .visible, before: "x", layout: layout)
    expect(l2.visible == ["timer", "b", "x", "wifi"] && l2.hidden == ["a"], "drop before an icon", "\(l2)")
    expect(Planner.place(clock, in: .hidden, before: nil, layout: layout) == layout, "fixed items cannot be placed")
}

print("check")
do {
    let reality = ["a", "b", D, I, "timer", "x", "wifi", clock]
    let good = State(updated: Date(), icons: reality, bar: ["a", "b"], settings: Layout(hidden: ["a", "b"], visible: ["timer", "x", "wifi", clock]), pinned: [])
    expect(Check.problems(reality: reality, state: good, layout: layout).isEmpty, "all four agree = OK")
    var stale = good; stale.settings = Layout(hidden: ["a", "b"], visible: ["x", "wifi"])
    expect(Check.problems(reality: reality, state: stale, layout: layout) == ["settings window ≠ menu bar"], "stale settings window is caught")
    // Codex audit finding 4: a matching but old state means the app is hung.
    var old = good; old.updated = Date(timeIntervalSince1970: 0)
    expect(Check.problems(reality: reality, state: old, layout: layout).first?.hasPrefix("app has not updated") == true, "stale state is caught")
    let drift = ["timer", "a", "b", D, I, "x", "wifi", clock]
    var s = good; s.icons = drift; s.bar = nil; s.settings = nil
    expect(Check.problems(reality: drift, state: s, layout: layout).first?.hasPrefix("menu bar ≠ memory") == true, "drifted timer is caught")
}

print("owner match")
do {
    let apps: Set<String> = ["com.knollsoft.Rectangle", "com.pais.handy", IDs.bundle]
    // 9 Oct: shelf's own window, named after shelf, sat next to Rectangle's icon.
    expect(!IDs.ownerFits(windowName: IDs.bundle, owner: "com.knollsoft.Rectangle", apps: apps), "shelf's window is never another app's icon")
    expect(!IDs.ownerFits(windowName: "com.pais.handy", owner: "com.knollsoft.Rectangle", apps: apps), "window named after another app is refused")
    expect(IDs.ownerFits(windowName: "com.knollsoft.Rectangle", owner: "com.knollsoft.Rectangle", apps: apps), "window named after its own app fits")
    expect(IDs.ownerFits(windowName: "Item-0", owner: "com.knollsoft.Rectangle", apps: apps), "plain item name fits")
    expect(IDs.ownerFits(windowName: "vault.15m.sh", owner: "com.ameba.SwiftBar", apps: apps), "dotted plugin name fits")
    expect(IDs.ownerFits(windowName: nil, owner: "com.knollsoft.Rectangle", apps: apps), "no name fits")
}

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

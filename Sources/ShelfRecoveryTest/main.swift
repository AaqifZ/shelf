import Foundation
import ShelfCore

var failures = 0
func expect(_ condition: Bool, _ name: String) {
    print(condition ? "  ok  \(name)" : "  FAIL \(name)")
    if !condition { failures += 1 }
}

let start = Date(timeIntervalSince1970: 1_000)
let first = Appearance(id: "timer", windowID: 1)
let replacement = Appearance(id: "timer", windowID: 2)
let second = Appearance(id: "weather", windowID: 3)

print("failed move backoff")
do {
    var policy = RecoveryPolicy()
    policy.synchronize(active: [first], context: "layout-a", now: start)
    expect(policy.recordStuck(first, now: start) == .retryAfter(attempt: 1, seconds: 1), "first failure waits one second")
    expect(policy.isBenched(first, now: start.addingTimeInterval(0.5)), "failure is benched during its wait")
    expect(policy.recordStuck(first, now: start.addingTimeInterval(1)) == .retryAfter(attempt: 2, seconds: 2), "second failure doubles the wait")
    var last = RecoveryPolicy.Event.retryAfter(attempt: 0, seconds: 0)
    for attempt in 3...100 {
        last = policy.recordStuck(first, now: start.addingTimeInterval(TimeInterval(attempt)))
    }
    expect(last == .retryAfter(attempt: 100, seconds: 60), "large retry counts stay capped without overflow")
}

print("slot-off loop")
do {
    var policy = RecoveryPolicy()
    policy.synchronize(active: [first], context: "layout-a", now: start)
    expect(policy.recordSlotOff(first, now: start) == .slotOff(count: 1, retryAfter: nil), "first slot-off replans at once")
    expect(policy.recordSlotOff(first, now: start) == .slotOff(count: 2, retryAfter: nil), "second slot-off replans at once")
    expect(policy.recordSlotOff(first, now: start) == .slotOff(count: 3, retryAfter: 1), "third slot-off backs off")
}

print("fight detection")
do {
    var policy = RecoveryPolicy()
    policy.synchronize(active: [first], context: "layout-a", now: start)
    expect(policy.recordPlaced(first, now: start) == nil, "first successful correction is allowed")
    expect(policy.recordPlaced(first, now: start.addingTimeInterval(30)) == nil, "second successful correction is allowed")
    expect(policy.recordPlaced(first, now: start.addingTimeInterval(60)) == .fight(seconds: 600), "third return is a fight")
    expect(policy.isBenched(first, now: start.addingTimeInterval(61)), "fight benches this appearance")
}

print("appearance and context reset")
do {
    var policy = RecoveryPolicy()
    policy.synchronize(active: [first], context: "layout-a", now: start)
    _ = policy.recordStuck(first, now: start)
    policy.synchronize(active: [first, replacement], context: "layout-a", now: start)
    expect(!policy.isBenched(replacement, now: start), "a recreated window does not inherit an old bench")
    policy.synchronize(active: [first], context: "layout-b", now: start)
    expect(!policy.isBenched(first, now: start), "a layout or click change clears the old bench")
    expect(policy.recordStuck(first, now: start) == .retryAfter(attempt: 1, seconds: 1), "a context change clears the old retry count")
}

print("targeted reset")
do {
    var policy = RecoveryPolicy()
    policy.synchronize(active: [first, second], context: "layout-a", now: start)
    for offset in [0.0, 30.0, 60.0] {
        _ = policy.recordPlaced(first, now: start.addingTimeInterval(offset))
    }
    _ = policy.recordStuck(second, now: start)
    policy.reset(second)
    expect(policy.isBenched(first, now: start.addingTimeInterval(61)), "resetting icon B preserves icon A's fight cooldown")
    expect(!policy.isBenched(second, now: start), "resetting icon B clears only icon B")
    expect(policy.recordStuck(second, now: start) == .retryAfter(attempt: 1, seconds: 1), "resetting icon B clears its retry count")
}

print("pruning")
do {
    var policy = RecoveryPolicy()
    policy.synchronize(active: [first], context: "layout-a", now: start)
    _ = policy.recordStuck(first, now: start)
    policy.synchronize(active: [], context: "layout-a", now: start)
    policy.synchronize(active: [first], context: "layout-a", now: start)
    expect(!policy.isBenched(first, now: start), "a disappeared appearance returns with clean state")
    expect(policy.recordStuck(first, now: start) == .retryAfter(attempt: 1, seconds: 1), "pruning clears the failure count")
}

print(failures == 0 ? "all passed" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

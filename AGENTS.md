# shelf: notes for coding agents

shelf is a macOS 26 menu bar manager in Swift. It keeps menu bar icons where the user put them.

## Build and test
- Build: `swift build`. No dependencies. XCTest is not used.
- Test: `scripts/verify-reliability.sh`. It builds all targets and runs the four offline suites.
- Brake test: `node --test scripts/watch.test.mjs`.
- `swift run ShelfChurn <path to shelf> 50` moves real icons. Run it only when the user agrees.
- `scripts/install.sh` changes the machine (app, login agent). Run it only when the user asks.

## Layout
- `Sources/ShelfCore`: pure logic. Icon ids, the layout memory, the planner, the check. Test changes here in `ShelfSelfTest`.
- `Sources/shelf`: the app and the CLI in one binary. `shelf run` is the app.
- `docs/DECISIONS.md`: each design decision (D1 to D17) and its reason. Read it before you change the design.

## Rules
- One live list feeds every view (D3). Do not cache a copy per view.
- Learn a layout only from a whole user ⌘-drag or the settings window (D7).
- Never fight the user or an app (D6).
- Pause on incomplete ownership or ambiguous display geometry. Never plan from a partial scan.
- macOS 26 behavior (D8, D9, D14) was verified live. Re-verify it before you change it.
- Out of scope: always-hidden section, themes, search, helper process, updater.

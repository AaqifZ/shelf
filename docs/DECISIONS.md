# Decisions

Each decision has a number, the choice, and the reason. Update this file when a decision changes.

Test 1 is the live churn test (`swift run ShelfChurn`): a fake app adds and removes its icon 50 times, and shelf must put it back each time. "Run N" is the Nth time we ran it.

**D1. Build a small one, reuse the mechanisms.** shelf does not depend on another menu bar manager. Ice (GPLv3) has had no commits since September 2025, and its active fork Thaw is a large app. shelf adapts only the four mechanisms it needs and is GPLv3 too (see NOTICE).

**D2. Remember the layout, fix drift.** Ice saves no layout: the menu bar is its only state. An app that re-creates its icon (a timer, for example) lands wherever macOS puts it. shelf keeps a layout memory (`~/.shelf/config.json`) and moves drifted icons back. Absent icons keep their place in the memory.

**D3. One live list feeds every view.** Ice's layout pane showed a cached snapshot, so it could list icons in an order the menu bar no longer had. shelf's views draw only from the live list. Pictures of icons that no longer exist are dropped at once.

**D4. The divider never expands.** Hidden icons are shown only in the shelf bar, never by expanding them into the menu bar. This removes the expand and collapse state, and the collisions with the notch and the app menus.

**D5. Closed-loop moves.** Plan, do one move, scan again, re-plan. At most 8 moves a tick. Each move is anchored on the nearest icon already in place, so each move makes progress and the loop always ends (proved by 500 random shuffles in `ShelfSelfTest`).

**D6. Never fight, never give up.** No moves while a mouse button is down, the mouse just moved, or a menu is open. A move that fails is retried after 2, 4, 8 ... up to 60 seconds, without end: failures are usually transient (an earlier version gave up for 10 minutes after one failed move, and Test 1 lost 6 of 50 cycles). A move that works but does not stay, three times in two minutes with no layout change and no click, is a fight: shelf leaves that icon alone for 10 minutes. Counted per appearance (window), because an icon that comes back 40 times a day needs 40 moves. A move that does not lift is tried once more with the press on the icon itself (Thaw's "source-anchored" move).

**D7. Learn only from a whole ⌘-drag.** A ⌘-mouse-down in the menu bar followed by its mouse-up teaches shelf a new layout. shelf tags its own synthetic events and ignores them, and a stray mouse-up alone teaches nothing. (Found live: shelf's own click echo once taught it a wrong layout.)

**D8. Session-tap events.** On macOS 26, a ⌘-drag posted to the app's pid does nothing. Posted to the session tap, it moves the icon in about 35 ms.

**D9. Identity = bundle id + window name.** On macOS 26 every status item window belongs to Control Center. The owning app comes from Accessibility (`AXExtrasMenuBar` frames matched by centre, in parallel, about 0.7 s for all apps, once per new window).

**D10. Skip macOS indicators.** AudioVideoModule (screen recording or microphone in use) and similar items come and go and cannot move. shelf ignores them, as Ice does.

**D11. One manager at a time.** Two managers push the same icons around. shelf quits Ice while it runs. `shelf use shelf|ice` switches. Ice can stay installed.

**D12. Seed positions at the right end.** A new status item lands at the far left, which on a notched Mac is off the screen, and macOS never shows it. shelf asks for the right end on first run. The divider is created 1 pt wide and stretched after macOS places it.

**D13. An independent check.** `shelf check` scans the menu bar in a separate process and compares it with the app's live list, the shelf bar, the settings window and the memory. The app runs it every hour into `~/.shelf/check.log`.

**D14. Control Center's icons are one block at the right.** On macOS 26 another app's icon cannot be dropped among or right of Wi-Fi, Battery and the other Control Center icons (moves there fail every time, found by Test 1). The planner keeps app icons left of that block.

**D15. No "has no icons" cache, and never give up matching.** shelf once remembered which apps had no menu bar icons and skipped them. An app that creates its icon on demand was skipped forever, so its icon was never managed (found live by Test 1 run 4). Every new window now checks every app (0.7 s, in parallel), and an unmatched window is retried with back-off, never dropped.

**D16. A move has three outcomes.** Placed; landed one slot off (re-plan at once, no back-off); or stuck (back off and retry). A stuck icon usually means its app's main thread is busy: macOS needs it to start the drag. Test 1's own fake app taught this: it blocked its main thread and its icon could not be moved, by shelf or by hand.

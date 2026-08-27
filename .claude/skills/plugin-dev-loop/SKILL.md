---
name: plugin-dev-loop
description: Develop, test, and release this Omarchy shell plugin — hot-reload behavior, validation, headless IPC driving, log watching, manual test checklist, and the release procedure. Use whenever verifying changes or shipping a version.
---

# Plugin dev loop

The running shell watches this directory and logs "Local plugin changed,
reloading" on every file save — **but do not trust it** (verified 2026-08-27):

- After a QML edit, the live bar-widget instance keeps running the OLD code.
- After a `manifest.json` edit, the widget is torn down and NOT re-added —
  the bar icon disappears. A leaked stale instance may still answer IPC,
  which makes "it responds, therefore it loaded" a false conclusion.

The only reliable way to load changes is `omarchy-restart-shell` (a second
of bar flicker; safe). Batch your edits, restart once, then test.

## Verify a change

```sh
# 1. Manifest + structure validation (from the plugins dir)
cd ~/.config/omarchy/plugins && omarchy plugin validate godlewski.framework-led-matrix-helper

# 2. QML lint (informational — this qmllint can't parse IpcHandler's typed
#    `function f(): void` signatures; ignore errors on those lines)
qmllint -I /usr/share/omarchy/shell *.qml

# 3. Watch the shell for QML errors while reloading / interacting
journalctl --user -f | grep omarchy-shell
```

After `omarchy-restart-shell`, a healthy load logs `Configuration Loaded`
with no `qml:` warning/error lines; then confirm the widget is live with the
summon probe below.

## Drive the UI headlessly

```sh
# Widget's own IPC target (functions defined in LedMatrix.qml's IpcHandler)
omarchy-shell godlewski.framework-led-matrix-helper toggle|open|close|sleep|wake|refresh

# Bar summon routing (exercises the panel contract: opened/open/close)
omarchy-shell shell toggle godlewski.framework-led-matrix-helper
omarchy-shell shell hide godlewski.framework-led-matrix-helper
```

The summon path doubles as a liveness probe: if the widget is dead/missing
it logs `WARN qml: summon: no live bar widget for: <id>` — check for that
line after driving it.

Close anything you opened when done — the panel is on the user's screen.

## Manual test checklist (run after UI changes)

- Click bar icon → panel opens; click outside → closes; Esc → closes.
- j/k walks every row on both tabs; h/l adjusts brightness/target/effect/tab;
  Enter opens the Display dropdown and toggles power; Tab switches to a
  neighboring panel.
- Display dropdown: selecting a streamer (Clock/EQ/Bounce) disables the
  Effect group with the hint text; selecting a pattern re-enables it.
- Staging: selecting a display/effect or typing text paints the emulated
  twins only (accent border + "Preview only" hint appear) — hardware is
  untouched until Apply; Revert and `x` discard; Enter in the text field
  applies; animated twins tick (clock/EQ/bounce, breathe/blink).
- Target switch (Both/Left/Right) shows that target's recorded state.
- Text display: field appears, Enter sends, Esc returns focus to the panel.
- Panels tab: Identify pulses the right physical panel; Left/Right assignment
  updates labels everywhere; Flash shows the ConfirmDialog (mouse and
  keyboard), cancel works.
- Bar icon: wheel changes brightness, right-click sleeps/wakes.
- Disable + re-enable the plugin and `omarchy-restart-shell`; confirm no
  journal errors.

## Release

1. Bump `version` in `manifest.json` by a PATCH only (e.g. 1.0.0 → 1.0.1);
   minor/major bumps only when the user explicitly asks for one.
2. Update `README.md` if user-visible behavior changed.
3. Re-run validation + the checklist above.
4. Commit `vX.Y.Z: <summary>` — only when the user asks.
5. Publishing requires: permanent namespaced id (no `omarchy.*` prefix, no
   `clonedFrom` field), README with install/usage/removal, no symlinks in the
   plugin folder.

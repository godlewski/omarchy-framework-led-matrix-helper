# Framework LED Matrix Helper — agent guidelines

Omarchy shell plugin (bar widget + popup panel) that controls the Framework 16
LED Matrix input modules. Lives at
`~/.config/omarchy/plugins/godlewski.framework-led-matrix-helper/` — you are
editing a live UI on the user's screen, and despite the shell logging
"reloading" on save, changes only actually load via `omarchy-restart-shell`
(a manifest.json save even removes the bar icon until then — see the
plugin-dev-loop skill).

## Skills

Load these before working in their area — they carry the details this file
only points at:

- **omarchy-shell-ui** — the shell's QML UI kit (`qs.Ui` / `qs.Commons`):
  component inventory, theming tokens, keyboard-cursor contract, panel
  contract. Load before touching any `.qml` file.
- **led-matrix-cli** — hardware semantics and `bin/led-matrix-ctl`: what
  composes with what on the panels, serial quirks, safe testing. Load before
  touching `bin/` or the display/effect logic.
- **plugin-dev-loop** — validate, lint, reload, IPC-drive, and release the
  plugin. Load when testing or shipping.

## Repo layout

| File | Role |
|---|---|
| `manifest.json` | Plugin manifest (`bar-widget` kind, entry `LedMatrix.qml`) |
| `LedMatrix.qml` | Entry point. ALL state and every `Process` live here; also the bar button, panel shell, keyboard cursor, IPC |
| `ControlsTab.qml` | Pure view: emulated twin panels, target / brightness / display / effect controls, Apply/Revert |
| `EditorTab.qml` | Pattern editor: interactive grid over PanelPreview, save/load/delete of custom patterns (9x34 PNGs via ctl `save-pattern`/`list-patterns`; displays as `custom:<name>` values) |
| `FirmwareTab.qml` | Pure view: per-panel identify, side assignment, flashing |
| `PanelPreview.qml` | One emulated 9x34 module (Canvas dot grid) rendering a frame from the model |
| `LedMatrixModel.js` | Pure functions: domain rules (display vs effect), labels, option lists, and the frame generators that emulate firmware rendering (font, patterns, streams — sourced from inputmodule-rs). No QML types allowed here |
| `bin/led-matrix-ctl` | Self-contained bash CLI over `inputmodule-control`; the only thing that talks to hardware |
| `bin/led-matrix-png` | PNG <-> 306-bit frame codec (canonical encode, liberal decode for imports) |
| `bin/led-matrix-bounce` | Frame-streaming bounce animation loop |
| `bin/led-matrix-flash` | RP2040 UF2 firmware flasher |

Keep that separation: views never own state or spawn processes; the model file
never imports QML; hardware access never happens outside `bin/`.

## The domain model (do not regress this)

The UI is built on the hardware's real composition rules — see the header
comment in `LedMatrixModel.js`:

- A **display** owns the 9x34 grid: firmware patterns and text are static;
  clock/eq/mic-eq/bounce are host-side frame **streamers** that continuously
  overwrite the grid.
- An **effect** (breathing/blinking) only modulates brightness, so it composes
  with patterns/text — but never with a streamer (the ctl has a single host
  animation slot).

The UI must keep these as one Display picker plus an Effect group that is
disabled while a streamer owns the display. Do not reintroduce independent
"pattern" and "animation" pickers that patch up conflicts after the fact.

## State flow

- `panelState` in `LedMatrix.qml` is per-target APPLIED optimistic state
  (`{display, effect, text, brightness}`). The firmware has no readback for
  these; `animation-status` is the only ground truth and is reconciled into
  the `"all"` bucket by `statusProc` (device buckets inherit "all" via
  `stateFor`'s fallback).
- `stagedState` is the same shape for PENDING edits: display/effect/text
  changes stage only (painting the emulated twins); `commitStaged()` sends
  the diff to hardware and folds it into `panelState`. Brightness and
  power are immediate, not staged. A staged bucket exists only when
  something was staged — `stagedFor()` falls back to applied state, so
  revert is just `stagedState = {}`.
- **QML `var` gotcha:** never mutate `panelState`/`flashStatus` in place —
  assigning the same object reference back does not fire change signals.
  Always build a fresh top-level object (`recordFor` / `setFlashStatus` do
  this correctly).
- Settings (`swapped`, `leftPort`, `rightPort`) live in the widget's
  `shell.json` entry, written via the serialized `barSet` queue
  (`omarchy bar set …`; never pass `--json`, it silently drops `false`).
  Reads come from `setting()` and hot-reload via `onSettingsChanged`.
- The swap derivation (`deriveSwap`) is deliberately an unconditional write
  compared against raw discovery order — read its comments before "fixing" it.

## Non-negotiable UI rules

- Use the shell kit (`qs.Ui`) — `Button`, `ButtonGroup`, `Dropdown`,
  `PanelSlider`, `ToggleSwitch`, `TextField`, `ConfirmDialog`, `PanelHero`,
  `PanelSeparator`, `PanelSectionHeader`, `CursorSurface`, `PanelKeyCatcher`,
  `KeyboardPanel`. Never hand-roll a control the kit already ships.
- All colors from `root.fg` (bar foreground) / `Color.*`, all sizes from
  `Style.space()` / `Style.spacing.*` / `Style.font.*`. No literal px or hex.
- Keyboard and mouse share one cursor (`cursorRow` on the root; rows paint
  only from `hasCursor`, mouse hover calls `setCursor`). Every new
  interactive row must join `cursorRows` and both input paths.
- The panel contract on the widget root (`opened`, `open()`, `close()`,
  `toggle()`, `closeForPopoutSwitch()`, `popoutSwitchClosing`) is what makes
  `omarchy-shell shell summon/toggle` and bar popout switching work. Keep it.

## Testing & gotchas

- Validate: `omarchy plugin validate ~/.config/omarchy/plugins/godlewski.framework-led-matrix-helper`
- **Hot reload is unreliable** — QML saves leave the old code running and a
  manifest.json save drops the widget from the bar. Batch edits, then
  `omarchy-restart-shell`, then verify with the summon probe (a dead widget
  logs `summon: no live bar widget`).
- Drive the UI headlessly:
  `omarchy-shell godlewski.framework-led-matrix-helper toggle|open|close|sleep|wake|refresh`
  and `omarchy-shell shell toggle godlewski.framework-led-matrix-helper`.
- Watch for QML errors: `journalctl --user -f | grep omarchy-shell`.
- Manual test checklist after UI changes: click open, Esc close, j/k/h/l
  cursor walk, Tab panel-switch, target switch restores that target's state,
  effect disabled under clock/eq/bounce, flash confirm via keyboard and mouse.
- Hardware tests briefly take over the user's visible LED panels — keep
  writes short and restore state (see the led-matrix-cli skill).

## Releasing

Bump `version` in `manifest.json` by a PATCH only (1.0.0 → 1.0.1) — minor
and major bumps are Steve's call, never made unprompted. Update `README.md`
if behavior changed, re-run validate, commit with a `vX.Y.Z:` prefixed
summary. Do not commit unless asked.

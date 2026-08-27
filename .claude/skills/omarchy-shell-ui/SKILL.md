---
name: omarchy-shell-ui
description: Omarchy shell QML UI kit reference for plugin development — component inventory (qs.Ui), theming tokens (qs.Commons Style/Color), keyboard-cursor contract, panel/popout contract. Use before writing or modifying any QML in this plugin.
---

# Omarchy shell UI kit

The shell's QML sources are the ground truth. They live at:

- `/usr/share/omarchy/shell/Ui/` — reusable components (`import qs.Ui`)
- `/usr/share/omarchy/shell/Commons/` — `Style`, `Color`, `Border`, `Util` singletons (`import qs.Commons`)
- `/usr/share/omarchy/shell/plugins/` — first-party plugins to copy patterns from. The **audio panel** (`plugins/panels/audio/Panel.qml`) is the canonical rich panel; `plugins/bar/widgets/` has simple bar widgets.

Component headers are well documented — when unsure of an API, `Read` the
component file rather than guessing.

## Rule zero

Never hand-roll a control the kit ships. Hand-rolled Rectangles+MouseAreas
break theming (hover fills, focus rings, border tokens all come from
`shell.toml` via `Style`), keyboard support, and consistency.

## Component inventory (qs.Ui)

| Component | Use for | Key API |
|---|---|---|
| `BarWidget` | Base for bar entry points | `bar`, `moduleName`, `settings`, `setting(name, fallback)`, `broadcast(method)` |
| `BarIconButton` | The icon in the bar | `text` (glyph), `bar`, `active`, `tooltipText`, `slotSize`, `onPressed(button)`, `onWheelMoved(delta)` |
| `KeyboardPanel` | Popup card anchored to a bar icon | `anchorItem`, `bar`, `owner`, `open`, `focusTarget`, `contentWidth/Height`, `fittedContentWidth/Height(desired, cap)` |
| `PanelKeyCatcher` | Key dispatch inside a panel | signals `moveRequested(dx,dy)`, `activateRequested`, `closeRequested`, `tabRequested(dir)`, `textKey(t)`; `blocked` to hand keys to an inner editor/popup |
| `Button` | Every clickable thing | `text`, `iconText`, `bordered`, `selected`, `active`, `hasCursor`, `tooltipText`, `leftAlign`, `clicked()`, `rightClicked()`, `hovered(bool)` |
| `ButtonGroup` | Pick-one-of-N chip row | `options` (`[{value,label,icon?,tooltip?}]` or `string[]`), `value`, `changed(value)`, `cursorIndex`, `hovered(index,bool)` — never assigns its own `value` |
| `Dropdown` | Single-select with overlay popup | `label`, `options`, `value`, `changed(value)`, `hasCursor`, `popupOpen`, `open()/close()/toggle()`, `hovered(bool)`. **Assigns its own `value` on select** — re-assert external state with a `Binding` element |
| `SearchableDropdown` | Dropdown + filter input | same visuals, adds embedded filter |
| `PanelSlider` | Sliders | `minimum/maximum/step/integer`, `value`, `liveValue`, `dragging`, `moved(v)`, `released(v)`, `rightClicked()`, `tickCount` |
| `ToggleSwitch` | Bare on/off switch | `checked` (caller owns it — flip on `toggled()`), `busy`, `hasCursor`, `hovered(bool)`, `containsMouse` |
| `Toggle` | Labeled row + switch | label + ToggleSwitch composed |
| `TextField` | Text input (QQC-derived) | inherits QQC TextField API; `hasCursor`, `password`; hover via inherited `hovered` |
| `NumberField` | Numeric input | |
| `ConfirmDialog` | Destructive-action confirm overlay | `opened`, `message`, `confirmText`, `selectedIndex`, `canceled()`, `confirmed()`, `handleKey(event)` — index 1 renders as destructive |
| `PanelHero` | Panel header: icon + title + meta + trailing control | `iconComponent`, `title`, `meta` (auto-uppercased), `detail` (pill), `trailingControl` (Component) |
| `PanelSectionHeader` | "BRIGHTNESS"-style section label | `text`, `foreground` |
| `PanelSeparator` | 1px section divider | `foreground` |
| `CursorSurface` | Row chrome for keyboard+mouse cursor | `hasCursor`, `current`, `outline`, `fill` — see contract below |
| `PanelToolTip` | Tooltip for non-Button items | `visible`, `text`, `fontFamily` |
| `BorderSurface` | Themed rect with border spec | building block; prefer higher-level components |

## Theming tokens (qs.Commons)

- Spacing: `Style.space(px)` (scaled), `Style.spacing.*` (`controlHeight`,
  `controlPaddingX`, `labelGap`, `panelGap`, `lg`, `md`, …).
- Type: `Style.font.family` + `Style.font.caption|body|title|heading|display`.
- State fills/borders: `Style.hoverFillFor(fg, accent)`,
  `selectedFillFor`, `controlFill(focused, hot, fg, accent)` — themes override
  these via `[controls]` in shell.toml; never invent hover colors.
- Colors: panel content uses the bar foreground (`bar.foreground`, this
  plugin exposes it as `root.fg`); dim secondary text with
  `Qt.darker(fg, 1.4)`; popup surface colors are `Color.popups.*`.
- Radius: `Style.cornerRadius` (mirrors Hyprland rounding).

## The cursor contract

Panels keep ONE highlight for keyboard and mouse combined:

1. Root owns `cursorActive` + a cursor position (here: `cursorRow` string).
2. Rows paint **only** from `hasCursor` (via `CursorSurface` or the
   component's `hasCursor` prop) — never from `containsMouse`.
3. Mouse hover reports back (`hovered` signals / `HoverHandler`) and calls the
   root's `setCursor(row)`, so the mouse moves the same cursor.
4. `PanelKeyCatcher` drives j/k/h/l/Enter/Esc/Tab; set `blocked` while a
   `Dropdown` popup is open or a `TextField` has focus.

## Panel/popout contract (bar widget root)

`Bar.findPanelWidget` requires on the widget root: readonly `opened`,
`open()`, `close()`; popout switching also wants `closeForPopoutSwitch()` and
`popoutSwitchClosing`. `switchPanel(direction)` = `bar.switchPanelFrom(root, direction)`.
Without these, `omarchy-shell shell summon/toggle <id>` logs
"no live bar widget" and hotkey routing fails.

## Pitfalls

- `Dropdown` severs plain bindings on `value` (internal assignment). Use
  `Binding { target: dd; property: "value"; value: <state> }`.
- QML `var` properties: rebuild objects/arrays instead of mutating in place,
  or change signals never fire.
- Reserve space for state borders; kit `Button` already does — another reason
  not to hand-roll.
- Panel content that can exceed the height cap needs a `ScrollView` with the
  audio panel's `ensureCursorVisible` pattern.

---
name: led-matrix-cli
description: Framework 16 LED Matrix hardware semantics and the bin/led-matrix-ctl CLI — display/effect composition rules, serial quirks, port-based side identity, firmware flashing, and how to test against real panels safely. Use before changing bin/ scripts or the display/effect logic in QML.
---

# LED Matrix hardware & CLI

Two 9x34 LED input modules on the Framework 16, driven over USB-CDC serial by
`inputmodule-control` (from FrameworkComputer/inputmodule-rs). Everything in
this plugin funnels through `bin/led-matrix-ctl`; QML never calls
`inputmodule-control` directly.

## Composition rules (the whole reason the UI looks the way it does)

| Thing | Mechanism | Composes with |
|---|---|---|
| Patterns / images / text / percentage | one-shot firmware command, static grid | effects |
| `breathing`, `blinking` (**effects**) | host loop sending only brightness | any static grid content |
| `clock`, `eq`, `mic-eq` (via inputmodule-control), `bounce` (our frame loop) (**streamers**) | host loop streaming full frames — owns the grid | nothing |
| Games (`snake`, `pong`, …) | run **on-device**, overwrite grid every tick until `--stop-game` | nothing (not exposed in UI yet) |

There is a single host animation slot (`~/.local/state/<plugin-id>/animation.pid`
+ `.type`), so an effect and a streamer can never run simultaneously.
`led-matrix-ctl` enforces the transitions: `pattern`/`text` call
`stop_display_owners` (kills streamers, leaves effects running); `animate`
kills whatever loop ran before.

## CLI quick reference

```
led-matrix-ctl [--swap] [--device /dev/ttyACMx] <action>
  list                      effective-order device list (--swap reverses)
  brightness 0-100 | pattern <name> | text <str> | percentage <n>
  sleep | wake | off
  animate <breathing|blinking|clock|eq|mic-eq|bounce> | stop-animation
  animation-status          running type, or empty
  frame <306 bits>          display an arbitrary 9x34 frame (row-major 0/1
                            string; rendered to PNG via python3, sent as
                            --image-bw). Used for pixel-shifted text/drawings
  save-pattern <name> <bits>  save a drawing to the pattern library
  list-patterns             one "name|bits" line per saved pattern
  import-pattern <png> [name]  import any 9x34 PNG into the library
  delete-pattern <name>     remove a saved pattern
  deps                      print missing binaries, one per line (runs
                            before the inputmodule-control guard)

Pattern library: ~/.local/share/<plugin-id>/patterns/ as 9x34 PNGs. All PNG
work goes through bin/led-matrix-png (encode = canonical grayscale;
decode = liberal: gray/RGB/palette/alpha, bit depths 1-8, filters 0-4;
rejects interlaced/16-bit/wrong-size). PNGs dropped into the library dir by
hand are decoded the same way, so that's a valid import path.

Dependency UX: the widget shows a guided-setup state (bar icon + panel with
an Install button) when `deps` reports anything missing — the install runs
`yay -S --needed` via omarchy-launch-floating-terminal-with-presentation,
because inputmodule-control is an AUR package and omarchy-pkg-add is
pacman-only.
  game <name> | stop-game
  device-info               dev|usb-port|fw-version   (ALWAYS unswapped order)
  latest-firmware           tag|url (1h cache); download-firmware <tag>
  identify                  brightness pulse (needs --device)
```

## Identity: ports, not tty numbers

The two panels share one serial number and enumerate in random order per boot,
so `/dev/ttyACM*` and list order are unstable. The **USB port path**
(e.g. `1-4.2`, from `/sys/class/tty/*/device`) is stable per physical slot.
Side assignment stores `leftPort`/`rightPort` in shell.json; the `swapped`
flag is then *derived*: `device-info` runs unswapped, so
`deviceInfo[0].port !== leftPort → swapped`. Manual swap only matters when no
ports are assigned.

## Serial quirks (hard-won — keep these behaviors)

- Killing a frame-streamer mid-write can desync the firmware's command
  parser; `flush_parsers` sends a few idempotent `--animate false` writes to
  realign. Don't remove it.
- Animator PIDs can block in serial reads for seconds — `stop_animation`
  waits for real death, escalating to SIGKILL, before the next command runs.
- Stale PID files may point at reused PIDs — `pid_is_ours` checks
  `/proc/<pid>/cmdline` before killing.
- Background animators must not inherit stdout/stderr, or a QML `Process`
  reading the pipe blocks forever (wedging the widget's action queue).
- `--string ""` leaves previous text on the panel — pad chunks with spaces.
- `animate` forces brightness to 80 for visibility; the QML re-asserts the
  user's brightness afterwards.
- `all-on` lifts the firmware brightness cap to max — UI records 100.

## Flashing (bin/led-matrix-flash)

RP2040 UF2 flow: `--bootloader` → module re-enumerates as RPI-RP2 mass
storage → copy `.uf2` → self-flash → wait for the module back **on the same
USB port** (tty number may change). Downloads are verified by the `UF2` magic
before use. One line of progress per step on stdout — the QML streams it into
the panel. Never flash both panels concurrently.

## The firmware sleeps after 60s of silence

`SLEEP_TIMEOUT` in ledmatrix `main.rs` is 60s: the module fades to sleep one
minute after the last received command, and every command resets the timer
(and wakes a sleeping module). Streams and brightness-modulator loops
therefore never sleep; static displays (patterns/text/frames) DO unless the
host keeps talking. The widget runs a 45s brightness keepalive (write-only,
grid untouched) while panels are awake, lit, and no animation is running —
remove it and applied patterns fade out after a minute. USB autosuspend is
not a factor (disabled for these devices, `power/control = on`).

## Per-panel "off" is brightness-0, not sleep

Any serial command — even a status query, likely via the connection's DTR
toggle — wakes a sleeping module (verified 2026-08-27). So a per-panel off
under a running animation cannot use `--sleeping`: the streamer would re-wake
it instantly. The plugin turns a single panel off by sending brightness 0 and
leaving the recorded brightness untouched; effects (breathing/blinking) drive
brightness themselves, so starting one re-lights every panel (the UI reflects
that). Global sleep (hero switch) still uses real `sleep`/`wake`.

## Testing against real hardware

The panels sit on the user's machine — tests are user-visible.

- Read-only (always safe): `list`, `animation-status`, `device-info`,
  `latest-firmware`.
- Visible but harmless: `identify`, `brightness`, `pattern`; finish by
  restoring the prior state (check `animation-status` first; re-run its
  animation or re-apply the pattern afterwards, and end with
  `stop-animation` only if nothing was running before).
- Never run `download-firmware`/flash paths as a "test"; mock with an echo
  script if the chain logic needs exercising.
- After killing anything mid-stream, expect garbled panels until a pattern
  write realigns the parser.

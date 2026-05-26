# XboxMacControl

Use an Xbox controller as a lightweight macOS remote.

The current tool maps the Xbox controller to macOS pointer, scroll, click, and shortcut events:

- left stick: scroll under the mouse pointer
- right stick: move the mouse pointer
- right trigger: left click
- left trigger: right click
- hold B: hold `Control`.
- X: copy
- Y: paste
- A: Return
- LB: undo
- RB: Delete, with repeat while held
- D-pad left/right: switch macOS desktops/spaces
- `Control-C`: quit

Desktop switching uses macOS System Events to send `Control-Left` and `Control-Right`.
If macOS asks for Automation or Accessibility permission for your terminal app, allow it.

## Dictation

macOS often does not allow synthetic events to behave exactly like the hardware `Fn/Globe` key. This tool can hold `Control` from the controller:

1. Open `System Settings -> Keyboard -> Dictation`.
2. If your dictation tool can use a modifier-only hotkey, set it to `Control`.
3. Run this tool. Holding `B` holds `Control`; releasing `B` releases it.

## Requirements

- macOS 13 or newer
- Swift toolchain / Xcode command line tools
- A connected Xbox controller
- macOS Accessibility permission for the terminal or app that launches the tool

## Run

```sh
swift run xbox-scroll
```

If the program starts but pages do not scroll, open:

```text
System Settings -> Privacy & Security -> Accessibility
```

Then allow the terminal app you used to launch the command, such as Terminal, iTerm, or Codex.

## Tuning

```sh
swift run xbox-scroll --speed 24
swift run xbox-scroll --mouse-speed 24
swift run xbox-scroll --deadzone 0.22
swift run xbox-scroll --invert-y
swift run xbox-scroll --invert-mouse-y
swift run xbox-scroll --no-horizontal
swift run xbox-scroll --debug
swift run xbox-scroll --input hid --debug
swift run xbox-scroll --right-stick auto
swift run xbox-scroll --right-stick zrz
swift run xbox-scroll --dictation-button b
swift run xbox-scroll --diagnose --no-clicks --no-dictation
```

Available options:

- `--speed <number>`: scroll speed in pixels per frame, default `18`
- `--mouse-speed <number>`: pointer speed in pixels per frame, default `18`
- `--deadzone <number>`: ignored center zone from `0.0` to `0.95`, default `0.16`
- `--invert-x`: reverse horizontal scrolling
- `--invert-y`: reverse vertical scrolling
- `--invert-mouse-x`: reverse horizontal pointer movement
- `--invert-mouse-y`: reverse vertical pointer movement. The default matches this Xbox controller's `Z/Rz` right-stick direction.
- `--no-horizontal`: only allow vertical scrolling
- `--no-mouse`: disable right-stick pointer movement
- `--no-clicks`: disable trigger mouse clicks
- `--no-fn`: disable dictation shortcut trigger
- `--no-dictation`: disable dictation shortcut trigger
- `--debug`: print live stick values and scroll deltas
- `--diagnose`: print raw HID usage pages, usages, raw values, and normalized values
- `--test-scroll`: post scroll events without using the controller
- `--input <mode>`: choose `auto`, `gameController`, or `hid`, default `auto`
- `--right-stick <pair>`: choose `auto`, `xy`, `rxry`, or `zrz`, default `auto`
- `--triggers <pair>`: choose `none`, `xy`, `rxry`, or `zrz`, default `none`
- `--fn-button <button>`: alias for `--dictation-button`
- `--dictation-button <button>`: choose which gamepad button holds `Control`: `a`, `b`, `x`, `y`, `menu`, `view`, `home`, `share`, `lb`, `rb`, `l3`, or `r3`, default `b`
- `--tap <session|hid>`: choose the event tap target, default `session`
- `--unit <pixel|line>`: choose scroll units, default `pixel`

## Troubleshooting

First test whether macOS accepts scroll events from this process:

```sh
swift run xbox-scroll --test-scroll
```

Move the mouse pointer over a scrollable page or list before the 3 second countdown ends.

If that does not scroll, keep the pointer over the target area and try:

```sh
swift run xbox-scroll --test-scroll --unit line
swift run xbox-scroll --test-scroll --tap hid
```

Then check whether the controller values are arriving:

```sh
swift run xbox-scroll --debug
```

Move the left stick. If `gc=(0.000, 0.000)` never changes, try the lower-level HID reader:

```sh
swift run xbox-scroll --input hid --debug
```

If `HID matched: Xbox Wireless Controller` appears but no `HID axis ...` lines appear while moving the stick, macOS is seeing the controller device but is not delivering input values to this process. Check `System Settings -> Privacy & Security -> Input Monitoring` and allow the terminal app, then unplug/reconnect the controller and rerun.

For the tested Xbox Wireless Controller, macOS reports the right stick as `Z/Rz`, and the program auto-detects that pair. If the left stick scrolls but the right stick does not move the pointer, force that pair:

```sh
swift run xbox-scroll --input hid --debug --right-stick zrz
```

In debug mode, right-stick pointer movement prints `mouse gc=... hid=... move=...`. Holding the dictation button prints `Control down` and releasing it prints `Control up`. If you want to use a different gamepad button:

```sh
swift run xbox-scroll --input hid --debug --dictation-button view
```

If right-stick movement or the Fn button still cannot be identified, run diagnosis mode and move one control at a time:

```sh
swift run xbox-scroll --diagnose --no-clicks --no-dictation
```

Move the right stick in a circle, then press Menu, View, LB, RB, L3, and R3. Look for `HID value page=... usage=...` lines changing; those lines show how macOS reports the control.

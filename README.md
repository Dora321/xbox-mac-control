# XboxMacControl

Use an Xbox controller as a lightweight macOS remote.

The current tool maps the Xbox controller to macOS pointer, scroll, click, and shortcut events:

- left stick: scroll under the mouse pointer
- right stick: move the mouse pointer
- right trigger: left click
- left trigger: right click
- hold Menu: Fn shortcut layer
- `Control-C`: quit

## Fn Shortcuts

Hold the Xbox Menu button, then press:

- `A`: Return
- `B`: Escape
- `X`: Command-C
- `Y`: Command-V
- `LB`: Command-[
- `RB`: Command-]
- `View`: Control-Up
- `L3`: Command-W
- `R3`: Command-Tab

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
swift run xbox-scroll --right-stick zrz --triggers rxry
```

Available options:

- `--speed <number>`: scroll speed in pixels per frame, default `18`
- `--mouse-speed <number>`: pointer speed in pixels per frame, default `18`
- `--deadzone <number>`: ignored center zone from `0.0` to `0.95`, default `0.16`
- `--invert-x`: reverse horizontal scrolling
- `--invert-y`: reverse vertical scrolling
- `--invert-mouse-x`: reverse horizontal pointer movement
- `--invert-mouse-y`: reverse vertical pointer movement
- `--no-horizontal`: only allow vertical scrolling
- `--no-mouse`: disable right-stick pointer movement
- `--no-clicks`: disable trigger mouse clicks
- `--no-fn`: disable Menu-held shortcuts
- `--debug`: print live stick values and scroll deltas
- `--test-scroll`: post scroll events without using the controller
- `--input <mode>`: choose `auto`, `gameController`, or `hid`, default `auto`
- `--right-stick <pair>`: choose `xy`, `rxry`, or `zrz`, default `rxry`
- `--triggers <pair>`: choose `xy`, `rxry`, or `zrz`, default `zrz`
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

If the left stick scrolls but the right stick or triggers do not behave correctly, inspect the printed `HID axis ...` lines and swap the HID axis pairs:

```sh
swift run xbox-scroll --input hid --debug --right-stick zrz --triggers rxry
```

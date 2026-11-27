# Input device checklist (manual, TestFlight)

Automated tests cover the input logic with simulated devices (`SFInputTests/InputModeMatrixTests`).
They cannot cover real hardware. Run this list on a real device before each TestFlight build.
Record the device, OS, and app build for each row. A row passes only if the behaviour matches the expected result exactly.

## Setup
- Use iPhone or iPad (iOS 26+) and a Mac (macOS 26+) with each device paired first.
- Start a Quick Flight in the default aircraft on KMRY, in calm weather.
- Keep the app in landscape for touch and tilt.

## Touch (iPhone and iPad)
- [ ] Drag the left pad: the aircraft rolls and pitches, and the stick springs back when released.
- [ ] Drag the throttle: it holds its value after release.
- [ ] Two fingers, one on each control: both respond at once.
- [ ] Tilt the device with the tilt control enabled: roll and pitch follow, and recalibrate works.
- [ ] Rotate the device to portrait and back: no stuck axes.

## Game controllers (one row per family)
For each: Xbox, PlayStation (DualSense and DualShock), 8BitDo, and any other generic pad.
- [ ] Both sticks, both triggers, and the dpad map as in the default profile.
- [ ] Released triggers read zero throttle, not full (touch throttle is not overridden).
- [ ] Buttons B and X toggle flaps down and up.
- [ ] Connect a second pad: it works alongside the first (multi-pad merge).
- [ ] Disconnect mid-flight: controls stop and the aircraft does not run away.
- [ ] Reconnect: the same pad resumes without reconfiguring.

## Flight hardware (joysticks, yokes, pedals, throttle quadrants)
- [ ] Each axis moves the expected flight control after calibration.
- [ ] Centre and full deflection are reached on each axis (no dead zone past the stop).
- [ ] Throttle quadrant at idle reads zero, and at full reads one.
- [ ] Rudder pedals drive yaw.
- [ ] Hot-plug: unplug and replug the device during flight.

## Keyboard and mouse
- [ ] W, A, S, D, Q, E drive pitch, roll, and yaw with the expected sign.
- [ ] Shift+F and F drive flaps up and down (no double firing).
- [ ] Hold a key in the menu: no repeat actions in flight.
- [ ] Mouse wheel and buttons do what the binding screen shows, if bound.
- [ ] Connect a keyboard to an iPad: keys work without the on-screen keyboard.

## Rebinding
- [ ] Rebind a key: capture works, the new key takes effect, the old key stops.
- [ ] Pressing a key already used shows a conflict and resolves on confirm.
- [ ] Hold a key while starting a capture: it is ignored (no false bind).
- [ ] Export and import a profile: bindings match after re-import.
- [ ] Press Escape during capture: capture cancels.

## Multiple devices together
- [ ] Keyboard plus gamepad in flight: both act, and an analog stick is not cancelled by a held key.
- [ ] Touch plus gamepad connected but idle: touch still flies the aircraft.

## Notes
Log each failing row with device, OS, build, and steps. Name the owning thread (touch, controller, flight hardware, keyboard and mouse, or verification).

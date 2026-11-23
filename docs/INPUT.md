# Input contract (SFInput)

Owner: gamepad thread. Every input source (touch, tilt, flight hardware, keyboard, mouse,
gamepad) reports into one shared model. Nothing bypasses `InputMapper`.

## Shape (do not change without telling all input threads)
- `DeviceState`: analog values in [-1, 1] by control ID, pressed digital IDs, modifiers.
  Sources combine with `DeviceState.merge` (analog keeps the value farther from rest).
- `Binding`: device class, control ID, modifiers, context, aircraft, target, axis settings.
- `BindingTarget`: `.axis(FlightAxis)` or `.action(FlightAction)`.
- `BindingProfile` and layers: global < device < aircraft < context. JSON import/export, schema v1.
- `InputMapper.evaluate` returns axes and actions for one frame.

## Control ID prefixes
- `key.*` keyboard (e.g. `key.w`, `key.space`)
- `gamepad.*` canonical IDs in `GamepadControl` (e.g. `gamepad.leftStick.y`, `gamepad.buttonA`)
- `touch.*` touch stick, throttle, rudder (`touch.stick.x`, `touch.stick.y`, `touch.throttle`, `touch.rudder`), touch buttons as `touch.button.<name>`
- `tilt.*` device tilt (`tilt.roll`, `tilt.pitch`)
- `mouse.*` mouse controls (keyboard and mouse thread)
- `joystick.*` or `hid.*` flight hardware (flight hardware thread)

## Rules
- Controls are analog ([-1, 1]) or digital (pressed set). Triggers are analog with rest at -1.
- New source: add an ID prefix, then add a `Binding` in a `BindingProfile`. Do not add new `FlightAxis` cases without telling the other threads.
- Camera gestures are not axes. Use a separate struct.
- Rebinding: `BindingCapture` captures the next control. Keep the prefix rule above.

## Status
- Gamepad: canonical IDs, multi-pad merge, hot-plug slots, Apple reads all pads (this milestone).
- Not yet: HID fallback for unrecognised pads on macOS, DualSense haptics and adaptive triggers.

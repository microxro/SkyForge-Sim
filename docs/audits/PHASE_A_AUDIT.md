# Phase A stub and dishonest-code audit (2026-11-08)

Scope: production sources under `Packages/SkyforgeKit/Sources` and `App`.
- Swept for TODO, FIXME, placeholder, stub, `fatalError("…")` and fake data. None found in shipped paths; the "stub" hits are taxiway stubs and stubble fields.
- Swept for swallowed errors (`try?`, empty `catch`) in SFUI and SFQuickFlight.

| Finding | Severity | Fix |
|---|---|---|
| `BindingsStore.save` ignored write errors while the UI said "Bound X." or "User bindings cleared", implying the change was kept | HIGH | `save` throws; the status adds "Not saved (…): applies until the app quits." |
| Airport lookup reported "not in the bundled OurAirports data" when the database itself failed to load | MEDIUM | A separate message for an unreadable database |
| Quick Flight discarded per-frame render errors (blank view, no explanation) | MEDIUM | Status becomes "Rendering stopped: …" |
| Cockpit mesh upload failure was silent (the cockpit toggle showed nothing) | LOW | The error is shown in the attribution and notice list |

Reviewed and kept, because the fallback is stated or harmless:
- OSM fetch failure: procedural fallback buildings, with no ODbL attribution added.
- Showcase pack missing: streams from the network, with the download prompt for non-showcase airports.
- METAR failure: fair-weather clouds, and no weather line is added.
- DEM baseline unavailable: Terrarium tiles only.
- Detail imagery streaming failure: the previous layer stays.
- Tile cache creation failure: network only.

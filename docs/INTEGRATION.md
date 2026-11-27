# Integration status

Integration lead's living list of what is live in the app, what is merged but unwired, and where systems overlap. Update it when a PR merges. Based on reading `main` and the open PR diffs on 2026-11-23. Items marked "verify" were not checked in code yet.

## Overlaps to resolve

| Area | Overlap | Owner threads | Action |
|---|---|---|---|
| Career rank | `AirlineCareer.rank` (#137) adds a second rank and reputation next to `Progression` and `CareerState` | airline (#137), career | Decide one progression model before merging #137 |
| SAR | Campaign `search-and-rescue` (#139) points at `sar-*` missions added in #136 | SAR missions (#136), SAR career (#139) | Merge #136 before #139; check the mission ids match |
| Missions | Generated mission library (#163) and hand-written missions (#135, #136) | mission library (#163), gate and roll (#135) | Verify no duplicate ids in `MissionCatalog` |
| Tutorial and flight school | Tutorial (#143) hands off to flight school (#133); #143 says the school is not in this build | tutorial (#143), flight school (#133) | Wire the hand-off once #133 is on main |
| Input | Gamepad (#145), HID (#144), touch (#149), keyboard (#150), and matrix tests (#148) | input threads | Confirm one mapper path (`InputMapper`) |

## Live on main (wired)

- Quick Flight with GameplaySession and MissionRuntime (verify the session path end to end).
- Night lights and night sky pass, reachable from the Quick Flight Time menu (#104, #112).
- Real-airport setup shared by app and frames harness (`applyRealAirport`, #122).
- Lake scoop firefight mission (#113).

## Merged but not wired or not verified

- Renderer modules from round 5 (Ocean, AAShadow, AircraftExterior). Their notes say they were not wired into `WorldRenderer` (PR #21). Verify.
- `SFPerf` QualityGovernor, GPUTelemetry, ResidencyCache, StreamingPlanner: no callers outside their own modules (from the repo overview notes). Verify.
- EOX Sentinel-2 imagery: off by default.

## Open PRs needing a decision before merge

- #137 airline career: adds SOP checklist and airline rank (see overlaps). No UI yet, per its own doc.
- #139 SAR career logbook: rescue counter, depends on #136.
- #140 carrier: no check yet.

## Known gaps

- Apple CI runs are queued behind a macOS backlog. Linux CI is the first signal.
- Renderer ownership: GPU perf thread owns `WorldRenderer` structural edits. Coordinate hooks there.

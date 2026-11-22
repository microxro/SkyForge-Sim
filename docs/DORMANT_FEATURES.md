# Dormant features

A dormant feature is code that merged to main but never runs, because nothing sets the value or calls the function that turns it on. This list is partial. Each row names the file where wiring is missing and the thread that owns it. Owners should confirm or correct their rows.

Status key: CONFIRMED means the gap was read in the source on main. UNVERIFIED means a suspected gap that still needs checking.

| Feature | Where it should be wired | Status | Owner |
|---|---|---|---|
| Round 5 AA: TAA resolve, SMAA-lite and tier cascades (PR #42) | `Packages/SkyforgeKit/Sources/SFRender/WorldRenderer.swift`: `public var aaTier: AAShadowTier?` (default nil, never assigned). The app or the scenery settings must set it. | CONFIRMED | Scenery thread (has the aaTier wiring) |
| Quality ladder (`QualityGovernor`, `QualityLadder`, `QualityPlan`) | `Packages/SkyforgeKit/Sources/SFPerf/QualityGovernor.swift`. No caller in `SFQuickFlight/QuickFlight.swift`. The renderer should apply `QualityPlan` each frame. | UNVERIFIED (no caller found in the files read) | Performance thread |
| Ocean wind and wake sources | `WorldRenderer.swift`: public ocean wind and wake properties. Check that the app or flight session writes them each frame. | UNVERIFIED | Ocean / visuals thread |
| Aircraft wakes into flight model | `QuickFlight.swift`: `setWakes(_:)`. Check that a traffic or mission layer calls it. | UNVERIFIED | Flight model thread |

## Method

1. Read the declaration of each feature.
2. Search the whole package and `App/` for each setter and call site. Code search via `gh api search/code` returned no results for this repo, so the check was done by reading files.
3. Record a row only when no live caller exists.

## Next steps

- Owners confirm or correct their rows in a comment on this PR.
- The audit is not complete. Remaining SFRender, SFPerf and SFGameplay files still need reading.

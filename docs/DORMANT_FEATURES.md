# Dormant features

A dormant feature is code that merged to main but never runs, because nothing sets the value or calls the function that turns it on. This list is partial. Each row names the file where wiring is missing and the thread that owns it.

Status key: CONFIRMED means the gap was read in source on main. WIRED means a live call site was read on main. PENDING means a live call site exists on an open PR branch. REPORTED means the owning thread says it is fixed, and it has not been re-checked here. UNVERIFIED means a suspected gap that still needs checking.

| Feature | Where it should be wired | Status | Owner |
|---|---|---|---|
| Round 5 AA: TAA resolve, SMAA-lite and tier cascades (PR #42) | `Packages/SkyforgeKit/Sources/SFRender/WorldRenderer.swift`: `public var aaTier: AAShadowTier?` (default nil, never assigned on main). | CONFIRMED on main; REPORTED fixed in PR #62 | Scenery thread |
| Quality ladder (`QualityGovernor`, `QualityLadder`, `QualityPlan`) | `Packages/SkyforgeKit/Sources/SFPerf/QualityGovernor.swift`. No caller on main in `SFQuickFlight/QuickFlight.swift`. | PENDING: `QuickFlightView.swift` creates the governor (line 188) and applies it each frame (line 326) on PR #38's branch, not yet on main | Airport frames thread (PR #38) |
| Ocean wind and wake sources | `WorldRenderer.swift`: public ocean wind and wake properties. Check that the app writes them each frame. | UNVERIFIED | Scenery thread |
| Aircraft wakes into flight model | `QuickFlightSession.setWakes(_:)` in `QuickFlight.swift`. | WIRED: `QuickFlightView.swift` calls `session.setWakes` each step; `GameplaySession` sets `environment.wakes` directly (PR #50, merged) | Flight model thread |

## Method

1. Read the declaration of each feature.
2. Search the whole package and `App/` for each setter and call site. Code search via `gh api search/code` returned no results for this repo, so the check was done by reading files.
3. Record a row only when no live caller exists.

## Next steps

- Owners confirm or correct their rows in a comment on this PR.
- The audit is not complete. Remaining SFRender, SFPerf and SFGameplay files still need reading.

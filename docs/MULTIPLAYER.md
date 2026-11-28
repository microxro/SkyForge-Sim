# Multiplayer (GameKit)

Free Game Center real-time matches. No paid server. Lobby size is the GameKit real-time cap, 16 pilots (`SessionLimits.maxPlayers`).

## What is in the code
- `SFNetcode/GameKitTransport.swift`: `GKMatch` adapter behind `MultiplayerTransport`, auto-match, Game Center sign-in (iOS presents the sheet; macOS signs in through Game Center settings).
- `SFNetcode/MultiplayerSession.swift`: sends our aircraft state (unreliable), validates remote packets, keeps one interpolation buffer per peer. Tested on Linux with `LoopbackNetwork`.
- `SFUI/MultiplayerViews.swift`: lobby screen, reached from the hub's Multiplayer row.

## Manual steps (developer portal, not in code)
- Enable the Game Center capability on the App ID, then add `com.apple.developer.game-center` to `App/SKYFORGE.entitlements`. Not added yet: signing fails until the App ID has the capability.
- Test on two devices signed into different Game Center accounts.

## Not done yet
- Remote aircraft are not drawn in flight. Rendering them belongs to the WorldRenderer owner (GPU perf thread).
- Chat and mission events on the reliable channel.

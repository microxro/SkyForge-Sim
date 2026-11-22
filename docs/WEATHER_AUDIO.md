# Weather effects and audio

Volumetric cumulus already existed (`SFAtmosphere.VolumetricClouds`, `CloudRenderer`). This adds the rest of the weather picture and the first audio system. New files only, apart from one `public init()` in `FlightOutputs` and Package.swift wiring.

## Weather (`SFWeather/WeatherEffects.swift`, `SFRender/WeatherRenderer.swift`)
- `WeatherEffects(metar:)` / `WeatherEffects(state:)` give precipitation kind and intensity, Koschmieder fog extinction, thunderstorm flag, gusting wind, turbulence and deterministic lightning (`lightning(at:)`, `nextLightning(after:)`).
- `WeatherRenderer` is a one-triangle overlay (rain, drizzle, snow, hail streaks in three parallax layers, a wet-air veil, lightning wash). Encode it after the cloud composite, before post:
  `if WeatherRenderer.needsOverlay(fx, lightning: l) { try weather.encode(cmd:colour:effects:time:airspeed:lightning:ambient:) }`
- Fog needs a hook in the world pass (owned by the "Push airport frames past 8.2" thread): see the hookup list in the PR description.

## Audio (`SFAudio`)
All sound is synthesized, so there are no audio assets and no licences to track.
- `AudioModel`: flight state, controls and weather to `AudioParameters` plus one-shot `AudioEvent`s (touchdown scaled by sink rate, flap motor, thunder with speed-of-sound delay).
- `ProceduralSynth`: engine firing harmonics plus blade pass, wind, rain, ground rumble, stall horn, touchdown thump, flap motor, thunder. Allocation-free `render`.
- `ProceduralAudioEngine` (`@MainActor`, AVAudioEngine): `start()`, then `update(time:state:outputs:inputs:weather:)` once per frame.

## Needs a Mac build
See the PR description.

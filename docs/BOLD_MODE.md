# SKYFORGE — Bold Mode directive (user, 2026-11-08)

Overrides the incremental art-tuning loop. Every other MASTER_PROMPT rule still applies.

Goal: the independent art director scores the app's Metal frames at least 8/10 on average, with zero failing tests, CI green and a measured frame-time budget met.

Phases:
- A, real world first:
  - real airports as the default start;
  - any OurAirports airport;
  - 3–5 bundled showcase airports;
  - OSM buildings and roads with ODbL attribution;
  - imagery colour match and de-haze, mips and anisotropic filtering;
  - real DEM with CDLOD and per-pixel detail.
- B, renderer:
  - bloom and glare, TAA or SMAA;
  - contact shadows and SSAO, 3–4 stable cascades;
  - aircraft PBR textures, glint and prop blur, cockpit textures;
  - water with waves, reflections and foam;
  - cloud self-shadowing per tier.
- C, performance:
  - a CI GPU frame-time test per tier;
  - building LOD and instancing, GPU culling, texture streaming with a memory cap;
  - no main-thread stalls;
  - 60/30 fps targets; device numbers marked unverified.
- D, correctness:
  - tests for every feature;
  - gate before every commit, CI green before the next big item;
  - a 30-minute soak test;
  - a stub/dishonest-code audit per phase.

Review: the art director scores CI Metal frames plus CPU previews, with 3–5 fixes batched per round. Two rounds gaining less than 0.2 means switching to a structural change.

Done when:
- the average is at least 8 on Metal frames from at least 3 real airports and 1 SkyWorld scene;
- the frame-time test and the soak test pass;
- all tests are green;
- attribution and the licence audit are complete;
- the PR shows before/after with frame links.

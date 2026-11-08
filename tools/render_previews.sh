#!/usr/bin/env bash
# SKYFORGE — Apache-2.0
# Re-renders the reviewed CPU preview scenes into docs/previews at their canonical times (scene defaults).
set -euo pipefail
cd "$(dirname "$0")/../Packages/SkyforgeKit"
swift build -c release --product sfpreview >/dev/null
out=../../docs/previews
for s in "suburban a_suburban_golden" "forest_river d_forest_river" "coastline e_coastline" \
         "mountain_valley f_mountain_valley" "airport_final j_airport_final"; do
  set -- $s
  .build/release/sfpreview --scene "$1" --out "$out/$2.png" | grep -o "^sfpreview: [a-z_]* [a-z]*\|total [0-9.]*s" | paste -sd' '
done

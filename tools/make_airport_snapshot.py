#!/usr/bin/env python3
"""Build the bundled OurAirports snapshot (public domain) for SFNavData.
Usage: make_airport_snapshot.py <dir with airports.csv runways.csv navaids.csv> <output resources dir>
Keeps the columns NavDatabase reads, drops closed airports, heliports and balloonports, zlib-compresses each
file (level 9) and writes manifest.json with row counts and the source date."""
import csv, io, json, sys, zlib, datetime, os
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
AIRPORT_COLS = ["ident", "type", "name", "latitude_deg", "longitude_deg", "elevation_ft", "iso_country", "municipality", "iata_code"]
RUNWAY_COLS = ["airport_ident", "length_ft", "width_ft", "surface", "lighted", "closed",
               "le_ident", "le_latitude_deg", "le_longitude_deg", "le_elevation_ft", "le_heading_degT", "le_displaced_threshold_ft",
               "he_ident", "he_latitude_deg", "he_longitude_deg", "he_elevation_ft", "he_heading_degT", "he_displaced_threshold_ft"]
NAVAID_COLS = ["ident", "name", "type", "frequency_khz", "latitude_deg", "longitude_deg", "elevation_ft",
               "dme_latitude_deg", "dme_longitude_deg", "associated_airport"]
def read(name): return list(csv.DictReader(open(os.path.join(src, name), encoding="utf-8", newline="")))
airports = [r for r in read("airports.csv") if r["type"] not in ("closed", "heliport", "balloonport")]
keep = {r["ident"] for r in airports}
runways = [r for r in read("runways.csv") if r["airport_ident"] in keep and r["closed"] != "1"]
navaids = read("navaids.csv")
manifest = {"source": "OurAirports (public domain) https://davidmegginson.github.io/ourairports-data/",
            "built": datetime.date.today().isoformat(), "files": {}}
for name, rows, cols in [("airports", airports, AIRPORT_COLS), ("runways", runways, RUNWAY_COLS), ("navaids", navaids, NAVAID_COLS)]:
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(cols)
    for r in rows: w.writerow([r.get(c, "") for c in cols])
    raw = buf.getvalue().encode("utf-8")
    z = zlib.compress(raw, 9)
    open(os.path.join(dst, f"{name}.csv.z"), "wb").write(z)
    manifest["files"][name] = {"rows": len(rows), "rawBytes": len(raw), "compressedBytes": len(z)}
    print(f"{name}: {len(rows)} rows, {len(raw)} -> {len(z)} bytes")
json.dump(manifest, open(os.path.join(dst, "manifest.json"), "w"), indent=2, sort_keys=True)

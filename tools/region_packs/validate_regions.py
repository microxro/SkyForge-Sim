#!/usr/bin/env python3
# SKYFORGE — Apache-2.0
"""Validates tools/region_packs/regions.json: schema, bounding boxes, licensed sources and the size budget.

Stdlib only. Exit 0 when valid, 1 otherwise. Run in CI and before any region fetch:
    python3 tools/region_packs/validate_regions.py
"""
import json, pathlib, sys

HERE = pathlib.Path(__file__).resolve().parent
ALLOWED_PROVIDERS = {
    "imagery": {"usgs-orthoimagery", "sentinel2-eox-cloudless", "linz-aerial"},
    "elevation": {"aws-terrarium-dem"},
    "buildings": {"openstreetmap"},  # user decision: OSM-only building data
    "landmarks": {"original-models"},
}
REQUIRED_LAYERS = set(ALLOWED_PROVIDERS)
REQUIRED_REGION_KEYS = {"id", "name", "kind", "bbox", "sources", "target_gb", "landmarks", "wave"}
TARGET_GB = 5.0  # famous regions, first wave, inside the 15 GB game total (PR #157)
WAVES = {"first", "later"}
TOLERANCE_GB = 0.05


def check(data):
    errors = []
    if data.get("schema") != "skyforge.region-packs/1":
        errors.append("unknown schema")
    regions = data.get("regions", [])
    if not regions:
        errors.append("no regions")
    seen = set()
    for r in regions:
        rid = r.get("id", "<no id>")
        missing = REQUIRED_REGION_KEYS - set(r)
        if missing:
            errors.append(f"{rid}: missing keys {sorted(missing)}")
            continue
        if rid in seen:
            errors.append(f"{rid}: duplicate id")
        seen.add(rid)
        if not all(c.islower() or c.isdigit() or c == "-" for c in rid):
            errors.append(f"{rid}: id must be lowercase kebab-case")
        b = r["bbox"]
        if not (-90 <= b["min_lat"] < b["max_lat"] <= 90 and -180 <= b["min_lon"] < b["max_lon"] <= 180):
            errors.append(f"{rid}: bbox out of range or inverted")
        if (b["max_lat"] - b["min_lat"]) > 1.5 or (b["max_lon"] - b["min_lon"]) > 1.5:
            errors.append(f"{rid}: bbox larger than one region (1.5 x 1.5 degrees)")
        layers = r["sources"]
        if set(layers) != REQUIRED_LAYERS:
            errors.append(f"{rid}: sources must be exactly {sorted(REQUIRED_LAYERS)}")
        for layer, allowed in ALLOWED_PROVIDERS.items():
            prov = layers.get(layer, {}).get("provider")
            if prov not in allowed:
                errors.append(f"{rid}: {layer} provider {prov!r} not in {sorted(allowed)}")
        if r["wave"] not in WAVES:
            errors.append(f"{rid}: wave must be one of {sorted(WAVES)}")
        if not r["landmarks"]:
            errors.append(f"{rid}: no landmarks listed")
        if not isinstance(r["target_gb"], (int, float)) or r["target_gb"] <= 0:
            errors.append(f"{rid}: target_gb must be positive")
    total = sum(r.get("target_gb", 0) for r in regions if r.get("wave") == "first")
    if abs(total - TARGET_GB) > TOLERANCE_GB:
        errors.append(f"budget: first-wave regions total {total:.2f} GB, target {TARGET_GB} GB")
    later = sum(r.get("target_gb", 0) for r in regions if r.get("wave") == "later")
    return errors, total, later


def main():
    data = json.loads((HERE / "regions.json").read_text())
    errors, total, later = check(data)
    for e in errors:
        print("region packs:", e)
    print(f"region packs: first wave {total:.2f} GB, optional later packs {later:.2f} GB")
    print("region packs:", "FAIL" if errors else "OK")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())

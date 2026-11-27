"""Halden Reach: generates world.json (the data contract) and map.svg (the printed map).
All coordinates are kilometres: x east, y north, origin at the south-west corner of the 140 x 100 km map frame."""
import json, sys, pathlib

OUT = pathlib.Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)
W, H = 140, 100

world = {
    "name": "Halden Reach",
    "worldgenVersion": 1,
    "frameKm": [W, H],
    "originNote": "x east, y north, km; origin = south-west corner of the frame",
    "island": [[18,88],[45,96],[70,92],[92,97],[118,90],[132,72],[128,55],[136,40],[124,22],[108,8],
               [84,4],[60,10],[40,4],[20,14],[8,34],[12,58],[4,72]],
    "seaLevelM": 0,
    "peaks": [
        {"name": "Mount Ardent", "x": 58, "y": 62, "m": 2870},
        {"name": "Sable Peak", "x": 76, "y": 70, "m": 2650},
        {"name": "Cold Tor", "x": 44, "y": 46, "m": 2410},
        {"name": "Harrow Crest", "x": 30, "y": 32, "m": 2100},
        {"name": "Greywether", "x": 98, "y": 78, "m": 1640},
    ],
    "ridges": [[[26,28],[44,46],[58,62],[76,70],[98,78]]],
    "rivers": [
        {"name": "Tessel River", "widthM": 180, "points": [[62,88],[66,70],[72,50],[90,40],[104,30],[110,16],[112,4]]},
        {"name": "Orra River", "widthM": 90, "points": [[10,58],[26,54],[40,50],[56,40],[66,28],[76,14],[84,4]]},
    ],
    "lakes": [{"name": "Lake Ysolde", "x": 58, "y": 40, "rx": 6, "ry": 4}],
    "regions": [
        {"name": "Ashwold Steppe", "biome": "dry_grassland", "x": 18, "y": 16, "w": 34, "h": 26},
        {"name": "Serrin Coast", "biome": "coastal_farmland", "x": 104, "y": 26, "w": 30, "h": 30},
        {"name": "Caldera Plain", "biome": "temperate_farmland", "x": 80, "y": 34, "w": 30, "h": 24},
        {"name": "Ardent Highlands", "biome": "alpine_conifer", "x": 44, "y": 50, "w": 40, "h": 30},
        {"name": "Northern Woods", "biome": "mixed_forest", "x": 40, "y": 78, "w": 60, "h": 20},
        {"name": "Brightwater Downs", "biome": "wet_heath", "x": 8, "y": 56, "w": 26, "h": 28},
    ],
    "cities": [
        {"name": "Caldera", "x": 96, "y": 46, "pop": 320000, "tier": "hub"},
        {"name": "Port Serrin", "x": 118, "y": 36, "pop": 110000, "tier": "city"},
        {"name": "Northgate", "x": 70, "y": 84, "pop": 60000, "tier": "city"},
        {"name": "Brightwater", "x": 34, "y": 66, "pop": 45000, "tier": "city"},
        {"name": "Ashwold", "x": 28, "y": 24, "pop": 12000, "tier": "town"},
        {"name": "Millbrook", "x": 84, "y": 30, "pop": 8000, "tier": "town"},
        {"name": "Tessel Falls", "x": 100, "y": 20, "pop": 6000, "tier": "town"},
        {"name": "Greyhaven", "x": 54, "y": 72, "pop": 4000, "tier": "town"},
        {"name": "Kestrel Cross", "x": 116, "y": 62, "pop": 3000, "tier": "town"},
        {"name": "Saltmarsh", "x": 22, "y": 42, "pop": 2000, "tier": "village"},
    ],
    "airports": [
        {"id": "HRCI", "name": "Caldera International", "x": 92, "y": 42, "elevM": 40, "runwayM": 3600, "surface": "asphalt", "class": "hub"},
        {"id": "HRPS", "name": "Port Serrin Regional", "x": 116, "y": 40, "elevM": 15, "runwayM": 1800, "surface": "asphalt", "class": "regional"},
        {"id": "HRNG", "name": "Northgate Field", "x": 72, "y": 80, "elevM": 210, "runwayM": 1400, "surface": "asphalt", "class": "regional"},
        {"id": "HRBW", "name": "Brightwater Strip", "x": 30, "y": 62, "elevM": 60, "runwayM": 900, "surface": "asphalt", "class": "ga"},
        {"id": "HRAH", "name": "Ashwold Hangar Strip", "x": 26, "y": 20, "elevM": 480, "runwayM": 700, "surface": "dirt", "class": "bush"},
        {"id": "HRKT", "name": "Kestrel Tor", "x": 50, "y": 56, "elevM": 1120, "runwayM": 620, "surface": "gravel", "class": "bush"},
        {"id": "HRAR", "name": "Ardent Rest", "x": 64, "y": 54, "elevM": 1900, "runwayM": 800, "surface": "gravel", "class": "mountain"},
        {"id": "HRTS", "name": "Tessel Strip", "x": 108, "y": 16, "elevM": 35, "runwayM": 500, "surface": "grass", "class": "bush"},
        {"id": "HRYS", "name": "Lake Ysolde Water Base", "x": 58, "y": 36, "elevM": 180, "runwayM": 1200, "surface": "water", "class": "seaplane"},
        {"id": "HRKX", "name": "Kestrel Cross Field", "x": 114, "y": 66, "elevM": 90, "runwayM": 1000, "surface": "grass", "class": "ga"},
    ],
    "roads": [
        {"name": "Coast Highway", "class": "highway", "points": [[30,84],[60,88],[92,86],[118,70],[126,52],[118,40]]},
        {"name": "Caldera Expressway", "class": "highway", "points": [[60,30],[80,40],[96,46],[112,40],[118,36]]},
        {"name": "Ridge Road", "class": "arterial", "points": [[34,58],[44,50],[58,44],[72,40],[84,30]]},
    ],
}

(OUT / "world.json").write_text(json.dumps(world, indent=2) + "\n")

# ---- SVG rendering ----
S = 8  # px per km
def P(x, y):
    return x * S, (H - y) * S
def poly(pts):
    return " ".join(f"{P(x,y)[0]:.1f},{P(x,y)[1]:.1f}" for x, y in pts)

BIOME = {"dry_grassland": "#d9c98a", "coastal_farmland": "#b9cf8f", "temperate_farmland": "#a7c47a",
         "alpine_conifer": "#8fa58a", "mixed_forest": "#7fae7a", "wet_heath": "#a9b98f"}
TIER_R = {"hub": 9, "city": 6, "town": 4, "village": 3}
parts = []
parts.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-40 -60 {W*S+80} {H*S+120}" font-family="Georgia, serif">')
parts.append(f'<defs><filter id="ridge"><feGaussianBlur stdDeviation="3"/></filter></defs>')
parts.append(f'<rect x="-40" y="-60" width="{W*S+80}" height="{H*S+120}" fill="#9fc4d6"/>')
# grid
for k in range(0, W + 1, 20):
    x, _ = P(k, 0); parts.append(f'<line x1="{x}" y1="0" x2="{x}" y2="{H*S}" stroke="#ffffff55" stroke-width="1"/>')
for k in range(0, H + 1, 20):
    _, y = P(0, k); parts.append(f'<line x1="0" y1="{y}" x2="{W*S}" y2="{y}" stroke="#ffffff55" stroke-width="1"/>')
# island land fill then biome regions clipped to island
parts.append(f'<clipPath id="land"><polygon points="{poly(world["island"])}"/></clipPath>')
parts.append(f'<polygon points="{poly(world["island"])}" fill="#e8dfc4"/>')
parts.append('<g clip-path="url(#land)">')
for r in world["regions"]:
    x, y = P(r["x"], r["y"] + r["h"])
    parts.append(f'<rect x="{x}" y="{y}" width="{r["w"]*S}" height="{r["h"]*S}" fill="{BIOME[r["biome"]]}" opacity="0.75"/>')
parts.append(f'<polyline points="{poly(world["ridges"][0])}" fill="none" stroke="#7d6e5c" stroke-width="{S*9}" stroke-linecap="round" opacity="0.25" filter="url(#ridge)"/>')
parts.append('</g>')
parts.append(f'<polygon points="{poly(world["island"])}" fill="none" stroke="#5b4a33" stroke-width="2.5"/>')
# rivers and lakes
for rv in world["rivers"]:
    parts.append(f'<polyline points="{poly(rv["points"])}" fill="none" stroke="#4f8fb8" stroke-width="{max(2, rv["widthM"]/60):.1f}" stroke-linecap="round" stroke-linejoin="round"/>')
for lk in world["lakes"]:
    cx, cy = P(lk["x"], lk["y"])
    parts.append(f'<ellipse cx="{cx}" cy="{cy}" rx="{lk["rx"]*S}" ry="{lk["ry"]*S}" fill="#4f8fb8" stroke="#2f6a92"/>')
# peaks
for pk in world["peaks"]:
    cx, cy = P(pk["x"], pk["y"])
    parts.append(f'<path d="M{cx-9},{cy+6} L{cx},{cy-10} L{cx+9},{cy+6} Z" fill="#8a7b6a" stroke="#4b4236"/>')
    parts.append(f'<text x="{cx+11}" y="{cy+2}" font-size="9" fill="#3b3226">{pk["name"]} {pk["m"]} m</text>')
# roads
for rd in world["roads"]:
    w = {"highway": 3.5, "arterial": 2.5}.get(rd["class"], 1.5)
    parts.append(f'<polyline points="{poly(rd["points"])}" fill="none" stroke="#b5654a" stroke-width="{w}" stroke-dasharray="{"" if rd["class"]=="highway" else "5 3"}"/>')
# cities
for c in world["cities"]:
    cx, cy = P(c["x"], c["y"])
    parts.append(f'<circle cx="{cx}" cy="{cy}" r="{TIER_R[c["tier"]]}" fill="#2b2b2b" stroke="#fff" stroke-width="1.5"/>')
    fs = 12 if c["tier"] == "hub" else 10
    parts.append(f'<text x="{cx+TIER_R[c["tier"]]+3}" y="{cy+4}" font-size="{fs}" font-weight="{"bold" if c["tier"]=="hub" else "normal"}" fill="#1d1d1d">{c["name"]}</text>')
# airports
AIR_COL = {"hub": "#c0392b", "regional": "#8e44ad", "ga": "#2c6fbb", "bush": "#b9770e", "mountain": "#922b21", "seaplane": "#117a65"}
for a in world["airports"]:
    cx, cy = P(a["x"], a["y"])
    col = AIR_COL[a["class"]]
    parts.append(f'<rect x="{cx-4}" y="{cy-4}" width="8" height="8" fill="{col}" stroke="#fff"/>')
    parts.append(f'<text x="{cx+7}" y="{cy+10}" font-size="8.5" fill="{col}">{a["id"]} {a["name"]}</text>')
# frame, scale, north arrow, legend
parts.append(f'<rect x="0" y="0" width="{W*S}" height="{H*S}" fill="none" stroke="#333" stroke-width="1.5"/>')
parts.append(f'<text x="0" y="-22" font-size="26" font-weight="bold" fill="#1d1d1d">Halden Reach</text>')
parts.append(f'<text x="0" y="-4" font-size="11" fill="#333">Original SkyWorld region, 140 x 100 km. Airports marked by class, not to scale for runway length.</text>')
bx, by = W*S - 170, H*S + 22
parts.append(f'<rect x="{bx}" y="{by}" width="{S*20}" height="5" fill="#222"/><rect x="{bx+S*20}" y="{by}" width="{S*20}" height="5" fill="#fff" stroke="#222"/>')
parts.append(f'<text x="{bx}" y="{by+18}" font-size="10" fill="#222">0 — 20 — 40 km</text>')
parts.append(f'<text x="{W*S-30}" y="{-30}" font-size="14" fill="#222" text-anchor="middle">N ▲</text>')
ly = H*S + 22
legend = [("Hub airport", AIR_COL["hub"]), ("Regional", AIR_COL["regional"]), ("General aviation", AIR_COL["ga"]),
          ("Bush strip", AIR_COL["bush"]), ("Mountain strip", AIR_COL["mountain"]), ("Seaplane base", AIR_COL["seaplane"])]
for i, (t, c) in enumerate(legend):
    x = i * 150
    parts.append(f'<rect x="{x}" y="{ly}" width="10" height="10" fill="{c}"/><text x="{x+14}" y="{ly+10}" font-size="10" fill="#222">{t}</text>')
parts.append('</svg>')
(OUT / "map.svg").write_text("\n".join(parts) + "\n")
print("wrote", OUT)

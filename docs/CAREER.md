# Career: aircraft ownership and maintenance

Module: `Packages/SkyforgeKit/Sources/SFCareer` (pure Swift, no UI, Linux-testable).
Credits are in-game only. Nothing is bought with real money.

## What exists

- **Wallet**: whole-credit balance with an append-only ledger. Overdrafts are rejected.
- **Catalogue**: `AircraftModel.sf1Trainer` (180,000 cr new). Used aircraft start with wear and cost less.
- **Storage**: tie-down (25 cr/day, airframe and avionics weather wear) or hangar (T-hangar 120 cr/day, large 300 cr/day, no weather wear). Moving storage costs five days of the new rent.
- **Components**: engine, propeller, brakes, tires, airframe, avionics. Each has wear (0 to 1), hours since service, and a defect flag.
- **Wear**: per flight hour, per landing, and per hard landing (airframe). Tie-down adds daily airframe and avionics wear.
- **Service**: inspection (resets interval), repair (clears defect, -0.25 wear), overhaul (resets wear, interval and defect). Costs come from the new price.
- **Failures**: above 0.8 wear, each flight hour has a chance of failure, capped at 5%. A failure sets a defect and adds wear.
- **Dispatch**: grounded if a defect is open, wear is at least 1, or an interval is overdue by 20%. Warning if an interval is due or wear is at least 0.8.
- **Resale**: new price times an hours factor (floor 15%) times a wear factor, minus 10% while a defect is open.
- **Maintenance log**: per aircraft, one entry per service, failure and storage change.

## Not yet built

- The flight session does not call `Fleet.recordFlight` yet. The hook is in place.
- No earnings from jobs, no fuel costs, no upgrades, no save/load.
- The repo has no in-flight failure system to tie into, so these rules are self-contained. Wire them to a flight-model failure system when one exists.
- Unpaid tie-down rent is forgiven. A debt system is a later decision.

## Balance numbers

All numbers are game balance and easy to tune. They live in `Maintenance.swift`, `Aircraft.swift` and `Fleet.swift`.

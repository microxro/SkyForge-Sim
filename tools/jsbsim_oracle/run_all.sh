#!/usr/bin/env bash
# Run the whole offline oracle comparison: JSBSim c172p, SF-1 mirror, sensitivity checks, comparison report.
set -euo pipefail
cd "$(dirname "$0")"
python3 -c "import jsbsim, numpy" 2>/dev/null || { echo "need: pip install jsbsim numpy" >&2; exit 2; }
python3 run_jsbsim.py --selfcheck >/dev/null
python3 run_jsbsim.py -o jsbsim_results.json
python3 run_sf1.py -o sf1_results.json
python3 whatif.py -o whatif_results.json
python3 compare.py "$@"

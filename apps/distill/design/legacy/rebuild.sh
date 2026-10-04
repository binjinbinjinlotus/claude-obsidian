#!/bin/bash
# Regenerate every board, wire buttons, keep the live canvas layout (heights only).
set -e
S=$(cd "$(dirname "$0")" && pwd); P=$S/distill-design/project
cp $P/canvas.json $S/canvas.keep.json
cd $S
python3 gen_components.py --measure | tail -1
python3 gen_controls.py --measure | tail -1
python3 gen_actions.py --measure | tail -1
for g in gen_md gen_compose gen_images; do python3 $g.py >/dev/null; done
(cd $P && python3 $S/gen_sizing.py >/dev/null)
python3 gen_audit.py --measure | tail -1
python3 wire_buttons.py
python3 wire_controls.py
cp $S/canvas.keep.json $P/canvas.json
python3 $S/place_row0.py
python3 $S/fit_heights.py

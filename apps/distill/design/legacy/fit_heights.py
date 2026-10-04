"""Re-measure every board and update only its canvas height (positions stay as the user left them)."""
import json, os, re, subprocess
S = os.path.dirname(os.path.abspath(__file__)); P = os.path.join(S, 'distill-design', 'project')
c = json.load(open(os.path.join(P, 'canvas.json')))
changed = []
for k, b in c['boards'].items():
    out = subprocess.run([os.path.join(S, 'snapbin'), os.path.join(P, k), str(b['w']), os.path.join(S, 'fit.png'), '0.1'], capture_output=True, text=True).stdout
    m = re.search(r'MEASURE (-?\d+) (\d+)', out)
    if not m:
        continue
    pv = json.loads(re.search(r"data-props='([^']*)'", open(os.path.join(P, k)).read()).group(1).replace('&#39;', "'")).get('$preview', {})
    if int(m.group(1)) <= 0:
        continue  # components: the frame size is the user's (canvas editor), not ours
    h = int(m.group(1))
    if abs(h - b['h']) > 2:
        changed.append((k, b['h'], h)); b['h'] = h
json.dump(c, open(os.path.join(P, 'canvas.json'), 'w'), indent=2, ensure_ascii=False)
print('heights changed:', changed)

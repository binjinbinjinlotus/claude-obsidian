"""Add any row-0 component or states board missing from canvas.json at the right end of row 0 (y 240). Nothing else moves."""
import json, os, re
import gen_components as C, gen_controls as G
P = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'distill-design', 'project')
p = os.path.join(P, 'canvas.json'); c = json.load(open(p)); b = c['boards']; order = c['order']
x = max(v['x'] + v['w'] for v in b.values() if v['y'] == 240) + 80
last = max(order.index(k) for k, v in b.items() if v['y'] == 240 and k in order)
added = []
for t in G.CONTROLS:
    for f, w, h, title in [(f'{t[0]}.dc.html', t[5], t[6], f'{t[0]} (component)'),
                           (f'{t[0]}States.dc.html', G.WIDE.get(t[0], (960, 3))[0], C.SIZES.get(f'{t[0]}States.dc.html', 300), f'{t[0]} · states')]:
        if f not in b:
            b[f] = {'x': x, 'y': 240, 'w': w, 'h': h, 'title': title}; x += w + 80; added.append(f)
for f in reversed(added):
    order.insert(last + 1, f)
json.dump(c, open(p, 'w'), indent=2, ensure_ascii=False)
print('added', len(added))

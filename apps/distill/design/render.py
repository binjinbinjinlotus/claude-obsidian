#!/usr/bin/env python3
"""Render the Distill design schema to design-canvas boards (.dc.html). Standard library only.

    python3 apps/distill/design/render.py OUT_DIR [--only Board ...] [--canvas LIVE/canvas.json] [--measure]

Writes, into OUT_DIR:
  - one component board per entry in components.json   (<Name>.dc.html)
  - one states board per component (or shared board)   (<Name>States.dc.html, ButtonsStates.dc.html)
  - one screen board per board in screens/*.json        (ActionsTodo.dc.html, ...)
  - support.js (the offscreen runtime shim, for local renders only; never published)

--only Board      render only these boards (file name with or without .dc.html; repeatable)
--canvas FILE     merge FILE (a copy of the live canvas.json) into OUT_DIR/canvas.json: x/y/w and
                  component frame sizes stay as the user left them, states and screen boards take the
                  heights from sizes.json, missing boards are appended at the end of their row. Boards
                  whose output differs from the .dc.html next to FILE are printed as "changed".
--measure         render each generated states/screen board offscreen (WKWebView, no window) and store
                  its measured height in sizes.json, then render again at that height. macOS only.

Publishing is the lead's job: this script never talks to claude.ai.
"""
import copy
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
FONTS = ('<link rel="preconnect" href="https://fonts.googleapis.com">\n'
         '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,800&amp;family=DM+Sans:wght@400;500;600;700&amp;display=swap">')
BASE_CSS = 'body{margin:0;font-family:"DM Sans",-apple-system,sans-serif;color:#1D1C1A;-webkit-font-smoothing:antialiased}'
COMPONENT_ROW_Y = 240  # row "0 · Components" on the canvas


def load(name):
    with open(os.path.join(ROOT, name), encoding='utf-8') as f:
        return json.load(f)


def schema():
    comps = load('components.json')['components']
    screens = []
    sdir = os.path.join(ROOT, 'screens')
    for f in sorted(os.listdir(sdir)) if os.path.isdir(sdir) else []:
        if f.endswith('.json'):
            s = load(os.path.join('screens', f))
            s['_file'] = f
            screens.append(s)
    return comps, screens


SIZES_FILE = os.path.join(ROOT, 'sizes.json')


def sizes():
    return load('sizes.json') if os.path.exists(SIZES_FILE) else {}


# ---------------------------------------------------------------- primitives
def attr(v):
    return 'true' if v is True else 'false' if v is False else str(v)


def kebab(k):
    return re.sub(r'([A-Z])', lambda m: '-' + m.group(1).lower(), k)


def auto_width(name, props):
    """hint-size must be a CSS length matching the child's root: an estimate for width "auto"."""
    g = lambda k: '' if props.get(k) is None else attr(props[k])
    if name == 'MarkdownStyleBar':
        w = 470 if g('variant') != 'compact' else 290
        w += 90 if g('image') == 'true' else 0
        return int(w * (0.86 if g('size') == 'small' else 1))
    if name in ('PrimaryButton', 'SoftButton'):
        return 8 * len(g('title')) + (64 if g('systemImage') else 44)
    if name == 'Pill':
        return 7 * len(g('text')) + 22
    return 200


def dc_import(name, props, size):
    """<dc-import> of a sibling component; camelCase props become kebab attributes; None is left out."""
    a = ' '.join(f'{kebab(k)}="{attr(v)}"' for k, v in props.items() if v is not None)
    w, h = size
    if w == 'auto':
        w = f'{auto_width(name, props)}px'
    return f'<dc-import name="{name}" {a} hint-size="{w},{h}"></dc-import>'


def template_parts(name):
    with open(os.path.join(ROOT, 'components', f'{name}.dc.html'), encoding='utf-8') as f:
        src = f.read()
    m = re.search(r'<x-dc>\n(.*)\n</x-dc>\n<script type="text/x-dc-logic">\n(.*)\n</script>', src, re.S)
    if not m:
        raise SystemExit(f'components/{name}.dc.html: expected <x-dc>…</x-dc> then <script type="text/x-dc-logic">…</script>')
    return m.group(1), m.group(2)


_DATA = {}


def data_tokens():
    if not _DATA:
        _DATA['@@ICONS@@'] = json.dumps(load('data/icons.json'))
        _DATA['@@SETTINGS_NAV@@'] = json.dumps(load('data/settings_nav.json'))
    return _DATA


def editor_props(c):
    out = {}
    for p in c['props']:
        e = {'editor': p['type'], 'default': p.get('default')}
        for k in ('options', 'section'):
            if k in p:
                e[k] = p[k]
        out[p['name']] = e
    w, h = c['preview']
    out['$preview'] = {'width': w, 'height': h}
    return out


def page(title, body, props_json, script, css=''):
    return f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
{FONTS}
<style>{BASE_CSS}{css}</style>
</helmet>
{body}
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{props_json}'>
{script}
</script>
</body>
</html>'''


# ---------------------------------------------------------------- component boards
def component_board(c):
    markup, logic = template_parts(c['name'])
    for k, v in data_tokens().items():
        logic = logic.replace(k, v)
    props_json = json.dumps(editor_props(c), ensure_ascii=False).replace("'", '&#39;')
    script = ('class Component extends DCLogic {\nrenderVals() {\nconst p = this.props || {};\n'
              "const on = (v, d) => v === undefined || v === null || v === '' ? d : (v === true || v === 'true');\n"
              f'{logic}\n}}\n}}')
    return page(c['title'], markup, props_json, script)


def state_cell(label, inner, cap):
    c = f'<span style="font-size: 11px; color: #6B6862; line-height: 1.45; max-width: 260px">{cap}</span>' if cap else ''
    return f'<div style="display: flex; flex-direction: column; gap: 8px; align-items: flex-start"><span style="font-size: 12px; font-weight: 700">{label}</span>{inner}{c}</div>'


def state_inner(name, st, wrap):
    if 'layers' in st:
        imps = [dc_import(name, l['props'], l['size']) for l in st['layers']]
        args = [l['props'] for l in st['layers']]
        kw = {f'import{i}': s for i, s in enumerate(imps)}
    else:
        imps = [dc_import(name, st['props'], st['size'])]
        args = [st['props']]
        kw = {'import': imps[0]}
    wrap = st.get('wrap', wrap)
    if not wrap:
        return imps[0]
    return wrap.format(*args, **kw, **st.get('vars', {}))


def states_boards(comps, H):
    """{file: (html, width)} for every states board; shared boards collect their components' states in order."""
    boards = {}
    for c in comps:
        b = c.get('board')
        if not b or 'heading' not in b:
            continue
        names = b.get('components', [c['name']])
        cells = []
        for n in names:
            cc = next(x for x in comps if x['name'] == n)
            wrap = cc['board'].get('wrap') if cc.get('board') else None
            for st in cc.get('states', []):
                cells.append(state_cell(st['name'], state_inner(n, st, wrap), st.get('caption', '')))
        f, W, cols = b['file'], b['width'], b.get('cols')
        gap = b.get('gap', '28px 24px')
        hgt = H.get(f, 300)
        grid = (f'<div style="display: grid; grid-template-columns: repeat({cols}, minmax(0, 1fr)); gap: {gap}">' if cols
                else f'<div style="display: flex; flex-wrap: wrap; gap: {gap}">') + ''.join(cells) + '</div>'
        body = (f'<div style="width: {W}px; height: {hgt}px; box-sizing: border-box; background: #F6F5F2; overflow: hidden">\n'
                f'<div data-measure style="padding: 30px 36px 36px; display: flex; flex-direction: column; gap: 20px">\n'
                f'<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-family: \'Bricolage Grotesque\', sans-serif; font-weight: 800; font-size: 24px; letter-spacing: -0.02em">{b["heading"]}</span>\n'
                f'<span style="font-size: 13px; color: #6B6862; line-height: 1.5; max-width: 1100px">{b["intro"]}</span></div>\n'
                f'{grid}\n</div>\n</div>')
        props_json = '{"$preview":{"width":%d,"height":%d}}' % (W, hgt)
        html = page(b['title'], body, props_json, 'class Component extends DCLogic { renderVals() { return {}; } }')
        boards[f] = (html, W, b.get('canvasTitle', f'{b["heading"]} · states'))
    return boards


# ---------------------------------------------------------------- screens: base + override = state
def prop_orders(comps):
    """{component name: [prop names in declared order]}: what screens need to know about components."""
    return {c['name']: [p['name'] for p in c['props']] for c in comps}


def is_instance(comp_names, v):
    return isinstance(v, dict) and len(v) == 1 and next(iter(v)) in comp_names and isinstance(next(iter(v.values())), dict)


def normalize(comp_names, v):
    """{"FilterPanel": {...}} is shorthand for {"c": "FilterPanel", "props": {...}}."""
    if is_instance(comp_names, v):
        (n, p), = v.items()
        return {'c': n, 'props': dict(p)}
    if isinstance(v, list):
        return [normalize(comp_names, x) for x in v]
    if isinstance(v, dict):
        return {k: normalize(comp_names, x) for k, x in v.items()}
    return v


NODE_KEYS = {'c', 'props', 'size', 'at', 't', 'vars', 'html'}  # a node's own keys; any other key on an instance is a prop


def apply_override(base, override, comp_names):
    """A state is the base screen plus `override`: {"dotted.path": value}. A path walks regions, then a
    component instance's props ("toolbar.chips" sets the toolbar instance's chips prop). null removes."""
    s = copy.deepcopy(base)
    for path, value in override.items():
        value = normalize(comp_names, value)
        keys = path.split('.')
        node = s['regions'] if keys[0] in s.get('regions', {}) or keys[0] not in s else s
        order = None
        for k in keys[:-1]:
            if isinstance(node, dict) and 'c' in node and k not in NODE_KEYS:
                order = comp_names.get(node['c']) if isinstance(comp_names, dict) else None
                node = node.setdefault('props', {})
            node = node.setdefault(k, {})
        last = keys[-1]
        if isinstance(node, dict) and 'c' in node and last not in NODE_KEYS:
            order = comp_names.get(node['c']) if isinstance(comp_names, dict) else None
            node = node.setdefault('props', {})
        if value is None:
            node.pop(last, None)
        elif last in node or not order or last not in order:
            node[last] = value
        else:  # a new prop goes where the component declares it, so attribute order stays stable
            items = list(node.items())
            at = next((i for i, (k, _) in enumerate(items) if k in order and order.index(k) > order.index(last)), len(items))
            items.insert(at, (last, value))
            node.clear()
            node.update(items)
    return s


def render_node(node, screen):
    """A region value: component instance, template use, raw html, or a list of those."""
    if node is None:
        return ''
    if isinstance(node, str):
        return node
    if isinstance(node, list):
        return ''.join(render_node(n, screen) for n in node)
    if 'c' in node:
        props = {k: ('|'.join(v) if isinstance(v, list) else v) for k, v in node.get('props', {}).items()}
        out = dc_import(node['c'], props, node.get('size', ['auto', 'auto']))
    elif 't' in node:
        tpl = screen['templates'][node['t']]
        vars_ = {k: render_node(v, screen) if isinstance(v, (dict, list)) else attr(v) for k, v in node.get('vars', {}).items()}
        out = tpl.format(**vars_)
    elif 'html' in node:
        out = node['html']
    else:
        raise SystemExit(f'unknown node {node}')
    if 'at' in node:
        pos = '; '.join(f'{k}: {v}px' if isinstance(v, (int, float)) else f'{k}: {v}' for k, v in node['at'].items())
        out = f'<div style="position: absolute; {pos}">{out}</div>'
    return out


def render_list(node, screen):
    """An ActionRow list from screen["lists"]. Group heads count the rows of their group that are not
    gone (or show a fixed "count"); selected / hover / gone are row indexes, heads not counted."""
    items = screen['lists'][node['list']]
    sel, hov, gone = node.get('selected'), node.get('hover'), node.get('gone')
    idx, i = [], 0
    for it in items:
        idx.append(i)
        if 'head' not in it:
            i += 1
    out = []
    for j, it in enumerate(items):
        if 'head' in it:
            text = it['head']
            if it.get('style') == 'plain':
                out.append(f'<div style="padding: 8px 10px 2px; font-size: 10px; font-weight: 800; letter-spacing: .06em; color: #9B978F">{text}</div>')
                continue
            if 'fixedCount' in it:
                n = it['fixedCount']
            else:
                n = 0
                for k in items[j + 1:]:
                    if 'head' in k:
                        break
                    n += 1
                n -= 1 if gone is not None and idx[j] <= gone < idx[j] + n else 0
            c = it.get('color', '#9B978F')
            out.append(f'<div style="display: flex; align-items: center; gap: 6px; padding: 10px 12px 4px; font-size: 10px; font-weight: 800; letter-spacing: .06em; color: {c}">'
                       f'<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="{c}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="flex-shrink: 0; color: {c}"><path d="M6 9l6 6 6-6"/></svg>'
                       f'{text}<span style="font-weight: 700; color: #9B978F">{n}</span></div>')
            continue
        r = idx[j]
        props = {k: v for k, v in it.items() if k != 'mode'}
        props.update(selected=True if r == sel else None, hover=True if r == hov else None, mode=it.get('mode'), faded=True if r == gone else None)
        out.append(dc_import('ActionRow', props, ['100%', '56px']))
    return ''.join(out)


_FRAGS = {}


def fragment(screen, name):
    """Named markup in screens/<screen>/<name>.html: bespoke parts that are not components yet."""
    key = (screen['_file'], name)
    if key not in _FRAGS:
        with open(os.path.join(ROOT, 'screens', screen['_file'][:-5], name + '.html'), encoding='utf-8') as f:
            _FRAGS[key] = f.read()
    return _FRAGS[key]


def render_region(node, screen):
    if isinstance(node, dict) and 'frag' in node:
        return fragment(screen, node['frag'])
    if isinstance(node, dict) and 'list' in node:
        return render_list(node, screen)
    return render_node(node, screen)


def render_window(s, screen):
    """WindowShell frame, Sidebar, <main> laid out by the state's layout, overlay, traffic lights."""
    regions = {k: render_region(v, screen) for k, v in s.get('regions', {}).items()}
    layout = screen['layouts'][s['layout']]
    fields = {k: regions.get(k, '') for k in re.findall(r'(?<!\{)\{(\w+)\}', layout)}
    main = layout.format(**fields)
    w, h = s['window']['width'], s['window']['height']
    sh = s['sidebar'].get('height', h - 40)
    side = f'<div style="width: 220px; height: {sh}px; flex-shrink: 0">{dc_import("Sidebar", s["sidebar"], ["220px", f"{sh}px"])}</div>'
    content = side + f'<main style="flex-grow: 1; display: flex; flex-direction: column; min-width: 0; position: relative; background: #FFFFFF">{main}</main>'
    return (f'<div style="position: relative; width: {w}px; height: {h}px; flex-shrink: 0; isolation: isolate">'
            f'<div style="position: absolute; inset: 0; z-index: -1">{dc_import("WindowShell", {"layer": "frame", "width": w, "height": h}, [f"{w}px", f"{h}px"])}</div>'
            f'<div style="position: absolute; left: 20px; top: 20px; right: 20px; bottom: 20px; display: flex; border-radius: 16px; overflow: hidden">{content}{regions.get("overlay", "")}</div>'
            f'<div style="position: absolute; left: 38px; top: 36px">{dc_import("WindowShell", {"layer": "controls"}, ["52px", "12px"])}</div></div>')


def screen_states(screen, comp_names):
    """{state id: resolved state}. Frame states are their base plus the override; card states stand alone."""
    bases = {k: normalize(comp_names, v) for k, v in screen.get('bases', {}).items()}
    out = {}
    for st in screen['states']:
        if 'base' in st:
            out[st['id']] = dict(apply_override(bases[st['base']], st.get('set', {}), comp_names), _state=st)
        else:
            out[st['id']] = dict(normalize(comp_names, st), _state=st)
    return out


HEAD = "font-family: 'Bricolage Grotesque', sans-serif"
BOARD_CSS = (' code{font-size:11px;background:#F6F5F2;padding:1px 4px;border-radius:4px}'
             ' mark{background:#E9FBC9;color:inherit;border-radius:3px;padding:0 1px;box-shadow:0 0 0 1px #B9F06A}')


def framed(label, inner):
    return f'<div style="display: flex; flex-direction: column; gap: 10px"><span style="font-size: 14px; font-weight: 700">{label}</span>{inner}</div>'


def card(n, st, body):
    c = st['card']
    return (f'<section style="display: flex; flex-direction: column; gap: 10px; min-width: 0">'
            f'<div style="display: flex; align-items: center; gap: 8px"><span style="width: 22px; height: 22px; border-radius: 11px; background: #1F6FEB; color: #FFFFFF; font-size: 11px; font-weight: 700; display: flex; align-items: center; justify-content: center; flex-shrink: 0">{n}</span><span style="font-size: 14px; font-weight: 700">{st["label"]}</span></div>'
            f'<div style="position: relative; height: {c.get("height", 430)}px; border-radius: 18px; background: {c.get("bg", "#E4E1DB")}; overflow: hidden; padding: {c.get("pad", "22px")}; box-sizing: border-box; display: flex; flex-direction: column; align-items: {c.get("align", "center")}; justify-content: flex-start">{body}</div>'
            f'<span style="font-size: 12px; color: #6B6862; line-height: 1.5">{st.get("caption", "")}</span></section>')


def screen_boards(screens, comps, H):
    names = prop_orders(comps)
    boards = {}
    for screen in screens:
        resolved = screen_states(screen, names)

        def frame(sid):
            return framed(resolved[sid]['_state']['label'], render_window(resolved[sid], screen))

        for b in screen.get('boards', []):
            if b.get('pending') and '--include-pending' not in sys.argv:
                continue
            parts = []
            for sec in b['sections']:
                if 'row' in sec:
                    parts.append(f'<div style="{sec.get("style", "display: flex; gap: 40px")}">' + ''.join(frame(i) for i in sec['row']) + '</div>')
                elif 'frame' in sec:
                    parts.append(frame(sec['frame']))
                elif 'title' in sec:
                    sub = f'<span style="font-size: 13px; color: #6B6862; line-height: 1.5; max-width: 1300px">{sec["sub"]}</span>' if sec.get('sub') else ''
                    parts.append(f'<div style="display: flex; flex-direction: column; gap: 4px; margin-top: 10px"><span style="{HEAD}; font-weight: 800; font-size: 20px; letter-spacing: -0.01em">{sec["title"]}</span>{sub}</div>')
                elif 'grid' in sec:
                    cards = []
                    for n, sid in enumerate(sec['grid'], 1):
                        st = resolved[sid]
                        cards.append(card(st['_state'].get('number', n), st['_state'], render_region(st['body'], screen)))
                    parts.append(f'<div style="display: grid; grid-template-columns: repeat({sec.get("cols", 4)}, minmax(0, 1fr)); gap: {sec.get("gap", "30px 24px")}">' + ''.join(cards) + '</div>')
            W, f = b['width'], b['file']
            hgt = H.get(f, 2000)
            body = (f'<div style="width: {W}px; height: {hgt}px; box-sizing: border-box; background: #F6F5F2; overflow: hidden">\n'
                    f'<div data-measure style="padding: 34px 40px 40px; display: flex; flex-direction: column; gap: 22px">\n'
                    f'<div style="display: flex; flex-direction: column; gap: 8px">\n<span style="{HEAD}; font-weight: 800; font-size: 28px; letter-spacing: -0.02em">{b["heading"]}</span>\n'
                    f'<span style="font-size: 13px; color: #6B6862; max-width: 1400px; line-height: 1.55">{b["intro"]}</span>\n</div>\n'
                    + ''.join(parts) + '\n</div>\n</div>')
            props_json = '{"$preview":{"width":%d,"height":%d}}' % (W, hgt)
            boards[f] = (page(f'Distill — {b["title"]}', body, props_json, 'class Component extends DCLogic { renderVals() { return {}; } }', BOARD_CSS), W, b['title'])
    return boards


# ---------------------------------------------------------------- everything
def build_all(H=None):
    """{file: (html, width, canvas title, row y or None, kind)}; kind is component | states | screen."""
    comps, screens = schema()
    H = sizes() if H is None else H
    out = {}
    for c in comps:
        out[f'{c["name"]}.dc.html'] = (component_board(c), c['preview'][0], f'{c["name"]} (component)', COMPONENT_ROW_Y, 'component')
    for f, (html, W, title) in states_boards(comps, H).items():
        out[f] = (html, W, title, COMPONENT_ROW_Y, 'states')
    for f, (html, W, title) in screen_boards(screens, comps, H).items():
        row = next((s.get('row') for s in screens if any(b['file'] == f for b in s.get('boards', []))), None)
        out[f] = (html, W, title, row, 'screen')
    return out


def snap_binary():
    """Compile tools/snap.swift once into .build/snap (gitignored). None when swiftc is missing."""
    src = os.path.join(ROOT, 'tools', 'snap.swift')
    exe = os.path.join(ROOT, '.build', 'snap')
    if os.path.exists(exe) and os.path.getmtime(exe) >= os.path.getmtime(src):
        return exe
    if not shutil.which('swiftc'):
        return None
    os.makedirs(os.path.dirname(exe), exist_ok=True)
    r = subprocess.run(['swiftc', '-O', src, '-o', exe], capture_output=True, text=True)
    return exe if r.returncode == 0 else None


def measure(out_dir, files, widths):
    exe = snap_binary()
    if not exe:
        print('measure: swiftc not found; heights unchanged', file=sys.stderr)
        return {}
    got = {}
    for f in files:
        png = os.path.join(out_dir, '.shots', f.replace('.dc.html', '.png'))
        os.makedirs(os.path.dirname(png), exist_ok=True)
        r = subprocess.run([exe, os.path.join(out_dir, f), str(widths[f]), png, '0.5'], capture_output=True, text=True, timeout=120)
        m = re.search(r'MEASURE (\d+)', r.stdout)
        if m:
            got[f] = int(m.group(1))
    return got


def preview_height(html):
    m = re.search(r"data-props='([^']*)'", html)
    return json.loads(m.group(1).replace('&#39;', "'")).get('$preview', {}).get('height') if m else None


def same_board(a, b):
    """Equal boards: identical markup, and data-props equal as JSON (key order inside a prop is free)."""
    rx = r"data-props='([^']*)'"
    pa, pb = re.search(rx, a), re.search(rx, b)
    if not pa or not pb:
        return a == b
    ja, jb = (json.loads(p.group(1).replace('&#39;', "'")) for p in (pa, pb))
    return ja == jb and a.replace(pa.group(0), '') == b.replace(pb.group(0), '')


def merge_canvas(live_path, out_dir, built, written):
    """Live canvas.json + this render → OUT_DIR/canvas.json. Prints the boards that changed."""
    live_dir = os.path.dirname(os.path.abspath(live_path))
    with open(live_path, encoding='utf-8') as f:
        c = json.load(f)
    boards, order = c['boards'], c['order']
    changed, added, resized = [], [], []
    for f in written:
        html, W, title, row, kind = built[f]
        old = os.path.join(live_dir, f)
        if not os.path.exists(old):
            changed.append(f)
        else:
            with open(old, encoding='utf-8') as fh:
                if not same_board(fh.read(), html):
                    changed.append(f)
        h = preview_height(html)
        if f in boards:
            if kind != 'component' and h and abs(h - boards[f]['h']) > 2:  # a component frame keeps the user's editor size
                resized.append((f, boards[f]['h'], h))
                boards[f]['h'] = h
            continue
        if row is None:
            print(f'warning: {f} has no canvas row; not placed', file=sys.stderr)
            continue
        in_row = [k for k, v in boards.items() if v['y'] == row]
        x = max((boards[k]['x'] + boards[k]['w'] for k in in_row), default=-80) + 80
        boards[f] = {'x': x, 'y': row, 'w': W, 'h': h or 400, 'title': title}
        last = max((order.index(k) for k in in_row if k in order), default=len(order) - 1)
        order.insert(last + 1, f)
        added.append(f)
    with open(os.path.join(out_dir, 'canvas.json'), 'w', encoding='utf-8') as fh:
        json.dump(c, fh, indent=2, ensure_ascii=False)
    for f in changed:
        print('changed', f)
    for f in added:
        print('added  ', f, '(end of row y=%d)' % boards[f]['y'])
    for f, a, b in resized:
        print('height ', f, a, '->', b)
    return changed, added, resized


def main(argv):
    args = list(argv)
    if not args or args[0].startswith('-'):
        print(__doc__)
        return 2
    out_dir = args.pop(0)
    only, canvas, do_measure = [], None, False
    while args:
        a = args.pop(0)
        if a == '--only':
            only.append(args.pop(0))
        elif a == '--canvas':
            canvas = args.pop(0)
        elif a == '--measure':
            do_measure = True
        elif a == '--include-pending':
            pass
        else:
            print(f'unknown argument {a}', file=sys.stderr)
            return 2
    only = {o if o.endswith('.dc.html') else o + '.dc.html' for o in only}
    os.makedirs(out_dir, exist_ok=True)
    built = build_all()
    unknown = only - set(built)
    if unknown:
        print('unknown boards: ' + ', '.join(sorted(unknown)), file=sys.stderr)
        return 2
    files = [f for f in built if not only or f in only]

    def write():
        # Boards import components at render time, so the component files always go along (they are
        # tiny). Only `files` are reported and merged.
        for f in [f for f in built if built[f][4] == 'component' and f not in files] + files:
            with open(os.path.join(out_dir, f), 'w', encoding='utf-8') as fh:
                fh.write(built[f][0])
        shutil.copy(os.path.join(ROOT, 'support.js'), os.path.join(out_dir, 'support.js'))

    write()
    if do_measure:
        targets = [f for f in files if built[f][4] != 'component']
        got = measure(out_dir, targets, {f: built[f][1] for f in targets})
        H = sizes()
        moved = {f: (H.get(f), h) for f, h in got.items() if H.get(f) != h}
        H.update(got)
        with open(SIZES_FILE, 'w', encoding='utf-8') as fh:
            json.dump(dict(sorted(H.items())), fh, indent=2)
            fh.write('\n')
        for f, (a, b) in moved.items():
            print('measured', f, a, '->', b)
        built = build_all(H)
        write()
    if canvas:
        merge_canvas(canvas, out_dir, built, files)
    print(f'wrote {len(files)} boards to {out_dir}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

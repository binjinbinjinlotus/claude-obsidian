#!/usr/bin/env python3
"""Drift check between the design schema and the Swift app (the one-to-one mapping).

    python3 apps/distill/design/test_design.py

Fails when:
  - tokens.json, ds/tokens.json or ds/tokens.css disagrees with Theme.swift (values, not only names);
  - a component in components.json has no `struct <Name>` (or typealias) in its `swift` file;
  - a prop is neither a parameter / stored property of that struct (under its own name or its
    `swift` name) nor marked `"swift": false` with a `why` (design-only: the view derives it) or
    `"swiftPending"` (designed, not built yet; fails once Swift has it, so the mark gets dropped);
  - a template, a state's prop or a board reference doesn't match components.json;
  - the schema doesn't render.
Reports (never fails): components with no Swift view yet, swiftPending props, and screen states with no snapshot
state of the same id in clients/macos/Sources/Distill/Snapshot*.swift.
"""
import glob
import json
import os
import re
import sys
import unittest

ROOT = os.path.dirname(os.path.abspath(__file__))
APP = os.path.normpath(os.path.join(ROOT, '..'))
SWIFT_DIR = os.path.join(APP, 'clients', 'macos', 'Sources', 'Distill')
sys.path.insert(0, ROOT)
sys.dont_write_bytecode = True
import render  # noqa: E402
import tokens  # noqa: E402

COMPONENTS = render.load('components.json')['components']


# ---------------------------------------------------------------- Swift parsing
def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def strip_comments(src):
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    return re.sub(r'//[^\n]*', '', src)


def braced(src, start):
    """Text inside the brace pair that opens at or after `start`."""
    i = src.index('{', start)
    depth = 0
    for j in range(i, len(src)):
        depth += {'{': 1, '}': -1}.get(src[j], 0)
        if depth == 0:
            return src[i + 1:j]
    raise ValueError('unbalanced braces')


def top_level(body):
    """Only the text at brace depth 0 of a body: member declarations, not code inside them."""
    out, depth = [], 0
    for ch in body:
        if ch == '}':
            depth -= 1
        if depth == 0:
            out.append(ch)
        if ch == '{':
            depth += 1
    return ''.join(out)


def find_struct(name, path, seen=()):
    """(file, struct body) for `name` declared in `path`, following `typealias Name = Target`."""
    src = strip_comments(read(path))
    m = re.search(rf'^\s*(?:(?:private|fileprivate|public|internal)\s+)?struct\s+{name}\b[^{{]*', src, re.M)
    if m:
        return path, braced(src, m.end())
    a = re.search(rf'^\s*(?:(?:private|fileprivate|public|internal)\s+)?typealias\s+{name}\b(?:<[^>]*>)?\s*=\s*(\w+)', src, re.M)
    if a and a.group(1) not in seen:
        target = a.group(1)
        for p in [path] + sorted(glob.glob(os.path.join(SWIFT_DIR, '*.swift'))):
            if re.search(rf'struct\s+{target}\b', read(p)):
                return find_struct(target, p, seen + (name,))
    return None, None


def members(body):
    """Stored properties (let/var, any wrapper or access level) and init parameter labels."""
    top = top_level(body)
    names = set(re.findall(r'(?:^|[\s;])(?:let|var)\s+(\w+)', top))
    for m in re.finditer(r'\binit\s*\(', top):
        depth, j = 0, m.end() - 1
        for j in range(m.end() - 1, len(top)):
            depth += {'(': 1, ')': -1}.get(top[j], 0)
            if depth == 0:
                break
        params = top[m.end():j]
        names |= set(re.findall(r'(?:^|,)\s*(?:_\s+)?(\w+)(?:\s+\w+)?\s*:', params))
    return names


# ---------------------------------------------------------------- checks
def component_problems(c):
    """[problem strings] for one component; [] when it maps one to one."""
    if not c.get('swift'):
        return []
    path = os.path.join(APP, c['swift'])
    if not os.path.exists(path):
        return [f'{c["name"]}: swift file {c["swift"]} does not exist']
    file, body = find_struct(c['name'], path)
    if body is None:
        return [f'{c["name"]}: no `struct {c["name"]}` or typealias in {c["swift"]}']
    have = members(body)
    out = []
    for p in c['props']:
        if p.get('swift') is False:
            if not p.get('why'):
                out.append(f'{c["name"]}.{p["name"]}: "swift": false needs a "why"')
            continue
        if p.get('swiftPending'):
            want = p.get('swift', p['name'])
            if want in have:
                out.append(f'{c["name"]}.{p["name"]}: Swift has `{want}` now; drop "swiftPending"')
            continue
        want = p.get('swift', p['name'])
        if want not in have:
            out.append(f'{c["name"]}.{p["name"]}: no parameter or stored property `{want}` in struct {c["name"]} '
                       f'({os.path.relpath(file, APP)}); set "swift" to the Swift name, or "swift": false with a "why"')
    return out


def snapshot_ids():
    ids = set()
    for p in glob.glob(os.path.join(SWIFT_DIR, 'Snapshot*.swift')):
        ids |= set(re.findall(r'"([a-z0-9]+(?:-[a-z0-9]+)+)"', read(p)))
    return ids


TOKEN_HEX = {v.upper(): k for k, v in tokens.theme()['color'].items()}


def hex_colors(text):
    """Every #rgb / #rrggbb colour literal in text, upper-case and 6-digit."""
    out = []
    for h in re.findall(r'#[0-9A-Fa-f]{6}\b|#[0-9A-Fa-f]{3}\b(?![0-9A-Fa-f])', text):
        h = h.upper()
        out.append('#' + ''.join(c * 2 for c in h[1:]) if len(h) == 4 else h)
    return out


TOKENIZED_SCREENS = ['queue', 'review', 'reviewqueue', 'session', 'fullread', 'actions', 'actionsummary', 'actioncontext', 'routing', 'scriptactions', 'collectors', 'livelog', 'activity', 'panes']


def token_checked_files():
    """The templates already moved to tokens (design-system-plan.md, step 3)."""
    files = glob.glob(os.path.join(ROOT, 'components', '*.html')) + [os.path.join(ROOT, 'render.py')]
    for name in TOKENIZED_SCREENS:
        files += [os.path.join(ROOT, 'screens', name + '.json')] + glob.glob(os.path.join(ROOT, 'screens', name, '*.html'))
    return sorted(files)


class Tokens(unittest.TestCase):
    def test_tokens_match_theme(self):
        # tokens.json, and the Design System's ds/tokens.json and ds/tokens.css, all regenerate from Theme.swift.
        for path, text in tokens.outputs().items():
            with open(path, encoding='utf-8') as f:
                self.assertEqual(f.read(), text, f'{os.path.relpath(path, ROOT)} disagrees with Theme.swift: run python3 apps/distill/design/tokens.py')

    def test_design_system_values(self):
        # The values the Design System shows are Theme.swift's, not just its names.
        t = tokens.theme()
        with open(tokens.DS_JSON, encoding='utf-8') as f:
            d = json.load(f)
        colors = {x['name']: x['value'] for x in d['color']['tokens']}
        for name, hexv in t['color'].items():
            self.assertEqual(colors.get(name), hexv, f'colour {name}')
        flat = {x['name']: x['value'] for fam in ('spacing', 'radius', 'size') for x in d[fam]['tokens']}
        styles = {s['name']: s['fontSize'] for g in d['type']['groups'] for s in g['styles']}
        b, p = t['button']['sizes'], t['pill']
        for name, v in [('button-height', b['regular']['height']), ('button-height-small', b['small']['height']),
                        ('button-height-mini', b['mini']['height']), ('button-pad', b['regular']['paddingPrimary']),
                        ('pill-height', p['regular']['height']), ('pill-height-small', p['small']['height']),
                        ('pill-pad', p['regular']['paddingX']), ('pill-pad-small', p['small']['paddingX']),
                        ('radius-card', t['radius']['card']), ('icon-button', t['iconButton']['size'])]:
            self.assertEqual(flat[name], f'{v}px', name)
        self.assertEqual(styles['pill-small'], f'{p["small"]["fontSize"]}px')
        self.assertEqual(styles['button'], f'{b["regular"]["fontSize"]}px')

    def test_templates_use_tokens(self):
        # A colour that is a token is written var(--name), so a Theme.swift change reaches every board.
        # Colours that match no token are reported (report()), not failed: they are still to name.
        for path in token_checked_files():
            with open(path, encoding='utf-8') as f:
                found = [h for h in hex_colors(f.read()) if h in TOKEN_HEX]
            self.assertEqual(found, [], f'{os.path.relpath(path, ROOT)}: write these as var(--{{token}})')

    def test_svg_colours_are_styles(self):
        # var() in an SVG fill or stroke attribute is not CSS: WebKit draws it, Chrome does not. A token
        # colour or a {{hole}} that can carry one goes in style="fill: …" instead.
        rx = re.compile(r'<(?:svg|path|circle|rect|line|polyline|polygon|ellipse|g)\b[^>]*\s(?:fill|stroke)=\\?"[^"\\]*(?:var\(|\{\{)')
        for path in token_checked_files():
            with open(path, encoding='utf-8') as f:
                self.assertEqual(rx.findall(f.read()), [], f'{os.path.relpath(path, ROOT)}: SVG colour attribute holds var() or a hole')

    def test_bundle_css_uses_tokens(self):
        with open(os.path.join(ROOT, 'ds', 'components', 'bundle.css'), encoding='utf-8') as f:
            css = f.read()
        self.assertEqual(re.findall(r'#[0-9A-Fa-f]{3,8}\b', css), [], 'bundle.css: a colour literal instead of a token')


class Components(unittest.TestCase):
    def test_unique_names(self):
        names = [c['name'] for c in COMPONENTS]
        self.assertEqual(len(names), len(set(names)), 'duplicate component names')

    def test_swift_views_and_props(self):
        problems = [p for c in COMPONENTS for p in component_problems(c)]
        self.assertEqual(problems, [], '\n' + '\n'.join(problems))

    def test_templates_match_entries(self):
        files = {os.path.basename(f)[:-len('.dc.html')] for f in glob.glob(os.path.join(ROOT, 'components', '*.dc.html'))}
        names = {c['name'] for c in COMPONENTS}
        self.assertEqual(sorted(files - names), [], 'templates with no components.json entry')
        self.assertEqual(sorted(names - files), [], 'components.json entries with no template')

    def test_states_use_declared_props(self):
        bad = []
        for c in COMPONENTS:
            declared = {p['name'] for p in c['props']}
            for st in c.get('states', []):
                for layer in st.get('layers', [st]):
                    bad += [f'{c["name"]} / {st["name"]}: {k}' for k in layer.get('props', {}) if k not in declared]
        self.assertEqual(bad, [], 'state props not declared in the component')

    def test_boards_resolve(self):
        heads = {c['board']['file'] for c in COMPONENTS if c.get('board') and 'heading' in c['board']}
        for c in COMPONENTS:
            b = c.get('board')
            if b:
                self.assertIn(b['file'], heads, f'{c["name"]}: board {b["file"]} has no heading entry')
            if c.get('states'):
                self.assertTrue(b, f'{c["name"]} has states but no board')

    def test_renders(self):
        built = render.build_all()
        for c in COMPONENTS:
            self.assertIn(f'{c["name"]}.dc.html', built)
        for f, (html, *_rest) in built.items():
            self.assertNotIn('@@', html, f'{f}: unreplaced data token')


class Screens(unittest.TestCase):
    def test_overrides_resolve(self):
        comps, screens = render.schema()
        names = render.prop_orders(comps)
        for s in screens:
            ids = [st['id'] for st in s['states']]
            self.assertEqual(len(ids), len(set(ids)), f'{s["_file"]}: duplicate state ids')
            for st in s['states']:
                if 'base' in st:
                    self.assertIn(st['base'], s['bases'], f'{s["_file"]}: state {st["id"]} uses unknown base {st["base"]}')
                    self.assertIn(st.get('set', {}).get('layout', s['bases'][st['base']]['layout']), s['layouts'])
                else:
                    self.assertIn('card', st, f'{s["_file"]}: state {st["id"]} has neither a base nor a card')
            render.screen_states(s, names)
            for b in s['boards']:
                if 'page' in b:  # a page board is one state
                    self.assertIn(b['page'], ids, f'{b["file"]}: unknown state {b["page"]}')
                    continue
                for sec in b['sections']:
                    for sid in sec.get('row', []) + sec.get('grid', []) + ([sec['frame']] if 'frame' in sec else []):
                        self.assertIn(sid, ids, f'{b["file"]}: unknown state {sid}')

    def test_fragments_exist_and_are_used(self):
        _, screens = render.schema()
        for s in screens:
            used = set(re.findall(r'"frag": "([^"]+)"', json.dumps(s)))
            d = os.path.join(ROOT, 'screens', s['_file'][:-5])
            have = {f[:-5] for f in os.listdir(d) if f.endswith('.html')} if os.path.isdir(d) else set()
            self.assertEqual(sorted(used - have), [], f'{s["_file"]}: fragments referenced but missing')
            self.assertEqual(sorted(have - used), [], f'{s["_file"]}: fragment files nothing uses')

    def test_override_is_not_a_copy(self):
        base = {'regions': {'toolbar': {'c': 'ActionsToolbar', 'props': {'placeholder': 'Search to-dos'}}, 'overlay': None}}
        st = render.apply_override(base, {'toolbar.chips': ['Due: Today'], 'overlay': {'FilterPanel': {'due': 'Today'}}}, {'ActionsToolbar', 'FilterPanel'})
        self.assertEqual(st['regions']['toolbar']['props'], {'placeholder': 'Search to-dos', 'chips': ['Due: Today']})
        self.assertEqual(st['regions']['overlay'], {'c': 'FilterPanel', 'props': {'due': 'Today'}})
        self.assertNotIn('chips', base['regions']['toolbar']['props'], 'the base must not change')


class Canvas(unittest.TestCase):
    # One page with all the boards never drew in the canvas viewer; area pages of 3 to 17 did
    # (docs/specs/design-system-plan.md, 2026-10-06). So every board has a page, and pages stay small.
    P = render.pages()

    def test_every_board_has_one_page(self):
        listed = [f for p in self.P['pages'] for r in p['rows'] for f in r['boards']]
        self.assertEqual(sorted(f for f in set(listed) if listed.count(f) > 1), [], 'boards on two rows')
        self.assertEqual(sorted(set(render.build_all()) - set(listed)), [], 'boards pages.json places nowhere')

    def test_pages_stay_small(self):
        for p in self.P['pages']:
            self.assertRegex(p['id'], r'^[A-Za-z0-9_-]{1,40}$')
            n = sum(len(r['boards']) for r in p['rows'])
            self.assertLessEqual(n, self.P['maxBoards'], f'page {p["id"]} holds {n} boards')
        self.assertLessEqual(len(self.P['pages']), 40)

    def merge(self, live):
        import contextlib
        import io
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, 'live.json')
            with open(path, 'w', encoding='utf-8') as f:
                json.dump(live, f)
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                render.merge_canvas(path, d, {}, [])
            with open(os.path.join(d, 'canvas.json'), encoding='utf-8') as f:
                return json.load(f)

    def test_merge_puts_every_board_on_its_page(self):
        first = self.P['pages'][0]
        f = first['rows'][0]['boards'][0]
        c = self.merge({'v': 3, 'pages': [], 'launch': {'view': 'canvas'}, 'order': [f], 'notes': {},
                        'boards': {f: {'x': 0, 'y': 70000, 'w': 100, 'h': 100, 'title': 'A'}}})
        self.assertEqual([p['id'] for p in c['pages']], [p['id'] for p in self.P['pages']])
        self.assertEqual(c['launch'], {'view': 'canvas', 'page': first['id']})
        self.assertEqual(c['boards'][f]['page'], first['id'])
        self.assertEqual(c['boards'][f]['y'], render.TITLE_ROOM, 'a board moved to its page goes to its row')
        note = first['rows'][0]['note']['id']
        self.assertEqual(c['notes'][note]['page'], first['id'])

    def test_merge_refuses_a_board_without_a_page(self):
        with self.assertRaises(SystemExit):
            self.merge({'v': 3, 'order': ['Stray.dc.html'], 'notes': {},
                        'boards': {'Stray.dc.html': {'x': 0, 'y': 0, 'w': 100, 'h': 100}}})


def report():
    pending = [c['name'] for c in COMPONENTS if not c.get('swift')]
    design_only = sum(1 for c in COMPONENTS for p in c['props'] if p.get('swift') is False)
    print(f'components: {len(COMPONENTS)}; no Swift view yet: {", ".join(pending) or "none"}; design-only props: {design_only}')
    for c in COMPONENTS:
        for p in c['props']:
            if p.get('swiftPending'):
                print(f'  designed, not in Swift yet: {c["name"]}.{p["name"]} ({p["swiftPending"]})')
    loose = {}
    for path in token_checked_files():
        with open(path, encoding='utf-8') as f:
            for h in hex_colors(f.read()):
                if h not in TOKEN_HEX:
                    loose[h] = loose.get(h, 0) + 1
    print(f'colours that match no token (still to name): {len(loose)}: '
          + ', '.join(f'{h} ×{n}' for h, n in sorted(loose.items(), key=lambda kv: -kv[1])))
    _, screens = render.schema()
    ids = snapshot_ids()
    missing = [st['id'] for s in screens for st in s['states'] if st['id'] not in ids]
    total = sum(len(s['states']) for s in screens)
    print(f'screen states: {total}; without a snapshot state of the same id (report only): {len(missing)}')
    for i in missing:
        print('  -', i)


if __name__ == '__main__':
    report()
    unittest.main(verbosity=1)

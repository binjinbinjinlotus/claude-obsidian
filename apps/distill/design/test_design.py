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
  - the schema doesn't render;
  - a golden board (testdata/golden/) renders differently. After an intended change to render.py's board
    chrome or to those boards, regenerate them and review the diff:
        UPDATE_GOLDEN=1 python3 apps/distill/design/test_design.py
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


# var() in an SVG fill or stroke attribute is not CSS: WebKit draws it, Chrome does not (test_svg_colours_are_styles).
SVG_COLOUR_ATTR = re.compile(r'<(?:svg|path|circle|rect|line|polyline|polygon|ellipse|g)\b[^>]*\s(?:fill|stroke)=\\?"[^"\\]*(?:var\(|\{\{)')


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
        for path in token_checked_files():
            with open(path, encoding='utf-8') as f:
                self.assertEqual(SVG_COLOUR_ATTR.findall(f.read()), [], f'{os.path.relpath(path, ROOT)}: SVG colour attribute holds var() or a hole')

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


class TokenTools(unittest.TestCase):
    """The checks above only see today's files; these feed the helpers, the generators and the
    entry points known inputs so a broken one fails here instead of passing quietly."""

    def test_hex_colors(self):
        self.assertEqual(hex_colors('a #abc b #A1b2C3; #FFF) #1d1c1a'), ['#AABBCC', '#A1B2C3', '#FFFFFF', '#1D1C1A'])
        self.assertEqual(hex_colors('#abcd #abcdef12 #ab #abcg x#ggg'), [], 'not 3 or 6 digits')

    def test_svg_colour_attr(self):
        for bad in ['<svg width="10" fill="var(--ink)">', '<path d="M0" stroke="{{color}}"/>', '<g fill=\\"var(--x)\\">',
                    '<circle r="2" stroke="#fff" fill="var(--lime)"/>', '<rect\nfill="var(--x)"/>']:
            self.assertTrue(SVG_COLOUR_ATTR.search(bad), bad)
        for ok in ['<svg fill="none" stroke="#1D1C1A">', '<path style="fill: var(--ink)"/>', '<div fill="var(--x)">',
                   '<svg data-fill="var(--x)">', '<path fill="currentColor" d="var(">']:
            self.assertFalse(SVG_COLOUR_ATTR.search(ok), ok)

    def test_px_and_css(self):
        self.assertEqual(tokens.px(4), '4px')
        d = {'name': 'T',
             'color': {'tokens': [{'name': 'ink', 'value': '#000000'}, {'name': 'chip', 'value': '{ink}'}]},
             'spacing': {'tokens': [{'name': 'gap', 'value': '4px'}]}, 'radius': {'tokens': [{'name': 'r', 'value': '8px'}]},
             'size': {'tokens': [{'name': 's', 'value': '20px'}]},
             'type': {'families': {'body': 'Sans'}, 'groups': [{'styles': [{'name': 'pill', 'fontSize': '11px', 'fontWeight': 700}]}]}}
        self.assertEqual(tokens.ds_css(d),
                         '/* T — generated from tokens.json by apps/distill/design/tokens.py (Theme.swift); never edit by hand */\n'
                         ':root, [data-theme="light"] {--ink: #000000; --chip: var(--ink);}\n'
                         ':root {--gap: 4px; --r: 8px; --s: 20px; --font-body: Sans; --pill-size: 11px; --pill-weight: 700;}\n')

    def test_ds_tokens_vault_chips_and_usage(self):
        t = tokens.theme()
        d = tokens.ds_tokens(t)
        colors = {x['name']: x for x in d['color']['tokens']}
        fill, ink = t['vaultChips'][0]
        self.assertEqual(colors['vaultChip1'], {'name': 'vaultChip1', 'value': '{%s}' % fill, 'usage': 'Vault 1 chip fill (Theme.vaultChips[0]).'})
        self.assertEqual(colors['vaultChip1Ink'], {'name': 'vaultChip1Ink', 'value': '{%s}' % ink, 'usage': 'Text on vaultChip1.'})
        self.assertEqual(len([n for n in colors if n.startswith('vaultChip')]), 2 * len(t['vaultChips']))
        self.assertEqual(colors['ink']['usage'], 'Primary text.')
        self.assertEqual(colors['ink']['value'], t['color']['ink'])
        self.assertEqual(tokens.render(), tokens.outputs()[tokens.OUT], 'render() is tokens.json')

    def test_tokens_main_checks_and_writes(self):
        import contextlib
        import io
        import tempfile
        saved = tokens.OUT, tokens.DS_JSON, tokens.DS_CSS
        with tempfile.TemporaryDirectory() as d:
            tokens.OUT, tokens.DS_JSON, tokens.DS_CSS = (os.path.join(d, 'tokens.json'), os.path.join(d, 'ds', 'tokens.json'),
                                                         os.path.join(d, 'ds', 'tokens.css'))
            try:
                err, out = io.StringIO(), io.StringIO()
                with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
                    self.assertEqual(tokens.main(['--check']), 1, 'missing files are out of date')
                    self.assertEqual(tokens.main([]), 0)
                    self.assertEqual(tokens.main(['--check']), 0)
                for p in (tokens.OUT, tokens.DS_JSON, tokens.DS_CSS):
                    self.assertIn(os.path.relpath(p), err.getvalue().split('\n')[0])
                    self.assertIn(f'wrote {os.path.relpath(p)}', out.getvalue())
                self.assertIn('run python3 apps/distill/design/tokens.py', err.getvalue())
                expect = tokens.outputs()
                for p in expect:
                    self.assertEqual(read(p), expect[p])
                with open(tokens.DS_CSS, 'a', encoding='utf-8') as f:
                    f.write('/* edited */')
                with contextlib.redirect_stderr(io.StringIO()) as err2:
                    self.assertEqual(tokens.main(['--check']), 1)
                self.assertIn('tokens.css', err2.getvalue())
                self.assertNotIn('tokens.json', err2.getvalue(), 'only the stale file is named')
            finally:
                tokens.OUT, tokens.DS_JSON, tokens.DS_CSS = saved

    def test_every_board_links_the_tokens(self):
        # Boards and the components they import read colours as var(--name): every board loads tokens.css
        # once, in its head, and every var() it uses is a token there.
        defined = set(re.findall(r'--([A-Za-z0-9-]+):', read(tokens.DS_CSS)))
        self.assertIn('color:var(--ink)', render.BASE_CSS)
        for f, (html, *_rest) in render.build_all().items():
            head = html.split('</head>')[0]
            self.assertEqual(html.count(render.TOKENS_LINK), 1, f)
            self.assertIn(render.TOKENS_LINK, head, f)
            self.assertTrue(head.index('support.js') < head.index(render.TOKENS_LINK), f)
            used = set(re.findall(r'var\(--([A-Za-z0-9-]+)\)', html))
            self.assertEqual(sorted(used - defined), [], f'{f}: var() names no token')

    def test_tokens_link_path(self):
        # The canvas installs the Design System's variables at ds/distill/tokens.css; boards link it relative.
        self.assertEqual(render.TOKENS_CSS, 'ds/distill/tokens.css')
        self.assertEqual(render.TOKENS_LINK, '<link rel="stylesheet" href="./ds/distill/tokens.css">')

    def test_card_without_caption(self):
        # Every card on today's boards has a caption, so the goldens never show the empty one.
        self.assertTrue(render.card(1, {'card': {}, 'label': 'L'}, '').endswith('<span style="font-size: 12px; color: var(--muted); line-height: 1.5"></span></section>'))

    def test_state_cell_caption(self):
        self.assertNotIn('<span style="font-size: 11px', render.state_cell('L', '<i></i>', ''))
        self.assertIn('color: var(--muted); line-height: 1.45; max-width: 260px">Cap</span></div>', render.state_cell('L', '<i></i>', 'Cap'))

    def test_legacy_boards(self):
        import tempfile
        built = render.build_all()
        on_disk = sorted(f for f in os.listdir(render.LEGACY_DIR) if f.endswith('.dc.html'))
        self.assertEqual(sorted(f for f, b in built.items() if b[3] == 'legacy'), on_disk)
        saved = render.LEGACY_DIR
        try:
            with tempfile.TemporaryDirectory() as d:
                render.LEGACY_DIR = d
                board = ('<!doctype html>\n<head>\n<title>Distill — Old board</title>\n<script src="./support.js"></script>\n</head>\n'
                         '<script src="./support.js"></script>\n'
                         """<script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":1234,"height":9},"q":"it&#39;s"}'></script>\n""")
                for name, text in [('Old.dc.html', board), ('notes.md', 'x'), ('Plain.dc.html', board.replace('Distill — ', ''))]:
                    with open(os.path.join(d, name), 'w', encoding='utf-8') as f:
                        f.write(text)
                got = render.legacy_boards()
                self.assertEqual(sorted(got), ['Old.dc.html', 'Plain.dc.html'])
                html, w, title = got['Old.dc.html']
                self.assertEqual((w, title), (1234, 'Old board'))
                self.assertEqual(got['Plain.dc.html'][2], 'Old board')
                self.assertEqual(html.count(render.TOKENS_LINK), 1, 'linked once, after the first support.js')
                self.assertIn(f'<script src="./support.js"></script>\n{render.TOKENS_LINK}\n</head>', html)
                render.LEGACY_DIR = os.path.join(d, 'missing')
                self.assertEqual(render.legacy_boards(), {})
        finally:
            render.LEGACY_DIR = saved

    def test_main_writes_the_tokens_css(self):
        import contextlib
        import io
        import tempfile
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(render.main([]), 2)
            self.assertEqual(render.main(['--only']), 2)
            with tempfile.TemporaryDirectory() as d:
                self.assertEqual(render.main([d, '--bogus']), 2)
                self.assertEqual(render.main([d, '--only', 'Pill']), 0)
                self.assertEqual(render.main([d, '--only', 'Pill']), 0, 'a second render into the same folder')
                self.assertEqual(read(os.path.join(d, render.TOKENS_CSS)), read(tokens.DS_CSS))
                self.assertTrue(os.path.exists(os.path.join(d, 'support.js')))
                self.assertTrue(os.path.exists(os.path.join(d, 'Pill.dc.html')))


GOLDEN_DIR = os.path.join(ROOT, 'testdata', 'golden')
# One board per kind and per piece of board chrome: a component, a states board (captions), a screen board
# with numbered cards, one with plain list heads, one with counted list heads, one with section subtitles, a page board
# (window, sidebar, main) and a legacy board (the tokens link put in).
GOLDEN_BOARDS = ['Pill.dc.html', 'QuickSourceButtonStates.dc.html', 'QueueLabelGate.dc.html', 'ActionsHistory.dc.html',
                 'ActionsSlack.dc.html', 'Activity.dc.html', 'MainEmpty.dc.html', 'AppIcon.dc.html']


class Golden(unittest.TestCase):
    """render.py's output for a fixed set of boards, byte for byte. In memory, no canvas, no network."""

    def test_boards_match_goldens(self):
        built = render.build_all()
        update = os.environ.get('UPDATE_GOLDEN') == '1'
        if update:
            os.makedirs(GOLDEN_DIR, exist_ok=True)
        for f in GOLDEN_BOARDS:
            self.assertIn(f, built, f'{f}: no longer built; pick another board for GOLDEN_BOARDS')
            html, width, title, kind = built[f]
            got = f'<!-- golden: {kind}, width {width}, title {title} -->\n{html}'
            path = os.path.join(GOLDEN_DIR, f)
            if update:
                with open(path, 'w', encoding='utf-8') as fh:
                    fh.write(got)
                continue
            self.assertTrue(os.path.exists(path), f'{f}: no golden; run UPDATE_GOLDEN=1 python3 apps/distill/design/test_design.py')
            self.assertEqual(got, read(path), f'{f} renders differently from testdata/golden/{f}; if intended, run '
                                              'UPDATE_GOLDEN=1 python3 apps/distill/design/test_design.py and review the diff')
        self.assertEqual(sorted(os.listdir(GOLDEN_DIR)), sorted(GOLDEN_BOARDS), 'golden files no board is checked against')


def report():
    pending =[c['name'] for c in COMPONENTS if not c.get('swift')]
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

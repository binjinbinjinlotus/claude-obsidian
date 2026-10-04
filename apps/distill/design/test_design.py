#!/usr/bin/env python3
"""Drift check between the design schema and the Swift app (the one-to-one mapping).

    python3 apps/distill/design/test_design.py

Fails when:
  - tokens.json disagrees with Theme.swift;
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


class Tokens(unittest.TestCase):
    def test_tokens_match_theme(self):
        with open(tokens.OUT, encoding='utf-8') as f:
            self.assertEqual(f.read(), tokens.render(), 'tokens.json disagrees with Theme.swift: run python3 apps/distill/design/tokens.py')


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


def report():
    pending = [c['name'] for c in COMPONENTS if not c.get('swift')]
    design_only = sum(1 for c in COMPONENTS for p in c['props'] if p.get('swift') is False)
    print(f'components: {len(COMPONENTS)}; no Swift view yet: {", ".join(pending) or "none"}; design-only props: {design_only}')
    for c in COMPONENTS:
        for p in c['props']:
            if p.get('swiftPending'):
                print(f'  designed, not in Swift yet: {c["name"]}.{p["name"]} ({p["swiftPending"]})')
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

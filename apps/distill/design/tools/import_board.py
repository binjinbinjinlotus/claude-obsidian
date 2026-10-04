#!/usr/bin/env python3
"""Import published legacy boards into a screens/*.json file (migration tool, standard library only).

    python3 apps/distill/design/tools/import_board.py [--ids IDS.json] PROJECT_DIR SCREEN_JSON BOARD[:BASE_PREFIX] ...

PROJECT_DIR is a copy of the canvas project (the final, published .dc.html files). Each board is
parsed into the schema: frames become states of a base screen (the board's first frame), recognized
regions become nodes (header template, ActionsToolbar instance, ActionRow lists as data, detail and
other panes as named fragments in screens/<name>/), and each state keeps only what differs from its
base. Grid cards become card states whose body is a fragment or a component instance. render.py must
reproduce every imported board byte for byte; the tool checks that and refuses to write otherwise.

Fragments are honest leftovers: bespoke markup that is not a component yet. The summary prints how
many each board has, so they can be turned into components one by one.
"""
import copy
import hashlib
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DESIGN = os.path.dirname(HERE)
sys.path.insert(0, DESIGN)
sys.dont_write_bytecode = True
import render  # noqa: E402

VOID = {'br', 'img', 'meta', 'link', 'input', 'hr'}
TAG = re.compile(r'<(/?)([a-zA-Z][\w-]*)((?:\s+[^\s=>/]+(?:="[^"]*"|=\'[^\']*\')?)*)\s*(/?)>')


# ---------------------------------------------------------------- a byte-exact element tree
class El:
    def __init__(self, tag, attrs, start, open_end):
        self.tag, self.attrs, self.start, self.open_end = tag, attrs, start, open_end
        self.end = self.close_start = None
        self.kids = []

    def style(self):
        m = re.search(r'style="([^"]*)"', self.attrs)
        return m.group(1) if m else ''

    def attr(self, k):
        m = re.search(rf'\s{k}="([^"]*)"', self.attrs)
        return m.group(1) if m else None


def parse(s, start=0, end=None):
    end = len(s) if end is None else end
    root = El('#root', '', start, start)
    stack = [root]
    for m in TAG.finditer(s, start, end):
        close, tag, attrs, selfclose = m.group(1), m.group(2).lower(), m.group(3), m.group(4)
        if close:
            for i in range(len(stack) - 1, 0, -1):
                if stack[i].tag == tag:
                    for el in stack[i:]:
                        if el.end is None:
                            el.close_start, el.end = m.start(), m.end()
                    del stack[i:]
                    break
            continue
        el = El(tag, attrs, m.start(), m.end())
        stack[-1].kids.append(el)
        if selfclose or tag in VOID:
            el.close_start = el.end = m.end()
        else:
            stack.append(el)
    root.close_start = root.end = end
    return root


def html(s, el):
    return s[el.start:el.end]


def inner(s, el):
    return s[el.open_end:el.close_start]


def camel(k):
    return re.sub(r'-([a-z])', lambda m: m.group(1).upper(), k)


def value(v):
    if v == 'true':
        return True
    if v == 'false':
        return False
    if re.fullmatch(r'-?[1-9]\d*|0', v):
        return int(v)
    return v


def instance(s, el):
    """A dc-import element → {"c", "props", "size"}; None when render.dc_import can't give it back."""
    attrs = re.findall(r'\s([\w-]+)="([^"]*)"', el.attrs)
    name = dict(attrs).get('name')
    hint = dict(attrs).get('hint-size', '')
    props = {camel(k): value(v) for k, v in attrs if k not in ('name', 'hint-size')}
    node = {'c': name, 'props': props, 'size': hint.split(',', 1) if ',' in hint else ['auto', 'auto']}
    return node if render.dc_import(name, props, node['size']) == html(s, el) else None


# ---------------------------------------------------------------- fragments
class Frags:
    def __init__(self, prefix):
        self.prefix, self.by_text, self.files = prefix, {}, {}

    def add(self, text, hint):
        if text in self.by_text:
            return {'frag': self.by_text[text]}
        name = f'{self.prefix}-{hint}'
        i = 2
        while name in self.files:
            name, i = f'{self.prefix}-{hint}-{i}', i + 1
        self.by_text[text], self.files[name] = name, text
        return {'frag': name}


def slug(text, n=5):
    words = re.findall(r'[a-z0-9]+', re.sub(r'<[^>]+>', ' ', text).lower())
    return '-'.join(words[:n]) or 'x'


# ---------------------------------------------------------------- regions inside <main>
DETAIL_STYLES = ('flex-grow: 1; min-width: 0; overflow: hidden; padding: 2px 2px 20px',
                 'flex-grow: 1; padding: 0 32px',
                 'flex-grow: 1; min-width: 0; display: flex; flex-direction: column; gap: 14px; padding: 26px 30px')
TOAST_STYLE = 'position: absolute; left: 50%; bottom: 20px; transform: translateX(-50%)'
HEAD_RX = re.compile(r'<div style="display: flex; align-items: center; gap: 6px; padding: 10px 12px 4px; font-size: 10px; font-weight: 800; letter-spacing: \.06em; color: (#[0-9A-F]{6})">'
                     r'<svg [^>]*><path d="M6 9l6 6 6-6"/></svg>([^<]*)<span style="font-weight: 700; color: #9B978F">(\d+)</span></div>$')
PLAIN_RX = re.compile(r'<div style="padding: 8px 10px 2px; font-size: 10px; font-weight: 800; letter-spacing: \.06em; color: #9B978F">([^<]*)</div>$')


def action_list(s, container):
    """Children of a list container → (items, flags) when they are only heads and ActionRows."""
    items, flags, n = [], {'selected': None, 'hover': None, 'gone': None}, 0
    for k in container.kids:
        h = html(s, k)
        if k.tag == 'dc-import' and k.attr('name') == 'ActionRow':
            node = instance(s, k)
            if not node or node['size'] != ['100%', '56px']:
                return None
            p = dict(node['props'])
            for flag, key in (('selected', 'selected'), ('hover', 'hover'), ('faded', 'gone')):
                if p.pop(flag, False) is True:
                    if flags[key] is not None:
                        return None
                    flags[key] = n
            items.append(p)
            n += 1
            continue
        m = HEAD_RX.match(h)
        if m:
            it = {'head': m.group(2), 'fixedCount': int(m.group(3))}
            if m.group(1) != '#9B978F':
                it['color'] = m.group(1)
            items.append(it)
            continue
        m = PLAIN_RX.match(h)
        if m:
            items.append({'head': m.group(1), 'style': 'plain'})
            continue
        return None
    return items, flags


def split_main(s, main, frags, ctx):
    """<main> inner → (layout skeleton with {placeholders}, regions)."""
    regions, cuts = {}, []

    def take(el, name, node, whole=True):
        regions[name] = node
        a, b = (el.start, el.end) if whole else (el.open_end, el.close_start)
        cuts.append((a, b, name))

    def walk(el):
        for k in el.kids:
            st = k.style()
            if k.tag == 'header' and 'header' not in regions:
                take(k, 'header', header_node(s, k, frags, ctx))
                continue
            if k.tag == 'dc-import' and k.attr('name') == 'ActionsToolbar' and 'toolbar' not in regions:
                node = instance(s, k)
                if node:
                    take(k, 'toolbar', node)
                    continue
            if 'list' not in regions and any(x.tag == 'dc-import' and x.attr('name') == 'ActionRow' for x in k.kids):
                got = action_list(s, k)
                if got:
                    items, flags = got
                    take(k, 'list', {'_items': items, **flags}, whole=False)
                    continue
            if 'list' not in regions and st == 'display: flex; flex-direction: column; gap: 1px' and k.kids and k.kids[0].tag == 'div':
                take(k, 'list', frags.add(html(s, k), f'{ctx}-list'))
                continue
            if 'detail' not in regions and (any(st.startswith(d) for d in DETAIL_STYLES) or (k.tag == 'aside' and 'list' in regions)):
                if k.tag == 'aside':
                    take(k, 'detail', frags.add(html(s, k), f'{ctx}-detail'))
                else:
                    take(k, 'detail', frags.add(inner(s, k), f'{ctx}-detail') if inner(s, k) else '', whole=False)
                continue
            if st == TOAST_STYLE:
                take(k, 'toast', frags.add(inner(s, k), f'{ctx}-toast'), whole=False)
                continue
            walk(k)

    walk(main)
    cuts.sort()
    out, pos = [], main.open_end
    for a, b, name in cuts:
        out.append(s[pos:a].replace('{', '{{').replace('}', '}}'))
        out.append('{' + name + '}')
        pos = b
    out.append(s[pos:main.close_start].replace('{', '{{').replace('}', '}}'))
    return ''.join(out), regions


HEADER_TEMPLATE = ('<header style="display: flex; align-items: flex-start; gap: 12px; padding: 28px 32px 0">\n<div style="display: flex; flex-direction: column; gap: 5px; flex-grow: 1">'
                   '<span style="font-size: 11px; font-weight: 800; letter-spacing: .06em; color: #9B978F">ACTIONS</span><h1 style="margin: 0; font-family: \'Bricolage Grotesque\', sans-serif; '
                   'font-weight: 800; font-size: 30px; letter-spacing: -0.03em; line-height: 1.05">{title}</h1>\n<span style="font-size: 13px; color: #6B6862">{sub}</span></div>{right}</header>')


def header_node(s, el, frags, ctx):
    m = re.fullmatch(r'<header style="display: flex; align-items: flex-start; gap: 12px; padding: 28px 32px 0">\n<div style="display: flex; flex-direction: column; gap: 5px; flex-grow: 1"><span style="font-size: 11px; font-weight: 800; letter-spacing: \.06em; color: #9B978F">ACTIONS</span><h1 style="margin: 0; font-family: \'Bricolage Grotesque\', sans-serif; font-weight: 800; font-size: 30px; letter-spacing: -0\.03em; line-height: 1\.05">(.*?)</h1>\n<span style="font-size: 13px; color: #6B6862">(.*?)</span></div>(.*)</header>', html(s, el), re.S)
    if m:
        right_el = parse(s, el.start + m.start(3), el.start + m.end(3))
        right = [instance(s, k) for k in right_el.kids]
        if all(right) and ''.join(html(s, k) for k in right_el.kids) == m.group(3):
            return {'t': 'header', 'vars': {'title': m.group(1), 'sub': m.group(2), 'right': right}}
    return frags.add(html(s, el), f'{ctx}-header')


# ---------------------------------------------------------------- frames, cards, boards
WIN_RX = re.compile(r'<div style="position: relative; width: (\d+)px; height: (\d+)px; flex-shrink: 0; isolation: isolate">')


def positioned_instance(s, els):
    """One `position: absolute` div around one dc-import → an instance with "at"; None otherwise."""
    if len(els) != 1 or len(els[0].kids) != 1 or els[0].kids[0].tag != 'dc-import':
        return None
    st = els[0].style()
    if not st.startswith('position: absolute; ') or inner(s, els[0]) != html(s, els[0].kids[0]):
        return None
    node = instance(s, els[0].kids[0])
    if not node:
        return None
    at = {}
    for part in st[len('position: absolute; '):].split('; '):
        k, _, v = part.partition(': ')
        at[k] = int(v[:-2]) if re.fullmatch(r'-?\d+px', v) else v
    node['at'] = at
    return node if render.render_node(node, {}) == html(s, els[0]) else None


def frame_state(s, win, frags, ctx):
    m = WIN_RX.match(html(s, win))
    if not m or len(win.kids) != 3:
        return None
    w, h = int(m.group(1)), int(m.group(2))
    content = win.kids[1]
    if not content.kids or content.kids[0].tag != 'div' or len(content.kids) < 2 or content.kids[1].tag != 'main':
        return None
    side = content.kids[0]
    sb = instance(s, side.kids[0]) if side.kids else None
    if not sb or sb['c'] != 'Sidebar':
        return None
    layout, regions = split_main(s, content.kids[1], frags, ctx)
    over = ''.join(html(s, k) for k in content.kids[2:])
    if over:
        regions['overlay'] = positioned_instance(s, content.kids[2:]) or frags.add(over, f'{ctx}-overlay')
    st = {'window': {'width': w, 'height': h}, 'sidebar': sb['props'], 'layout': layout, 'regions': regions}
    return st


SECTION_RX = re.compile(r'<section style="display: flex; flex-direction: column; gap: 10px; min-width: 0"><div style="display: flex; align-items: center; gap: 8px"><span style="[^"]*">(\d+)</span><span style="font-size: 14px; font-weight: 700">(.*?)</span></div>'
                        r'<div style="position: relative; height: (\d+)px; border-radius: 18px; background: ([^;]+); overflow: hidden; padding: ([^;]+); box-sizing: border-box; display: flex; flex-direction: column; align-items: ([^;]+); justify-content: flex-start">', re.S)


def card_state(s, sec, frags, ctx):
    m = SECTION_RX.match(html(s, sec))
    if not m or len(sec.kids) != 3:
        return None
    body_el, cap_el = sec.kids[1], sec.kids[2]
    body = inner(s, body_el)
    node = None
    if len(body_el.kids) == 1 and body_el.kids[0].tag == 'dc-import' and html(s, body_el.kids[0]) == body:
        node = instance(s, body_el.kids[0])
    if node is None:
        node = frags.add(body, f'{ctx}-{slug(m.group(2), 4)}')
    return int(m.group(1)), {'label': m.group(2), 'caption': inner(s, cap_el), 'body': node,
                             'card': {'height': int(m.group(3)), 'bg': m.group(4), 'pad': m.group(5), 'align': m.group(6)}}


def import_board(s, prefix, frags, ids):
    root = parse(s, s.index('<x-dc>'))
    measure = None

    def find(el):
        nonlocal measure
        for k in el.kids:
            if k.tag == 'div' and ' data-measure ' in k.attrs + ' ':
                measure = k
                return
            find(k)
    find(root)
    outer = measure and next(k for k in root.kids[0].kids if k.tag == 'div')
    head = measure.kids[0]
    hm = re.fullmatch(r'<div style="display: flex; flex-direction: column; gap: 8px">\n<span style="[^"]*">(.*?)</span>\n<span style="font-size: 13px; color: #6B6862; max-width: 1400px; line-height: 1\.55">(.*)</span>\n</div>', html(s, head), re.S)
    board = {'heading': hm.group(1), 'intro': hm.group(2), 'width': int(re.search(r'width: (\d+)px', outer.style()).group(1)), 'sections': []}
    states, base, frame_no = [], None, 0

    def add_frame(fr):
        nonlocal base, frame_no
        label = inner(s, fr.kids[0])
        st = frame_state(s, fr.kids[1], frags, f'f{frame_no}')
        frame_no += 1
        if st is None:
            raise SystemExit(f'{prefix}: frame "{label[:50]}" did not parse')
        sid = f'{prefix}-frame-{frame_no}'
        st.update(id=sid, label=label)
        states.append(st)
        return sid

    for k in measure.kids[1:]:
        st = k.style()
        if st.startswith('display: flex; gap: 40px'):
            board['sections'].append({'row': [add_frame(f) for f in k.kids], 'style': st})
        elif st == 'display: flex; flex-direction: column; gap: 10px' and len(k.kids) == 2 and k.kids[0].tag == 'span':
            board['sections'].append({'frame': add_frame(k)})
        elif st == 'display: flex; flex-direction: column; gap: 4px; margin-top: 10px':
            t = inner(s, k.kids[0])
            sec = {'title': t}
            if len(k.kids) > 1:
                sec['sub'] = inner(s, k.kids[1])
            board['sections'].append(sec)
        elif st.startswith('display: grid; grid-template-columns: repeat('):
            gm = re.match(r'display: grid; grid-template-columns: repeat\((\d+), minmax\(0, 1fr\)\); gap: (.*)$', st)
            sec = {'grid': [], 'cols': int(gm.group(1))}
            if gm.group(2) != '30px 24px':
                sec['gap'] = gm.group(2)
            for i, c in enumerate(k.kids):
                got = card_state(s, c, frags, f'c{len(states)}')
                if not got:
                    raise SystemExit(f'{prefix}: card {i + 1} did not parse')
                n, cs = got
                if n != i + 1:
                    cs['number'] = n
                cs['id'] = f'{prefix}-card-{slug(cs["label"], 4)}'
                states.append(cs)
                sec['grid'].append(cs['id'])
            board['sections'].append(sec)
        else:
            raise SystemExit(f'{prefix}: unknown board section {st[:60]!r}')
    return board, states


# ---------------------------------------------------------------- bases and overrides
def diff_props(a, b, path):
    out = {}
    for k in list(a) + [k for k in b if k not in a]:
        if a.get(k) != b.get(k):
            out[f'{path}.{k}'] = b.get(k)
    if list(b) != [k for k in a if k in b] + [k for k in b if k not in a]:
        return None  # order differs: replace whole
    return out


def same(a, b):
    return json.dumps(a, ensure_ascii=False) == json.dumps(b, ensure_ascii=False)  # order-sensitive


def checked(cand, whole, base_part, want, orders):
    """`cand` if applying it to `base_part` gives exactly `want` (attribute order included), else `whole`."""
    got = render.apply_override(base_part, cand, orders)
    return cand if same(got, want) else whole


def to_overrides(base, st, lists, orders):
    """The smallest override that turns `base` into frame state `st`."""
    o = {}
    if st['window'] != base['window']:
        o['window'] = st['window']
    if not same(base['sidebar'], st['sidebar']):
        d = {f'sidebar.{k}': st['sidebar'].get(k) for k in list(base['sidebar']) + list(st['sidebar']) if base['sidebar'].get(k) != st['sidebar'].get(k)}
        o.update(checked(d, {'sidebar': st['sidebar']}, {'regions': {}, 'sidebar': base['sidebar']}, {'regions': {}, 'sidebar': st['sidebar']}, orders))
    if st['layout'] != base['layout']:
        o['layout'] = st['layout']
    br, sr = base['regions'], st['regions']
    for k in list(br) + [k for k in sr if k not in br]:
        a, b = br.get(k), sr.get(k)
        if a == b and same(a, b):
            continue
        if b is None:
            o[k] = None
        elif a and 'c' in a and 'c' in b and a['c'] == b['c'] and a.get('size') == b.get('size'):
            d = {f'{k}.{p}': b['props'].get(p) for p in list(a['props']) + list(b['props']) if a['props'].get(p) != b['props'].get(p)}
            o.update(checked(d, {k: b}, {'regions': {k: a}}, {'regions': {k: b}}, orders))
        elif a and 'list' in a and 'list' in b and a['list'] == b['list']:
            for f in ('selected', 'hover', 'gone'):
                if a.get(f) != b.get(f):
                    o[f'{k}.{f}'] = b.get(f)
        elif a and 't' in a and 't' in b and a['t'] == b['t']:
            for v in list(a['vars']) + [v for v in b['vars'] if v not in a['vars']]:
                if a['vars'].get(v) != b['vars'].get(v):
                    o[f'{k}.vars.{v}'] = b['vars'].get(v)
        else:
            o[k] = b
    return o


def name_lists(states, prefix, lists):
    for st in states:
        for r, node in st.get('regions', {}).items():
            if isinstance(node, dict) and '_items' in node:
                items = node.pop('_items')
                gone, idx = node.get('gone'), 0
                for j, it in enumerate(items):  # drop counts the renderer derives anyway
                    if 'head' not in it:
                        idx += 1
                        continue
                    n = 0
                    for k in items[j + 1:]:
                        if 'head' in k:
                            break
                        n += 1
                    n -= 1 if gone is not None and idx <= gone < idx + n else 0
                    if it.get('fixedCount') == n:
                        del it['fixedCount']
                key = next((k for k, v in lists.items() if v == items), None)
                if key is None:
                    key = prefix if prefix not in lists else f'{prefix}-{len([k for k in lists if k.startswith(prefix)]) + 1}'
                    lists[key] = items
                node['list'] = key
                for f in ('selected', 'hover', 'gone'):
                    if node.get(f) is None:
                        node.pop(f, None)


def layout_key(screen, text, prefix, regions):
    """A layout's name says what it holds: list + detail, + toast, or a single pane (empty states)."""
    found = next((k for k, v in screen['layouts'].items() if v == text), None)
    if found:
        return found
    kind = ('list-detail' if 'list' in regions else 'pane') + ('-toast' if 'toast' in regions else '')
    key, i = f'{prefix}-{kind}', 2
    while key in screen['layouts']:
        key, i = f'{prefix}-{kind}-{i}', i + 1
    screen['layouts'][key] = text
    return key


def main(argv):
    args = list(argv)
    idmap = {}
    if '--ids' in args:
        i = args.index('--ids')
        idmap = {k: v for k, v in json.load(open(args[i + 1])).items() if not k.startswith('$')}
        del args[i:i + 2]
    proj, screen_path = args[0], args[1]
    screen = json.load(open(screen_path)) if os.path.exists(screen_path) else {}
    name = os.path.basename(screen_path)[:-5]
    frag_dir = os.path.join(os.path.dirname(screen_path), name)
    screen.setdefault('$doc', 'Imported from the published canvas by tools/import_board.py, then edited by hand. Bases: one per tab; '
                      'states: overrides on a base (frames) or cards; boards: ordered sections. Fragments (screens/' + name + '/*.html) are bespoke '
                      'markup that is not a component yet.')
    screen.setdefault('row', 13625)
    screen['templates'] = dict(screen.get('templates', {}), header=HEADER_TEMPLATE)
    screen['layouts'], screen['lists'], screen['bases'], screen['states'], screen['boards'] = {}, {}, {}, [], []
    orders = render.prop_orders(render.load('components.json')['components'])
    report = []
    for spec in args[2:]:
        file, _, prefix = spec.partition(':')
        prefix = prefix or slug(file[:-8], 2)
        s = open(os.path.join(proj, file), encoding='utf-8').read()
        frags = Frags(prefix)
        board, states = import_board(s, prefix, frags, {})
        for st in states:
            st['id'] = idmap.get(st['id'], st['id'])
        for sec in board['sections']:
            for k in ('row', 'grid'):
                if k in sec:
                    sec[k] = [idmap.get(x, x) for x in sec[k]]
            if 'frame' in sec:
                sec['frame'] = idmap.get(sec['frame'], sec['frame'])
        name_lists(states, prefix, screen['lists'])
        frames = [x for x in states if 'window' in x]
        for st in frames:
            st['layout'] = layout_key(screen, st['layout'], prefix, st['regions'])
        if frames:
            b = frames[0]
            screen['bases'][prefix] = {'window': b['window'], 'sidebar': b['sidebar'], 'layout': b['layout'], 'regions': b['regions']}
        full = sum(len(json.dumps(x)) for x in frames)
        small = 0
        for st in states:
            if 'window' in st:
                o = to_overrides(screen['bases'][prefix], st, screen['lists'], orders)
                entry = {'id': st['id'], 'base': prefix, 'label': st['label']}
                if o:
                    entry['set'] = o
                small += len(json.dumps(o))
            else:
                entry = {k: st[k] for k in ('id', 'label', 'caption', 'card', 'body', 'number') if k in st}
            screen['states'].append(entry)
        board.update(file=file, title=re.search(r'<title>Distill — (.*?)</title>', s).group(1))
        screen['boards'].append({k: board[k] for k in ('file', 'title', 'heading', 'intro', 'width', 'sections')})
        os.makedirs(frag_dir, exist_ok=True)
        for fname, text in frags.files.items():
            with open(os.path.join(frag_dir, fname + '.html'), 'w', encoding='utf-8') as f:
                f.write(text)
        cards = sum(1 for x in states if 'card' in x)
        card_frags = sum(1 for x in states if 'card' in x and 'frag' in x['body'])
        report.append(f'{file}: {len(frames)} frames (overrides {small} B vs {full} B as full frames), {cards} cards ({card_frags} fragments), {len(frags.files)} fragments in all')
    with open(screen_path, 'w', encoding='utf-8') as f:
        json.dump(screen, f, indent=1, ensure_ascii=False)
        f.write('\n')
    print('\n'.join(report))


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

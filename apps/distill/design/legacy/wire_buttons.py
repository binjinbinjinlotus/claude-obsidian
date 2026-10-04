"""Boards written by hand (rows 1–5 originals, gen_md/compose/images/sizing) still draw some buttons and
status pills inline. This pass swaps them for PrimaryButton / SoftButton / Pill imports. gen_actions emits
the components directly (btn, pill); this catches the rest. Runs last in rebuild.sh; idempotent."""
import os, re, sys, collections
import symbols
from gen_actions import P

PROJ = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'distill-design', 'project')
COMPONENTS = {'Sidebar', 'WindowShell', 'QuickShell', 'MarkdownStyleBar', 'PrimaryButton', 'SoftButton', 'Pill', 'SettingsSectionNav'}
LEAD = r'(<svg\b[^>]*>(?:(?!</svg>).)*</svg>|<span style="width: \d+px; height: \d+px;[^"]*border-top-color[^"]*"></span>)?'
EL = re.compile(r'<(span|button|a|div)( [^>]*)?style="([^"]*)"([^>]*)>\s*' + LEAD + r'\s*([^<>{}]{1,40})</\1>', re.S)

# Status text → Pill. Segmented options, source/label chips, menus, the Aa toggle and fields stay their own views.
STATUS = re.compile(r'^(Applied|Ready|In batch|Next batch|Couldn’t read|Already in|Always|Rejected|Failed|Cancelled|Queued|Default|Edited|Removed|'
                    r'Draft|Not written|Not created|Created|Writing|Polishing|Creating|Copied|Sent|Done|Open|New|Unconfirmed|AI|Coming later|✓ )')
NOT_BUTTONS = re.compile(r'^(Any label|All labels|All notes|On|Off|\d+ min|\d+ hour|2h 30m|Daily|Slack|Meeting|GitHub review|Jira comment|Email|'
                         r'In person|Web page|Document|Paper|Remember this|Idea|Aa$|Discussion|Sonnet · Medium)|[▾›]$')
PLACEHOLDER = '#9B978F'
WHITE = ('#FFFFFF', '#FFF', 'WHITE')
BY_D = symbols.symbols(P)
PATHS = {re.sub(r'\s*/>', '>', v).replace('></path>', '>').replace('></circle>', '>').replace('></rect>', '>'): k for k, v in P.items()}


def props(style):
    return {k.strip(): v.strip() for k, v in (p.split(':', 1) for p in style.split(';') if ':' in p)}


def lead_of(lead):
    """'' | 'busy' | SF symbol | None (an icon we can't name: leave the element alone)."""
    if not lead:
        return ''
    if lead.startswith('<span'):
        return 'busy'
    inner = re.sub(r'<svg\b[^>]*>|</svg>', '', lead)
    inner = re.sub(r'\s*/>', '>', inner).replace('></path>', '>').replace('></circle>', '>').replace('></rect>', '>')
    inner = re.sub(r'\s+(stroke|fill|stroke-width)="[^"]*"', lambda m: m.group(0) if 'currentColor' in m.group(0) else '', inner)
    name = PATHS.get(inner)
    if name:
        return symbols.SF.get(name)
    d = re.fullmatch(r'<path d="([^"]*)">', inner.strip())
    return next((k for k, v in BY_D.items() if d and v == d.group(1)), None)


def stroke_of(st):
    m = re.search(r'(?:1px solid|1\.5px solid|0 0 0 1px|0 0 0 1\.5px) (#[0-9A-Fa-f]{3,6})', st.get('border', '') + ' ' + st.get('box-shadow', ''))
    return m.group(1) if m else None


def classify(m):
    st = props(m.group(3))
    text = m.group(6).strip()
    lead = lead_of(m.group(5))
    if lead is None or not text or 'width' in st or 'min-width' in st or 'border-radius' not in st:
        return None
    if int((re.match(r'\d+', st['border-radius']) or [0])[0] or 0) < 8:
        return None
    hs = st.get('height', '')
    h = int(hs[:-2]) if re.fullmatch(r'\d+px', hs) else None
    bg = st.get('background', st.get('background-color', 'transparent'))
    ink = st.get('color', '#1C1B19')
    if not (bg.startswith('#') or bg == 'transparent'):
        return None
    if STATUS.search(text) and (h is None or h <= 28) and 'font-size' in st:
        small = (h or 22) <= 20 or st.get('font-size', '12px') in ('10px', '10.5px')
        p = {'text': text, 'fill': bg, 'ink': ink}
        if small: p['size'] = 'small'
        if lead == 'busy': p['busy'] = 'true'
        elif lead: p['system-image'] = lead
        if 'dashed' in st.get('border', ''): p['dashed'] = 'true'
        elif stroke_of(st): p['stroke'] = stroke_of(st)
        return 'Pill', p, st
    if h is None or not 24 <= h <= 44 or 'padding' not in st or NOT_BUTTONS.search(text) or lead == 'busy' or ink.upper() == PLACEHOLDER:
        return None
    size = 'regular' if h >= 36 else 'small' if h >= 29 else 'mini'
    p = {'title': text}
    if lead: p['system-image'] = lead
    p['size'] = size
    if bg.upper() == '#1F6FEB' and ink.upper() in WHITE:
        return 'PrimaryButton', p, st
    if bg.upper() == '#A8C6F5' and ink.upper() in WHITE:
        return 'PrimaryButton', dict(p, enabled='false'), st
    p.update(tint=ink, fill=bg)
    if stroke_of(st) and bg != 'transparent':
        p['stroke'] = stroke_of(st)
    return 'SoftButton', p, st


LAYOUT = ('margin', 'margin-left', 'margin-right', 'margin-top', 'margin-bottom', 'align-self', 'position', 'left', 'right', 'top', 'bottom', 'justify-self')
H = {'regular': 40, 'small': 30, 'mini': 26}


def replace(m, stats):
    c = classify(m)
    if not c:
        return m.group(0)
    name, p, st = c
    icon = 16 if ('system-image' in p or 'busy' in p) else 0
    if name == 'Pill':
        small = p.get('size') == 'small'
        w, h = round(len(p['text']) * (6.2 if small else 7)) + (16 if small else 20) + icon, (20 if small else 24)
    else:
        w = round({'regular': 8, 'small': 7.2, 'mini': 6.6}[p['size']] * len(p['title'])) + {'regular': 40, 'small': 28, 'mini': 22}[p['size']] + icon
        h = H[p['size']]
    attrs = ' '.join(f'{k}="{v}"' for k, v in p.items())
    extra = re.sub(r'\s*type="button"', '', (m.group(2) or '') + m.group(4))
    keep = '; '.join(f'{k}: {st[k]}' for k in LAYOUT if k in st)
    imp = f'<dc-import name="{name}" {attrs} hint-size="{w}px,{h}px"></dc-import>'
    stats[(name, p.get('size', 'regular'))] += 1
    tag = 'a' if m.group(1) == 'a' else 'span'
    if keep or extra.strip():
        return f'<{tag}{extra.rstrip()} style="display: inline-flex; flex-shrink: 0; text-decoration: none; {keep}">{imp}</{tag}>'
    return imp


# Status pills drawn inside <sc-for> with holes: background/color/text all come from the row.
TPL = re.compile(r'<span( title="[^"]*")? style="height: 2[2-6]px; display: flex; align-items: center;[^"]*border-radius: 1[1-3]px;[^"]*background: (\{\{[a-zA-Z.]+\}\}); color: (\{\{[a-zA-Z.]+\}\})">(\{\{[a-zA-Z.]+\}\})</span>')


def replace_tpl(m, stats):
    stats[('Pill', 'template')] += 1
    imp = f'<dc-import name="Pill" text="{m.group(4)}" fill="{m.group(2)}" ink="{m.group(3)}" hint-size="110px,24px"></dc-import>'
    return f'<span{m.group(1)} style="display: inline-flex; flex-shrink: 0">{imp}</span>' if m.group(1) else imp


if __name__ == '__main__':
    stats = collections.Counter()
    for f in sorted(os.listdir(PROJ)):
        if not f.endswith('.dc.html') or f[:-8] in COMPONENTS:
            continue
        p = os.path.join(PROJ, f)
        s = open(p).read()
        s2 = TPL.sub(lambda m: replace_tpl(m, stats), EL.sub(lambda m: replace(m, stats), s))
        if '--dry' in sys.argv:
            for m in EL.finditer(s):
                c = classify(m)
                if c: print(f, c[0], c[1])
        elif s2 != s:
            open(p, 'w').write(s2)
    print(dict(stats), sum(stats.values()))

"""Second wiring pass (after wire_buttons.py): small controls drawn inline on hand-written boards become
imports of their Swift-named components: Segmented, PillSwitch, CapsuleSwitch, LabelChip, FilterChip,
DropdownButton, QuickSourceButton, ModelChip, MarkdownBarToggle, SendButton, IconButton, LinkButton.
gen_actions emits most of these directly (toggle, seg, select, filter_chip, iconbtn, btn ghost). Idempotent."""
import os, re, sys, collections
import symbols
from wire_buttons import PROJ, lead_of, props

SKIP = {'Sidebar', 'WindowShell', 'QuickShell', 'MarkdownStyleBar', 'PrimaryButton', 'SoftButton', 'Pill', 'SettingsSectionNav',
        'Segmented', 'SegmentedPills', 'PillSwitch', 'CapsuleSwitch', 'LabelChip', 'FilterChip', 'SourceChip', 'ModelChip', 'DropdownButton',
        'QuickSourceButton', 'MarkdownBarToggle', 'SendButton', 'IconButton', 'LinkButton', 'Tile'}
OPEN = re.compile(r'<(span|button|div|a)\b([^>]*)>')
HOLE = re.compile(r'^\{\{[a-zA-Z.$]+\}\}$')


def elements(s):
    """Yield (start, end, tag, attrs, inner) for every element, outermost first."""
    for m in OPEN.finditer(s):
        tag = m.group(1)
        depth, i = 1, m.end()
        tok = re.compile(rf'<{tag}\b[^>]*>|</{tag}>')
        while depth:
            t = tok.search(s, i)
            if not t:
                break
            depth += -1 if t.group(0).startswith('</') else 1
            i = t.end()
        if depth == 0:
            yield m.start(), i, tag, m.group(2), s[m.end():i - len(tag) - 3]


def text_of(inner):
    return re.sub(r'\s+', ' ', re.sub(r'<[^>]+>', ' ', inner)).strip()


def imp(name, w, h, **p):
    a = ' '.join(f'{re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), k)}="{v}"' for k, v in p.items() if v is not None)
    return f'<dc-import name="{name}" {a} hint-size="{w}px,{h}px"></dc-import>'


def px(st, k):
    m = re.match(r'(\d+)px', st.get(k, ''))
    return int(m.group(1)) if m else None


def classify(tag, attrs, inner):
    sm = re.search(r'style="([^"]*)"', attrs)
    if not sm:
        return None
    st = props(sm.group(1))
    txt = text_of(inner)
    w, h = px(st, 'width'), px(st, 'height')
    bg = st.get('background', 'transparent')
    radius = st.get('border-radius', '')
    kids = re.findall(r'<(button|span)\b[^>]*style="([^"]*)"[^>]*>([^<]{1,30})</\1>', inner)
    # Segmented: a white track (gap 2, padding 2) holding text segments, one of them blue.
    if 'gap' in st and st.get('padding') == '2px' and len(kids) >= 2 and len(kids) == len(re.findall(r'<(?:button|span)\b', inner)):
        sel = [t for _, ks, t in kids if '#1F6FEB' in props(ks).get('background', '')]
        if len(sel) == 1:
            hh = px(props(kids[0][1]), 'height') or 24
            return 'Segmented', sum(len(t) * 7 + 22 for *_, t in kids) + 6, hh + 4, dict(options='|'.join(t.strip() for *_, t in kids), selection=sel[0].strip(), height=hh if hh != 24 else None)
    # PillSwitch / CapsuleSwitch: a 34–40 × 20–24 capsule with a knob.
    if w and h and 30 <= w <= 42 and 18 <= h <= 24 and txt == '' and ('#1F6FEB' in bg or '#D6D3CC' in bg):
        isOn = 'true' if '#1F6FEB' in bg else 'false'
        if w == 34 and h == 20:
            return 'CapsuleSwitch?', 0, 0, dict(isOn=isOn)
        return 'PillSwitch', w, h, dict(isOn=isOn, width=w if w != 40 else None, height=h if h != 24 else None)
    # SendButton: round blue/grey button with the arrow-up.
    if w and w == h and 'M12 19V5M5 12l7-7 7 7' in inner and txt == '':
        return 'SendButton', w, w, dict(enabled='false' if '#D6D3CC' in bg else None, size=w if w != 38 else None)
    # Tile: square-ish colored tile with a 1–4 letter label (file type, vault initial).
    if w and w == h and 28 <= w <= 48 and (re.fullmatch(r'[A-Z]{1,4}', txt) or re.fullmatch(r'\{\{[a-zA-Z.]+\}\}', txt)) and '<svg' not in inner and bg != 'transparent':
        r = px(st, 'border-radius') or 0
        if 0.2 * w <= r <= 0.4 * w:
            display = 'Bricolage' in st.get('font-family', '') or (px(st, 'font-size') or 10) > 12
            return 'Tile', w, w, dict(text=txt, fill=bg, ink=st.get('color'), size=w if w != 40 else None, display='true' if display else None)
    # IconButton: round, plain fill, one stroked icon, no text.
    if w and w == h and 16 <= w <= 34 and txt in ('', '×') and radius in (f'{w // 2}px', '50%') and bg in ('transparent', '#F6F5F2', '#FFFFFF') and tag in ('span', 'button'):
        svg = re.fullmatch(r'\s*(<svg\b(?:(?!</svg>).)*</svg>)\s*', inner, re.S)
        sym = lead_of(svg.group(1)) if svg else ('xmark' if txt == '×' else None)
        if sym and sym != 'busy':
            ink = re.search(r'stroke="(#[0-9A-Fa-f]{6})"', inner)
            tint = ink.group(1) if ink else st.get('color', '#6B6862')
            t = re.search(r'(?:title|aria-label)="([^"{]*)"', attrs)
            return 'IconButton', w, w, dict(systemImage=sym, size=w if w != 26 else None, tint=tint if tint.upper() != '#6B6862' else None,
                                            fill=bg if bg != 'transparent' else None, help=t.group(1) if t else None)
    if not h or not 18 <= h <= 34:
        return None
    # Aa
    if txt == 'Aa':
        return 'MarkdownBarToggle', 38, min(26, max(24, h)), dict(isOn='true' if '#E3EEFF' in bg else None, height=26 if h >= 26 else None)
    # QuickSourceButton: + Source, or a chosen source in lime with ▾ (quick note footer).
    m = re.fullmatch(r'(.+?) ▾', txt)
    if (txt == '+ Source' and '#F6F5F2' in bg) or (m and bg.upper() in ('#E9FBC9', '#F3FDE4')):
        return 'QuickSourceButton', 90, 24, dict(source=m.group(1) if m else None)
    # LabelChip: 24–26 pt, dashed (suggested) or solid tint, '#name'.
    if h in (24, 26) and ('#' in txt[:3] or '{{' in txt) and ('dashed' in st.get('border', '') or ('#E3EEFF' in bg and '#' in txt[:3])):
        border = st.get('border', '')
        hole = re.search(r'\{\{([a-zA-Z]+)\.[a-zA-Z]+\}\}', border)
        if hole:
            style = '{{' + hole.group(1) + '.style}}'
        else:
            style = 'suggestedNew' if '#FFB894' in border else 'suggestedExisting' if '#B9F06A' in border else 'muted' if 'dashed' in border else None
        nm = re.search(r'#(\{\{[a-zA-Z.]+\}\}|[\w-]+)', txt)
        if not nm:
            return None
        return 'LabelChip', len(txt) * 7 + 24, h, dict(labelName=nm.group(1), style=style, sparkle='true' if '✦' in txt else None,
                                                     removable='true' if '×' in txt else None, height=h if h != 26 else None)
    # FilterChip: 28 pt tinted chip with × (Ask filters).
    if h == 28 and '×' in txt and bg.upper() in ('#E3EEFF', '#E9FBC9', '#F3FDE4'):
        t = txt.replace('×', '').strip()
        return 'FilterChip', len(t) * 7 + 40, 28, dict(text=t, fill=bg if bg.upper() != '#E3EEFF' else None, ink=st.get('color') if st.get('color', '').upper() != '#1F6FEB' else None)
    # ModelChip (compact): the quick ask footer's "Sonnet · Medium".
    mm = re.fullmatch(r'(Sonnet|Haiku|Opus) · (Low|Medium|High)', txt)
    if mm and '#F6F5F2' in bg:
        return 'ModelChip', len(txt) * 7 + 34, 26, dict(model=mm.group(1), effort=mm.group(2), showRunner='false', showEffort='true', compact='true')
    # DropdownButton: "Title ▾" pickers (models, effort, Insert field).
    if m and not re.search(r'<svg', inner) and bg.upper() in ('#FFFFFF', '#F6F5F2', '#E3EEFF'):
        r = px(st, 'border-radius') or 10
        return 'DropdownButton', len(m.group(1)) * 7 + 40, h, dict(title=m.group(1), height=h if h != 32 else None, radius=r if r != 10 else None)
    return None


def capsule_title(s, start, end):
    """CapsuleSwitch draws its own title: take the text right after the switch inside the parent span."""
    m = re.match(r'\s*([^<]{1,40})', s[end:])
    return (m.group(1).strip(), end + m.end()) if m and m.group(1).strip() else (None, end)


def wire(s, stats):
    out, pos = [], 0
    for start, end, tag, attrs, inner in elements(s):
        if start < pos or 'data-measure' in attrs:
            continue
        c = classify(tag, attrs, inner)
        if not c:
            continue
        name, w, h, p = c
        if name == 'CapsuleSwitch?':
            title, end2 = capsule_title(s, start, end)
            if not title:
                name, w, h, p = 'PillSwitch', 34, 20, dict(p, width=34, height=20)
            else:
                name, w, h, p = 'CapsuleSwitch', len(title) * 7 + 44, 20, dict(p, title=title)
                end = end2
        out.append(s[pos:start])
        out.append(imp(name, w, h, **p))
        stats[name] += 1
        pos = end
    out.append(s[pos:])
    s = ''.join(out)
    # LinkButton: blue text buttons previously wired as transparent SoftButtons.
    def link(m):
        a = m.group(0)
        if 'title="+ Source"' in a:
            stats['QuickSourceButton'] += 1
            return '<dc-import name="QuickSourceButton" hint-size="70px,24px"></dc-import>'
        if 'fill="transparent"' in a and 'tint="#1F6FEB"' in a and 'system-image' not in a:
            t = re.search(r'title="([^"]*)"', a).group(1)
            stats['LinkButton'] += 1
            return f'<dc-import name="LinkButton" title="{t}" hint-size="{len(t) * 7 + 16}px,28px"></dc-import>'
        return a
    return re.sub(r'<dc-import name="SoftButton"[^>]*></dc-import>', link, s)


def script_styles(s):
    """LabelChip in templates reads {{x.style}}: give the rows' label objects a style from their tag."""
    s = s.replace("tag: 'existing',", "tag: 'existing', style: 'suggestedExisting',").replace("tag: 'new',", "tag: 'new', style: 'suggestedNew',")
    s = s.replace("({ name, tag: isNew ? 'new' : '',", "({ name, style: isNew ? 'suggestedNew' : 'suggestedExisting', tag: isNew ? 'new' : '',")
    return re.sub(r"style: '(suggested\w+)', style: '\1', ", r"style: '\1', ", s)


if __name__ == '__main__':
    stats = collections.Counter()
    for f in sorted(os.listdir(PROJ)):
        if not f.endswith('.dc.html') or f[:-8] in SKIP or f.endswith('States.dc.html'):
            continue
        p = os.path.join(PROJ, f)
        s = open(p).read()
        i = s.find('<x-dc>'); j = s.find('</x-dc>')
        body = wire(s[i:j], stats)
        s2 = script_styles(s[:i] + body + s[j:])
        if s2 != s and '--dry' not in sys.argv:
            open(p, 'w').write(s2)
    print(dict(stats), sum(stats.values()))

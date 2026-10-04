#!/usr/bin/env python3
"""Flow 6 · Actions from your notes. Writes the Actions*.dc.html and SettingsNav.dc.html boards
and places them on canvas.json. Run: python3 gen_actions.py [--measure]"""
import json, os, re, subprocess, sys
import symbols

S = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.join(S, 'distill-design', 'project')

INK, MUTED, FAINT, PANEL, LINE, BLUE, TINT = '#1D1C1A', '#6B6862', '#9B978F', '#F6F5F2', '#ECEAE5', '#1F6FEB', '#E3EEFF'
BODY = '#2A2925'
LIME_INK, LIME_BG, LIME = '#3D6110', '#F3FDE4', '#B9F06A'
PEACH_INK, PEACH_BG, PEACH = '#B03A0A', '#FFF4EE', '#FFB894'
HEAD = "font-family: 'Bricolage Grotesque', sans-serif"

# ---------------------------------------------------------------- icons
P = {
    'check': '<path d="M5 12l5 5 9-10"/>',
    'clock': '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    'plus': '<path d="M12 5v14M5 12h14"/>',
    'search': '<circle cx="11" cy="11" r="7"/><path d="M20 20l-4-4"/>',
    'down': '<path d="M6 9l6 6 6-6"/>',
    'right': '<path d="M9 6l6 6-6 6"/>',
    'todo': '<circle cx="12" cy="12" r="9"/><path d="M8 12l3 3 5-6"/>',
    'slack': '<path d="M4 5h16v11H9l-5 4z"/><path d="M10 8.5l-1 5M14 8.5l-1 5M8.3 10h7M8 12h7"/>',
    'jira': '<path d="M4 7a2 2 0 0 1 2-2h12a2 2 0 0 1 2 2v2a2 2 0 0 0 0 4v2a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2v-2a2 2 0 0 0 0-4z"/><path d="M10 9h4M10 13h4"/>',
    'page': '<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4M9 12h6M9 16h6"/>',
    'mail': '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 7l9 6 9-6"/>',
    'copy': '<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h8"/>',
    'send': '<path d="M21 3L10 14M21 3l-7 18-4-7-7-4z"/>',
    'trash': '<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/>',
    'restore': '<path d="M3 12a9 9 0 1 0 3-6.7"/><path d="M3 4v5h5"/>',
    'ext': '<path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>',
    'note': '<path d="M6 3h12v18H6z"/><path d="M9 8h6M9 12h6M9 16h4"/>',
    'person': '<circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/>',
    'flag': '<path d="M5 21V4h11l-2 4 2 4H5"/>',
    'cal': '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
    'pencil': '<path d="M4 20h4L19 9l-4-4L4 16z"/>',
    'filter': '<path d="M4 5h16l-6 8v6l-4-2v-4z"/>',
    'dots': '<circle cx="5" cy="12" r="1.3" fill="currentColor"/><circle cx="12" cy="12" r="1.3" fill="currentColor"/><circle cx="19" cy="12" r="1.3" fill="currentColor"/>',
    'refresh': '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
    'globe': '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',
    'lock': '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
    'warn': '<circle cx="12" cy="12" r="9"/><path d="M12 8v5M12 16h.01"/>',
    'list': '<path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01"/>',
    'sort': '<path d="M7 4v16M3 16l4 4 4-4M17 20V4M13 8l4-4 4 4"/>',
    'x': '<path d="M6 6l12 12M18 6L6 18"/>',
    'link': '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
    'undo': '<path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>',
    'hash': '<path d="M10 4L8 20M16 4l-2 16M4 9h16M3 15h16"/>',
    'gear': '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
    'bolt': '<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>',
    'inbox': '<path d="M22 12h-6l-2 3h-4l-2-3H2"/><path d="M5.5 5h13L22 12v6a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-6z"/>',
    'review': '<path d="M9 11l3 3 8-8"/><path d="M20 12v6a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h9"/>',
    'ask': '<path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/>',
    'tag': '<path d="M20.6 13.4l-7.2 7.2a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8z"/><path d="M7.5 7.5h.01"/>',
    'actions': '<path d="M9 6h11M9 12h11M9 18h11"/><path d="M3.5 6l1.5 1.5L7.5 5M3.5 12l1.5 1.5L7.5 11M3.5 18l1.5 1.5L7.5 17"/>',
    'grip': '<circle cx="9" cy="6" r="1" fill="currentColor"/><circle cx="15" cy="6" r="1" fill="currentColor"/><circle cx="9" cy="12" r="1" fill="currentColor"/><circle cx="15" cy="12" r="1" fill="currentColor"/><circle cx="9" cy="18" r="1" fill="currentColor"/><circle cx="15" cy="18" r="1" fill="currentColor"/>',
}


def ic(name, size=14, c=MUTED, sw=2):
    return (f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="none" stroke="{c}" stroke-width="{sw}" '
            f'stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="flex-shrink: 0; color: {c}">{P[name]}</svg>')


SPARK = '<svg width="{s}" height="{s}" viewBox="0 0 24 24" fill="{c}" aria-hidden="true" style="flex-shrink: 0"><path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"></path></svg>'


def spark(c=LIME_INK, s=12):
    return SPARK.format(c=c, s=s)


def spinner(c=BLUE, s=12):
    return f'<span style="width: {s}px; height: {s}px; box-sizing: border-box; border-radius: 50%; border: 2px solid #D6E4FB; border-top-color: {c}; flex-shrink: 0"></span>'


# ---------------------------------------------------------------- shared components (row 0, gen_components.py)
def dc(name, w='auto', h='auto', **props):
    """<dc-import> of a sibling component; camelCase props become kebab attributes."""
    a = ' '.join(f'{re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), k)}="{v}"' for k, v in props.items() if v is not None)
    return f'<dc-import name="{name}" {a} hint-size="{w},{h}"></dc-import>'


STYLEBAR = dc('MarkdownStyleBar', 'auto', '34px', variant='compact')
STYLEBAR_SM = dc('MarkdownStyleBar', 'auto', '28px', variant='compact', size='small')


def window(content, w=1200, h=760, overlay=''):
    """WindowShell frame behind, content in the window, traffic lights on top."""
    hh = f'height: {h}px;' if h else ''
    fw, fh = (w, h) if h else ('100%', '100%')
    return (f'<div style="position: relative; width: {w}px; {hh} flex-shrink: 0; isolation: isolate">'
            f'<div style="position: absolute; inset: 0; z-index: -1">{dc("WindowShell", f"{w}px", f"{h}px" if h else "100%", layer="frame", width=fw, height=fh)}</div>'
            f'<div style="{"position: absolute; left: 20px; top: 20px; right: 20px; bottom: 20px;" if h else "margin: 20px;"} display: flex; border-radius: 16px; overflow: hidden">{content}{overlay}</div>'
            f'<div style="position: absolute; left: 38px; top: 36px">{dc("WindowShell", "52px", "12px", layer="controls")}</div></div>')


SB_KEY = {'Queue': 'queue', 'Review': 'review', 'Actions': 'actions', 'Ask': 'ask', 'Labels': 'labels', 'History': 'history'}


def sidebar_dc(active='Queue', sub='', height=720, **props):
    return f'<div style="width: 220px; height: {height}px; flex-shrink: 0">{dc("Sidebar", "220px", f"{height}px", section=SB_KEY.get(active, active), sub=sub or None, height=height, **props)}</div>'


def sidebar_box(active='Queue', sub='', height=400, **props):
    return f'<div style="border-radius: 14px; overflow: hidden; box-shadow: 0 0 0 1px {LINE}; width: 220px">{sidebar_dc(active, sub, height, **props)}</div>'


def quick_frame(inner, w=560, title='Quick ask', gap=9, pad='12px 14px 14px', h=None, extra=''):
    """QuickShell: frame behind, close bar on top, board content in between (no slots in Design Components)."""
    hh = f'height: {h}px;' if h else ''
    return (f'<div style="position: relative; width: {w}px; {hh} box-sizing: border-box; isolation: isolate; {extra}">'
            f'<div style="position: absolute; inset: 0; z-index: -1">{dc("QuickShell", "100%", "100%", part="frame", width="100%", height="100%")}</div>'
            f'<div style="display: flex; flex-direction: column; gap: {gap}px; padding: {pad}">{dc("QuickShell", "100%", "22px", part="bar", title=title)}{inner}</div></div>')

# action types: the registry every board draws from
TYPES = {
    'todo': dict(name='To do', one='to-do', many='To do', icon='todo', bg=TINT, ink=BLUE),
    'slack': dict(name='Slack message', one='Slack message', many='Slack messages', icon='slack', bg='#FFE0EC', ink='#A3245A'),
    'jira': dict(name='Jira ticket', one='Jira ticket', many='Jira tickets', icon='jira', bg='#DDF2FF', ink='#0B5C86'),
    'conf': dict(name='Confluence page', one='Confluence page', many='Confluence pages', icon='page', bg='#E9FBC9', ink=LIME_INK),
    'mail': dict(name='Email', one='email', many='Emails', icon='mail', bg='#FFE4D6', ink=PEACH_INK),
}


def tbadge(t, size=30, r=9, isz=15):
    d = TYPES[t]
    return f'<span style="width: {size}px; height: {size}px; border-radius: {r}px; background: {d["bg"]}; display: flex; align-items: center; justify-content: center; flex-shrink: 0">{ic(d["icon"], isz, d["ink"])}</span>'


# ---------------------------------------------------------------- small parts
def _pill_inline(text, bg=PANEL, fg=INK, h=24, fs=12, fw=600, extra=''):
    return f'<span style="height: {h}px; display: inline-flex; align-items: center; gap: 5px; padding: 0 {h // 2 - 2}px; border-radius: {h // 2}px; background: {bg}; color: {fg}; font-size: {fs}px; font-weight: {fw}; white-space: nowrap; box-sizing: border-box; {extra}">{text}</span>'


def _btn_inline(text, kind='secondary', h=32, fs=13, icon=None, disabled=False, extra=''):
    st = {
        'primary': f'background: {BLUE}; color: #FFFFFF; box-shadow: 0 4px 12px rgba(31,111,235,.25)',
        'secondary': f'background: #FFFFFF; color: {INK}; box-shadow: 0 0 0 1px {LINE}',
        'soft': f'background: {PANEL}; color: {INK}',
        'ghost': f'background: transparent; color: {BLUE}',
        'danger': f'background: transparent; color: {PEACH_INK}',
        'ok': f'background: {LIME_BG}; color: {LIME_INK}; box-shadow: 0 0 0 1px {LIME}',
    }[kind]
    if disabled:
        st = f'background: {PANEL}; color: #B5B1A9; box-shadow: 0 0 0 1px {LINE}' if kind != 'primary' else 'background: #A8C6F5; color: #FFFFFF'
    ico = ''
    if icon:
        c = '#FFFFFF' if kind == 'primary' else ('#B5B1A9' if disabled else (BLUE if kind == 'ghost' else (PEACH_INK if kind == 'danger' else (LIME_INK if kind == 'ok' else '#48463F'))))
        ico = ic(icon, fs, c, 2.2)
    return f'<span style="height: {h}px; display: inline-flex; align-items: center; gap: 7px; padding: 0 {h // 2}px; border-radius: {h // 2}px; {st}; font-size: {fs}px; font-weight: 600; white-space: nowrap; box-sizing: border-box; flex-shrink: 0; {extra}">{ico}{text}</span>'


def _lead_icon(text):
    """A leading ic()/spinner() in a label → ('busy' | SF symbol | None, plain rest)."""
    if text.startswith('<span style="width: ') and 'border-top-color' in text.split('</span>', 1)[0]:
        return 'busy', text.split('</span>', 1)[1]
    m = re.match(r'<svg [^>]*>(.*?)</svg>', text)
    if m:
        name = next((n for n, v in P.items() if v == m.group(1)), None)
        return (symbols.SF.get(name) if name else None), text[m.end():]
    return None, text


def _layout(extra):
    keep = '; '.join(p.strip() for p in extra.split(';') if p.strip().split(':')[0].strip() in ('margin-left', 'margin-right', 'margin-top', 'align-self', 'flex-shrink', 'margin'))
    return keep


def _wrap(imp, extra):
    keep = _layout(extra)
    return f'<span style="display: inline-flex; flex-shrink: 0; {keep}">{imp}</span>' if keep else imp


def size_of(h):
    return 'regular' if h >= 36 else 'small' if h >= 29 else 'mini'


def pill(text, bg=PANEL, fg=INK, h=24, fs=12, fw=600, extra=''):
    """Status pills are the Pill component; 28+ pt chips (presets, sources, labels) stay their own views."""
    lead, rest = _lead_icon(text)
    if h >= 28 or '<' in rest or (text.startswith('<') and not lead):
        return _pill_inline(text, bg, fg, h, fs, fw, extra)
    st = {kv.split(':', 1)[0].strip(): kv.split(':', 1)[1].strip() for kv in extra.split(';') if ':' in kv}
    stroke = re.search(r'(#[0-9A-Fa-f]{6})', st.get('box-shadow', '')) if 'inset' in st.get('box-shadow', '') else None
    dashed = 'dashed' in st.get('border', '')
    small = h <= 20
    w = round(len(rest) * (6.2 if small else 7)) + (16 if small else 20) + (16 if lead else 0)
    imp = dc('Pill', f'{w}px', f'{20 if small else 24}px', text=rest, fill=bg, ink=fg, size='small' if small else None,
             busy='true' if lead == 'busy' else None, systemImage=lead if lead and lead != 'busy' else None,
             stroke=stroke.group(1) if stroke else None, dashed='true' if dashed else None)
    return _wrap(imp, extra)


def btn(text, kind='secondary', h=32, fs=13, icon=None, disabled=False, extra=''):
    """PrimaryButton / SoftButton (Theme.swift) at size regular 40 · small 30 · mini 26."""
    if '<' in text:
        return _btn_inline(text, kind, h, fs, icon, disabled, extra)
    if kind == 'ghost' and not icon and not disabled:
        return _wrap(dc('LinkButton', f'{len(text) * 7 + 16}px', '28px', title=text, size=fs if fs in (11, 13) else None), extra)
    size = size_of(h)
    hh = {'regular': 40, 'small': 30, 'mini': 26}[size]
    w = round(len(text) * {'regular': 8, 'small': 7.2, 'mini': 6.6}[size]) + {'regular': 40, 'small': 28, 'mini': 22}[size] + (18 if icon else 0)
    sym = symbols.SF.get(icon) if icon else None
    st = {kv.split(':', 1)[0].strip(): kv.split(':', 1)[1].strip() for kv in extra.split(';') if ':' in kv}
    if kind == 'primary' and 'background' not in st:
        imp = dc('PrimaryButton', f'{w}px', f'{hh}px', title=text, systemImage=sym, size=size, enabled='false' if disabled else None)
        return _wrap(imp, extra)
    tint, fill, stroke = {'primary': ('#FFFFFF', BLUE, None), 'secondary': (INK, '#FFFFFF', LINE), 'soft': (INK, PANEL, None), 'ghost': (BLUE, 'transparent', None),
                          'danger': (PEACH_INK, 'transparent', None), 'ok': (LIME_INK, LIME_BG, LIME)}[kind]
    fill = st.get('background', fill)
    tint = st.get('color', tint)
    if st.get('box-shadow') == 'none' or fill == 'transparent':
        stroke = None
    imp = dc('SoftButton', f'{w}px', f'{hh}px', title=text, tint=tint, fill=fill, stroke=stroke, systemImage=sym, size=size, enabled='false' if disabled else None)
    return _wrap(imp, extra)


def iconbtn(name, size=28, c=MUTED, bg='transparent', title=''):
    """IconButton: round icon-only button (⋯, edit, remove, close)."""
    return dc('IconButton', f'{size}px', f'{size}px', systemImage=symbols.SF.get(name, name), size=size if size != 26 else None,
              tint=c if c != MUTED else None, fill=bg if bg != 'transparent' else None, help=title or None)


def toggle(on=True, label=None):
    """PillSwitch at the Settings size (36 × 22)."""
    return dc('PillSwitch', '36px', '22px', isOn='true' if on else 'false', label=label, width=36, height=22)


def seg(opts, active, h=28, fs=12):
    """SegmentedPills (the Settings segmented control)."""
    w = sum(len(o) * 7 + 22 for o in opts) + 6
    return dc('SegmentedPills', f'{w}px', f'{h}px', options='|'.join(opts), selection=active, height=h - 4 if h != 28 else 24)


def select(text, w=None, hl=False, h=30, radius=10):
    """DropdownButton. hl draws the canvas's highlight ring around it (annotation, not a state)."""
    d = dc('DropdownButton', f'{w or len(text) * 7 + 40}px', f'{h}px', title=text, width=w, height=h, radius=radius if radius != 10 else None)
    return f'<span style="display: inline-flex; border-radius: {radius + 2}px; box-shadow: 0 0 0 2px #BFD5FA">{d}</span>' if hl else d


def avatar(initials, bg='#FFE0EC', fg='#A3245A', s=20):
    return f'<span style="width: {s}px; height: {s}px; border-radius: {s // 2}px; background: {bg}; color: {fg}; font-size: {max(9, s // 2 - 1)}px; font-weight: 700; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0">{initials}</span>'


def label(n, fs=11):
    return f'<span style="font-size: {fs}px; font-weight: 600; color: {LIME_INK}; white-space: nowrap">#{n}</span>'


def notelink(title, when=None, fs=12):
    w = f'<span style="color: {MUTED}; font-weight: 400"> · {when}</span>' if when else ''
    return f'<span style="display: inline-flex; align-items: center; gap: 5px; font-size: {fs}px; font-weight: 600; color: {BLUE}; white-space: nowrap">{ic("note", fs, BLUE)}{title}{w}</span>'


def quote(text, fs=12):
    return f'<div style="border-left: 3px solid #D6D3CC; padding: 2px 0 2px 10px; font-size: {fs}px; line-height: 1.55; color: #48463F; font-style: italic">{text}</div>'


def context(note, when, excerpt, why, fs=12, by='Sonnet', created='today at 3:44 PM'):
    return (f'<div style="display: flex; flex-direction: column; gap: 7px; padding: 11px 12px; border-radius: 12px; background: {PANEL}">'
            f'<div style="display: flex; align-items: center; gap: 8px"><span style="font-size: 10px; font-weight: 800; letter-spacing: .05em; color: {FAINT}">FROM</span>{notelink(note, when, fs)}</div>'
            f'{quote(excerpt, fs)}'
            f'<div style="display: flex; gap: 6px; font-size: {fs}px; line-height: 1.5; color: #48463F"><b style="flex-shrink: 0; color: {INK}">Why:</b><span>{why}</span></div>'
            f'<div style="display: flex; align-items: center; gap: 6px; font-size: 11px; color: {MUTED}">{spark(LIME_INK, 11)}Found by {by} · Created {created}</div></div>')


def caret(color=INK):
    return f'<span style="display: inline-block; width: 1.5px; height: 14px; background: {color}; vertical-align: -2px; margin-left: 1px"></span>'


def toast(text, actions=(), icon='check', ic_c=LIME_INK, w=None):
    ww = f'width: {w}px;' if w else ''
    acts = ''.join(f'<span style="font-size: 12px; font-weight: 700; color: #8FB8FF; white-space: nowrap">{a}</span>' for a in actions)
    return (f'<div style="{ww} display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-radius: 14px; background: #1D1C1A; color: #FFFFFF; box-shadow: 0 10px 24px rgba(29,28,26,.25); box-sizing: border-box">'
            f'{ic(icon, 14, "#B9F06A" if ic_c == LIME_INK else ic_c, 2.4)}<span style="font-size: 12px; font-weight: 600; flex-grow: 1">{text}</span>{acts}</div>')


def shimmer_over(text, cancel=True, radius=12):
    c = f'<span style="height: 22px; display: flex; align-items: center; padding: 0 9px; border-radius: 11px; background: {PANEL}; font-size: 11px; font-weight: 700; color: #48463F">Cancel</span>' if cancel else ''
    return (f'<div style="position: absolute; inset: 0; border-radius: {radius}px; background: rgba(255,255,255,.6)"></div>'
            f'<div style="position: absolute; inset: 0; border-radius: {radius}px; background: linear-gradient(100deg, transparent 30%, rgba(227,238,255,.75) 50%, transparent 70%)"></div>'
            '<div style="position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); display: flex; align-items: center; gap: 8px; height: 30px; padding: 0 6px 0 12px; border-radius: 15px; background: #FFFFFF; box-shadow: 0 6px 16px rgba(29,28,26,.18); white-space: nowrap">'
            f'{spinner()}<span style="font-size: 12px; font-weight: 700">{text}</span>{c}</div>')


def banner(kind, title, body='', actions=''):
    bg, fg, line, icn = {
        'error': (PEACH_BG, PEACH_INK, '#FFD9C5', 'warn'),
        'info': ('#F2F7FF', BLUE, '#D6E4FB', 'globe'),
        'ok': (LIME_BG, LIME_INK, '#DDF5B8', 'check'),
        'wait': ('#F2F7FF', BLUE, '#D6E4FB', None),
    }[kind]
    lead = spinner() if icn is None else ic(icn, 15, fg, 2.2)
    b = f'<span style="font-size: 12px; line-height: 1.5; color: #48463F">{body}</span>' if body else ''
    a = f'<div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap; margin-top: 4px">{actions}</div>' if actions else ''
    return (f'<div style="display: flex; gap: 10px; padding: 11px 13px; border-radius: 12px; background: {bg}; box-shadow: 0 0 0 1px {line}">'
            f'<span style="padding-top: 1px">{lead}</span><div style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1; min-width: 0">'
            f'<span style="font-size: 13px; font-weight: 700; color: {fg}">{title}</span>{b}{a}</div></div>')


def state_pill(kind, text):
    m = {'draft': (PANEL, '#48463F'), 'ready': (LIME_BG, LIME_INK), 'busy': (TINT, BLUE), 'done': (LIME_BG, LIME_INK),
         'error': ('#FFE4D6', PEACH_INK), 'muted': (PANEL, MUTED), 'later': ('#FFFFFF', FAINT), 'jira': ('#DDF2FF', '#0B5C86')}[kind]
    lead = spinner(BLUE, 10) if kind == 'busy' else ''
    extra = f'box-shadow: inset 0 0 0 1.5px {LINE}; border: none' if kind == 'later' else ''
    return pill(lead + text, m[0], m[1], 22, 11, 700, extra)


def md(text, fs=13):
    """Tiny Markdown-ish renderer for drafts: **b**, `code`, lines starting with '- ' and '## '."""
    out = []
    for ln in text.split('\n'):
        h = ln
        h = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', h)
        h = re.sub(r'`(.+?)`', r'<code>\1</code>', h)
        h = re.sub(r'@(\w+)', rf'<span style="color: {BLUE}; font-weight: 600">@\1</span>', h)
        if ln.startswith('## '):
            out.append(f'<div style="{HEAD}; font-weight: 600; font-size: {fs + 2}px; margin-top: 4px">{h[3:]}</div>')
        elif ln.startswith('- '):
            out.append(f'<div style="display: flex; gap: 7px; font-size: {fs}px; line-height: 1.55; color: {BODY}"><span style="color: {FAINT}">•</span><span>{h[2:]}</span></div>')
        elif ln.startswith('[ ] '):
            out.append(f'<div style="display: flex; gap: 7px; align-items: center; font-size: {fs}px; line-height: 1.55; color: {BODY}"><span style="width: 11px; height: 11px; border-radius: 3px; box-shadow: inset 0 0 0 1.5px #B5B1A9"></span><span>{h[4:]}</span></div>')
        elif ln == '':
            out.append('<div style="height: 6px"></div>')
        else:
            out.append(f'<div style="font-size: {fs}px; line-height: 1.55; color: {BODY}">{h}</div>')
    return ''.join(out)


# ---------------------------------------------------------------- app shell
NAV = [('Queue', 'inbox', '3', 'plain'), ('Review', 'review', '1', 'peach'), ('Actions', 'actions', '9', 'blue'),
       ('Ask', 'ask', '', ''), ('Labels', 'tag', '12', 'peachtext'), ('History', 'clock', '', '')]


HREF = {'Queue': 'Main.dc.html', 'Review': 'Review.dc.html', 'Actions': 'ActionsTodo.dc.html', 'Ask': 'Ask.dc.html', 'Labels': 'Notes.dc.html', 'History': 'History.dc.html'}


def nav_items(active, counts=None):
    return sidebar(active, counts).split('aria-label="Sections">')[1].split('</nav>')[0]


def sidebar(active, counts=None):
    items = ''
    for name, icon, cnt, kind in NAV:
        if counts and name in counts:
            cnt = counts[name]
        on = name == active
        badge = ''
        if cnt:
            badge = {'plain': f'<span style="font-size: 12px; color: {MUTED}">{cnt}</span>',
                     'peach': f'<span style="font-size: 11px; font-weight: 700; color: {PEACH_INK}; background: #FFE4D6; border-radius: 9px; padding: 2px 8px">{cnt}</span>',
                     'blue': f'<span style="font-size: 11px; font-weight: 700; color: {BLUE}; background: {TINT}; border-radius: 9px; padding: 2px 8px">{cnt}</span>',
                     'peachtext': f'<span style="font-size: 12px; font-weight: 700; color: {PEACH_INK}">{cnt}</span>'}[kind]
        st = f'background: #FFFFFF; box-shadow: 0 1px 3px rgba(29,28,26,0.08); font-weight: 600' if on else ''
        items += (f'<a href="{HREF[name]}" style="display: flex; align-items: center; gap: 10px; padding: 9px 12px; border-radius: 10px; color: {INK}; text-decoration: none; font-size: 14px; {st}">'
                  f'{ic(icon, 17, BLUE if on else MUTED)}<span style="flex-grow: 1">{name}</span>{badge}</a>')
    return f'''<aside style="width: 220px; flex-shrink: 0; background: {PANEL}; display: flex; flex-direction: column; padding: 16px 14px; gap: 22px; box-sizing: border-box">
<div style="display: flex; gap: 8px; padding: 0 4px"><span style="width: 12px; height: 12px; border-radius: 6px; background: #FF5F57"></span><span style="width: 12px; height: 12px; border-radius: 6px; background: #FEBC2E"></span><span style="width: 12px; height: 12px; border-radius: 6px; background: #28C840"></span></div>
<div style="display: flex; align-items: center; gap: 9px; padding: 0 6px"><svg width="26" height="26" viewBox="0 0 32 32" aria-hidden="true"><path d="M12 3h8v8l7 13a3 3 0 0 1-2.6 4.5H7.6A3 3 0 0 1 5 24l7-13z" fill="#FFFFFF" stroke="#6B7785" stroke-width="2" stroke-linejoin="round"></path><path d="M8.6 18.5h14.8l2.5 4.8a2 2 0 0 1-1.8 2.9H7.9a2 2 0 0 1-1.8-2.9z" fill="#B9F06A"></path><circle cx="15" cy="14.5" r="1.3" fill="#1F6FEB"></circle><circle cx="18" cy="11.5" r="0.9" fill="#FF9A6B"></circle></svg><span style="{HEAD}; font-weight: 800; font-size: 20px; letter-spacing: -0.02em">distill</span></div>
<nav style="display: flex; flex-direction: column; gap: 2px" aria-label="Sections">{items}</nav>
<div style="margin-top: auto"><div style="display: flex; align-items: center; gap: 10px; padding: 8px; border-radius: 12px; background: #FFFFFF; box-shadow: 0 0 0 1px {LINE}"><span style="width: 30px; height: 30px; border-radius: 9px; background: #FFE0EC; color: #A3245A; display: flex; align-items: center; justify-content: center; {HEAD}; font-weight: 800; font-size: 15px">R</span><span style="display: flex; flex-direction: column; flex-grow: 1"><span style="font-size: 13px; font-weight: 600">Research</span><span style="font-size: 11px; color: {MUTED}">Sonnet · ready</span></span></div></div>
</aside>'''


def app(main, active='Actions', w=1200, h=760, overlay='', sub='', **sb):
    content = (sidebar_dc(active, sub, h - 40, **sb)
               + f'<main style="flex-grow: 1; display: flex; flex-direction: column; min-width: 0; position: relative; background: #FFFFFF">{main}</main>')
    return window(content, w, h, overlay)


def actions_header(tab, sub='Found in your notes · last found today at 3:44 PM in <b style="color: #1D1C1A; font-weight: 600">Tea club planning</b>', right=None):
    """Page header. The old tab bar is gone: To do, Slack messages, Jira tickets and Confluence pages are sidebar sub-items."""
    right = right if right is not None else (btn('History', 'secondary', 34, 13, 'clock') + btn('Add to-do', 'primary', 34, 13, 'plus'))
    return f'''<header style="display: flex; align-items: flex-start; gap: 12px; padding: 28px 32px 0">
<div style="display: flex; flex-direction: column; gap: 5px; flex-grow: 1"><span style="font-size: 11px; font-weight: 800; letter-spacing: .06em; color: {FAINT}">ACTIONS</span><h1 style="margin: 0; {HEAD}; font-weight: 800; font-size: 30px; letter-spacing: -0.03em; line-height: 1.05">{tab}</h1>
<span style="font-size: 13px; color: {MUTED}">{sub}</span></div>{right}</header>'''


# ---------------------------------------------------------------- board scaffolding
def card(i, name, inner, cap, h=430, bg='#E4E1DB', align='center', pad='22px'):
    return (f'<section style="display: flex; flex-direction: column; gap: 10px; min-width: 0">'
            f'<div style="display: flex; align-items: center; gap: 8px"><span style="width: 22px; height: 22px; border-radius: 11px; background: {BLUE}; color: #FFFFFF; font-size: 11px; font-weight: 700; display: flex; align-items: center; justify-content: center; flex-shrink: 0">{i}</span><span style="font-size: 14px; font-weight: 700">{name}</span></div>'
            f'<div style="position: relative; height: {h}px; border-radius: 18px; background: {bg}; overflow: hidden; padding: {pad}; box-sizing: border-box; display: flex; flex-direction: column; align-items: {align}; justify-content: flex-start">{inner}</div>'
            f'<span style="font-size: 12px; color: {MUTED}; line-height: 1.5">{cap}</span></section>')


def grid(cards, cols, start=1, gap='30px 24px'):
    return (f'<div style="display: grid; grid-template-columns: repeat({cols}, minmax(0, 1fr)); gap: {gap}">'
            + ''.join(card(start + i, *c) if isinstance(c, tuple) else c for i, c in enumerate(cards)) + '</div>')


def section_title(t, sub=''):
    s = f'<span style="font-size: 13px; color: {MUTED}; line-height: 1.5; max-width: 1300px">{sub}</span>' if sub else ''
    return f'<div style="display: flex; flex-direction: column; gap: 4px; margin-top: 10px"><span style="{HEAD}; font-weight: 800; font-size: 20px; letter-spacing: -0.01em">{t}</span>{s}</div>'


def framed(inner, label_text):
    return (f'<div style="display: flex; flex-direction: column; gap: 10px">'
            f'<span style="font-size: 14px; font-weight: 700">{label_text}</span>{inner}</div>')


SIZES_FILE = os.path.join(S, 'actions_sizes.json')
SIZES = json.load(open(SIZES_FILE)) if os.path.exists(SIZES_FILE) else {}


def board(fname, title, heading, intro, body, W):
    H = SIZES.get(fname, 2000)
    html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Distill — {title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,800&amp;family=DM+Sans:wght@400;500;600;700&amp;display=swap">
<style>body{{margin:0;font-family:"DM Sans",-apple-system,sans-serif;color:#1D1C1A;-webkit-font-smoothing:antialiased}} code{{font-size:11px;background:#F6F5F2;padding:1px 4px;border-radius:4px}} mark{{background:#E9FBC9;color:inherit;border-radius:3px;padding:0 1px;box-shadow:0 0 0 1px #B9F06A}}</style>
</helmet>
<div style="width: {W}px; height: {H}px; box-sizing: border-box; background: #F6F5F2; overflow: hidden">
<div data-measure style="padding: 34px 40px 40px; display: flex; flex-direction: column; gap: 22px">
<div style="display: flex; flex-direction: column; gap: 8px">
<span style="{HEAD}; font-weight: 800; font-size: 28px; letter-spacing: -0.02em">{heading}</span>
<span style="font-size: 13px; color: {MUTED}; max-width: 1400px; line-height: 1.55">{intro}</span>
</div>
{body}
</div>
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":{W},"height":{H}}}}}'>
class Component extends DCLogic {{ renderVals() {{ return {{}}; }} }}
</script>
</body>
</html>'''
    open(os.path.join(PROJ, fname), 'w').write(html)
    return fname, W, H, title


BOARDS = []


# ================================================================ TO DO
DUE = {'over': ('#FFE4D6', PEACH_INK), 'today': (TINT, BLUE), 'week': (PANEL, '#48463F'), 'none': None}
PRIO = {'High': PEACH_INK, 'Medium': '#B7791F', 'Low': FAINT}
PEOPLE = {'Mei': ('MT', '#FFE0EC', '#A3245A'), 'Priya': ('PS', '#DDF2FF', '#0B5C86'), 'You': ('JL', '#E9FBC9', LIME_INK), 'Tom': ('TK', '#FFE4D6', PEACH_INK)}

TODOS = [
    dict(g='Overdue', t='Cap payment client retries at 3 with backoff', note='Auth retry bug', who='You', labels=['project-x'], prio='High', due=('over', 'Sep 30'), send='jira'),
    dict(g='Today', t='Book the tasting room for Saturday', note='Tea club planning', who='Mei', labels=['tea-club'], prio='Medium', due=('today', 'Today')),
    dict(g='Today', t='Read Priya’s INC-212 timeline before the review', note='Incident review prep', who='Priya', labels=['project-x', 'incidents'], prio='Medium', due=('today', '5:00 PM')),
    dict(g='This week', t='Write the on-call handoff checklist', note='Q3 architecture sync', who='You', labels=['project-x'], prio=None, due=('week', 'Fri'), send='conf'),
    dict(g='This week', t='Ask the shop about the spring harvest', note='Gyokuro at 60 °C', who='Mei', labels=['tea'], prio='Low', due=('week', 'Thu')),
    dict(g='No due date', t='Buy the 50 g gyokuro tin', note='Gyokuro at 60 °C', who=None, labels=['tea'], prio=None, due=('none', '')),
]


def checkbox(state='open', s=18):
    if state == 'done':
        return f'<span style="width: {s}px; height: {s}px; border-radius: {s // 2}px; background: {LIME_INK}; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0">{ic("check", s - 6, "#FFFFFF", 3)}</span>'
    if state == 'sel':
        return f'<span style="width: {s}px; height: {s}px; border-radius: 5px; background: {BLUE}; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0">{ic("check", s - 6, "#FFFFFF", 3)}</span>'
    if state == 'box':
        return f'<span style="width: {s}px; height: {s}px; border-radius: 5px; box-shadow: inset 0 0 0 1.5px #B5B1A9; flex-shrink: 0; background: #FFFFFF"></span>'
    return f'<span style="width: {s}px; height: {s}px; border-radius: {s // 2}px; box-shadow: inset 0 0 0 1.5px #B5B1A9; flex-shrink: 0"></span>'


def due_chip(d):
    k, t = d
    if k == 'none':
        return ''
    bg, fg = DUE[k]
    return pill(ic('cal', 11, fg) + t, bg, fg, 22, 11, 700)


def todo_row(d, selected=False, mode='open', hl=None, compact=False, show_note=True):
    title = d['t']
    if hl:
        title = re.sub(f'({re.escape(hl)})', r'<mark>\1</mark>', title, flags=re.I)
    if mode == 'done':
        title = f'<span style="text-decoration: line-through; color: {FAINT}">{title}</span>'
    box = checkbox({'open': 'open', 'done': 'done', 'bulk': 'box', 'bulksel': 'sel'}.get(mode, 'open'))
    meta = []
    if show_note:
        meta.append(f'<span style="display: inline-flex; align-items: center; gap: 4px; color: {MUTED}">{ic("note", 11, FAINT)}{d["note"]}</span>')
    if d.get('who'):
        a = PEOPLE[d['who']]
        meta.append(f'<span style="display: inline-flex; align-items: center; gap: 5px; color: {MUTED}">{avatar(a[0], a[1], a[2], 16)}{d["who"]}</span>')
    meta += [label(l) for l in d['labels']]
    if d.get('prio'):
        meta.append(f'<span style="display: inline-flex; align-items: center; gap: 3px; color: {PRIO[d["prio"]]}; font-weight: 600">{ic("flag", 11, PRIO[d["prio"]])}{d["prio"]}</span>')
    bg = 'background: #F2F7FF; box-shadow: inset 0 0 0 1.5px #BFD5FA' if selected else ''
    if mode == 'bulksel':
        bg = 'background: #F2F7FF'
    pad = '8px 10px' if compact else '10px 12px'
    return (f'<div style="display: flex; align-items: center; gap: 12px; padding: {pad}; border-radius: 12px; {bg}">{box}'
            f'<div style="display: flex; flex-direction: column; gap: 4px; flex-grow: 1; min-width: 0"><span style="font-size: 14px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{title}</span>'
            f'<span style="display: flex; align-items: center; gap: 10px; font-size: 11px; white-space: nowrap; overflow: hidden">{"".join(meta)}</span></div>'
            f'{due_chip(d["due"])}</div>')


def group_head(name, n, color=FAINT):
    return f'<div style="display: flex; align-items: center; gap: 6px; padding: 10px 12px 4px; font-size: 10px; font-weight: 800; letter-spacing: .06em; color: {color}">{ic("down", 10, color, 3)}{name.upper()}<span style="font-weight: 700; color: {FAINT}">{n}</span></div>'


def todo_list(items=TODOS, sel=None, mode='open', hl=None, groups=True, compact=False):
    out, last = '', None
    for i, d in enumerate(items):
        if groups and d['g'] != last:
            n = sum(1 for x in items if x['g'] == d['g'])
            out += group_head(d['g'], n, PEACH_INK if d['g'] == 'Overdue' else FAINT)
            last = d['g']
        m = mode
        if mode == 'bulk' and i in (0, 2, 3):
            m = 'bulksel'
        out += todo_row(d, selected=(i == sel), mode=m, hl=hl, compact=compact)
    return f'<div style="display: flex; flex-direction: column; gap: 1px">{out}</div>'


def filter_chip(text, active=False, val=None):
    """An active filter is a FilterChip (with ▾ for its menu and × to clear); an unset one is a DropdownButton."""
    if active:
        t = f'{text}: {val} ▾'
        return dc('FilterChip', f'{len(t) * 7 + 40}px', '28px', text=t)
    return select(text, None, h=28, radius=14)


def searchbox(text='', w=190, ph='Search to-dos', focus=False):
    t = f'<span style="color: {INK}">{text}</span>{caret(BLUE)}' if text else f'<span style="color: {FAINT}">{ph}</span>'
    ring = f'box-shadow: 0 0 0 2px {BLUE}; background: #FFFFFF' if focus else f'background: {PANEL}'
    return (f'<span style="width: {w}px; height: 30px; display: inline-flex; align-items: center; gap: 7px; padding: 0 10px; border-radius: 15px; {ring}; font-size: 12px; box-sizing: border-box; flex-shrink: 0">'
            f'{ic("search", 13, FAINT)}<span style="flex-grow: 1; white-space: nowrap; overflow: hidden">{t}</span>'
            + (f'<span style="width: 16px; height: 16px; border-radius: 8px; background: #DAD7D0; display: inline-flex; align-items: center; justify-content: center">{ic("x", 8, "#FFFFFF", 3.4)}</span>' if text else '') + '</span>')


def filter_btn(n=0):
    """The To do Filter button: a DropdownButton; blue with a count once filters beyond Status: Open are set."""
    t = f'Filter · {n}' if n else 'Filter'
    return dc('DropdownButton', f'{len(t) * 7 + 52}px', '30px', title=t, systemImage='line.3.horizontal.decrease', height=30, radius=15, active='true' if n else None)


def sort_btn(group='Due date'):
    return dc('DropdownButton', f'{len(group) * 7 + 52}px', '30px', title=group, systemImage='arrow.up.arrow.down', height=30, radius=15)


def fchip(text):
    return dc('FilterChip', f'{len(text) * 7 + 40}px', '28px', text=text)


def toolbar(placeholder='Search to-dos', filters=(), search='', focus=False, right='sort', sort='Due date', conn=None, sw=190, avail=812):
    """ActionsToolbar: one line; chips that don't fit in `avail` px collapse into +N."""
    room = avail - sw - 96 - (round(len(sort) * 6.5) + 50 if right == 'sort' else 0) - (300 if right == 'connection' else 0) - 30
    vis = 0
    for f in filters:
        need = round(len(f) * 6.8) + 44
        if room - need < (44 if vis < len(filters) - 1 else 0):
            break
        room -= need; vis += 1
    return dc('ActionsToolbar', '100%', '30px', placeholder=placeholder, search=search or None, focus='true' if focus else None, searchWidth=sw if sw != 190 else None,
              chips='|'.join(filters) or None, visibleChips=vis if vis < len(filters) else None, right=right if right != 'sort' else None,
              sortTitle=sort if right == 'sort' and sort != 'Due date' else None, connection=conn if conn and conn != 'connected' else None)


def filterbar(search='', filters=(), group='Due date', focus=False, pad='14px 32px 8px', sort=True, sw=190, avail=812):
    """The To do toolbar row."""
    return (f'<div style="padding: {pad}">' + toolbar('Search to-dos', filters, search, focus, 'sort' if sort else 'none', group, sw=sw, avail=avail) + '</div>')


def menu(items, w=280, title=None, foot=None):
    """items: (icon|None, text, sub|None, state) state: '', 'on', 'off', 'hr', 'check'"""
    rows = f'<div style="padding: 6px 10px 4px; font-size: 10px; font-weight: 800; letter-spacing: .06em; color: {FAINT}">{title}</div>' if title else ''
    for it in items:
        if it == 'hr':
            rows += f'<div style="height: 1px; background: {LINE}; margin: 4px 6px"></div>'
            continue
        lead, text, sub, st = it
        dis = st == 'off'
        bg = 'background: #F2F7FF' if st == 'on' else ''
        col = '#B5B1A9' if dis else INK
        right = ''
        if st == 'check':
            right = ic('check', 13, BLUE, 2.6)
        if isinstance(st, str) and st.startswith('tag:'):
            right = pill(st[4:], LIME_BG, LIME_INK, 18, 10, 700)
        if dis:
            right = pill('Coming later', '#FFFFFF', FAINT, 18, 10, 700, f'box-shadow: inset 0 0 0 1.5px {LINE}')
        lead_html = tbadge(lead, 26, 8, 13) if lead in TYPES else (ic(lead, 14, MUTED) if lead else '')
        if dis and lead in TYPES:
            lead_html = f'<span style="opacity: .45; display: inline-flex">{lead_html}</span>'
        s = f'<span style="font-size: 11px; color: {"#C9C6BF" if dis else MUTED}; line-height: 1.35">{sub}</span>' if sub else ''
        rows += (f'<div style="display: flex; align-items: center; gap: 10px; padding: 7px 10px; border-radius: 9px; {bg}">{lead_html}'
                 f'<div style="display: flex; flex-direction: column; gap: 1px; flex-grow: 1; min-width: 0"><span style="font-size: 13px; font-weight: 600; color: {col}">{text}</span>{s}</div>{right}</div>')
    if foot:
        rows += f'<div style="margin: 4px 6px 2px; padding: 8px 6px 2px; border-top: 1px solid {LINE}; font-size: 11px; color: {MUTED}; line-height: 1.45">{foot}</div>'
    return f'<div style="width: {w}px; padding: 6px; border-radius: 14px; background: #FFFFFF; box-shadow: 0 0 0 1px rgba(29,28,26,.08), 0 14px 32px rgba(29,28,26,.18); box-sizing: border-box">{rows}</div>'


SEND_MENU = [('jira', 'Jira ticket', 'Draft a ticket in PX · Project X', 'tag:Suggested'),
             ('conf', 'Confluence page', 'Draft a page in the Project X space', ''),
             ('slack', 'Slack message', 'Write a message to paste in Slack', ''),
             'hr',
             ('mail', 'Email', 'Write an email', 'off')]
SEND_FOOT = 'It leaves To do and becomes a draft you check first. Nothing is created in Jira until you press Create.'


def field(k, v):
    return f'<div style="display: flex; align-items: center; gap: 10px; min-height: 26px"><span style="width: 70px; flex-shrink: 0; font-size: 12px; color: {MUTED}">{k}</span><span style="display: flex; align-items: center; gap: 6px; font-size: 13px; flex-wrap: wrap">{v}</span></div>'


def todo_detail(d=TODOS[1], editing=False, send_open=False):
    a = PEOPLE['Mei']
    if editing:
        title = (f'<div style="padding: 8px 10px; border-radius: 10px; box-shadow: 0 0 0 2px {BLUE}; {HEAD}; font-weight: 600; font-size: 17px; line-height: 1.3">Book the tasting room for Saturday 2 PM{caret(BLUE)}</div>')
        fields = (field('Due', select('Sat, Oct 4', 150)) + field('Priority', select('Medium', 150)) + field('People', select('Mei Tanaka', 150))
                  + field('Labels', label('tea-club', 12) + f'<span style="font-size: 12px; color: {BLUE}; font-weight: 600">+ Add</span>'))
    else:
        title = f'<div style="{HEAD}; font-weight: 600; font-size: 18px; line-height: 1.3">{d["t"]}</div>'
        retry = d is TODOS[0]
        pr = d['prio'] or 'Medium'
        who = PEOPLE[d['who'] or 'You']
        fields = (field('Due', due_chip(d['due']) + f'<span style="font-size: 12px; color: {MUTED}">{"Tue, Sep 30 · 2 days late" if retry else "Thu, Oct 2"}</span>')
                  + field('Priority', f'<span style="display: inline-flex; align-items: center; gap: 4px; color: {PRIO[pr]}; font-weight: 600; font-size: 12px">{ic("flag", 12, PRIO[pr])}{pr}</span>')
                  + field('People', avatar(who[0], who[1], who[2], 20) + f'<span style="font-size: 13px">{"You (Jin Liu)" if retry else "Mei Tanaka"}</span>')
                  + field('Labels', ''.join(label(l, 12) for l in d['labels'])))
    if not editing and d is TODOS[0]:
        ctx = context('Auth retry bug', 'today at 11:20 AM', '“Action for me: cap the payment client at 3 retries with exponential backoff before Thursday. Needs a ticket in PX.”',
                      'You assigned it to yourself. The note says it needs a ticket, so Jira ticket is suggested.', created='today at 11:24 AM')
        also = f'<div style="display: flex; align-items: center; gap: 8px; font-size: 12px; color: {MUTED}">{tbadge("slack", 22, 7, 11)}<span>Also from this note: <b style="color: {BLUE}; font-weight: 600">Message to #project-x</b></span></div>'
    else:
        ctx = context('Tea club planning', 'today at 2:10 PM',
                      '“I’ll book the tasting room for Saturday afternoon and tell Mei so she can bring the new tin.”',
                      'You said you would book it. Booking a room isn’t an action type Distill can do, so it’s a to-do.')
        also = (f'<div style="display: flex; align-items: center; gap: 8px; font-size: 12px; color: {MUTED}">{tbadge("slack", 22, 7, 11)}<span>Also from this note: <b style="color: {BLUE}; font-weight: 600">Message to Mei</b> in Slack messages</span></div>')
    foot = (iconbtn('trash', 30, MUTED, title='Remove') + '<span style="flex-grow: 1"></span>' + complete_btn() + btn('Send to', 'primary', 32, 13, 'send'))
    if editing:
        foot = f'<span style="font-size: 11px; color: {MUTED}; flex-grow: 1">Saved as you type</span>' + btn('Done', 'primary', 32, 13)
    return (f'<aside style="width: 330px; flex-shrink: 0; border-left: 1px solid {LINE}; display: flex; flex-direction: column; gap: 14px; padding: 4px 22px 20px; box-sizing: border-box; position: relative">'
            f'<div style="display: flex; align-items: center; gap: 6px">{state_pill("draft", "Open")}<span style="flex-grow: 1"></span>{iconbtn("pencil", 28, BLUE if editing else MUTED, TINT if editing else "transparent", "Edit")}{iconbtn("dots", 28)}</div>'
            f'{title}<div style="display: flex; flex-direction: column; gap: 4px">{fields}</div>{ctx}{also}'
            f'<div style="margin-top: auto; display: flex; align-items: center; gap: 8px">{foot}</div></aside>')


def todo_window(sel=1, detail=None, overlay='', mode='open', filt=None, group='Due date', items=TODOS, groups=True, bottom='', w=1200):
    detail = detail if detail is not None else todo_detail()
    fb = filt if filt is not None else filterbar(group=group)
    body = (actions_header('To do') + fb
            + f'<div style="flex-grow: 1; display: flex; gap: 8px; padding: 0 0 0 20px; min-height: 0; overflow: hidden">'
            + f'<div style="flex-grow: 1; min-width: 0; overflow: hidden; padding-right: 8px">{todo_list(items, sel, mode, groups=groups)}</div>{detail}</div>{bottom}')
    return app(body, overlay=overlay, sub='todo', w=w)


def bulk_bar():
    return (f'<div style="position: absolute; left: 50%; bottom: 18px; transform: translateX(-50%); display: flex; align-items: center; gap: 4px; padding: 6px 6px 6px 14px; border-radius: 16px; background: {INK}; color: #FFFFFF; box-shadow: 0 12px 28px rgba(29,28,26,.3); white-space: nowrap">'
            f'<span style="font-size: 13px; font-weight: 700; margin-right: 8px">3 selected</span>'
            + ''.join(f'<span style="height: 30px; display: inline-flex; align-items: center; gap: 6px; padding: 0 10px; border-radius: 10px; font-size: 12px; font-weight: 600; color: {c}">{ic(i, 13, c)}{t}</span>'
                      for i, t, c in [('check', 'Complete', '#B9F06A'), ('cal', 'Due date', '#FFFFFF'), ('flag', 'Priority', '#FFFFFF'), ('tag', 'Label', '#FFFFFF'), ('send', 'Send to', '#FFFFFF'), ('trash', 'Remove', '#FFB894')])
            + f'<span style="width: 1px; height: 18px; background: #48463F; margin: 0 4px"></span><span style="height: 30px; display: inline-flex; align-items: center; padding: 0 10px; font-size: 12px; font-weight: 600; color: #9B978F">Clear</span></div>')


def panel(inner, w=540, h=None, pad='14px 14px'):
    hh = f'height: {h}px;' if h else ''
    return f'<div style="position: relative; width: {w}px; {hh} box-sizing: border-box; padding: {pad}; border-radius: 16px; background: #FFFFFF; box-shadow: 0 0 0 1px rgba(29,28,26,.06), 0 10px 24px rgba(29,28,26,.10); display: flex; flex-direction: column; gap: 8px; overflow: hidden">{inner}</div>'


def mini_bar(search='', filters=(), focus=False, sort=False):
    return filterbar(search, filters, focus=focus, pad='0', sort=sort, sw=170, avail=530)


def filter_panel(**p):
    return dc('FilterPanel', '300px', f'{p.get("height", 560)}px', **p)


def todo_board():
    send_overlay = f'<div style="position: absolute; right: 120px; bottom: 64px">{menu(SEND_MENU, 300, "SEND TO", SEND_FOOT)}</div>'
    d0 = TODOS[0]
    detail_send = todo_detail(d0)
    # main frames
    w1 = framed(todo_window(), 'A · To do, grouped by due date, one item open')
    w2 = framed(todo_window(sel=0, detail=detail_send, overlay=send_overlay),
                'B · Send to: pick the action type that should handle it')
    bulk_fb = filterbar(filters=('#project-x',))
    w3 = framed(todo_window(sel=None, detail='', mode='bulk', bottom='', overlay=bulk_bar(), filt=bulk_fb),
                'C · Select several (click the boxes, ⇧-click a range, ⌘A): one bar for all of them')
    by_note = sorted(TODOS, key=lambda x: x['note'])
    items_note = [dict(d, g=d['note']) for d in by_note]
    w4 = framed(todo_window(sel=None, detail='', items=items_note, filt=filterbar(group='Source note')),
                'D · Group by source note: every to-do from one note together')
    row = lambda a, b: f'<div style="display: flex; gap: 40px; align-items: flex-start">{a}{b}</div>'
    # the one Filter menu
    p_over = f'<div style="position: absolute; left: 448px; top: 150px">{filter_panel(due="Today", height=520)}</div>'
    today = [d for d in TODOS if d['due'][0] == 'today']
    w5 = framed(todo_window(sel=None, detail='', items=today, filt=filterbar(filters=('Due: Today',)), overlay=p_over),
                'E · Filter: one menu for every filter (open, choosing Due: Today; the list updates as you pick)')
    mine = [d for d in TODOS if d['who'] == 'You' and 'project-x' in d['labels']]
    w6 = framed(todo_window(sel=0, detail=todo_detail(TODOS[0]), items=mine, filt=filterbar(filters=('Person: You', '#project-x'))),
                'F · Two filters set: Filter · 2 and one chip each (× clears it; clicking a chip opens the menu at its section)')
    narrow_f = ('Status: All', 'Due: This week', 'Person: You', '#project-x', '#tea')
    w7 = framed(todo_window(sel=None, detail='', w=890, items=[TODOS[3]], filt=filterbar(filters=narrow_f, sw=160, avail=566)),
                'G · A narrow window (890 pt): still one line; chips that don’t fit collapse into +4 (it opens the Filter panel)')

    W = 560
    due_menu = menu([(None, 'Any time', None, ''), ('cal', 'Overdue', None, ''), ('cal', 'Today', None, 'check'), ('cal', 'This week', None, 'check'),
                     ('cal', 'Next 7 days', None, ''), ('cal', 'No due date', None, ''), 'hr', ('cal', 'Pick dates…', None, '')], 230, 'DUE')
    person_menu = menu([(None, f'<span style="display: inline-flex; align-items: center; gap: 8px">{avatar(*PEOPLE[n], 20)}{full}</span>', f'{c} to-dos', st)
                        for n, full, c, st in [('You', 'You (Jin Liu)', 3, 'check'), ('Mei', 'Mei Tanaka', 2, ''), ('Priya', 'Priya Shah', 1, ''), ('Tom', 'Tom Kim', 0, '')]], 260, 'PEOPLE')
    person_menu = person_menu.replace('<div style="padding: 6px 10px 4px', f'<div style="padding: 4px 4px 6px">{searchbox("", 236, "Find a person")}</div><div style="padding: 6px 10px 4px', 1)
    sort_menu = menu([(None, 'Due date', None, 'check'), (None, 'Source note', None, ''), (None, 'Label', None, ''), (None, 'Person', None, ''), (None, 'Priority', None, ''), (None, 'Created', None, ''), (None, 'No groups', None, ''), 'hr'], 220, 'GROUP BY')
    sort_menu2 = menu([(None, 'Due date, soonest first', None, 'check'), (None, 'Priority, highest first', None, ''), (None, 'Created, newest first', None, ''), (None, 'Title, A to Z', None, ''), 'hr',
                       (None, 'Show completed', 'Last 7 days, greyed', '')], 230, 'SORT')
    more_menu = menu([('note', 'Source note', 'Tea club planning, Auth retry bug…', ''), ('flag', 'Priority', 'High, Medium, Low, None', ''), ('clock', 'Created', 'Today, This week, Pick dates…', ''),
                      ('person', 'Added by', 'Distill or you', ''), ('globe', 'Vault', 'Research, Work notes', '')], 280, 'MORE FILTERS')
    cards = [
        ('Filter menu', f'<div style="display: flex; flex-direction: column; gap: 8px; align-items: flex-start; width: {W}px">{panel(mini_bar(), W)}<div style="margin-left: 176px">{filter_panel(height=520)}</div></div>',
         'One Filter button replaces the row of filter menus. Its panel holds every filter: Status (one choice), Due, Person (with search), Label, Source note, Priority and More (added by, vault, this batch). Long sections show the top 5, then Show all. Choices apply at once; Done closes it, Clear all goes back to Status: Open.'),
        ('Opened from a chip', f'<div style="display: flex; flex-direction: column; gap: 8px; align-items: flex-start; width: {W}px">{panel(mini_bar(filters=("Person: You", "#project-x")), W)}<div style="margin-left: 250px">{filter_panel(scrollTo="person", focus="person", person="You (Jin Liu)", label="#project-x", height=420)}</div></div>',
         'Each active filter is a chip after the button. Clicking a chip opens the panel scrolled to its section; × on the chip clears just that filter. The button counts the chips.'),
        ('Status: All shows a chip', panel(mini_bar(filters=('Status: All',)) + todo_row(TODOS[0]) + todo_row(TODOS[1], mode='done'), W),
         'Status: Open is the default and has no chip. Any other status (Completed, All) appears as a chip like every other filter, and counts in Filter · N.'),
        ('Group and sort', f'<div style="display: flex; gap: 10px; align-items: flex-start">{sort_menu}{sort_menu2}</div>',
         'Group by due date (default), source note, label, person, priority or created; or no groups. Sort applies inside groups. Defaults live in Settings → To-do defaults; changes here are remembered.'),
        ('Search', panel(mini_bar('tin', focus=True) + f'<span style="font-size: 11px; color: {MUTED}; padding: 4px 2px">2 of 6 to-dos match</span>'
                         + todo_row(TODOS[5], hl='tin') + todo_row(TODOS[1]) +
                         f'<div style="font-size: 11px; color: {MUTED}; padding: 0 12px 0 42px; margin-top: -6px">Match in the note excerpt: “…bring the new <mark>tin</mark>.”</div>', W),
         'Search matches titles, notes, people, labels and the quoted excerpt, as you type. A match outside the title shows the line it came from. Esc clears.'),
        ('Add by hand', panel(f'<div style="display: flex; flex-direction: column; gap: 8px; padding: 10px 12px; border-radius: 12px; box-shadow: 0 0 0 2px {BLUE}">'
                              f'<div style="display: flex; align-items: center; gap: 12px">{checkbox()}<span style="font-size: 14px; font-weight: 600">Order more 180 ml kyusu lids{caret(BLUE)}</span></div>'
                              f'<div style="display: flex; align-items: center; gap: 6px; padding-left: 30px">{select("Due: Fri", 100)}{select("Priority: None", 128)}{select("People", 86)}{select("#tea", 74, True)}</div>'
                              f'<div style="display: flex; align-items: center; gap: 8px; padding-left: 30px; font-size: 11px; color: {MUTED}"><span style="flex-grow: 1">↩ adds · Esc cancels · no source note</span>{btn("Add", "primary", 28, 12)}</div></div>'
                              + todo_row(TODOS[1], compact=True) + todo_row(TODOS[4], compact=True), W),
         'Add to-do opens a new row at the top. Only the title is needed. Labels you are filtering by are filled in. Hand-made to-dos say “Added by you” instead of a note link.'),
        ('Edit', f'<div style="width: 330px; height: 426px; background: #FFFFFF; border-radius: 16px; overflow: hidden; display: flex">{todo_detail(editing=True).replace("border-left: 1px solid #ECEAE5;", "").replace("padding: 4px 22px 20px", "padding: 16px 18px")}</div>',
         'The pencil (or double-click, or Return) makes every field editable in place. It saves as you type. To-dos have no AI pass after editing; only drafts for action types do.', 470),
        ('Complete', panel(todo_row(TODOS[0]) + todo_row(TODOS[1], mode='done') + todo_row(TODOS[2]) + f'<div style="margin-top: 14px; display: flex; justify-content: center">{toast("Completed “Book the tasting room for Saturday”", ("Undo",), w=430)}</div>', W),
         'Clicking the circle completes it: struck through for 2 seconds, then it leaves the list and goes to History as Completed. Undo or ⌘Z brings it back. Status → Completed shows them too.'),
        ('Remove', panel(todo_row(TODOS[0]) + todo_row(TODOS[2]) + f'<div style="margin-top: 14px; display: flex; justify-content: center">{toast("Removed “Book the tasting room for Saturday”", ("Undo", "History"), icon="trash", w=470)}</div>', W),
         'Remove (Delete key or the trash) takes it out without asking. Nothing is lost: it goes to History as Removed, where Restore puts it back.'),
        ('Sent to an action type', panel(todo_row(TODOS[1]) + todo_row(TODOS[2]) + f'<div style="margin-top: 14px; display: flex; justify-content: center">{toast("Moved to Jira tickets as a draft", ("Undo", "Open"), icon="send", w=420)}</div>'
                                         + f'<div style="font-size: 11px; color: {MUTED}; padding: 4px 6px; line-height: 1.5">Sidebar: To do goes 6 → 5 and Jira tickets 1 → 2; the Actions total stays 9. The draft keeps the to-do’s context and note link. Sonnet writes the ticket while you look.</div>', W),
         'After Send to, the to-do leaves this list and lives in that action type’s list, following its lifecycle. Undo moves it back unchanged. Open jumps to the new draft.'),
        ('Nothing to do', panel(f'<div style="height: 330px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px; text-align: center">'
                                f'<span style="width: 64px; height: 64px; border-radius: 32px; background: {LIME_BG}; display: flex; align-items: center; justify-content: center">{ic("check", 30, LIME_INK, 2.4)}</span>'
                                f'<span style="{HEAD}; font-weight: 600; font-size: 20px">Nothing to do</span><span style="font-size: 13px; color: {MUTED}; line-height: 1.5; max-width: 340px">When a processed note asks you to do something, Distill adds it here. Done and removed items are in History.</span>'
                                f'<div style="display: flex; gap: 8px; margin-top: 4px">{btn("Add to-do", "primary", 32, 13, "plus")}{btn("History", "secondary", 32, 13, "clock")}</div></div>', W),
         'Empty To do. The sub-item stays; its count disappears. The Actions total still includes drafts waiting in the other sub-items.'),
        ('No match for the filters', panel(mini_bar('kettle', filters=('#tea',)) + f'<div style="height: 280px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px; text-align: center">'
                                           f'{ic("search", 34, "#C9C6BF", 2)}<span style="{HEAD}; font-weight: 600; font-size: 18px">No to-dos match</span><span style="font-size: 13px; color: {MUTED}; max-width: 320px; line-height: 1.5">Nothing open with #tea mentions “kettle”. 1 completed to-do matches.</span>'
                                           f'<div style="display: flex; gap: 8px">{btn("Clear filters", "secondary", 30, 12)}{btn("Show completed", "ghost", 30, 12)}</div></div>', W),
         'Different from empty: it names the filters, offers Clear filters, and says when hidden items (completed) would match.'),
        ('Finding actions after a batch', panel(f'<div style="display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 12px; background: #F2F7FF">{spinner()}<span style="font-size: 13px; font-weight: 600; flex-grow: 1">Finding actions in 2 notes with Sonnet…</span><span style="font-size: 11px; color: {MUTED}">Started at 3:43 PM</span></div>'
                                                + ''.join(f'<div style="display: flex; align-items: center; gap: 12px; padding: 10px 12px">{checkbox()}<div style="display: flex; flex-direction: column; gap: 6px; flex-grow: 1"><span style="height: 12px; width: {w1}%; border-radius: 6px; background: #ECEAE5"></span><span style="height: 8px; width: {w2}%; border-radius: 4px; background: #F2F0EC"></span></div></div>' for w1, w2 in [(70, 40), (55, 46)])
                                                + todo_row(TODOS[0]) + todo_row(TODOS[2]), W),
         'Right after a batch is applied, a strip at the top says which model is reading how many notes, with the start time. New items fade in where they sort; existing ones don’t move. Shimmer rows only stand in for items still coming.'),
        ('First load', panel(''.join(f'<div style="display: flex; align-items: center; gap: 12px; padding: 12px">{checkbox()}<div style="display: flex; flex-direction: column; gap: 6px; flex-grow: 1"><span style="height: 12px; width: {w1}%; border-radius: 6px; background: linear-gradient(90deg, #ECEAE5, #F6F5F2, #ECEAE5)"></span><span style="height: 8px; width: {w2}%; border-radius: 4px; background: #F2F0EC"></span></div><span style="width: 56px; height: 20px; border-radius: 10px; background: #F2F0EC"></span></div>'
                                     for w1, w2 in [(62, 38), (74, 50), (48, 30), (66, 44), (58, 36), (70, 48)]), W),
         'Opening Actions before the core answers shows shimmer rows (the shared loading pattern), never an empty state.'),
        ('Couldn’t find actions', panel(banner('error', 'Couldn’t find actions in Tea club planning', 'Claude Code isn’t signed in. The note itself was added to your vault; only the action step failed.', btn('Try again', 'secondary', 28, 12) + btn('Settings', 'ghost', 28, 12)) + todo_row(TODOS[0]) + todo_row(TODOS[2]), W),
         'Errors say what failed, what is safe, and one next step. Try again reruns only the action step for that note.'),
        ('Sidebar count', sidebar_box('Actions', 'todo', 390),
         '<b>Why “Actions”, not “To do”:</b> the screen holds To do and every action type’s list (Slack messages, Jira tickets, Confluence pages, and later Email). Its sub-items (To do, Slack messages, Jira tickets, Confluence pages) show only while Actions is open, each counting what is waiting on you: open to-dos and drafts ready to copy or create (6 + 1 + 1 + 1). Collapsed, Actions shows the total, 9.'),
    ]
    body = (row(w1, w2) + row(w3, w4) + row(w5, w6) + w7 + section_title('Filters, management and states') + grid(cards, 4))
    intro = ('Distill adds a <b>To do</b> for every action in a processed note that needs you to do something and that no action type can do for you. '
             'To do is the first sub-item of the new <b>Actions</b> sidebar item. Filter by status, due date, person, label, source note, priority and created; search; group and sort; '
             'add, edit, complete, remove, and select several. The sidebar item is called <b>Actions</b>, not To do, because it also holds every action type’s list. <b>Send to</b> hands a to-do to an action type (Jira ticket, Confluence page, Slack message): it leaves this list and lives in that list. '
             'Completed, removed and sent items go to History → Actions, where they can be restored.')
    return board('ActionsTodo.dc.html', 'Actions · To do', 'Actions · To do', intro, body, 2520)


SIZES.update({})




# ================================================================ shared draft card (every action type)
def dcard(t, sub, pill_html, body, ctx='', foot='', top='', overlay='', w=540, h=None, ring=False):
    d = TYPES[t]
    hh = f'height: {h}px;' if h else ''
    rg = f'0 0 0 2px {BLUE}, ' if ring else ''
    return (f'<div style="position: relative; width: {w}px; {hh} box-sizing: border-box; display: flex; flex-direction: column; gap: 12px; padding: 16px 18px; border-radius: 16px; background: #FFFFFF; box-shadow: {rg}0 0 0 1px rgba(29,28,26,.06), 0 10px 24px rgba(29,28,26,.10); overflow: hidden; flex-shrink: 0">'
            f'<div style="display: flex; align-items: center; gap: 10px">{tbadge(t)}<div style="display: flex; flex-direction: column; gap: 1px; flex-grow: 1; min-width: 0">'
            f'<span style="font-size: 11px; font-weight: 800; letter-spacing: .05em; color: {d["ink"]}">{d["name"].upper()}</span><span style="font-size: 13px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{sub}</span></div>{pill_html}{iconbtn("dots", 26)}</div>'
            f'{top}<div style="position: relative; display: flex; flex-direction: column; gap: 10px">{body}{overlay}</div>{ctx}'
            + (f'<div style="display: flex; align-items: center; gap: 8px; margin-top: auto; padding-top: 4px">{foot}</div>' if foot else '') + '</div>')


def later_btn(text):
    return (f'<span title="Coming later" style="height: 32px; display: inline-flex; align-items: center; gap: 7px; padding: 0 14px; border-radius: 16px; border: 1.5px dashed #D6D3CC; color: #B5B1A9; font-size: 13px; font-weight: 600; white-space: nowrap; box-sizing: border-box">'
            f'{ic("send", 13, "#C9C6BF")}{text}<span style="font-size: 10px; font-weight: 700; color: {FAINT}">Later</span></span>')


def paper(inner, editing=False, tint=None):
    sh = f'box-shadow: 0 0 0 2px {BLUE}; background: #FFFFFF' if editing else f'background: {tint or PANEL}'
    return f'<div style="display: flex; flex-direction: column; gap: 4px; padding: 12px 14px; border-radius: 12px; {sh}">{inner}</div>'


def improved_bar(model, what, when='3:51 PM'):
    return (f'<div style="display: flex; align-items: center; gap: 8px; font-size: 11px; color: {MUTED}">{spark(LIME_INK, 11)}<span style="flex-grow: 1">Improved by {model} at {when}: {what}</span>'
            f'<span style="display: inline-flex; align-items: center; gap: 4px; font-weight: 700; color: {BLUE}">{ic("undo", 11, BLUE, 2.4)}Undo ⌘Z</span><span style="font-weight: 700; color: {BLUE}">Show changes</span></div>')


def edited_mark(t):
    return f'<span style="background: {LIME_BG}; box-shadow: 0 0 0 1px {LIME}; border-radius: 3px; padding: 0 1px">{t}</span>'


# ================================================================ SLACK
MSG = 'Hi @Mei, I booked the tasting room for **Saturday at 2 PM**. Could you bring the new 50 g gyokuro tin? The shop recommends 60 °C for the first steep.'
MSG_EDIT = 'Hi @Mei, booked the tasting room for **Saturday at 2 PM** - could you bring the new gyokuro tin and the kyusu to'
MSG_POL = (f'Hi @Mei, {edited_mark("I")} booked the tasting room for **Saturday at 2 PM**{edited_mark(". C")}ould you bring the new gyokuro tin and the kyusu {edited_mark("too?")}')
SL_CTX = dict(note='Tea club planning', when='today at 2:10 PM',
              excerpt='“I’ll book the tasting room for Saturday afternoon and tell Mei so she can bring the new tin.”',
              why='Mei is bringing the tea, so she needs the time. You said you would tell her.')
SL2_CTX = dict(note='Auth retry bug', when='today at 11:20 AM', excerpt='“Let #project-x know we’re capping payment client retries at 3 before Thursday’s deploy.”',
               why='The channel needs a heads-up before the deploy changes retry behaviour.')


ATYPE = {'conf': 'confluence'}


def arow(t, title, source, status, kind='draft', sel=False, hover=False, mode=None, faded=False):
    """ActionRow component (handler lists and History → Actions)."""
    return dc('ActionRow', '100%', '56px', type=ATYPE.get(t, t), title=title, source=source, status=status, statusKind=kind if kind != 'draft' else None,
              selected='true' if sel else None, hover='true' if hover else None, mode=mode, faded='true' if faded else None)


def empty_pane(t, title, sub, primary, secondary=None, h=420):
    """The empty state every Actions tab uses: type tile, one line, one primary action (History beside it)."""
    sec = secondary if secondary is not None else btn('History', 'secondary', 32, 13, 'clock')
    return (f'<div style="height: {h}px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px; text-align: center">{tbadge(t, 56, 18, 26)}'
            f'<span style="{HEAD}; font-weight: 600; font-size: 19px">{title}</span><span style="font-size: 13px; color: {MUTED}; max-width: 360px; line-height: 1.5">{sub}</span>'
            f'<div style="display: flex; gap: 8px; margin-top: 4px">{primary}{sec}</div></div>')


def no_results(what, filters_text):
    return (f'<div style="height: 300px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px; text-align: center">{ic("search", 34, "#C9C6BF", 2)}'
            f'<span style="{HEAD}; font-weight: 600; font-size: 18px">No {what} match</span><span style="font-size: 13px; color: {MUTED}; max-width: 330px; line-height: 1.5">{filters_text}</span>'
            f'<div style="display: flex; gap: 8px">{btn("Clear filters", "secondary", 30, 12)}</div></div>')


COMPLETE_TOAST = lambda w=300: toast('Completed', ('Undo',), w=w)


def connect_btn(state='disconnected', h=32):
    return btn('Connecting…', 'primary', h, 13, None) .replace('title="Connecting…"', 'title="Connecting…" system-image="progress.indicator"') if state == 'connecting' else btn('Connect now', 'primary', h, 13, 'link')


def recipient(kind='person'):
    if kind == 'person':
        return f'<span style="display: inline-flex; align-items: center; gap: 6px">To {avatar("MT", "#FFE0EC", "#A3245A", 18)}<b>Mei Tanaka</b><span style="color: {FAINT}; font-weight: 400">· direct message</span></span>'
    return f'<span style="display: inline-flex; align-items: center; gap: 5px">To {ic("hash", 13, "#A3245A")}<b>project-x</b><span style="color: {FAINT}; font-weight: 400">· channel</span></span>'


def edit_trash():
    return iconbtn('pencil', 30, MUTED, title='Edit') + iconbtn('trash', 30, MUTED, title='Remove') + '<span style="flex-grow: 1"></span>'


def complete_btn(disabled=False):
    return btn('Complete', 'soft', 32, 13, 'check', disabled=disabled)


def slack_foot(copied=False, future=False):
    """Detail footer: edit, remove … Complete (secondary) · primary on the right."""
    c = btn('Copied', 'ok', 32, 13, 'check') if copied else btn('Copy', 'primary', 32, 13, 'copy')
    s = btn('Send in Slack', 'primary', 32, 13, 'send') if future else later_btn('Send in Slack')
    if future:
        c = btn('Copy', 'secondary', 32, 13, 'copy')
        return edit_trash() + complete_btn() + c + s
    return edit_trash() + s + complete_btn() + c


def slack_card(state='ready', w=540, ctx=True, h=None):
    cx = context(**SL_CTX) if ctx else ''
    rp = recipient()
    if state == 'notyet':
        cx2 = context(**SL2_CTX, created='today at 11:24 AM') if ctx else ''
        body = paper(f'<span style="font-size: 13px; color: {MUTED}; line-height: 1.5">Distill found a message to send but hasn’t written it. Slack messages are set to be written only when you ask.</span>')
        return dcard('slack', recipient('channel'), state_pill('muted', 'Not written'), body, cx2, iconbtn('trash', 30, MUTED, title='Remove') + f'<span style="font-size: 11px; color: {MUTED}; flex-grow: 1">Sonnet writes it from the note</span>' + complete_btn() + btn('Create message', 'primary', 32, 13), w=w, h=h)
    if state == 'creating':
        body = paper(''.join(f'<span style="height: 10px; width: {x}%; border-radius: 5px; background: #ECEAE5; margin: 3px 0"></span>' for x in (92, 80, 60)))
        cx2 = context(**SL2_CTX, created='today at 11:24 AM') if ctx else ''
        return dcard('slack', recipient('channel'), state_pill('busy', 'Writing'), body, cx2, edit_trash() + later_btn('Send in Slack') + complete_btn(True) + btn('Copy', 'primary', 32, 13, 'copy', disabled=True),
                     overlay=shimmer_over('Writing with Sonnet…'), w=w, h=h)
    if state == 'editing':
        body = (f'<div style="display: flex; align-items: center; gap: 8px">{STYLEBAR_SM}<span style="flex-grow: 1"></span></div>'
                + paper(md(MSG_EDIT) .replace('</div>', caret(BLUE) + '</div>', 1), editing=True))
        return dcard('slack', rp, state_pill('busy', 'Editing'), body, cx, f'<span style="font-size: 11px; color: {MUTED}; flex-grow: 1">When you click Done (or ⌘↩), Sonnet fixes grammar and spelling.</span>' + btn('Cancel', 'soft', 32, 13) + btn('Done', 'primary', 32, 13), w=w, ring=False, h=h)
    if state == 'polishing':
        body = paper(md(MSG_EDIT))
        return dcard('slack', rp, state_pill('busy', 'Polishing'), body, cx, edit_trash() + later_btn('Send in Slack') + complete_btn(True) + btn('Copy', 'primary', 32, 13, 'copy', disabled=True), overlay=shimmer_over('Polishing with Sonnet…'), w=w, h=h)
    if state == 'polished':
        body = paper(md(MSG_POL)) + improved_bar('Sonnet', 'fixed grammar and punctuation')
        return dcard('slack', rp, state_pill('ready', 'Ready to paste'), body, cx, slack_foot(), w=w, h=h)
    if state == 'copied':
        body = paper(md(MSG))
        top = ''
        foot = slack_foot(copied=True)
        extra = banner('ok', 'Copied. Paste it in Slack.', 'Once it’s posted, mark it as sent so it leaves this list.', btn('Mark as sent', 'primary', 28, 12, 'check') + btn('Not yet', 'soft', 28, 12))
        return dcard('slack', rp, state_pill('ready', 'Copied at 3:52 PM'), body + extra, '', foot, w=w, h=h)
    if state == 'future':
        body = paper(md(MSG))
        return dcard('slack', rp, state_pill('ready', 'Ready to send'), body, '', slack_foot(future=True), w=w, h=h)
    body = paper(md(MSG))
    return dcard('slack', rp, state_pill('ready', 'Ready to paste'), body, cx, slack_foot(), w=w, h=h)


def slack_rows(sel=0, hover=None, gone=None):
    rows = [('Message to Mei Tanaka', 'From Tea club planning · today at 3:44 PM', 'Ready to paste', 'ready'),
            ('Message to #project-x', 'From Auth retry bug · not written yet', 'Not written', 'muted'),
            ('Message to Tom Kim', 'From Q3 architecture sync · copied at 3:52 PM', 'Copied', 'ready')]
    return group_head('Messages', 3 - (gone is not None)) + ''.join(arow('slack', a, b, c, k, sel=(i == sel), hover=(i == hover), faded=(i == gone)) for i, (a, b, c, k) in enumerate(rows))


def list_detail(rows, detail, toast_html=''):
    """Every handler tab: list of ActionRows on the left, the detail pane on the right."""
    t = f'<div style="position: absolute; left: 50%; bottom: 20px; transform: translateX(-50%)">{toast_html}</div>' if toast_html else ''
    return (f'<div style="flex-grow: 1; display: flex; gap: 18px; padding: 0 24px 0 20px; min-height: 0; overflow: hidden; position: relative"><div style="width: 330px; flex-shrink: 0">{rows}</div>'
            f'<div style="flex-grow: 1; min-width: 0; overflow: hidden; padding: 2px 2px 20px">{detail}</div>{t}</div>')


def slack_window(detail=None, sel=0, hover=None, gone=None, toast_html='', empty=None, filters=()):
    head = actions_header('Slack messages', right=btn('History', 'secondary', 34, 13, 'clock')) + f'<div style="padding: 14px 32px 10px">{toolbar("Search messages", filters, sort="Newest first")}</div>'
    if empty is not None:
        return app(head + f'<div style="flex-grow: 1; padding: 0 32px">{empty}</div>', sub='slack')
    return app(head + list_detail(slack_rows(sel, hover, gone), detail if detail is not None else slack_card('ready', 548), toast_html), sub='slack')


def slack_board():
    w1 = framed(slack_window(), 'A · Slack messages: the list on the left, the selected message on the right (primary action Copy, on the right; Complete beside it)')
    stage = lambda x: x
    cards = [
        ('Written when the note is processed', slack_card('ready'), 'Default. The message is ready to paste: recipient, text, and where it came from with the exact lines and why it needs sending. The tab count includes it.'),
        ('Not written yet', slack_card('notyet'), 'When Settings → Actions → Slack message is set to “Only when I ask”, Distill only notes that a message is needed. Create message writes it.'),
        ('Writing', slack_card('creating'), 'Writing names the model and can be cancelled. Copy waits until the text is there. Send in Slack stays a dashed “later” slot.'),
        ('Editing', slack_card('editing'), 'Edit (pencil, or double-click the text) opens the shared Markdown editor with the compact style bar. @mentions and **bold** use Slack’s own marks when copied.'),
        ('Polishing after your edit', slack_card('polishing'), 'Done runs the improve prompt for Slack messages (grammar and spelling, keep your words). The text dims with a shimmer; Cancel keeps your version as is.'),
        ('Polished, with Undo', slack_card('polished'), 'Changed bits are tinted for a few seconds. Undo (⌘Z) returns your exact edit. Show changes lists them. Turn this off per type in Settings.'),
        ('Copied', slack_card('copied'), 'Copy puts the text on the clipboard in Slack format. The button reads Copied for 2 seconds. Copying is not sending, so a prompt asks to mark it as sent.'),
        ('Recipient', f'<div style="position: relative">' + dcard('slack', recipient(), state_pill('ready', 'Ready to paste'), paper(md(MSG)), '', f'<span style="font-size: 12px; color: {MUTED}">Click the recipient in the header to change it.</span>')
                      + f'<div style="position: absolute; left: 70px; top: 56px">{menu([("person", "Mei Tanaka", "Direct message · from the note", "check"), ("person", "Mei Tanaka, Tom Kim", "Group message", ""), ("hash", "#tea-club", "Channel", ""), "hr", ("search", "Someone else…", "Type a name or #channel", "")], 300, "SEND TO")}</div></div>',
         'The person or channel comes from the note. Click it to pick another; Distill doesn’t look anything up in Slack yet, so names are typed freely.'),
        ('Removed', f'<div style="display: flex; flex-direction: column; gap: 14px; align-items: center">{slack_card("ready", ctx=False).replace("position: relative; width: 540px", "position: relative; width: 540px; opacity: .35")}{toast("Removed the message to Mei", ("Undo", "History"), icon="trash", w=420)}</div>',
         'Remove (trash or Delete) takes it out of the list right away. It goes to History → Actions as Removed; Restore puts it back exactly as it was.'),
        ('Completed', f'<div style="display: flex; flex-direction: column; gap: 10px; width: 540px">{panel(slack_rows(0, hover=0) , 540)}<div style="display: flex; justify-content: center">{COMPLETE_TOAST()}</div></div>',
         'Complete (✓ on the row, or in the detail footer) means you’ve handled it, whatever happened in Slack. It leaves the list and goes to History → Actions as Completed, with Restore. Undo in the toast brings it straight back.'),
        ('Marked as sent', f'<div style="display: flex; flex-direction: column; gap: 14px; align-items: center">{slack_card("copied", ctx=False).replace("position: relative; width: 540px", "position: relative; width: 540px; opacity: .35")}{toast("Message to Mei marked as sent", ("Undo", "History"), w=420)}</div>',
         'Mark as sent (also in the ⋯ menu) ends the message’s life here: it leaves the list and goes to History as Sent, with the time you marked it.'),
        ('Later: Send in Slack', slack_card('future'), 'Design for later, not built now: once Slack is connected for sending, the dashed slot becomes a real Send in Slack button and sending moves it to History as Sent automatically. Copy stays.'),
        ('Turned off', panel(f'<div style="height: 330px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px; text-align: center">{tbadge("slack", 56, 18, 26)}<span style="{HEAD}; font-weight: 600; font-size: 19px">Slack messages are off</span>'
                             f'<span style="font-size: 13px; color: {MUTED}; max-width: 340px; line-height: 1.5">Messages to send are added as to-dos instead. Turn them on in Settings → Actions.</span>{btn("Open Settings", "secondary", 32, 13)}</div>', 540),
         'An action type that is turned off has no sub-item. Its actions fall back to To do. This frame shows what a link to an off type opens.'),
    ]
    w2 = framed(slack_window(slack_card('polished', 548), sel=0, hover=2, toast_html=COMPLETE_TOAST()),
                'B · Hover a row: ✓ Complete and ⋯. Here “Message to Tom Kim” was just completed (toast: Completed · Undo); the open one was polished by Sonnet')
    w3 = framed(slack_window(empty=empty_pane('slack', 'No Slack messages to send', 'When a processed note or an Ask answer needs a message, Distill writes it here. You can also send a to-do here from To do.', btn('Open To do', 'primary', 32, 13, 'todo'))),
                'C · Empty: one primary action')
    w4 = framed(slack_window(empty=no_results('messages', 'Nothing ready to paste for #tea-club. 1 copied message matches.'), filters=('Ready to paste', '#tea-club')),
                'D · No results for the filters: Clear filters')
    body = (f'<div style="display: flex; gap: 40px">{w1}{w2}</div>' + f'<div style="display: flex; gap: 40px">{w3}{w4}</div>'
            + section_title('Every state of a Slack message') + grid(cards, 4))
    intro = ('A Slack message is an action Distill can do for you: it writes the message so you only paste it. Today the handler is <b>Copy</b>; <b>Send in Slack</b> is a reserved, disabled slot. '
             'Each message shows who it is for, the text ready to paste, and its context (the note, the quoted lines, and why it needs sending). '
             'Editing uses the shared Markdown editor; when you finish, the AI polishes grammar (Sonnet by default) and you can Undo. Removed and sent messages go to History.')
    return board('ActionsSlack.dc.html', 'Actions · Slack messages', 'Actions · Slack messages', intro, body, 2520)



# ================================================================ JIRA + CONFLUENCE (same lifecycle, different fields)
HLS = 'background: #F3FDE4; box-shadow: 0 0 0 1px #B9F06A; border-radius: 3px'
REMOTE = {
    'jira': dict(
        svc='Jira', site='acme.atlassian.net', btn='Create in Jira', open='Open in Jira', verb='ticket', tab='Jira tickets',
        title='Cap payment client retries at 3 with exponential backoff', sub='PX · Project X · Task',
        fields=[('Project', 'PX · Project X'), ('Type', 'Task'), ('Priority', 'High'), ('Assignee', 'You (Jin Liu)'), ('Labels', 'project-x, retries')],
        body='## Why\nThe INC-212 retry storm came from unbounded payment client retries.\n## What to do\n- Cap retries at 3\n- Exponential backoff from 200 ms, with jitter\n- Log the final failure with the request ID\n## Done when\n[ ] Retries stop after 3 attempts in staging\n[ ] Alert fires above 50 retries a minute',
        body_edit='## Why\nINC-212 retry storm, retries are unbounded\n## What to do\n- cap at 3, backoff 200ms\n- add jitter',
        body_imp=f'## Why\nThe INC-212 retry storm came from <span style="{HLS}">unbounded payment client retries.</span>\n## What to do\n- Cap retries at 3, <span style="{HLS}">with exponential</span> backoff from 200 ms\n- Add jitter\n## Done when\n<span style="{HLS}">Retries stop after 3 attempts in staging</span>',
        key='PX-481', status='To Do', ctx=dict(note='Auth retry bug', when='today at 11:20 AM', excerpt='“Action for me: cap the payment client at 3 retries with exponential backoff before Thursday. Needs a ticket in PX.”',
                                               why='You asked for a ticket in PX. Sent from To do at 3:50 PM.', created='today at 3:50 PM'),
        other=dict(title='Add an alert for retry storms on the auth service', key='PX-482', status='In progress', who='Priya Shah', note='Incident review prep'),
        third=dict(title='Write a runbook entry for payment client timeouts', note='Q3 architecture sync'),
        reject='Jira didn’t create the ticket: Component is required in project PX.', missing='Component',
    ),
    'conf': dict(
        svc='Confluence', site='acme.atlassian.net/wiki', btn='Create in Confluence', open='Open in Confluence', verb='page', tab='Confluence pages',
        title='Incident review: INC-212 auth retry storm', sub='Project X › Incident reviews',
        fields=[('Space', 'Project X'), ('Parent page', 'Incident reviews'), ('Labels', 'incident, retries')],
        body='## Summary\nOn Sep 29 the auth service slowed for 40 minutes because the payment client retried without a limit.\n## Timeline\n- 9:12 AM retries spike to 900 a minute\n- 9:31 AM Priya rolls back the client\n## What we change\n- Cap retries at 3 (PX-481)\n- Alert on retry storms (PX-482)',
        body_edit='## Summary\nauth slow 40 min on sep 29, payment client retried with no limit\n## Timeline\n- 9:12 spike\n- 9:31 rollback',
        body_imp=f'## Summary\n<span style="{HLS}">On Sep 29 the auth service slowed for 40 minutes</span> because the payment client retried with no limit.\n## Timeline\n- 9:12 AM retries spike\n- 9:31 AM <span style="{HLS}">Priya rolls back the client</span>',
        key='Incident review: INC-212', status='Published', ctx=dict(note='Incident review prep', when='today at 1:05 PM', excerpt='“Write up INC-212 in Confluence under Incident reviews before Friday’s review.”',
                                                                    why='The note asks for a page in a named place. Distill can draft it for you.', created='today at 1:12 PM'),
        other=dict(title='On-call handoff checklist', key='On-call handoff checklist', status='Published', who='You', note='Q3 architecture sync'),
        third=dict(title='Tea club: brewing temperatures cheat sheet', note='Gyokuro at 60 °C'),
        reject='Confluence didn’t create the page: a page with this title already exists under Incident reviews.', missing='Title',
    ),
}


def rfields(t, edit=False, bad=None):
    R = REMOTE[t]
    out = ''
    for k, v in R['fields']:
        out += field(k, select(v, 220) if edit else f'<span style="font-size: 13px">{v}</span>')
    if bad:
        out += field(bad, f'<span style="width: 220px; height: 30px; display: inline-flex; align-items: center; gap: 6px; padding: 0 10px; border-radius: 10px; box-sizing: border-box; background: #FFFFFF; box-shadow: 0 0 0 2px {PEACH}; font-size: 12px; font-weight: 600; color: {PEACH_INK}"><span style="flex-grow: 1">Choose a component</span>{ic("down", 11, PEACH_INK, 2.4)}</span>')
    return f'<div style="display: flex; flex-direction: column; gap: 2px">{out}</div>'


def rtitle(t, edit=False, bad=False):
    R = REMOTE[t]
    if edit or bad:
        c = PEACH if bad else BLUE
        return f'<div style="padding: 7px 10px; border-radius: 10px; box-shadow: 0 0 0 2px {c}; {HEAD}; font-weight: 600; font-size: 16px; line-height: 1.3">{R["title"]}{caret(c) if edit else ""}</div>'
    return f'<div style="{HEAD}; font-weight: 600; font-size: 16px; line-height: 1.3">{R["title"]}</div>'


def rfoot(t, disabled=False):
    R = REMOTE[t]
    return edit_trash() + complete_btn(disabled) + btn(R['btn'], 'primary', 32, 13, 'send', disabled=disabled)


def skel(ws):
    return paper(''.join(f'<span style="height: 10px; width: {x}%; border-radius: 5px; background: #ECEAE5; margin: 3px 0"></span>' for x in ws))


def rcard(state='draft', t='jira', w=540, ctx=True, h=None):
    R = REMOTE[t]
    svc = R['svc']
    cx = context(**R['ctx']) if ctx else ''
    body_full = rtitle(t) + rfields(t) + paper(md(R['body'], 12))
    short = rtitle(t) + rfields(t)
    if state == 'draft':
        return dcard(t, R['sub'], state_pill('draft', 'Draft'), body_full, cx, rfoot(t), w=w, h=h)
    if state == 'notyet':
        return dcard(t, R['sub'], state_pill('muted', 'Not written'), rtitle(t) + paper(f'<span style="font-size: 13px; color: {MUTED}; line-height: 1.5">Distill found a {R["verb"]} to create but hasn’t written the draft. Write draft fills in the fields and description from the note; nothing is sent to {svc}.</span>'),
                     cx, iconbtn('trash', 30, MUTED, title='Remove') + f'<span style="font-size: 11px; color: {MUTED}; flex-grow: 1">Sonnet writes it</span>' + complete_btn() + btn('Write draft', 'primary', 32, 13), w=w, h=h)
    if state == 'writing':
        return dcard(t, R['sub'], state_pill('busy', 'Writing'), rtitle(t) + skel((60, 92, 80, 70, 50)), cx, rfoot(t, disabled=True), overlay=shimmer_over('Writing the draft with Sonnet…'), w=w, h=h)
    if state == 'editing':
        b = rtitle(t, True) + rfields(t, True) + STYLEBAR_SM + paper(md(R['body_edit'], 12), editing=True)
        return dcard(t, R['sub'], state_pill('busy', 'Editing'), b, '', f'<span style="font-size: 11px; color: {MUTED}; flex-grow: 1">Done runs the improve prompt with Sonnet. Fields you set are kept.</span>' + btn('Cancel', 'soft', 32, 13) + btn('Done', 'primary', 32, 13), w=w, h=h)
    if state == 'improving':
        return dcard(t, R['sub'], state_pill('busy', 'Improving'), short + paper(md(R['body_edit'], 12)), '', rfoot(t, disabled=True), overlay=shimmer_over('Improving with Sonnet…'), w=w, h=h)
    if state == 'improved':
        return dcard(t, R['sub'], state_pill('draft', 'Draft'), short + paper(md(R['body_imp'], 12)) + improved_bar('Sonnet', 'clearer sentences, added Done when' if t == 'jira' else 'full sentences, times'), '', rfoot(t), w=w, h=h)
    if state == 'creating':
        return dcard(t, R['sub'], state_pill('busy', 'Creating'), body_full, '', rfoot(t, disabled=True), overlay=shimmer_over(f'Creating in {svc}…', cancel=False), w=w, h=h)
    if state in ('created', 'created2'):
        o = R['other'] if state == 'created2' else None
        key = o['key'] if o else R['key']
        status = o['status'] if o else R['status']
        ttl = o['title'] if o else R['title']
        link = (f'<div style="display: flex; align-items: center; gap: 10px; padding: 12px 14px; border-radius: 12px; background: #F2F7FF; box-shadow: 0 0 0 1px #D6E4FB">'
                f'<span style="display: inline-flex; align-items: center; gap: 6px; font-size: 14px; font-weight: 700; color: {BLUE}">{key}{ic("ext", 13, BLUE)}</span><span style="flex-grow: 1"></span>{state_pill("jira", status)}</div>'
                f'<div style="display: flex; align-items: center; gap: 6px; font-size: 11px; color: {MUTED}">{ic("refresh", 11, MUTED)}<span>Status from {svc} at 3:52 PM · <b style="color: {BLUE}">Refresh</b></span><span style="flex-grow: 1"></span>Created today at 3:51 PM</div>')
        b = f'<div style="{HEAD}; font-weight: 600; font-size: 16px; line-height: 1.3">{ttl}</div>' + link
        return dcard(t, R['sub'], state_pill('done', 'Created'), b, cx if not o else '', iconbtn('trash', 30, MUTED, title='Remove') + '<span style="flex-grow: 1"></span>' + complete_btn() + btn(R['open'], 'primary', 32, 13, 'ext'), w=w, h=h)
    if state == 'noconn':
        top = banner('error', f'{svc} isn’t connected', f'Your draft is safe here. Sign in once and Distill can create {R["verb"]}s on {R["site"]}.',
                     btn(f'Sign in to {svc} in your browser', 'primary', 28, 12, 'globe') + btn('Settings', 'ghost', 28, 12))
        return dcard(t, R['sub'], state_pill('error', 'Not created'), short, cx, rfoot(t, disabled=True), top=top, w=w, h=h)
    if state == 'waiting':
        top = banner('wait', 'Waiting for you to sign in, in your browser', f'We opened {R["site"]} in your default browser. Allow Distill there, then come back. This card updates by itself.',
                     btn('Open the page again', 'secondary', 28, 12, 'ext') + btn('Cancel', 'soft', 28, 12))
        return dcard(t, R['sub'], state_pill('busy', 'Signing in'), short, '', rfoot(t, disabled=True), top=top, w=w, h=h)
    if state == 'signedin':
        top = banner('ok', f'Signed in to {svc} as Jin Liu', f'{R["site"]} is connected. Your draft hasn’t been sent yet.', btn('Retry: ' + R['btn'], 'primary', 28, 12, 'send'))
        return dcard(t, R['sub'], state_pill('draft', 'Draft'), short, '', rfoot(t), top=top, w=w, h=h)
    if state == 'expired':
        top = banner('error', f'Your {svc} sign-in expired', 'It expired on Sep 30 at 6:00 PM. Your draft is safe. Sign in again, then retry.',
                     btn('Sign in again in your browser', 'primary', 28, 12, 'globe') + btn('Retry', 'secondary', 28, 12, 'refresh'))
        return dcard(t, R['sub'], state_pill('error', 'Not created'), short, '', rfoot(t, disabled=True), top=top, w=w, h=h)
    if state == 'rejected':
        top = banner('error', R['reject'], 'Nothing was created and your draft is unchanged. Fix the marked field, then retry.', btn('Retry', 'primary', 28, 12, 'refresh'))
        return dcard(t, R['sub'], state_pill('error', 'Not created'), rtitle(t, bad=(t == 'conf')) + rfields(t, bad=R['missing'] if t == 'jira' else None), '', rfoot(t), top=top, w=w, h=h)
    if state == 'offline':
        top = banner('error', f'Couldn’t reach {R["site"]}', 'You might be offline. Nothing was created; the draft is safe.', btn('Retry', 'primary', 28, 12, 'refresh'))
        return dcard(t, R['sub'], state_pill('error', 'Not created'), short, '', rfoot(t), top=top, w=w, h=h)
    raise ValueError(state)


def rrow(t, title, sub, pill_html, sel=False):
    bg = 'background: #F2F7FF; box-shadow: inset 0 0 0 1.5px #BFD5FA' if sel else ''
    return (f'<div style="display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 12px; {bg}">{tbadge(t, 28, 8, 13)}'
            f'<div style="display: flex; flex-direction: column; gap: 3px; flex-grow: 1; min-width: 0"><span style="font-size: 13px; font-weight: 600; line-height: 1.3">{title}</span>'
            f'<span style="font-size: 11px; color: {MUTED}">{sub}</span></div>{pill_html}</div>')


def remote_rows(t, bad=False, hover=None, gone=None):
    R = REMOTE[t]
    o, th = R['other'], R['third']
    created_title = (o['key'] + ' ' + o['title']) if t == 'jira' else o['title']
    return (group_head('Drafts', 2) + arow(t, R['title'], f'From {R["ctx"]["note"]} · created {R["ctx"]["created"]}', 'Not created' if bad else 'Draft', 'error' if bad else 'draft', sel=True)
            + arow(t, th['title'], f'From {th["note"]} · not written yet', 'Not written', 'muted', hover=(hover == 1))
            + group_head(f'Created in {R["svc"]}', 1 - (gone == 2)) + arow(t, created_title, f'Created today at 3:51 PM · {o["status"]} in {R["svc"]}', 'Created', 'created', hover=(hover == 2), faded=(gone == 2)))


def remote_window(t, state='draft', conn=None, empty=None, hover=None, gone=None, toast_html=''):
    R = REMOTE[t]
    bad = state in ('noconn', 'waiting')
    conn = conn or ('disconnected' if bad else 'connected')
    head = (actions_header(R['tab'], right=btn('History', 'secondary', 34, 13, 'clock'))
            + f'<div style="padding: 14px 32px 8px">{toolbar("Search " + R["verb"] + "s", right="connection", conn=conn, sw=180)}</div>')
    if empty is not None:
        return app(head + f'<div style="flex-grow: 1; padding: 0 32px">{empty}</div>', sub='jira' if t == 'jira' else 'confluence')
    return app(head + list_detail(remote_rows(t, bad, hover, gone), rcard(state, t, w=548, ctx=(state == 'draft')), toast_html), sub='jira' if t == 'jira' else 'confluence')


def remote_board(t):
    R = REMOTE[t]
    svc = R['svc']
    w1 = framed(remote_window(t, 'draft'), f'A · {R["tab"]}: drafts you check, and {R["verb"]}s already created')
    w2 = framed(remote_window(t, 'noconn'), f'B · {svc} not connected: Connect now in the toolbar; the draft waits')
    many = R['verb'] + 's'
    w3 = framed(remote_window(t, conn='disconnected', empty=empty_pane(t, f'No {many} yet', f'Connect Atlassian once and Distill can create {many} on {R["site"]} with one click. Drafts from your notes and To do appear here.', connect_btn())),
                f'C · Not connected, no {many} yet: Connect now in the toolbar and in the empty state (it opens Settings → Connections, the token sign-in)')
    w4 = framed(remote_window(t, conn='connecting', empty=empty_pane(t, f'No {many} yet', 'Finish signing in in your browser. This page updates by itself.', connect_btn('connecting'))),
                'D · Connecting: the button shows Connecting… until the sign-in finishes; then the line reads acme.atlassian.net · connected')
    w5 = framed(remote_window(t, 'draft', hover=2, gone=None, toast_html=COMPLETE_TOAST()),
                f'E · Hover a row: ✓ Complete and ⋯, on drafts and created {many} alike. Completing a created one doesn’t change it in {svc} (toast: Completed · Undo)')
    w6 = framed(remote_window(t, conn='connected', empty=no_results(many, f'No drafts in {"PX · Project X" if t == "jira" else "Operations"}. 1 created {R["verb"]} matches.')).replace('placeholder="Search', 'chips="Draft|' + ('PX · Project X' if t == 'jira' else 'Operations') + '" placeholder="Search', 1),
                'F · No results for the filters: Clear filters')
    cap = {
        'draft': f'The draft has the fields {svc} needs, the description in Markdown, and its context. Nothing is in {svc} yet: creating is always a button press, never part of note processing.',
        'notyet': f'With “Write drafts: only when I ask”, the card only says a {R["verb"]} is needed. Write draft fills it in. Send to from To do writes the draft right away.',
        'writing': 'Writing the draft names the model and can be cancelled. Create waits until it’s done.',
        'editing': 'Edit makes the fields pickers and the description the shared Markdown editor with the compact style bar.',
        'improving': f'Done runs the improve prompt for {R["tab"].lower()} (Sonnet by default): clearer text, fills gaps, keeps what you wrote. Cancel keeps your edit.',
        'improved': 'Changes are tinted for a few seconds. Undo (⌘Z) returns your exact edit; Show changes lists them.',
        'creating': f'Create in {svc} sends the draft. The card is locked while it runs; it can’t be cancelled halfway.',
        'created': f'Created: the {R["verb"]} link and its status as {svc} reports it, with the clock time it was checked (never a ticking counter). Refresh checks again. It stays until you complete it (or it’s done there).',
        'noconn': f'Not connected: what failed, that the draft is safe, and one next step. Sign in opens {svc} in your browser; Distill never asks for a password.',
        'waiting': 'While the browser is open the card waits. Open the page again reopens the same sign-in; Cancel goes back to Not connected.',
        'signedin': 'Back from the browser: connected, and Retry finishes what you started.',
        'expired': 'Sign-in expired: the same browser flow, plus Retry in case it was renewed in Settings → Connections.',
        'rejected': f'{svc} refused it: its reason in plain words, and the field to fix is marked.',
        'offline': f'Can’t reach {svc}: nothing was created, the draft is safe, Retry.',
    }
    names = {'draft': 'Draft, written when the note was processed', 'notyet': 'Not written yet', 'writing': 'Writing the draft', 'editing': 'Editing',
             'improving': 'Improving after your edit', 'improved': 'Improved, with Undo', 'creating': f'Creating in {svc}', 'created': f'Created in {svc}',
             'noconn': f'{svc} isn’t connected', 'waiting': 'Signing in, in the browser', 'signedin': 'Signed in → Retry', 'expired': 'Sign-in expired',
             'rejected': f'{svc} refused it', 'offline': f'Can’t reach {svc}'}
    order = ['draft', 'notyet', 'writing', 'editing', 'improving', 'improved', 'creating', 'created', 'noconn', 'waiting', 'signedin', 'expired', 'rejected', 'offline']
    fade = lambda x: x.replace('position: relative; width: 540px', 'position: relative; width: 540px; opacity: .35', 1)
    cards = [(names[k], rcard(k, t), cap[k], 610) for k in order]
    cards += [
        ('Removed', f'<div style="display: flex; flex-direction: column; gap: 14px; align-items: center">{fade(rcard("draft", t, ctx=False))}{toast("Removed the " + R["verb"] + " draft", ("Undo", "History"), icon="trash", w=420)}</div>',
         f'Remove takes a draft out right away; it goes to History → Actions as Removed. Removing a created {R["verb"]} removes it from Distill only, never from {svc}, and the toast says so.', 610),
        ('Completed', f'<div style="display: flex; flex-direction: column; gap: 14px; align-items: center">{fade(rcard("created2", t, ctx=False))}{COMPLETE_TOAST()}</div>',
         f'Complete (✓ on the row, or in the footer) means you’ve handled it. It is not {svc}’s status: an item can still be open in {svc} and be completed here. It goes to History → Actions as Completed, with Restore. When {svc} reports it done{" (status category Done)" if t == "jira" else ""}, it is completed for you.', 610),
    ]
    body = (f'<div style="display: flex; gap: 40px">{w1}{w2}</div>' + f'<div style="display: flex; gap: 40px">{w3}{w4}</div>' + f'<div style="display: flex; gap: 40px">{w5}{w6}</div>'
            + section_title(f'Every state of a {R["verb"]}') + grid(cards, 4))
    if t == 'jira':
        intro = ('Jira tickets are drafts you check, then create with one button. Distill never creates a ticket during note processing. '
                 'A draft comes from a note (written when the note is processed, or when you ask) or from To do → Send to, and shows its context. '
                 'Once created, the ticket keeps its key, link and status from Jira until you complete it here (or it is done there). Sign-in happens in your browser; errors keep the draft safe and offer one next step.')
        return board('ActionsJira.dc.html', 'Actions · Jira tickets', 'Actions · Jira tickets', intro, body, 2520)
    intro = ('Confluence pages follow the same lifecycle as Jira tickets: a draft with space and parent page, Create in Confluence only when you press it, '
             'then a link to the published page until you complete it. Same context, editing with AI improvement and Undo, History, and browser sign-in. '
             'One Atlassian sign-in covers Jira and Confluence on the same site.')
    return board('ActionsConfluence.dc.html', 'Actions · Confluence pages', 'Actions · Confluence pages', intro, body, 2520)




# ================================================================ HISTORY → Actions
OUT = {'Removed': 'removed', 'Completed': 'completed', 'Sent': 'sent', 'Created': 'created', 'Dismissed': 'dismissed'}
HIST = [
    ('Today', 'slack', 'Message to #project-x about retries', 'Removed', 'today at 4:02 PM', True),
    ('Today', 'todo', 'Book the tasting room for Saturday', 'Completed', 'today at 3:58 PM', True),
    ('Today', 'jira', 'PX-482 Add an alert for retry storms', 'Completed', 'by you today at 3:55 PM · still In progress in Jira', True),
    ('Today', 'todo', 'Cap payment client retries at 3 with backoff', 'Sent', 'to Jira tickets today at 3:50 PM', False),
    ('Yesterday', 'slack', 'Message to Mei about the kyusu', 'Sent', 'marked as sent yesterday at 6:12 PM', False),
    ('Yesterday', 'conf', 'On-call handoff checklist', 'Completed', 'by you yesterday at 5:40 PM', True),
    ('Sep 30', 'todo', 'Order tasting cups for the club', 'Removed', 'Sep 30 at 9:14 AM', True),
]


def hrow(t, title, outcome, line, restorable, sel=False, hover=False):
    return arow(t, title, line, outcome, OUT[outcome], sel=sel, hover=hover and restorable, mode='history')


def hist_list(sel=0, rows=HIST, hover=None):
    out, last = '', None
    for i, (g, t, title, oc, line, rs) in enumerate(rows):
        if g != last:
            out += f'<div style="padding: 8px 10px 2px; font-size: 10px; font-weight: 800; letter-spacing: .06em; color: {FAINT}">{g.upper()}</div>'
            last = g
        out += hrow(t, title, oc, line, rs, i == sel, i == hover)
    return out


def timeline(steps):
    out = ''
    for i, (txt, when, kind) in enumerate(steps):
        dot = {'done': LIME_INK, 'now': BLUE, 'end': PEACH_INK}[kind]
        lineh = '' if i == len(steps) - 1 else f'<span style="position: absolute; left: 5px; top: 16px; bottom: -6px; width: 2px; background: {LINE}"></span>'
        out += (f'<div style="position: relative; display: flex; gap: 12px; padding-bottom: 12px">{lineh}<span style="width: 12px; height: 12px; border-radius: 6px; background: {dot}; margin-top: 3px; flex-shrink: 0"></span>'
                f'<div style="display: flex; flex-direction: column; gap: 1px"><span style="font-size: 13px; font-weight: 600">{txt}</span><span style="font-size: 11px; color: {MUTED}">{when}</span></div></div>')
    return f'<div style="display: flex; flex-direction: column">{out}</div>'


def hist_window(sel=0, detail='', hover=None):
    left = (f'<div style="width: 370px; flex-shrink: 0; border-right: 1px solid {LINE}; padding: 26px 16px; box-sizing: border-box; display: flex; flex-direction: column; gap: 12px; overflow: hidden">'
            f'<div style="display: flex; flex-direction: column; gap: 2px"><span style="font-size: 11px; font-weight: 800; letter-spacing: .06em; color: {FAINT}">HISTORY</span><span style="{HEAD}; font-weight: 800; font-size: 28px">Actions</span></div>'
            f'{toolbar("Search history", right="none", sw=200, avail=338)}'
            f'<div style="display: flex; flex-direction: column; gap: 1px">{hist_list(sel, hover=hover)}</div></div>')
    return app(f'<div style="display: flex; height: 100%">{left}<div style="flex-grow: 1; min-width: 0; display: flex; flex-direction: column; gap: 14px; padding: 26px 30px; box-sizing: border-box; overflow: hidden">{detail}</div></div>', active='History', sub='actions')


def hist_detail_removed():
    card_html = dcard('slack', recipient('channel'), pill('Removed', '#FFE4D6', PEACH_INK, 22, 11, 700),
                      paper(md('Heads-up @here: we’re capping payment client retries at **3** with exponential backoff. It ships with Thursday’s deploy; PX-481 has the details.', 12)), context(**SL2_CTX, created='today at 11:24 AM'), '', w=500)
    return (f'<span style="font-size: 12px; color: {MUTED}">Removed today at 4:02 PM from Slack messages</span>' + card_html
            + timeline([('Found in Auth retry bug by Sonnet', 'Today at 11:24 AM', 'done'), ('Written with Sonnet', 'Today at 11:25 AM', 'done'), ('Removed by you', 'Today at 4:02 PM', 'end')])
            + f'<div style="display: flex; align-items: center; gap: 10px; margin-top: auto">{btn("Restore", "primary", 36, 13, "restore")}<span style="font-size: 12px; color: {MUTED}; flex-grow: 1">Puts it back in Slack messages exactly as it was.</span>{btn("Delete forever", "danger", 36, 13)}</div>')


def hist_detail_sent():
    return (f'<span style="font-size: 12px; color: {MUTED}">Sent to Jira tickets today at 3:50 PM</span>'
            + f'<div style="display: flex; align-items: center; gap: 10px">{tbadge("todo")}<span style="{HEAD}; font-weight: 600; font-size: 18px">Cap payment client retries at 3 with backoff</span></div>'
            + context('Auth retry bug', 'today at 11:20 AM', '“Action for me: cap the payment client at 3 retries with exponential backoff before Thursday. Needs a ticket in PX.”', 'You assigned it to yourself.', created='today at 11:24 AM')
            + f'<span style="font-size: 12px; font-weight: 700; margin-top: 4px">What happened</span>'
            + timeline([('To-do found in Auth retry bug', 'Today at 11:24 AM', 'done'), ('Sent to Jira tickets', 'Today at 3:50 PM · draft written by Sonnet', 'done'),
                        ('Created PX-481 in Jira', 'Today at 3:51 PM', 'done'), ('Open in Jira: To Do', 'Status from Jira at 3:52 PM', 'now')])
            + f'<div style="display: flex; align-items: center; gap: 10px; margin-top: auto">{btn("Open in Jira tickets", "secondary", 36, 13, "jira")}<span style="font-size: 12px; color: {MUTED}">No Restore here: it lives on as PX-481. To undo the send, remove the draft before it is created.</span></div>')


def history_board():
    w1 = framed(hist_window(0, hist_detail_removed(), hover=2), 'A · History → Actions: a removed message open; hovering a completed ticket shows Restore and ⋯')
    w2 = framed(hist_window(3, hist_detail_sent()), 'B · A sent to-do: its whole path, and where it lives now')
    what = menu([(None, 'Everything', None, 'check'), (None, 'Completed', 'Handled: any type, by you', ''), (None, 'Removed', 'Can be restored', ''), (None, 'Sent', 'To-dos handed to an action type', ''),
                 (None, 'Created', 'Jira and Confluence items created', ''), (None, 'Dismissed', 'Found but not added', '')], 270, 'OUTCOME')
    W = 540
    wbar = panel('<div style="display: flex; gap: 6px">' + toolbar('Search history', ('Removed',), right='none', sw=160, avail=510) + '</div>', W)
    jobs = panel(f'<div style="display: flex; flex-direction: column; gap: 6px; padding: 4px">'
                 f'<span style="font-size: 12px; color: {MUTED}">Jobs · Finished today at 3:44 PM</span><span style="{HEAD}; font-weight: 600; font-size: 17px">Tea club planning, Auth retry bug</span>'
                 f'<span style="font-size: 12px; color: #48463F">2 notes · 1 new page · 4 files updated</span>'
                 f'<div style="display: flex; align-items: center; gap: 8px; padding: 10px 12px; border-radius: 12px; background: #F2F7FF; margin-top: 6px">{ic("actions", 15, BLUE)}<span style="font-size: 13px; font-weight: 600; flex-grow: 1">Found 3 to-dos, 1 Slack message, 1 Jira ticket</span><span style="font-size: 12px; font-weight: 700; color: {BLUE}">Open in Actions</span></div></div>', W)
    cards = [
        ('Filter: what happened', f'<div style="display: flex; flex-direction: column; align-items: flex-start; gap: 8px; width: {W}px">{wbar}<div style="margin-left: 170px">{what}</div></div>',
         'The same single Filter menu as To do, with its own sections: WHAT happened (shown), TYPE, SOURCE NOTE and WHEN (today, this week, pick dates). Each set filter is a chip after the button (here “Removed ×”). Search covers titles, text and notes.'),
        ('Restored', panel(hist_list(1, HIST[1:4]) + f'<div style="display: flex; justify-content: center; margin-top: 10px">{toast("Restored to Slack messages", ("Open",), icon="restore", w=360)}</div>', W),
         'Restore (on row hover, or in the detail) puts a removed or completed item back in the list it came from, with its text, edits and context. Its History entry goes away.'),
        ('Restore when the note is gone', panel(banner('error', 'Restored without its note link', 'The note Auth retry bug was deleted from your vault after this was found. The quoted lines are kept.', btn('OK', 'secondary', 28, 12))
                                                + hist_list(2, HIST[2:5]), W),
         'Restoring never fails because of what changed since. It says what is missing and keeps what it can.'),
        ('Restore when the type is off', panel(banner('info', 'Slack messages are turned off', 'Restore this as a to-do instead, or turn Slack messages on.', btn('Restore as a to-do', 'primary', 28, 12) + btn('Open Settings', 'ghost', 28, 12)) + hist_list(0, HIST[0:3]), W),
         'If the item’s action type was turned off, it can come back as a to-do so nothing is stranded.'),
        ('Delete forever', panel(f'<div style="height: 330px; display: flex; align-items: center; justify-content: center"><div style="width: 360px; display: flex; flex-direction: column; gap: 10px; padding: 20px; border-radius: 16px; background: #FFFFFF; box-shadow: 0 0 0 1px {LINE}, 0 14px 32px rgba(29,28,26,.18)">'
                                 f'<span style="{HEAD}; font-weight: 600; font-size: 17px">Delete this forever?</span><span style="font-size: 13px; color: #48463F; line-height: 1.5">The message to #project-x can’t be restored after this. The note stays in your vault.</span>'
                                 f'<div style="display: flex; justify-content: flex-end; gap: 8px; margin-top: 6px">{btn("Cancel", "soft", 32, 13)}{btn("Delete forever", "primary", 32, 13, extra="background: #B03A0A; box-shadow: none")}</div></div></div>', W),
         'The only step in Actions that asks first, because it can’t be undone.'),
        ('Nothing in History yet', panel(empty_pane('todo', 'Nothing here yet', 'Completed, removed and sent actions show up here, so you can see what happened and bring things back.', btn('Open To do', 'primary', 32, 13, 'todo'), '', 330), W),
         'Empty History → Actions: one primary action, like every Actions tab.'),
        ('No results for the filters', panel(toolbar('Search history', ('Dismissed', 'This week'), right='none', sw=160, avail=510) + no_results('actions', 'Nothing dismissed this week. 4 dismissed actions are older.'), W),
         'The same toolbar and Filter menu as every Actions tab (Type, Outcome, Date, Source). Clear filters goes back to everything.'),
        ('Jobs link to what they found', jobs, 'History → Jobs: each finished job says what actions it found and links to them, filtered to that job’s notes.'),
        ('How long History keeps items', panel(f'<div style="display: flex; flex-direction: column; gap: 10px; padding: 6px">'
                                               f'<span style="font-size: 13px; font-weight: 700">Keep action history</span>{seg(["30 days", "90 days", "1 year", "Forever"], "90 days")}'
                                               f'<span style="font-size: 12px; color: {MUTED}; line-height: 1.5">Settings → To-do defaults. Older entries are cleared once a day. Restorable items show the day they’ll be cleared (“Kept until Dec 29”).</span></div>', W),
         'Retention is a setting (90 days by default). Items are never cleared silently while you are looking at them.'),
    ]
    body = f'<div style="display: flex; gap: 40px">{w1}{w2}</div>' + section_title('Filters, restore and edge cases') + grid(cards, 4)
    intro = ('Everything that leaves an Actions list lands in <b>History → Actions</b>, a third sub-item under History, next to Jobs and Ask chats: completed items of every type (to-dos, messages, tickets, pages), removed items, to-dos sent to another type, '
             'and Slack messages marked as sent. It uses the same toolbar and rows as the other Actions tabs. Times are clock times. <b>Restore</b> brings removed and completed items back to the list they came from. '
             'Sent items show their path and link to where they live now.')
    return board('ActionsHistory.dc.html', 'Actions · History', 'Actions · History', intro, body, 2520)


# ================================================================ OVERVIEW
def box(inner, w=None, bg='#FFFFFF', ring=LINE, pad='14px 16px', dashed=False):
    ww = f'width: {w}px;' if w else ''
    b = f'border: 1.5px dashed #C9C6BF' if dashed else f'box-shadow: 0 0 0 1px {ring}'
    return f'<div style="{ww} box-sizing: border-box; padding: {pad}; border-radius: 16px; background: {bg}; {b}; display: flex; flex-direction: column; gap: 6px">{inner}</div>'


def arrow(w=60, label_text=''):
    l = f'<span style="position: absolute; top: -18px; left: 0; right: 0; text-align: center; font-size: 10px; font-weight: 700; color: {FAINT}; white-space: nowrap">{label_text}</span>' if label_text else ''
    return (f'<div style="position: relative; width: {w}px; flex-shrink: 0; align-self: center">{l}<svg width="{w}" height="14" viewBox="0 0 {w} 14" aria-hidden="true"><path d="M0 7h{w - 6}" stroke="#B5B1A9" stroke-width="2"/><path d="M{w - 8} 2l6 5-6 5" fill="none" stroke="#B5B1A9" stroke-width="2" stroke-linejoin="round"/></svg></div>')


def chip_h(text, kind='now'):
    if kind == 'now':
        return pill(text, LIME_BG, LIME_INK, 22, 11, 700, f'box-shadow: inset 0 0 0 1px {LIME}')
    if kind == 'btn':
        return pill(text, TINT, BLUE, 22, 11, 700)
    return pill(text + ' · later', '#FFFFFF', FAINT, 22, 11, 700, 'border: 1.5px dashed #D6D3CC')


def overview_board():
    # A · pipeline
    note = box(f'<span style="font-size: 10px; font-weight: 800; letter-spacing: .06em; color: {FAINT}">1 · NOTE PROCESSED</span><span style="{HEAD}; font-weight: 600; font-size: 17px">Tea club planning</span>'
               f'<span style="font-size: 12px; color: {MUTED}">Batch applied today at 3:44 PM</span>'
               + quote('“I’ll book the tasting room for Saturday afternoon and tell Mei so she can bring the new tin.”'), 360)
    asks = box(f'<span style="font-size: 10px; font-weight: 800; letter-spacing: .06em; color: {FAINT}">1 · OR AN ASK ANSWER</span><span style="{HEAD}; font-weight: 600; font-size: 17px">What do I still owe before Friday?</span>'
               f'<span style="font-size: 12px; color: {MUTED}">Answered today at 3:12 PM, main window or quick ask</span>', 360, bg='#F2F7FF', ring='#D6E4FB')
    sources = f'<div style="display: flex; flex-direction: column; gap: 14px">{note}{asks}</div>'
    confirm = box(f'<span style="font-size: 10px; font-weight: 800; letter-spacing: .06em; color: {FAINT}">4 · YOU CONFIRM</span><span style="{HEAD}; font-weight: 600; font-size: 17px">Add or dismiss</span>'
                  f'<span style="font-size: 12px; color: {MUTED}; line-height: 1.5">On by default for both sources. Turn it off per source in Settings and items are added right away, with Undo.</span>', 250, bg='#FFFFFF', ring=LINE)
    find = box(f'<span style="font-size: 10px; font-weight: 800; letter-spacing: .06em; color: {FAINT}">2 · FIND ACTIONS</span><span style="display: flex; align-items: center; gap: 8px; {HEAD}; font-weight: 600; font-size: 17px">{spark(LIME_INK, 16)}Sonnet reads it</span>'
               f'<span style="font-size: 12px; color: {MUTED}; line-height: 1.5">New and changed notes after Approve, or a finished answer. Each action gets a title, people, due date, the quoted lines and why it matters.</span>', 300, bg='#FBFFF4', ring='#DDF5B8')
    match = box(f'<span style="font-size: 10px; font-weight: 800; letter-spacing: .06em; color: {FAINT}">3 · MATCH TO AN ACTION TYPE</span><span style="{HEAD}; font-weight: 600; font-size: 17px">Can Distill do it?</span>'
                f'<span style="font-size: 12px; color: {MUTED}; line-height: 1.5">Each type says what it recognizes. If a type that is on matches, it becomes that type. Otherwise it’s a to-do.</span>', 300)

    def outbox(t, n, extra, later=False):
        d = TYPES[t]
        return box(f'<div style="display: flex; align-items: center; gap: 10px">{tbadge(t, 30)}<div style="display: flex; flex-direction: column; flex-grow: 1"><span style="font-size: 14px; font-weight: 700">{d["many"]}</span><span style="font-size: 11px; color: {MUTED}">{extra}</span></div>'
                   f'<span style="{HEAD}; font-weight: 800; font-size: 22px; color: {"#C9C6BF" if later else d["ink"]}">{n}</span></div>', 380, dashed=later, pad='10px 14px')
    outs = (f'<div style="display: flex; flex-direction: column; gap: 10px">'
            + outbox('todo', '3', 'Needs you · the catch-all') + outbox('slack', '1', 'To Mei · written now, ready to copy')
            + outbox('jira', '1', 'PX draft · created only when you press Create') + outbox('conf', '0', 'Pages to write in Confluence')
            + outbox('mail', '–', 'Coming later: a new type is one more row', later=True) + '</div>')
    fan = ('<svg width="70" height="300" viewBox="0 0 70 300" aria-hidden="true" style="flex-shrink: 0; align-self: center">'
           + ''.join(f'<path d="M0 150 C 35 150, 35 {y}, 64 {y}" fill="none" stroke="{"#D6D3CC" if y == 274 else "#B5B1A9"}" stroke-width="2" {"stroke-dasharray=\"4 4\"" if y == 274 else ""}/><path d="M58 {y - 5}l6 5-6 5" fill="none" stroke="#B5B1A9" stroke-width="2"/>' for y in (26, 88, 150, 212, 274))
           + '</svg>')
    pipeline = f'<div style="display: flex; align-items: center; justify-content: center; gap: 0; padding: 30px 32px; border-radius: 24px; background: #FFFFFF; box-shadow: 0 0 0 1px {LINE}">{sources}{arrow(70, "new text")}{find}{arrow(50)}{match}{arrow(50)}{confirm}{fan}{outs}</div>'

    # B · registry
    cols = ['Action type', 'Recognizes', 'Fields', 'Draft written', 'Create prompt', 'Improve prompt (after you edit)', 'Handlers', 'Lifecycle']
    rows = [
        ('todo', 'Anything you must do that no other type can do', 'Title, due, priority, people, labels', 'Always, with the note', '“Turn the action into a short, specific to-do…”', '—  (to-dos are edited by hand)',
         chip_h('Complete') + chip_h('Send to…', 'btn'), 'Open → Completed / Removed / Sent'),
        ('slack', 'A message someone should get', 'To (person or channel), text', 'On processing (default) or when you ask', '“Write a short Slack message to {recipient}…”', '“Fix grammar and spelling; keep their words…”',
         chip_h('Copy') + chip_h('Send in Slack', 'later'), 'Written → Copied → Marked as sent'),
        ('jira', 'Work to track in a Jira project', 'Project, type, summary, description, priority, assignee, labels', 'On processing (default) or when you ask', '“Draft a Jira ticket with Why / What / Done when…”', '“Tighten the wording, fill gaps, keep their fields…”',
         chip_h('Create in Jira', 'btn') + chip_h('Open in Jira'), 'Draft → Creating → Created (status from Jira) → Done'),
        ('conf', 'A write-up that belongs in Confluence', 'Space, parent page, title, body, labels', 'On processing (default) or when you ask', '“Draft a Confluence page with Summary / Timeline…”', '“Make it read cleanly; keep their structure…”',
         chip_h('Create in Confluence', 'btn') + chip_h('Open in Confluence'), 'Draft → Creating → Created → Done'),
        ('mail', 'An email someone should get', 'To, subject, body', '—', 'Default prompt ships with the type', 'Default prompt ships with the type',
         chip_h('Copy', 'later') + chip_h('Open in Mail', 'later'), 'Same as Slack'),
    ]
    th = ''.join(f'<th style="text-align: left; padding: 10px 12px; font-size: 10px; font-weight: 800; letter-spacing: .05em; color: {FAINT}; border-bottom: 1px solid {LINE}">{c.upper()}</th>' for c in cols)
    trs = ''
    for t, *cells in rows:
        later = t == 'mail'
        name = (f'<div style="display: flex; align-items: center; gap: 10px; {"opacity: .55" if later else ""}">{tbadge(t, 28, 8, 14)}<div style="display: flex; flex-direction: column"><span style="font-size: 13px; font-weight: 700">{TYPES[t]["name"]}</span>'
                + (f'<span style="font-size: 10px; font-weight: 700; color: {FAINT}">COMING LATER</span>' if later else (f'<span style="font-size: 10px; font-weight: 700; color: {BLUE}">CATCH-ALL</span>' if t == 'todo' else '')) + '</div></div>')
        tds = ''.join(f'<td style="padding: 12px; font-size: 12px; line-height: 1.45; color: {"#B5B1A9" if later else "#48463F"}; vertical-align: top; border-bottom: 1px solid {LINE}">{c}</td>' for c in cells[:-2])
        tds += f'<td style="padding: 12px; vertical-align: top; border-bottom: 1px solid {LINE}"><div style="display: flex; flex-wrap: wrap; gap: 5px">{cells[-2]}</div></td>'
        tds += f'<td style="padding: 12px; font-size: 12px; color: {"#B5B1A9" if later else "#48463F"}; vertical-align: top; border-bottom: 1px solid {LINE}">{cells[-1]}</td>'
        trs += f'<tr style="{"background: repeating-linear-gradient(135deg, #FFFFFF 0 10px, #FAF9F7 10px 20px)" if later else ""}"><td style="padding: 12px; vertical-align: top; border-bottom: 1px solid {LINE}">{name}</td>{tds}</tr>'
    legend = (f'<div style="display: flex; align-items: center; gap: 14px; font-size: 12px; color: {MUTED}">{chip_h("Works now")}<span>a handler you can use today</span>{chip_h("Needs a press", "btn")}<span>reaches out to another app, only on your click</span>'
              f'{chip_h("Send in Slack", "later")}<span>reserved slot, shown disabled</span></div>')
    registry = (f'<div style="padding: 24px 28px; border-radius: 24px; background: #FFFFFF; box-shadow: 0 0 0 1px {LINE}; display: flex; flex-direction: column; gap: 14px">'
                f'<table style="border-collapse: collapse; width: 100%"><thead><tr>{th}</tr></thead><tbody>{trs}</tbody></table>{legend}</div>')

    # C · lifecycle
    def node(t, sub='', kind='plain'):
        bg = {'plain': '#FFFFFF', 'end': LIME_BG, 'hist': PANEL}[kind]
        return f'<div style="padding: 9px 13px; border-radius: 12px; background: {bg}; box-shadow: 0 0 0 1px {LINE}; display: flex; flex-direction: column; gap: 2px; flex-shrink: 0"><span style="font-size: 13px; font-weight: 700; white-space: nowrap">{t}</span>' + (f'<span style="font-size: 11px; color: {MUTED}; white-space: nowrap">{sub}</span>' if sub else '') + '</div>'
    lane = lambda lab, inner: f'<div style="display: flex; align-items: center; gap: 0"><span style="width: 150px; flex-shrink: 0; display: flex; align-items: center; gap: 8px; font-size: 12px; font-weight: 700">{lab}</span>{inner}</div>'
    life = (f'<div style="display: flex; flex-direction: column; gap: 22px; padding: 28px 32px; border-radius: 24px; background: #FFFFFF; box-shadow: 0 0 0 1px {LINE}">'
            + lane(tbadge('todo', 24, 7, 12) + 'To do', node('Open', 'found or added by hand') + arrow(60, 'Complete') + node('Completed', '', 'end') + arrow(60) + node('History', 'Restore → Open', 'hist')
                   + f'<span style="width: 40px"></span>' + node('Open') + arrow(80, 'Send to ▾') + node('Leaves To do', 'becomes a draft of that type') + arrow(60) + node('History: Sent', 'links to where it lives', 'hist'))
            + lane(tbadge('slack', 24, 7, 12) + 'Slack message', node('Not written', 'if “only when I ask”') + arrow(60, 'Create') + node('Ready to paste') + arrow(60, 'Edit') + node('Polished', 'Undo available') + arrow(60, 'Copy') + node('Copied') + arrow(80, 'Mark as sent') + node('History: Sent', '', 'hist'))
            + lane(tbadge('jira', 24, 7, 12) + 'Jira / Confluence', node('Draft') + arrow(60, 'Edit') + node('Improved', 'Undo available') + arrow(80, 'Create in Jira') + node('Creating') + arrow(60) + node('Created', 'key, link, status') + arrow(80, 'Complete') + node('History: Completed', 'Jira status unchanged', 'hist'))
            + lane(f'<span style="width: 24px"></span>Complete', node('Ready · Created · Sent', 'any handler item') + arrow(80, '✓ Complete') + node('History: Completed', 'you’ve handled it', 'hist') + arrow(70, 'Restore') + node('Back where it was')
                   + f'<span style="font-size: 12px; color: {MUTED}; max-width: 320px; line-height: 1.45; margin-left: 16px">Complete is yours, not the service’s: it works from ready, created and sent, and never changes the item’s status in Jira, Confluence or Slack.</span>')
            + lane(f'<span style="width: 24px"></span>Any item', node('Any state') + arrow(70, 'Remove') + node('History: Removed', 'kept 90 days', 'hist') + arrow(70, 'Restore') + node('Back where it was'))
            + lane(f'<span style="width: 24px"></span>Errors', node('Not connected / expired / refused / offline', 'draft stays safe') + arrow(110, 'Sign in in browser') + node('Signed in') + arrow(60, 'Retry') + node('Creating'))
            + '</div>')

    # D · where actions first appear
    steps = ''.join(f'<div style="display: flex; align-items: center; gap: 10px; padding: 6px 0"><span style="width: 18px; height: 18px; border-radius: 9px; background: {c}; color: #FFFFFF; font-size: 11px; font-weight: 700; display: flex; align-items: center; justify-content: center">{m}</span><span style="font-size: 13px; color: {fg}">{t}</span></div>'
                    for t, c, m, fg in [('Moved 2 files to inbox', LIME_INK, '✓', INK), ('Read sources and existing pages', LIME_INK, '✓', INK), ('Applied 5 page changes', LIME_INK, '✓', INK),
                                        ('Finding actions in 2 notes · Sonnet', BLUE, '…', INK), ('Ready', '#D6D3CC', '', FAINT)])
    W = 560
    f1 = panel(f'<span style="font-size: 12px; color: {MUTED}">Queue · batch running · started at 3:41 PM</span><span style="{HEAD}; font-weight: 600; font-size: 18px">Reading 2 sources into Research</span>{steps}', W)
    f2 = panel(f'<span style="align-self: flex-start; font-size: 12px; font-weight: 700; color: {LIME_INK}; background: {LIME_BG}; padding: 4px 10px; border-radius: 12px">Applied at 3:44 PM</span>'
               f'<span style="{HEAD}; font-weight: 800; font-size: 24px; letter-spacing: -.02em">Tea club planning</span>'
               f'<div style="display: flex; gap: 8px">' + ''.join(f'<div style="flex-grow: 1; display: flex; align-items: center; gap: 8px; padding: 10px 12px; border-radius: 14px; background: {bg}"><span style="{HEAD}; font-weight: 800; font-size: 22px; color: {ink}">{n}</span><span style="font-size: 12px; font-weight: 600">{l}</span></div>'
                                                               for n, l, bg, ink in [('1', 'new page', '#E9FBC9', LIME_INK), ('5', 'files updated', TINT, BLUE)]) + '</div>'
               f'<div style="display: flex; align-items: center; gap: 10px; padding: 12px 14px; border-radius: 14px; background: #F2F7FF; box-shadow: 0 0 0 1px #D6E4FB">{ic("actions", 16, BLUE)}<div style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1"><span style="font-size: 13px; font-weight: 700">Found 5 actions to confirm</span><span style="font-size: 11px; color: {MUTED}">3 to-dos, 1 Slack message, 1 Jira ticket</span></div>{btn("Review them", "primary", 30, 12)}</div>', W)
    f3 = panel(f'<div style="display: flex; align-items: center; gap: 10px; padding: 12px 14px; border-radius: 14px; background: {INK}; color: #FFFFFF">{ic("actions", 16, "#B9F06A")}<span style="font-size: 13px; font-weight: 600; flex-grow: 1">5 actions to confirm from Tea club planning</span><span style="font-size: 12px; font-weight: 700; color: #8FB8FF">Open</span></div>'
               f'<span style="font-size: 12px; color: {MUTED}; line-height: 1.5; padding: 4px">If Distill isn’t the front window, the same line appears as a macOS notification (only when something was found). The Actions sidebar count goes up by the number of open items.</span>'
               + sidebar_box('Queue', '', 260), W)
    f4 = panel(f'<span style="font-size: 12px; color: {MUTED}">History → Jobs · Finished today at 3:44 PM</span><span style="{HEAD}; font-weight: 600; font-size: 18px">Tea club planning, Auth retry bug</span>'
               f'<div style="display: flex; align-items: center; gap: 8px; padding: 10px 12px; border-radius: 12px; background: #F2F7FF">{ic("actions", 15, BLUE)}<span style="font-size: 13px; font-weight: 600; flex-grow: 1">Found 3 to-dos, 1 Slack message, 1 Jira ticket</span><span style="font-size: 12px; font-weight: 700; color: {BLUE}">Open in Actions</span></div>'
               f'<span style="font-size: 12px; color: {MUTED}; line-height: 1.5">Open in Actions filters the lists to that job’s notes.</span>', W)
    appear = grid([('In the batch steps', f1, 'Finding actions is the last step of a batch, after the changes are applied. It names the model and the number of notes.', 400),
                   ('On the finished job', f2, 'The Review screen, once applied, ends with one line counting what was found, with Review them (opens Actions on “To confirm”). With confirmation off it says “Added …” and Open in Actions.', 400),
                   ('Toast, notification and sidebar count', f3, 'A short toast (or a notification in the background). Nothing pops up when nothing was found.', 400),
                   ('History → Jobs', f4, 'The job entry keeps the same line, so you can find the actions later.', 400)], 4)

    body = (section_title('How it works', 'Actions come from two sources: notes processed into the wiki, and Ask answers. Distill reads the new text, matches each action to an action type, and asks you to confirm (default). Whatever no type can do becomes a to-do.') + pipeline
            + section_title('Action types are a registry', 'Each type declares what it recognizes, its fields, when its draft is written, a default create prompt and a different default improve prompt (both editable in Settings, with Reset to default), and its handlers. Adding Email later is one more row; the screens, Settings and History pick it up.') + registry
            + section_title('Lifecycle of an item') + life
            + section_title('Where actions first appear', 'For notes. Ask answers show them right under the answer: see Actions · from Ask answers.') + appear)
    intro = ('Distill finds action items in processed notes and in Ask answers, and by default asks you to confirm each one. If Distill can do the action itself (today: write a Slack message, draft a Jira ticket, draft a Confluence page), it becomes that action type. '
             'Everything else becomes a <b>to-do</b> for you. Action types are an extensible set: each has its own fields, prompts and handlers, and new ones (Email next) slot in without new screens.')
    return board('ActionsOverview.dc.html', 'Actions · how it works', 'Actions from your notes · how it works', intro, body, 2520)


# ================================================================ SETTINGS with navigation and search
SNAV = [('GENERAL', [('Vaults', 'globe'), ('Batching', 'clock'), ('Sources', 'note'), ('Labels', 'tag'), ('Ask history', 'ask'), ('Keyboard shortcuts', 'grip')]),
        ('AI', [('AI runners', 'bolt'), ('Models for tasks', 'gear')]),
        ('ACTIONS', [('Actions', 'actions'), ('To-do defaults', 'todo'), ('Connections', 'link')])]


def settings_win(active, content, search='', counts=None, w=1180, h=760, overlay=''):
    counts = counts or {}
    nav = dc('SettingsSectionNav', '236px', '560px', selected=active, query=search or None, matches=','.join(f'{k}:{v}' for k, v in counts.items()) or None)
    content = (f'<div style="width: 236px; flex-shrink: 0; background: {PANEL}">{nav}</div>'
               f'<div style="flex-grow: 1; min-width: 0; padding: 30px 36px; box-sizing: border-box; display: flex; flex-direction: column; gap: 18px; overflow: hidden; position: relative; background: #FFFFFF">{content}</div>')
    return window(content, w, h, overlay)


def sh1(t, sub=''):
    s = f'<span style="font-size: 13px; color: {MUTED}; line-height: 1.5">{sub}</span>' if sub else ''
    return f'<div style="display: flex; flex-direction: column; gap: 4px"><h1 style="margin: 0; {HEAD}; font-weight: 800; font-size: 26px; letter-spacing: -.02em">{t}</h1>{s}</div>'


def srow(label_text, sub, control, hl=False, border=True):
    b = f'border-top: 1px solid {LINE};' if border else ''
    bg = 'background: #FBFFF4; box-shadow: 0 0 0 2px #B9F06A; border-radius: 10px; padding-left: 10px; padding-right: 10px;' if hl else ''
    s = f'<span style="font-size: 12px; color: {MUTED}; line-height: 1.45">{sub}</span>' if sub else ''
    return (f'<div style="display: flex; align-items: center; gap: 16px; padding: 11px 0; {b} {bg}"><div style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1; min-width: 0">'
            f'<span style="font-size: 13px; font-weight: 600">{label_text}</span>{s}</div><div style="display: flex; align-items: center; gap: 6px; flex-shrink: 0">{control}</div></div>')


def model_ctl(model='Sonnet', effort='Medium'):
    return select('Claude Code', 128) + select(model, 100) + select(effort, 96)


PROMPTS = {
    'slack_create': 'Write a short Slack message to {recipient} that does what the note asks.\nUse only facts from {excerpt} and {note_title}. Don’t invent times, names or numbers.\nFriendly and direct, under 80 words. Use Slack formatting: *bold*, bullet lists, @mentions.\nReturn only the message.',
    'slack_improve': 'The user edited this Slack message. Fix grammar, spelling and punctuation only.\nKeep their words, tone, length and formatting. Don’t add or remove content.\nReturn only the message.',
    'jira_create': 'Draft a Jira ticket for project {project} from {excerpt}.\nSummary: one line, starts with a verb. Description sections: Why, What to do, Done when (checklist).\nFill priority and assignee only if the note says so.',
    'jira_create_edited': 'Draft a Jira ticket for project {project} from {excerpt}.\nSummary: one line, starts with a verb. Description sections: Context, Steps, Acceptance criteria.\nAlways link the incident number if the note has one, and add the label from {labels}.',
}


def prompt_box(title, sub, key, edited=False, h=None, hl=None):
    text = PROMPTS[key]
    text = re.sub(r'(\{\w+\})', rf'<span style="color: {BLUE}; background: {TINT}; border-radius: 4px; padding: 0 3px; font-weight: 600">\1</span>', text).replace('\n', '<br>')
    if hl:
        text = re.sub(f'({hl})', r'<mark>\1</mark>', text, flags=re.I)
    badge = pill('Edited', '#FFE4D6', PEACH_INK, 20, 10, 700) if edited else pill('Default', PANEL, MUTED, 20, 10, 700)
    reset = btn('Reset to default', 'ghost', 26, 12, 'restore', disabled=not edited, extra='box-shadow: none; background: transparent' if not edited else '')
    hh = f'height: {h}px;' if h else ''
    return (f'<div style="display: flex; flex-direction: column; gap: 6px"><div style="display: flex; align-items: center; gap: 8px"><span style="font-size: 13px; font-weight: 600">{title}</span>{badge}<span style="flex-grow: 1"></span>'
            f'<span style="font-size: 12px; font-weight: 600; color: {MUTED}">Insert field ▾</span>{reset}</div>'
            f'<span style="font-size: 12px; color: {MUTED}">{sub}</span>'
            f'<div style="{hh} padding: 10px 12px; border-radius: 12px; background: {PANEL}; box-shadow: {"0 0 0 1.5px " + PEACH if edited else "none"}; font-family: ui-monospace, Menlo, monospace; font-size: 11.5px; line-height: 1.6; color: #2A2925; overflow: hidden">{text}</div></div>')


def trow(t, on, when, models, later=False):
    d = TYPES[t]
    return (f'<div style="display: flex; align-items: center; gap: 12px; padding: 12px 0; border-top: 1px solid {LINE}; {"opacity: .5" if later else ""}">{tbadge(t, 32)}'
            f'<div style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1"><span style="font-size: 14px; font-weight: 600">{d["name"]}</span><span style="font-size: 12px; color: {MUTED}">{when}</span></div>'
            f'<span style="font-size: 12px; color: {MUTED}; width: 170px">{models}</span>'
            + (pill('Coming later', '#FFFFFF', FAINT, 22, 11, 700, f'box-shadow: inset 0 0 0 1.5px {LINE}') if later else (toggle(on) if t != 'todo' else pill('Always on', PANEL, MUTED, 22, 11, 700)))
            + ic('right', 14, FAINT) + '</div>')


def crow(t, state, site, extra, act):
    d = TYPES[t]
    st = {'ok': pill(ic('check', 11, LIME_INK, 2.6) + 'Connected', LIME_BG, LIME_INK, 22, 11, 700), 'off': pill('Not connected', PANEL, MUTED, 22, 11, 700),
          'exp': pill(ic('warn', 11, PEACH_INK) + 'Sign-in expired', '#FFE4D6', PEACH_INK, 22, 11, 700), 'wait': pill(spinner(BLUE, 10) + 'Waiting for browser', TINT, BLUE, 22, 11, 700)}[state]
    return (f'<div style="display: flex; flex-direction: column; gap: 10px; padding: 14px 16px; border-radius: 16px; box-shadow: 0 0 0 1px {LINE}">'
            f'<div style="display: flex; align-items: center; gap: 12px">{tbadge(t, 34)}<div style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1"><span style="font-size: 14px; font-weight: 700">{d["name"].split(" ")[0]}</span><span style="font-size: 12px; color: {MUTED}">{site}</span></div>{st}{act}</div>{extra}</div>')


def settings_board():
    vault_cards = ''.join(f'<div style="display: flex; flex-direction: column; gap: 10px; padding: 16px; border-radius: 18px; box-shadow: {sh}"><span style="width: 34px; height: 34px; border-radius: 11px; background: {c}; color: {k}; display: flex; align-items: center; justify-content: center; {HEAD}; font-weight: 800">{i}</span><span style="font-size: 14px; font-weight: 600">{n}</span><span style="font-size: 12px; color: {MUTED}">{q}</span></div>'
                          for i, n, q, c, k, sh in [('R', 'Research', 'Queue: Distill Queue/research', '#FFE0EC', '#A3245A', f'0 0 0 2px {BLUE}'), ('W', 'Work notes', 'Queue: vault inbox', '#DDF2FF', '#0B5C86', f'0 0 0 1px {LINE}')])
    f1 = settings_win('Vaults', sh1('Vaults', 'The vault Distill adds notes to, and where each one’s queue lives.')
                      + f'<div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px">{vault_cards}<div style="border-radius: 18px; border: 1.5px dashed #D6D3CC; display: flex; align-items: center; justify-content: center; color: {BLUE}; font-size: 13px; font-weight: 600">+ Add vault</div></div>')
    # search results
    res = [('Actions › Slack message', [('Create prompt', 'How Distill writes a Slack message from a note'), ('Improve prompt', 'Runs after you edit a message')]),
           ('Actions › Jira ticket', [('Create prompt', 'How Distill drafts a ticket'), ('Improve prompt', 'Runs after you edit a ticket')]),
           ('Actions › Confluence page', [('Create prompt', 'How Distill drafts a page'), ('Improve prompt', 'Runs after you edit a page')]),
           ('Models for tasks', [('Ask a question', 'Model and effort; the system prompt is fixed')])]
    rhtml = ''
    for grp, items in res:
        rhtml += f'<div style="padding: 10px 0 4px; font-size: 11px; font-weight: 700; color: {MUTED}">{grp}</div>'
        for t, sub in items:
            rhtml += (f'<div style="display: flex; align-items: center; gap: 10px; padding: 9px 12px; border-radius: 10px; box-shadow: 0 0 0 1px {LINE}; margin-bottom: 6px">'
                      f'<div style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1"><span style="font-size: 13px; font-weight: 600">{re.sub("(?i)(prompt)", r"<mark>\1</mark>", t)}</span><span style="font-size: 12px; color: {MUTED}">{re.sub("(?i)(prompt)", r"<mark>\1</mark>", sub)}</span></div>{ic("right", 13, FAINT)}</div>')
    f2 = settings_win('', f'<span style="font-size: 13px; color: {MUTED}"><b style="color: {INK}">7 settings</b> match “prompt”</span>' + f'<div style="display: flex; flex-direction: column">{rhtml}</div>',
                      search='prompt', counts={'Actions': 6, 'Models for tasks': 1})
    f3 = settings_win('', f'<div style="flex-grow: 1; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 10px; text-align: center">{ic("search", 36, "#C9C6BF")}'
                          f'<span style="{HEAD}; font-weight: 600; font-size: 20px">No settings match “webhook”</span><span style="font-size: 13px; color: {MUTED}; max-width: 360px; line-height: 1.5">Try fewer or different words, or pick a section on the left.</span>{btn("Clear search", "secondary", 32, 13)}</div>',
                      search='webhook', counts={}, h=1140)
    # Actions overview page
    f4 = settings_win('Actions', sh1('Actions', 'Distill finds actions in processed notes and Ask answers. Each action type can do some for you; the rest become to-dos.') + sources_settings()
                      + ''
                      + srow('Model for finding actions', 'Also listed in Models for tasks', model_ctl('Sonnet', 'Medium'))
                      + f'<span style="font-size: 11px; font-weight: 800; letter-spacing: .06em; color: {FAINT}; margin-top: 6px">ACTION TYPES</span><div>'
                      + trow('todo', True, 'Catch-all for anything no other type can do', 'Found with the note or answer')
                      + trow('slack', True, 'Write drafts: when a note is processed', 'Sonnet · improve: Sonnet')
                      + trow('jira', True, 'Write drafts: when a note is processed · create: on your click', 'Sonnet · improve: Sonnet')
                      + trow('conf', True, 'Write drafts: when a note is processed · create: on your click', 'Sonnet · improve: Sonnet')
                      + trow('mail', False, 'Write and copy emails', '—', later=True) + '</div>', h=1140)
    # Slack type detail
    f5 = settings_win('Actions', f'<span style="font-size: 12px; color: {BLUE}; font-weight: 600">‹ Actions</span>'
                      + f'<div style="display: flex; align-items: center; gap: 12px">{tbadge("slack", 40, 12, 20)}{sh1("Slack message")}<span style="flex-grow: 1"></span>{toggle(True)}</div>'
                      + srow('Write the message', 'When off, Slack messages show a Create message button', seg(['When a note is processed', 'Only when I ask'], 'When a note is processed'), border=False)
                      + srow('Model for writing', '', model_ctl('Sonnet', 'Low'))
                      + srow('Improve after I edit', 'Fixes grammar when you finish editing; you can always Undo', toggle(True) + select('Sonnet', 100) + select('Low', 80))
                      + srow('Send in Slack', 'Copy only for now', pill('Coming later', '#FFFFFF', FAINT, 22, 11, 700, f'box-shadow: inset 0 0 0 1.5px {LINE}'))
                      + prompt_box('Create prompt', 'Used to write a new message from a note', 'slack_create')
                      + prompt_box('Improve prompt', 'Used after you edit a message. Different from the create prompt.', 'slack_improve'))
    # Jira detail with edited prompt + reset confirm
    confirm = (f'<div style="position: absolute; right: 60px; top: 446px; width: 300px; padding: 14px; border-radius: 14px; background: #FFFFFF; box-shadow: 0 0 0 1px rgba(29,28,26,.08), 0 14px 32px rgba(29,28,26,.2); display: flex; flex-direction: column; gap: 8px">'
               f'<span style="font-size: 13px; font-weight: 700">Reset the create prompt?</span><span style="font-size: 12px; color: #48463F; line-height: 1.5">Your version is replaced by the default. You can undo this until you close Settings.</span>'
               f'<div style="display: flex; justify-content: flex-end; gap: 6px">{btn("Cancel", "soft", 28, 12)}{btn("Reset", "primary", 28, 12)}</div></div>')
    f6 = settings_win('Actions', f'<span style="font-size: 12px; color: {BLUE}; font-weight: 600">‹ Actions</span>'
                      + f'<div style="display: flex; align-items: center; gap: 12px">{tbadge("jira", 40, 12, 20)}{sh1("Jira ticket")}<span style="flex-grow: 1"></span>{toggle(True)}</div>'
                      + srow('Write the draft', '', seg(['When a note is processed', 'Only when I ask'], 'When a note is processed'), border=False)
                      + srow('Create in Jira', 'Always by your click on Create in Jira. Never during note processing.', pill(ic('lock', 11, MUTED) + 'On your click', PANEL, MUTED, 24, 11, 700))
                      + srow('Default project', 'From Connections › Jira; a draft can pick another', select('PX · Project X', 170) + select('Task', 90))
                      + srow('Models', 'Writing · improving after edit', select('Sonnet', 100) + select('Sonnet', 100))
                      + prompt_box('Create prompt', 'Used to draft a ticket from a note or a to-do', 'jira_create_edited', edited=True),
                      overlay=confirm)
    # To-do defaults
    f7 = settings_win('To-do defaults', sh1('To-do defaults', 'How To do opens. Changes you make on the To do screen are remembered there.')
                      + srow('Show', '', seg(['Open', 'Open and completed'], 'Open'), border=False)
                      + srow('Group by', '', select('Due date', 160))
                      + srow('Sort', 'Inside each group', select('Due date, soonest first', 210))
                      + srow('Due date filter', 'Applied when To do opens', select('Any time', 160))
                      + srow('New to-dos get', 'When you add one by hand', select('Priority: None', 150) + select('Due: None', 120))
                      + srow('Completed to-dos', 'Struck through for 2 seconds, then moved to History', select('Move to History', 170))
                      + srow('Keep action history', 'Removed, completed, sent and done items', seg(['30 days', '90 days', '1 year', 'Forever'], '90 days'))
                      + srow('Remind me of overdue to-dos', 'One macOS notification each morning', toggle(False) + select('9:00 AM', 100)))

    f8 = settings_win('Connections', sh1('Connections', 'Sign-in happens in your browser. Distill keeps the access in your Keychain and never sees your password.')
                      + crow('slack', 'off', 'Not needed while Slack messages are copy-only', '', btn('Connect', 'secondary', 30, 12, 'globe', disabled=True))
                      + crow('jira', 'ok', 'acme.atlassian.net · as Jin Liu · since Sep 12', f'<div style="display: flex; gap: 8px; padding-left: 46px">{select("Default project: PX · Project X", 250)}{select("Issue type: Task", 150)}</div>', btn('Disconnect', 'danger', 30, 12))
                      + crow('conf', 'exp', 'acme.atlassian.net/wiki · expired Sep 30 at 6:00 PM', f'<div style="display: flex; gap: 8px; padding-left: 46px">{select("Default space: Project X", 220)}{select("Parent: Incident reviews", 200)}</div>', btn('Sign in via browser', 'primary', 30, 12, 'globe'))
                      + f'<span style="font-size: 12px; color: {MUTED}">Jira and Confluence on the same Atlassian site use one sign-in; signing in to one connects both.</span>')
    f9 = settings_win('Connections', sh1('Connections', 'Sign-in happens in your browser. Distill keeps the access in your Keychain and never sees your password.')
                      + crow('slack', 'off', 'Not needed while Slack messages are copy-only', '', btn('Connect', 'secondary', 30, 12, 'globe', disabled=True))
                      + crow('jira', 'wait', 'acme.atlassian.net', banner('wait', 'Finish signing in, in your browser', 'We opened acme.atlassian.net in Safari. Allow Distill there; this page updates by itself.', btn('Open the page again', 'secondary', 28, 12, 'ext') + btn('Cancel', 'soft', 28, 12)), '')
                      + crow('conf', 'off', 'Connects with Jira (same site)', '', btn('Sign in via browser', 'secondary', 30, 12, 'globe', disabled=True))
                      + banner('error', 'Couldn’t sign in to Jira', 'The browser said access was denied. Nothing changed. You can try again.', btn('Try again', 'secondary', 28, 12)).replace('<div style="display: flex; gap: 10px', '<div style="opacity: .55; display: flex; gap: 10px', 1)
                      + f'<span style="font-size: 12px; color: {MUTED}">Faded: what shows instead if the browser sign-in is denied.</span>')
    frames = [(f1, '1 · Default: section navigation, search on top'), (f2, '2 · Typing “prompt”: results by section, matches highlighted; nav shows counts and dims the rest'),
              (f3, '3 · No settings match'), (f4, '4 · Actions: where actions come from (notes and Ask answers: detect to-dos, detect action types, confirm, all on by default), the finding model, and every action type'),
              (f5, '5 · Actions › Slack message: when to write, models, create and improve prompts at their defaults'),
              (f6, '6 · Actions › Jira ticket: an edited create prompt (Edited, Reset to default enabled) and the reset confirmation'),
              (f7, '7 · To-do defaults'), (f8, '8 · Connections: connected, not needed yet, sign-in expired'), (f9, '9 · Connections: signing in, in the browser')]
    frames.append((settings_win('Actions', f'<span style="font-size: 12px; color: {BLUE}; font-weight: 600">‹ Actions</span>' + sh1('Where actions come from', 'Each source has its own detection and confirmation. Defaults are shown on the right of each row.') + sources_settings()), '10 · Actions › Where actions come from: notes and Ask answers, each with detect to-dos, detect action types, and confirm (default on)'))
    frames.append((settings_win('Models for tasks', sh1('Models for tasks', 'One place for every model choice. Action types link here and back.')
                                + ''.join(srow(n, d, model_ctl(m, e), border=(i > 0)) for i, (n, d, m, e) in enumerate([
                                    ('Adding notes', 'Batches into wiki pages', 'Sonnet', 'Medium'), ('Ask a question', 'Answers from your vault', 'Sonnet', 'Medium'),
                                    ('Label suggestions', 'After a note is queued', 'Haiku', 'Low'), ('Text from images', 'When you click Extract content', 'Haiku', 'Low'),
                                    ('Finding actions', 'After a batch is applied', 'Sonnet', 'Medium')]))
                                + srow('Action drafts', 'Writing and improving are set per type', f'<span style="font-size: 13px; font-weight: 600; color: {BLUE}">Open Actions ›</span>')), '11 · Models for tasks gains Finding actions, and points to per-type models'))
    rows = ''
    for i in range(0, len(frames), 2):
        rows += '<div style="display: flex; gap: 40px">' + ''.join(framed(f, l) for f, l in frames[i:i + 2]) + '</div>'
    body = rows
    intro = ('Settings now has a section list on the left, grouped into General, AI and Actions, with a search field on top. Typing filters to matching settings across all sections, highlights the words, '
             'and shows counts in the list; Esc clears. New sections: <b>Actions</b> (find actions; per type: on/off, when to write, models for writing and for improving after an edit, and the create and improve prompts with Reset to default), '
             '<b>To-do defaults</b>, and <b>Connections</b> (sign in via browser, site, default project or space, disconnect).')
    return board('SettingsNav.dc.html', 'Settings · sections and search', 'Settings · sections, search, Actions', intro, body, 2520)



# ================================================================ ASK → actions (second source)
ASK_Q = 'What do I still owe the tea club and Project X before Friday?'
ASK_ITEMS = [
    dict(t='todo', text='Book the tasting room for Saturday', why='You said you would book it', cite='1', btn='Add'),
    dict(t='slack', text='Tell Mei the room is booked and ask her to bring the tin', why='Mei is bringing the tea; she needs the time', cite='1', btn='Create draft', to='To Mei Tanaka'),
    dict(t='conf', text='Incident review: INC-212 auth retry storm', why='The review is Friday and no page exists yet', cite='2', btn='Create draft', to='Project X › Incident reviews'),
    dict(t='jira', text='Cap payment client retries at 3 with backoff', why='The note says it needs a ticket in PX', cite='3', btn='Create draft', to='PX · Project X'),
]


def cite(n):
    return f'<span style="font-size: 10px; font-weight: 700; color: {BLUE}; background: {TINT}; padding: 1px 6px; border-radius: 8px">{n}</span>'


def ask_answer(fs=14):
    return (f'<div style="display: flex; align-items: center; gap: 8px"><span style="width: 24px; height: 24px; border-radius: 12px; background: {TINT}; display: flex; align-items: center; justify-content: center">{spark(BLUE, 12)}</span>'
            f'<span style="font-size: 13px; font-weight: 700">Claude</span><span style="font-size: 12px; color: {FAINT}">from 3 pages · answered at 3:12 PM</span></div>'
            f'<p style="margin: 0; font-size: {fs}px; line-height: 1.6; color: {BODY}">For the tea club, you said you’d <b>book the tasting room for Saturday</b> and tell Mei so she can bring the new tin {cite(1)}. '
            f'For Project X, the INC-212 review is Friday and the write-up isn’t in Confluence yet {cite(2)}; the retry cap still needs a ticket in PX {cite(3)}.</p>')


def item_row(it, state='pending', compact=False, editing=False):
    d = TYPES[it['t']]
    target = (f'<span style="display: inline-flex; align-items: center; gap: 4px; font-size: 10px; font-weight: 800; letter-spacing: .05em; color: {d["ink"]}">{d["name"].upper()}{ic("down", 9, d["ink"], 3)}</span>'
              + (f'<span style="font-size: 11px; color: {MUTED}">{it["to"]}</span>' if it.get('to') and not compact else ''))
    text = it['text']
    if editing:
        text = f'<span style="padding: 3px 8px; margin-left: -8px; border-radius: 8px; box-shadow: 0 0 0 2px {BLUE}">Book the tasting room for Saturday 2 PM{caret(BLUE)}</span>'
    title = f'<span style="font-size: {12 if compact else 13}px; font-weight: 600; line-height: 1.35">{text}</span>'
    why = '' if compact else f'<span style="display: flex; align-items: center; gap: 6px; font-size: 11px; color: {MUTED}"><b style="color: #48463F">Why:</b> {it["why"]} {cite(it["cite"])}</span>'
    if state == 'pending':
        right = btn(it['btn'], 'secondary', 28, 12, 'plus') + iconbtn('x', 26, FAINT, title='Dismiss')
    elif state == 'adding':
        right = pill(spinner(BLUE, 10) + ('Adding…' if it['t'] == 'todo' else 'Writing draft…'), TINT, BLUE, 26, 12, 700)
    elif state == 'added':
        where = 'Added to To do' if it['t'] == 'todo' else f'Draft in {d["many"]}'
        right = pill(ic('check', 11, LIME_INK, 2.6) + where, LIME_BG, LIME_INK, 26, 12, 700) + f'<span style="font-size: 12px; font-weight: 700; color: {BLUE}">Open</span>'
    elif state == 'dup':
        right = pill(f'Already in {d["many"]}', PANEL, MUTED, 26, 12, 700) + f'<span style="font-size: 12px; font-weight: 700; color: {BLUE}">Open</span>'
    elif state == 'dismissed':
        return (f'<div style="display: flex; align-items: center; gap: 10px; padding: 6px 10px; border-radius: 10px; opacity: .6">{tbadge(it["t"], 22, 7, 11)}'
                f'<span style="font-size: 12px; color: {FAINT}; text-decoration: line-through; flex-grow: 1">{it["text"]}</span><span style="font-size: 11px; color: {MUTED}">Dismissed</span>'
                f'<span style="font-size: 12px; font-weight: 700; color: {BLUE}">Undo</span></div>')
    elif state == 'editing':
        right = btn('Add', 'primary', 28, 12, 'plus') + btn('Cancel', 'soft', 28, 12)
    bg = 'background: #FBFFF4' if state == 'added' else ''
    return (f'<div style="display: flex; align-items: center; gap: 10px; padding: {"7px 8px" if compact else "9px 10px"}; border-radius: 12px; {bg}">{tbadge(it["t"], 26 if compact else 30, 8, 13)}'
            f'<div style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1; min-width: 0"><span style="display: flex; align-items: center; gap: 8px">{target}</span>{title}{why}</div>'
            f'<div style="display: flex; align-items: center; gap: 6px; flex-shrink: 0">{right}</div></div>')


def found_block(states=('pending',) * 4, items=ASK_ITEMS, compact=False, head=None, foot=None, edit_first=False):
    n = len(items)
    head = head if head is not None else (f'<div style="display: flex; align-items: center; gap: 8px; padding: 2px 4px 4px">{ic("actions", 14, BLUE)}<span style="font-size: 12px; font-weight: 800; white-space: nowrap">Found in this answer</span>'
                                          f'<span style="font-size: 11px; color: {MUTED}; white-space: nowrap">{n} · Sonnet</span><span style="flex-grow: 1"></span>'
                                          + ('' if compact else btn('Dismiss all', 'ghost', 26, 12, extra='color: #6B6862')) + btn('Add all', 'primary', 26, 12) + '</div>')
    rows = ''.join(item_row(it, st, compact, editing=(edit_first and i == 0)) for i, (it, st) in enumerate(zip(items, states)))
    f = f'<div style="padding: 6px 6px 0; border-top: 1px solid {LINE}; font-size: 11px; color: {MUTED}">{foot}</div>' if foot else ''
    return f'<div style="display: flex; flex-direction: column; gap: 2px; padding: 10px; border-radius: 16px; background: #FFFFFF; box-shadow: 0 0 0 1.5px #D6E4FB">{head}{rows}{f}</div>'


def answer_actions(menu_open=None):
    return (f'<div style="display: flex; align-items: center; gap: 8px; position: relative">{btn("Save answer to vault", "soft", 32, 12, extra="background: #E3EEFF; color: #1F6FEB")}{btn("Copy", "soft", 32, 12)}'
            f'<span style="width: 1px; height: 18px; background: {LINE}"></span>{btn("Add to to-do", "secondary", 32, 12, "plus")}<span style="margin-left: -6px">{btn("", "secondary", 32, 12, "down", extra="padding: 0 10px")}</span>{btn("Send to", "secondary", 32, 12, "send")}{menu_open or ""}</div>')


def ask_main(block, actions_menu=None):
    return (f'<header style="display: flex; align-items: flex-end; gap: 16px; padding: 28px 40px 0"><div style="display: flex; flex-direction: column; gap: 4px; flex-grow: 1"><h1 style="margin: 0; {HEAD}; font-weight: 800; font-size: 28px; letter-spacing: -0.03em">Ask your vault</h1>'
            f'<span style="font-size: 13px; color: {MUTED}">Answers come only from Research, with the pages they cite.</span></div>{btn("New chat", "soft", 32, 13)}</header>'
            f'<div style="flex-grow: 1; display: flex; flex-direction: column; gap: 12px; padding: 16px 40px; overflow: hidden; position: relative">'
            f'<div style="align-self: flex-end; max-width: 520px; padding: 11px 15px; border-radius: 18px 18px 4px 18px; background: #E9FBC9; font-size: 14px">{ASK_Q}</div>'
            f'<article style="display: flex; flex-direction: column; gap: 12px; max-width: 800px">{ask_answer()}{block}{answer_actions(actions_menu)}</article></div>'
            f'<footer style="padding: 0 40px 22px"><div style="height: 44px; display: flex; align-items: center; padding: 0 16px; border-radius: 22px; background: {PANEL}; font-size: 13px; color: {FAINT}">Ask a follow-up…</div></footer>')


def quick_ask(inner, h=None):
    body = (f'<div style="align-self: flex-end; max-width: 400px; padding: 8px 12px; border-radius: 14px 14px 4px 14px; background: #E9FBC9; font-size: 12px">{ASK_Q}</div>'
            f'<div style="font-size: 12px; line-height: 1.55; color: {BODY}">Book the tasting room for Saturday and tell Mei {cite(1)}. INC-212 needs a Confluence write-up {cite(2)} and the retry cap a PX ticket {cite(3)}.</div>{inner}')
    # shown at 90 % so the 560 pt window fits the grid cell
    return f'<div style="width: 504px">{quick_frame(body, 560, "Quick ask", extra="transform: scale(.9); transform-origin: top left")}</div>'


def ask_board():
    w1 = framed(app(ask_main(found_block()), active='Ask', recentRunning='Oolong vs pu-erh caffeine', recentFailed='Summarize the hiring loop', recentOpen='What do I still owe the tea club and Project X before Friday?'), 'A · An answer with actions: “Found in this answer”, waiting for you to confirm (the default)')
    send_m = f'<div style="position: absolute; left: 330px; top: 40px; z-index: 2">{menu([("todo", "To-do from the whole answer", "Title: What I owe before Friday", ""), ("todo", "To-do from selected text", "Select text in the answer first", "off"), "hr", ("slack", "Slack message", "Draft from this answer", ""), ("jira", "Jira ticket", "Draft from this answer", ""), ("conf", "Confluence page", "Draft from this answer", ""), "hr", ("mail", "Email", None, "off")], 300, "ADD OR SEND THIS ANSWER")}</div>'
    send_m = send_m.replace(pill('Coming later', '#FFFFFF', FAINT, 18, 10, 700, f'box-shadow: inset 0 0 0 1.5px {LINE}'), pill('Select text', '#FFFFFF', FAINT, 18, 10, 700, f'box-shadow: inset 0 0 0 1.5px {LINE}'), 1)
    w2 = framed(app(ask_main('', send_m), active='Ask', recentRunning='Oolong vs pu-erh caffeine', recentFailed='Summarize the hiring loop', recentOpen='What do I still owe the tea club and Project X before Friday?'), 'B · Any answer, nothing detected: add or send it by hand')
    W = 560
    it = ASK_ITEMS
    sel_html = (f'<p style="margin: 0; font-size: 13px; line-height: 1.6; color: {BODY}">For Project X, the INC-212 review is Friday and <span style="background: #CFE0FC">the write-up isn’t in Confluence yet</span> {cite(2)}.</p>'
                f'<div style="display: flex; gap: 4px; padding: 4px; border-radius: 12px; background: {INK}; width: fit-content; margin-left: 120px">'
                + ''.join(f'<span style="height: 26px; display: inline-flex; align-items: center; gap: 5px; padding: 0 9px; border-radius: 8px; color: #FFFFFF; font-size: 12px; font-weight: 600">{ic(i, 12, "#FFFFFF")}{t}</span>' for i, t in [('plus', 'Add as to-do'), ('send', 'Send to ▾'), ('copy', 'Copy')]) + '</div>')
    detecting = (f'<div style="display: flex; flex-direction: column; gap: 8px; padding: 12px; border-radius: 16px; box-shadow: 0 0 0 1.5px #D6E4FB; position: relative; overflow: hidden">'
                 f'<div style="display: flex; align-items: center; gap: 8px">{spinner()}<span style="font-size: 12px; font-weight: 700">Looking for actions in this answer…</span><span style="font-size: 11px; color: {MUTED}">Sonnet</span></div>'
                 + ''.join(f'<div style="display: flex; align-items: center; gap: 10px"><span style="width: 30px; height: 30px; border-radius: 9px; background: #ECEAE5"></span><div style="display: flex; flex-direction: column; gap: 5px; flex-grow: 1"><span style="height: 8px; width: 22%; border-radius: 4px; background: #ECEAE5"></span><span style="height: 10px; width: {w}%; border-radius: 5px; background: #F2F0EC"></span></div></div>' for w in (66, 52))
                 + '<div style="position: absolute; inset: 0; background: linear-gradient(100deg, transparent 30%, rgba(227,238,255,.6) 50%, transparent 70%)"></div></div>')
    retarget = (f'<div style="position: relative; width: {W}px">{found_block(("pending",) * 2, it[:2])}'
                f'<div style="position: absolute; left: 46px; top: 74px">{menu([("todo", "To-do", None, "check"), ("slack", "Slack message", None, ""), ("jira", "Jira ticket", None, ""), ("conf", "Confluence page", None, ""), "hr", ("mail", "Email", None, "off")], 240, "ADD AS")}</div></div>')
    confirm_off = (f'<div style="display: flex; flex-direction: column; gap: 8px; width: {W}px">{panel(ask_answer(13), W)}'
                   f'<div style="display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 14px; background: {LIME_BG}; box-shadow: 0 0 0 1px #DDF5B8">{ic("check", 14, LIME_INK, 2.6)}'
                   f'<span style="font-size: 12px; font-weight: 600; flex-grow: 1">Added 1 to-do and created 3 drafts from this answer</span><span style="font-size: 12px; font-weight: 700; color: {BLUE}">Show</span><span style="font-size: 12px; font-weight: 700; color: {BLUE}">Undo</span><span style="font-size: 12px; font-weight: 700; color: {BLUE}">Open Actions</span></div>'
                   f'<span style="font-size: 11px; color: {MUTED}; padding: 0 4px">Show expands the same list in its Added state. Undo removes all four (no History entry). Drafts are still only drafts: nothing is created in Jira or Confluence.</span></div>')
    from_ask_ctx = (f'<div style="display: flex; flex-direction: column; gap: 7px; padding: 11px 12px; border-radius: 12px; background: {PANEL}">'
                    f'<div style="display: flex; align-items: center; gap: 8px"><span style="font-size: 10px; font-weight: 800; letter-spacing: .05em; color: {FAINT}">FROM</span><span style="display: inline-flex; align-items: center; gap: 5px; font-size: 12px; font-weight: 600; color: {BLUE}">{ic("ask", 12, BLUE)}Ask chat<span style="color: {MUTED}; font-weight: 400"> · today at 3:12 PM</span></span></div>'
                    + quote('“…you’d book the tasting room for Saturday and tell Mei so she can bring the new tin.”')
                    + f'<div style="font-size: 12px; color: #48463F"><b style="color: {INK}">Why:</b> You said you would book it.</div>'
                    + f'<div style="display: flex; align-items: center; gap: 6px; font-size: 11px; color: {MUTED}">{ic("note", 11, MUTED)}Answer cites <b style="color: {BLUE}; font-weight: 600">Tea club planning</b> · added by you from Ask at 3:13 PM</div></div>')
    to_confirm = panel(group_head('To confirm', 2, BLUE)
                       + ''.join(f'<div style="display: flex; align-items: center; gap: 12px; padding: 9px 12px; border-radius: 12px; background: #F2F7FF; border: 1.5px dashed #BFD5FA">{tbadge("todo", 26, 8, 12)}<div style="display: flex; flex-direction: column; gap: 3px; flex-grow: 1; min-width: 0"><span style="font-size: 13px; font-weight: 600">{t}</span><span style="font-size: 11px; color: {MUTED}">{ic("note", 10, FAINT)} {n} · found at 3:44 PM</span></div>{btn("Add", "secondary", 28, 12, "plus")}{iconbtn("x", 26, FAINT)}</div>'
                                 for t, n in [('Book the tasting room for Saturday', 'Tea club planning'), ('Buy the 50 g gyokuro tin', 'Gyokuro at 60 °C')])
                       + group_head('Today', 1) + todo_row(TODOS[2], compact=True), W)
    cards = [
        ('Detecting', panel(ask_answer(13) + detecting, W), 'As soon as the answer finishes, Sonnet (the Finding actions model) reads it. The block holds its place with shimmer, so the answer doesn’t jump. Answers with no actions just lose the block.'),
        ('Found: confirm each one', found_block(), 'Default. Each item shows where it would go, what it says and why, with the citation it came from. Add (to-dos) or Create draft (action types); × dismisses. Nothing is added until you confirm.'),
        ('Change where it goes', retarget, 'The type label is a menu: a to-do can become a Jira ticket, and the other way round. Only types that are turned on are listed.'),
        ('Edit before adding', found_block(('editing', 'pending'), it[:2], edit_first=True), 'Click the text to fix it before adding. Return adds; Esc cancels. Drafts are edited later in their own list, with the usual AI improve pass.'),
        ('Adding and added', found_block(('added', 'adding', 'added', 'pending'), foot='Drafts are drafts: creating in Jira or Confluence still takes your click there.'), 'Each row turns into where it went, with Open. Writing a draft names its state while it runs.', 520),
        ('Dismissed', found_block(('added', 'dismissed', 'dismissed', 'pending')), 'Dismissed rows fold into one faded line with Undo. Dismissed items are not suggested again for this chat.'),
        ('Add all', found_block(('added', 'added', 'added', 'added'), head=f'<div style="display: flex; align-items: center; gap: 8px; padding: 2px 4px 4px">{ic("check", 14, LIME_INK, 2.6)}<span style="font-size: 12px; font-weight: 800">Added 1 to-do and created 3 drafts</span><span style="flex-grow: 1"></span><span style="font-size: 12px; font-weight: 700; color: {BLUE}">Undo</span><span style="font-size: 12px; font-weight: 700; color: {BLUE}">Open Actions</span></div>'),
         'Add all adds every item still waiting (dismissed ones stay dismissed). The header becomes the summary with one Undo for all of them.'),
        ('Already there', found_block(('dup', 'pending', 'pending', 'dup')), 'If the same item is already open in Actions (from a note or an earlier chat), the row says so and links to it instead of adding a copy.'),
        ('Confirmation off', confirm_off, 'Settings → Actions → Ask answers → “Ask me to confirm” off: items are added right away and one line says what happened, with Undo.'),
        ('Add or send by hand', f'<div style="display: flex; flex-direction: column; gap: 10px; width: {W}px">{panel(sel_html, W)}</div>', 'For anything not detected: select text in an answer for a small bar (Add as to-do, Send to, Copy), or use Add to to-do ▾ / Send to ▾ under the answer for the whole answer.'),
        ('Added by hand: prefilled', panel(f'<div style="display: flex; flex-direction: column; gap: 8px; padding: 10px 12px; border-radius: 12px; box-shadow: 0 0 0 2px {BLUE}"><span style="font-size: 10px; font-weight: 800; letter-spacing: .05em; color: {BLUE}">NEW TO-DO FROM THIS ANSWER</span>'
                                           f'<div style="display: flex; align-items: center; gap: 12px">{checkbox()}<span style="font-size: 14px; font-weight: 600">Write the INC-212 review in Confluence{caret(BLUE)}</span></div>'
                                           f'<div style="display: flex; gap: 6px; padding-left: 30px">{select("Due: Fri", 100)}{select("Priority: None", 128)}{select("#project-x", 104, True)}</div>'
                                           f'<div style="padding-left: 30px; font-size: 11px; color: {MUTED}">Sonnet wrote the title from your selection. The quote and chat link are kept as context.</div>'
                                           f'<div style="display: flex; justify-content: flex-end; gap: 6px">{btn("Cancel", "soft", 28, 12)}{btn("Add to-do", "primary", 28, 12)}</div></div>', W),
         'Manual adds open a small prefilled form (title suggested from the selection, labels from the answer’s pages). Send to opens the draft right in that type’s list.'),
        ('Context: from an Ask chat', panel(f'<div style="{HEAD}; font-weight: 600; font-size: 16px">Book the tasting room for Saturday</div>{from_ask_ctx}', W),
         'In Actions, items from Ask link back to the chat (not a note) and also name the note the answer cited. The Note filter matches either.'),
        ('Quick ask: found', quick_ask(found_block(('pending',) * 3, it[:3], compact=True)), 'The quick ask window shows the same block, compact: no Why line (hover shows it), no Dismiss all. The window grows to fit, like other content.'),
        ('Quick ask: added', quick_ask(found_block(('added', 'added', 'dismissed'), it[:3], compact=True, head=f'<div style="display: flex; align-items: center; gap: 8px; padding: 2px 4px 4px">{ic("check", 13, LIME_INK, 2.6)}<span style="font-size: 12px; font-weight: 800; flex-grow: 1">Added 1 to-do and 1 draft</span><span style="font-size: 12px; font-weight: 700; color: {BLUE}">Undo</span></div>')),
         'After confirming, rows show where things went. Open closes the quick window and opens Actions on that item.'),
        ('Notes with confirmation on', to_confirm, 'The same confirm rule for notes: found items wait in a “To confirm” group at the top of each Actions list, with Add and ×, instead of appearing as open items. The batch result says “Found 5 actions to confirm”.'),
        ('Settings: where actions come from', panel(sources_settings(), W), 'One row per source, three controls each. Defaults: everything detected, and confirm on for both sources. Full window in Settings frame 10.', 520),
    ]
    body = f'<div style="display: flex; gap: 40px">{w1}{w2}</div>' + section_title('Every state') + grid(cards, 4)
    intro = ('Ask answers are a second source of actions, next to processed notes. When an answer contains things to do, a <b>Found in this answer</b> block lists each one with where it would go '
             '(To do, Slack message, Jira ticket, Confluence page), what it says and why. By default you confirm each one: Add or Create draft, Dismiss, or Add all. '
             'Every answer also has <b>Add to to-do ▾</b> and <b>Send to ▾</b> for anything Distill didn’t detect. Settings → Actions → Where actions come from sets detection and confirmation per source.')
    return board('ActionsAsk.dc.html', 'Actions · from Ask answers', 'Actions · from Ask answers', intro, body, 2520)


def sources_settings(compact=True):
    def src(icon, name, sub, rows):
        r = ''.join(f'<div style="display: flex; align-items: center; gap: 10px; padding: 7px 0; border-top: 1px solid {LINE}"><span style="flex-grow: 1; display: flex; flex-direction: column; gap: 1px"><span style="font-size: 12px; font-weight: 600">{a}</span>'
                    + (f'<span style="font-size: 11px; color: {MUTED}">{b}</span>' if b else '') + f'</span>{c}<span style="width: 58px; font-size: 10px; font-weight: 700; color: {FAINT}; text-align: right">DEFAULT {dflt}</span></div>' for a, b, c, dflt in rows)
        return (f'<div style="display: flex; flex-direction: column; gap: 4px; padding: 12px 14px; border-radius: 14px; box-shadow: 0 0 0 1px {LINE}">'
                f'<div style="display: flex; align-items: center; gap: 10px; padding-bottom: 4px">{ic(icon, 16, BLUE)}<span style="font-size: 13px; font-weight: 700">{name}</span><span style="font-size: 11px; color: {MUTED}">{sub}</span></div>{r}</div>')
    types = lambda on: ''.join(f'<span title="{TYPES[t]["name"]}" style="opacity: {1 if t in on else .3}">{tbadge(t, 22, 7, 11)}</span>' for t in ('slack', 'jira', 'conf'))
    return (f'<div style="display: flex; flex-direction: column; gap: 10px"><span style="font-size: 11px; font-weight: 800; letter-spacing: .06em; color: {FAINT}">WHERE ACTIONS COME FROM</span>'
            + src('note', 'Notes processed into the wiki', 'after a batch is applied', [('Detect to-dos', '', toggle(True), 'ON'), ('Detect Slack, Jira, Confluence items', 'Click a type to turn it off for this source', types(('slack', 'jira', 'conf')) + toggle(True), 'ON'), ('Ask me to confirm before adding', 'Found items wait in “To confirm”', toggle(True), 'ON')])
            + src('ask', 'Ask answers', 'main window and quick ask', [('Detect to-dos', '', toggle(True), 'ON'), ('Detect Slack, Jira, Confluence items', 'Click a type to turn it off for this source', types(('slack', 'jira', 'conf')) + toggle(True), 'ON'), ('Ask me to confirm before adding', '“Found in this answer” with Add and Dismiss', toggle(True), 'ON')])
            + '</div>')


BUILDERS = [overview_board, todo_board, ask_board, slack_board, lambda: remote_board('jira'), lambda: remote_board('conf'), history_board, settings_board]




def build():
    return [b() for b in BUILDERS]


def measure(boards):
    for fname, W, H, _ in boards:
        r = subprocess.run([os.path.join(S, 'snapbin'), os.path.join(PROJ, fname), str(W), os.path.join(S, 'shots', fname.replace('.dc.html', '.png')), '0.5'],
                           capture_output=True, text=True, timeout=120)
        m = re.search(r'MEASURE (\d+)', r.stdout)
        if m:
            SIZES[fname] = int(m.group(1))
    json.dump(SIZES, open(SIZES_FILE, 'w'), indent=2)


if __name__ == '__main__':
    os.makedirs(os.path.join(S, 'shots'), exist_ok=True)
    boards = build()
    if '--measure' in sys.argv:
        measure(boards)
        boards = build()
        measure(boards)  # second pass writes shots at the final height
    print('\n'.join(f'{f} {w}x{h}' for f, w, h, _ in boards))
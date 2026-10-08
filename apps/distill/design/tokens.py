#!/usr/bin/env python3
"""Tokens from clients/macos/Sources/Distill/Theme.swift (colours, type, button and pill sizes, radii, spacing).

    python3 apps/distill/design/tokens.py           # rewrite the three files below
    python3 apps/distill/design/tokens.py --check   # exit 1 when any of them is out of date

Writes tokens.json (a name-to-value map, for render.py and the drift test), and for the Distill
Design System ds/tokens.json (the list shape the Design System page reads) and ds/tokens.css (the
`:root` variables boards and the component bundle use; the page builds its own only in the browser).
Theme.swift is the source of truth; never edit these files by hand. Standard library only.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
THEME = os.path.join(ROOT, '..', 'clients', 'macos', 'Sources', 'Distill', 'Theme.swift')
OUT = os.path.join(ROOT, 'tokens.json')
DS_JSON = os.path.join(ROOT, 'ds', 'tokens.json')
DS_CSS = os.path.join(ROOT, 'ds', 'tokens.css')
FAMILIES = {'display': '"Bricolage Grotesque", ui-rounded, system-ui, sans-serif',
            'body': '"DM Sans", -apple-system, system-ui, sans-serif'}
USAGE = {  # what each Theme colour is for, as the Design System shows it
    'window': 'Window and card background.', 'panel': 'Sidebar, toolbars, quiet fills.', 'border': 'Hairlines and card borders.',
    'ink': 'Primary text.', 'muted': 'Secondary text on window or panel.',
    'faint': 'Placeholder and timestamp text; not for body copy (below 4.5:1 on window).', 'flaskLine': 'App icon flask outline.',
    'primary': 'Primary action fill; links and focus.', 'primaryTint': 'Selected rows, busy pills.',
    'lime': 'Joy accent fill (icon liquid).', 'limeTint': 'Success pill fill.', 'limeInk': 'Text on limeTint.',
    'peach': 'Joy accent fill.', 'peachTint': 'Warning or count pill fill.', 'peachInk': 'Text on peachTint.',
    'pinkTint': 'Vault chip fill.', 'pinkInk': 'Text on pinkTint.', 'skyTint': 'Vault chip fill.', 'skyInk': 'Text on skyTint.',
    'working': 'Working indicator.'}


def body_of(src, decl):
    """The brace-matched body that follows `decl` (a regex)."""
    m = re.search(decl, src)
    if not m:
        raise SystemExit(f'Theme.swift: {decl!r} not found')
    i = src.index('{', m.end() - 1)
    depth = 0
    for j in range(i, len(src)):
        depth += {'{': 1, '}': -1}.get(src[j], 0)
        if depth == 0:
            return src[i + 1:j]
    raise SystemExit(f'Theme.swift: unbalanced braces after {decl!r}')


def num(s):
    v = float(s)
    return int(v) if v.is_integer() else v


def switch_values(body, prop):
    """`var height: CGFloat { switch self { case .regular: return 40; ... } }` → {regular: 40, ...}."""
    m = re.search(rf'var {prop}: CGFloat \{{\s*switch self \{{(.*?)\}}\s*\}}', body, re.S)
    if not m:
        raise SystemExit(f'Theme.swift: ButtonSize.{prop} not found')
    return {k: num(v) for k, v in re.findall(r'case \.(\w+): return ([\d.]+)', m.group(1))}


def extract(src):
    theme = body_of(src, r'enum Theme\s*\{')
    colors = {name: '#' + hexv.upper() for name, hexv in re.findall(r'static let (\w+) = Color\(hex: 0x([0-9A-Fa-f]{6})\)', theme)}
    disp = re.search(r'static func display\(_ size: CGFloat\) -> Font \{ \.system\(size: size, weight: \.(\w+), design: \.(\w+)\) \}', theme)
    body = re.search(r'static func body\(_ size: CGFloat, _ weight: Font\.Weight = \.(\w+)\) -> Font \{ \.system\(size: size, weight: weight\) \}', theme)
    if not disp or not body:
        raise SystemExit('Theme.swift: Theme.display / Theme.body changed shape; update tokens.py')
    chips = re.search(r'static let vaultChips: \[\(Color, Color\)\] = \[(.*?)\]', theme).group(1)

    bs = body_of(src, r'enum ButtonSize\s*\{')
    icon = re.search(r'var iconSize: CGFloat \{ self == \.regular \? ([\d.]+) : ([\d.]+) \}', bs)
    pad = re.search(r'case \.regular: return primary \? ([\d.]+) : ([\d.]+); case \.small: return ([\d.]+); case \.mini: return ([\d.]+)', bs)
    heights, fonts = switch_values(bs, 'height'), switch_values(bs, 'fontSize')
    buttons = {k: {'height': heights[k], 'fontSize': fonts[k],
                   'iconSize': num(icon.group(1)) if k == 'regular' else num(icon.group(2))} for k in heights}
    buttons['regular']['paddingPrimary'], buttons['regular']['paddingSoft'] = num(pad.group(1)), num(pad.group(2))
    buttons['small']['padding'], buttons['mini']['padding'] = num(pad.group(3)), num(pad.group(4))
    primary = body_of(src, r'struct PrimaryButton: View\s*\{')
    shadow = re.search(r'\.shadow\(color: Theme\.primary\.opacity\(size == \.regular \? ([\d.]+) : 0\), radius: ([\d.]+), y: ([\d.]+)\)', primary)
    gap = re.search(r'HStack\(spacing: ([\d.]+)\)', primary)
    disabled = re.search(r'\.opacity\(enabled \? 1 : ([\d.]+)\)', primary)

    pill = body_of(src, r'struct Pill: View\s*\{')
    p = lambda rx: re.search(rx, pill)
    pills = {'regular': {'height': num(p(r'\.frame\(height: size == \.small \? [\d.]+ : ([\d.]+)\)').group(1)),
                         'paddingX': num(p(r'\.padding\(\.horizontal, size == \.small \? [\d.]+ : ([\d.]+)\)').group(1)),
                         'fontSize': num(p(r'Theme\.body\(size == \.small \? [\d.]+ : ([\d.]+), \.bold\)').group(1)),
                         'gap': num(p(r'HStack\(spacing: size == \.small \? [\d.]+ : ([\d.]+)\)').group(1))},
             'small': {'height': num(p(r'\.frame\(height: size == \.small \? ([\d.]+)').group(1)),
                       'paddingX': num(p(r'\.padding\(\.horizontal, size == \.small \? ([\d.]+)').group(1)),
                       'fontSize': num(p(r'Theme\.body\(size == \.small \? ([\d.]+)').group(1)),
                       'gap': num(p(r'HStack\(spacing: size == \.small \? ([\d.]+)').group(1))}}

    icb = body_of(src, r'struct IconButton: View\s*\{')
    icb_size = re.search(r'init\(systemImage: String, size: CGFloat = ([\d.]+)', icb)
    icb_ratio = re.search(r'iconSize \?\? size \* ([\d.]+)', icb)
    icb_hover = re.search(r'hovered \{ Circle\(\)\.fill\(Theme\.ink\.opacity\(([\d.]+)\)\)', icb)
    tile = body_of(src, r'struct Tile: View\s*\{')
    tile_r = re.search(r'RoundedRectangle\(cornerRadius: size \* ([\d.]+)\)', tile)
    tile_size = re.search(r'var size: CGFloat = ([\d.]+)', tile)
    card = re.search(r'func card\(_ radius: CGFloat = ([\d.]+), selected: Bool = false\)', src)
    card_sel = re.search(r'lineWidth: selected \? ([\d.]+) : ([\d.]+)', src)
    for what, m in [('PrimaryButton shadow', shadow), ('PrimaryButton gap', gap), ('PrimaryButton disabled', disabled), ('IconButton size', icb_size), ('IconButton ratio', icb_ratio),
                    ('IconButton hover', icb_hover), ('Tile radius', tile_r), ('Tile size', tile_size), ('card radius', card), ('card stroke', card_sel)]:
        if not m:
            raise SystemExit(f'Theme.swift: {what} changed shape; update tokens.py')
    return {
        '$source': 'clients/macos/Sources/Distill/Theme.swift (regenerate with design/tokens.py; never edit by hand)',
        'color': colors,
        'vaultChips': [[a, b] for a, b in re.findall(r'\((\w+), (\w+)\)', chips)],
        'type': {'display': {'weight': disp.group(1), 'design': disp.group(2), 'canvasFamily': 'Bricolage Grotesque'},
                 'body': {'defaultWeight': body.group(1), 'design': 'default', 'canvasFamily': 'DM Sans'}},
        'button': {'sizes': buttons, 'gap': num(gap.group(1)), 'disabledOpacity': num(disabled.group(1)),
                   'primaryShadow': {'opacity': num(shadow.group(1)), 'radius': num(shadow.group(2)), 'y': num(shadow.group(3))}},
        'pill': pills,
        'iconButton': {'size': num(icb_size.group(1)), 'iconRatio': num(icb_ratio.group(1)), 'hoverInkOpacity': num(icb_hover.group(1))},
        'radius': {'card': num(card.group(1)), 'tileRatio': num(tile_r.group(1)), 'button': 'capsule', 'pill': 'capsule'},
        'size': {'tile': num(tile_size.group(1))},
        'stroke': {'card': num(card_sel.group(2)), 'cardSelected': num(card_sel.group(1))},
    }


def theme():
    with open(THEME, encoding='utf-8') as f:
        return extract(f.read())


def render():
    return json.dumps(theme(), indent=2) + '\n'


def px(v):
    return f'{v}px'


def ds_tokens(t):
    """The Design System's tokens.json: every family a list of {name, value, usage} (the shape its page reads)."""
    tok = lambda name, value, usage: {'name': name, 'value': value, 'usage': usage}
    colors = [tok(n, v, USAGE.get(n, '')) for n, v in t['color'].items()]
    for i, (fill, ink) in enumerate(t['vaultChips'], 1):  # Theme.vaultChips: a vault's chip, by its place in the list
        colors += [tok(f'vaultChip{i}', '{%s}' % fill, f'Vault {i} chip fill (Theme.vaultChips[{i - 1}]).'),
                   tok(f'vaultChip{i}Ink', '{%s}' % ink, f'Text on vaultChip{i}.')]
    b, p = t['button']['sizes'], t['pill']
    style = lambda name, size, weight, usage: {'name': name, 'fontSize': px(size), 'lineHeight': 1, 'fontWeight': weight, 'usage': usage}
    return {
        'name': 'Distill', 'version': 1,
        'meta': {'source': 'apps/distill/clients/macos/Sources/Distill/Theme.swift via apps/distill/design/tokens.py'},
        'color': {'themes': [{'id': 'light', 'name': 'Light'}], 'tokens': colors},
        'type': {'fonts': [], 'families': FAMILIES, 'groups': [
            {'name': 'Display', 'family': 'display', 'styles': [
                {'name': 'display-title', 'fontSize': '24px', 'lineHeight': 1.2, 'fontWeight': 800,
                 'usage': f'Theme.display: {t["type"]["display"]["weight"]} {t["type"]["display"]["design"]} titles (canvas stand-in {t["type"]["display"]["canvasFamily"]}).'}]},
            {'name': 'Controls', 'family': 'body', 'styles': [
                style('button', b['regular']['fontSize'], 600, 'PrimaryButton and SoftButton, regular (semibold).'),
                style('button-small', b['small']['fontSize'], 600, 'Buttons, small.'),
                style('button-mini', b['mini']['fontSize'], 600, 'Buttons, mini.'),
                style('pill', p['regular']['fontSize'], 700, 'Pill, regular (bold).'),
                style('pill-small', p['small']['fontSize'], 700, 'Pill, small.')]}]},
        'spacing': {'tokens': [
            tok('button-gap', px(t['button']['gap']), 'Icon to title in buttons.'),
            tok('button-pad', px(b['regular']['paddingPrimary']), 'PrimaryButton horizontal padding, regular.'),
            tok('button-pad-soft', px(b['regular']['paddingSoft']), 'SoftButton horizontal padding, regular.'),
            tok('button-pad-small', px(b['small']['padding']), 'Button horizontal padding, small.'),
            tok('button-pad-mini', px(b['mini']['padding']), 'Button horizontal padding, mini.'),
            tok('pill-pad', px(p['regular']['paddingX']), 'Pill horizontal padding, regular.'),
            tok('pill-pad-small', px(p['small']['paddingX']), 'Pill horizontal padding, small.'),
            tok('pill-gap', px(p['regular']['gap']), 'Icon to text in a pill, regular.'),
            tok('pill-gap-small', px(p['small']['gap']), 'Icon to text in a pill, small.')]},
        'radius': {'tokens': [
            tok('radius-card', px(t['radius']['card']), 'Cards and panels (Theme card()).'),
            tok('radius-capsule', '999px', 'Buttons and pills (SwiftUI Capsule).')]},
        'size': {'tokens': [
            tok('button-height', px(b['regular']['height']), 'Regular button height.'),
            tok('button-height-small', px(b['small']['height']), 'Small button height.'),
            tok('button-height-mini', px(b['mini']['height']), 'Mini button height.'),
            tok('button-icon', px(b['regular']['iconSize']), 'Button icon, regular.'),
            tok('button-icon-small', px(b['small']['iconSize']), 'Button icon, small and mini.'),
            tok('pill-height', px(p['regular']['height']), 'Regular pill height.'),
            tok('pill-height-small', px(p['small']['height']), 'Small pill height.'),
            tok('icon-button', px(t['iconButton']['size']), 'IconButton, default size.'),
            tok('tile', px(t['size']['tile']), 'Tile, default size.')]},
    }


def ds_css(d):
    """tokens.css: one `--name` per token; an alias reads its target; type styles as --<style>-size and -weight."""
    def value(v):
        return f'var(--{v[1:-1]})' if v.startswith('{') else v
    colors = ' '.join(f'--{x["name"]}: {value(x["value"])};' for x in d['color']['tokens'])
    rest = ' '.join(f'--{x["name"]}: {x["value"]};' for fam in ('spacing', 'radius', 'size') for x in d[fam]['tokens'])
    fonts = ' '.join(f'--font-{k}: {v};' for k, v in d['type']['families'].items())
    styles = ' '.join(f'--{s["name"]}-size: {s["fontSize"]}; --{s["name"]}-weight: {s["fontWeight"]};'
                      for g in d['type']['groups'] for s in g['styles'])
    return (f'/* {d["name"]} — generated from tokens.json by apps/distill/design/tokens.py (Theme.swift); never edit by hand */\n'
            f':root, [data-theme="light"] {{{colors}}}\n:root {{{rest} {fonts} {styles}}}\n')


def outputs():
    t = theme()
    d = ds_tokens(t)
    return {OUT: json.dumps(t, indent=2) + '\n', DS_JSON: json.dumps(d, indent=2, ensure_ascii=False) + '\n', DS_CSS: ds_css(d)}


def main(argv):
    files = outputs()
    if '--check' in argv:
        stale = [p for p, text in files.items() if (open(p, encoding='utf-8').read() if os.path.exists(p) else '') != text]
        if stale:
            print('out of date with Theme.swift: ' + ', '.join(os.path.relpath(p) for p in stale)
                  + ': run python3 apps/distill/design/tokens.py', file=sys.stderr)
            return 1
        return 0
    for p, text in files.items():
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, 'w', encoding='utf-8') as f:
            f.write(text)
        print('wrote', os.path.relpath(p))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

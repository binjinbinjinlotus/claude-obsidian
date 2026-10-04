#!/usr/bin/env python3
"""tokens.json from clients/macos/Sources/Distill/Theme.swift (colours, type, button and pill sizes, radii, spacing).

    python3 apps/distill/design/tokens.py           # rewrite tokens.json
    python3 apps/distill/design/tokens.py --check   # exit 1 when tokens.json is out of date

Theme.swift is the source of truth; never edit tokens.json by hand. Standard library only.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.abspath(__file__))
THEME = os.path.join(ROOT, '..', 'clients', 'macos', 'Sources', 'Distill', 'Theme.swift')
OUT = os.path.join(ROOT, 'tokens.json')


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


def render():
    with open(THEME, encoding='utf-8') as f:
        return json.dumps(extract(f.read()), indent=2) + '\n'


def main(argv):
    text = render()
    if '--check' in argv:
        cur = open(OUT, encoding='utf-8').read() if os.path.exists(OUT) else ''
        if cur != text:
            print('tokens.json is out of date with Theme.swift: run python3 apps/distill/design/tokens.py', file=sys.stderr)
            return 1
        return 0
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write(text)
    print('wrote', os.path.relpath(OUT))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

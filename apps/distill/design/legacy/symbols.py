"""Icon names on the boards → SF Symbol names used by the Swift views, and SVG → one path d
(components draw icons as <path d="{{d}}">, so circles and rects become path data)."""
import re

SF = {'check': 'checkmark', 'plus': 'plus', 'send': 'paperplane', 'refresh': 'arrow.clockwise', 'copy': 'doc.on.doc', 'trash': 'trash',
      'restore': 'clock.arrow.circlepath', 'undo': 'arrow.uturn.backward', 'ext': 'arrow.up.right.square', 'pencil': 'pencil', 'x': 'xmark',
      'link': 'link', 'down': 'chevron.down', 'right': 'chevron.right', 'search': 'magnifyingglass', 'slack': 'text.bubble', 'jira': 'ticket',
      'page': 'doc.text', 'mail': 'envelope', 'note': 'note.text', 'person': 'person', 'flag': 'flag', 'cal': 'calendar',
      'filter': 'line.3.horizontal.decrease', 'dots': 'ellipsis', 'globe': 'globe', 'lock': 'lock', 'warn': 'exclamationmark.circle',
      'list': 'list.bullet', 'sort': 'arrow.up.arrow.down', 'hash': 'number', 'gear': 'gearshape', 'bolt': 'bolt', 'inbox': 'tray',
      'review': 'checkmark.square', 'ask': 'bubble.left', 'tag': 'tag', 'actions': 'checklist', 'grip': 'circle.grid.2x2', 'clock': 'clock',
      'todo': 'checkmark.circle'}
EXTRA = {'play': 'M7 4l13 8-13 8z', 'square.and.arrow.down': 'M12 3v12M7 10l5 5 5-5M4 19h16',
         'sparkles': 'M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z', 'arrow.up': 'M12 19V5M5 12l7-7 7 7',
         'progress.indicator': 'M12 3a9 9 0 1 1-9 9'}


def _n(v):
    return float(v)


def to_d(svg):
    out = []
    for tag, attrs in re.findall(r'<(path|circle|rect|line|polyline)\b([^>]*)/?>', svg):
        a = dict(re.findall(r'([a-z-]+)="([^"]*)"', attrs))
        if tag == 'path':
            out.append(a['d'])
        elif tag == 'circle':
            cx, cy, r = _n(a['cx']), _n(a['cy']), _n(a['r'])
            out.append(f'M{cx - r:g} {cy:g}a{r:g} {r:g} 0 1 0 {2 * r:g} 0a{r:g} {r:g} 0 1 0 {-2 * r:g} 0')
        elif tag == 'rect':
            x, y, w, h, rx = _n(a['x']), _n(a['y']), _n(a['width']), _n(a['height']), _n(a.get('rx', 0))
            out.append(f'M{x + rx:g} {y:g}h{w - 2 * rx:g}a{rx:g} {rx:g} 0 0 1 {rx:g} {rx:g}v{h - 2 * rx:g}a{rx:g} {rx:g} 0 0 1 {-rx:g} {rx:g}'
                       f'h{-(w - 2 * rx):g}a{rx:g} {rx:g} 0 0 1 {-rx:g} {-rx:g}v{-(h - 2 * rx):g}a{rx:g} {rx:g} 0 0 1 {rx:g} {-rx:g}z')
        elif tag == 'line':
            out.append(f'M{a["x1"]} {a["y1"]}L{a["x2"]} {a["y2"]}')
        elif tag == 'polyline':
            pts = a['points'].split()
            out.append('M' + 'L'.join(p.replace(',', ' ') for p in pts))
    return ''.join(out)


def symbols(P):
    """SF name → path d for every board icon."""
    d = {SF[k]: to_d(v) for k, v in P.items() if k in SF}
    d.update(EXTRA)
    return d

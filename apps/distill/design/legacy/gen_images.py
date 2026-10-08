#!/usr/bin/env python3
"""Board: images stay inside the text; hover → Extract content (ImagesInline.dc.html)."""
import json, os
import re as _re
def dc(name, w='auto', h='auto', **props):
    a = ' '.join(f'{_re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), k)}="{v}"' for k, v in props.items() if v is not None)
    return f'<dc-import name="{name}" {a} hint-size="{w},{h}"></dc-import>'
S = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.join(S, 'distill-design', 'project')

INK, MUTED, FAINT, PANEL, LINE, BLUE = '#1D1C1A', '#6B6862', '#9B978F', '#F6F5F2', '#ECEAE5', '#1F6FEB'
SPARK = '<svg width="12" height="12" viewBox="0 0 24 24" fill="{c}" aria-hidden="true"><path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"></path></svg>'
XSVG = '<svg width="9" height="9" viewBox="0 0 24 24" fill="none" stroke="{c}" stroke-width="3" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"></path></svg>'
IMGSVG = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="#48463F" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="4" width="18" height="16" rx="3"></rect><circle cx="9" cy="10" r="2"></circle><path d="M21 16l-5-5-9 9"></path></svg>'


def p(t, size=13):
    return f'<div style="font-size: {size}px; line-height: 1.55; color: #2A2925">{t}</div>'


def card_img(h=150, w='78%', kind='card'):
    """A stand-in for a pasted screenshot / photo at its own aspect ratio."""
    if kind == 'card':
        inner = ('<div style="position: absolute; left: 16px; top: 14px; right: 16px; display: flex; flex-direction: column; gap: 6px">'
                 '<span style="font: 800 13px \'Bricolage Grotesque\', sans-serif; color: #1F3B6E">Gyokuro brewing card</span>'
                 + ''.join(f'<span style="height: 7px; width: {x}%; border-radius: 4px; background: rgba(31,59,110,.18)"></span>' for x in (88, 70, 80, 55, 64))
                 + '</div>')
        bg = '#E3EEFF'
    else:
        inner = '<div style="position: absolute; inset: 0; background: linear-gradient(160deg, #DDF2FF 0 45%, #CDEBC0 45% 100%)"></div><span style="position: absolute; left: 30%; bottom: 18%; width: 34%; height: 30%; border-radius: 50% 50% 12px 12px; background: #F4E3C3"></span>'
        bg = '#DDF2FF'
    return f'<div style="position: relative; width: {w}; height: {h}px; border-radius: 10px; overflow: hidden; background: {bg}; box-shadow: 0 0 0 1px rgba(29,28,26,.06)">{inner}{{over}}</div>'


def img(over='', **kw):
    return card_img(**kw).replace('{over}', over)


def hover_bar():
    return ('<div style="position: absolute; right: 8px; top: 8px; display: flex; gap: 6px">'
            f'<span style="height: 26px; display: flex; align-items: center; gap: 6px; padding: 0 11px; border-radius: 13px; background: {BLUE}; color: #FFFFFF; font-size: 12px; font-weight: 700; box-shadow: 0 4px 12px rgba(31,111,235,.3)">{SPARK.format(c="#FFFFFF")}Extract content</span>'
            f'<span title="Remove image" style="width: 26px; height: 26px; border-radius: 13px; background: rgba(255,255,255,.95); display: flex; align-items: center; justify-content: center; box-shadow: 0 2px 6px rgba(29,28,26,.15)">{XSVG.format(c=MUTED)}</span></div>'
            '<span style="position: absolute; left: 8px; bottom: 8px; height: 20px; display: flex; align-items: center; padding: 0 8px; border-radius: 10px; background: rgba(255,255,255,.92); font-size: 10px; font-weight: 700; color: #48463F">brewing-card.png · 412 KB</span>')


def reading_over():
    return ('<div style="position: absolute; inset: 0; background: rgba(255,255,255,.55)"></div>'
            '<div style="position: absolute; inset: 0; background: linear-gradient(100deg, transparent 30%, rgba(255,255,255,.7) 50%, transparent 70%)"></div>'
            '<div style="position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); display: flex; align-items: center; gap: 8px; height: 30px; padding: 0 6px 0 12px; border-radius: 15px; background: #FFFFFF; box-shadow: 0 6px 16px rgba(29,28,26,.18); white-space: nowrap">'
            f'<span style="width: 12px; height: 12px; border-radius: 6px; border: 2px solid #D6E4FB; border-top-color: {BLUE}"></span>'
            '<span style="font-size: 12px; font-weight: 700">Reading with Haiku…</span>'
            f'<span style="height: 22px; display: flex; align-items: center; padding: 0 9px; border-radius: 11px; background: {PANEL}; font-size: 11px; font-weight: 700; color: #48463F">Cancel</span></div>')


def fail_over():
    return ('<div style="position: absolute; left: 8px; right: 8px; bottom: 8px; display: flex; align-items: center; gap: 8px; padding: 7px 8px 7px 11px; border-radius: 10px; background: #FFF4EE; box-shadow: 0 0 0 1px #FFD9C5">'
            '<span style="font-size: 11px; color: #B03A0A; font-weight: 600; flex-grow: 1">Couldn’t read this image: Claude Code isn’t signed in.</span>'
            f'<span style="font-size: 11px; font-weight: 700; color: {BLUE}">Try again</span>'
            f'<span style="font-size: 11px; font-weight: 700; color: {BLUE}">Settings</span></div>')


def extracted(note=True):
    body = ('<div style="padding: 6px 8px; margin: 0 -8px; border-radius: 8px; background: #F3FDE4">'
            + p('<b>Gyokuro brewing card</b>') + p('- 60 °C, 2 min first steep') + p('- Second steep 30 s, third 1 min')
            + p('- 6 g leaf for a 180 ml kyusu') + '</div>')
    if note:
        body += (f'<div style="display: flex; align-items: center; gap: 8px; margin-top: 4px; font-size: 11px; color: {MUTED}">'
                 f'{SPARK.format(c="#5B8C1E")}<span>Extracted from brewing-card.png by Haiku</span>'
                 f'<span style="font-weight: 700; color: {BLUE}">Undo ⌘Z</span></div>')
    return body


def editor(content, foot='One note · 1 image', btn='Add to queue', disabled=False):
    b = f'background: {"#A8C6F5" if disabled else BLUE}'
    return (f'<div style="display: flex; flex-direction: column; gap: 10px; height: 100%; box-sizing: border-box; padding: 16px 18px; border-radius: 16px; background: #FFFFFF; box-shadow: 0 0 0 1.5px {LINE}">'
            '<span style="font: 600 17px \'Bricolage Grotesque\', sans-serif">Kettle settings for the new tea set</span>'
            + toolbar() +
            f'<div style="flex-grow: 1; display: flex; flex-direction: column; gap: 8px; min-height: 0; overflow: hidden">{content}</div>'
            f'<div style="display: flex; align-items: center; gap: 8px; padding-top: 8px; border-top: 1px solid {LINE}"><span style="flex-grow: 1; font-size: 11px; color: {MUTED}">{foot}</span>'
            f'<span style="height: 28px; display: flex; align-items: center; padding: 0 13px; border-radius: 14px; {b}; color: #FFFFFF; font-size: 12px; font-weight: 700">{btn}</span></div></div>')


def toolbar():
    return dc('MarkdownStyleBar', 'auto', '28px', variant='full', image='true', size='small')


def quick(content, foot='⌘V adds an image · ⌘↩ saves', h=None):
    hh = f'height: {h}px;' if h else ''
    return (f'<div style="position: relative; isolation: isolate; width: 360px; {hh} box-sizing: border-box; display: flex; flex-direction: column; gap: 9px; padding: 12px 14px 14px">'
            f'<div style="position: absolute; inset: 0; z-index: -1">{dc("QuickShell", "100%", "100%", part="frame", width="100%", height="100%")}</div>'
            + dc('QuickShell', '100%', '22px', part='bar', title='Quick note') +
            '<span style="font: 600 15px \'Bricolage Grotesque\', sans-serif">Gyokuro at 60 °C</span>'
            f'<div style="flex-grow: 1; display: flex; flex-direction: column; gap: 7px">{content}</div>'
            f'<div style="display: flex; align-items: center; gap: 8px"><span style="height: 24px; padding: 0 8px; border-radius: 12px; background: {PANEL}; font-size: 11px; font-weight: 800; display: flex; align-items: center">Aa</span>'
            f'<span style="height: 24px; padding: 0 9px; border-radius: 12px; background: {PANEL}; font-size: 11px; font-weight: 700; display: flex; align-items: center">+ Source</span>'
            f'<span style="flex-grow: 1; font-size: 10px; color: {FAINT}">{foot}</span>'
            f'<span style="height: 28px; padding: 0 12px; border-radius: 14px; background: {BLUE}; color: #FFFFFF; font-size: 12px; font-weight: 600; display: flex; align-items: center">Add to queue</span></div></div>')


def pointer(x, y):
    return f'<svg style="position: absolute; left: {x}; top: {y}" width="16" height="20" viewBox="0 0 16 20" aria-hidden="true"><path d="M1 1l13 8-6 1.5L5 18z" fill="#1D1C1A" stroke="#FFFFFF" stroke-width="1.4"></path></svg>'


def stage(inner, extra='', pad='22px', bg='#E4E1DB'):
    return f'<div style="position: relative; height: 430px; border-radius: 18px; background: {bg}; overflow: hidden; padding: {pad}; box-sizing: border-box; display: flex; align-items: flex-start; justify-content: center">{inner}{extra}</div>'


P1 = p('The gooseneck kettle has presets. 80 °C works for sencha; I set 60 °C for the gyokuro the shop recommended.')
P2 = p('Their card had the steep times:')
P3 = p('Buy the 50 g tin next time.')

cards = [
    ('Paste: the image lands where you are typing',
     stage(editor(P1 + P2 + img(h=140) + p('Buy the 50 g tin next time.<span style="display: inline-block; width: 1.5px; height: 14px; background: #1D1C1A; vertical-align: -2px; margin-left: 1px"></span>'))),
     '⌘V, drop, or the Image button puts the image at the cursor, between your lines, at its own shape (up to the box width, 320 pt tall at most). Typing carries on under it. In the note it is saved as an attachment and embedded at that spot: <code>![[brewing-card.png]]</code>.'),
    ('Hover: Extract content',
     stage(editor(P1 + P2 + img(over=hover_bar(), h=140) + P3), pointer('70%', '170px')),
     'Hovering the image shows <b>Extract content</b> and × in its corner, and its name and size. Nothing happens to the image unless you click. Right-click has the same actions; with the image selected (click it), Delete removes it.'),
    ('Reading the image',
     stage(editor(P1 + P2 + img(over=reading_over(), h=140) + P3, foot='One note · reading 1 image…', btn='Add to queue', disabled=True)),
     'The image dims with a shimmer and “Reading with Haiku…”. You can keep typing anywhere else. Add to queue waits until the reading finishes (or you cancel). Cancel leaves the image as it was.'),
    ('Extracted: the text replaces the image',
     stage(editor(P1 + P2 + extracted() + P3, foot='One note')),
     'The text read from the image goes into the note at the image’s spot, as normal Markdown you can edit (lists, headings and tables are kept). It is tinted for a few seconds. ⌘Z or Undo brings the image back. The image is not saved.'),
    ('Couldn’t read it',
     stage(editor(P1 + P2 + img(over=fail_over(), h=140) + P3)),
     'The image stays as it was, so nothing is lost. The reason and Try again sit on the image; Settings opens AI runners. “No text found in this image” uses the same spot.'),
    ('Several images',
     stage(editor(P2 + img(h=86, w='60%') + p('My tasting setup:') + img(h=86, w='46%', kind='photo'), foot='One note · 2 images')),
     'Each image has its own hover actions and its own reading state, so you can extract one and keep the other. The footer counts images that stay: “One note · 2 images”.'),
    ('Quick note: same rules',
     stage(quick(p('Shop recommended 60 °C, 2 min first steep.', 12) + img(over=hover_bar(), h=118, w='100%'))),
     'The quick note shows pasted images inline too, with the same hover actions. The window grows to fit the image, like a few more lines of text.'),
    ('Quick note: extracted',
     stage(quick(p('Shop recommended 60 °C, 2 min first steep.', 12) + extracted())),
     'Extract content swaps the image for its text in place; the window resizes to the new content. ⌘Z restores the image.'),
    ('Which model reads images',
     stage('<div style="width: 520px; display: flex; flex-direction: column; gap: 10px; padding: 16px 18px; border-radius: 16px; background: #FFFFFF; box-shadow: 0 0 0 1.5px #ECEAE5">'
           '<span style="font: 800 15px \'Bricolage Grotesque\', sans-serif">Models for tasks</span>'
           + ''.join(f'<div style="display: flex; align-items: center; gap: 8px; padding: 8px 0; border-top: 1px solid {LINE}"><span style="flex-grow: 1; display: flex; flex-direction: column"><span style="font-size: 12px; font-weight: 700">{n}</span><span style="font-size: 11px; color: {MUTED}">{d}</span></span>'
                     + ''.join(f'<span style="height: 24px; display: flex; align-items: center; padding: 0 9px; border-radius: 12px; background: {"#E3EEFF" if hl else PANEL}; color: {BLUE if hl else INK}; font-size: 11px; font-weight: 700">{v} ▾</span>' for v in vals) + '</div>'
                     for n, d, vals, hl in [('Adding notes', 'Batches into wiki pages', ('Claude Code', 'Sonnet', 'Medium'), False),
                                            ('Ask', 'Answers from your vault', ('Claude Code', 'Sonnet', 'Medium'), False),
                                            ('Label suggestions', 'After a note is queued', ('Claude Code', 'Haiku', 'Low'), False),
                                            ('Text from images', 'When you click Extract content', ('Claude Code', 'Haiku', 'Low'), True),
                                            ('Finding actions', 'After batches and Ask answers', ('Claude Code', 'Sonnet', 'Medium'), False)])
           + '</div>'),
     'Settings → Models for tasks → <b>Text from images</b> picks the runner, model and effort. Haiku (low effort) is the default: fast and cheap for reading screenshots. The reading shows the model it uses (“Reading with Haiku…”).'),
]

COLS, H = 3, 1980


def card(i, name, stg, cap):
    return (f'<section style="display: flex; flex-direction: column; gap: 10px">'
            f'<div style="display: flex; align-items: center; gap: 8px"><span style="width: 22px; height: 22px; border-radius: 11px; background: {BLUE}; color: #FFFFFF; font-size: 11px; font-weight: 700; display: flex; align-items: center; justify-content: center">{i}</span><span style="font-size: 14px; font-weight: 700">{name}</span></div>'
            f'{stg}<span style="font-size: 12px; color: {MUTED}; line-height: 1.5">{cap}</span></section>')


grid = f'<div style="display: grid; grid-template-columns: repeat({COLS}, minmax(0, 1fr)); gap: 30px 24px">' + ''.join(card(i + 1, *c) for i, c in enumerate(cards)) + '</div>'
html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Distill — Images inside the text</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,800&amp;family=DM+Sans:wght@400;500;600;700&amp;display=swap">
<style>body{{margin:0;font-family:"DM Sans",-apple-system,sans-serif;color:#1D1C1A;-webkit-font-smoothing:antialiased}} code{{font-size:11px;background:#F6F5F2;padding:1px 4px;border-radius:4px}}</style>
</helmet>
<div style="width: 1800px; height: {H}px; box-sizing: border-box; background: #F6F5F2; padding: 34px 40px; display: flex; flex-direction: column; gap: 22px">
<div style="display: flex; flex-direction: column; gap: 8px">
<span style="font-family: 'Bricolage Grotesque', sans-serif; font-weight: 800; font-size: 28px; letter-spacing: -0.02em">Images stay inside the text</span>
<span style="font-size: 13px; color: {MUTED}; max-width: 1300px; line-height: 1.55">Every input that takes images (Write a note and the quick note) keeps a pasted image exactly where you pasted it, inside the text. There is no Keep / Extract switch: an image is kept unless you choose otherwise. Hover an image and click <b>Extract content</b> to read it right away; its text replaces the image in place and you can edit it before adding the note. ⌘Z brings the image back. Replaces the image tiles and the Keep image / Extract text switch on “Write a note” and the quick note.</span>
</div>
{grid}
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":1800,"height":{H}}}}}'>
class Component extends DCLogic {{ renderVals() {{ return {{}}; }} }}
</script>
</body>
</html>'''
open(os.path.join(PROJ, 'ImagesInline.dc.html'), 'w').write(html)
print('ok')

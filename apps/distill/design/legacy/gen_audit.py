#!/usr/bin/env python3
"""Bring rows 1–5 in line with Actions (flow 6). Re-runnable: every hand-written board is rebuilt
from its original copy in board-bak-audit/, then edited. Settings.dc.html is regenerated whole.
Run: python3 gen_audit.py   (then python3 gen_audit.py --canvas to re-place boards)"""
import json, os, re, sys
import gen_actions as G
from gen_actions import (app, ic, btn, pill, toggle, seg, select, spinner, tbadge, srow, sh1, settings_win, sources_settings,
                         trow, crow, model_ctl, found_block, item_row, nav_items, board, dc, sidebar_dc, INK, MUTED, FAINT, PANEL, LINE, BLUE, TINT,
                         LIME_INK, LIME_BG, PEACH_INK, HEAD, TYPES)

S = G.S
PROJ = G.PROJ
BAK = os.path.join(S, 'board-bak-audit')


def orig(name):
    return open(os.path.join(BAK, name)).read()


def write(name, s):
    open(os.path.join(PROJ, name), 'w').write(s)


def sub1(s, old, new, name=''):
    assert old in s, f'{name}: missing {old[:80]!r}'
    return s.replace(old, new, 1)


def swap_nav(s, active, counts=None):
    s2, n = re.subn(r'(<nav[^>]*aria-label="Sections">).*?(</nav>)', lambda m: m.group(1) + nav_items(active, counts) + m.group(2), s, count=1, flags=re.S)
    assert n == 1
    return s2


# ---------------------------------------------------------------- shared components instead of copied chrome
WIN_OUTER = re.compile(r'<div style="width: 1200px; height: (\d+)px; box-sizing: border-box; background: #EAE8E3; padding: 20px; display: flex">')
WIN_INNER = '<div style="flex-grow: 1; display: flex; border-radius: 16px; overflow: hidden; background: #FFFFFF; box-shadow: 0 0 0 1px rgba(29,28,26,0.08), 0 20px 44px rgba(29,28,26,0.14)">'


def componentize(s, name, active, sub='', **sb):
    """WindowShell (frame + controls) and Sidebar replace the copied window chrome."""
    m = WIN_OUTER.search(s)
    assert m, name
    H = int(m.group(1))
    s = s[:m.start()] + (f'<div style="position: relative; width: 1200px; height: {H}px; isolation: isolate">'
                         f'<div style="position: absolute; inset: 0; z-index: -1">{dc("WindowShell", "1200px", f"{H}px", layer="frame", width=1200, height=H)}</div>'
                         f'<div style="position: absolute; left: 38px; top: 36px; z-index: 2">{dc("WindowShell", "52px", "12px", layer="controls")}</div>') + s[m.end():]
    s = sub1(s, WIN_INNER, '<div style="position: absolute; left: 20px; top: 20px; right: 20px; bottom: 20px; display: flex; border-radius: 16px; overflow: hidden; background: #FFFFFF">', name)
    s, n = re.subn(r'<aside style="width: 220px;.*?</aside>', lambda _: sidebar_dc(active, sub, H - 40, **sb), s, count=1, flags=re.S)
    assert n == 1, name
    return s


def stylebar(s, name, variant, image=False):
    s, n = re.subn(r'<div role="toolbar" aria-label="Text style".*?</div>', lambda _: dc('MarkdownStyleBar', 'auto', '34px', variant=variant, image='true' if image else None), s, count=1, flags=re.S)
    assert n == 1, name
    return s


QUICK_WIN = re.compile(r'<div style="width: (\d+)px;  display: flex; flex-direction: column; gap: 12px; padding: 16px; position: relative; resize: both; overflow: hidden; min-width: 360px; min-height: (\d+)px; border-radius: 20px; background: #FFFFFF; box-shadow: 0 18px 40px rgba\(29,28,26,0.22\)">')
QUICK_BAR = re.compile(r'<div style="display: flex; align-items: center; gap: 8px; margin: -6px -6px -4px 0">\s*<span[^>]*>(QUICK ASK|QUICK NOTE)</span>.*?</button>\s*</div>', re.S)
QUICK_GRIP = re.compile(r'<span aria-hidden="true" title="Drag to resize" style="position: absolute; right: 6px; bottom: 6px;[^"]*"></span>')


def quickshells(s, name):
    """QuickShell frame + bar replace each copied quick window card and close bar."""
    s, n1 = QUICK_WIN.subn(lambda m: (f'<div style="width: {m.group(1)}px; display: flex; flex-direction: column; gap: 12px; padding: 12px 16px 16px; position: relative; isolation: isolate; min-height: {m.group(2)}px; box-sizing: border-box">'
                                      f'<div style="position: absolute; inset: 0; z-index: -1">{dc("QuickShell", "100%", "100%", part="frame", width="100%", height="100%")}</div>'), s)
    s, n2 = QUICK_BAR.subn(lambda m: dc('QuickShell', '100%', '22px', part='bar', title=m.group(1).capitalize()), s)
    s, n3 = QUICK_GRIP.subn('', s)
    assert n1 == n2 == n3 and n1 > 0, (name, n1, n2, n3)
    return s


# ---------------------------------------------------------------- sidebar on every app window
RECENT = dict(recentRunning='Oolong vs pu-erh caffeine', recentFailed='Summarize the hiring loop')
NAVS = {'Main.dc.html': ('Queue', '', {}), 'MainLoading.dc.html': ('Queue', '', {'status': 'Sonnet · working'}),
        'Capture.dc.html': ('Queue', '', {'reviewCount': '0'}), 'CaptureLoading.dc.html': ('Queue', '', {'reviewCount': '0'}),
        'Review.dc.html': ('Review', '', {'status': 'Sonnet · waiting on you'}), 'ReviewLoading.dc.html': ('Review', '', {'status': 'Sonnet · working'}),
        'Ask.dc.html': ('Ask', '', dict(RECENT, recentOpen='Green tea water temperature')), 'AskLoading.dc.html': ('Ask', '', dict(RECENT)),
        'History.dc.html': ('History', 'chats', {}), 'Notes.dc.html': ('Labels', '', {}), 'NotesLoading.dc.html': ('Labels', '', {})}

RECENT_HEAD = '<div style="font-size: 11px; font-weight: 700; color: #9B978F; padding: 0 12px; letter-spacing: 0.06em">RECENT QUESTIONS</div>'


def recent_rows(current=None):
    """Answering and failed questions in the sidebar's Recent questions (built behaviour)."""
    out = ''
    if current:
        out += (f'<div style="display: flex; align-items: center; gap: 7px; padding: 5px 8px 5px 12px; border-radius: 8px; background: #FFFFFF; box-shadow: 0 0 0 1px {LINE}">{spinner(BLUE, 11)}'
                f'<span style="flex-grow: 1; min-width: 0; display: flex; flex-direction: column"><span style="font-size: 13px; color: {INK}; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{current}</span>'
                f'<span style="font-size: 10px; color: {MUTED}">answering…</span></span></div>')
    out += (f'<div style="display: flex; align-items: center; gap: 7px; padding: 5px 8px 5px 12px">{spinner(BLUE, 11)}'
            f'<span style="flex-grow: 1; min-width: 0; display: flex; flex-direction: column"><span style="font-size: 13px; color: #48463F; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">Oolong vs pu-erh caffeine</span>'
            f'<span style="font-size: 10px; color: {MUTED}">answering…</span></span>'
            f'<span title="Stop" style="font-size: 11px; font-weight: 700; color: {BLUE}">Stop</span></div>'
            f'<div style="display: flex; align-items: center; gap: 7px; padding: 5px 8px 5px 12px">{ic("warn", 12, PEACH_INK, 2.2)}'
            f'<span style="flex-grow: 1; min-width: 0; display: flex; flex-direction: column"><span style="font-size: 13px; color: #48463F; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">Summarize the hiring loop</span>'
            f'<span style="font-size: 10px; color: {PEACH_INK}">couldn’t answer</span></span>{ic("x", 11, FAINT, 2.6)}</div>')
    return out


def ask_items():
    return [dict(t='todo', text='Ask the shop for the gyokuro water temperature', why='Gap: your vault has no temperature for gyokuro', cite='1', btn='Add'),
            dict(t='slack', text='Ask Mei which temperature she uses for gyokuro', why='Mei brews it for the club', cite='2', btn='Create draft', to='To Mei Tanaka')]


def answer_buttons():
    return (f'<span style="width: 1px; height: 18px; background: {LINE}; align-self: center"></span>'
            + btn('Add to to-do', 'secondary', 34, 13, 'plus') + btn('', 'secondary', 34, 13, 'down', extra='padding: 0 10px; margin-left: -4px') + btn('Send to', 'secondary', 34, 13, 'send'))


def do_app_boards():
    for name, (active, sub, sb) in NAVS.items():
        s = componentize(orig(name), name, active, sub, **sb)
        if name in ('Review.dc.html', 'ReviewLoading.dc.html'):
            s = stylebar(s, name, 'compact')
        if name in ('Capture.dc.html', 'CaptureLoading.dc.html'):
            s = stylebar(s, name, 'full', image=True)

        if name == 'MainLoading.dc.html':
            s = sub1(s, 'Claude Code · Sonnet · 1:52 · nothing is written until you approve', 'Claude Code · Sonnet · started at 3:41 AM · nothing is written until you approve', name)
            s = sub1(s, '<span style="color: #9B978F">Ready for review</span>', '<span style="color: #9B978F">Ready for review</span><span style="color: #9B978F">Finding actions (after you apply)</span>', name)
            s = sub1(s, "'Pasted just now · 1.8 MB'", "'Pasted at 3:40 AM · 1.8 MB'", name)
            s = sub1(s, "'Dropped 4 min ago · 2.3 MB'", "'Dropped at 3:36 AM · 2.3 MB'", name)

        if name == 'ReviewLoading.dc.html':
            s = sub1(s, 'Writing to Research · 0:03 · the card unlocks when the vault write finishes', 'Writing to Research · started at 3:45 PM · then Distill finds actions in these notes', name)

        if name == 'Review.dc.html':
            strip = (f'<div style="display: flex; align-items: center; gap: 10px; padding: 10px 14px; border-radius: 14px; background: #F2F7FF">{ic("actions", 15, BLUE)}'
                     f'<span style="font-size: 13px; color: #48463F; flex-grow: 1">After you apply, Distill looks for actions in these 2 notes with Sonnet and asks you to confirm them.</span>'
                     f'<a href="ActionsOverview.dc.html" style="font-size: 12px; font-weight: 700; text-decoration: none">How it works</a></div>\n')
            s = sub1(s, '<div style="display: flex; flex-direction: column; gap: 4px">\n<div style="display: flex; align-items: baseline', strip + '<div style="display: flex; flex-direction: column; gap: 4px">\n<div style="display: flex; align-items: baseline', name)
            s = sub1(s, '<sc-for list="{{changes}}" as="c" hint-placeholder-count="5">', '<sc-for list="{{changes}}" as="c" hint-placeholder-count="4">', name)


        if name == 'Ask.dc.html':
            s = sub1(s, 'from 2 pages · 4s', 'from 2 pages · answered at 3:12 PM', name)
            fb = found_block(('pending', 'pending'), ask_items(), compact=True)
            s = sub1(s, '<div style="display: flex; gap: 8px">\n<button type="button" style="height: 34px; display: flex; align-items: center; gap: 6px; padding: 0 14px; border: none; border-radius: 17px; background: #E3EEFF',
                     fb + '\n<div style="display: flex; gap: 8px">\n<button type="button" style="height: 34px; display: flex; align-items: center; gap: 6px; padding: 0 14px; border: none; border-radius: 17px; background: #E3EEFF', name)
            s = sub1(s, 'font-size: 13px; font-weight: 600">Copy</button>\n</div>', 'font-size: 13px; font-weight: 600">Copy</button>\n' + answer_buttons() + '\n</div>', name)
            # the Gap callout now has a matching to-do in the block: keep it to one line
            # the Gap callout becomes the first found item (same fact, now actionable)
            s, n = re.subn(r'<div style="display: flex; align-items: center; gap: 10px; padding: 12px 14px; border-radius: 14px; background: #FFF4EE">\n<svg.*?</svg>\n<span[^>]*>Gap: nothing in your vault on gyokuro water temperature\. Drop a source in the queue to fill it\.</span>\n</div>\n', '', s, count=1, flags=re.S)
            assert n == 1, 'gap'

        if name == 'AskLoading.dc.html':
            s = sub1(s, 'Claude Code · Sonnet · Medium · 15 pages · 0:14', 'Claude Code · Sonnet · Medium · 15 pages · started at 3:12 PM', name)

        if name == 'NotesLoading.dc.html':
            s = sub1(s, 'Haiku · 0:41 · you can leave this screen', 'Haiku · started at 3:20 PM · you can leave this screen', name)

        if name in ('Capture.dc.html', 'CaptureLoading.dc.html'):
            # the Keep / Extract image data is no longer rendered (images live inside the text)
            s, n = re.subn(r',?\nimages: \[.*?\n\]', '', s, count=1, flags=re.S)
            assert n == 1, name

        if name == 'History.dc.html':
            s = sub1(s, '<div style="display: flex; width: fit-content; padding: 3px; border-radius: 16px; box-shadow: 0 0 0 1px #ECEAE5"><span style="padding: 6px 14px; font-size: 13px; font-weight: 700; color: #6B6862">Jobs</span><span style="padding: 6px 14px; border-radius: 13px; background: #1F6FEB; color: #FFFFFF; font-size: 13px; font-weight: 700">Ask chats</span></div>', '', name)
            s = sub1(s, '<span style="font-family: \'Bricolage Grotesque\', sans-serif; font-weight: 800; font-size: 28px">History</span>',
                     '<div style="display: flex; flex-direction: column; gap: 2px"><span style="font-size: 11px; font-weight: 800; letter-spacing: .06em; color: #9B978F">HISTORY</span><span style="font-family: \'Bricolage Grotesque\', sans-serif; font-weight: 800; font-size: 28px">Ask chats</span></div>', name)
            rows = (f'<div style="display: flex; align-items: flex-start; gap: 12px; padding: 12px; border-radius: 14px; background: transparent">'
                    f'<span style="width: 34px; height: 34px; flex-shrink: 0; border-radius: 17px; background: {TINT}; display: flex; align-items: center; justify-content: center">{spinner(BLUE, 14)}</span>'
                    f'<span style="display: flex; flex-direction: column; gap: 3px; flex-grow: 1; min-width: 0"><span style="font-size: 14px; font-weight: 600; line-height: 1.3">Oolong vs pu-erh caffeine</span>'
                    f'<span style="font-size: 12px; color: {MUTED}; white-space: nowrap">Asked today at 3:09 AM · answering…</span></span>'
                    f'<span style="height: 24px; display: flex; align-items: center; padding: 0 10px; border-radius: 12px; background: {PANEL}; font-size: 12px; font-weight: 600">Stop</span></div>'
                    f'<div style="display: flex; align-items: flex-start; gap: 12px; padding: 12px; border-radius: 14px; background: transparent">'
                    f'<span style="width: 34px; height: 34px; flex-shrink: 0; border-radius: 17px; background: #FFE4D6; display: flex; align-items: center; justify-content: center">{ic("warn", 15, PEACH_INK, 2.2)}</span>'
                    f'<span style="display: flex; flex-direction: column; gap: 3px; flex-grow: 1; min-width: 0"><span style="font-size: 14px; font-weight: 600; line-height: 1.3">Summarize the hiring loop</span>'
                    f'<span style="font-size: 12px; color: {PEACH_INK}; white-space: nowrap">Asked today at 3:07 AM · couldn’t answer</span></span>'
                    f'<span title="Dismiss" style="padding-top: 6px">{ic("x", 13, FAINT, 2.4)}</span></div>')
            s = sub1(s, '<div style="display: flex; flex-direction: column; gap: 2px"><div style="display: flex; align-items: flex-start; gap: 12px; padding: 12px; border-radius: 14px; background: #F6F5F2">',
                     '<div style="display: flex; flex-direction: column; gap: 2px">' + rows + '<div style="display: flex; align-items: flex-start; gap: 12px; padding: 12px; border-radius: 14px; background: #F6F5F2">', name)
            s = sub1(s, 'Never a running count like "14 mins, 41 secs. ago".', 'Never a running count like "14 mins, 41 secs. ago". A question still being answered (after New chat or opening another chat) shows "answering…" with Stop, here; Ask’s Recent questions shows it with a spinner. One that failed shows "couldn’t answer" with × here, and just its title in Recent questions (as in Swift). Jobs, Ask chats and Actions are sub-items of History in the sidebar.', name)
        write(name, s)


# ---------------------------------------------------------------- Loading: clock times + new patterns
def section(n, title, inner, cap):
    return (f'<section style="display: flex; flex-direction: column; gap: 10px"><span style="font-size: 14px; font-weight: 700">{n} · {title}</span>'
            f'<div style="flex-grow: 1; border-radius: 20px; background: #FFFFFF; box-shadow: 0 0 0 1px #ECEAE5; padding: 20px; display: flex; flex-direction: column; gap: 12px; overflow: hidden">{inner}</div>'
            f'<span style="font-size: 12px; color: #6B6862; line-height: 1.45">{cap}</span></section>')


def do_loading():
    name = 'Loading.dc.html'
    s = orig(name)
    for a, b in [('Sonnet · Medium · 6 pages · 0:14', 'Sonnet · Medium · 6 pages · started at 3:12 PM'),
                 ('Haiku · Low · 0:06 · Esc keeps it running', 'Haiku · Low · started at 3:14 PM · Esc keeps it running'),
                 ('Haiku · 0:03', 'Haiku · started at 3:20 PM'),
                 ('Haiku · 0:41 · you can leave this screen', 'Haiku · started at 3:21 PM · you can leave this screen'),
                 ('Claude Code · Sonnet · 1:52 · nothing is written until you approve', 'Claude Code · Sonnet · started at 3:41 PM · nothing is written until you approve'),
                 ('Still working · 2:10', 'Still working · started at 3:12 PM'),
                 ('<span style="font-size: 16px">⏳</span>', ic('clock', 18, '#B7791F', 2.2)),
                 ('an elapsed timer appears after 3 s', 'the start shows as a clock time (“started at 3:41 PM”, never a ticking timer)'),
                 ('Settings → runner cards use the same spinner', 'Settings → AI runners: runner cards use the same spinner')]:
        s = sub1(s, a, b, name)
    # Finding actions as the last batch step
    s = sub1(s, "step('Ready for your review', 'todo')", "step('Ready for your review', 'todo'), step('After you apply: finding actions', 'todo')", name)
    H = 1760
    s = quickshells(s, name)
    s = s.replace('width: 1600px; height: 1180px', f'width: 1600px; height: {H}px').replace('"height":1180', f'"height":{H}')
    it = [dict(t='todo', text='Book the tasting room for Saturday', why='You said you would book it', cite='1', btn='Add'),
          dict(t='slack', text='Tell Mei the room is booked', why='She is bringing the tea', cite='1', btn='Create draft')]
    det = (f'<div style="display: flex; align-items: center; gap: 10px; padding: 12px 14px; border-radius: 14px; background: #F2F7FF">{spinner()}<span style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1">'
           f'<span style="font-size: 13px; font-weight: 700">Finding actions in 2 notes…</span><span style="font-size: 11px; color: {MUTED}">Sonnet · started at 3:44 PM · after the batch was applied</span></span></div>'
           + ''.join(f'<div style="display: flex; align-items: center; gap: 10px"><span style="width: 28px; height: 28px; border-radius: 8px; background: #ECEAE5"></span><div style="display: flex; flex-direction: column; gap: 6px; flex-grow: 1"><span class="sk" style="height: 8px; width: 24%"></span><span class="sk" style="height: 11px; width: {w}%"></span></div></div>' for w in (70, 54))
           + f'<div style="display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 12px; background: #F6F5F2">{spinner(BLUE, 12)}<span style="font-size: 12px; font-weight: 600; flex-grow: 1">Looking for actions in this answer…</span><span style="font-size: 11px; color: {MUTED}">Ask · Sonnet</span></div>')
    shim = lambda t: (f'<div style="position: relative; display: flex; flex-direction: column; gap: 8px; padding: 12px 14px; border-radius: 12px; background: #F6F5F2; overflow: hidden">'
                      + ''.join(f'<span class="sk" style="height: 10px; width: {w}%"></span>' for w in (92, 84, 60))
                      + f'<div style="position: absolute; left: 50%; top: 50%; transform: translate(-50%, -50%); display: flex; align-items: center; gap: 8px; height: 30px; padding: 0 6px 0 12px; border-radius: 15px; background: #FFFFFF; box-shadow: 0 6px 16px rgba(29,28,26,.18); white-space: nowrap">{spinner()}<span style="font-size: 12px; font-weight: 700">{t}</span><span style="height: 22px; display: flex; align-items: center; padding: 0 9px; border-radius: 11px; background: #F6F5F2; font-size: 11px; font-weight: 700; color: #48463F">Cancel</span></div></div>')
    drafts = (f'<div style="display: flex; align-items: center; gap: 8px">{tbadge("slack", 26, 8, 13)}<span style="font-size: 12px; font-weight: 700; flex-grow: 1">Message to Mei</span>{pill(spinner(BLUE, 10) + "Writing", TINT, BLUE, 22, 11, 700)}</div>'
              + shim('Writing with Sonnet…')
              + f'<div style="display: flex; align-items: center; gap: 8px; margin-top: 4px">{tbadge("slack", 26, 8, 13)}<span style="font-size: 12px; font-weight: 700; flex-grow: 1">After your edit</span>{pill(spinner(BLUE, 10) + "Polishing", TINT, BLUE, 22, 11, 700)}</div>'
              + shim('Polishing with Sonnet…'))
    create = (f'<div style="display: flex; align-items: center; gap: 8px">{tbadge("jira", 26, 8, 13)}<span style="font-size: 12px; font-weight: 700; flex-grow: 1">Cap payment client retries at 3</span>{pill(spinner(BLUE, 10) + "Creating", TINT, BLUE, 22, 11, 700)}</div>'
              + shim('Creating in Jira…').replace('<span style="height: 22px; display: flex; align-items: center; padding: 0 9px; border-radius: 11px; background: #F6F5F2; font-size: 11px; font-weight: 700; color: #48463F">Cancel</span>', '')
              + f'<div style="display: flex; align-items: center; gap: 10px; padding: 10px 12px; border-radius: 12px; background: #F2F7FF; box-shadow: 0 0 0 1px #D6E4FB">{spinner()}<span style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1"><span style="font-size: 12px; font-weight: 700; color: {BLUE}">Waiting for you to sign in, in your browser</span><span style="font-size: 11px; color: {MUTED}">We opened acme.atlassian.net. The draft is safe.</span></span><span style="font-size: 11px; font-weight: 700">Cancel</span></div>')
    new = (section(7, 'Finding actions', det, 'After a batch is applied, and when an Ask answer finishes. Shimmer rows hold the place of the items still coming; nothing is added until you confirm. Same pattern in Actions’ lists.')
           + section(8, 'Writing and polishing a draft', drafts, 'Writing a Slack, Jira or Confluence draft, and the AI pass after you edit one: the text dims with a shimmer, the model is named, Cancel keeps what was there.')
           + section(9, 'Creating in Jira or Confluence', create, 'Creating can’t be cancelled halfway; it takes a second or two. Signing in happens in the browser while the card waits. Errors follow section 6: what failed, the draft is safe, one next step.'))
    s = sub1(s, '</section>\n\n</div>\n</div>\n</x-dc>', '</section>\n' + new + '\n</div>\n</div>\n</x-dc>', name)
    write(name, s)
    return H


# ---------------------------------------------------------------- QuickActions: 560 × 214, + Source, found block
def do_quick():
    name = 'QuickActions.dc.html'
    s = orig(name)
    H = 2140
    s = s.replace('width: 1600px; height: 1320px', f'width: 1600px; height: {H}px').replace('"height":1320', f'"height":{H}')
    s = sub1(s, 'grid-template-columns: repeat(3, minmax(0, 1fr)); grid-auto-rows: minmax(0, 1fr)', 'grid-template-columns: repeat(2, minmax(0, 1fr)); grid-auto-rows: auto', name)
    s = s.replace('flex-grow: 1; position: relative; border-radius: 20px; background: #DCD9D2; overflow: hidden', 'flex-grow: 1; min-height: 470px; position: relative; border-radius: 20px; background: #DCD9D2; overflow: hidden')
    s = s.replace('<div style="width: 380px;  display: flex;', '<div style="width: 560px;  display: flex;').replace('<div style="width: 400px;  display: flex;', '<div style="width: 560px;  display: flex;')
    s = s.replace('min-width: 360px; min-height: 160px;', 'min-width: 360px; min-height: 214px;')
    s = sub1(s, 'Hover the flask, pick an action, and a small window opens in the center of the screen, like Spotlight. The main app stays closed.',
             'Hover the flask, pick an action, and a small window opens in the center of the screen, like Spotlight. The main app stays closed. Windows open at 560 × 214, grow with their content and start fresh after you close them (see Quick windows: size, growth, scrolling).', name)
    # menu: Actions entry with its count
    s = sub1(s, "{ label: 'Open Distill', key: '',", "{ label: 'Actions', key: '9', icon: 'M9 6h11M9 12h11M9 18h11M3.5 6l1.5 1.5L7.5 5M3.5 12l1.5 1.5L7.5 11M3.5 18l1.5 1.5L7.5 17', ...plain },\n{ label: 'Open Distill', key: '',", name)
    s = sub1(s, 'A click still opens the full app.</span>', 'A click still opens the full app. Actions opens the main window on Actions; the number is what’s waiting on you there.</span>', name)
    # window 2: an answer with actions
    s = sub1(s, 'value="Best water temp for sencha?"', 'value="What do I still owe the tea club?"', name)
    s = sub1(s, '70–80 °C. Boiling water pulls out bitter catechins.</p>', 'Book the tasting room for Saturday and tell Mei so she can bring the new tin [1].</p>', name)
    s = sub1(s, '</span>\nBrewing Green Tea\n</a>', '</span>\nTea club planning\n</a>', name)
    it2 = [dict(t='todo', text='Book the tasting room for Saturday', why='', cite='1', btn='Add'),
           dict(t='slack', text='Tell Mei the room is booked and ask her to bring the tin', why='', cite='1', btn='Create draft')]
    it4 = [dict(t='jira', text='Cap payment client retries at 3 with backoff', why='', cite='1', btn='Create draft'),
           dict(t='todo', text='Stop retrying on 503 in the auth client', why='', cite='1', btn='Add')]
    marker = '<div style="margin-top: auto; display: flex; flex-direction: column; gap: 8px">'
    parts = s.split(marker)
    assert len(parts) == 3, len(parts)
    s = parts[0] + found_block(('pending', 'pending'), it2, compact=True) + marker + parts[1] + found_block(('dup', 'pending'), it4, compact=True) + marker + parts[2]
    s = sub1(s, 'Type and press Return. The model and filter row stays at the bottom, just above the footer, however big the window gets; the answer fills the space between. × or Esc closes; drag the bottom-right corner to make the window bigger (it remembers the size). The short answer appears with its sources. Follow-ups stay in the same chat; "Continue in Distill" opens it in the full Ask screen.',
             'Type and press Return. The model and filter row stays at the bottom, just above the footer, however big the window gets; the answer fills the space between. When the answer holds actions, a compact “Found in this answer” block lists them to confirm: Add, Create draft, × or Add all (see Actions · from Ask answers). × or Esc closes and the next window opens fresh; a size you drag is remembered. Follow-ups stay in the same chat; “Continue in Distill” opens it in the full Ask screen.', name)
    # window 3: source moves to the footer
    s, n = re.subn(r'<div style="display: flex; gap: 6px; flex-wrap: wrap; align-items: center">\n<span style="height: 24px; display: flex; align-items: center; padding: 0 9px; border-radius: 12px; background: #1F6FEB; color: #FFFFFF; font-size: 11px; font-weight: 700">In person</span>\n</div>\n', '', s, count=1)
    assert n == 1
    s = sub1(s, '<span style="font-size: 11px; color: #9B978F; flex-grow: 1">⌘V adds an image · ⌘↩ saves</span>',
             '<span style="height: 26px; display: flex; align-items: center; padding: 0 10px; border-radius: 13px; background: #E9FBC9; color: #3D6110; font-size: 11px; font-weight: 700">In person ▾</span><span style="font-size: 11px; color: #9B978F; flex-grow: 1">⌘↩ saves</span>', name)
    s = sub1(s, '× or Esc closes (counts as Skip once queued); drag the corner to resize — the note field grows with the window.',
             'Opens at 560 × 214 and grows as you type. The source is picked in the footer (+ Source, here In person ▾). × or Esc closes (counts as Skip once queued) and the next window opens fresh; drag the corner to resize.', name)
    s = sub1(s, 'Both start from your Settings defaults and apply to this chat only.', 'Both start from your Settings defaults and apply to this chat only. In the Found block, an item already in Actions says “Already in Jira tickets” instead of being added twice.', name)
    s = quickshells(s, name)
    write(name, s)
    return H


# ---------------------------------------------------------------- Settings: every section in the nav layout
def stepper(v, unit):
    return (f'<div style="display: flex; align-items: center; gap: 6px; padding: 8px; border-radius: 14px; background: {PANEL}">'
            f'<span style="width: 28px; height: 28px; border-radius: 14px; background: #FFFFFF; box-shadow: 0 1px 2px rgba(29,28,26,.1); display: flex; align-items: center; justify-content: center">−</span>'
            f'<span style="display: flex; flex-direction: column; align-items: center; min-width: 54px"><span style="{HEAD}; font-weight: 800; font-size: 24px">{v}</span><span style="font-size: 11px; color: {MUTED}">{unit}</span></span>'
            f'<span style="width: 28px; height: 28px; border-radius: 14px; background: #FFFFFF; box-shadow: 0 1px 2px rgba(29,28,26,.1); display: flex; align-items: center; justify-content: center">+</span></div>')


def h2(t, sub='', first=False):
    s = f'<span style="font-size: 13px; color: {MUTED}; line-height: 1.5">{sub}</span>' if sub else ''
    top = '' if first else f'border-top: 1px solid {LINE}; padding-top: 26px; margin-top: 8px;'
    return f'<div style="{top} display: flex; flex-direction: column; gap: 4px"><h2 style="margin: 0; {HEAD}; font-weight: 800; font-size: 22px; letter-spacing: -.02em">{t}</h2>{s}</div>'


def settings_full():
    vault_cards = ''.join(f'<div style="display: flex; flex-direction: column; gap: 10px; padding: 16px; border-radius: 18px; box-shadow: {sh}"><span style="width: 34px; height: 34px; border-radius: 11px; background: {c}; color: {k}; display: flex; align-items: center; justify-content: center; {HEAD}; font-weight: 800">{i}</span><span style="font-size: 14px; font-weight: 600">{n}</span><span style="font-size: 12px; color: {MUTED}">{q}</span></div>'
                          for i, n, q, c, k, sh in [('R', 'Research', 'Queue: Distill Queue/research', '#FFE0EC', '#A3245A', f'0 0 0 2px {BLUE}'), ('W', 'Work notes', 'Queue: vault inbox', '#DDF2FF', '#0B5C86', f'0 0 0 1px {LINE}')])
    c = sh1('General', 'Vaults, batching, sources, labels, Ask history and shortcuts.')
    c += h2('Vaults', 'The vault Distill adds notes to, and where each one’s queue lives.', True)
    c += f'<div style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px">{vault_cards}<div style="border-radius: 18px; border: 1.5px dashed #D6D3CC; display: flex; align-items: center; justify-content: center; color: {BLUE}; font-size: 13px; font-weight: 600">+ Add vault</div></div>'
    c += h2('Batching', 'When queued notes go into the vault.')
    c += srow('Batch every', 'Automatic: runs on this schedule. Off: only when you press Process now.', toggle(True), border=False)
    c += f'<div style="display: flex; gap: 12px">{stepper(0, "days")}{stepper(2, "hours")}{stepper(30, "minutes")}</div>'
    c += f'<div style="display: flex; gap: 8px">' + ''.join(pill(p, BLUE if p == '2h 30m' else PANEL, '#FFFFFF' if p == '2h 30m' else INK, 30, 13, 600) for p in ['5 min', '15 min', '1 hour', '2h 30m', 'Daily']) + '</div>'
    c += srow('Wait before picking up a file', 'A file must stay unchanged this long before a batch takes it, so half-written notes wait. Process now ignores it.', stepper(10, 'minutes') + stepper(0, 'seconds'))
    groups = [('Discussion', BLUE, ['Slack', 'Meeting', 'GitHub review', 'Jira comment', 'Email', 'In person']), ('Reference', LIME_INK, ['Web page', 'Document', 'Paper']), ('Personal', PEACH_INK, ['Remember this', 'Idea'])]
    c += h2('Sources', 'Where a note came from. Picking a group in Ask includes everything inside it.')
    for g, col, items in groups:
        c += (f'<div style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap"><span style="width: 90px; font-size: 12px; font-weight: 800; color: {col}">{g}</span>'
              + ''.join(G.dc('SourceChip', f'{len(i) * 7 + 22}px', '26px', label=i) for i in items) + f'<span style="font-size: 12px; font-weight: 600; color: {BLUE}">+ Add</span></div>')
    c += f'<span style="font-size: 13px; font-weight: 600; color: {BLUE}">+ New group</span>'
    c += h2('Labels', 'Read from your vault’s tags. Rename or merge to keep suggestions tidy.')
    c += '<div style="display: flex; gap: 8px; flex-wrap: wrap">' + ''.join(pill(f'#{n} <span style="color: {FAINT}">{k}</span>', LIME_BG, LIME_INK, 28, 12, 600) for n, k in [('tea', 14), ('brewing', 6), ('gyokuro', 3), ('project-x', 22), ('hiring', 9), ('architecture', 17)]) + '</div>'
    c += srow('Suggest labels after a note is queued', 'Uses the Label suggestions model (Models for tasks)', toggle(True))
    c += srow('When Ask is limited to several labels, use notes with', 'The default for new chats. You can switch it per question in Ask.', seg(['Any label', 'All labels'], 'Any label'))
    c += srow('Include notes whose labels aren’t confirmed yet', 'AI-applied labels still in Labels → To review. The default for new chats.', toggle(True))
    c += srow('In Distill: ask me to confirm', 'Notes written here show suggestions after Add to queue. Nothing is applied until you accept.', pill('Always', PANEL, MUTED, 24, 12, 700))
    c += srow('Queue folder: label automatically', 'Files dropped straight into the folder get AI labels, marked To review in Labels.', toggle(True))
    c += srow('CLI: use AI labels if none are sent back', 'If no labels arrive before the batch runs, the AI labels apply, marked To review.', toggle(True))
    c += h2('Ask history', 'Past questions and answers, listed in History. Stored on this Mac only.')
    c += srow('Keep', 'Chats older than 10 days are deleted, counted from the last message. Pinned chats are kept. Turning Keep off deletes each chat when you close it.', toggle(True) + stepper(10, 'days') + btn('Clear now', 'secondary', 30, 12), border=False)
    c += h2('Keyboard shortcuts', 'Off until you record one. They work from any app.')
    c += srow('Ask a question', 'Opens the quick-ask window', pill('Record shortcut', '#FFFFFF', MUTED, 30, 12, 600, 'border: 1.5px dashed #D6D3CC'), border=False)
    c += srow('Add a note', 'Opens the quick-note window', pill('Press keys…', TINT, BLUE, 30, 12, 700, f'box-shadow: 0 0 0 2px {BLUE}'))
    general, c = c, sh1('AI', 'The AI tools Distill may use, and the model for each job.')
    c += h2('AI runners', 'Turn on the AI tools Distill may use.', True)
    for mono, n, note, tint, ink, act, on in [('CC', 'Claude Code', 'Agent · ready · ~/.local/bin/claude', '#FFE4D6', PEACH_INK, 'On', True), ('CX', 'Codex', 'Agent · checking sign-in…', '#ECEAE5', '#48463F', 'Checking…', False),
                                              ('OR', 'OpenRouter', 'Model API · key in Keychain', TINT, BLUE, 'Set up', False), ('AI', 'OpenAI API', 'Model API · needs API key', '#E9FBC9', LIME_INK, 'Set up', False), ('V', 'Vercel AI SDK', 'Model API · via local bridge', '#FFE0EC', '#A3245A', 'Set up', False)]:
        c += (f'<div style="display: flex; align-items: center; gap: 12px; padding: 12px 14px; border-radius: 14px; box-shadow: 0 0 0 {"2px " + BLUE if on else "1px " + LINE}">'
              f'<span style="width: 34px; height: 34px; border-radius: 10px; background: {tint}; color: {ink}; display: flex; align-items: center; justify-content: center; font-size: 11px; font-weight: 800">{mono}</span>'
              f'<span style="display: flex; flex-direction: column; flex-grow: 1"><span style="font-size: 14px; font-weight: 600">{n}</span><span style="font-size: 12px; color: {MUTED}">{note}</span></span>{btn(act, "primary" if on else "soft", 30, 12)}</div>')
    c += h2('Models for tasks', 'Runner, model and effort for each job. Ask can still change them per question.')
    for i, (n, d, m, e) in enumerate([('Adding notes', 'Batches into wiki pages', 'Sonnet', 'Medium'), ('Ask a question', 'Answers from your vault', 'Sonnet', 'Medium'),
                                      ('Label suggestions', 'After a note is queued', 'Haiku', 'Low'), ('Text from images', 'When you click Extract content on an image', 'Haiku', 'Low'),
                                      ('Finding actions', 'After a batch is applied, and on Ask answers', 'Sonnet', 'Medium')]):
        c += srow(n, d, model_ctl(m, e), border=(i > 0))
    c += srow('Action drafts', 'Writing and improving are set per action type in Actions', f'<span style="font-size: 13px; font-weight: 600; color: {BLUE}">Open Actions ›</span>')
    c += (f'<div style="display: flex; align-items: center; gap: 8px; padding: 10px 12px; border-radius: 12px; background: #FFF4EE">{ic("warn", 14, PEACH_INK, 2.2)}'
          f'<span style="font-size: 12px; color: #48463F">Adding notes and Ask need a runner that can read files and respect permissions (Claude Code, Codex). Model APIs like OpenRouter show up only for label suggestions and text from images.</span></div>')
    ai, c = c, sh1('Actions and connections', 'Where actions come from, action types, to-do defaults and sign-ins.')
    c += h2('Actions', 'Distill finds actions in processed notes and Ask answers. Each action type can do some for you; the rest become to-dos.', True)
    c += sources_settings()
    c += srow('Model for finding actions', 'Also listed in Models for tasks', model_ctl('Sonnet', 'Medium'))
    c += ('<div>' + trow('todo', True, 'Catch-all for anything no other type can do', 'Found with the note or answer') + trow('slack', True, 'Write drafts: when a note is processed', 'Sonnet · improve: Sonnet')
          + trow('jira', True, 'Write drafts: when a note is processed · create: on your click', 'Sonnet · improve: Sonnet') + trow('conf', True, 'Write drafts: when a note is processed · create: on your click', 'Sonnet · improve: Sonnet')
          + trow('mail', False, 'Write and copy emails', '—', later=True) + '</div>')
    c += f'<span style="font-size: 12px; color: {MUTED}">Each type opens its own page: when to write, models, and the create and improve prompts with Reset to default (see Settings · sections, search, Actions).</span>'
    c += h2('To-do defaults', 'How To do opens. Changes you make on the To do screen are remembered there.')
    c += (srow('Show', '', seg(['Open', 'Open and completed'], 'Open'), border=False) + srow('Group by', '', select('Due date', 160)) + srow('Sort', 'Inside each group', select('Due date, soonest first', 210))
          + srow('Completed to-dos', 'Struck through for 2 seconds, then moved to History', select('Move to History', 170)) + srow('Keep action history', 'Removed, completed, sent and done items', seg(['30 days', '90 days', '1 year', 'Forever'], '90 days')))
    c += h2('Connections', 'Sign-in happens in your browser. Distill keeps the access in your Keychain and never sees your password.')
    c += (crow('slack', 'off', 'Not needed while Slack messages are copy-only', '', btn('Connect', 'secondary', 30, 12, 'globe', disabled=True))
          + crow('jira', 'ok', 'acme.atlassian.net · as Jin Liu · since Sep 12', f'<div style="display: flex; gap: 8px; padding-left: 46px">{select("Default project: PX · Project X", 250)}{select("Issue type: Task", 150)}</div>', btn('Disconnect', 'danger', 30, 12))
          + crow('conf', 'exp', 'acme.atlassian.net/wiki · expired Sep 30 at 6:00 PM', f'<div style="display: flex; gap: 8px; padding-left: 46px">{select("Default space: Project X", 220)}{select("Parent: Incident reviews", 200)}</div>', btn('Sign in via browser', 'primary', 30, 12, 'globe')))
    wins = ''.join(f'<div style="display: flex; flex-direction: column; gap: 10px"><span style="font-size: 14px; font-weight: 700">{lab}</span>{settings_win(act, body, h=None)}</div>'
                   for lab, act, body in [('A · General', 'Vaults', general), ('B · AI', 'AI runners', ai), ('C · Actions and connections', 'Actions', c)])
    win = f'<div style="display: flex; gap: 40px; align-items: flex-start">{wins}</div>'
    intro = ('The one Settings window, shown three times side by side, scrolled to each group of its section list: General, AI, and Actions and connections. Each shows its sections’ content in full. '
             'Batching holds both Batch every and Wait before picking up a file. Models for tasks has every model choice, including Text from images (Haiku · Low) and Finding actions (Sonnet · Medium). '
             'Search, the no-results state and each action type’s page are on “Settings · sections, search, Actions”.')
    return board('Settings.dc.html', 'Settings', 'Settings · every section', intro, win, 3700)



# ---------------------------------------------------------------- row 1: a finished batch in History → Jobs
def raw_board(fname, title, body, W, H):
    html = f"""<!doctype html>
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
<style>body{{margin:0;font-family:"DM Sans",-apple-system,sans-serif;color:#1D1C1A;-webkit-font-smoothing:antialiased}} a{{color:#1F6FEB}}</style>
</helmet>
{body}
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":{W},"height":{H}}}}}'>
class Component extends DCLogic {{ renderVals() {{ return {{}}; }} }}
</script>
</body>
</html>"""
    write(fname, html)


def do_job_board():
    def job(t, sub, chip, sel=False):
        bg, fg = chip[1], chip[2]
        return (f'<div style="display: flex; flex-direction: column; gap: 4px; padding: 12px; border-radius: 14px; {"background: #F6F5F2" if sel else ""}">'
                f'<span style="font-size: 14px; font-weight: 600; line-height: 1.3">{t}</span>'
                f'<span style="display: flex; align-items: center; gap: 6px">{pill(chip[0], bg, fg, 20, 11, 700)}<span style="font-size: 12px; color: {MUTED}">{sub}</span></span></div>')
    left = (f'<div style="width: 330px; flex-shrink: 0; border-right: 1px solid {LINE}; padding: 26px 16px; box-sizing: border-box; display: flex; flex-direction: column; gap: 12px">'
            f'<div style="display: flex; flex-direction: column; gap: 2px"><span style="font-size: 11px; font-weight: 800; letter-spacing: .06em; color: {FAINT}">HISTORY</span><span style="{HEAD}; font-weight: 800; font-size: 28px">Jobs</span></div>'
            + job('Tea club planning, Auth retry bug', '2 notes · Finished today at 3:44 AM', ('Applied', LIME_BG, LIME_INK), True)
            + job('Gyokuro at 60 °C', '1 note · Finished yesterday at 9:30 PM', ('Applied', LIME_BG, LIME_INK))
            + job('Q3 architecture sync', '3 notes · Rejected Sep 30 at 4:12 PM', ('Rejected', '#FFE4D6', PEACH_INK))
            + job('Hiring loop feedback', '1 note · Finished Sep 30 at 2:05 PM', ('Applied', LIME_BG, LIME_INK)) + '</div>')
    stats = ''.join(f'<div style="flex-grow: 1; display: flex; align-items: center; gap: 10px; padding: 12px 14px; border-radius: 16px; background: {bg}"><span style="{HEAD}; font-weight: 800; font-size: 26px; line-height: 1; color: {ink}">{n}</span><span style="font-size: 13px; font-weight: 600">{l}</span></div>'
                    for n, l, bg, ink in [('1', 'new page', '#E9FBC9', LIME_INK), ('5', 'files updated', TINT, BLUE), ('3', 'claims to verify', '#FFE4D6', PEACH_INK)])
    found = (f'<div style="display: flex; align-items: center; gap: 12px; padding: 14px 16px; border-radius: 16px; background: #F2F7FF; box-shadow: 0 0 0 1px #D6E4FB">{ic("actions", 18, BLUE)}'
             f'<div style="display: flex; flex-direction: column; gap: 2px; flex-grow: 1"><span style="font-size: 15px; font-weight: 700">Found 5 actions to confirm</span>'
             f'<span style="font-size: 12px; color: {MUTED}">3 to-dos, 1 Slack message, 1 Jira ticket · found by Sonnet at 3:44 AM, after the changes were applied</span></div>'
             f'<a href="ActionsTodo.dc.html" style="text-decoration: none">{dc("PrimaryButton", "150px", "40px", title="Review them")}</a></div>')
    rows = ''.join(f'<div style="display: flex; align-items: center; gap: 12px; padding: 6px 4px"><span style="width: 22px; height: 22px; border-radius: 11px; display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: 13px; background: {bg}; color: {ink}">{g}</span><span style="font-size: 14px; flex-grow: 1">{n}</span><span style="font-size: 12px; color: {FAINT}">{d}</span></div>'
                   for g, bg, ink, n, d in [('+', '#E9FBC9', LIME_INK, 'Brewing Green Tea', 'wiki/sources'), ('•', TINT, BLUE, 'Index', 'wiki'), ('•', TINT, BLUE, 'Log', 'wiki'), ('•', TINT, BLUE, 'Hot cache', 'wiki'), ('•', TINT, BLUE, 'Source and claim ledgers', 'wiki/meta')])
    steps = ''.join(f'<span style="display: inline-flex; align-items: center; gap: 5px"><b style="color: {LIME_INK}">✓</b> {t}</span>' for t in ['Moved 2 files to inbox', 'Read sources', 'Applied 5 changes', 'Found 5 actions'])
    right = (f'<div style="flex-grow: 1; min-width: 0; display: flex; flex-direction: column; gap: 16px; padding: 28px 34px; box-sizing: border-box; overflow: hidden">'
             f'<div style="display: flex; align-items: center; gap: 10px">{pill("Applied at 3:44 AM", LIME_BG, LIME_INK, 24, 12, 700)}<span style="font-size: 12px; color: {MUTED}">Started at 3:41 AM · Claude Code · Sonnet · approved by you at 3:44 AM</span></div>'
             f'<h1 style="margin: 0; {HEAD}; font-weight: 800; font-size: 30px; letter-spacing: -0.03em; line-height: 1.1">Tea club planning, Auth retry bug</h1>'
             f'<div style="display: flex; gap: 10px">{stats}</div>{found}'
             f'<div style="display: flex; flex-direction: column; gap: 2px"><span style="font-size: 14px; font-weight: 700; padding-bottom: 4px">Changes</span>{rows}</div>'
             f'<div style="margin-top: auto; display: flex; gap: 18px; font-size: 12px; color: #48463F">{steps}</div></div>')
    body = app(f'<div style="display: flex; height: 100%">{left}{right}</div>', active='History', sub='jobs', w=1200, h=760)
    raw_board('HistoryJob.dc.html', 'History · finished batch', body, 1200, 760)


# ---------------------------------------------------------------- canvas
def place():
    c = json.load(open(os.path.join(BAK, 'canvas.json')))      # rows 1–5 as they were before this audit
    live = json.load(open(os.path.join(PROJ, 'canvas.json')))
    sizes = json.load(open(G.SIZES_FILE))
    b = c['boards']
    b['Loading.dc.html']['h'] = LOADING_H
    r1 = b['ImagesInline.dc.html']
    b['HistoryJob.dc.html'] = dict(x=r1['x'] + r1['w'] + 80, y=r1['y'], w=1200, h=760, title='History → Jobs · a finished batch with its actions')
    c['notes']['flow1']['maxW'] = b['HistoryJob.dc.html']['x'] + 1200 + 60
    b['QuickActions.dc.html']['h'] = QUICK_H
    old_w = b['Settings.dc.html']['w']
    b['Settings.dc.html'].update(w=3700, h=sizes['Settings.dc.html'], title='Settings · every section (General, AI, Actions and connections)')
    dx = 3700 - old_w
    for k in ('AppIcon.dc.html', 'Markdown.dc.html'):          # same row, right of Settings
        b[k]['x'] += dx
    c['notes']['flow5']['maxW'] += dx
    # row 6 keeps its order and spacing, moved below the new bottom of rows 1–5
    row6 = [k for k in live['order'] if k.startswith('Actions') or k == 'SettingsNav.dc.html']
    bottom = max(v['y'] + v['h'] for k, v in b.items() if k not in row6)
    for k in row6:
        b[k] = dict(live['boards'][k], y=bottom + 480, h=sizes[k])
    c['notes']['flow6'] = dict(live['notes']['flow6'], y=bottom + 240)
    c['order'] = [k for k in live['order'] if k not in ROW0_ORDER and k != 'HistoryJob.dc.html']
    c['order'].insert(c['order'].index('ImagesInline.dc.html') + 1, 'HistoryJob.dc.html')
    # row 0 · Components on top; everything else moves down by the same amount
    csz = json.load(open(os.path.join(S, 'components_sizes.json')))
    masters = {'Sidebar.dc.html': (220, 720), 'WindowShell.dc.html': (1200, 760), 'QuickShell.dc.html': (560, 214),
               'MarkdownStyleBar.dc.html': (480, 40), 'PrimaryButton.dc.html': (180, 40), 'SoftButton.dc.html': (160, 40), 'Pill.dc.html': (80, 22)}
    titles = {'Sidebar.dc.html': 'Sidebar (component)', 'SidebarStates.dc.html': 'Sidebar · states',
              'WindowShell.dc.html': 'WindowShell (component)', 'WindowShellStates.dc.html': 'WindowShell · states',
              'QuickShell.dc.html': 'QuickShell (component)', 'QuickShellStates.dc.html': 'QuickShell · states',
              'MarkdownStyleBar.dc.html': 'MarkdownStyleBar (component)', 'MarkdownStyleBarStates.dc.html': 'MarkdownStyleBar · states',
              'PrimaryButton.dc.html': 'PrimaryButton (component)', 'SoftButton.dc.html': 'SoftButton (component)', 'Pill.dc.html': 'Pill (component)', 'ButtonsStates.dc.html': 'PrimaryButton, SoftButton and Pill · states'}
    row0 = {}
    x = 0
    for k in ROW0_ORDER:
        w, h = masters.get(k) or (1920, csz[k])
        row0[k] = dict(x=x, y=240, w=w, h=h, title=titles[k])
        x += w + 80
    delta = 240 + max(v['h'] for v in row0.values()) + 240
    for v in b.values():
        v['y'] += delta
    for n in c['notes'].values():
        n['y'] += delta
    b.update(row0)
    c['notes']['flow0'] = dict(kind='title1', maxW=x - 80 + 60, text='0 · Components (shared by every board)', w=240, x=0, y=0)
    c['order'] = ROW0_ORDER + c['order']
    json.dump(c, open(os.path.join(PROJ, 'canvas.json'), 'w'), indent=2, ensure_ascii=False)
    return bottom, delta


LOADING_H = 1760
ROW0_ORDER = ['Sidebar.dc.html', 'SidebarStates.dc.html', 'WindowShell.dc.html', 'WindowShellStates.dc.html', 'QuickShell.dc.html', 'QuickShellStates.dc.html',
              'MarkdownStyleBar.dc.html', 'MarkdownStyleBarStates.dc.html', 'PrimaryButton.dc.html', 'SoftButton.dc.html', 'Pill.dc.html', 'ButtonsStates.dc.html']
QUICK_H = 2140

def fix_hints():
    """hint-size must be CSS lengths matching the child's root: replace 'auto' widths with estimates."""
    def width(tag):
        g = lambda k: (re.search(k + r'="([^"]*)"', tag) or [None, ''])[1]
        name = g('name')
        if name == 'MarkdownStyleBar':
            w = 470 if g('variant') != 'compact' else 290
            w += 90 if g('image') == 'true' else 0
            return int(w * (0.86 if g('size') == 'small' else 1))
        if name in ('PrimaryButton', 'SoftButton'):
            return 8 * len(g('title')) + (64 if g('system-image') else 44)
        if name == 'Pill':
            return 7 * len(g('text')) + 22
        return 200
    for f in os.listdir(PROJ):
        if not f.endswith('.dc.html'):
            continue
        p = os.path.join(PROJ, f)
        s = open(p).read()
        s2 = re.sub(r'<dc-import [^>]*hint-size="auto,[^"]*"[^>]*>', lambda m: m.group(0).replace('hint-size="auto,', f'hint-size="{width(m.group(0))}px,'), s)
        if s2 != s:
            open(p, 'w').write(s2)


if __name__ == '__main__':
    do_app_boards()
    LOADING_H = do_loading()
    QUICK_H = do_quick()
    do_job_board()
    fix_hints_later = True
    boards = [settings_full()]
    if '--measure' in sys.argv:
        G.measure(boards)
        boards = [settings_full()]
        G.measure(boards)
    fix_hints()
    if '--canvas' in sys.argv:
        print('rows 1–5 bottom', place())
    print('ok')

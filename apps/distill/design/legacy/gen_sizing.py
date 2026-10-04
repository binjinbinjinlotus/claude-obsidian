import json
import re as _re
def dc(name, w='auto', h='auto', **props):
    a = ' '.join(f'{_re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), k)}="{v}"' for k, v in props.items() if v is not None)
    return f'<dc-import name="{name}" {a} hint-size="{w},{h}"></dc-import>'
STAGE_H=430; W=340
LINES=["Shop recommended 60 °C, 2 min first steep.","Second steep 30 s, third 1 min.","Use soft water; our tap is fine.","Mei prefers 50 °C for a sweeter cup.","Buy the 50 g tin next time.","Card attached for the exact grams.","Ask the shop about the spring harvest.","Kyusu holds 180 ml; use 6 g of leaf."]
LH=18
def lines(n,start=0,color='#2A2925'):
    return ''.join(f'<div style="height: {LH}px; font-size: 12px; line-height: {LH}px; color: {color}; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{LINES[(start+i)%len(LINES)]}</div>' for i in range(n))
def x_btn():
    return '<span aria-hidden="true" style="width: 20px; height: 20px; border-radius: 10px; background: #F6F5F2; display: flex; align-items: center; justify-content: center"><svg width="8" height="8" viewBox="0 0 24 24" fill="none" stroke="#6B6862" stroke-width="3" stroke-linecap="round"><path d="M6 6l12 12M18 6L6 18"></path></svg></span>'
def bar(t): return dc('QuickShell', '100%', '22px', part='bar', title=t.capitalize())
def grip(): return '<span aria-hidden="true" style="position: absolute; right: 5px; bottom: 5px; width: 11px; height: 11px; background: linear-gradient(135deg, transparent 0 45%, #C9C6BF 45% 52%, transparent 52% 65%, #C9C6BF 65% 72%, transparent 72%)"></span>'
def title(t='Gyokuro at 60 °C',ph=False):
    c='#C9C6BF' if ph else '#1D1C1A'
    return f'<div style="font-family: \'Bricolage Grotesque\', sans-serif; font-weight: 600; font-size: 15px; line-height: 20px; color: {c}">{t}</div>'
AA='<span style="height: 24px; padding: 0 8px; border-radius: 12px; background: #F6F5F2; font-size: 11px; font-weight: 800; color: #48463F; display: flex; align-items: center">Aa</span>'
def footer(btn='Add to queue',src=None):
    sc='background: #E9FBC9; color: #3D6110' if src else 'background: #F6F5F2'
    return f'<div style="display: flex; align-items: center; gap: 8px; padding-top: 2px">{AA}<span style="height: 24px; padding: 0 9px; border-radius: 12px; {sc}; font-size: 11px; font-weight: 700; display: flex; align-items: center">{(src+" ▾") if src else "+ Source"}</span><span style="flex-grow: 1; font-size: 10px; color: #9B978F">⌘↩ saves</span><span style="height: 28px; padding: 0 12px; border-radius: 14px; background: #1F6FEB; color: #FFFFFF; font-size: 12px; font-weight: 600; display: flex; align-items: center">{btn}</span></div>'
LINK='<div style="margin-top: auto; display: flex; align-items: center; gap: 6px; height: 26px; padding: 0 10px; border-radius: 13px; box-shadow: inset 0 0 0 1px #E2DFD9; font-size: 11px; color: #9B978F"><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#9B978F" stroke-width="2.4" stroke-linecap="round"><path d="M10 14a5 5 0 0 0 7 0l3-3a5 5 0 0 0-7-7l-1 1M14 10a5 5 0 0 0-7 0l-3 3a5 5 0 0 0 7 7l1-1"></path></svg> Link, channel or person</div>'
def body(n,start=0): return f'<div>{lines(n,start)}</div>'
def scroll(content_html,h,thumb_top,thumb_h,top_fade=False):
    tf='<span style="position: absolute; left: 0; right: 0; top: 0; height: 14px; background: linear-gradient(#FFFFFF, rgba(255,255,255,0))"></span>' if top_fade else ''
    return f'<div style="position: relative; height: {h}px; overflow: hidden">{content_html}{tf}<span style="position: absolute; left: 0; right: 0; bottom: 0; height: 18px; background: linear-gradient(rgba(255,255,255,0), #FFFFFF)"></span><span aria-hidden="true" style="position: absolute; right: -6px; top: {thumb_top}px; width: 4px; height: {thumb_h}px; border-radius: 2px; background: rgba(29,28,26,0.3)"></span></div>'
def win(inner,h=None,w=W,ring=False):
    hh=f'height: {h}px;' if h else ''
    rg='border-radius: 16px; box-shadow: 0 0 0 2px #1F6FEB;' if ring else ''
    return (f'<div style="position: relative; isolation: isolate; width: {w}px; {hh} box-sizing: border-box; display: flex; flex-direction: column; gap: 10px; padding: 12px 14px 14px; {rg}">'
            f'<div style="position: absolute; inset: 0; z-index: -1">{dc("QuickShell", "100%", "100%", part="frame", width="100%", height="100%")}</div>{inner}</div>')
FLASK_BOTTOM='<span style="position: absolute; right: 16px; bottom: 16px; width: 32px; height: 32px; border-radius: 16px; background: #FFFFFF; box-shadow: 0 4px 10px rgba(29,28,26,0.18)"></span>'
FLASK_TOP='<span style="position: absolute; right: 16px; top: 16px; width: 32px; height: 32px; border-radius: 16px; background: #FFFFFF; box-shadow: 0 4px 10px rgba(29,28,26,0.18)"></span>'
SCREEN_TOP='<span style="position: absolute; left: 0; right: 0; top: 0; height: 22px; border-bottom: 1.5px dashed #9B978F; font-size: 10px; font-weight: 700; color: #6B6862; padding-left: 10px; line-height: 20px; box-sizing: border-box">TOP OF SCREEN · 8 pt margin</span>'
ANCHOR='<span style="position: absolute; left: 0; right: 0; top: 52px; border-top: 1px dotted #B5B1A9"></span><span style="position: absolute; left: 10px; top: 36px; font-size: 9px; font-weight: 700; color: #9B978F; letter-spacing: .04em">TOP EDGE STAYS HERE</span>'
SCREEN_BOTTOM='<span style="position: absolute; left: 0; right: 0; bottom: 0; height: 22px; border-top: 1.5px dashed #9B978F; font-size: 10px; font-weight: 700; color: #6B6862; padding-left: 10px; line-height: 20px; box-sizing: border-box">BOTTOM OF SCREEN · 8 pt margin</span>'
def stage(w,flask='bottom',screen=False,extra=''):
    pos='position: absolute; left: 50%; top: 60px; transform: translateX(-50%)'
    return f'{ANCHOR}{SCREEN_BOTTOM if screen else ""}{FLASK_BOTTOM}<div style="{pos}">{w}</div>{extra}'
def card(num,name,stg,cap):
    return f'''<section style="display: flex; flex-direction: column; gap: 10px">
<div style="display: flex; align-items: center; gap: 8px"><span style="width: 22px; height: 22px; border-radius: 11px; background: #1F6FEB; color: #FFFFFF; font-size: 11px; font-weight: 700; display: flex; align-items: center; justify-content: center">{num}</span><span style="font-size: 14px; font-weight: 700">{name}</span></div>
<div style="position: relative; height: {STAGE_H}px; border-radius: 18px; background: #E4E1DB; overflow: hidden">{stg}</div>
<span style="font-size: 12px; color: #6B6862; line-height: 1.5">{cap}</span>
</section>'''
MAX_H=STAGE_H-60-30  # top edge fixed at 60, stops 8 pt above the screen bottom line
def note_at_limit(start=0,thumb=(30,60),extra_note=''):
    fixed=20+10+20+10+38  # bar, gap, title, gap, footer ~
    h=MAX_H-14-12-fixed-10
    return win(bar('QUICK NOTE')+title()+scroll(body(20,start),h,thumb[0],thumb[1])+extra_note+footer(),h=MAX_H)
img=lambda n,mode=None: '<div style="width: 72%; height: 46px; margin-top: 6px; border-radius: 8px; background: #E3EEFF; box-shadow: 0 0 0 1px rgba(29,28,26,.06)"></div>'
chip=lambda n,new=False: f'<span style="height: 22px; padding: 0 8px; border-radius: 11px; border: 1.5px dashed {"#FFB894" if new else "#B9F06A"}; background: {"#FFF4EE" if new else "#F3FDE4"}; color: {"#B03A0A" if new else "#3D6110"}; font-size: 11px; font-weight: 600; display: flex; align-items: center">#{n}{"<span style='font-size: 9px; font-weight: 700; opacity: .75; margin-left: 4px'>new</span>" if new else ""}</span>'
def size_card():
    k=0.6
    old=f'<div style="position: absolute; left: 22px; top: 70px; width: {round(420*k)}px; height: {round(160*k)}px; border-radius: 12px; border: 1.5px dashed #9B978F; display: flex; align-items: flex-end; justify-content: flex-end; padding: 6px 8px; box-sizing: border-box; font-size: 10px; font-weight: 700; color: #6B6862">before · 420 × 160</div>'
    new=f'<div style="position: absolute; left: 22px; top: 70px; width: {round(560*k)}px; height: {round(214*k)}px; border-radius: 14px; background: rgba(255,255,255,.55); box-shadow: 0 0 0 2px #1F6FEB; display: flex; align-items: flex-end; justify-content: flex-end; padding: 6px 8px; box-sizing: border-box; font-size: 11px; font-weight: 800; color: #1F6FEB">now · 560 × 214</div>'
    note='<div style="position: absolute; left: 22px; right: 22px; top: 230px; font-size: 12px; line-height: 1.55; color: #48463F">Both quick windows open a third bigger: <b>560 pt wide</b> and at least <b>214 pt tall</b> (was 420 × 160). They still grow with the content. You can drag one down to 360 × 160; a size you drag is kept as the new opening size.</div>'
    return old+new+note
def closed_ghost(inner):
    return f'<div style="position: absolute; left: 22px; top: 22px; opacity: .45; transform: scale(.76); transform-origin: top left">{inner}</div><span style="position: absolute; left: 22px; top: 196px; font-size: 10px; font-weight: 800; color: #B03A0A; letter-spacing: .04em">× CLOSED</span>'
def reopened(inner):
    return f'<span style="position: absolute; left: 22px; top: 214px; font-size: 10px; font-weight: 800; color: #1F6FEB; letter-spacing: .04em">OPENED AGAIN · FRESH</span><div style="position: absolute; left: 50%; top: 234px; transform: translateX(-50%)">{inner}</div>'
note=[
 ('Empty', stage(win(bar('QUICK NOTE')+title('Title',True)+'<div style="font-size: 12px; line-height: 18px; color: #C9C6BF; height: 36px">Write a note…</div>'+footer())), 'Opens compact with two lines of room. No scroll bar anywhere.'),
 ('Typing grows the window', stage(win(bar('QUICK NOTE')+title()+body(6)+footer()), extra='<span style="position: absolute; left: 22px; bottom: 16px; font-size: 11px; font-weight: 700; color: #1F6FEB">↓ grows one line at a time</span>'), 'Each new line grows the window by one line, downward. The top edge (and the field you type in) never moves. The text box never shows its own scroll bar.'),
 ('At the screen height limit', stage(note_at_limit(), screen=True), 'The window stops 8 pt above the bottom of the screen. Only the text scrolls, with a thin overlay bar while scrolling; the close bar and the footer stay put.'),
 ('Long paste', stage(note_at_limit(start=3,thumb=(110,44),extra_note='<span style="font-size: 10px; font-weight: 600; color: #1F6FEB; margin-top: -4px">Scrolled to your cursor</span>'), screen=True), 'Pasting a long text jumps straight to the maximum height and scrolls to the cursor.'),
 ('You dragged it bigger', stage(win(bar('QUICK NOTE')+title()+body(2)+'<div style="flex-grow: 1; border-radius: 8px; background: repeating-linear-gradient(135deg, #F7FAFF 0 6px, #FFFFFF 6px 12px); display: flex; align-items: center; justify-content: center; font-size: 10px; font-weight: 600; color: #1F6FEB">text area fills the extra space</div>'+LINK+footer(src='In person'),w=320,h=330)), 'Your size wins: the text area fills it and the window never shrinks below it. The source (picked in the footer) and its link field stay pinned at the bottom, right above the footer. The dragged size is kept as the opening size; the content is not.'),
 ('You dragged it smaller', stage(win(bar('QUICK NOTE')+title()+scroll(body(6,2),54,6,22,top_fade=True)+footer(),h=190)), 'Smaller than the text: the text scrolls, the close bar and the footer stay. The minimum size is 360 × 160 in the app.'),
 ('Many images', stage(win(bar('QUICK NOTE')+title()+scroll('<div>'+lines(2)+img('card-1.png')+img('card-2.png','Extract text')+img('card-3.png')+img('card-4.png')+'</div>',150,40,60)+footer(),h=MAX_H-40), screen=True), 'Images sit inside the text where they were pasted and scroll with it, so many images never push the footer off screen. Hover one for Extract content.'),
 ('Long title', stage(win(bar('QUICK NOTE')+title('Notes from the Kyoto tea shop visit with Mei and the owner')+body(2)+footer())), 'The title wraps to 2 lines, then scrolls inside its own field.'),
 ('Error', stage(win(bar('QUICK NOTE')+title()+body(2)+'<div style="display: flex; gap: 6px; align-items: flex-start; padding: 7px 9px; border-radius: 10px; background: #FFF4EE; font-size: 11px; line-height: 16px; color: #B03A0A"><b>!</b><span>Couldn’t queue the note: Distill core is not running.</span></div>'+footer('Try again'))), 'The error appears above the footer; the window grows to fit it and shrinks back when it clears.'),
 ('Label step', stage(win(bar('QUICK NOTE')+'<div style="padding: 7px 10px; border-radius: 10px; background: #F3FDE4; font-size: 12px; font-weight: 700">✓ Queued “Gyokuro at 60 °C”</div><div style="display: flex; flex-wrap: wrap; gap: 6px">'+chip('tea')+chip('gyokuro')+chip('brewing')+chip('tea-shops',True)+chip('kyoto',True)+'</div>'+footer('Apply 5 labels'))), 'After Add to queue the window eases to the label step’s height. Chips wrap onto new lines instead of widening the window.'),
 ('On the screen you are using', stage(win(bar('QUICK NOTE')+title()+body(3)+footer())), 'Opens centered on the screen that has the pointer (or the flask when opened from its menu), a little above the middle like Spotlight. Every time: a window you dragged elsewhere opens centered again after you close it.'),
 ('Default size (a third bigger)', size_card(), 'Applies to quick note and quick ask.'),
 ('Close, then open again', closed_ghost(win(bar('QUICK NOTE')+title()+body(3)+footer(src='In person'),w=300))+reopened(win(bar('QUICK NOTE')+title('Title',True)+'<div style="font-size: 12px; line-height: 18px; color: #C9C6BF; height: 36px">Write a note…</div>'+footer())), '× or Esc throws the unsaved note away (title, text, images, source). The next time it opens empty, centered, at the opening size. During the label step × still means Skip: the note stays queued.'),
 ('Deleting text', stage(win(bar('QUICK NOTE')+title()+body(1)+'<div style="height: 18px"></div>'+footer())), 'Shrinks back one line at a time, down to the opening size or the size you dragged it to.'),
]
q=lambda t: f'<div style="padding: 8px 10px; border-radius: 10px; background: #F6F5F2; font-size: 12px; line-height: 18px">{t}</div>'
qf='<div style="display: flex; justify-content: space-between; align-items: center; gap: 8px; padding-top: 8px; border-top: 1px solid #ECEAE5; font-size: 10px; color: #9B978F"><span style="height: 22px; padding: 0 7px; border-radius: 11px; background: #F6F5F2; font-size: 10px; font-weight: 800; color: #48463F; display: flex; align-items: center">Aa</span><span style="flex-grow: 1">Haiku · Low · Esc to close</span><span style="color: #1F6FEB; font-weight: 700">Continue in Distill</span></div>'
achips=lambda extra='': '<div style="margin-top: auto; display: flex; flex-wrap: wrap; gap: 6px"><span style="height: 22px; padding: 0 8px; border-radius: 11px; background: #F6F5F2; font-size: 11px; font-weight: 700; display: flex; align-items: center">Haiku · Low ▾</span>'+(extra or '<span style="height: 22px; padding: 0 8px; border-radius: 11px; background: #F6F5F2; font-size: 11px; font-weight: 700; display: flex; align-items: center">All notes</span>')+'<span style="height: 22px; padding: 0 4px; color: #1F6FEB; font-size: 11px; font-weight: 700; display: flex; align-items: center">+ Limit</span></div>'
ask=[
 ('Long question', stage(win(bar('QUICK ASK')+q('What did Mei and the shop owner say about water for gyokuro versus sencha, how many steeps work best, and the leaf amount for a small kyusu?')+achips()+qf)), 'The question box wraps up to 4 lines, then scrolls inside itself; the window grows with it.'),
 ('Long answer at the limit', stage(win(bar('QUICK ASK')+q('Best water temp for sencha?')+scroll(body(20,1),MAX_H-14-12-20-10-34-10-30-10-32,26,56)+achips()+qf,h=MAX_H), screen=True), 'The window grows as the answer arrives. At the screen limit only the answer scrolls; the question and footer stay put.'),
 ('Many filters', stage(win(bar('QUICK ASK')+q('What did we decide about retries?')+'<div style="margin-top: auto; display: flex; flex-wrap: wrap; gap: 6px">'+''.join(f'<span style="height: 22px; padding: 0 8px; border-radius: 11px; background: #E3EEFF; color: #1F6FEB; font-size: 11px; font-weight: 700; display: flex; align-items: center; white-space: nowrap">{t} ×</span>' for t in ['#project-x','#incidents','#auth','#retries','Slack','Meeting'])+'</div>'+qf)), 'Chips sit at the bottom above the footer and wrap onto more lines; the window never gets wider than you set it.'),
 ('Close, then open again', closed_ghost(win(bar('QUICK ASK')+q('Best water temp for sencha?')+'<div style="font-size: 11px; color: #6B6862; display: flex; gap: 6px; align-items: center"><span style="width: 10px; height: 10px; border-radius: 5px; border: 2px solid #D6E4FB; border-top-color: #1F6FEB"></span>Answering…</div>'+achips()+qf,w=300))+reopened(win(bar('QUICK ASK')+q('<span style="color: #C9C6BF">Ask Research…</span>')+achips()+qf)), '× or Esc always gives a fresh quick ask next time: empty question, Settings defaults. A question that was still answering is not stopped: it finishes and is saved, and History and the sidebar show it answering until then.'),
 ('You dragged it bigger', stage(win(bar('QUICK ASK')+q('Best water temp for sencha?')+'<div style="flex-grow: 1; border-radius: 8px; background: repeating-linear-gradient(135deg, #F7FAFF 0 6px, #FFFFFF 6px 12px); display: flex; align-items: center; justify-content: center; font-size: 10px; font-weight: 600; color: #1F6FEB">the answer appears here</div>'+achips()+qf,h=320)), 'The question stays at the top; the model and filter row and the footer stay at the bottom. Extra space goes to the answer, never between the question and the model row.'),
]
cols=4
def grid(cards): return f'<div style="display: grid; grid-template-columns: repeat({cols}, minmax(0, 1fr)); gap: 28px 22px">'+''.join(card(i+1,n,s,c) for i,(n,s,c) in enumerate(cards))+'</div>'
H=3600
html=f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Distill — Quick window sizing</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,800&amp;family=DM+Sans:wght@400;500;600;700&amp;display=swap">
<style>body{{margin:0;font-family:"DM Sans",-apple-system,sans-serif;color:#1D1C1A;-webkit-font-smoothing:antialiased}}</style>
</helmet>
<div style="width: 1600px; height: {H}px; box-sizing: border-box; background: #F6F5F2; padding: 34px 40px; display: flex; flex-direction: column; gap: 22px">
<div style="display: flex; flex-direction: column; gap: 8px">
<span style="font-family: 'Bricolage Grotesque', sans-serif; font-weight: 800; font-size: 28px; letter-spacing: -0.02em">Quick windows: size, growth and scrolling</span>
<span style="font-size: 13px; color: #6B6862; max-width: 1180px; line-height: 1.55">Both quick windows open in the center of the screen, a little above the middle (like Spotlight), wherever the flask is. The window fits its content and grows downward as you type; its top edge stays put. Text boxes never show their own scroll bar. The controls under the text (source, model and filters) always stay at the bottom, right above the footer. Only at the screen height limit does the middle area scroll, with a thin overlay bar while scrolling and a soft fade at the cut edge. The close bar and the footer are always visible. Closing (× or Esc) always starts fresh: the next window opens empty and centered. A size you drag is remembered and acts as the minimum. Resizing eases (instant with Reduce Motion).</span>
</div>
<span style="font-family: 'Bricolage Grotesque', sans-serif; font-weight: 800; font-size: 18px">Quick note</span>
{grid(note)}
<span style="font-family: 'Bricolage Grotesque', sans-serif; font-weight: 800; font-size: 18px; margin-top: 8px">Quick ask</span>
{grid(ask)}
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":1600,"height":{H}}}}}'>
class Component extends DCLogic {{ renderVals() {{ return {{}}; }} }}
</script>
</body>
</html>'''
open('QuickSizing.dc.html','w').write(html)
c=json.load(open('canvas.json')); old=c['boards']['QuickSizing.dc.html']['h']; c['boards']['QuickSizing.dc.html']['h']=H
y=c['boards']['QuickSizing.dc.html']['y']; d=H-old
for k,b in c['boards'].items():
    if b['y']>y: b['y']+=d
for n in c['notes'].values():
    if n['y']>y: n['y']+=d
json.dump(c,open('canvas.json','w'),indent=2)

import json
src=open('gen_md.py').read(); _ns={}; exec(src[:src.index('def bubble')], _ns); TB=_ns['toolbar']()
LINES=["The gooseneck kettle has presets. 80 °C works for sencha;","I set 60 °C for the gyokuro the shop recommended.","Second steep 30 s, third 1 min. Mei prefers 50 °C.","Buy the 50 g tin next time, not the 100 g one.","Ask the shop about the spring harvest dates.","Kyusu holds 180 ml; use 6 g of leaf for two cups.","Card attached for the exact grams and times.","Water: soft is best; our tap is fine per the owner."]
def lines(n,start=0): return ''.join(f'<div style="font-size: 13px; line-height: 21px; color: #2A2925; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{LINES[(start+i)%len(LINES)]}</div>' for i in range(n))
def chip(t,on=False): return f'<span style="height: 24px; padding: 0 10px; border-radius: 12px; font-size: 11px; font-weight: 600; display: flex; align-items: center; white-space: nowrap; background: {"#E3EEFF" if on else "#FFFFFF"}; color: {"#1F6FEB" if on else "#1D1C1A"}">{t}</span>'
def source():
    return f'''<div style="flex-shrink: 0; display: flex; flex-direction: column; gap: 8px; padding: 10px 12px; border-radius: 14px; background: #F6F5F2">
<div style="display: flex; gap: 10px; align-items: flex-start"><span style="width: 52px; font-size: 11px; font-weight: 700; color: #6B6862; line-height: 24px">Source</span><div style="display: flex; flex-wrap: wrap; gap: 6px; flex-grow: 1">{chip("Discussion ›",True)}{chip("Slack")}{chip("Meeting")}{chip("GitHub review")}{chip("In person")}<span style="height: 24px; flex-grow: 1; min-width: 140px; border-radius: 12px; background: #FFFFFF; box-shadow: 0 0 0 1px #ECEAE5; font-size: 11px; color: #9B978F; display: flex; align-items: center; padding: 0 10px">Link, channel or person</span></div></div>
<div style="display: flex; gap: 10px; align-items: center"><span style="width: 52px; font-size: 11px; font-weight: 700; color: #6B6862">Labels</span><span style="font-size: 11px; color: #6B6862">Suggested after you add it to the queue.</span></div>
</div>'''
def images(n):
    tiles=''.join(f'<div style="width: 120px; flex-shrink: 0; display: flex; flex-direction: column; gap: 5px; padding: 6px; border-radius: 12px; background: #F6F5F2"><span style="height: 44px; border-radius: 8px; background: #E3EEFF"></span><span style="font-size: 10px; font-weight: 700; text-align: center; padding: 3px; border-radius: 7px; background: #FFFFFF">{"Keep image" if i%2==0 else "Extract text"}</span></div>' for i in range(n))
    add='<div style="width: 90px; flex-shrink: 0; height: 82px; border-radius: 12px; border: 1.5px dashed #D6D3CC; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 3px; color: #1F6FEB; font-size: 11px; font-weight: 700"><span style="font-size: 16px">+</span>Add image<span style="font-size: 9px; color: #9B978F; font-weight: 600">or paste ⌘V</span></div>'
    return f'<div style="flex-shrink: 0; display: flex; flex-wrap: wrap; gap: 8px">{tiles}{add}</div>'
def inline_img(w=200,h=64,bg='#E3EEFF'):
    return f'<div style="width: {w}px; height: {h}px; margin: 4px 0; border-radius: 8px; background: {bg}; box-shadow: 0 0 0 1px rgba(29,28,26,.06)"></div>'
def editor(n, fill=True, scroll=False, start=0, minh=None, imgs=0):
    fade='<span style="position: absolute; left: 0; right: 0; bottom: 0; height: 22px; background: linear-gradient(rgba(255,255,255,0), #FFFFFF)"></span><span style="position: absolute; right: -4px; top: 6px; width: 4px; height: 34px; border-radius: 2px; background: rgba(29,28,26,0.3)"></span>' if scroll else ''
    grow='flex-grow: 1; min-height: 0;' if fill else ''
    mh=f'min-height: {minh}px;' if minh else ''
    body=lines(n,start) if not imgs else lines(2,start)+''.join(inline_img(200 if i%2==0 else 150, 64 if i%2==0 else 52, '#E3EEFF' if i%2==0 else '#DDF2FF')+lines(1,start+2+i) for i in range(imgs))+lines(max(0,n-2-imgs),start+2+imgs)
    return f'<div style="position: relative; {grow} {mh} overflow: hidden">{body}{fade}</div>'
def card(inner,scrolls=False):
    extra='<span style="position: absolute; left: 0; right: 0; bottom: 0; height: 26px; border-radius: 0 0 18px 18px; background: linear-gradient(rgba(255,255,255,0), #FFFFFF)"></span><span style="position: absolute; right: 4px; top: 40px; width: 4px; height: 60px; border-radius: 2px; background: rgba(29,28,26,0.3)"></span>' if scrolls else ''
    ov='overflow: hidden; position: relative;' if scrolls else ''
    return f'<div style="flex-grow: 1; min-height: 0; {ov} display: flex; flex-direction: column; gap: 12px; padding: 16px 18px; border-radius: 18px; background: #FFFFFF; box-shadow: 0 0 0 1.5px #ECEAE5">{inner}{extra}</div>'
def screen(h, inner, footer_note='One note · 1 image', w=620, scrolls=False):
    return f'''<div style="width: {w}px; height: {h}px; box-sizing: border-box; display: flex; flex-direction: column; gap: 12px; padding: 18px 22px 16px; border-radius: 14px; background: #FFFFFF; box-shadow: 0 0 0 1px rgba(29,28,26,0.08), 0 14px 32px rgba(29,28,26,0.12)">
<div style="flex-shrink: 0; display: flex; align-items: center"><span style="flex-grow: 1; font-family: 'Bricolage Grotesque', sans-serif; font-weight: 800; font-size: 20px">Add to your vault</span><span style="display: flex; padding: 3px; border-radius: 14px; background: #F6F5F2"><span style="padding: 4px 10px; font-size: 11px; font-weight: 600; color: #6B6862; white-space: nowrap">Drop files</span><span style="padding: 4px 10px; border-radius: 11px; background: #FFFFFF; font-size: 11px; font-weight: 600; white-space: nowrap">Write a note</span></span></div>
{card(inner,scrolls)}
<div style="flex-shrink: 0; display: flex; align-items: center; gap: 8px"><span style="flex-grow: 1; font-size: 11px; color: #6B6862">{footer_note}</span><span style="padding: 7px 12px; border-radius: 14px; background: #F6F5F2; font-size: 11px; font-weight: 600">Discard</span><span style="padding: 7px 12px; border-radius: 14px; background: #1F6FEB; color: #FFFFFF; font-size: 11px; font-weight: 600">Add to queue</span></div>
</div>'''
T='<div style="flex-shrink: 0; font-family: \'Bricolage Grotesque\', sans-serif; font-weight: 600; font-size: 17px">Kettle settings for the new tea set</div>'+'<div style="flex-shrink: 0; transform: scale(0.86); transform-origin: left center; margin: -2px 0">'+TB+'</div>'
states=[
 ('Normal window', screen(470, T+editor(4,imgs=1)+source()), 'The note box takes all the space between the title and the Source panel. No scroll bar strip, ever.'),
 ('Taller window', screen(700, T+editor(4,imgs=1)+source()), 'Extra height goes to the note box, not to an empty gap. Source and buttons stay together at the bottom of the card; images are part of the text.'),
 ('Long note', screen(470, T+editor(12,scroll=True,start=2)+source(), 'One note · 34 lines'), 'When the text is longer than the box, only the box scrolls: a thin overlay bar appears while scrolling and a soft fade marks the cut edge.'),
 ('Many images', screen(560, T+editor(4,imgs=3)+source(), 'One note · 3 images'), 'Images sit inside the text where they were pasted, at their own shape, and scroll with the text. Hover one for Extract content (see “Images stay inside the text”).'),
 ('Short window', screen(400, T+'<div style="flex-shrink: 0">'+lines(2)+inline_img()+lines(1,2)+'</div>'+source(), scrolls=True), 'At the minimum window height the note box keeps 4 lines and the card scrolls as a whole: overlay bar while scrolling, soft fade at the bottom edge. Header and buttons stay put.'),
 ('Narrow window', screen(560, T+editor(4,imgs=1)+source(), w=440), 'In a narrow window the source chips wrap onto more lines and the Drop files | Write a note switch always stays on one line.'),
]
def cell(i,n,s,c,h): return f'''<section style="display: flex; flex-direction: column; gap: 10px"><div style="display: flex; align-items: center; gap: 8px"><span style="width: 22px; height: 22px; border-radius: 11px; background: #1F6FEB; color: #FFFFFF; font-size: 11px; font-weight: 700; display: flex; align-items: center; justify-content: center">{i}</span><span style="font-size: 14px; font-weight: 700">{n}</span></div><div style="height: {h}px; border-radius: 18px; background: #E4E1DB; padding: 10px; box-sizing: border-box; overflow: hidden; display: flex; align-items: flex-start; justify-content: center">{s}</div><span style="font-size: 12px; color: #6B6862; line-height: 1.5">{c}</span></section>'''
H=1600
html=f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Distill — Write a note sizing</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,800&amp;family=DM+Sans:wght@400;500;600;700&amp;display=swap">
<style>body{{margin:0;font-family:"DM Sans",-apple-system,sans-serif;color:#1D1C1A;-webkit-font-smoothing:antialiased}}</style>
</helmet>
<div style="width: 2000px; height: {H}px; box-sizing: border-box; background: #F6F5F2; padding: 34px 40px; display: flex; flex-direction: column; gap: 22px">
<div style="display: flex; flex-direction: column; gap: 8px"><span style="font-family: 'Bricolage Grotesque', sans-serif; font-weight: 800; font-size: 28px; letter-spacing: -0.02em">Write a note: size and scrolling</span><span style="font-size: 13px; color: #6B6862; max-width: 1300px; line-height: 1.55">The note box fills the card: the window's extra height goes to it, never to a blank gap. Text boxes never show a scroll-bar strip; scrolling uses the thin overlay bar only while you scroll. Header and buttons stay visible at every size.</span></div>
<div style="display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 28px 24px">{''.join(cell(i+1,n,s,c,(720 if i<3 else 600)) for i,(n,s,c) in enumerate(states))}</div>
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":2000,"height":{H}}}}}'>
class Component extends DCLogic {{ renderVals() {{ return {{}}; }} }}
</script>
</body>
</html>'''
open('distill-design/project/ComposeSizing.dc.html','w').write(html)
import subprocess
open('preview/ComposeSizing.html','w').write(html.replace('<script src="./support.js"></script>','').replace('<helmet>','').replace('</helmet>',''))

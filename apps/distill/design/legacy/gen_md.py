import json
import re as _re
def dc(name, w='auto', h='auto', **props):
    a = ' '.join(f'{_re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), k)}="{v}"' for k, v in props.items() if v is not None)
    return f'<dc-import name="{name}" {a} hint-size="{w},{h}"></dc-import>'
ICON={'bold':'<b style="font-size: 13px">B</b>','italic':'<i style="font-family: Georgia, serif; font-size: 14px">I</i>','strike':'<s style="font-size: 13px">S</s>',
'h':'<span style="font-size: 12px; font-weight: 800">H<span style="font-size: 9px">▾</span></span>',
'ul':'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M9 6h11M9 12h11M9 18h11"/><circle cx="4" cy="6" r="1.3" fill="currentColor"/><circle cx="4" cy="12" r="1.3" fill="currentColor"/><circle cx="4" cy="18" r="1.3" fill="currentColor"/></svg>',
'ol':'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M10 6h10M10 12h10M10 18h10"/><text x="1" y="8" font-size="7" fill="currentColor" stroke="none" font-weight="700">1</text><text x="1" y="14" font-size="7" fill="currentColor" stroke="none" font-weight="700">2</text><text x="1" y="20" font-size="7" fill="currentColor" stroke="none" font-weight="700">3</text></svg>',
'check':'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="7" height="7" rx="1.5"/><path d="M4.5 7.5l1.5 1.5 3-3M13 7.5h8M3 14h7v7H3zM13 17.5h8"/></svg>',
'quote':'<svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor"><path d="M4 18v-5c0-4 2-7 6-8l1 2c-2 1-3 3-3 5h3v6zm9 0v-5c0-4 2-7 6-8l1 2c-2 1-3 3-3 5h3v6z"/></svg>',
'code':'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M8 8l-4 4 4 4M16 8l4 4-4 4"/></svg>',
'block':'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="4" width="18" height="16" rx="3"/><path d="M9 10l-2 2 2 2M15 10l2 2-2 2"/></svg>',
'link':'<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/></svg>',
'wiki':'<span style="font-size: 11px; font-weight: 800; letter-spacing: -0.5px">[[ ]]</span>'}
TIPS={'bold':'Bold ⌘B','italic':'Italic ⌘I','strike':'Strikethrough ⌘⇧X','h':'Heading','ul':'Bullet list','ol':'Numbered list','check':'Checklist','quote':'Quote','code':'Inline code ⌘E','block':'Code block','link':'Link ⌘K','wiki':'Link to a note [['}
def btn(k,on=False,size=28):
    return f'<button type="button" title="{TIPS[k]}" aria-label="{TIPS[k]}" aria-pressed="{str(on).lower()}" style="width: {size}px; height: {size}px; border: none; border-radius: 8px; display: flex; align-items: center; justify-content: center; padding: 0; background: {"#E3EEFF" if on else "transparent"}; color: {"#1F6FEB" if on else "#48463F"}">{ICON[k]}</button>'
SEP='<span style="width: 1px; height: 16px; background: #E1DED8; margin: 0 3px"></span>'
MAP={'bold':'bold','italic':'italic','strike':'strike','h':'heading','ul':'bullet','ol':'numbered','check':'checklist','quote':'quote','code':'code','block':'codeBlock','link':'link','wiki':'wikilink'}
def toolbar(active=(),full=True):
    return dc('MarkdownStyleBar', 'auto', '34px', variant='full' if full else 'compact', pressed=MAP[active[0]] if active else None)
def bubble():
    return f'<div role="toolbar" aria-label="Style selection" style="display: flex; align-items: center; gap: 1px; padding: 3px; border-radius: 10px; background: #1D1C1A; box-shadow: 0 8px 20px rgba(29,28,26,0.25); width: fit-content">'+''.join(btn(k).replace('color: #48463F','color: #FFFFFF') for k in ['bold','italic','strike','code','link','wiki'])+'</div>'
P=lambda t,extra='': f'<div style="font-size: 13px; line-height: 21px; color: #2A2925; {extra}">{t}</div>'
MK=lambda t: f'<span style="color: #B5B1A9">{t}</span>'
def styled_note():
    return ''.join([
     f'<div style="font-family: \'Bricolage Grotesque\', sans-serif; font-weight: 700; font-size: 17px; line-height: 26px">{MK("## ")}Brewing</div>',
     P(f'Use {MK("**")}<b>60 °C</b>{MK("**")} for gyokuro and {MK("*")}<i>never</i>{MK("*")} boiling water.'),
     P(f'{MK("- ")}First steep 2 min'),P(f'{MK("- ")}Second steep {MK("`")}<code style="font-family: ui-monospace, monospace; font-size: 12px; background: #F6F5F2; padding: 1px 4px; border-radius: 4px">30 s</code>{MK("`")}'),
     P(f'{MK("- [x] ")}<s style="color: #9B978F">Buy the 50 g tin</s>'),
     P(f'{MK("- [ ] ")}Ask about the spring harvest'),
     P(f'{MK("> ")}<span style="color: #6B6862">“Soft water is best.” — the owner</span>','border-left: 3px solid #E1DED8; padding-left: 8px; margin: 2px 0'),
     P(f'See {MK("[[")}<span style="color: #1F6FEB; font-weight: 600">Sencha basics</span>{MK("]]")} and {MK("[")}<span style="color: #1F6FEB; text-decoration: underline">the shop</span>{MK("](https://…)")}'),
    ])
def frame(inner,w=560,label=''):
    return f'<div style="width: {w}px; box-sizing: border-box; display: flex; flex-direction: column; gap: 12px; padding: 16px 18px; border-radius: 18px; background: #FFFFFF; box-shadow: 0 0 0 1.5px #ECEAE5, 0 12px 28px rgba(29,28,26,0.10)">{inner}</div>'
TITLE='<div style="font-family: \'Bricolage Grotesque\', sans-serif; font-weight: 600; font-size: 17px">Kettle settings for the new tea set</div>'
def card(i,name,stage,cap,h=420):
    return f'''<section style="display: flex; flex-direction: column; gap: 10px"><div style="display: flex; align-items: center; gap: 8px"><span style="width: 22px; height: 22px; border-radius: 11px; background: #1F6FEB; color: #FFFFFF; font-size: 11px; font-weight: 700; display: flex; align-items: center; justify-content: center">{i}</span><span style="font-size: 14px; font-weight: 700">{name}</span></div><div style="position: relative; height: {h}px; border-radius: 18px; background: #E4E1DB; overflow: hidden; display: flex; align-items: flex-start; justify-content: center; padding-top: 28px; box-sizing: border-box">{stage}</div><span style="font-size: 12px; color: #6B6862; line-height: 1.5">{cap}</span></section>'''
quick_bar=dc('QuickShell', '100%', '22px', part='bar', title='Quick note')
qfoot=lambda aa=False: f'<div style="display: flex; align-items: center; gap: 8px"><button type="button" title="Show text style bar" aria-pressed="{str(aa).lower()}" style="height: 26px; padding: 0 9px; border: none; border-radius: 13px; font-size: 12px; font-weight: 800; background: {"#E3EEFF" if aa else "#F6F5F2"}; color: {"#1F6FEB" if aa else "#48463F"}">Aa</button><span style="height: 26px; padding: 0 9px; border-radius: 13px; background: #F6F5F2; font-size: 11px; font-weight: 700; display: flex; align-items: center">+ Source</span><span style="flex-grow: 1"></span><span style="height: 30px; padding: 0 14px; border-radius: 15px; background: #1F6FEB; color: #FFFFFF; font-size: 12px; font-weight: 600; display: flex; align-items: center">Add to queue</span></div>'
cards=[
 ('Write a note: style bar always shown', frame(TITLE+toolbar(active=('bold',))+styled_note(),w=600), 'The bar sits above the note box. Buttons light up for the style under the cursor (here: bold). Markdown marks stay visible but faded, like Obsidian Live Preview, and are saved as typed.'),
 ('Heading menu', frame(TITLE+'<div style="position: relative">'+toolbar()+'<div style="position: absolute; left: 92px; top: 36px; z-index: 2; width: 170px; padding: 6px; border-radius: 12px; background: #FFFFFF; box-shadow: 0 10px 26px rgba(29,28,26,0.18)">'+''.join(f'<div style="display: flex; align-items: center; justify-content: space-between; padding: 6px 8px; border-radius: 8px; background: {bg}"><span style="font-family: \'Bricolage Grotesque\', sans-serif; font-weight: 700; font-size: {fs}px">{t}</span><span style="font-size: 10px; color: #9B978F">{k}</span></div>' for t,fs,k,bg in [('Normal text',13,'⌘⌥0','transparent'),('Heading 1',18,'⌘⌥1','transparent'),('Heading 2',15,'⌘⌥2','#E3EEFF'),('Heading 3',13,'⌘⌥3','transparent')])+'</div></div>'+'<div style="height: 150px"></div>',w=600), 'H opens a small menu: Normal, Heading 1–3, with shortcuts. The current level is highlighted.'),
 ('Select text → style bubble', frame(TITLE+toolbar()+P('Use 60 °C for gyokuro and never boiling water.')+'<div style="position: relative; height: 70px"><div style="position: absolute; left: 70px; top: 0">'+bubble()+'</div><div style="position: absolute; left: 70px; top: 44px; font-size: 13px; line-height: 21px"><span style="background: #CFE0FF">steep for two minutes</span> before pouring.</div></div>',w=600), 'Selecting text shows a dark bubble with the common styles right next to it, in every input, even when the bar is hidden.'),
 ('Link ⌘K', frame(TITLE+toolbar(active=('link',))+P('Bought from <span style="background: #CFE0FF">the Kyoto shop</span> last week.')+'<div style="width: 330px; display: flex; flex-direction: column; gap: 8px; padding: 10px; border-radius: 12px; background: #FFFFFF; box-shadow: 0 10px 26px rgba(29,28,26,0.18)"><div style="height: 30px; border-radius: 9px; background: #F6F5F2; display: flex; align-items: center; padding: 0 10px; font-size: 12px; color: #9B978F">Paste a link or type a note name…</div><div style="font-size: 11px; color: #6B6862">Notes in your vault</div><div style="font-size: 12px; font-weight: 600">[[Kyoto tea shops]]</div><div style="font-size: 12px; font-weight: 600">[[Sencha basics]]</div></div>',w=600), '⌘K or the link button asks for a URL or a vault note. Picking a note writes [[Note]]; a URL writes [text](url). Typing [[ opens the same note list.',320),
 ('Quick note: Aa shows the bar', frame(quick_bar+'<div style="font-family: \'Bricolage Grotesque\', sans-serif; font-weight: 600; font-size: 15px">Gyokuro at 60 °C</div>'+toolbar(full=False)+P(f'{MK("- ")}First steep 2 min')+P(f'{MK("- ")}Second steep 30 s')+qfoot(True),w=380), 'Quick windows stay clean: Aa toggles a compact bar (remembered). The selection bubble and all shortcuts work with the bar hidden.',320),
 ('Ask: Markdown in questions', frame('<div style="display: flex; flex-direction: column; gap: 8px; padding: 10px 12px; border-radius: 16px; box-shadow: 0 0 0 1.5px #ECEAE5"><div style="font-size: 13px; line-height: 21px">Compare these two:<br>'+MK('- ')+'<b>'+MK('**')+'gyokuro'+MK('**')+'</b> at 60 °C<br>'+MK('- ')+'sencha at 80 °C</div><div style="display: flex; align-items: center; gap: 8px"><button type="button" style="height: 24px; padding: 0 8px; border: none; border-radius: 12px; font-size: 11px; font-weight: 800; background: #F6F5F2; color: #48463F">Aa</button><span style="flex-grow: 1; font-size: 10px; color: #9B978F">Return sends · ⇧Return new line · Return in a list adds an item</span><span style="width: 30px; height: 30px; border-radius: 15px; background: #1F6FEB"></span></div></div>',w=560), 'Ask fields take Markdown too. Return sends; ⇧Return adds a line; inside a list, Return adds the next item and Return on an empty item sends.',320),
]
shortcuts=[('Bold','⌘B','**text**'),('Italic','⌘I','*text*'),('Strikethrough','⌘⇧X','~~text~~'),('Inline code','⌘E','`code`'),('Link','⌘K','[text](url) or [[Note]]'),('Heading 1–3','⌘⌥1–3','# ## ###'),('Bullet list','⌘⇧8','- item'),('Numbered list','⌘⇧7','1. item'),('Checklist','⌘⇧9','- [ ] item'),('Quote','⌘⇧.','> text'),('Code block','⌘⌥C','```'),('Indent / outdent','Tab / ⇧Tab','nested lists')]
auto=[('# + space','Heading 1 (## for 2, ### for 3)'),('- or * + space','Bullet list'),('1. + space','Numbered list'),('[ ] + space','Checklist item'),('> + space','Quote'),('``` + Return','Code block'),('[[','Note picker'),('Return on an empty list item','Ends the list'),('Paste from a web page or Slack','Converted to Markdown'),('Paste Markdown','Kept as written')]
table=lambda rows,heads: '<table style="border-collapse: collapse; font-size: 12px; width: 100%"><tr>'+''.join(f'<th style="text-align: left; padding: 7px 10px; font-size: 10px; letter-spacing: .05em; color: #9B978F; border-bottom: 1px solid #E1DED8">{h}</th>' for h in heads)+'</tr>'+''.join('<tr>'+''.join(f'<td style="padding: 7px 10px; border-bottom: 1px solid #ECEAE5; {"font-family: ui-monospace, monospace; font-size: 11px;" if j>0 else "font-weight: 600;"}">{c}</td>' for j,c in enumerate(r))+'</tr>' for r in rows)+'</table>'
H=1640
html=f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Distill — Markdown editing</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,700;12..96,800&amp;family=DM+Sans:wght@400;500;600;700&amp;display=swap">
<style>body{{margin:0;font-family:"DM Sans",-apple-system,sans-serif;color:#1D1C1A;-webkit-font-smoothing:antialiased}}</style>
</helmet>
<div style="width: 2000px; height: {H}px; box-sizing: border-box; background: #F6F5F2; padding: 34px 40px; display: flex; flex-direction: column; gap: 22px">
<div style="display: flex; flex-direction: column; gap: 8px"><span style="font-family: 'Bricolage Grotesque', sans-serif; font-weight: 800; font-size: 28px; letter-spacing: -0.02em">Markdown in every text input</span><span style="font-size: 13px; color: #6B6862; max-width: 1400px; line-height: 1.55">Note bodies (Write a note, quick note) and Ask questions accept full Markdown. Text is stored exactly as Markdown and styled while you type; the marks stay visible but faded. A style bar does the typing for you. Titles, source links and label fields stay plain text.</span></div>
<div style="display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 28px 24px">{''.join(card(i+1,*x) for i,x in enumerate(cards))}</div>
<div style="display: grid; grid-template-columns: 1fr 1fr; gap: 24px">
<div style="padding: 18px 20px; border-radius: 18px; background: #FFFFFF"><div style="font-size: 14px; font-weight: 800; margin-bottom: 8px">Keyboard shortcuts</div>{table(shortcuts,['STYLE','KEYS','MARKDOWN'])}</div>
<div style="padding: 18px 20px; border-radius: 18px; background: #FFFFFF"><div style="font-size: 14px; font-weight: 800; margin-bottom: 8px">Type-to-format and paste</div>{table(auto,['YOU TYPE','RESULT'])}</div>
</div>
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":2000,"height":{H}}}}}'>
class Component extends DCLogic {{ renderVals() {{ return {{}}; }} }}
</script>
</body>
</html>'''
open('distill-design/project/Markdown.dc.html','w').write(html)
open('preview/Markdown.html','w').write(html.replace('<script src="./support.js"></script>','').replace('<helmet>','').replace('</helmet>',''))

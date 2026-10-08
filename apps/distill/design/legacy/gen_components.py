#!/usr/bin/env python3
"""Row 0 · Components. Shared app chrome as Design Components, named after their Swift views,
plus one states board per component. Every app-window board imports these instead of copying.
Run: python3 gen_components.py"""
import json, os, re

S = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.join(S, 'distill-design', 'project')

FONTS = ('<link rel="preconnect" href="https://fonts.googleapis.com">\n'
         '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600;12..96,800&amp;family=DM+Sans:wght@400;500;600;700&amp;display=swap">')
BASE_CSS = 'body{margin:0;font-family:"DM Sans",-apple-system,sans-serif;color:#1D1C1A;-webkit-font-smoothing:antialiased}'


def component(fname, title, markup, props, script_body, w, h, css=''):
    html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
{FONTS}
<style>{BASE_CSS}{css}</style>
</helmet>
{markup}
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{json.dumps(dict(props, **{"$preview": {"width": w, "height": h}}), ensure_ascii=False).replace("'", "&#39;")}'>
class Component extends DCLogic {{
renderVals() {{
const p = this.props || {{}};
const on = (v, d) => v === undefined || v === null || v === '' ? d : (v === true || v === 'true');
{script_body}
}}
}}
</script>
</body>
</html>'''
    open(os.path.join(PROJ, fname), 'w').write(html)
    return fname, w, h


# ================================================================ Sidebar (MainView.swift: Sidebar + RecentQuestions + VaultSwitcher)
NAV_PATHS = {
    'queue': 'M22 12h-6l-2 3h-4l-2-3H2M5.5 5h13L22 12v6a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-6z',
    'review': 'M9 11l3 3 8-8M20 12v6a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h9',
    'actions': 'M9 6h11M9 12h11M9 18h11M3.5 6l1.5 1.5L7.5 5M3.5 12l1.5 1.5L7.5 11M3.5 18l1.5 1.5L7.5 17',
    'ask': 'M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z',
    'labels': 'M20.6 13.4l-7.2 7.2a2 2 0 0 1-2.8 0L3 13V3h10l7.6 7.6a2 2 0 0 1 0 2.8zM7.5 7.5h.01',
    'history': 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18zM12 7v5l3 2',
}

SIDEBAR_MARKUP = '''<aside style="width: 220px; height: {{height}}; flex-shrink: 0; background: #F6F5F2; display: flex; flex-direction: column; padding: 16px 14px; gap: 22px; box-sizing: border-box">
<div style="height: 12px"></div>
<div style="display: flex; align-items: center; gap: 9px; padding: 0 6px">
<svg width="26" height="26" viewBox="0 0 32 32" aria-hidden="true"><path d="M12 3h8v8l7 13a3 3 0 0 1-2.6 4.5H7.6A3 3 0 0 1 5 24l7-13z" fill="#FFFFFF" stroke="#6B7785" stroke-width="2" stroke-linejoin="round"></path><path d="M8.6 18.5h14.8l2.5 4.8a2 2 0 0 1-1.8 2.9H7.9a2 2 0 0 1-1.8-2.9z" fill="#B9F06A"></path><circle cx="15" cy="14.5" r="1.3" fill="#1F6FEB"></circle><circle cx="18" cy="11.5" r="0.9" fill="#FF9A6B"></circle></svg>
<span style="font-family: 'Bricolage Grotesque', sans-serif; font-weight: 800; font-size: 20px; letter-spacing: -0.02em">distill</span>
</div>
<nav style="display: flex; flex-direction: column; gap: 2px" aria-label="Sections">
<sc-for list="{{items}}" as="it" hint-placeholder-count="6">
<sc-if value="{{it.isTop}}" hint-placeholder-val="{{ true }}">
<a href="{{it.href}}" style="display: flex; align-items: center; gap: 10px; height: 36px; padding: 0 12px; border-radius: 10px; color: #1D1C1A; text-decoration: none; font-size: 14px; font-weight: {{it.weight}}; background: {{it.bg}}; box-shadow: {{it.shadow}}">
<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="{{it.stroke}}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="{{it.d}}"></path></svg>
<span style="flex-grow: 1">{{it.label}}</span>
<sc-if value="{{it.pill}}" hint-placeholder-val="{{ false }}"><span style="font-size: 11px; font-weight: 700; color: {{it.pillFg}}; background: {{it.pillBg}}; border-radius: 9px; padding: 2px 8px">{{it.count}}</span></sc-if>
<sc-if value="{{it.plain}}" hint-placeholder-val="{{ false }}"><span style="font-size: 12px; color: #6B6862">{{it.count}}</span></sc-if>
</a>
</sc-if>
<sc-if value="{{it.isSub}}" hint-placeholder-val="{{ false }}">
<a href="{{it.href}}" style="display: flex; align-items: center; gap: 8px; height: 28px; margin-left: 30px; padding: 0 10px; border-radius: 8px; color: {{it.fg}}; text-decoration: none; font-size: 12.5px; font-weight: {{it.weight}}; background: {{it.bg}}; box-shadow: {{it.shadow}}">
<span style="flex-grow: 1; white-space: nowrap">{{it.label}}</span>
<span style="font-size: 11px; font-weight: 600; color: {{it.countFg}}">{{it.count}}</span>
</a>
</sc-if>
</sc-for>
</nav>
<sc-if value="{{showRecent}}" hint-placeholder-val="{{ false }}">
<div style="display: flex; flex-direction: column">
<div style="font-size: 11px; font-weight: 700; color: #9B978F; padding: 0 12px 4px; letter-spacing: 0.06em">RECENT QUESTIONS</div>
<sc-for list="{{recent}}" as="q" hint-placeholder-count="3">
<a href="Ask.dc.html" title="{{q.help}}" style="display: flex; align-items: center; gap: 6px; padding: 6px 12px; font-size: 13px; color: {{q.fg}}; text-decoration: none">
<span style="flex-grow: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{{q.text}}</span>
<sc-if value="{{q.running}}" hint-placeholder-val="{{ false }}"><span style="width: 10px; height: 10px; box-sizing: border-box; border-radius: 50%; border: 2px solid #D6E4FB; border-top-color: #1F6FEB; flex-shrink: 0"></span></sc-if>
</a>
</sc-for>
</div>
</sc-if>
<div style="margin-top: auto; display: flex; align-items: center; gap: 10px; padding: 8px; border-radius: 12px; background: #FFFFFF; box-shadow: 0 0 0 1px #ECEAE5">
<span style="width: 30px; height: 30px; border-radius: 9px; background: {{chipBg}}; color: {{chipFg}}; display: flex; align-items: center; justify-content: center; font-family: 'Bricolage Grotesque', sans-serif; font-weight: 800; font-size: 15px">{{initial}}</span>
<span style="display: flex; flex-direction: column; flex-grow: 1; min-width: 0"><span style="font-size: 13px; font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{{vault}}</span>
<sc-if value="{{hasStatus}}" hint-placeholder-val="{{ true }}"><span style="font-size: 11px; color: #6B6862">{{status}}</span></sc-if></span>
<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="#6B6862" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M7 10l5-5 5 5M7 14l5 5 5-5"></path></svg>
</div>
</aside>'''

SIDEBAR_SCRIPT = '''const section = p.section || 'queue';
const sub = p.sub || '';
const cnt = (v, d) => (v === undefined || v === null) ? d : String(v);
const P = ''' + json.dumps(NAV_PATHS) + ''';
const subs = {
  actions: [['todo', 'To do', cnt(p.todoCount, '6'), 'ActionsTodo.dc.html'], ['slack', 'Slack messages', cnt(p.slackCount, '1'), 'ActionsSlack.dc.html'], ['jira', 'Jira tickets', cnt(p.jiraCount, '1'), 'ActionsJira.dc.html'], ['confluence', 'Confluence pages', cnt(p.confluenceCount, '1'), 'ActionsConfluence.dc.html']],
  history: [['jobs', 'Jobs', '', 'History.dc.html'], ['chats', 'Ask chats', '', 'History.dc.html'], ['actions', 'Actions', '', 'ActionsHistory.dc.html']]
};
const sum = (k) => subs[k].reduce((a, s) => a + (parseInt(s[2], 10) || 0), 0);
const top = [
  ['queue', 'Queue', cnt(p.queueCount, '3'), false, 'Main.dc.html'],
  ['review', 'Review', cnt(p.reviewCount, '1'), true, 'Review.dc.html'],
  ['actions', 'Actions', cnt(p.actionsCount, String(sum('actions'))), true, 'ActionsTodo.dc.html'],
  ['ask', 'Ask', '', false, 'Ask.dc.html'],
  ['labels', 'Labels', cnt(p.labelsCount, '12'), false, 'Notes.dc.html'],
  ['history', 'History', '', false, 'History.dc.html']
];
const items = [];
top.forEach(([key, label, count, highlight, href]) => {
  const active = section === key;
  const open = active && subs[key];
  const shown = open ? '' : (count === '0' ? '' : count);
  const parentOnly = active && !(open && sub);
  items.push({ isTop: true, isSub: false, label, href, d: P[key], count: shown,
    pill: !!shown && highlight, plain: !!shown && !highlight, pillBg: key === 'review' ? '#FFE4D6' : '#E3EEFF', pillFg: key === 'review' ? '#B03A0A' : '#1F6FEB',
    weight: active ? 600 : 400, stroke: active ? '#1F6FEB' : '#6B6862',
    bg: parentOnly ? '#FFFFFF' : 'transparent', shadow: parentOnly ? '0 1px 3px rgba(29,28,26,0.08)' : 'none' });
  if (open) subs[key].forEach(([skey, slabel, scount, shref]) => {
    const on = sub === skey;
    items.push({ isTop: false, isSub: true, label: slabel, href: shref, count: scount === '0' ? '' : scount,
      fg: on ? '#1D1C1A' : '#48463F', countFg: on ? '#1F6FEB' : '#9B978F', weight: on ? 600 : 500,
      bg: on ? '#FFFFFF' : 'transparent', shadow: on ? '0 1px 3px rgba(29,28,26,0.08)' : 'none' });
  });
});
const recent = [];
if (p.recentRunning) recent.push({ text: p.recentRunning, running: true, fg: '#48463F', help: 'Still answering — open it' });
if (p.recentFailed) recent.push({ text: p.recentFailed, running: false, fg: '#48463F', help: 'Couldn’t answer — open it' });
['Green tea water temperature', 'What did I add this week?', 'Oolong oxidation range'].forEach((t) => recent.push({ text: t, running: false, fg: t === p.recentOpen ? '#1F6FEB' : '#48463F', help: '' }));
const vault = p.vault || 'Research';
const chips = { R: ['#FFE0EC', '#A3245A'], W: ['#DDF2FF', '#0B5C86'] };
const initial = vault === 'Choose a vault' ? '?' : vault.charAt(0).toUpperCase();
const chip = chips[initial] || ['#F6F5F2', '#6B6862'];
const status = p.status ?? 'Sonnet · ready';
return { items, recent: recent.slice(0, 5), showRecent: section === 'ask', vault, initial, chipBg: chip[0], chipFg: chip[1], status, hasStatus: vault !== 'Choose a vault' && status !== '',
  height: (p.height || 720) + 'px' };'''

SIDEBAR_PROPS = {
    'section': {'editor': 'enum', 'options': ['queue', 'review', 'actions', 'ask', 'labels', 'history'], 'default': 'queue'},
    'sub': {'editor': 'enum', 'options': ['', 'todo', 'slack', 'jira', 'confluence', 'jobs', 'chats', 'actions'], 'default': ''},
    'queueCount': {'editor': 'text', 'default': '3'}, 'reviewCount': {'editor': 'text', 'default': '1'},
    'labelsCount': {'editor': 'text', 'default': '12'}, 'actionsCount': {'editor': 'text', 'default': ''},
    'todoCount': {'editor': 'text', 'default': '6', 'section': 'Actions sub-items'}, 'slackCount': {'editor': 'text', 'default': '1', 'section': 'Actions sub-items'},
    'jiraCount': {'editor': 'text', 'default': '1', 'section': 'Actions sub-items'}, 'confluenceCount': {'editor': 'text', 'default': '1', 'section': 'Actions sub-items'},
    'recentRunning': {'editor': 'text', 'default': '', 'section': 'Recent questions'}, 'recentFailed': {'editor': 'text', 'default': '', 'section': 'Recent questions'},
    'recentOpen': {'editor': 'text', 'default': '', 'section': 'Recent questions'},
    'vault': {'editor': 'text', 'default': 'Research', 'section': 'Vault'},
    'status': {'editor': 'enum', 'options': ['Sonnet · ready', 'Sonnet · working', 'Sonnet · waiting on you', 'Starting…', 'Needs setup', ''], 'default': 'Sonnet · ready', 'section': 'Vault'},
    'height': {'editor': 'int', 'default': 720},
}

# ================================================================ WindowShell (no Swift view: the macOS window itself)
WINDOW_MARKUP = '''<sc-if value="{{isFrame}}" hint-placeholder-val="{{ true }}">
<div style="width: {{w}}; height: {{h}}; box-sizing: border-box; background: #EAE8E3; padding: 20px; border-radius: 20px">
<div style="width: 100%; height: 100%; border-radius: 16px; background: #FFFFFF; box-shadow: 0 0 0 1px rgba(29,28,26,0.08), 0 20px 44px rgba(29,28,26,0.14)"></div>
</div>
</sc-if>
<sc-if value="{{isControls}}" hint-placeholder-val="{{ false }}">
<div style="display: flex; gap: 8px; width: 52px; height: 12px">
<span style="width: 12px; height: 12px; border-radius: 6px; background: {{c1}}"></span>
<span style="width: 12px; height: 12px; border-radius: 6px; background: {{c2}}"></span>
<span style="width: 12px; height: 12px; border-radius: 6px; background: {{c3}}"></span>
</div>
</sc-if>'''
WINDOW_SCRIPT = '''const layer = p.layer || 'frame';
const px = (v, d) => (v === undefined || v === null || v === '') ? d : (/^[0-9.]+$/.test(String(v)) ? v + 'px' : String(v));
const inactive = on(p.inactive, false);
return { isFrame: layer === 'frame', isControls: layer === 'controls', w: px(p.width, '1200px'), h: px(p.height, '760px'),
  c1: inactive ? '#DAD7D0' : '#FF5F57', c2: inactive ? '#DAD7D0' : '#FEBC2E', c3: inactive ? '#DAD7D0' : '#28C840' };'''
WINDOW_PROPS = {'layer': {'editor': 'enum', 'options': ['frame', 'controls'], 'default': 'frame'},
                'width': {'editor': 'int', 'default': 1200}, 'height': {'editor': 'int', 'default': 760},
                'inactive': {'editor': 'boolean', 'default': False}}

# ================================================================ QuickShell (QuickShell.swift)
QUICK_MARKUP = '''<sc-if value="{{isFrame}}" hint-placeholder-val="{{ true }}">
<div style="position: relative; width: {{w}}; height: {{h}}; box-sizing: border-box; border-radius: 16px; background: #FFFFFF; box-shadow: 0 0 0 1px rgba(29,28,26,0.06), 0 14px 32px rgba(29,28,26,0.20)">
<sc-if value="{{cut}}" hint-placeholder-val="{{ false }}"><span style="position: absolute; left: 0; right: 0; bottom: 64px; height: 22px; background: linear-gradient(rgba(255,255,255,0), #FFFFFF)"></span><span style="position: absolute; right: 5px; top: 40%; width: 4px; height: 60px; border-radius: 2px; background: rgba(29,28,26,0.3)"></span></sc-if>
<sc-if value="{{grip}}" hint-placeholder-val="{{ true }}"><span aria-hidden="true" title="Drag to resize" style="position: absolute; right: 6px; bottom: 6px; width: 12px; height: 12px; background: linear-gradient(135deg, transparent 0 45%, #C9C6BF 45% 52%, transparent 52% 65%, #C9C6BF 65% 72%, transparent 72%)"></span></sc-if>
</div>
</sc-if>
<sc-if value="{{isBar}}" hint-placeholder-val="{{ false }}">
<div style="display: flex; align-items: center; gap: 8px; height: 22px">
<span style="flex-grow: 1; font-size: 10.5px; font-weight: 700; letter-spacing: 0.09em; color: #9B978F">{{title}}</span>
<span title="Close (Esc)" style="width: 22px; height: 22px; border-radius: 11px; background: #F6F5F2; display: flex; align-items: center; justify-content: center"><svg width="8" height="8" viewBox="0 0 24 24" fill="none" stroke="#6B6862" stroke-width="3.4" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"></path></svg></span>
</div>
</sc-if>'''
QUICK_SCRIPT = '''const part = p.part || 'frame';
const px = (v, d) => (v === undefined || v === null || v === '') ? d : (/^[0-9.]+$/.test(String(v)) ? v + 'px' : String(v));
return { isFrame: part === 'frame', isBar: part === 'bar', title: (p.title || 'Quick note').toUpperCase(),
  w: px(p.width, '560px'), h: px(p.height, '214px'), grip: on(p.grip, true), cut: on(p.cut, false) };'''
QUICK_PROPS = {'part': {'editor': 'enum', 'options': ['frame', 'bar'], 'default': 'frame'},
               'title': {'editor': 'enum', 'options': ['Quick note', 'Quick ask'], 'default': 'Quick note'},
               'width': {'editor': 'text', 'default': '560'}, 'height': {'editor': 'text', 'default': '214'},
               'grip': {'editor': 'boolean', 'default': True}, 'cut': {'editor': 'boolean', 'default': False}}

# ================================================================ MarkdownStyleBar (MarkdownEditorBar.swift)
BAR_ITEMS = {
    'bold': ('text', 'B', '', 'font-weight: 800'), 'italic': ('text', 'I', '', 'font-family: Georgia, serif; font-style: italic'),
    'strike': ('text', 'S', '', 'text-decoration: line-through; font-weight: 700'), 'heading': ('text', 'H▾', '', 'font-weight: 800'),
    'bullet': ('path', '', 'M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01', ''),
    'numbered': ('text', '1.', '', 'font-weight: 800'),
    'checklist': ('path', '', 'M3 4h7v7H3zM4.5 7.5l1.5 1.5 3-3M13 7.5h8M3 14h7v7H3zM13 17.5h8', ''),
    'quote': ('path', '', 'M10 7H6v5h4v-1c0 2-1 4-3 5M19 7h-4v5h4v-1c0 2-1 4-3 5', ''),
    'code': ('path', '', 'M8 8l-4 4 4 4M16 8l4 4-4 4', ''),
    'codeBlock': ('path', '', 'M4 5h16v14H4zM10 10l-2 2 2 2M14 10l2 2-2 2', ''),
    'link': ('path', '', 'M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1', ''),
    'wikilink': ('text', '[[ ]]', '', 'font-weight: 800; font-size: 10px; letter-spacing: -0.5px'),
}
HELP = {'bold': 'Bold ⌘B', 'italic': 'Italic ⌘I', 'strike': 'Strikethrough ⌘⇧X', 'heading': 'Heading', 'bullet': 'Bullet list ⌘⇧8', 'numbered': 'Numbered list ⌘⇧7',
        'checklist': 'Checklist ⌘⇧9', 'quote': 'Quote ⌘⇧.', 'code': 'Inline code ⌘E', 'codeBlock': 'Code block ⌘⌥C', 'link': 'Link ⌘K', 'wikilink': 'Link to a note [['}
GROUPS = {'full': [['bold', 'italic', 'strike'], ['heading'], ['bullet', 'numbered', 'checklist'], ['quote'], ['code', 'codeBlock'], ['link', 'wikilink']],
          'compact': [['bold', 'italic'], ['heading'], ['bullet', 'checklist'], ['code'], ['link', 'wikilink']]}
BAR_MARKUP = '''<div role="toolbar" aria-label="Text style" style="display: flex; align-items: center; gap: 1px; padding: {{pad}}; border-radius: {{radius}}; background: #F6F5F2; width: fit-content">
<sc-for list="{{cells}}" as="c" hint-placeholder-count="10">
<sc-if value="{{c.divider}}" hint-placeholder-val="{{ false }}"><span style="width: 1px; height: 16px; background: #E1DED8; margin: 0 3px"></span></sc-if>
<sc-if value="{{c.isText}}" hint-placeholder-val="{{ true }}"><span title="{{c.help}}" style="width: {{size}}; height: {{size}}; border-radius: 8px; display: flex; align-items: center; justify-content: center; background: {{c.bg}}; color: {{c.fg}}; font-size: 12.5px; {{c.css}}">{{c.label}}</span></sc-if>
<sc-if value="{{c.isPath}}" hint-placeholder-val="{{ false }}"><span title="{{c.help}}" style="width: {{size}}; height: {{size}}; border-radius: 8px; display: flex; align-items: center; justify-content: center; background: {{c.bg}}"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="{{c.fg}}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="{{c.d}}"></path></svg></span></sc-if>
</sc-for>
<sc-if value="{{image}}" hint-placeholder-val="{{ false }}"><span style="width: 1px; height: 16px; background: #E1DED8; margin: 0 3px"></span><span title="Insert image (or paste ⌘V, or drop)" style="height: {{size}}; display: flex; align-items: center; gap: 5px; padding: 0 9px; border-radius: 8px; background: #FFFFFF; box-shadow: 0 0 0 1px #ECEAE5; font-size: 12px; font-weight: 700; color: #48463F"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#48463F" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 4h18v16H3zM21 16l-5-5-9 9M9 8h.01"></path></svg>Image</span></sc-if>
</div>'''
BAR_SCRIPT = '''const ITEMS = ''' + json.dumps(BAR_ITEMS, ensure_ascii=False) + ''';
const HELP = ''' + json.dumps(HELP, ensure_ascii=False) + ''';
const GROUPS = ''' + json.dumps(GROUPS) + ''';
const variant = p.variant === 'compact' ? 'compact' : 'full';
const pressed = p.pressed || '';
const small = p.size === 'small';
const cells = [];
GROUPS[variant].forEach((g, gi) => g.forEach((k, ki) => {
  const [kind, label, d, css] = ITEMS[k];
  const onNow = pressed === k;
  cells.push({ divider: gi > 0 && ki === 0, isText: kind === 'text', isPath: kind === 'path', label, d, css, help: HELP[k],
    bg: onNow ? '#E3EEFF' : 'transparent', fg: onNow ? '#1F6FEB' : '#48463F' });
}));
return { cells, image: on(p.image, false), size: small ? '24px' : '28px', pad: small ? '2px' : '3px', radius: small ? '9px' : '11px' };'''
BAR_PROPS = {'variant': {'editor': 'enum', 'options': ['full', 'compact'], 'default': 'full'},
             'pressed': {'editor': 'enum', 'options': [''] + list(BAR_ITEMS), 'default': ''},
             'image': {'editor': 'boolean', 'default': False},
             'size': {'editor': 'enum', 'options': ['regular', 'small'], 'default': 'regular'}}

# ================================================================ PrimaryButton / SoftButton (Theme.swift)
import symbols, gen_actions as _G
ICONS = dict({'': ''}, **symbols.symbols(_G.P))
PRIMARY_MARKUP = '''<span style="height: {{h}}; display: inline-flex; align-items: center; gap: {{gap}}; padding: 0 {{pad}}; border-radius: {{r}}; opacity: {{op}}; background: #1F6FEB; color: #FFFFFF; font-size: {{fs}}; font-weight: 600; white-space: nowrap; box-shadow: {{shadow}}; box-sizing: border-box">
<sc-if value="{{hasIcon}}" hint-placeholder-val="{{ false }}"><svg width="{{ic}}" height="{{ic}}" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="{{d}}"></path></svg></sc-if>{{title}}</span>'''
PRIMARY_SCRIPT = '''const ICONS = ''' + json.dumps(ICONS) + ''';
const d = ICONS[p.systemImage || ''] || '';
const SIZES = { regular: [40, 20, 14, 12, 7], small: [30, 14, 13, 11, 6], mini: [26, 11, 12, 10, 5] };
const z = SIZES[p.size] || SIZES.regular;
const enabled = on(p.enabled, true);
return { title: p.title !== undefined ? p.title : 'Add to queue', d, hasIcon: !!d, h: z[0] + 'px', pad: z[1] + 'px', r: z[0] / 2 + 'px', fs: z[2] + 'px', ic: z[3], gap: z[4] + 'px',
  op: enabled ? 1 : 0.45, shadow: enabled && z[0] >= 40 ? '0 4px 8px rgba(31,111,235,0.28)' : 'none' };'''
PRIMARY_PROPS = {'title': {'editor': 'text', 'default': 'Add to queue'},
                 'systemImage': {'editor': 'enum', 'options': list(ICONS), 'default': ''},
                 'size': {'editor': 'enum', 'options': ['regular', 'small', 'mini'], 'default': 'regular'},
                 'enabled': {'editor': 'boolean', 'default': True}}
SOFT_MARKUP = '''<span style="height: {{h}}; display: inline-flex; align-items: center; gap: {{gap}}; padding: 0 {{pad}}; border-radius: {{r}}; opacity: {{op}}; background: {{fill}}; color: {{tint}}; box-shadow: {{ring}}; font-size: {{fs}}; font-weight: 600; white-space: nowrap; box-sizing: border-box"><sc-if value="{{hasIcon}}" hint-placeholder-val="{{ false }}"><svg width="{{ic}}" height="{{ic}}" viewBox="0 0 24 24" fill="none" stroke="{{tint}}" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="{{d}}"></path></svg></sc-if>{{title}}</span>'''
PILL_MARKUP = '''<span style="height: {{h}}; display: inline-flex; align-items: center; gap: 5px; padding: 0 {{pad}}; border-radius: {{r}}; background: {{fill}}; color: {{ink}}; box-shadow: {{ring}}; border: {{border}}; font-size: {{fs}}; font-weight: 700; white-space: nowrap; box-sizing: border-box">
<sc-if value="{{busy}}" hint-placeholder-val="{{ false }}"><span style="width: 10px; height: 10px; box-sizing: border-box; border-radius: 50%; border: 2px solid #D6E4FB; border-top-color: #1F6FEB; flex-shrink: 0"></span></sc-if><sc-if value="{{hasIcon}}" hint-placeholder-val="{{ false }}"><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="{{ink}}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="flex-shrink: 0"><path d="{{d}}"></path></svg></sc-if>{{text}}</span>'''
PILL_SCRIPT = '''const ICONS = ''' + json.dumps(ICONS) + ''';
const d = ICONS[p.systemImage || ''] || '';
const small = p.size === 'small';
const dashed = on(p.dashed, false);
return { text: p.text || '1', fill: p.fill || '#FFE4D6', ink: p.ink || '#B03A0A', d, hasIcon: !!d, busy: on(p.busy, false),
  h: small ? '20px' : '24px', pad: small ? '8px' : '10px', r: small ? '10px' : '12px', fs: small ? '10.5px' : '12px',
  ring: p.stroke && !dashed ? 'inset 0 0 0 1.5px ' + p.stroke : 'none', border: dashed ? '1.5px dashed ' + (p.stroke || '#D6D3CC') : 'none' };'''
PILL_PROPS = {'text': {'editor': 'text', 'default': '1'},
              'fill': {'editor': 'color', 'default': '#FFE4D6', 'options': ['#FFE4D6', '#E3EEFF', '#F3FDE4', '#F6F5F2', '#FFFFFF']},
              'ink': {'editor': 'color', 'default': '#B03A0A', 'options': ['#B03A0A', '#1F6FEB', '#3D6110', '#6B6862', '#9B978F']},
              'size': {'editor': 'enum', 'options': ['regular', 'small'], 'default': 'regular'},
              'systemImage': {'editor': 'enum', 'options': list(ICONS), 'default': ''},
              'busy': {'editor': 'boolean', 'default': False},
              'stroke': {'editor': 'color', 'default': '', 'options': ['', '#ECEAE5', '#B9F06A']},
              'dashed': {'editor': 'boolean', 'default': False}}
SOFT_SCRIPT = '''const SIZES = { regular: [40, 20, 14, 12, 7], small: [30, 14, 13, 11, 6], mini: [26, 11, 12, 10, 5] };
const z = SIZES[p.size] || SIZES.regular;
const ICONS = ''' + json.dumps(ICONS) + ''';
const d = ICONS[p.systemImage || ''] || '';
const enabled = on(p.enabled, true);
return { d, hasIcon: !!d, op: enabled ? 1 : 0.45, ic: z[3], gap: z[4] + 'px', title: p.title !== undefined ? p.title : 'Skip labels', tint: p.tint || '#1D1C1A', fill: p.fill || '#F6F5F2', ring: p.stroke ? 'inset 0 0 0 1px ' + p.stroke : 'none',
  h: z[0] + 'px', pad: (z[1] - 2) + 'px', r: z[0] / 2 + 'px', fs: z[2] + 'px' };'''
SOFT_PROPS = {'title': {'editor': 'text', 'default': 'Skip labels'},
              'tint': {'editor': 'color', 'default': '#1D1C1A', 'options': ['#1D1C1A', '#B03A0A', '#1F6FEB']},
              'fill': {'editor': 'color', 'default': '#F6F5F2', 'options': ['#F6F5F2', '#FFFFFF', '#FFF4EE', 'transparent']},
              'stroke': {'editor': 'color', 'default': '', 'options': ['', '#ECEAE5']},
              'systemImage': {'editor': 'enum', 'options': list(ICONS), 'default': ''},
              'size': {'editor': 'enum', 'options': ['regular', 'small', 'mini'], 'default': 'regular'},
              'enabled': {'editor': 'boolean', 'default': True}}

# ================================================================ SettingsSectionNav (Settings window, section list + search)
SNAV_MARKUP = """<aside style="width: 236px; height: {{height}}; flex-shrink: 0; background: #F6F5F2; padding: 16px 14px; box-sizing: border-box; display: flex; flex-direction: column; gap: 2px">
<div style="height: 26px"></div>
<span style="width: 196px; height: 30px; display: inline-flex; align-items: center; gap: 7px; padding: 0 10px; border-radius: 15px; background: {{searchBg}}; box-shadow: {{searchRing}}; font-size: 12px; box-sizing: border-box; flex-shrink: 0">
<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="#9B978F" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0M20 20l-4-4"></path></svg>
<span style="flex-grow: 1; white-space: nowrap; overflow: hidden; color: {{queryFg}}">{{queryText}}<sc-if value="{{hasQuery}}" hint-placeholder-val="{{ false }}"><span style="display: inline-block; width: 1.5px; height: 14px; background: #1F6FEB; vertical-align: -2px; margin-left: 1px"></span></sc-if></span>
<sc-if value="{{hasQuery}}" hint-placeholder-val="{{ false }}"><span style="width: 16px; height: 16px; border-radius: 8px; background: #DAD7D0; display: inline-flex; align-items: center; justify-content: center"><svg width="8" height="8" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="3.4" stroke-linecap="round" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18"></path></svg></span></sc-if>
</span>
<nav style="display: flex; flex-direction: column; gap: 2px" aria-label="Settings sections">
<sc-for list="{{rows}}" as="r" hint-placeholder-count="14">
<sc-if value="{{r.isGroup}}" hint-placeholder-val="{{ false }}"><div style="padding: 14px 10px 4px; font-size: 10px; font-weight: 800; letter-spacing: .06em; color: #9B978F">{{r.label}}</div></sc-if>
<sc-if value="{{r.isItem}}" hint-placeholder-val="{{ true }}"><div style="display: flex; align-items: center; gap: 9px; padding: 7px 10px; border-radius: 9px; font-size: 13px; background: {{r.bg}}; box-shadow: {{r.shadow}}; font-weight: {{r.weight}}; opacity: {{r.op}}">
<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="{{r.stroke}}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="flex-shrink: 0"><path d="{{r.d}}"></path></svg>
<span style="flex-grow: 1">{{r.label}}</span>
<sc-if value="{{r.hasCount}}" hint-placeholder-val="{{ false }}"><span style="font-size: 11px; font-weight: 700; color: #1F6FEB; background: #E3EEFF; border-radius: 9px; padding: 1px 7px">{{r.count}}</span></sc-if>
</div></sc-if>
</sc-for>
</nav>
</aside>"""
SNAV_SCRIPT = """const ICONS = """ + json.dumps(ICONS) + """;
const GROUPS = """ + json.dumps([[g, [[n, symbols.SF[i]] for n, i in items]] for g, items in _G.SNAV]) + """;
const selected = p.selected || '';
const query = p.query || '';
const matches = {};
String(p.matches || '').split(',').forEach(m => { const i = m.lastIndexOf(':'); if (i > 0) matches[m.slice(0, i).trim()] = m.slice(i + 1).trim(); });
const rows = [];
GROUPS.forEach(([g, items]) => {
  rows.push({ isGroup: true, isItem: false, label: g });
  items.forEach(([label, sym]) => {
    const on = label === selected;
    const count = matches[label] || '';
    rows.push({ isGroup: false, isItem: true, label, d: ICONS[sym] || '', stroke: on ? '#1F6FEB' : '#6B6862',
      bg: on ? '#FFFFFF' : 'transparent', shadow: on ? '0 1px 3px rgba(29,28,26,.08)' : 'none', weight: on ? 600 : 400,
      op: query && !count ? 0.4 : 1, count, hasCount: !!count });
  });
});
const h = p.height;
return { rows, hasQuery: !!query, queryText: query || 'Search settings', queryFg: query ? '#1D1C1A' : '#9B978F',
  searchBg: query ? '#FFFFFF' : '#F6F5F2', searchRing: query ? '0 0 0 2px #1F6FEB' : 'none',
  height: h === undefined || h === null || h === '' ? 'auto' : (/^[0-9.]+$/.test(String(h)) ? h + 'px' : String(h)) };"""
SNAV_PROPS = {'selected': {'editor': 'enum', 'options': [''] + [n for _, items in _G.SNAV for n, _ in items], 'default': 'Vaults'},
              'query': {'editor': 'text', 'default': ''},
              'matches': {'editor': 'text', 'default': ''},
              'height': {'editor': 'text', 'default': ''}}


# ================================================================ states boards
def imp(name, attrs, w, h):
    a = ' '.join(f'{re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), k)}="{v}"' for k, v in attrs.items())
    return f'<dc-import name="{name}" {a} hint-size="{w},{h}"></dc-import>'


def state(label, inner, cap=''):
    c = f'<span style="font-size: 11px; color: #6B6862; line-height: 1.45; max-width: 260px">{cap}</span>' if cap else ''
    return (f'<div style="display: flex; flex-direction: column; gap: 8px; align-items: flex-start"><span style="font-size: 12px; font-weight: 700">{label}</span>{inner}{c}</div>')


def states_board(fname, title, heading, intro, cells, W, H, cols=None, gap='28px 24px'):
    grid = (f'<div style="display: grid; grid-template-columns: repeat({cols}, minmax(0, 1fr)); gap: {gap}">' if cols else f'<div style="display: flex; flex-wrap: wrap; gap: {gap}">') + ''.join(cells) + '</div>'
    html = f'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>{title}</title>
<script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
{FONTS}
<style>{BASE_CSS}</style>
</helmet>
<div style="width: {W}px; height: {H}px; box-sizing: border-box; background: #F6F5F2; overflow: hidden">
<div data-measure style="padding: 30px 36px 36px; display: flex; flex-direction: column; gap: 20px">
<div style="display: flex; flex-direction: column; gap: 6px"><span style="font-family: 'Bricolage Grotesque', sans-serif; font-weight: 800; font-size: 24px; letter-spacing: -0.02em">{heading}</span>
<span style="font-size: 13px; color: #6B6862; line-height: 1.5; max-width: 1100px">{intro}</span></div>
{grid}
</div>
</div>
</x-dc>
<script type="text/x-dc" data-dc-script data-props='{{"$preview":{{"width":{W},"height":{H}}}}}'>
class Component extends DCLogic {{ renderVals() {{ return {{}}; }} }}
</script>
</body>
</html>'''
    open(os.path.join(PROJ, fname), 'w').write(html)
    return fname, W, H


SIZES_FILE = os.path.join(S, 'components_sizes.json')
SIZES = json.load(open(SIZES_FILE)) if os.path.exists(SIZES_FILE) else {}


def H(f, d):
    return SIZES.get(f, d)


def build():
    out = []
    out.append(component('Sidebar.dc.html', 'Sidebar', SIDEBAR_MARKUP, SIDEBAR_PROPS, SIDEBAR_SCRIPT, 220, 720))
    out.append(component('WindowShell.dc.html', 'Window shell', WINDOW_MARKUP, WINDOW_PROPS, WINDOW_SCRIPT, 1200, 760))
    out.append(component('QuickShell.dc.html', 'Quick shell', QUICK_MARKUP, QUICK_PROPS, QUICK_SCRIPT, 560, 214))
    out.append(component('MarkdownStyleBar.dc.html', 'Markdown style bar', BAR_MARKUP, BAR_PROPS, BAR_SCRIPT, 480, 40))
    out.append(component('PrimaryButton.dc.html', 'Primary button', PRIMARY_MARKUP, PRIMARY_PROPS, PRIMARY_SCRIPT, 180, 40))
    out.append(component('SoftButton.dc.html', 'Soft button', SOFT_MARKUP, SOFT_PROPS, SOFT_SCRIPT, 160, 40))
    out.append(component('Pill.dc.html', 'Pill', PILL_MARKUP, PILL_PROPS, PILL_SCRIPT, 80, 24))
    out.append(component('SettingsSectionNav.dc.html', 'Settings section nav', SNAV_MARKUP, SNAV_PROPS, SNAV_SCRIPT, 236, 520))

    sb = lambda a, h=720: imp('Sidebar', dict(a, height=h), '220px', f'{h}px')
    side = lambda inner: f'<div style="width: 220px; border-radius: 14px; overflow: hidden; box-shadow: 0 0 0 1px #ECEAE5">{inner}</div>'
    cells = [
        state('Queue (default)', side(sb({'section': 'queue'})), 'Counts show only above 0. Review and Actions use a pill (they need you); others are plain.'),
        state('Review', side(sb({'section': 'review', 'status': 'Sonnet · waiting on you'})), 'Vault card: “waiting on you” while a batch waits for Review.'),
        state('Actions, open on To do', side(sb({'section': 'actions', 'sub': 'todo'})), 'Sub-items show only while their page is open. The open parent drops its total; each sub-item carries its own count.'),
        state('Actions › Slack messages', side(sb({'section': 'actions', 'sub': 'slack'})), 'The selected sub-item is highlighted; the parent keeps its blue icon.'),
        state('Ask with recent questions', side(sb({'section': 'ask', 'recentRunning': 'Oolong vs pu-erh caffeine', 'recentFailed': 'Summarize the hiring loop', 'recentOpen': 'Green tea water temperature'})),
              'As in Swift’s RecentQuestions: a running question has a spinner, a failed one shows its title (tooltip “Couldn’t answer — open it”), the open chat is blue. At most 5.'),
        state('Labels', side(sb({'section': 'labels'})), 'Labels has 2 tabs (To review, Unlabeled), so they stay as tabs on the page.'),
        state('History › Jobs', side(sb({'section': 'history', 'sub': 'jobs', 'status': 'Sonnet · working'})), 'History’s parts become sub-items. Vault card: “working” while a batch runs.'),
        state('History › Ask chats', side(sb({'section': 'history', 'sub': 'chats'})), ''),
        state('History › Actions', side(sb({'section': 'history', 'sub': 'actions'})), ''),
        state('Collapsed Actions total', side(sb({'section': 'queue', 'todoCount': '5', 'jiraCount': '2'})), 'Collapsed, the parent shows the sum of its sub-items: 5 + 1 + 2 + 1 = 9.'),
        state('Starting', side(sb({'section': 'queue', 'status': 'Starting…'})), ''),
        state('No vault yet', side(sb({'section': 'queue', 'vault': 'Choose a vault', 'queueCount': '0', 'reviewCount': '0', 'labelsCount': '0', 'todoCount': '0', 'slackCount': '0', 'jiraCount': '0', 'confluenceCount': '0'})), 'Swift: “Choose a vault”, no status line.'),
    ]
    out.append(states_board('SidebarStates.dc.html', 'Sidebar states', 'Sidebar', 'MainView.swift → <b>Sidebar</b> (with RecentQuestions and VaultSwitcher). One file, imported by every app window. '
                            'Props: section, sub, queueCount, reviewCount, actionsCount, labelsCount, todoCount, slackCount, jiraCount, confluenceCount, recentRunning, recentFailed, recentOpen, vault, status, height. '
                            'Swift’s Section has no Actions yet and no sub-items: both are design ahead of the app.', cells, 1920, H('SidebarStates.dc.html', 1700), cols=6))

    wsh = lambda a, w, h: f'<div style="position: relative; width: {w}px; height: {h}px">' \
        f'<div style="position: absolute; left: 0; top: 0">{imp("WindowShell", dict(a, layer="frame", width=w, height=h), f"{w}px", f"{h}px")}</div>' \
        f'<div style="position: absolute; left: 38px; top: 36px">{imp("WindowShell", dict(a, layer="controls"), "52px", "12px")}</div></div>'
    cells = [state('Frame + controls', f'<div style="transform: scale(.5); transform-origin: top left; width: 600px; height: 380px">{wsh({}, 1200, 760)}</div>', 'layer="frame" sits behind the window’s content; layer="controls" (the traffic lights) sits on top, 18 × 16 pt in from the window corner, over the sidebar’s empty strip.'),
             state('Inactive window', f'<div style="transform: scale(.5); transform-origin: top left; width: 600px; height: 380px">{wsh({"inactive": "true"}, 1200, 760)}</div>', 'inactive: grey lights.'),
             state('Settings window size', f'<div style="transform: scale(.5); transform-origin: top left; width: 590px; height: 380px">{wsh({}, 1180, 760)}</div>', 'width and height set the frame; content is laid on top by each board.')]
    out.append(states_board('WindowShellStates.dc.html', 'Window shell states', 'WindowShell', 'The macOS window: backdrop, rounded surface and shadow (frame), and the traffic lights (controls). No Swift view: AppKit draws it. '
                            'Props: layer (frame | controls), width, height, inactive. Design Components have no child slots, so a board stacks: frame → content → controls.', cells, 1920, H('WindowShellStates.dc.html', 560), cols=3))

    def qs(title, w, h, cut=False, grip=True, body=''):
        return (f'<div style="position: relative; width: {w}px; height: {h}px">'
                f'<div style="position: absolute; inset: 0">{imp("QuickShell", {"part": "frame", "width": w, "height": h, "cut": str(cut).lower(), "grip": str(grip).lower()}, f"{w}px", f"{h}px")}</div>'
                f'<div style="position: relative; padding: 12px 16px 16px; display: flex; flex-direction: column; gap: 12px">{imp("QuickShell", {"part": "bar", "title": title}, "100%", "22px")}{body}</div></div>')
    cells = [state('Quick note, default 560 × 214', qs('Quick note', 560, 214), 'part="frame" behind, part="bar" (title + ×) at the top. The footer is the board’s own content: no slots.'),
             state('Quick ask', qs('Quick ask', 560, 214), ''),
             state('Minimum 360 × 160', qs('Quick note', 360, 160), 'Swift QuickWindowGeometry.minSize.'),
             state('Cut at the screen limit', qs('Quick note', 560, 360, cut=True), 'cut: fade and overlay scroller over the middle (Swift snapshotOverflow).'),
             state('No grip (snapshot)', qs('Quick ask', 560, 214, grip=False), '')]
    out.append(states_board('QuickShellStates.dc.html', 'Quick shell states', 'QuickShell', 'QuickShell.swift → <b>QuickShell</b>: close bar (QUICK NOTE / QUICK ASK and ×), card, resize grip. '
                            'Props: part (frame | bar), title, width, height, grip, cut. Default width is 560 here; Swift’s QuickWindowGeometry.defaultWidth is still 420.', cells, 1920, H('QuickShellStates.dc.html', 900), cols=3))

    bar = lambda a: imp('MarkdownStyleBar', a, 'auto', '34px')
    cells = [state('Full', bar({'variant': 'full'}), 'Write a note.'), state('Full + Image', bar({'variant': 'full', 'image': 'true'}), 'Editors that take images inline.'),
             state('Full, heading menu open', bar({'variant': 'full', 'pressed': 'heading'}), 'pressed forces an item on.'),
             state('Compact', bar({'variant': 'compact'}), 'Replies, drafts, quick windows.'), state('Compact, bold on', bar({'variant': 'compact', 'pressed': 'bold'}), ''),
             state('Compact, small', bar({'variant': 'compact', 'size': 'small'}), 'size="small" for cards (Slack, Jira, Confluence drafts).')]
    out.append(states_board('MarkdownStyleBarStates.dc.html', 'Markdown style bar states', 'MarkdownStyleBar', 'MarkdownEditorBar.swift → <b>MarkdownStyleBar</b>. Groups follow MarkdownBarItem.groups. '
                            'Props: variant (full | compact), pressed (an item), image (the Image button), size (regular | small).', cells, 1920, H('MarkdownStyleBarStates.dc.html', 360), cols=3))

    pb = lambda a: imp('PrimaryButton', a, 'auto', '40px')
    sbn = lambda a: imp('SoftButton', a, 'auto', '40px')
    cells = [state('PrimaryButton', pb({'title': 'Add to queue'}), 'title'), state('With systemImage', pb({'title': 'Apply 3 labels', 'system-image': 'checkmark'}), 'systemImage: checkmark'),
             state('Process now', pb({'title': 'Process now', 'system-image': 'play'}), ''), state('Busy title', pb({'title': 'Applying…', 'system-image': 'checkmark'}), 'Swift shows progress by changing the title.'),
             state('Small', imp('PrimaryButton', {'title': 'Review them', 'size': 'small'}, '110px', '30px'), 'size="small" · 30 pt (cards, sheets)'),
             state('Mini', imp('PrimaryButton', {'title': 'Add all', 'size': 'mini'}, '70px', '26px'), 'size="mini" · 26 pt (quick windows, found blocks)'),
             state('Disabled', pb({'title': 'Add to queue', 'enabled': 'false'}), 'enabled="false" (nothing to add yet)'),
             state('SoftButton', sbn({'title': 'Skip labels'}), 'title'), state('Tinted', sbn({'title': 'Reject', 'tint': '#B03A0A', 'fill': '#FFF4EE'}), 'tint, fill'),
             state('Outlined', sbn({'title': 'Choose files', 'fill': '#FFFFFF', 'stroke': '#E4E1DA'}), 'stroke on white surfaces'),
             state('Small', imp('SoftButton', {'title': 'Cancel', 'size': 'small'}, '70px', '30px'), 'size="small"'),
             state('Mini, link', imp('SoftButton', {'title': '+ Label', 'tint': '#1F6FEB', 'fill': 'transparent', 'size': 'mini'}, '64px', '26px'), 'fill="transparent"'),
             state('Destructive', imp('SoftButton', {'title': 'Delete forever', 'tint': '#FFFFFF', 'fill': '#B03A0A', 'size': 'small'}, '110px', '30px'), 'the only confirm'),
             state('With systemImage', imp('SoftButton', {'title': 'Send to', 'system-image': 'paperplane', 'fill': '#FFFFFF', 'stroke': '#ECEAE5', 'size': 'small'}, '90px', '30px'), 'systemImage takes the tint'),
             state('Disabled', imp('SoftButton', {'title': 'Create draft', 'system-image': 'plus', 'fill': '#FFFFFF', 'stroke': '#ECEAE5', 'size': 'small', 'enabled': 'false'}, '110px', '30px'), 'enabled="false"'),
             state('Pill', imp('Pill', {'text': '1'}, '30px', '24px'), 'Review count (peach)'), state('Pill, ready', imp('Pill', {'text': 'Ready to paste', 'fill': '#F3FDE4', 'ink': '#3D6110'}, '110px', '24px'), 'State pills on drafts'),
             state('Pill, blue', imp('Pill', {'text': '9', 'fill': '#E3EEFF', 'ink': '#1F6FEB'}, '30px', '24px'), 'Actions count'), state('Pill, muted', imp('Pill', {'text': 'Not written', 'fill': '#F6F5F2', 'ink': '#6B6862'}, '96px', '24px'), ''),
             state('Pill, busy', imp('Pill', {'text': 'Writing', 'fill': '#E3EEFF', 'ink': '#1F6FEB', 'busy': 'true'}, '90px', '24px'), 'busy: spinner while AI works'),
             state('Pill, systemImage', imp('Pill', {'text': 'Connected', 'fill': '#F3FDE4', 'ink': '#3D6110', 'system-image': 'checkmark'}, '100px', '24px'), 'systemImage before the text'),
             state('Pill, small', imp('Pill', {'text': 'Edited', 'fill': '#FFE4D6', 'ink': '#B03A0A', 'size': 'small'}, '60px', '20px'), 'size="small" · 20 pt in dense rows'),
             state('Pill, stroke', imp('Pill', {'text': 'Coming later', 'fill': '#FFFFFF', 'ink': '#9B978F', 'stroke': '#ECEAE5'}, '100px', '24px'), 'stroke: types not built yet'),
             state('Pill, dashed', imp('Pill', {'text': 'Send in Slack · later', 'fill': '#FFFFFF', 'ink': '#9B978F', 'dashed': 'true'}, '150px', '24px'), 'dashed: a future handler slot')]
    out.append(states_board('ButtonsStates.dc.html', 'Button and pill states', 'PrimaryButton, SoftButton and Pill', 'Theme.swift → <b>PrimaryButton</b> (title, systemImage, size, enabled) and <b>SoftButton</b> (title, tint, fill, stroke, systemImage, size, enabled); size is regular 40 · small 30 · mini 26 pt. '
                            '<b>Pill</b> (text, fill, ink, size regular 24 | small 20, systemImage, busy, stroke, dashed) for counts and states. Every button and status pill on the boards imports one of these.', cells, 1920, H('ButtonsStates.dc.html', 300), cols=6))
    nv = lambda a, h=560: f'<div style="border-radius: 14px; overflow: hidden; box-shadow: 0 0 0 1px #ECEAE5; width: 236px">' + imp('SettingsSectionNav', dict(a, height=h), '236px', f'{h}px') + '</div>'
    cells = [state('Selected', nv({'selected': 'Vaults'}), 'selected: the section on the right'),
             state('An Actions page', nv({'selected': 'Actions'}), 'Action types and Where actions come from stay under Actions'),
             state('Searching', nv({'selected': '', 'query': 'prompt', 'matches': 'Actions:6,Models for tasks:1'}), 'query + matches: sections with results show a count; the rest dim'),
             state('No matches', nv({'selected': '', 'query': 'webhook', 'matches': ''}), 'Every section dims; the page says “No settings match”'),
             state('Connections', nv({'selected': 'Connections'}), '')]
    out.append(states_board('SettingsSectionNavStates.dc.html', 'Settings section nav states', 'SettingsSectionNav',
                            'Settings window → <b>SettingsSectionNav</b>: the search field and the section list on the left of the Settings window. Props: selected (a section), query (the search text), matches (section:count, comma-separated), height.',
                            cells, 1920, H('SettingsSectionNavStates.dc.html', 700), cols=5))
    return out


def measure(boards):
    import subprocess, re
    for f, w, h in boards:
        if not f.endswith('States.dc.html'):
            continue
        r = subprocess.run([os.path.join(S, 'snapbin'), os.path.join(PROJ, f), str(w), os.path.join(S, 'shots', f.replace('.dc.html', '.png')), '0.5'], capture_output=True, text=True, timeout=120)
        m = re.search(r'MEASURE (\d+)', r.stdout)
        if m:
            SIZES[f] = int(m.group(1))
    json.dump(SIZES, open(SIZES_FILE, 'w'), indent=2)


if __name__ == '__main__':
    import sys
    boards = build()
    if '--measure' in sys.argv:
        measure(boards)
        boards = build()
        measure(boards)
    print('\n'.join(f'{f} {w}x{h}' for f, w, h in boards))

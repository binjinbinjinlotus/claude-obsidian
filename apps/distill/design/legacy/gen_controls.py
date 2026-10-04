#!/usr/bin/env python3
"""Row 0 · Components, second batch: the small controls, one Design Component per Swift struct
(props = the struct's inputs) plus a states board each. Run after gen_components.py.
Run: python3 gen_controls.py [--measure]"""
import json, os, sys
import gen_components as C
from gen_components import component, states_board, imp, state, ICONS

BORDER, INK, MUTED, FAINT, PANEL, BLUE, TINT = '#ECEAE5', '#1D1C1A', '#6B6862', '#9B978F', '#F6F5F2', '#1F6FEB', '#E3EEFF'
LIME, LIME_TINT, LIME_INK, PEACH, PEACH_INK = '#B9F06A', '#E9FBC9', '#3D6110', '#FFB894', '#B03A0A'
PX = "const px = (v, d) => (v === undefined || v === null || v === '') ? d : (/^[0-9.]+$/.test(String(v)) ? v + 'px' : String(v));\n"
NUM = "const num = (v, d) => (v === undefined || v === null || v === '' || isNaN(Number(v))) ? d : Number(v);\n"

# ---------------------------------------------------------------- Segmented (AskParts.swift) / SegmentedPills (ComposeComponents.swift)
SEG_MARKUP = '''<span style="display: inline-flex; align-items: center; gap: 2px; padding: 2px; border-radius: {{r}}; background: {{track}}; box-shadow: inset 0 0 0 1px #ECEAE5; white-space: nowrap; box-sizing: border-box">
<sc-for list="{{segs}}" as="s" hint-placeholder-count="2"><span style="height: {{s.h}}; display: inline-flex; align-items: center; padding: 0 10px; border-radius: {{s.r}}; background: {{s.bg}}; color: {{s.fg}}; font-size: 12px; font-weight: 700">{{s.label}}</span></sc-for>
</span>'''
SEG_SCRIPT = NUM + '''const opts = String(p.options || 'Any label|All labels').split('|').map(o => o.trim()).filter(Boolean);
const sel = p.selection === undefined || p.selection === '' ? opts[0] : String(p.selection);
const h = num(p.height, 24);
return { r: (h / 2 + 2) + 'px', track: p.track || '#FFFFFF',
  segs: opts.map(o => ({ label: o, h: h + 'px', r: h / 2 + 'px', bg: o === sel ? '#1F6FEB' : 'transparent', fg: o === sel ? '#FFFFFF' : '#6B6862' })) };'''
SEG_PROPS = {'options': {'editor': 'text', 'default': 'Any label|All labels'}, 'selection': {'editor': 'text', 'default': 'Any label'},
             'height': {'editor': 'int', 'default': 24}}
SEGP_PROPS = dict(SEG_PROPS, track={'editor': 'color', 'default': '#FFFFFF', 'options': ['#FFFFFF', PANEL]})

# ---------------------------------------------------------------- PillSwitch (ComposeComponents.swift)
PSW_MARKUP = '''<span role="switch" aria-checked="{{on}}" aria-label="{{label}}" style="width: {{w}}; height: {{h}}; border-radius: {{r}}; background: {{bg}}; display: inline-flex; align-items: center; justify-content: {{justify}}; padding: 3px; box-sizing: border-box; flex-shrink: 0"><span style="width: {{k}}; height: {{k}}; border-radius: 50%; background: #FFFFFF; box-shadow: 0 1px 1px rgba(0,0,0,.12)"></span></span>'''
PSW_SCRIPT = NUM + '''const isOn = on(p.isOn, true);
const w = num(p.width, 40), h = num(p.height, 24);
return { on: isOn ? 'true' : 'false', label: p.label || 'Setting', w: w + 'px', h: h + 'px', r: h / 2 + 'px', k: (h - 6) + 'px',
  bg: isOn ? '#1F6FEB' : '#D6D3CC', justify: isOn ? 'flex-end' : 'flex-start' };'''
PSW_PROPS = {'isOn': {'editor': 'boolean', 'default': True}, 'label': {'editor': 'text', 'default': 'Setting'},
             'width': {'editor': 'int', 'default': 40}, 'height': {'editor': 'int', 'default': 24}}

# ---------------------------------------------------------------- CapsuleSwitch (AskParts.swift)
CSW_MARKUP = '''<span role="switch" aria-checked="{{on}}" style="display: inline-flex; align-items: center; gap: 6px; white-space: nowrap; font-size: {{fs}}; font-weight: 600; color: #48463F">
<span style="width: 34px; height: 20px; border-radius: 10px; background: {{bg}}; display: inline-flex; align-items: center; justify-content: {{justify}}; padding: 0 2px; box-sizing: border-box; flex-shrink: 0"><span style="width: 16px; height: 16px; border-radius: 50%; background: #FFFFFF"></span></span>{{title}}</span>'''
CSW_SCRIPT = '''const isOn = on(p.isOn, true);
return { on: isOn ? 'true' : 'false', title: p.title || 'Include unconfirmed', fs: (p.fontSize || 12) + 'px', bg: isOn ? '#1F6FEB' : '#D6D3CC', justify: isOn ? 'flex-end' : 'flex-start' };'''
CSW_PROPS = {'title': {'editor': 'text', 'default': 'Include unconfirmed'}, 'isOn': {'editor': 'boolean', 'default': True},
             'fontSize': {'editor': 'enum', 'options': [12, 11], 'default': 12}}

# ---------------------------------------------------------------- LabelChip (ComposeComponents.swift)
LCHIP_MARKUP = '''<span style="height: {{h}}; display: inline-flex; align-items: center; gap: 4px; padding: 0 {{padR}} 0 10px; border-radius: {{r}}; background: {{fill}}; color: {{ink}}; border: {{border}}; font-size: 12px; font-weight: 600; white-space: nowrap; box-sizing: border-box">{{text}}<sc-if value="{{newTag}}" hint-placeholder-val="{{ false }}"><span style="font-size: 10px; font-weight: 700; opacity: .7">new</span></sc-if><sc-if value="{{removable}}" hint-placeholder-val="{{ false }}"><span style="width: 16px; height: 16px; display: inline-flex; align-items: center; justify-content: center; font-size: 13px; font-weight: 400">×</span></sc-if></span>'''
LCHIP_SCRIPT = NUM + '''const style = p.style || 'plain';
const S = { suggestedExisting: ['#3D6110', '#F3FDE4', '1.5px dashed #B9F06A'], suggestedNew: ['#B03A0A', '#FFF4EE', '1.5px dashed #FFB894'],
            plain: ['#1F6FEB', '#E3EEFF', 'none'], muted: ['#9B978F', '#F6F5F2', '1.5px dashed #ECEAE5'] }[style] || ['#1F6FEB', '#E3EEFF', 'none'];
const h = num(p.height, 26), removable = on(p.removable, false);
return { text: (on(p.sparkle, false) ? '✦ ' : '') + '#' + (p.labelName || 'tea'), ink: S[0], fill: S[1], border: S[2], h: h + 'px', r: h / 2 + 'px',
  newTag: style === 'suggestedNew' && on(p.showNewTag, true), removable, padR: removable ? '4px' : '10px' };'''
LCHIP_PROPS = {'labelName': {'editor': 'text', 'default': 'tea'},
               'style': {'editor': 'enum', 'options': ['plain', 'suggestedExisting', 'suggestedNew', 'muted'], 'default': 'plain'},
               'sparkle': {'editor': 'boolean', 'default': False}, 'height': {'editor': 'int', 'default': 26},
               'showNewTag': {'editor': 'boolean', 'default': True}, 'removable': {'editor': 'boolean', 'default': False}}

# ---------------------------------------------------------------- FilterChip (AskParts.swift)
FCHIP_MARKUP = '''<span style="height: {{h}}; display: inline-flex; align-items: center; gap: 4px; padding: 0 {{padR}} 0 11px; border-radius: {{r}}; background: {{fill}}; color: {{ink}}; font-size: 12px; font-weight: 700; white-space: nowrap; box-sizing: border-box">{{text}}<sc-if value="{{removable}}" hint-placeholder-val="{{ false }}"><span style="width: 18px; height: 18px; display: inline-flex; align-items: center; justify-content: center; font-size: 13px; font-weight: 400">×</span></sc-if></span>'''
FCHIP_SCRIPT = NUM + '''const h = num(p.height, 28), removable = on(p.removable, true);
return { text: p.text || '#tea', fill: p.fill || '#E3EEFF', ink: p.ink || '#1F6FEB', h: h + 'px', r: h / 2 + 'px', removable, padR: removable ? '5px' : '11px' };'''
FCHIP_PROPS = {'text': {'editor': 'text', 'default': '#tea'}, 'fill': {'editor': 'color', 'default': TINT, 'options': [TINT, LIME_TINT, PANEL]},
               'ink': {'editor': 'color', 'default': BLUE, 'options': [BLUE, LIME_INK, INK]}, 'height': {'editor': 'int', 'default': 28},
               'removable': {'editor': 'boolean', 'default': True}}

# ---------------------------------------------------------------- SourceChip (SettingsSections.swift)
SCHIP_MARKUP = '''<span style="height: 26px; display: inline-flex; align-items: center; gap: 4px; padding: 0 10px; border-radius: 13px; background: #FFFFFF; box-shadow: inset 0 0 0 1px #ECEAE5; color: #1D1C1A; font-size: 12px; font-weight: 600; white-space: nowrap; box-sizing: border-box">{{label}}<sc-if value="{{hovering}}" hint-placeholder-val="{{ false }}"><span style="font-size: 13px; font-weight: 400; color: #9B978F">×</span></sc-if></span>'''
SCHIP_SCRIPT = '''return { label: p.label || 'Slack', hovering: on(p.hovering, false) };'''
SCHIP_PROPS = {'label': {'editor': 'text', 'default': 'Slack'}, 'hovering': {'editor': 'boolean', 'default': False}}

# ---------------------------------------------------------------- ModelChip (AskParts.swift)
DROP = 'M12 3c3.5 4.2 6 7.6 6 10.5a6 6 0 0 1-12 0C6 10.6 8.5 7.2 12 3z'
MCHIP_MARKUP = '''<span style="height: {{h}}; display: inline-flex; align-items: center; gap: 6px; padding: 0 10px 0 {{padL}}; border-radius: {{r}}; background: {{bg}}; box-shadow: {{ring}}; white-space: nowrap; box-sizing: border-box">
<sc-if value="{{drop}}" hint-placeholder-val="{{ true }}"><span style="width: 20px; height: 20px; border-radius: 50%; background: #E9FBC9; display: inline-flex; align-items: center; justify-content: center"><svg width="10" height="10" viewBox="0 0 24 24" fill="#3D6110" aria-hidden="true"><path d="''' + DROP + '''"></path></svg></span></sc-if>
<span style="font-size: 12px; font-weight: 700; color: #1D1C1A">{{text}}</span>
<svg width="8" height="8" viewBox="0 0 24 24" fill="none" stroke="#6B6862" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M6 9l6 6 6-6"></path></svg></span>'''
MCHIP_SCRIPT = '''const compact = on(p.compact, false);
let text = on(p.showRunner, true) ? (p.runner || 'Claude Code') + ' · ' + (p.model || 'Sonnet') : (p.model || 'Sonnet');
if (on(p.showEffort, false)) text += ' · ' + (p.effort || 'Medium');
return { text, drop: !compact, padL: compact ? '10px' : '6px', h: compact ? '26px' : '30px', r: compact ? '13px' : '15px',
  bg: compact ? '#F6F5F2' : '#FFFFFF', ring: compact ? 'none' : 'inset 0 0 0 1px #ECEAE5' };'''
MCHIP_PROPS = {'runner': {'editor': 'text', 'default': 'Claude Code'}, 'model': {'editor': 'text', 'default': 'Sonnet'},
               'effort': {'editor': 'enum', 'options': ['Low', 'Medium', 'High'], 'default': 'Medium'},
               'showRunner': {'editor': 'boolean', 'default': True}, 'showEffort': {'editor': 'boolean', 'default': False},
               'compact': {'editor': 'boolean', 'default': False}}

# ---------------------------------------------------------------- DropdownButton (ComposeComponents.swift)
DD_MARKUP = '''<span style="width: {{w}}; height: {{h}}; display: inline-flex; align-items: center; gap: 6px; padding: 0 10px; border-radius: {{r}}; background: {{bg}}; box-shadow: inset 0 0 0 1px {{ring}}; opacity: {{op}}; box-sizing: border-box; white-space: nowrap">
<sc-if value="{{hasIcon}}" hint-placeholder-val="{{ false }}"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="{{iconInk}}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="flex-shrink: 0"><path d="{{d}}"></path></svg></sc-if>
<span style="flex-grow: 1; font-size: {{fs}}; font-weight: {{fw}}; color: {{ink}}; overflow: hidden; text-overflow: ellipsis">{{title}}</span><span style="font-size: 11px; color: {{caret}}">▾</span></span>'''
DD_SCRIPT = PX + NUM + '''const ICONS = ''' + json.dumps(ICONS) + ''';
const d = ICONS[p.systemImage || ''] || '', active = on(p.active, false);
return { title: p.title || 'Claude Code', w: px(p.width, 'auto'), h: num(p.height, 32) + 'px', r: num(p.radius, 10) + 'px',
  fs: num(p.fontSize, 12) + 'px', op: on(p.enabled, true) ? 1 : 0.45, d, hasIcon: !!d,
  bg: active ? '#E3EEFF' : '#FFFFFF', ring: active ? '#BFD5FA' : '#ECEAE5', ink: active ? '#1F6FEB' : '#1D1C1A', fw: active ? 700 : 600,
  iconInk: active ? '#1F6FEB' : '#6B6862', caret: active ? '#1F6FEB' : '#9B978F' };'''
DD_PROPS = {'title': {'editor': 'text', 'default': 'Claude Code'}, 'width': {'editor': 'text', 'default': ''},
            'height': {'editor': 'int', 'default': 32}, 'radius': {'editor': 'int', 'default': 10},
            'fontSize': {'editor': 'enum', 'options': [12, 11, 13], 'default': 12}, 'enabled': {'editor': 'boolean', 'default': True},
            'systemImage': {'editor': 'enum', 'options': list(ICONS), 'default': ''}, 'active': {'editor': 'boolean', 'default': False}}

# ---------------------------------------------------------------- QuickSourceButton (QuickNote.swift)
QSB_MARKUP = '''<span style="max-width: 130px; height: 24px; display: inline-flex; align-items: center; gap: 4px; padding: 0 9px; border-radius: 12px; background: {{bg}}; color: {{fg}}; font-size: 11px; font-weight: 700; white-space: nowrap; box-sizing: border-box"><span style="overflow: hidden; text-overflow: ellipsis">{{text}}</span><sc-if value="{{chosen}}" hint-placeholder-val="{{ false }}"><span style="font-size: 10px">▾</span></sc-if></span>'''
QSB_SCRIPT = '''const chosen = !!p.source;
return { chosen, text: chosen ? p.source : '+ Source', bg: chosen ? '#E9FBC9' : '#F6F5F2', fg: chosen ? '#3D6110' : '#48463F' };'''
QSB_PROPS = {'source': {'editor': 'text', 'default': ''}}

# ---------------------------------------------------------------- MarkdownBarToggle (MarkdownEditorBar.swift) — the Aa button
AA_MARKUP = '''<span role="switch" aria-checked="{{on}}" aria-label="Text style bar" style="height: {{h}}; display: inline-flex; align-items: center; padding: 0 {{pad}}; border-radius: {{r}}; background: {{bg}}; color: {{fg}}; font-size: {{fs}}; font-weight: 800; box-sizing: border-box; flex-shrink: 0">Aa</span>'''
AA_SCRIPT = NUM + '''const isOn = on(p.isOn, false), h = num(p.height, 24);
return { on: isOn ? 'true' : 'false', h: h + 'px', r: h / 2 + 'px', pad: (h >= 26 ? 9 : 8) + 'px', fs: (h >= 26 ? 12 : 11) + 'px',
  bg: isOn ? '#E3EEFF' : '#F6F5F2', fg: isOn ? '#1F6FEB' : '#48463F' };'''
AA_PROPS = {'isOn': {'editor': 'boolean', 'default': False}, 'height': {'editor': 'enum', 'options': [24, 26, 22], 'default': 24}}

# ---------------------------------------------------------------- SendButton (AskParts.swift)
SEND_MARKUP = '''<span role="button" aria-label="Send" style="width: {{s}}; height: {{s}}; border-radius: 50%; background: {{bg}}; box-shadow: {{shadow}}; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0"><svg width="{{ic}}" height="{{ic}}" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 19V5M5 12l7-7 7 7"></path></svg></span>'''
SEND_SCRIPT = NUM + '''const en = on(p.enabled, true), s = num(p.size, 38);
return { s: s + 'px', ic: Math.round(s * 0.42), bg: en ? '#1F6FEB' : '#D6D3CC', shadow: en ? '0 4px 6px rgba(31,111,235,0.3)' : 'none' };'''
SEND_PROPS = {'enabled': {'editor': 'boolean', 'default': True}, 'size': {'editor': 'int', 'default': 38}}

# ---------------------------------------------------------------- IconButton (no Swift struct yet: add one, same props)
ICB_MARKUP = '''<span role="button" title="{{help}}" aria-label="{{help}}" style="width: {{s}}; height: {{s}}; border-radius: {{r}}; background: {{fill}}; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0"><svg width="{{ic}}" height="{{ic}}" viewBox="0 0 24 24" fill="none" stroke="{{tint}}" stroke-width="{{sw}}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="{{d}}"></path></svg></span>'''
ICB_SCRIPT = '''const ICONS = ''' + json.dumps(ICONS) + ''';
''' + NUM + '''const s = num(p.size, 26);
const SW = { regular: 1.8, medium: 2, semibold: 2.2, bold: 2.6 };
return { d: ICONS[p.systemImage || 'ellipsis'] || ICONS['ellipsis'], s: s + 'px', r: s / 2 + 'px', ic: num(p.iconSize, Math.round(s * 0.42)),
  sw: SW[p.weight] || 2, tint: p.tint || '#6B6862', fill: p.fill || 'transparent', help: p.help || '' };'''
ICB_PROPS = {'systemImage': {'editor': 'enum', 'options': [k for k in ICONS if k], 'default': 'ellipsis'}, 'size': {'editor': 'int', 'default': 26},
             'tint': {'editor': 'color', 'default': MUTED, 'options': [MUTED, FAINT, BLUE, PEACH_INK]},
             'fill': {'editor': 'color', 'default': 'transparent', 'options': ['transparent', PANEL, '#FFFFFF']},
             'iconSize': {'editor': 'int', 'default': ''}, 'weight': {'editor': 'enum', 'options': ['regular', 'medium', 'semibold', 'bold'], 'default': 'medium'},
             'help': {'editor': 'text', 'default': ''}}

# ---------------------------------------------------------------- LinkButton (AskParts.swift)
LINK_MARKUP = '''<span role="button" style="height: 28px; display: inline-flex; align-items: center; padding: 0 8px; color: #1F6FEB; font-size: {{fs}}; font-weight: 600; white-space: nowrap; box-sizing: border-box">{{title}}</span>'''
LINK_SCRIPT = NUM + '''return { title: p.title || '+ Label', fs: num(p.size, 12) + 'px' };'''
LINK_PROPS = {'title': {'editor': 'text', 'default': '+ Label'}, 'size': {'editor': 'enum', 'options': [12, 11, 13], 'default': 12}}

# ---------------------------------------------------------------- Tile (Theme.swift): file type or vault initial
TILE_MARKUP = '''<span style="width: {{s}}; height: {{s}}; border-radius: {{r}}; background: {{fill}}; color: {{ink}}; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0; font-family: {{family}}; font-size: {{fs}}; font-weight: {{fw}}">{{text}}</span>'''
TILE_SCRIPT = NUM + '''const s = num(p.size, 40), display = on(p.display, false);
return { text: p.text || 'NOTE', fill: p.fill || '#E9FBC9', ink: p.ink || '#3D6110', s: s + 'px', r: (s * 0.3) + 'px',
  family: display ? "'Bricolage Grotesque', sans-serif" : "'DM Sans', sans-serif", fs: display ? (s * 0.42) + 'px' : '10px', fw: display ? 800 : 700 };'''
TILE_PROPS = {'text': {'editor': 'text', 'default': 'NOTE'}, 'fill': {'editor': 'color', 'default': LIME_TINT, 'options': [LIME_TINT, TINT, '#FFE4D6', '#FFE0EC']},
              'ink': {'editor': 'color', 'default': LIME_INK, 'options': [LIME_INK, BLUE, PEACH_INK, '#A3245A']},
              'size': {'editor': 'int', 'default': 40}, 'display': {'editor': 'boolean', 'default': False}}

# ---------------------------------------------------------------- FilterPanel (To do: one Filter menu; no Swift view yet)
_NOTES = [['Tea club planning', 2], ['Gyokuro at 60 °C', 2], ['Auth retry bug', 1], ['Incident review prep', 1], ['Q3 architecture sync', 1], ['Hiring loop feedback', 0]]
FP_DATA = {  # per Actions tab: [key, LABEL, single?, search?, items] (items: label or [label, count]; 'more' items: [SUB, [labels]])
    'todo': [['status', 'STATUS', True, False, ['Open', 'Completed', 'All']],
             ['due', 'DUE', False, False, ['Overdue', 'Today', 'This week', 'Next 7 days', 'No due date', 'Pick dates…']],
             ['person', 'PERSON', False, True, [['You (Jin Liu)', 3], ['Mei Tanaka', 2], ['Priya Shah', 1], ['Tom Kim', 1], ['Ken Ito', 1], ['Sara Lee', 0]]],
             ['label', 'LABEL', False, False, [['#project-x', 3], ['#tea', 2], ['#tea-club', 2], ['#incidents', 1], ['#hiring', 1], ['#brewing', 1], ['#personal', 0]]],
             ['note', 'SOURCE NOTE', False, False, _NOTES],
             ['priority', 'PRIORITY', False, False, ['High', 'Medium', 'Low', 'None']],
             ['more', 'MORE', False, False, [['ADDED BY', ['Distill', 'You']], ['VAULT', ['Research', 'Work notes']], ['', ['Only from the last batch']]]]],
    'slack': [['status', 'STATUS', False, False, ['Not written', 'Draft', 'Ready to paste', 'Copied']],
              ['recipient', 'RECIPIENT', False, True, [['Mei Tanaka', 1], ['#project-x', 1], ['#tea-club', 0], ['Tom Kim', 0], ['Priya Shah', 0], ['#incidents', 0]]],
              ['note', 'SOURCE NOTE', False, False, _NOTES],
              ['label', 'LABEL', False, False, [['#tea-club', 1], ['#project-x', 1], ['#tea', 0], ['#incidents', 0]]]],
    'jira': [['status', 'STATUS', False, False, ['Not written', 'Draft', 'Created']],
             ['project', 'PROJECT', False, False, ['PX · Project X', 'OPS · Operations']],
             ['type', 'TYPE', False, False, ['Task', 'Bug', 'Story']],
             ['priority', 'PRIORITY', False, False, ['High', 'Medium', 'Low']],
             ['assignee', 'ASSIGNEE', False, True, [['You (Jin Liu)', 1], ['Priya Shah', 1], ['Unassigned', 0]]],
             ['note', 'SOURCE NOTE', False, False, _NOTES]],
    'confluence': [['status', 'STATUS', False, False, ['Not written', 'Draft', 'Created']],
                   ['space', 'SPACE', False, False, ['Project X', 'Operations', 'Team handbook']],
                   ['note', 'SOURCE NOTE', False, False, _NOTES]],
    'history': [['type', 'TYPE', False, False, ['To do', 'Slack message', 'Jira ticket', 'Confluence page']],
                ['outcome', 'OUTCOME', False, False, ['Completed', 'Sent', 'Created', 'Removed', 'Dismissed']],
                ['date', 'DATE', False, False, ['Today', 'This week', 'Last 30 days', 'Pick dates…']],
                ['source', 'SOURCE', False, False, ['Notes', 'Ask answers', 'Added by you']]],
}
FP_MARKUP = """<div style="width: {{w}}; border-radius: 14px; background: #FFFFFF; box-shadow: 0 0 0 1px rgba(29,28,26,.08), 0 14px 32px rgba(29,28,26,.18); display: flex; flex-direction: column; box-sizing: border-box; overflow: hidden">
<div style="max-height: {{maxH}}; overflow: hidden; padding: 6px 6px 4px">
<sc-if value="{{scrolled}}" hint-placeholder-val="{{ false }}"><div style="height: 3px; margin: 0 40% 4px; border-radius: 2px; background: #ECEAE5"></div></sc-if>
<sc-for list="{{rows}}" as="r" hint-placeholder-count="12">
<sc-if value="{{r.isHead}}" hint-placeholder-val="{{ false }}"><div style="display: flex; align-items: center; padding: 10px 10px 4px; font-size: 10px; font-weight: 800; letter-spacing: .06em; color: {{r.headInk}}"><span style="flex-grow: 1">{{r.label}}</span><span style="font-weight: 700; letter-spacing: 0; color: #1F6FEB">{{r.note}}</span></div></sc-if>
<sc-if value="{{r.isSub}}" hint-placeholder-val="{{ false }}"><div style="padding: 6px 10px 2px; font-size: 10px; font-weight: 700; color: #9B978F">{{r.label}}</div></sc-if>
<sc-if value="{{r.isSearch}}" hint-placeholder-val="{{ false }}"><div style="margin: 2px 6px 4px; height: 28px; display: flex; align-items: center; gap: 7px; padding: 0 10px; border-radius: 14px; background: {{r.bg}}; box-shadow: {{r.ring}}; font-size: 12px; color: {{r.ink}}"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#9B978F" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0M20 20l-4-4"></path></svg>{{r.label}}</div></sc-if>
<sc-if value="{{r.isRow}}" hint-placeholder-val="{{ true }}"><div style="display: flex; align-items: center; gap: 9px; padding: 6px 10px; border-radius: 8px; background: {{r.bg}}">
<span style="width: 14px; height: 14px; border-radius: {{r.box}}; box-sizing: border-box; display: inline-flex; align-items: center; justify-content: center; background: {{r.boxBg}}; box-shadow: inset 0 0 0 1.5px {{r.boxRing}}; flex-shrink: 0"><svg width="9" height="9" viewBox="0 0 24 24" fill="none" stroke="#FFFFFF" stroke-width="4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" style="opacity: {{r.tick}}"><path d="M5 12l5 5 9-10"></path></svg></span>
<span style="flex-grow: 1; font-size: 13px; font-weight: {{r.weight}}; color: #1D1C1A; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{{r.label}}</span><span style="font-size: 11px; color: #9B978F">{{r.count}}</span></div></sc-if>
<sc-if value="{{r.isMore}}" hint-placeholder-val="{{ false }}"><div style="padding: 4px 10px 6px 33px; font-size: 12px; font-weight: 600; color: #1F6FEB">{{r.label}}</div></sc-if>
</sc-for>
</div>
<div style="display: flex; align-items: center; gap: 8px; padding: 8px 10px 10px; border-top: 1px solid #ECEAE5">
<dc-import name="LinkButton" title="Clear all" hint-size="70px,28px"></dc-import><span style="flex-grow: 1; font-size: 11px; color: #9B978F; text-align: right">{{summary}}</span>
<dc-import name="PrimaryButton" title="Done" size="small" hint-size="64px,30px"></dc-import>
</div>
</div>"""
FP_SCRIPT = NUM + """const DATA = """ + json.dumps(FP_DATA, ensure_ascii=False) + """;
const kind = DATA[p.kind] ? p.kind : 'todo';
const list = v => String(v || '').split('|').map(x => x.trim()).filter(Boolean);
const chosen = new Set([].concat(list(p.selected), list(p.due), list(p.person), list(p.label), list(p.note), list(p.priority), list(p.more)));
const status = p.status || 'Open', query = p.personQuery || '', expanded = p.expanded || '';
const rows = [];
const head = (label, key, n) => rows.push({ isHead: true, label, note: n ? n + ' selected' : '', headInk: p.focus === key ? '#1F6FEB' : '#9B978F' });
const row = (label, on, count, single) => rows.push({ isRow: true, label, count: count === undefined ? '' : String(count), weight: on ? 600 : 400,
  bg: on ? '#F2F7FF' : 'transparent', box: single ? '50%' : '4px', boxBg: on ? '#1F6FEB' : '#FFFFFF', boxRing: on ? '#1F6FEB' : '#D6D3CC', tick: on ? 1 : 0 });
const name = it => Array.isArray(it) ? it[0] : it;
const sections = DATA[kind].map(([key, label, single, search, items]) => [key, () => {
  if (key === 'more') {
    const n = items.reduce((a, [, xs]) => a + xs.filter(x => chosen.has(x)).length, 0);
    head(label, key, n);
    items.forEach(([sub, xs]) => { if (sub) rows.push({ isSub: true, label: sub }); xs.forEach(x => row(x, chosen.has(x))); });
    return;
  }
  if (single) { head(label, key, 0); items.forEach(x => row(name(x), name(x) === status, undefined, true)); return; }
  head(label, key, items.filter(x => chosen.has(name(x))).length);
  const q = search ? query : '';
  const ph = { person: 'Find a person', recipient: 'Find a person or channel', assignee: 'Find a person' }[key] || 'Find…';
  if (search) rows.push({ isSearch: true, label: q || ph, ink: q ? '#1D1C1A' : '#9B978F', bg: q ? '#FFFFFF' : '#F6F5F2', ring: q ? '0 0 0 2px #1F6FEB' : 'none' });
  let shown = items.filter(x => !q || name(x).toLowerCase().includes(q.toLowerCase()));
  const all = shown.length;
  if (expanded !== key && !q && all > 6) shown = shown.slice(0, 5);
  shown.forEach(x => row(name(x), chosen.has(name(x)), Array.isArray(x) ? x[1] : undefined));
  if (shown.length < all) rows.push({ isMore: true, label: 'Show all ' + all });
}]);
const start = Math.max(0, sections.findIndex(([k]) => k === (p.scrollTo || sections[0][0])));
sections.slice(start).forEach(([, f]) => f());
const singleStatus = DATA[kind][0][2];
const n = chosen.size + (singleStatus && status !== 'Open' ? 1 : 0);
return { rows, w: num(p.width, 300) + 'px', maxH: num(p.height, 560) + 'px', scrolled: start > 0, summary: n ? n + (n === 1 ? ' filter' : ' filters') : (singleStatus ? 'Status: Open' : 'No filters') };"""
FP_PROPS = {'kind': {'editor': 'enum', 'options': ['todo', 'slack', 'jira', 'confluence', 'history'], 'default': 'todo'},
            'selected': {'editor': 'text', 'default': ''},
            'status': {'editor': 'enum', 'options': ['Open', 'Completed', 'All'], 'default': 'Open'},
            'due': {'editor': 'text', 'default': ''}, 'person': {'editor': 'text', 'default': ''}, 'label': {'editor': 'text', 'default': ''},
            'note': {'editor': 'text', 'default': ''}, 'priority': {'editor': 'text', 'default': ''}, 'more': {'editor': 'text', 'default': ''},
            'personQuery': {'editor': 'text', 'default': ''}, 'expanded': {'editor': 'enum', 'options': ['', 'person', 'label', 'note'], 'default': ''},
            'scrollTo': {'editor': 'text', 'default': ''}, 'focus': {'editor': 'text', 'default': ''},
            'width': {'editor': 'int', 'default': 300}, 'height': {'editor': 'int', 'default': 560}}

# ---------------------------------------------------------------- ActionsToolbar (every Actions tab; no Swift view yet)
TB_MARKUP = """<div style="width: {{w}}; display: flex; align-items: center; gap: 6px; white-space: nowrap; box-sizing: border-box">
<span style="width: {{sw}}; height: 30px; display: inline-flex; align-items: center; gap: 7px; padding: 0 10px; border-radius: 15px; background: {{sBg}}; box-shadow: {{sRing}}; font-size: 12px; box-sizing: border-box; flex-shrink: 0">
<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="#9B978F" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M4 11a7 7 0 1 0 14 0a7 7 0 1 0 -14 0M20 20l-4-4"></path></svg>
<span style="flex-grow: 1; overflow: hidden; color: {{sInk}}">{{sText}}<sc-if value="{{focus}}" hint-placeholder-val="{{ false }}"><span style="display: inline-block; width: 1.5px; height: 14px; background: #1F6FEB; vertical-align: -2px; margin-left: 1px"></span></sc-if></span></span>
<dc-import name="DropdownButton" title="{{filterTitle}}" system-image="line.3.horizontal.decrease" height="30" radius="15" active="{{active}}" hint-size="96px,30px"></dc-import>
<sc-for list="{{chips}}" as="c" hint-placeholder-count="2"><dc-import name="FilterChip" text="{{c.text}}" hint-size="{{c.hint}}"></dc-import></sc-for>
<sc-if value="{{more}}" hint-placeholder-val="{{ false }}"><dc-import name="FilterChip" text="{{moreText}}" removable="false" fill="#ECEAE5" ink="#48463F" hint-size="40px,28px"></dc-import></sc-if>
<span style="flex-grow: 1; min-width: 8px"></span>
<sc-if value="{{isSort}}" hint-placeholder-val="{{ true }}"><dc-import name="DropdownButton" title="{{sortTitle}}" system-image="arrow.up.arrow.down" height="30" radius="15" hint-size="110px,30px"></dc-import></sc-if>
<sc-if value="{{isConn}}" hint-placeholder-val="{{ false }}"><span style="display: inline-flex; align-items: center; gap: 8px; flex-shrink: 0">
<span style="display: inline-flex; align-items: center; gap: 5px; font-size: 12px; color: #6B6862"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="{{connInk}}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="{{connIcon}}"></path></svg><span>{{connSite}} · <b style="font-weight: 700; color: {{connInk}}">{{connState}}</b></span></span>
<sc-if value="{{disconnected}}" hint-placeholder-val="{{ false }}"><dc-import name="PrimaryButton" title="Connect now" system-image="link" size="mini" hint-size="110px,26px"></dc-import></sc-if>
<sc-if value="{{connecting}}" hint-placeholder-val="{{ false }}"><dc-import name="PrimaryButton" title="Connecting…" system-image="progress.indicator" size="mini" hint-size="110px,26px"></dc-import></sc-if>
</span></sc-if>
</div>"""
TB_SCRIPT = PX + NUM + """const chipsAll = String(p.chips || '').split('|').map(x => x.trim()).filter(Boolean);
const vis = p.visibleChips === undefined || p.visibleChips === '' ? chipsAll.length : num(p.visibleChips, chipsAll.length);
const shown = chipsAll.slice(0, vis), hidden = chipsAll.length - shown.length;
const focus = on(p.focus, false), q = p.search || '';
const conn = p.connection || 'connected';
const ICON = { connected: 'M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18', disconnected: 'M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0M9 9l6 6M15 9l-6 6', connecting: 'M12 3a9 9 0 1 1-9 9' };
return { w: px(p.width, '100%'), sw: num(p.searchWidth, 190) + 'px', focus, sText: q || p.placeholder || 'Search', sInk: q ? '#1D1C1A' : '#9B978F',
  sBg: focus ? '#FFFFFF' : '#F6F5F2', sRing: focus ? '0 0 0 2px #1F6FEB' : 'none',
  filterTitle: chipsAll.length ? 'Filter · ' + chipsAll.length : 'Filter', active: chipsAll.length ? 'true' : 'false',
  chips: shown.map(t => ({ text: t, hint: (t.length * 7 + 40) + 'px,28px' })), more: hidden > 0, moreText: '+' + hidden,
  isSort: (p.right || 'sort') === 'sort', sortTitle: p.sortTitle || 'Due date', isConn: p.right === 'connection',
  connSite: conn === 'connected' ? (p.site || 'acme.atlassian.net') : (p.service || 'Atlassian'),
  connState: conn === 'connected' ? 'connected' : 'not connected',
  connInk: conn === 'connected' ? '#3D6110' : '#B03A0A', connIcon: conn === 'connected' ? ICON.connected : ICON.disconnected,
  disconnected: conn === 'disconnected', connecting: conn === 'connecting' };"""
TB_PROPS = {'search': {'editor': 'text', 'default': ''}, 'placeholder': {'editor': 'text', 'default': 'Search to-dos'}, 'focus': {'editor': 'boolean', 'default': False},
            'searchWidth': {'editor': 'int', 'default': 190}, 'chips': {'editor': 'text', 'default': ''}, 'visibleChips': {'editor': 'int', 'default': ''},
            'right': {'editor': 'enum', 'options': ['sort', 'connection', 'none'], 'default': 'sort'}, 'sortTitle': {'editor': 'text', 'default': 'Due date'},
            'connection': {'editor': 'enum', 'options': ['connected', 'disconnected', 'connecting'], 'default': 'connected'},
            'site': {'editor': 'text', 'default': 'acme.atlassian.net'}, 'service': {'editor': 'text', 'default': 'Atlassian'}, 'width': {'editor': 'text', 'default': ''}}

# ---------------------------------------------------------------- ActionRow (Slack, Jira, Confluence lists and History → Actions; no Swift view yet)
AR_TYPES = {'todo': ['#E3EEFF', '#1F6FEB', 'checkmark.circle'], 'slack': ['#FFE0EC', '#A3245A', 'text.bubble'], 'jira': ['#DDF2FF', '#0B5C86', 'ticket'],
            'confluence': ['#E9FBC9', '#3D6110', 'doc.text'], 'email': ['#FFE4D6', '#B03A0A', 'envelope']}
AR_STATUS = {'draft': ['#F6F5F2', '#48463F'], 'ready': ['#E9FBC9', '#3D6110'], 'busy': ['#E3EEFF', '#1F6FEB'], 'created': ['#DDF2FF', '#0B5C86'],
             'error': ['#FFE4D6', '#B03A0A'], 'muted': ['#F6F5F2', '#6B6862'], 'completed': ['#E9FBC9', '#3D6110'], 'removed': ['#FFE4D6', '#B03A0A'],
             'sent': ['#E3EEFF', '#1F6FEB'], 'dismissed': ['#F6F5F2', '#6B6862']}
AR_MARKUP = """<div style="width: {{w}}; display: flex; align-items: center; gap: 10px; padding: 10px 10px 10px 12px; border-radius: 12px; background: {{bg}}; box-shadow: {{ring}}; box-sizing: border-box; opacity: {{op}}">
<span style="width: 28px; height: 28px; border-radius: 8px; background: {{tBg}}; display: inline-flex; align-items: center; justify-content: center; flex-shrink: 0"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="{{tInk}}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="{{tD}}"></path></svg></span>
<div style="display: flex; flex-direction: column; gap: 3px; flex-grow: 1; min-width: 0"><span style="font-size: 13px; font-weight: 600; line-height: 1.3; color: #1D1C1A; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; text-decoration: {{strike}}">{{title}}</span>
<span style="font-size: 11px; color: #6B6862; white-space: nowrap; overflow: hidden; text-overflow: ellipsis">{{source}}</span></div>
<sc-if value="{{showActions}}" hint-placeholder-val="{{ false }}"><span style="display: inline-flex; align-items: center; gap: 2px; flex-shrink: 0">
<sc-if value="{{isHistory}}" hint-placeholder-val="{{ false }}"><dc-import name="IconButton" system-image="clock.arrow.circlepath" tint="#1F6FEB" help="Restore" hint-size="26px,26px"></dc-import></sc-if>
<sc-if value="{{canComplete}}" hint-placeholder-val="{{ true }}"><dc-import name="IconButton" system-image="checkmark.circle" tint="#3D6110" help="Complete (you’ve handled it)" hint-size="26px,26px"></dc-import></sc-if>
<dc-import name="IconButton" system-image="ellipsis" help="More" hint-size="26px,26px"></dc-import></span></sc-if>
<dc-import name="Pill" text="{{status}}" fill="{{sBg}}" ink="{{sInk}}" busy="{{busy}}" size="small" hint-size="80px,20px"></dc-import>
</div>"""
AR_SCRIPT = PX + """const ICONS = """ + json.dumps(ICONS) + """;
const T = """ + json.dumps(AR_TYPES) + """, S = """ + json.dumps(AR_STATUS) + """;
const t = T[p.type] || T.slack, st = S[p.statusKind] || S.draft;
const sel = on(p.selected, false), hover = on(p.hover, false), hist = p.mode === 'history';
return { w: px(p.width, '100%'), tBg: t[0], tInk: t[1], tD: ICONS[t[2]] || '', title: p.title || 'Message to Mei Tanaka', source: p.source || 'From Tea club planning · today at 3:44 PM',
  status: p.status || 'Draft', sBg: st[0], sInk: st[1], busy: p.statusKind === 'busy' ? 'true' : 'false',
  bg: sel ? '#F2F7FF' : hover ? '#F6F5F2' : 'transparent', ring: sel ? 'inset 0 0 0 1.5px #BFD5FA' : 'none',
  showActions: hover, isHistory: hist, canComplete: !hist, op: on(p.faded, false) ? 0.4 : 1, strike: on(p.faded, false) ? 'line-through' : 'none' };"""
AR_PROPS = {'type': {'editor': 'enum', 'options': list(AR_TYPES), 'default': 'slack'}, 'title': {'editor': 'text', 'default': 'Message to Mei Tanaka'},
            'source': {'editor': 'text', 'default': 'From Tea club planning · today at 3:44 PM'}, 'status': {'editor': 'text', 'default': 'Draft'},
            'statusKind': {'editor': 'enum', 'options': list(AR_STATUS), 'default': 'draft'}, 'selected': {'editor': 'boolean', 'default': False},
            'hover': {'editor': 'boolean', 'default': False}, 'mode': {'editor': 'enum', 'options': ['list', 'history'], 'default': 'list'},
            'faded': {'editor': 'boolean', 'default': False}, 'width': {'editor': 'text', 'default': ''}}

CONTROLS = [  # file, title, markup, props, script, preview w, h, swift file, states
    ('Segmented', 'Segmented', SEG_MARKUP, SEG_PROPS, SEG_SCRIPT, 180, 28, 'AskParts.swift'),
    ('SegmentedPills', 'Segmented pills', SEG_MARKUP, SEGP_PROPS, SEG_SCRIPT, 180, 28, 'ComposeComponents.swift'),
    ('PillSwitch', 'Pill switch', PSW_MARKUP, PSW_PROPS, PSW_SCRIPT, 40, 24, 'ComposeComponents.swift'),
    ('CapsuleSwitch', 'Capsule switch', CSW_MARKUP, CSW_PROPS, CSW_SCRIPT, 160, 20, 'AskParts.swift'),
    ('LabelChip', 'Label chip', LCHIP_MARKUP, LCHIP_PROPS, LCHIP_SCRIPT, 100, 26, 'ComposeComponents.swift'),
    ('FilterChip', 'Filter chip', FCHIP_MARKUP, FCHIP_PROPS, FCHIP_SCRIPT, 80, 28, 'AskParts.swift'),
    ('SourceChip', 'Source chip', SCHIP_MARKUP, SCHIP_PROPS, SCHIP_SCRIPT, 80, 26, 'SettingsSections.swift'),
    ('ModelChip', 'Model chip', MCHIP_MARKUP, MCHIP_PROPS, MCHIP_SCRIPT, 180, 30, 'AskParts.swift'),
    ('DropdownButton', 'Dropdown button', DD_MARKUP, DD_PROPS, DD_SCRIPT, 160, 32, 'ComposeComponents.swift'),
    ('QuickSourceButton', 'Quick source button', QSB_MARKUP, QSB_PROPS, QSB_SCRIPT, 90, 24, 'QuickNote.swift'),
    ('MarkdownBarToggle', 'Aa toggle', AA_MARKUP, AA_PROPS, AA_SCRIPT, 36, 24, 'MarkdownEditorBar.swift'),
    ('SendButton', 'Send button', SEND_MARKUP, SEND_PROPS, SEND_SCRIPT, 38, 38, 'AskParts.swift'),
    ('IconButton', 'Icon button', ICB_MARKUP, ICB_PROPS, ICB_SCRIPT, 26, 26, 'Theme.swift'),
    ('LinkButton', 'Link button', LINK_MARKUP, LINK_PROPS, LINK_SCRIPT, 80, 28, 'AskParts.swift'),
    ('Tile', 'Tile', TILE_MARKUP, TILE_PROPS, TILE_SCRIPT, 40, 40, 'Theme.swift'),
    ('FilterPanel', 'Filter panel', FP_MARKUP, FP_PROPS, FP_SCRIPT, 300, 560, '(new)'),
    ('ActionsToolbar', 'Actions toolbar', TB_MARKUP, TB_PROPS, TB_SCRIPT, 820, 30, '(new)'),
    ('ActionRow', 'Action row', AR_MARKUP, AR_PROPS, AR_SCRIPT, 330, 56, '(new)'),
]


def i(name, w, h, **a):
    return imp(name, {k: ('true' if v is True else 'false' if v is False else v) for k, v in a.items()}, w, h)


STATES = {
    'Segmented': ('Any or all labels, effort, History Jobs / Ask chats. In Swift SegmentedPills is a typealias of Segmented: one view. Props: options (“|”-separated), selection, height.', [
        state('Any label', i('Segmented', '180px', '28px', options='Any label|All labels', selection='Any label'), 'Ask filters, height 24'),
        state('All labels', i('Segmented', '180px', '28px', options='Any label|All labels', selection='All labels'), ''),
        state('Quick ask', i('Segmented', '160px', '26px', options='Any label|All labels', selection='Any label', height=22), 'height 22'),
        state('Effort', i('Segmented', '200px', '30px', options='Low|Medium|High', selection='Medium', height=26), 'EffortPicker, height 26'),
        state('History', i('Segmented', '170px', '30px', options='Jobs|Ask chats', selection='Jobs', height=26), 'History, height 26')]),
    'SegmentedPills': ('SegmentedPills = Segmented in Swift (a typealias); kept as its own board so the Settings uses read the same. Props: options, selection, height, track.', [
        state('Draft timing', i('SegmentedPills', '330px', '28px', options='When a note is processed|Only when I ask', selection='When a note is processed'), 'Settings → Actions → a type'),
        state('Keep history', i('SegmentedPills', '260px', '28px', options='30 days|90 days|1 year|Forever', selection='90 days'), ''),
        state('Panel track', i('SegmentedPills', '180px', '28px', options='Any label|All labels', selection='All labels', track=PANEL), 'track="#F6F5F2"'),
        state('Show', i('SegmentedPills', '220px', '28px', options='Open|Open and completed', selection='Open'), 'To-do defaults')]),
    'PillSwitch': ('The on/off switch, blue when on. Props: isOn, label (accessibility), width, height. Settings uses 36 × 22.', [
        state('On', i('PillSwitch', '40px', '24px', isOn=True, label='Automatic batching'), '40 × 24'),
        state('Off', i('PillSwitch', '40px', '24px', isOn=False, label='Automatic batching'), ''),
        state('Settings on', i('PillSwitch', '36px', '22px', isOn=True, label='Detect to-dos', width=36, height=22), '36 × 22 in Settings rows'),
        state('Settings off', i('PillSwitch', '36px', '22px', isOn=False, label='Detect to-dos', width=36, height=22), '')]),
    'CapsuleSwitch': ('A switch with its title (Ask filters). Props: title, isOn, fontSize (12 | 11 in the quick ask).', [
        state('On', i('CapsuleSwitch', '160px', '20px', title='Include unconfirmed', isOn=True), ''),
        state('Off', i('CapsuleSwitch', '160px', '20px', title='Include unconfirmed', isOn=False), ''),
        state('Quick ask', i('CapsuleSwitch', '150px', '20px', title='Include unconfirmed', isOn=True, fontSize=11), 'fontSize 11')]),
    'LabelChip': ('A label. Suggested chips are dashed (green = existing, peach = new); confirmed ones are solid. Props: labelName (Swift: name), style, sparkle, height, showNewTag, removable (onRemove).', [
        state('Plain', i('LabelChip', '60px', '26px', labelName='tea'), 'confirmed'),
        state('Suggested, existing', i('LabelChip', '100px', '26px', labelName='gyokuro', style='suggestedExisting', removable=True), 'click to accept, × to drop'),
        state('Suggested, new', i('LabelChip', '110px', '26px', labelName='kettle', style='suggestedNew', removable=True), '“new” tag'),
        state('Sparkle', i('LabelChip', '110px', '26px', labelName='brewing', style='suggestedExisting', sparkle=True), 'AI suggestion inline'),
        state('Muted', i('LabelChip', '80px', '26px', labelName='hiring', style='muted'), 'skipped'),
        state('Removable', i('LabelChip', '80px', '26px', labelName='tea', removable=True), 'chosen in the label step')]),
    'FilterChip': ('A removable filter (#tea ×, Slack ×). Props: text, fill, ink, height, removable (onRemove).', [
        state('Label', i('FilterChip', '70px', '28px', text='#tea'), ''),
        state('Source', i('FilterChip', '80px', '28px', text='Slack', fill=LIME_TINT, ink=LIME_INK), 'source filters are lime'),
        state('Not removable', i('FilterChip', '70px', '28px', text='#tea', removable=False), ''),
        state('To-do filter', i('FilterChip', '130px', '28px', text='Status: Open ▾'), 'To do filter bar (an active filter)')]),
    'SourceChip': ('A source in Settings → Sources. Props: label, hovering (shows ×; also Remove in the context menu).', [
        state('Default', i('SourceChip', '60px', '26px', label='Slack'), ''),
        state('Hovering', i('SourceChip', '80px', '26px', label='Meeting', hovering=True), '')]),
    'ModelChip': ('Runner · model chip with the runner menu (Ask). Props: runner, model, effort, showRunner, showEffort, compact.', [
        state('Default', i('ModelChip', '180px', '30px', runner='Claude Code', model='Sonnet'), 'main Ask'),
        state('With effort', i('ModelChip', '230px', '30px', runner='Claude Code', model='Sonnet', showEffort=True), 'showEffort'),
        state('Compact', i('ModelChip', '130px', '26px', model='Sonnet', effort='Medium', showRunner=False, showEffort=True, compact=True), 'quick ask footer')]),
    'DropdownButton': ('A white field-looking button with ▾ that opens a menu (model pickers, To-do defaults, the To do Filter button). Props: title, width, height, radius, fontSize, enabled, systemImage, active (blue: filters are set). systemImage and active are new: Swift needs them for Filter.', [
        state('Runner', i('DropdownButton', '128px', '30px', title='Claude Code', width=128, height=30), 'ModelPickers in Settings'),
        state('Model', i('DropdownButton', '100px', '30px', title='Sonnet', width=100, height=30), ''),
        state('Effort', i('DropdownButton', '96px', '30px', title='Medium', width=96, height=30), ''),
        state('Round', i('DropdownButton', '110px', '30px', title='Haiku · Low', height=30, radius=15), 'Labels and image sheets: radius 15'),
        state('Disabled', i('DropdownButton', '96px', '30px', title='Default', width=96, height=30, enabled=False), 'no effort levels'),
        state('Filter', i('DropdownButton', '90px', '30px', title='Filter', systemImage='line.3.horizontal.decrease', height=30, radius=15), 'To do: no filters beyond Status: Open'),
        state('Filter · 2', i('DropdownButton', '110px', '30px', title='Filter · 2', systemImage='line.3.horizontal.decrease', height=30, radius=15, active=True), 'active: two filters set'),
        state('Group and sort', i('DropdownButton', '110px', '30px', title='Due date', systemImage='arrow.up.arrow.down', height=30, radius=15), 'right end of the bar')]),
    'QuickSourceButton': ('“+ Source” in the quick note footer; becomes the chosen source (green, ▾). Props: source.', [
        state('No source', i('QuickSourceButton', '70px', '24px'), 'a fresh quick note'),
        state('Chosen', i('QuickSourceButton', '90px', '24px', source='In person'), '')]),
    'MarkdownBarToggle': ('The Aa button that shows or hides the compact style bar. Props: isOn, height (24 main windows, 26 quick windows).', [
        state('Off', i('MarkdownBarToggle', '36px', '24px'), ''), state('On', i('MarkdownBarToggle', '36px', '24px', isOn=True), ''),
        state('Quick, off', i('MarkdownBarToggle', '38px', '26px', height=26), 'QuickMarkdownBarToggle'), state('Quick, on', i('MarkdownBarToggle', '38px', '26px', height=26, isOn=True), '')]),
    'SendButton': ('Round send button (⌘↩). Props: enabled, size.', [
        state('Enabled', i('SendButton', '38px', '38px'), ''), state('Disabled', i('SendButton', '38px', '38px', enabled=False), 'empty question'),
        state('Quick ask', i('SendButton', '30px', '30px', size=30), 'size 30')]),
    'IconButton': ('A round icon-only button (⋯, edit, remove, close, refresh). Swift: <b>IconButton</b>(systemImage:, size: = 26, tint: = Theme.muted, fill: Color? = nil, iconSize:, weight:, help:, label:, action:). The icon is 0.42 × size unless iconSize is set; fill and the hover fill (ink at 6%) are circles; help is both the tooltip and the accessibility label. Props: systemImage (SF Symbol), size, tint, fill, iconSize, weight, help.', [
        state('More', i('IconButton', '28px', '28px', systemImage='ellipsis', size=28, help='More'), 'size 28'),
        state('Edit', i('IconButton', '28px', '28px', systemImage='pencil', size=28, help='Edit'), 'size 28'),
        state('Remove', i('IconButton', '28px', '28px', systemImage='trash', size=28, help='Remove'), 'size 28'),
        state('Dismiss', i('IconButton', '26px', '26px', systemImage='xmark', tint=FAINT, help='Dismiss'), 'default size 26, faint'),
        state('Refresh', i('IconButton', '30px', '30px', systemImage='arrow.clockwise', size=30, fill=PANEL, help='Refresh'), 'fill panel'),
        state('Blue', i('IconButton', '26px', '26px', systemImage='arrow.up.right.square', tint=BLUE, help='Open'), ''),
        state('Bold, larger icon', i('IconButton', '26px', '26px', systemImage='xmark', iconSize=12, weight='bold', help='Close'), 'iconSize 12, weight bold')]),
    'LinkButton': ('Blue text button (+ Label, + Limit by source, Open Settings). Props: title, size.', [
        state('+ Label', i('LinkButton', '64px', '28px', title='+ Label'), ''), state('+ Limit by source', i('LinkButton', '120px', '28px', title='+ Limit by source'), ''),
        state('Open Settings', i('LinkButton', '100px', '28px', title='Open Settings'), ''), state('Small', i('LinkButton', '60px', '28px', title='+ Limit', size=11), 'size 11')]),
    'Tile': ('Colored rounded tile with a short label: the file type in Queue rows, a vault’s initial. Props: text, fill, ink, size, display (Bricolage initial instead of a 10 pt label).', [
        state('Note', i('Tile', '40px', '40px', text='NOTE'), 'Queue row'), state('PNG', i('Tile', '40px', '40px', text='PNG', fill=TINT, ink=BLUE), ''),
        state('PDF', i('Tile', '40px', '40px', text='PDF', fill='#FFE4D6', ink=PEACH_INK), ''), state('MD', i('Tile', '40px', '40px', text='MD'), ''),
        state('Vault initial', i('Tile', '34px', '34px', text='R', fill='#FFE0EC', ink='#A3245A', size=34, display=True), 'Settings → Vaults, size 34, display'),
        state('Sidebar vault', i('Tile', '30px', '30px', text='W', fill=TINT, ink=BLUE, size=30, display=True), 'VaultSwitcher')]),
    'FilterPanel': ('To do’s one Filter menu, a popover under the Filter button. Sections STATUS (one choice), DUE, PERSON (with search), LABEL, SOURCE NOTE, PRIORITY and MORE (several each, check marks). Long sections show the top 5, then “Show all N”. Footer: Clear all · Done. No Swift view yet: add <b>FilterPanel</b> with the same inputs. Props: status, due, person, label, note, priority, more (“|”-separated selections), personQuery, expanded, scrollTo (opened from a chip), focus, width, height.', [
        state('Nothing set', i('FilterPanel', '300px', '560px'), 'Status: Open is the default and shows no chip'),
        state('Two filters', i('FilterPanel', '300px', '560px', due='Today', label='#tea'), 'Due: Today and #tea; the button reads Filter · 2'),
        state('Opened from a chip', i('FilterPanel', '300px', '560px', scrollTo='person', focus='person', person='You (Jin Liu)'), 'Clicking “You (Jin Liu) ×” opens the panel at PERSON'),
        state('Searching people', i('FilterPanel', '300px', '420px', scrollTo='person', focus='person', personQuery='mei', height=420), 'The search narrows PERSON as you type'),
        state('Show all labels', i('FilterPanel', '300px', '560px', scrollTo='label', expanded='label', label='#tea|#tea-club'), 'Show all 7 expands the section in place'),
        state('Status: All', i('FilterPanel', '300px', '420px', status='All', height=420), 'Status: All shows a chip; Clear all returns to Status: Open'),
        state('Slack messages', i('FilterPanel', '300px', '480px', kind='slack', selected='Ready to paste', height=480), 'kind="slack": Status, Recipient, Source note, Label'),
        state('Jira tickets', i('FilterPanel', '300px', '480px', kind='jira', selected='Draft|PX · Project X', height=480), 'kind="jira": Status, Project, Type, Priority, Assignee, Source note'),
        state('Confluence pages', i('FilterPanel', '300px', '420px', kind='confluence', height=420), 'kind="confluence": Status, Space, Source note'),
        state('History → Actions', i('FilterPanel', '300px', '480px', kind='history', selected='Completed|This week', height=480), 'kind="history": Type, Outcome, Date, Source')]),
    'ActionsToolbar': ('One toolbar for every Actions tab: [search] [Filter ▾ · N] [active filter chips] … [right slot]. It stays one line: chips that don’t fit collapse into “+N” (opens the Filter panel) before anything wraps. Right slot: group/sort (To do), Newest first ▾ (Slack, History), connection status and Connect now (Jira, Confluence). No Swift view yet: add <b>ActionsToolbar</b>. Props: search, placeholder, focus, searchWidth, chips (“|”), visibleChips, right (sort | connection | none), sortTitle, connection (connected | disconnected | connecting), site, service, width.', [
        state('To do, no filters', i('ActionsToolbar', '820px', '30px', placeholder='Search to-dos', width=820), 'Status: Open is the default: no chip, plain Filter'),
        state('Two filters', i('ActionsToolbar', '820px', '30px', placeholder='Search to-dos', chips='Person: You|#project-x', width=820), 'Filter · 2, one removable chip each'),
        state('Narrow (890 pt window)', i('ActionsToolbar', '566px', '30px', placeholder='Search to-dos', searchWidth=160, chips='Status: All|Due: This week|Person: You|#project-x|#tea', visibleChips=1, width=566), 'Chips past the room collapse into +4; still one line'),
        state('Slack', i('ActionsToolbar', '820px', '30px', placeholder='Search messages', sortTitle='Newest first', width=820), 'right: Newest first ▾'),
        state('Jira, not connected', i('ActionsToolbar', '820px', '30px', placeholder='Search tickets', right='connection', connection='disconnected', width=820), 'Connect now opens Settings → Connections (token sign-in)'),
        state('Jira, connecting', i('ActionsToolbar', '820px', '30px', placeholder='Search tickets', right='connection', connection='connecting', width=820), 'While the browser sign-in is open'),
        state('Jira, connected', i('ActionsToolbar', '820px', '30px', placeholder='Search tickets', right='connection', chips='Draft', width=820), 'acme.atlassian.net · connected'),
        state('History → Actions', i('ActionsToolbar', '820px', '30px', placeholder='Search history', chips='Completed', sortTitle='Newest first', width=820), '')]),
    'ActionRow': ('One row for every handler list (Slack messages, Jira tickets, Confluence pages) and History → Actions: type icon, title, source line, status pill. On hover: ✓ Complete (“you’ve handled it”, independent of Jira’s or Confluence’s own status) and ⋯; in History, Restore and ⋯. To do keeps its own row (a checkbox that completes, due date, person, labels and priority), because to-dos are worked through as a checklist. No Swift view yet: add <b>ActionRow</b>. Props: type, title, source, status, statusKind, selected, hover, mode (list | history), faded, width.', [
        state('Slack, ready', i('ActionRow', '330px', '56px', type='slack', title='Message to Mei Tanaka', source='From Tea club planning · today at 3:44 PM', status='Ready to paste', statusKind='ready', width=330), ''),
        state('Selected', i('ActionRow', '330px', '56px', type='jira', title='Cap payment client retries at 3', source='From Auth retry bug · today at 3:50 PM', status='Draft', selected=True, width=330), 'its detail is open on the right'),
        state('Hover: Complete and ⋯', i('ActionRow', '330px', '56px', type='jira', title='PX-482 Add an alert for retry storms', source='Created today at 3:51 PM · In progress in Jira', status='Created', statusKind='created', hover=True, width=330), 'Complete works on drafts, created and ready items alike'),
        state('Not written', i('ActionRow', '330px', '56px', type='confluence', title='Tea club: brewing temperatures cheat sheet', source='From Gyokuro at 60 °C · not written yet', status='Not written', statusKind='muted', width=330), ''),
        state('Writing', i('ActionRow', '330px', '56px', type='slack', title='Message to #project-x', source='From Auth retry bug', status='Writing', statusKind='busy', width=330), ''),
        state('Completed (leaving)', i('ActionRow', '330px', '56px', type='slack', title='Message to Mei Tanaka', source='Completed just now', status='Completed', statusKind='completed', faded=True, width=330), 'struck through, then it moves to History; toast “Completed · Undo”'),
        state('History, hover: Restore', i('ActionRow', '330px', '56px', type='confluence', title='On-call handoff checklist', source='Completed by you yesterday at 5:40 PM', status='Completed', statusKind='completed', mode='history', hover=True, width=330), 'mode="history"'),
        state('History, removed', i('ActionRow', '330px', '56px', type='slack', title='Message to #project-x about retries', source='Removed today at 4:02 PM', status='Removed', statusKind='removed', mode='history', width=330), ''),
        state('History, sent', i('ActionRow', '330px', '56px', type='todo', title='Cap payment client retries at 3', source='Sent to Jira tickets today at 3:50 PM', status='Sent', statusKind='sent', mode='history', width=330), 'sent items have no Restore')]),
}


WIDE = {'ActionsToolbar': (1920, 2), 'FilterPanel': (1680, 5), 'ActionRow': (1280, 3)}  # states boards wider than 960


def build():
    out = []
    for name, title, markup, props, script, w, h, swift in CONTROLS:
        out.append(component(f'{name}.dc.html', title, markup, props, script, w, h))
        intro, cells = STATES[name]
        src = f'{swift} → <b>{name}</b>. ' if swift != '(new)' else ''
        W, cols = WIDE.get(name, (960, 3))
        out.append(states_board(f'{name}States.dc.html', f'{title} states', name, src + intro, cells, W,
                                C.H(f'{name}States.dc.html', 300), cols=cols))
    return out


if __name__ == '__main__':
    boards = build()
    if '--measure' in sys.argv:
        C.measure(boards)
        boards = build()
    print('\n'.join(f'{f} {w}x{h}' for f, w, h in boards if f.endswith('States.dc.html')))

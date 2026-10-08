/* @ds-bundle: {"format":4,"namespace":"Distill","components":[{"name":"PrimaryButton"},{"name":"Pill"}]} */
(function () {
  var h = window.React.createElement;
  // SF Symbol name -> stroke path (subset of apps/distill/design/data/icons.json)
  var ICONS = {
    'checkmark': 'M5 12l5 5 9-10',
    'plus': 'M12 5v14M5 12h14',
    'paperplane': 'M21 3L10 14M21 3l-7 18-4-7-7-4z',
    'clock': 'M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0M12 7v5l3 2',
    'exclamationmark.circle': 'M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0M12 8v5M12 16h.01'
  };
  function icon(name, size, width) {
    var d = ICONS[name || ''];
    if (!d) return null;
    return h('svg', { width: size, height: size, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: width, strokeLinecap: 'round', strokeLinejoin: 'round', 'aria-hidden': 'true', className: 'ds-icon' }, h('path', { d: d }));
  }
  // A colour prop is a token name (peachTint) or a literal colour.
  function color(v, fallback) {
    v = v || fallback;
    return /^[A-Za-z][A-Za-z0-9]*$/.test(v) ? 'var(--' + v + ')' : v;
  }
  // Theme.swift PrimaryButton: title, systemImage, size (regular | small | mini), enabled
  function PrimaryButton(p) {
    var size = p.size || 'regular';
    var enabled = p.enabled !== false && p.enabled !== 'false';
    return h('button', { type: 'button', disabled: !enabled, className: 'ds-primary ds-primary-' + size, onClick: p.onClick },
      icon(p.systemImage, size === 'regular' ? 12 : 10, 3), p.title != null ? p.title : p.children);
  }
  // Theme.swift Pill: text, fill, ink, size (regular | small), systemImage, busy, stroke, dashed
  function Pill(p) {
    var size = p.size || 'regular';
    var on = function (v) { return v === true || v === 'true'; };
    var cls = 'ds-pill ds-pill-' + size + (on(p.dashed) ? ' ds-pill-dashed' : on(p.stroke) ? ' ds-pill-stroke' : '');
    return h('span', { className: cls, style: { '--pill-fill': color(p.fill, 'peachTint'), '--pill-ink': color(p.ink, 'peachInk') } },
      on(p.busy) ? h('span', { className: 'ds-spinner', 'aria-hidden': 'true' }) : null,
      icon(p.systemImage, size === 'small' ? 9 : 10, 2.6),
      p.text != null ? p.text : p.children);
  }
  window.Distill = Object.assign(window.Distill || {}, { PrimaryButton: PrimaryButton, Pill: Pill });
})();

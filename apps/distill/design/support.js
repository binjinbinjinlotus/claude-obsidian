// Minimal local shim of the design canvas runtime, for headless screenshots only.
// Supports holes, sc-for, sc-if and <dc-import> of sibling .dc.html files.
class DCLogic { constructor() { this.props = {}; this.state = {}; } setState() {} forceUpdate() {} }
window.DCLogic = DCLogic;
document.addEventListener('DOMContentLoaded', () => {
  const ev = (expr, ctx) => {
    try { return new Function(...Object.keys(ctx), 'return (' + expr + ');')(...Object.values(ctx)); } catch (e) { return ''; }
  };
  const interp = (str, ctx) => str.replace(/\{\{([\s\S]+?)\}\}/g, (_, e) => { const v = ev(e.trim(), ctx); return v == null ? '' : String(v); });
  const one = (str, ctx) => { const m = str.match(/^\s*\{\{([\s\S]+?)\}\}\s*$/); return m ? ev(m[1].trim(), ctx) : str; };
  const runScript = (text, props) => {
    try {
      return new Function('DCLogic', 'props', text + '\nconst c = new Component(); c.props = props || {}; return c.renderVals();')(DCLogic, props);
    } catch (e) { console.error(e); return {}; }
  };
  const loaded = {};
  function loadComponent(name) {
    if (loaded[name]) return loaded[name];
    const xhr = new XMLHttpRequest();
    xhr.open('GET', name + '.dc.html', false);
    xhr.send();
    const doc = new DOMParser().parseFromString(xhr.responseText, 'text/html');
    const xdc = doc.querySelector('x-dc');
    const helmet = xdc && xdc.querySelector('helmet');
    if (helmet) { for (const ch of Array.from(helmet.childNodes)) document.head.appendChild(document.importNode(ch, true)); helmet.remove(); }
    const script = doc.querySelector('script[data-dc-script]');
    loaded[name] = { nodes: xdc ? Array.from(xdc.childNodes) : [], script: script ? script.textContent : '' };
    return loaded[name];
  }
  function walk(node, ctx) {
    if (node.nodeType === 3) { if (node.nodeValue.includes('{{')) node.nodeValue = interp(node.nodeValue, ctx); return; }
    if (node.nodeType !== 1) return;
    const tag = node.tagName.toLowerCase();
    if (tag === 'script') return;
    if (tag === 'dc-import') {
      const name = node.getAttribute('name');
      const props = {};
      for (const a of Array.from(node.attributes)) {
        if (a.name === 'name' || a.name.startsWith('hint-')) continue;
        const key = a.name.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
        props[key] = a.value.includes('{{') ? (/^\s*\{\{[\s\S]+\}\}\s*$/.test(a.value) ? one(a.value, ctx) : interp(a.value, ctx)) : a.value;
      }
      const comp = loadComponent(name);
      const vals = runScript(comp.script, props);
      const frag = document.createDocumentFragment();
      const kids = comp.nodes.map((n) => document.importNode(n, true));
      kids.forEach((k) => frag.appendChild(k));
      node.replaceWith(frag);
      kids.forEach((k) => walk(k, vals));
      return;
    }
    if (tag === 'sc-for') {
      const list = one(node.getAttribute('list') || '', ctx) || [];
      const as = node.getAttribute('as') || 'item';
      const frag = document.createDocumentFragment();
      list.forEach((item, i) => {
        const c = { ...ctx, [as]: item, index: i, $index: i };
        for (const ch of Array.from(node.childNodes)) { const cl = ch.cloneNode(true); frag.appendChild(cl); walk(cl, c); }
      });
      node.replaceWith(frag);
      return;
    }
    if (tag === 'sc-if') {
      const v = one(node.getAttribute('value') || '', ctx);
      if (!v) { node.remove(); return; }
      const frag = document.createDocumentFragment();
      for (const ch of Array.from(node.childNodes)) { frag.appendChild(ch); }
      const kids = Array.from(frag.childNodes);
      node.replaceWith(frag);
      kids.forEach((k) => walk(k, ctx));
      return;
    }
    for (const a of Array.from(node.attributes)) if (a.value.includes('{{')) node.setAttribute(a.name, interp(a.value, ctx));
    for (const ch of Array.from(node.childNodes)) walk(ch, ctx);
  }
  const s = document.querySelector('script[data-dc-script]');
  const vals = s ? runScript(s.textContent, {}) : {};
  walk(document.body, vals);
  const h = document.querySelector('helmet');
  if (h) for (const ch of Array.from(h.childNodes)) document.head.appendChild(ch);
});

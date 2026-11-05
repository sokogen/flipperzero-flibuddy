// FliBuddy for Flipper Zero: 128x64 1-bit renderer, screens and app state machine.
export const W = 128, H = 64, CORE = 242;

const I = {
  usb: ['....#####', '....#...#', '#####.#.#', '....#...#', '....#####'],
  bt: ['..#..', '..##.', '#.#.#', '.###.', '..#..', '.###.', '#.#.#', '..##.', '..#..'],
  check: ['......#', '.....##', '#...##.', '##.##..', '.###...', '..#....'],
  plus: ['..#..', '..#..', '#####', '..#..', '..#..'],
  q: ['.##.', '#..#', '..#.', '.#..', '....', '.#..'],
  x: ['#...#', '.#.#.', '..#..', '.#.#.', '#...#'],
  aL: ['..#', '.##', '###', '.##', '..#'],
  aR: ['#..', '##.', '###', '##.', '#..'],
  aU: ['..#..', '.###.', '#####'],
  aD: ['#####', '.###.', '..#..'],
  ok: ['.###.', '#...#', '#...#', '#...#', '.###.'],
  warn: ['....#....', '...#.#...', '...#.#...', '..#.#.#..', '..#.#.#..', '.#.....#.', '.#..#..#.', '#########'],
  app: ['..######..', '.#......#.', '#..####..#', '#.#....#.#', '#.#.##.#.#', '#.#.##.#.#', '#.#....#.#', '#..####..#', '.#......#.', '..######..'],
  clock: ['..######..', '.#......#.', '#...#....#', '#...#....#', '#...###..#', '#........#', '#........#', '#........#', '.#......#.', '..######..'],
  dice: ['##########', '#........#', '#.##..##.#', '#.##..##.#', '#........#', '#........#', '#.##..##.#', '#.##..##.#', '#........#', '##########'],
  count: ['..........', '.##..###..', '#..#....#.', '...#..##..', '..#.....#.', '.#...#..#.', '####..##..', '..........', '..........', '..........'],
};
export const APP_ICON = I.app;
const SPECIAL = {'…': ['.....', '.....', '.....', '.....', '#.#.#'], '·': ['...', '...', '.#.', '...', '...']};
const DIG = {
  0: ['.###.', '#...#', '#...#', '#...#', '#...#', '#...#', '.###.'], 1: ['..#..', '.##..', '..#..', '..#..', '..#..', '..#..', '.###.'],
  2: ['.###.', '#...#', '....#', '...#.', '..#..', '.#...', '#####'], 3: ['#####', '...#.', '..#..', '...#.', '....#', '#...#', '.###.'],
  4: ['...#.', '..##.', '.#.#.', '#..#.', '#####', '...#.', '...#.'], 5: ['#####', '#....', '####.', '....#', '....#', '#...#', '.###.'],
  6: ['..##.', '.#...', '#....', '####.', '#...#', '#...#', '.###.'], 7: ['#####', '....#', '...#.', '..#..', '.#...', '.#...', '.#...'],
  8: ['.###.', '#...#', '#...#', '.###.', '#...#', '#...#', '.###.'], 9: ['.###.', '#...#', '#...#', '.####', '....#', '...#.', '.##..'],
};
const BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]];

let off, octx, fontsP;
const cache = new Map(), tops = {};
export function loadFonts() {
  if (!fontsP) fontsP = Promise.all(['8px Silkscreen', '700 8px Silkscreen', '16px Silkscreen', '700 16px Silkscreen'].map(f => document.fonts.load(f))).then(() => {
    off = document.createElement('canvas'); off.width = 360; off.height = 48;
    octx = off.getContext('2d', {willReadFrequently: true});
    [[0, 1], [1, 1], [0, 2], [1, 2]].forEach(([b, s]) => { const r = raster('H', b, s); tops[b + '' + s] = r.minY; });
  });
  return fontsP;
}
function raster(str, bold, size) {
  const key = (bold ? 'b' : 'r') + size + str;
  if (cache.has(key)) return cache.get(key);
  octx.clearRect(0, 0, 360, 48);
  octx.font = `${bold ? 700 : 400} ${8 * size}px Silkscreen`;
  octx.fillStyle = '#000'; octx.textBaseline = 'alphabetic';
  octx.fillText(str, 2, 30);
  const d = octx.getImageData(0, 0, 360, 48).data, pts = [];
  let minY = 99;
  for (let y = 0; y < 48; y++) for (let x = 0; x < 360; x++) if (d[(y * 360 + x) * 4 + 3] > 120) { pts.push(x - 2, y); if (y < minY) minY = y; }
  const r = {pts, adv: Math.round(octx.measureText(str).width), minY};
  cache.set(key, r);
  return r;
}

export class G {
  constructor() { this.b = new Uint8Array(W * H); }
  px(x, y, c = 1) { x |= 0; y |= 0; if (x < 0 || y < 0 || x >= W || y >= H) return; const i = y * W + x; this.b[i] = c === 2 ? this.b[i] ^ 1 : c; }
  box(x, y, w, h, c = 1) { for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) this.px(x + i, y + j, c); }
  hline(x, y, w, c = 1) { this.box(x, y, w, 1, c); }
  dots(x, y, w) { for (let i = 0; i < w; i += 2) this.px(x + i, y); }
  frame(x, y, w, h, c = 1) { this.box(x, y, w, 1, c); this.box(x, y + h - 1, w, 1, c); this.box(x, y, 1, h, c); this.box(x + w - 1, y, 1, h, c); }
  _in(i, j, w, h, r) {
    if (i < 0 || j < 0 || i >= w || j >= h) return false;
    const dx = i < r ? r - i - 0.5 : i >= w - r ? i - (w - r) + 0.5 : 0, dy = j < r ? r - j - 0.5 : j >= h - r ? j - (h - r) + 0.5 : 0;
    return !(dx > 0 && dy > 0 && dx * dx + dy * dy > r * r + 0.5);
  }
  rbox(x, y, w, h, r, c = 1) { for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) if (this._in(i, j, w, h, r)) this.px(x + i, y + j, c); }
  rframe(x, y, w, h, r, c = 1) {
    for (let j = 0; j < h; j++) for (let i = 0; i < w; i++) if (this._in(i, j, w, h, r) && !(this._in(i - 1, j, w, h, r) && this._in(i + 1, j, w, h, r) && this._in(i, j - 1, w, h, r) && this._in(i, j + 1, w, h, r))) this.px(x + i, y + j, c);
  }
  line(x0, y0, x1, y1, c = 1) {
    const dx = Math.abs(x1 - x0), dy = -Math.abs(y1 - y0), sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1; let e = dx + dy;
    for (;;) { this.px(x0, y0, c); if (x0 === x1 && y0 === y1) break; const e2 = 2 * e; if (e2 >= dy) { e += dy; x0 += sx; } if (e2 <= dx) { e += dx; y0 += sy; } }
  }
  circle(cx, cy, r, c = 1) {
    let x = r, y = 0, e = 1 - r;
    while (x >= y) {
      [[x, y], [y, x], [-y, x], [-x, y], [-x, -y], [-y, -x], [y, -x], [x, -y]].forEach(([a, b]) => this.px(cx + a, cy + b, c));
      y++; if (e < 0) e += 2 * y + 1; else { x--; e += 2 * (y - x) + 1; }
    }
  }
  disc(cx, cy, r, c = 1, fill) { for (let j = -r; j <= r; j++) for (let i = -r; i <= r; i++) if (i * i + j * j <= r * r + r * 0.6) { const X = cx + i, Y = cy + j; if (!fill || fill(X, Y)) this.px(X, Y, c); } }
  arc(cx, cy, r, a0, a1, c = 1) { for (let a = a0; a <= a1; a += 0.5 / r) this.px(Math.round(cx + r * Math.cos(a)), Math.round(cy + r * Math.sin(a)), c); }
  bmp(x, y, rows, c = 1, s = 1) { rows.forEach((row, j) => [...row].forEach((ch, i) => { if (ch === '#') this.box(x + i * s, y + j * s, s, s, c); })); }
  _parts(str) { return String(str).toUpperCase().split(/([…·])/).filter(p => p !== ''); }
  measure(str, o = {}) {
    let w = 0; const size = o.size || 1;
    this._parts(str).forEach(p => { w += SPECIAL[p] ? SPECIAL[p][0].length + 1 : raster(p, o.bold ? 1 : 0, size).adv; });
    return Math.max(0, w - size);
  }
  text(x, y, str, o = {}) {
    const c = o.c ?? 1, size = o.size || 1, b = o.bold ? 1 : 0;
    if (o.align === 'center') x = Math.round((W - this.measure(str, o)) / 2);
    if (o.align === 'right') x = x - this.measure(str, o);
    const top = tops[b + '' + size] ?? 0;
    this._parts(str).forEach(p => {
      if (SPECIAL[p]) { this.bmp(x, y, SPECIAL[p], c); x += SPECIAL[p][0].length + 1; return; }
      const r = raster(p, b, size);
      for (let k = 0; k < r.pts.length; k += 2) this.px(x + r.pts[k], y + r.pts[k + 1] - top, c);
      x += r.adv;
    });
    return x;
  }
  big(x, y, str, dimLead) {
    const lead = dimLead ? (str.replace(/^0+/, '').length ? str.length - str.replace(/^0+/, '').length : str.length - 1) : 0;
    [...str].forEach((ch, k) => {
      const dim = k < lead;
      DIG[ch].forEach((row, j) => [...row].forEach((p, i) => {
        if (p !== '#') return;
        for (let a = 0; a < 2; a++) for (let bb = 0; bb < 2; bb++) { const X = x + k * 13 + i * 2 + a, Y = y + j * 2 + bb; if (!dim || (X + Y) % 2 === 0) this.px(X, Y); }
      }));
    });
  }
}

export function paint(canvas, g, scale = 4) {
  const dpr = 2, s = scale * dpr;
  if (canvas.width !== W * s) { canvas.width = W * s; canvas.height = H * s; }
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#FF8A2A'; ctx.fillRect(0, 0, W * s, H * s);
  ctx.fillStyle = 'rgba(0,0,0,0.035)';
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) if (!g.b[y * W + x]) ctx.fillRect(x * s, y * s, s - 1, s - 1);
  ctx.fillStyle = 'rgba(12,8,4,0.92)';
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) if (g.b[y * W + x]) ctx.fillRect(x * s, y * s, s - 1, s - 1);
}

// ---------- widgets ----------
function conn(g, s, t) {
  if (s.conn === 'usb') g.bmp(118, 2, I.usb);
  else if (s.conn === 'ble') g.bmp(122, 0, I.bt);
  else if (t % 2) g.bmp(122, 0, I.bt);
}
function header(g, s, t, title, o = {}) { g.text(o.x ?? 2, 2, title, {bold: 1}); if (!o.noConn) conn(g, s, t); g.dots(0, 10, W); }
function bL(g, l) { const w = g.measure(l) + 13; g.rbox(0, 53, w, 14, 3); g.bmp(3, 56, I.aL, 0); g.text(9, 56, l, {c: 0}); }
function bR(g, l) { const w = g.measure(l) + 13, x = W - w; g.rbox(x, 53, w, 14, 3); g.text(x + 4, 56, l, {c: 0}); g.bmp(W - 6, 56, I.aR, 0); }
function bC(g, l) { const w = g.measure(l) + 15, x = Math.round((W - w) / 2); g.rbox(x, 53, w, 14, 3); g.bmp(x + 3, 56, I.ok, 0); g.text(x + 10, 56, l, {c: 0}); }
function spool(g, cx, cy, r) {
  g.disc(cx, cy, r, 0); g.circle(cx, cy, r);
  for (let rr = r - 3; rr > r * 0.45; rr -= 2) g.circle(cx, cy, rr);
  const hub = Math.round(r * 0.38); g.disc(cx, cy, hub, 0); g.circle(cx, cy, hub); g.disc(cx, cy, Math.max(1, Math.round(r * 0.14)));
}
function waves(g, cx, cy, r0, t, n = 3) { for (let i = 0; i < n; i++) if ((t % (n + 1)) > i) g.arc(cx, cy, r0 + i * 4, -0.6, 0.6); }
function swatch(g, cx, cy, r, lum) {
  const dark = 1 - lum;
  g.disc(cx, cy, r, 0); g.disc(cx, cy, r, 1, (x, y) => BAYER[y & 3][x & 3] / 16 < dark - 0.01); g.circle(cx, cy, r);
}
function list(g, items, sel, top, y0 = 12, rows = 4, iconsFn) {
  items.slice(top, top + rows).forEach((it, k) => {
    const i = top + k, y = y0 + k * 12, on = i === sel, c = on ? 0 : 1;
    if (on) g.rbox(0, y, items.length > rows ? 123 : 128, 11, 2);
    let x = 5;
    if (iconsFn) { const ic = iconsFn(it); if (ic) { g.bmp(4, y + 3 - (ic.length > 5 ? 1 : 0), ic, c); x = 13; } }
    g.text(x, y + 3, it.label, {c});
    if (it.value != null) {
      const vw = g.measure(it.value), vx = 117 - vw;
      g.text(vx, y + 3, it.value, {c});
      if (on && !it.fixed) { g.bmp(vx - 6, y + 3, I.aL, c); g.bmp(119, y + 3, I.aR, c); }
    }
  });
  if (items.length > rows) {
    for (let y = y0; y < H; y += 2) g.px(126, y);
    const h = Math.max(6, Math.round((H - y0) * rows / items.length)), y = y0 + Math.round((H - y0 - h) * (sel / (items.length - 1)));
    g.box(125, y, 3, h);
  }
}
const uidShort = u => u.slice(0, 4) + '...' + u.slice(-4);
const center = (g, y, s, o = {}) => g.text(0, y, s, {...o, align: 'center'});

export const SETTINGS = [
  {key: 'conn', label: 'Connection', opts: ['Auto', 'USB', 'Bluetooth']},
  {key: 'autosave', label: 'Auto-save new', opts: ['Off', 'On']},
  {key: 'after', label: 'After scan', opts: ['Show', 'Weigh']},
  {key: 'mode', label: 'Weigh as', opts: ['Gross', 'Net']},
  {key: 'feedback', label: 'Feedback', opts: ['Vibro+LED', 'LED', 'Off']},
  {key: 'sound', label: 'Sound', opts: ['Off', 'On']},
  {key: 'version', label: 'Version', opts: ['1.0.0'], fixed: true},
];
export function menuItems(kind) {
  if (kind === 'known') return [['Weigh', 'weigh'], ['Mark as new', 'new'], ['Mark as empty', 'empty'], ['Relink on host', 'link'], ['Tag details', 'details'], ['Delete spool', 'delete']];
  if (kind === 'unknown') return [['Add new', 'add'], ['Add and weigh', 'addw'], ['Link on host', 'link'], ['Tag details', 'details']];
  return [['Link on host', 'link'], ['Tag details', 'details']];
}
const ERR = {
  host: {title: 'No host reply', l: ['No reply in 10 s.', 'Open FliBuddy on', 'Mac or iPhone.']},
  bambuddy: {title: 'Not saved', l: ['Bambuddy is', 'unreachable from', 'the host.']},
  notSpool: {title: 'Not a spool tag', l: ['Tag has no spool', 'data. Try the hub', 'of the spool.']},
};

// ---------- screens ----------
export function frame(s, t = 1, now = 0) {
  const g = new G(), tag = s.tag || {};
  const S = {
    waiting() {
      g.text(2, 2, 'FliBuddy', {bold: 1}); g.text(126, 2, 'v1.0', {align: 'right'}); g.dots(0, 10, W);
      const usbOK = s.conn === 'usbNoApp', bleOff = s.settings.conn === 1;
      g.bmp(4, 16, I.usb); g.text(18, 16, usbOK ? 'Cable OK, no app' : 'No cable');
      if (usbOK) g.bmp(120, 15, I.check); 
      if (!bleOff && t % 2) g.bmp(6, 25, I.bt); else if (bleOff) g.bmp(6, 25, I.bt);
      g.text(18, 27, bleOff ? 'Bluetooth off' : 'Visible: Workshop');
      center(g, 40, usbOK ? 'Open FliBuddy on host' : 'Waiting for host' + '.'.repeat(t % 4));
      bR(g, 'Settings');
    },
    ready() {
      header(g, s, t, 'FliBuddy');
      if (s.last) {
        g.box(0, 12, W, 10); g.bmp(3, 14, I.check, 0); g.text(13, 15, s.last, {c: 0});
        spool(g, 17, 37, 11); waves(g, 17, 37, 14, t);
        g.text(40, 27, 'Next spool', {bold: 1}); g.text(40, 36, 'Hold tag to'); g.text(40, 44, 'the back');
      } else {
        spool(g, 17, 31, 13); waves(g, 17, 31, 16, t);
        g.text(42, 16, 'Ready', {bold: 1, size: 2}); g.text(42, 32, 'Hold spool tag'); g.text(42, 40, 'to the back');
      }
      bL(g, 'Recent'); bR(g, 'Settings');
    },
    reading() {
      header(g, s, t, 'Reading tag');
      spool(g, 64, 30, 11); waves(g, 64, 30, 14, t + 1);
      g.arc(64, 30, 14 + (t % 3) * 4, Math.PI - 0.6, Math.PI + 0.6);
      center(g, 46, 'Keep still');
    },
    result() {
      const kind = tag.kind;
      if (kind === 'blank') g.circle(6, 5, 4); else swatch(g, 6, 5, 4, tag.lum);
      header(g, s, t, kind === 'blank' ? 'Blank tag' : tag.material, {x: 14});
      g.text(2, 15, tag.color || (tag.rgba ? 'Color #' + tag.rgba.slice(0, 6) : tag.type));
      g.text(2, 24, 'Tag ' + uidShort(tag.uid));
      if (kind === 'known') g.text(2, 33, `${tag.remaining} g left of ${tag.label}`);
      else { const l = kind === 'unknown' ? 'Not in Bambuddy' : 'No spool data', w = g.measure(l) + 6; g.rbox(0, 31, w, 9, 2); g.text(3, 33, l, {c: 0}); }
      bL(g, 'Menu');
      if (kind === 'known') { bC(g, 'Weigh'); bR(g, 'New'); }
      else if (kind === 'unknown') { bC(g, 'Add'); bR(g, 'Link'); }
      else bC(g, 'Link');
    },
    menu() {
      header(g, s, t, tag.material || 'Blank tag');
      list(g, menuItems(tag.kind).map(([label]) => ({label})), s.sel, s.top);
    },
    details() {
      header(g, s, t, 'Tag details');
      const rows = [['Type', tag.type], ['UID', tag.uid.match(/.{2}/g).join(':')]];
      if (tag.rgba) rows.push(['Data', 'Bambu Lab'], ['RGBA', tag.rgba], ['Label', tag.label + ' g']); else rows.push(['Data', 'Empty NDEF']);
      rows.forEach(([k, v], i) => { g.text(2, 14 + i * 9, k); g.text(35, 14 + i * 9, v); });
    },
    confirm() {
      g.bmp(4, 3, I.warn); g.text(17, 4, 'Delete spool?', {bold: 1}); g.dots(0, 13, W);
      g.text(2, 18, `${tag.material} ${tag.color || ''}`); g.text(2, 27, 'Removes it from'); g.text(2, 36, 'Bambuddy for good.');
      bL(g, 'Cancel'); bR(g, 'Delete');
    },
    weight() {
      const w = s.w, v = +w.d.join(''), net = w.mode === 'gross' ? v - CORE : v;
      g.text(2, 2, 'Weight', {bold: 1});
      const segs = [['Net', 'net'], ['Gross', 'gross']];
      let x = 127 - segs.reduce((a, [l]) => a + g.measure(l) + 7, 0) + 1;
      const sx = x;
      segs.forEach(([l, m]) => { const ww = g.measure(l) + 6; if (w.mode === m) { g.rbox(x, 0, ww, 10, 2); g.text(x + 3, 2, l, {c: 0}); } else { g.rframe(x, 0, ww, 10, 2); g.text(x + 3, 2, l); } x += ww + 1; });
      if (w.cur === 0) { g.bmp(sx - 7, 0, I.aU); g.bmp(sx - 7, 6, I.aD); }
      const x0 = 27, str = w.d.join('');
      g.big(x0, 15, str, true); g.text(81, 20, 'g', {bold: 1, size: 2});
      if (w.cur > 0) g.box(x0 + (w.cur - 1) * 13, 31, 10, 2); 
      if (net < 0) { const l = 'Below core weight', ww = g.measure(l) + 6, xx = Math.round((W - ww) / 2); g.rbox(xx, 36, ww, 9, 2); g.text(xx + 3, 38, l, {c: 0}); }
      else center(g, 38, w.mode === 'gross' ? `Net ${net} g - core ${CORE}` : `Saves ${net} g left`);
      g.bmp(1, 56, I.aL); g.bmp(5, 56, I.aR); g.text(10, 56, 'Move');
      bC(g, 'Save');
      g.bmp(101, 56, I.aU); g.bmp(101, 59, I.aD); g.text(107, 56, 'Set');
    },
    saving() {
      header(g, s, t, s.saving || 'Saving');
      center(g, 20, s.saving === 'Deleting' ? tag.material : `${tag.material}${s.pendingNet != null && s.saving === 'Saving' ? ' - ' + s.pendingNet + ' g' : ''}`);
      g.rframe(14, 30, 100, 8, 2); const p = (t % 8); g.box(16 + p * 11, 32, 18, 4);
      center(g, 44, 'Waiting for Bambuddy');
    },
    saved() {
      for (let k = 0; k < 3; k++) { g.line(50, 18 + k, 58, 26 + k); g.line(58, 26 + k, 76, 8 + k); }
      center(g, 33, 'Saved', {bold: 1, size: 2});
      center(g, 48, `${tag.material} - ${tag.remaining} g left`);
    },
    toast() {
      const T = {
        new: ['Marked as new', `${tag.label} g left - full`, 'Undo', 'Weigh'],
        empty: ['Marked as empty', '0 g left - archived', 'Undo', null],
        deleted: ['Deleted', 'Tag is free to reuse', null, null],
        created: ['Added to Bambuddy', `Spool #${tag.id} - ${tag.label} g`, null, 'Weigh', 'Next'],
      }[s.toast];
      g.bmp(3, 2, I.check); g.text(13, 2, T[0], {bold: 1}); g.dots(0, 10, W);
      g.text(2, 16, `${tag.material} ${tag.color || ''}`); g.text(2, 25, T[1]);
      if (s.toast !== 'created') { const frac = s.frac ?? Math.max(0, 1 - (now - (s.t0 || now)) / 3000); g.box(0, 36, Math.round(W * frac), 2); g.text(2, 41, 'Next spool in 3 s'); }
      if (T[2]) bL(g, T[2]); if (T[3]) bC(g, T[3]); if (T[4]) bR(g, T[4]);
    },
    link() {
      header(g, s, t, 'Link tag');
      g.text(2, 15, 'Pick the spool in'); g.text(2, 24, 'FliBuddy on host');
      for (let k = 0; k < 3; k++) { const up = (t % 3) === k ? 2 : 0; g.box(54 + k * 8, 36 - up, 4, 4); }
      bL(g, 'Cancel');
    },
    error() {
      const e = s.err || ERR.host;
      header(g, s, t, e.title);
      g.bmp(3, 16, I.warn); e.l.forEach((l, i) => g.text(17, 16 + i * 9, l));
      bL(g, 'Back'); bR(g, 'Retry');
    },
    settings() {
      header(g, s, t, 'Settings');
      list(g, SETTINGS.map(it => ({label: it.label, value: it.opts[s.settings[it.key] || 0], fixed: it.fixed})), s.sel, s.top);
    },
    about() {
      g.bmp(6, 6, I.app, 1, 2);
      g.text(32, 9, 'FliBuddy', {bold: 1}); g.text(32, 18, 'for Bambuddy');
      g.dots(0, 29, W);
      g.text(2, 33, 'Version 1.0.0 build 42'); g.text(2, 42, 'Protocol 3 - fw 1.3.4');
      g.text(2, 51, s.conn === 'none' ? 'Host: not connected' : 'Host: MacBook - ' + (s.conn === 'ble' ? 'BLE' : 'USB'));
    },
    recent() {
      header(g, s, t, 'Recent');
      if (!s.recent.length) { center(g, 30, 'No scans yet'); return; }
      list(g, s.recent, s.sel, s.top, 12, 4, it => I[it.mark]);
    },
    apps() {
      g.bmp(2, 2, I.aL); g.text(0, 2, 'Tools', {bold: 1, align: 'center'}); g.bmp(123, 2, I.aR); g.dots(0, 10, W);
      const items = [['Clock', I.clock], ['Counter', I.count], ['Dice', I.dice], ['FliBuddy', I.app]];
      items.forEach(([l, ic], k) => { const y = 12 + k * 13, on = k === 3, c = on ? 0 : 1; if (on) g.rbox(0, y, 128, 12, 2); g.bmp(3, y + 1, ic, c); g.text(17, y + 4, l, {c}); });
    },
  };
  (S[s.screen] || S.ready)();
  return g;
}

// ---------- app ----------
export const TAGS = {
  known: {kind: 'known', material: 'PLA Basic', color: 'Bambu Green', lum: 0.45, uid: '91B4E7C2', type: 'MIFARE Classic 1K', rgba: '00AE42FF', remaining: 590, label: 1000, id: 14},
  known2: {kind: 'known', material: 'PETG HF', color: 'Black', lum: 0, uid: '5B21C0DE', type: 'MIFARE Classic 1K', rgba: '000000FF', remaining: 742, label: 1000, id: 12},
  unknown: {kind: 'unknown', material: 'PLA Silk+', color: null, lum: 0.75, uid: '8C33F05D', type: 'MIFARE Classic 1K', rgba: 'F4A925FF', label: 1000},
  blank: {kind: 'blank', material: null, uid: '04B7E2116A3C80', type: 'NTAG215'},
};
export const ERRS = ERR;
export function initState() {
  return {
    screen: 'waiting', conn: 'none', settings: {conn: 0, autosave: 0, after: 0, mode: 0, feedback: 0, sound: 0},
    sel: 0, top: 0, tag: null, w: null, last: null, toast: null, err: null, led: null, vib: false, back: 'ready', failNext: false,
    recent: [
      {label: 'PLA Matte 410 g', mark: 'check', tag: {kind: 'known', material: 'PLA Matte', color: 'Charcoal', lum: 0.2, uid: 'A1C3770E', type: 'MIFARE Classic 1K', rgba: '3B3B3BFF', remaining: 410, label: 1000, id: 21}},
      {label: 'PLA Basic 15 g', mark: 'check', tag: {kind: 'known', material: 'PLA Basic', color: 'Pumpkin Orange', lum: 0.6, uid: '7EF1AB04', type: 'MIFARE Classic 1K', rgba: 'FF9016FF', remaining: 15, label: 1000, id: 9}},
    ],
  };
}
const pad = v => String(Math.max(0, Math.min(9999, v))).padStart(4, '0').split('').map(Number);
const keepTop = (sel, top, rows = 4) => sel < top ? sel : sel >= top + rows ? sel - rows + 1 : top;

export class FZApp {
  constructor(onChange) { this.on = onChange; this.s = initState(); this.seq = 0; }
  set(p) { if (p.screen && p.screen !== this.s.screen) this.seq++; this.s = {...this.s, ...p}; this.on && this.on(); }
  after(ms, fn) { const q = this.seq; setTimeout(() => { if (q === this.seq) fn(); }, ms); }
  flash(led, ms = 600, vib = false) {
    const fb = this.s.settings.feedback; if (fb === 2) return;
    this.s = {...this.s, led, vib: vib && fb === 0}; this.on && this.on();
    clearTimeout(this.lt); this.lt = setTimeout(() => { this.s = {...this.s, led: null, vib: false}; this.on && this.on(); }, ms);
  }
  reset() { this.seq++; this.s = initState(); this.on && this.on(); }
  connect(c) {
    const host = c === 'usb' || c === 'ble', sc = this.s.screen;
    if (['settings', 'about'].includes(sc)) return this.set({conn: c, back: host ? 'ready' : 'waiting'});
    if (host && sc === 'waiting') { this.set({conn: c, screen: 'ready', last: null}); this.flash('blue', 500, true); }
    else if (!host) this.set({conn: c, screen: 'waiting'});
    else this.set({conn: c});
  }
  scan(kind) {
    if (!['ready', 'result', 'saved', 'toast'].includes(this.s.screen)) return false;
    const tag = kind === 'bad' ? null : {...TAGS[kind]};
    this.set({screen: 'reading', tag: tag || this.s.tag}); this.flash('blue', 400);
    this.after(700, () => {
      if (kind === 'bad') { this.set({screen: 'error', err: ERR.notSpool, errBack: 'ready'}); this.flash('red', 700, true); return; }
      this.flash('blue', 150, true);
      const st = this.s.settings;
      if (tag.kind === 'known' && st.after === 1) return this.openWeight();
      if (tag.kind === 'unknown' && st.autosave === 1) return this.create(false);
      this.set({screen: 'result'});
    });
    return true;
  }
  openWeight() {
    const t = this.s.tag, mode = this.s.settings.mode === 0 ? 'gross' : 'net', base = t.remaining ?? t.label;
    this.set({screen: 'weight', w: {d: pad(base + (mode === 'gross' ? CORE : 0)), cur: 2, mode, touched: false, base}});
  }
  create(weigh) {
    this.set({screen: 'saving', saving: 'Adding'});
    this.after(800, () => {
      this.s = {...this.s, tag: {...this.s.tag, kind: 'known', id: 31, remaining: this.s.tag.label}};
      this.flash('green', 600, true);
      if (weigh) this.openWeight(); else this.set({screen: 'toast', toast: 'created', t0: Date.now()});
    });
  }
  toast(kind) {
    this.set({screen: 'toast', toast: kind, t0: Date.now()}); this.flash('green', 600, true);
    const tg = this.s.tag, last = {new: `New ${tg.material} ${tg.label} g`, empty: `Empty ${tg.material}`, deleted: `Deleted ${tg.material}`}[kind];
    this.after(3000, () => this.set({screen: 'ready', last}));
  }
  link() { this.set({screen: 'link'}); this.flash('blue', 400); this.after(2600, () => { this.s = {...this.s, tag: {...TAGS.known2, uid: this.s.tag.uid}}; this.set({screen: 'result'}); this.flash('green', 500, true); }); }
  save() {
    const w = this.s.w, v = +w.d.join(''), net = w.mode === 'gross' ? v - CORE : v;
    if (net < 0) { this.flash('red', 400, true); return; }
    this.set({screen: 'saving', saving: 'Saving', pendingNet: net});
    this.after(900, () => {
      if (this.s.failNext) { this.s = {...this.s, failNext: false}; this.set({screen: 'error', err: ERR.bambuddy, errBack: 'weight'}); this.flash('red', 800, true); return; }
      const tag = {...this.s.tag, remaining: net}, label = `${tag.material} ${net} g`;
      this.set({screen: 'saved', tag, recent: [{label, mark: 'check', tag}, ...this.s.recent.filter(r => r.tag.uid !== tag.uid)].slice(0, 6)});
      this.flash('green', 900, true);
      this.after(1300, () => this.set({screen: 'ready', last: 'Saved ' + label}));
    });
  }
  key(k) {
    const s = this.s, sc = s.screen, kind = s.tag && s.tag.kind;
    const nav = (n, cb) => { if (k === 'up' || k === 'down') { const sel = (s.sel + (k === 'up' ? n - 1 : 1)) % n; this.set({sel, top: keepTop(sel, s.top)}); return true; } return false; };
    switch (sc) {
      case 'waiting': if (k === 'right') this.set({screen: 'settings', back: 'waiting', sel: 0, top: 0}); break;
      case 'ready':
        if (k === 'left') this.set({screen: 'recent', sel: 0, top: 0});
        if (k === 'right') this.set({screen: 'settings', back: 'ready', sel: 0, top: 0});
        break;
      case 'result':
        if (k === 'back') return this.set({screen: 'ready', last: null});
        if (k === 'left') return this.set({screen: 'menu', sel: 0, top: 0});
        if (kind === 'known') { if (k === 'ok') this.openWeight(); if (k === 'right') { this.s = {...s, undo: s.tag.remaining, tag: {...s.tag, remaining: s.tag.label}}; this.toast('new'); } }
        if (kind === 'unknown') { if (k === 'ok') this.create(false); if (k === 'right') this.link(); }
        if (kind === 'blank' && k === 'ok') this.link();
        break;
      case 'menu': {
        const items = menuItems(kind);
        if (nav(items.length)) break;
        if (k === 'back') return this.set({screen: 'result'});
        if (k !== 'ok') break;
        const a = items[s.sel][1];
        if (a === 'weigh') this.openWeight();
        if (a === 'new') { this.s = {...s, undo: s.tag.remaining, tag: {...s.tag, remaining: s.tag.label}}; this.toast('new'); }
        if (a === 'empty') { this.s = {...s, undo: s.tag.remaining, tag: {...s.tag, remaining: 0}}; this.toast('empty'); }
        if (a === 'link') this.link();
        if (a === 'details') this.set({screen: 'details'});
        if (a === 'delete') this.set({screen: 'confirm'});
        if (a === 'add') this.create(false);
        if (a === 'addw') this.create(true);
        break;
      }
      case 'details': if (k === 'back' || k === 'ok') this.set({screen: 'menu'}); break;
      case 'confirm':
        if (k === 'left' || k === 'back') this.set({screen: 'menu'});
        if (k === 'right') { this.set({screen: 'saving', saving: 'Deleting'}); this.after(700, () => this.toast('deleted')); }
        break;
      case 'weight': {
        const w = {...s.w, d: [...s.w.d]};
        if (k === 'back') return this.set({screen: 'result'});
        if (k === 'ok') return this.save();
        if (k === 'left') w.cur = w.cur === 0 ? 4 : w.cur - 1;
        if (k === 'right') w.cur = w.cur === 4 ? 0 : w.cur + 1;
        if (k === 'up' || k === 'down') {
          if (w.cur === 0) {
            w.mode = w.mode === 'gross' ? 'net' : 'gross';
            if (!w.touched) w.d = pad(w.base + (w.mode === 'gross' ? CORE : 0));
          } else { const i = w.cur - 1; w.d[i] = (w.d[i] + (k === 'up' ? 1 : 9)) % 10; w.touched = true; }
        }
        this.set({w});
        break;
      }
      case 'toast':
        if (k === 'back') return this.set({screen: 'ready', last: null});
        if (s.toast === 'created') { if (k === 'ok') this.openWeight(); if (k === 'right') this.set({screen: 'ready', last: `Added ${s.tag.material}`}); }
        else if (k === 'left' && (s.toast === 'new' || s.toast === 'empty')) this.set({screen: 'result', tag: {...s.tag, remaining: s.undo}});
        else if (k === 'ok' && s.toast === 'new') this.openWeight();
        break;
      case 'link': if (k === 'left' || k === 'back') this.set({screen: 'result'}); break;
      case 'error':
        if (k === 'left' || k === 'back') this.set({screen: s.errBack === 'weight' ? 'weight' : 'ready', last: null});
        if (k === 'right') { if (s.errBack === 'weight') this.save(); else this.set({screen: 'ready', last: null}); }
        break;
      case 'settings': {
        if (nav(SETTINGS.length)) break;
        const it = SETTINGS[s.sel];
        if (k === 'back') return this.set({screen: s.back, sel: 0, top: 0});
        if (k === 'ok' && it.key === 'version') return this.set({screen: 'about'});
        if ((k === 'left' || k === 'right') && !it.fixed) {
          const n = it.opts.length, v = ((s.settings[it.key] || 0) + (k === 'right' ? 1 : n - 1)) % n;
          this.set({settings: {...s.settings, [it.key]: v}});
        }
        break;
      }
      case 'about': if (k === 'back' || k === 'ok') this.set({screen: 'settings'}); break;
      case 'recent':
        if (s.recent.length && nav(s.recent.length)) break;
        if (k === 'back') this.set({screen: 'ready'});
        if (k === 'ok' && s.recent.length) this.set({screen: 'result', tag: {...s.recent[s.sel].tag}});
        break;
    }
  }
}

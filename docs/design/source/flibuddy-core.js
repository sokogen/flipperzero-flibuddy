// FliBuddy prototype core: session model, row view-model, theme vars. Shared by the platform DCs.
export const CORE = 242;
const BASE_L = {'--fb-bg':'#F2F2F7','--fb-card':'#FFFFFF','--fb-card2':'#F2F2F7','--fb-l1':'#000000','--fb-l2':'rgba(60,60,67,0.6)','--fb-l3':'rgba(60,60,67,0.3)','--fb-sep':'rgba(60,60,67,0.18)','--fb-fill':'rgba(118,118,128,0.12)','--fb-fill2':'rgba(120,120,128,0.2)','--fb-blue':'#007AFF','--fb-tint':'rgba(0,122,255,0.14)','--fb-red':'#FF3B30','--fb-green':'#34C759','--fb-orange':'#FF9500','--fb-gray':'#8E8E93','--fb-glass':'rgba(255,255,255,0.72)','--fb-glassb':'rgba(0,0,0,0.07)','--fb-thumb':'#FFFFFF','--fb-sel':'rgba(0,122,255,0.22)','--fb-bar':'#F2F2F4'};
const BASE_D = {'--fb-bg':'#000000','--fb-card':'#1C1C1E','--fb-card2':'#2C2C2E','--fb-l1':'#FFFFFF','--fb-l2':'rgba(235,235,245,0.6)','--fb-l3':'rgba(235,235,245,0.3)','--fb-sep':'rgba(84,84,88,0.6)','--fb-fill':'rgba(118,118,128,0.24)','--fb-fill2':'rgba(120,120,128,0.36)','--fb-blue':'#0A84FF','--fb-tint':'rgba(10,132,255,0.24)','--fb-red':'#FF453A','--fb-green':'#30D158','--fb-orange':'#FF9F0A','--fb-gray':'#8E8E93','--fb-glass':'rgba(44,44,48,0.72)','--fb-glassb':'rgba(255,255,255,0.12)','--fb-thumb':'#636366','--fb-sel':'rgba(10,132,255,0.35)','--fb-bar':'#2A2A2C'};
export const LIGHT = {...BASE_L,'--fb-win':'#FFFFFF','--fb-winbar':'#F6F6F7','--fb-field':'#FFFFFF','--fb-fieldb':'rgba(0,0,0,0.14)','--fb-rowsel':'rgba(0,0,0,0.05)','--fb-ring':'rgba(0,122,255,0.5)','--fb-dim':'rgba(0,0,0,0.2)','--fb-sheet':'#FFFFFF','--fb-key':'#FFFFFF','--fb-kb':'rgba(210,213,219,0.94)','--fb-side':'rgba(236,238,243,0.86)'};
export const DARK = {...BASE_D,'--fb-win':'#1E1E1E','--fb-winbar':'#262628','--fb-field':'rgba(255,255,255,0.06)','--fb-fieldb':'rgba(255,255,255,0.16)','--fb-rowsel':'rgba(255,255,255,0.06)','--fb-ring':'rgba(10,132,255,0.6)','--fb-dim':'rgba(0,0,0,0.5)','--fb-sheet':'#2A2A2C','--fb-key':'rgba(255,255,255,0.3)','--fb-kb':'rgba(44,44,46,0.94)','--fb-side':'rgba(40,40,44,0.86)'};
export const T = {green:'var(--fb-green)',red:'var(--fb-red)',orange:'var(--fb-orange)',blue:'var(--fb-blue)',gray:'var(--fb-gray)',l2:'var(--fb-l2)'};
const SYM = {'ph ph-scales':'scalemass','ph-fill ph-check-circle':'checkmark.circle.fill','ph ph-question':'questionmark.circle','ph-fill ph-plus-circle':'plus.circle.fill','ph-fill ph-warning':'exclamationmark.triangle.fill','ph ph-broadcast':'dot.radiowaves.left.and.right'};

export const FLIP = {
  none: {text:'No Flipper · searching', short:'No Flipper · searching', icon:'ph ph-broadcast', sym:'antenna.radiowaves.left.and.right.slash', tint:'gray', spin:1},
  usb: {text:'Flipper · USB', short:'Flipper on USB', icon:'ph ph-usb', sym:'cable.connector', tint:'green'},
  adv: {text:'Flipper nearby, not connected', short:'Flipper nearby', icon:'ph ph-broadcast', sym:'antenna.radiowaves.left.and.right', tint:'orange', act:'Connect'},
  ble: {text:'Flipper · Bluetooth', short:'Flipper connected', icon:'ph ph-broadcast', sym:'antenna.radiowaves.left.and.right', tint:'green'},
  nohello: {text:'Open FliBuddy on the Flipper', short:'Open FliBuddy on the Flipper', icon:'ph ph-app-window', sym:'app.dashed', tint:'orange'},
};
export const BAMBU = {
  unchecked: {text:'Bambuddy · not checked', short:'Bambuddy not checked', icon:'ph ph-hard-drives', sym:'server.rack', tint:'gray', act:'Check'},
  ready: {text:'Bambuddy ready', short:'Bambuddy ready', icon:'ph ph-hard-drives', sym:'server.rack', tint:'green'},
  unreachable: {text:'Bambuddy unreachable', short:'Bambuddy unreachable', icon:'ph ph-wifi-slash', sym:'wifi.exclamationmark', tint:'red', act:'Retry'},
  noperm: {text:'API key lacks inventory permission', short:'Key lacks inventory permission', icon:'ph ph-lock-key', sym:'lock.trianglebadge.exclamationmark', tint:'red', act:'Settings'},
  spoolman: {text:'Bambuddy is in Spoolman mode', short:'Bambuddy is in Spoolman mode', icon:'ph ph-prohibit', sym:'nosign', tint:'red', act:'Retry'},
  nocolors: {text:'Bambuddy ready · colour names unavailable', short:'Colour names unavailable', icon:'ph ph-palette', sym:'paintpalette', tint:'orange'},
};
export function statusVM(cfg) {
  const prep = x => ({...x, color: T[x.tint], spin: !!x.spin, hasAct: !!x.act});
  const f = prep(FLIP[cfg.flipper]), b = prep(BAMBU[cfg.bambuddy]);
  const fOK = cfg.flipper === 'ble' || cfg.flipper === 'usb', bOK = cfg.bambuddy === 'ready';
  const p = !fOK ? f : !bOK ? b : null;
  const banner = p ? {text: p.short, icon: p.icon, sym: p.sym, color: p.color, spin: p.spin, hasAct: p.hasAct, act: p.act, bad: p.tint === 'red'}
    : {text: 'Flipper connected · Bambuddy ready', icon: 'ph-fill ph-check-circle', sym: 'checkmark.circle.fill', color: T.green, spin: false, hasAct: false};
  const w = p || {icon: 'ph ph-broadcast', tint: 'green'};
  const WT = {green:'#30D158', red:'#FF453A', orange:'#FF9F0A', gray:'#8E8E93'};
  return {flip: f, bambu: b, banner, blocking: cfg.bambuddy === 'spoolman', noColors: cfg.bambuddy === 'nocolors', watch: {icon: w.icon, color: WT[w.tint], spin: !!w.spin, text: p ? p.short : 'Flipper connected'}};
}

// Bambuddy's spools (GET /inventory/spools?include_archived=true). upd: minutes since updated_at;
// core: grams of the empty spool, catalog: its catalog entry; lastScale: last gross weight; archived: the day it went.
export const INV = [
  {id:14, material:'PETG', subtype:'HF', colorName:'Black', rgba:'#000000', brand:'Bambu Lab', remaining:742, label:1000, tag:'5B21C0DE', note:'', upd:2880, core:242, catalog:'Bambu Lab - Reusable spool + refill', lastScale:984, archived:null},
  {id:21, material:'PLA', subtype:'Matte', colorName:'Charcoal', rgba:'#3B3B3B', brand:'Bambu Lab', remaining:410, label:1000, tag:'A1C3770E', note:'', upd:4320, core:242, catalog:'Bambu Lab - Reusable spool + refill', lastScale:652, archived:null},
  {id:27, material:'PETG', subtype:'', colorName:'Transparent Blue', rgba:'#2F6DB5', brand:'Sunlu', remaining:880, label:1000, tag:null, note:'drawer 3', upd:30240, core:165, catalog:'Sunlu - Plastic', lastScale:null, archived:null},
  {id:30, material:'PLA', subtype:'Silk', colorName:'Copper', rgba:'#B87333', brand:'eSun', remaining:655, label:1000, tag:null, note:'opened in September', upd:17280, core:172, catalog:null, lastScale:827, archived:null},
  {id:31, material:'TPU', subtype:'95A', colorName:'Red', rgba:'#D62D20', brand:'Overture', remaining:420, label:500, tag:null, note:'', upd:50400, core:150, catalog:null, lastScale:null, archived:null},
  {id:33, material:'ASA', subtype:'', colorName:'White', rgba:'#F4F4F4', brand:'Polymaker', remaining:990, label:1000, tag:'C07A4411', note:'enclosure parts', upd:86400, core:140, catalog:'Polymaker - Cardboard', lastScale:1130, archived:null},
  {id:12, material:'PLA', subtype:'Basic', colorName:'Pumpkin Orange', rgba:'#FF9016', brand:'Bambu Lab', remaining:15, label:1000, tag:'7EF1AB04', note:'', upd:0, core:242, catalog:'Bambu Lab - Reusable spool + refill', lastScale:257, archived:null},
  {id:6, material:'PLA', subtype:'Matte', colorName:'Ivory White', rgba:'#FFFFFF', brand:'Bambu Lab', remaining:0, label:1000, tag:null, note:'', upd:25920, core:242, catalog:'Bambu Lab - Reusable spool + refill', lastScale:242, archived:'Oct 18, 2026'},
  {id:5, material:'ABS', subtype:'', colorName:'Black', rgba:'#000000', brand:'Bambu Lab', remaining:0, label:1000, tag:'3F0A9C12', note:'', upd:51840, core:242, catalog:'Bambu Lab - Reusable spool + refill', lastScale:null, archived:'Sep 30, 2026'},
];
const KNOWN = [
  {uid:'5B21C0DE', rgba:'#000000', material:'PETG', subtype:'HF', colorName:'Black', remaining:742, label:1000},
  {uid:'A1C3770E', rgba:'#3B3B3B', material:'PLA', subtype:'Matte', colorName:'Charcoal', remaining:410, label:1000},
  {uid:'E61F09B3', rgba:'#FFFFFF', material:'PLA', subtype:'Basic', colorName:'Jade White', remaining:860, label:1000},
];
const UNKNOWN = [
  {uid:'D40E19A7', rgba:'#FFFFFF', material:'PETG', subtype:'HF', label:1000},
  {uid:'8C33F05D', rgba:'#F4A925', material:'PLA', subtype:'Silk+', label:1000},
];
const BLANK = [{uid:'04B7E2116A3C80'}, {uid:'04D90C7A2B1F80'}];

export function seed() {
  return [
    {id:'r3', uid:'91B4E7C2', rgba:'#00AE42', material:'PLA', subtype:'Basic', colorName:'Bambu Green', known:true, remaining:590, label:1000, base:590, status:'enter', mode:'gross', sel:true},
    {id:'r4', uid:'04A2C93B1F5E80', status:'unknownNoMat', mode:'gross'},
    {id:'r2', uid:'3C9D20F1', rgba:'#A4DBE8', material:'PLA', subtype:'Pure', label:1000, status:'unknown', mode:'gross'},
    {id:'r1', uid:'7EF1AB04', rgba:'#FF9016', material:'PLA', subtype:'Basic', colorName:'Pumpkin Orange', known:true, remaining:15, label:1000, base:15, status:'saved', savedLeft:15, savedBy:'host', mode:'gross'},
  ];
}
export const suggestion = r => r.base == null ? null : r.base + (r.mode === 'gross' ? CORE : 0);
export const rawValue = r => r.value != null ? r.value : (suggestion(r) == null ? '' : String(suggestion(r)));
export const netOf = r => { const n = parseInt(rawValue(r), 10); return isNaN(n) ? null : r.mode === 'gross' ? n - CORE : n; };

export function vm(r, o = {}) {
  const title = r.material ? r.material + (r.subtype ? ' ' + r.subtype : '') : 'NTAG 7-byte UID ' + r.uid.slice(0, 4) + '…';
  const colorName = o.noColors ? null : r.colorName;
  const rem = r.known ? r.remaining + ' g left of ' + r.label : (r.material && r.label ? 'label ' + r.label + ' g' : '');
  const sub = [colorName, rem].filter(Boolean).join(' · ');
  const by = r.savedBy === 'flipper' ? 'Flipper' : 'host';
  const M = {
    lookup: ['Looking up', '', 'l2', 1], enter: ['Enter weight', 'ph ph-scales', 'blue'], saving: ['Saving…', '', 'l2', 1],
    saved: ['Saved ' + r.savedLeft + ' g left · by ' + by, 'ph-fill ph-check-circle', 'green'],
    timeout: ['Saved ' + r.savedLeft + ' g left · by host', 'ph-fill ph-check-circle', 'green'],
    unknown: ['Not in Bambuddy', 'ph ph-question', 'l2'], unknownNoMat: ['Not in Bambuddy; tag has no material', 'ph ph-question', 'l2'],
    creating: ['Creating in Bambuddy…', '', 'l2', 1],
    created: ['Added to Bambuddy', 'ph-fill ph-plus-circle', 'green'], error: ['Error: ' + r.error, 'ph-fill ph-warning', 'red'],
    flipperCreate: ['Flipper asks to create it here', 'ph ph-broadcast', 'blue'], flipperLink: ['Flipper asks to link it here', 'ph ph-broadcast', 'blue'],
  }[r.status];
  const entry = ['enter', 'saving', 'error'].includes(r.status);
  const raw = rawValue(r);
  const n = parseInt(raw, 10);
  const net = netOf(r);
  const bad = net != null && net < 0;
  const readout = net == null ? 'Type the scale reading' : bad ? 'Below the core weight (' + CORE + ' g)' : r.mode === 'gross' ? 'Saves ' + net + ' g left · ' + n + ' − ' + CORE + ' g core' : 'Saves ' + net + ' g left';
  const unknown = ['unknown', 'unknownNoMat', 'flipperCreate', 'flipperLink'].includes(r.status);
  let acts = [];
  if (unknown) {
    const lf = r.status === 'flipperLink';
    const nw = {key: 'new', label: r.material ? 'New' : 'New…', p: !lf}, lk = {key: 'link', label: 'Link to existing…', p: lf};
    acts = (lf ? [lk, nw] : [nw, lk]).map(a => ({...a, bg: a.p ? T.blue : 'var(--fb-fill)', fg: a.p ? '#fff' : T.blue}));
  }
  const thumb = 'var(--fb-thumb)', sh = '0 1px 3px rgba(0,0,0,.14)';
  const saving = r.status === 'saving';
  return {
    id: r.id, status: r.status, title, sub, hasSub: !!sub, colorName, hasColor: !!colorName, rem, hasRem: !!rem,
    remShort: r.known ? r.remaining + ' g left' : (r.material && r.label ? 'label ' + r.label + ' g' : 'Unknown tag'),
    uid: r.uid, swatch: r.rgba, hasSwatch: !!r.rgba, noSwatch: !r.rgba,
    statusText: M[0], icon: M[1], hasIcon: !!M[1], iconColor: T[M[2]], spin: !!M[3], sym: SYM[M[1]] || 'ProgressView',
    statusColor: r.status === 'error' ? T.red : T.l2, isError: r.status === 'error',
    note: r.status === 'timeout' ? 'Flipper timed out after 10 s and showed an error; the save went through.' : '', hasNote: r.status === 'timeout',
    entry, raw, valueText: raw || '0', empty: !raw, sel: !!r.sel, selBg: r.sel ? 'var(--fb-sel)' : 'transparent',
    mode: r.mode, isGross: r.mode === 'gross', isNet: r.mode === 'net', modeWord: r.mode === 'gross' ? 'gross' : 'net',
    netBg: r.mode === 'net' ? thumb : 'transparent', netSh: r.mode === 'net' ? sh : 'none',
    grossBg: r.mode === 'gross' ? thumb : 'transparent', grossSh: r.mode === 'gross' ? sh : 'none',
    net, readout, bad, readoutColor: bad ? T.red : T.l2, canSave: !bad && net != null && !saving,
    saveOp: saving || bad || net == null ? 0.45 : 1, saveLabel: saving ? 'Saving…' : 'Save', saving,
    netBig: net == null || bad ? '—' : String(net),
    acts, hasActs: acts.length > 0, unknown, hasMaterial: !!r.material,
    reopenable: ['saved', 'timeout', 'created'].includes(r.status),
    savedLike: r.status === 'saved' || r.status === 'timeout' || r.status === 'created',
  };
}

export class Session {
  constructor(onChange) {
    this.on = onChange; this.n = 10; this.k = {known: 0, unknown: 0, blank: 0};
    this.cfg = {failNext: false, timeoutNext: false, flipper: 'ble', bambuddy: 'ready'};
    this.rows = seed(); this.inv = INV.map(s => ({...s}));
    this.onFocus = null; this.onHaptic = null;
  }
  emit() { this.on && this.on(); }
  find(id) { return this.rows.find(r => r.id === id); }
  patch(id, p) { this.rows = this.rows.map(r => r.id === id ? {...r, ...p} : r); this.emit(); }
  setCfg(p) { this.cfg = {...this.cfg, ...p}; this.emit(); }
  setValue(id, v) { this.patch(id, {value: String(v).replace(/\D/g, '').slice(0, 5), touched: true, sel: false}); }
  select(id, on = true) { this.patch(id, {sel: on}); }
  key(id, k) {
    const r = this.find(id); if (!r) return;
    let v = r.sel ? '' : rawValue(r);
    if (k === 'del') v = v.slice(0, -1); else if (v.length < 5) v = (v === '0' ? '' : v) + k;
    this.patch(id, {value: v, touched: true, sel: false});
  }
  nudge(id, d) {
    const r = this.find(id); if (!r) return;
    const n = parseInt(rawValue(r), 10) || 0;
    this.patch(id, {value: String(Math.max(0, Math.min(9999, n + d))), touched: true, sel: false});
  }
  setMode(id, m) {
    const r = this.find(id); if (!r || r.mode === m) return;
    this.patch(id, r.touched ? {mode: m} : {mode: m, value: null});
  }
  save(id) {
    const r = this.find(id); if (!r) return;
    const net = netOf(r); if (net == null || net < 0 || r.status === 'saving') return;
    const prev = r.status;
    this.patch(id, {status: 'saving', sel: false, prev});
    setTimeout(() => {
      if (this.cfg.failNext) {
        this.cfg.failNext = false;
        this.patch(id, {status: 'error', error: this.cfg.bambuddy === 'noperm' ? 'API key lacks inventory permission' : 'Bambuddy unreachable'});
        this.onHaptic && this.onHaptic('failure', id);
        return;
      }
      const to = this.cfg.timeoutNext; this.cfg.timeoutNext = false;
      this.patch(id, {status: to ? 'timeout' : 'saved', savedLeft: net, savedBy: 'host', remaining: net, known: true, base: net, value: null, touched: false, mode: r.mode});
      this.onHaptic && this.onHaptic('success', id);
      this.focusNext();
    }, 700);
  }
  focusNext() { const nx = this.rows.find(r => r.status === 'enter'); this.onFocus && this.onFocus(nx ? nx.id : null); }
  reopen(id) { const r = this.find(id); if (r && ['saved', 'timeout', 'created'].includes(r.status)) { this.patch(id, {status: 'enter', sel: true}); this.onFocus && this.onFocus(id); } }
  scan(kind) {
    const pool = kind === 'known' ? KNOWN : kind === 'unknown' ? UNKNOWN : BLANK;
    const t = pool[this.k[kind]++ % pool.length];
    const id = 'r' + (++this.n);
    this.rows = [{...t, id, status: 'lookup', mode: 'gross', colorName: null, remaining: null, known: false}, ...this.rows.filter(r => r.uid !== t.uid)];
    this.emit();
    setTimeout(() => {
      if (kind === 'known') { this.patch(id, {status: 'enter', known: true, colorName: t.colorName, remaining: t.remaining, base: t.remaining, sel: true}); this.onFocus && this.onFocus(id); }
      else this.patch(id, {status: t.material ? 'unknown' : 'unknownNoMat'});
    }, 900);
    return id;
  }
  flipperAsk(kind) {
    const id = this.scan(kind === 'create' ? 'unknown' : 'blank');
    setTimeout(() => this.patch(id, {status: kind === 'create' ? 'flipperCreate' : 'flipperLink'}), 950);
  }
  flipperSave() {
    const r = this.rows.find(x => ['enter', 'created', 'error'].includes(x.status)); if (!r) return;
    const net = netOf(r); if (net == null || net < 0) return;
    this.patch(r.id, {status: 'saved', savedLeft: net, savedBy: 'flipper', remaining: net, known: true, base: net, value: null, touched: false, sel: false});
    this.focusNext();
  }
  create(id, form) {
    const r = this.find(id); if (!r) return;
    const f = form || {};
    this.patch(id, {status: 'creating'});
    setTimeout(() => {
      const label = f.label != null ? f.label : (r.label || 1000);
      this.patch(id, {status: 'created', known: true, material: f.material || r.material, subtype: f.subtype != null ? f.subtype : r.subtype,
        colorName: f.colorName || null, rgba: r.rgba || f.rgba || null, brand: f.brand, label, remaining: label, base: label, value: null, touched: false, sel: false, mode: 'gross'});
    }, 800);
  }
  link(id, spoolId) {
    const r = this.find(id), s = this.inv.find(x => x.id === spoolId); if (!r || !s) return;
    this.inv = this.inv.map(x => x.id === spoolId ? {...x, tag: r.uid} : x);
    this.patch(id, {status: 'lookup'});
    setTimeout(() => {
      this.patch(id, {status: 'enter', known: true, material: s.material, subtype: s.subtype, colorName: s.colorName, rgba: r.rgba || s.rgba, remaining: s.remaining, label: s.label, base: s.remaining, value: null, touched: false, sel: true, mode: 'gross'});
      this.onFocus && this.onFocus(id);
    }, 600);
  }
  filterInv(q) {
    const s = (q || '').trim().toLowerCase();
    return this.inv.filter(x => !x.archived && matches(x, s));
  }
  clear() { this.rows = []; this.emit(); }
  reset() { this.rows = seed(); this.inv = INV.map(s => ({...s})); this.k = {known: 0, unknown: 0, blank: 0}; this.cfg = {...this.cfg, failNext: false, timeoutNext: false}; this.emit(); }
}

export const invVM = (s, uid) => ({
  id: s.id, title: s.material + (s.subtype ? ' ' + s.subtype : ''), swatch: s.rgba,
  sub: [s.colorName, s.brand, s.remaining + ' g left'].filter(Boolean).join(' · '),
  note: s.note, hasNote: !!s.note, tag: s.tag, tagged: !!s.tag && s.tag !== uid, tagText: s.tag ? 'Tag ' + s.tag : '',
});
export const MATERIALS = ['PLA', 'PETG', 'ABS', 'ASA', 'TPU', 'PA', 'PC', 'PVA'];

// The Link picker's filter, also the Spools search: every word in material, subtype, colour, brand or note.
const matches = (x, q) => (q || '').trim().toLowerCase().split(/\s+/).filter(Boolean)
  .every(w => [x.material, x.subtype, x.colorName, x.brand, x.note].join(' ').toLowerCase().includes(w));

// "updated 3 d ago": minutes, hours, days, months, years; under a minute "just now".
export const ago = (m, full) => {
  if (m < 1) return 'just now';
  const [n, u, w] = m < 60 ? [m, 'min', 'minute'] : m < 1440 ? [Math.floor(m / 60), 'h', 'hour'] : m < 43200 ? [Math.floor(m / 1440), 'd', 'day']
    : m < 525600 ? [Math.floor(m / 43200), 'mo', 'month'] : [Math.floor(m / 525600), 'y', 'year'];
  return full ? n + ' ' + w + (n === 1 ? '' : 's') + ' ago' : n + ' ' + u + ' ago';
};
export const SPOOL_SCOPES = [['active', 'Active'], ['archived', 'Archived'], ['all', 'All']];
export const SPOOL_SORTS = [['updated', 'Recently updated'], ['left', 'Least left'], ['material', 'Material'], ['colour', 'Colour']];
const title = s => s.material + (s.subtype ? ' ' + s.subtype : '');
const isLow = s => !s.archived && s.label > 0 && s.remaining * 100 < s.label * 15;

// What the Spools tab shows instead of the list; the feed's Spoolman screen is shared.
export const SPOOL_STATES = {
  loading: {spin: true, icon: '', sym: 'ProgressView', color: 'var(--fb-l2)', title: 'Loading spools…', desc: '', act: ''},
  noserver: {icon: 'ph ph-hard-drives', sym: 'server.rack', color: 'var(--fb-l2)', title: 'Connect Bambuddy', desc: 'Scan the API-key QR code in Bambuddy, or type its address.', act: 'Open Settings'},
  down: {icon: 'ph ph-wifi-slash', sym: 'wifi.exclamationmark', color: 'var(--fb-red)', title: 'Can’t reach Bambuddy', desc: 'Check that Bambuddy is running and on the same network.', act: 'Retry'},
  noperm: {icon: 'ph ph-lock-key', sym: 'lock.trianglebadge.exclamationmark', color: 'var(--fb-red)', title: 'Can’t read the inventory', desc: 'The API key needs the inventory:read permission. Add it to the key in Bambuddy.', act: 'Open Settings'},
  rejected: {icon: 'ph ph-lock-key', sym: 'lock.trianglebadge.exclamationmark', color: 'var(--fb-red)', title: 'Bambuddy rejected the API key', desc: 'Check the key in Settings, or scan the QR code of a new one.', act: 'Open Settings'},
  spoolman: {icon: 'ph ph-prohibit', sym: 'nosign', color: 'var(--fb-red)', title: 'Bambuddy is in Spoolman mode', desc: 'FliBuddy works with Bambuddy’s own inventory. Switch it back from Spoolman in Bambuddy’s settings, then retry.', act: 'Retry'},
};
export const spoolState = k => {
  const x = SPOOL_STATES[k];
  return x && {...x, spin: !!x.spin, hasIcon: !x.spin, hasAct: !!x.act, hasDesc: !!x.desc};
};

// One row of the Spools list.
export const spoolRowVM = s => {
  const sub = [s.colorName, s.brand].filter(Boolean).join(' · ');
  const line = s.remaining + ' g left of ' + s.label + ' · updated ' + ago(s.upd);
  const low = isLow(s);
  const aria = [title(s), s.colorName, s.brand, s.remaining + ' grams left of ' + s.label, low ? 'low' : '', s.archived ? 'archived' : '',
    s.tag ? 'tag linked' : '', 'updated ' + ago(s.upd, true)].filter(Boolean).join(', ') + '.';
  return {id: s.id, title: title(s), swatch: s.rgba, sub, hasSub: !!sub, line, tagged: !!s.tag, low, archived: !!s.archived, aria};
};

// The list for a scope, search text, material filter and sort; `empty` says what shows instead of rows.
export function spoolsVM(inv, o = {}) {
  const scope = o.scope || 'active', sort = o.sort || 'updated';
  const inScope = inv.filter(s => scope === 'all' || (scope === 'archived') === !!s.archived);
  const shown = inScope.filter(s => (!o.material || s.material === o.material) && matches(s, o.q));
  const cmp = (a, b) => String(a || '\uffff').localeCompare(String(b || '\uffff'));
  const by = {updated: (a, b) => a.upd - b.upd, left: (a, b) => a.remaining - b.remaining || cmp(title(a), title(b)),
    material: (a, b) => cmp(title(a), title(b)) || cmp(a.colorName, b.colorName), colour: (a, b) => cmp(a.colorName, b.colorName) || cmp(title(a), title(b))}[sort];
  const q = (o.q || '').trim();
  const empty = inv.length === 0 ? {title: 'No spools in Bambuddy', desc: 'Spools added in Bambuddy, or with New in the feed, show here.', sym: 'shippingbox'}
    : shown.length > 0 ? null
    : q ? {title: 'No spools match “' + q + '”', desc: 'Search looks at material, colour, brand and note.', sym: 'magnifyingglass'}
    : o.material ? {title: 'No ' + o.material + ' spools', desc: 'Choose All materials to see every spool.', sym: 'line.3.horizontal.decrease.circle'}
    : {title: scope === 'archived' ? 'No archived spools' : 'No active spools', desc: 'Bambuddy has spools in the other scope.', sym: 'shippingbox'};
  return {
    rows: shown.slice().sort(by).map(spoolRowVM), empty, hasEmpty: !!empty, hasRows: !empty,
    active: inv.filter(s => !s.archived).length,
    materials: [...new Set(inv.map(s => s.material))].sort(),
  };
}

// The read-only detail; `rows`: the feed, for today's line.
export function spoolDetailVM(s, rows = []) {
  const r = rows.find(x => x.known && x.uid === s.tag);
  const today = r ? vm(r) : null;
  const pct = s.label > 0 ? Math.round(s.remaining * 100 / s.label) : 0;
  const facts = [
    ['Material', s.material], ['Subtype', s.subtype], ['Brand', s.brand], ['Label weight', s.label + ' g'],
    ['Empty spool', (s.catalog ? s.catalog + ' · ' : '') + s.core + ' g'], ['Last scale weight', s.lastScale != null ? s.lastScale + ' g' : 'Never weighed'],
    ['Tag', s.tag || 'No tag', !!s.tag], ['Note', s.note], ['Spool #', String(s.id)], ['Archived on', s.archived],
  ].filter(f => f[1]).map(([k, v, mono]) => ({k, v, mono: !!mono}));
  return {
    ...spoolRowVM(s), colorName: s.colorName || '', brand: s.brand || '', sub: [s.colorName, s.brand].filter(Boolean).join(' · '),
    gauge: s.remaining + ' g left of ' + s.label + ' g', pct: pct + '%', pctW: Math.min(100, pct) + '%', gaugeColor: isLow(s) ? 'var(--fb-orange)' : 'var(--fb-blue)',
    facts, today: today ? today.statusText : '', todayIcon: today ? today.icon : '', todayColor: today ? today.iconColor : '', hasToday: !!today,
    url: 'bambuddy.local:8000/inventory?spool=' + s.id,
  };
}

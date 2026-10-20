'use strict';

/* ---------------------------------------------------------------------------
   The window is a thin client over the handlers in server.go. Everything it
   can do is one of build.sh's verbs, so there is no build logic here: it picks
   a verb, ticks flags, and renders what the child prints.

   Two panes talk to the phone or edit files — config.env and adb — and both go
   through the server, which owns the parsing and the process running. Nothing
   in this file writes to the disk.
   --------------------------------------------------------------------------- */

const $ = (id) => document.getElementById(id);

function el(tag, cls, text) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
}

const FLAG_HELP = {
  '--with-vendor-hals': 'include src/vendor/ in the module',
  '--allow-unknown-resources': 'build even if a resource is missing',
  '--force': 're-pick the resource dictionary',
  '--all': 'also remove config and device files',
};

let state = null;
let selectedVerb = 'build';
let checkedFlags = new Set();
let running = false;
let lastSeq = 0;
let adbSeq = 0;
let currentDoc = null;
let statusTimer = null;
let refreshInFlight = false;

// config.env: the form keeps only what the user changed, so a poll that lands
// mid-edit cannot repaint the row they are typing in.
let cfgEdits = new Map();
let cfgRaw = false;
let cfgRawDirty = false;

// --------------------------------------------------------------------- api --
async function api(path, opts = {}) {
  const init = { method: opts.method || 'GET', cache: 'no-store' };
  if (opts.body !== undefined) {
    init.headers = { 'Content-Type': 'application/json' };
    init.body = JSON.stringify(opts.body);
  }
  const res = await fetch(path, init);
  const text = await res.text();
  let data = null;
  if (text) {
    try { data = JSON.parse(text); } catch (_) { data = null; }
  }
  if (!res.ok) {
    const err = new Error((data && data.error) || text || res.statusText);
    // Some failures come with useful detail (the update clash list), so keep
    // the whole payload on the error instead of only the message.
    err.data = data;
    err.status = res.status;
    throw err;
  }
  return data;
}

function status(message, ms = 3500) {
  $('run-status').textContent = message;
  if (statusTimer) clearTimeout(statusTimer);
  if (ms) statusTimer = setTimeout(() => { $('run-status').textContent = ''; }, ms);
}

// ------------------------------------------------------------------- state --
async function refreshState(forceRender = false) {
  if (refreshInFlight) return;
  refreshInFlight = true;
  try {
    state = await api('api/state');
  } catch (err) {
    $('sub').textContent = 'cannot reach the app server: ' + err.message;
    refreshInFlight = false;
    return;
  }
  refreshInFlight = false;

  renderHeader();
  renderVerbs();
  renderFlags();
  renderOut();
  renderConfig(forceRender);
  renderAdb();
  renderDocsNav();
  renderRunState();
}

function renderHeader() {
  const clone = $('chip-clone');
  const bash = $('chip-bash');
  const upd = state.update || {};

  clone.dataset.tone = state.cloneValid ? 'ok' : 'bad';
  clone.querySelector('.label').textContent = state.cloneValid
    ? baseName(state.clone)
    : 'no clone — click to set';
  clone.title = state.clone || 'no clone selected';

  bash.dataset.tone = state.bashValid ? 'ok' : 'bad';
  bash.querySelector('.label').textContent = state.bashValid
    ? baseName(state.bash)
    : 'no bash — click to set';
  bash.title = state.bash || 'bash not found';

  const branch = $('chip-branch');
  if (state.branch) {
    branch.textContent = state.commit ? `${state.branch} @ ${state.commit}` : state.branch;
    branch.dataset.tone = state.dirty ? 'warn' : 'ok';
    branch.title = state.dirty
      ? 'you have local edits — an update will list them before touching anything'
      : 'clean working tree';
  } else {
    branch.textContent = 'not a git clone';
    branch.dataset.tone = 'warn';
  }

  // The chip is about a newer release, not about the user's own edits: this is
  // a launcher for build.sh, so "is there a new version" is the question that
  // matters, and it is the only one worth a permanent badge.
  const chip = $('chip-update');
  chip.hidden = !upd.available;
  if (upd.available) {
    chip.querySelector('.label').textContent =
      `${upd.behind} new commit${upd.behind === 1 ? '' : 's'}`;
    chip.title = `${upd.upstream} is ${upd.behind} commit(s) ahead — click to see what it changes`;
    chip.dataset.tone = 'warn';
  }

  if (state.bashValid && state.cloneValid) {
    if (upd.available) {
      $('sub').textContent = `update available: ${upd.behind} commit${upd.behind === 1 ? '' : 's'} behind ${upd.upstream}`;
    } else if (upd.checked) {
      $('sub').textContent = 'up to date';
    } else if (upd.error && state.branch) {
      $('sub').textContent = 'could not check for updates';
    } else {
      $('sub').textContent = 'ready';
    }
  }
}

function baseName(p) {
  if (!p) return '';
  const parts = p.split(/[\\/]/).filter(Boolean);
  return parts[parts.length - 1] || p;
}

function currentVerb() {
  if (!state) return null;
  return state.verbs.find((v) => v.name === selectedVerb) || state.verbs[0] || null;
}

function renderVerbs() {
  const box = $('verbs');
  box.textContent = '';
  for (const v of state.verbs) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'verb' + (v.name === selectedVerb ? ' is-active' : '');
    const h = document.createElement('h3');
    h.textContent = v.label;
    const p = document.createElement('p');
    p.textContent = v.hint;
    b.append(h, p);
    b.addEventListener('click', () => {
      selectedVerb = v.name;
      renderVerbs();
      renderFlags();
      renderRunState();
    });
    box.appendChild(b);
  }
}

function renderFlags() {
  const v = currentVerb();
  const box = $('flags');
  box.textContent = '';

  if (!v || !v.flags || v.flags.length === 0) {
    box.appendChild(el('span', 'muted', 'none for this command'));
    return;
  }

  for (const flag of v.flags) {
    const label = el('label', 'flag');
    label.title = FLAG_HELP[flag] || '';

    const input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = checkedFlags.has(flag);
    input.addEventListener('change', () => {
      if (input.checked) checkedFlags.add(flag);
      else checkedFlags.delete(flag);
      renderRunState();
    });

    label.append(input, el('span', 'flag-name', flag));
    box.appendChild(label);
  }
}

function renderRunState() {
  const v = currentVerb();
  const ready = state && state.cloneValid && state.bashValid;
  $('run').disabled = !ready || running || !v;
  $('stop').disabled = !running;
  $('run').textContent = v ? `Run ${v.label.toLowerCase()}` : 'Run';

  const flags = v ? [...checkedFlags].filter((f) => v.flags && v.flags.includes(f)) : [];
  const cmd = v ? `build.sh ${v.arg}${flags.length ? ' ' + flags.join(' ') : ''} -y` : '';
  $('run').title = v ? `runs: bash --noprofile --norc ./${cmd}` : '';

  for (const input of $('flags').querySelectorAll('input')) input.disabled = running;
  for (const b of $('verbs').querySelectorAll('.verb')) b.disabled = running;
  $('adb-run').disabled = running || !adbReady();
  $('adb-stop').disabled = !running;
}

// -------------------------------------------------------------- last build --
// The list of what out/ holds is only interesting right after a build, so it
// sits folded at the bottom of the pane. renderOut keeps the summary line
// current either way, and a finished build opens it once.
function renderOut() {
  const box = $('out');
  const summary = $('out-summary');
  box.textContent = '';

  const files = state.out || [];
  if (files.length === 0) {
    summary.textContent = state.cloneValid ? 'nothing in out/ yet' : 'no clone selected';
    box.appendChild(el('span', 'muted', summary.textContent));
    return;
  }

  let newest = 0;
  let biggest = 0;
  for (const f of files) {
    if (f.mod > newest) newest = f.mod;
    if (f.size > biggest) biggest = f.size;
  }
  const when = ago(newest);
  summary.textContent = `${when} · ${files.length} file${files.length === 1 ? '' : 's'}`;
  summary.title = 'built ' + new Date(newest * 1000).toLocaleString();

  for (const f of files) {
    const row = el('div', 'out-item');
    row.append(el('span', null, f.name), el('span', null, `${bytes(f.size)} · ${ago(f.mod)}`));
    box.appendChild(row);
  }
}

function bytes(n) {
  if (n > 1 << 20) return (n / (1 << 20)).toFixed(1) + ' MB';
  if (n > 1 << 10) return (n / (1 << 10)).toFixed(0) + ' kB';
  return n + ' B';
}

function ago(unixSeconds) {
  const s = Math.max(0, Math.floor(Date.now() / 1000 - unixSeconds));
  if (s < 60) return 'just now';
  if (s < 3600) return Math.floor(s / 60) + ' min ago';
  if (s < 86400) return Math.floor(s / 3600) + ' h ago';
  return Math.floor(s / 86400) + ' d ago';
}

// --------------------------------------------------------------------- run --
async function runSelected() {
  const v = currentVerb();
  if (!v) return;
  const flags = [...checkedFlags].filter((f) => v.flags && v.flags.includes(f));
  try {
    clearLog();
    setRunning(true);
    status(`running ${v.label.toLowerCase()}…`, 0);
    await api('api/run', { method: 'POST', body: { verb: v.name, flags } });
  } catch (err) {
    setRunning(false);
    status(err.message, 8000);
  }
}

async function stopRun() {
  try {
    await api('api/cancel', { method: 'POST', body: {} });
  } catch (err) {
    status(err.message, 8000);
  }
}

function setRunning(value) {
  running = value;
  renderRunState();
}

// --------------------------------------------------------------------- log --
function connectLog() {
  const stream = new EventSource('api/log');

  stream.addEventListener('message', (event) => {
    let line;
    try { line = JSON.parse(event.data); } catch (_) { return; }
    // seq restarts at 1 on every run, and the server replays its buffer to a
    // reconnecting client: either way a slow seq means "new run, start over".
    if (line.seq <= lastSeq) {
      clearLog();
      lastSeq = 0;
    }
    lastSeq = line.seq;
    appendLine(line);
  });

  stream.addEventListener('error', () => {
    // EventSource retries on its own; the replay would duplicate, which the
    // seq check above handles.
  });
}

function renderLogLine(pre, line) {
  const stick = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
  const node = document.createElement('span');

  if (line.stream === 'done') {
    node.className = /finished/.test(line.text) ? 'done-ok' : 'done-bad';
    node.textContent = '— ' + line.text + ' —\n';
    pre.appendChild(node);
    if (stick) pre.scrollTop = pre.scrollHeight;
    return true;
  }
  if (line.stream === 'note') {
    node.className = 'note';
    node.textContent = '· ' + line.text + '\n';
  } else if (line.stream === 'err') {
    node.className = 'err';
    node.innerHTML = ansiToHtml(line.text) + '\n';
  } else {
    node.innerHTML = ansiToHtml(line.text) + '\n';
  }
  pre.appendChild(node);
  if (stick) pre.scrollTop = pre.scrollHeight;
  return false;
}

function appendLine(line) {
  const finished = renderLogLine($('log'), line);
  if (finished) {
    setRunning(false);
    status(line.text, 6000);
    // A build just wrote out/ — that is the one moment the file list is worth
    // showing without being asked for.
    if (/finished/.test(line.text)) $('out-fold').open = true;
    refreshState();
  }
}

function clearLog() {
  $('log').textContent = '';
  lastSeq = 0;
}

// The Device tab has its own console. It is fed by the same /api/log stream —
// the server replays the buffer to every subscriber — so an adb command, a
// download and a build all report in one place without a second protocol.
function connectAdbLog() {
  const stream = new EventSource('api/log');
  stream.addEventListener('message', (event) => {
    let line;
    try { line = JSON.parse(event.data); } catch (_) { return; }
    if (line.seq <= adbSeq) {
      adbClear();
      adbSeq = 0;
    }
    adbSeq = line.seq;
    renderLogLine($('adb-console'), line);
    if (line.stream === 'done') {
      setRunning(false);
      refreshState();
    }
  });
}

function adbClear() {
  $('adb-console').textContent = '';
  adbSeq = 0;
}

function adbPrint(text) {
  const pre = $('adb-console');
  pre.appendChild(el('span', 'err', text + '\n'));
  pre.scrollTop = pre.scrollHeight;
}

// -------------------------------------------------------------------- ansi --
const BASE16 = [
  '#2b2b2b', '#c14a3c', '#5f9e56', '#c9a227', '#4a7fb5', '#a05fbf', '#4c9aa8', '#c9c6b4',
  '#6f6d60', '#e2683a', '#8fd6a8', '#e3c55b', '#7aa6d8', '#c58ad8', '#7fc4cf', '#f2eee3',
];

function xterm256(n) {
  if (n < 16) return BASE16[n];
  if (n < 232) {
    const i = n - 16;
    const level = [0, 95, 135, 175, 215, 255];
    const r = level[Math.floor(i / 36) % 6];
    const g = level[Math.floor(i / 6) % 6];
    const b = level[i % 6];
    return `rgb(${r},${g},${b})`;
  }
  const grey = 8 + (n - 232) * 10;
  return `rgb(${grey},${grey},${grey})`;
}

// ansiToHtml renders the SGR codes build.sh emits (tput setaf, bold, dim) so a
// coloured script reads the same in the pane as in a terminal. Anything else is
// dropped, which is why the output is escaped text plus <span style>.
function ansiToHtml(input) {
  let out = '';
  let fg = null, bg = null, bold = false, dim = false, italic = false, underline = false;
  let last = 0;

  const styleAttr = () => {
    const s = [];
    if (fg) s.push('color:' + fg);
    if (bg) s.push('background:' + bg);
    if (bold) s.push('font-weight:700');
    if (dim) s.push('opacity:.65');
    if (italic) s.push('font-style:italic');
    if (underline) s.push('text-decoration:underline');
    return s.join(';');
  };

  const flush = (text) => {
    if (!text) return;
    const style = styleAttr();
    out += style ? `<span style="${style}">${esc(text)}</span>` : esc(text);
  };

  const re = /\x1b\[([0-9;]*)m/g;
  let m;
  while ((m = re.exec(input)) !== null) {
    flush(input.slice(last, m.index));
    last = re.lastIndex;

    const codes = m[1].split(';').map((x) => (x === '' ? 0 : parseInt(x, 10)));
    for (let i = 0; i < codes.length; i++) {
      const c = codes[i];
      if (Number.isNaN(c)) continue;
      if (c === 0) { fg = null; bg = null; bold = dim = italic = underline = false; }
      else if (c === 1) bold = true;
      else if (c === 2) dim = true;
      else if (c === 3) italic = true;
      else if (c === 4) underline = true;
      else if (c === 22) { bold = false; dim = false; }
      else if (c === 23) italic = false;
      else if (c === 24) underline = false;
      else if (c >= 30 && c <= 37) fg = BASE16[c - 30];
      else if (c === 39) fg = null;
      else if (c >= 40 && c <= 47) bg = BASE16[c - 40];
      else if (c === 49) bg = null;
      else if (c >= 90 && c <= 97) fg = BASE16[c - 90 + 8];
      else if (c >= 100 && c <= 107) bg = BASE16[c - 100 + 8];
      else if (c === 38 || c === 48) {
        const target = c === 38 ? 'fg' : 'bg';
        if (codes[i + 1] === 5) {
          const value = xterm256(codes[i + 2]);
          if (target === 'fg') fg = value; else bg = value;
          i += 2;
        } else if (codes[i + 1] === 2) {
          const value = `rgb(${codes[i + 2]},${codes[i + 3]},${codes[i + 4]})`;
          if (target === 'fg') fg = value; else bg = value;
          i += 4;
        }
      }
    }
  }
  flush(input.slice(last));
  return out;
}

function esc(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

// ------------------------------------------------------------------ config --
// Form view of config.env. The server hands over sections and entries with the
// comment block that belongs to each key; this file only tracks what changed
// and sends those rows back, so the headings, prose and commented-out lines are
// never rewritten by a round trip through a form.
function fieldsFocused() {
  const active = document.activeElement;
  return active && $('cfg-fields').contains(active);
}

function renderConfig(force = false) {
  const raw = $('cfg');
  raw.hidden = !cfgRaw;
  $('cfg-fields').hidden = cfgRaw;
  $('cfg-mode').textContent = cfgRaw ? 'back to the form' : 'edit the raw file';
  $('cfg-hint').hidden = cfgRaw;

  if (cfgRaw) {
    if (!cfgRawDirty && !fieldsFocused()) raw.value = state.configText || '';
    raw.disabled = !state.cloneValid;
    return;
  }

  // Never repaint over a keystroke, and never repaint away unsaved edits: the
  // 20-second poll would otherwise undo what is being typed.
  if (!force && (cfgEdits.size > 0 || fieldsFocused())) return;

  const box = $('cfg-fields');
  box.textContent = '';

  const doc = state.config;
  if (!state.cloneValid || !doc || !doc.sections || doc.sections.length === 0) {
    box.appendChild(el('p', 'muted', state.cloneValid
      ? 'config.env is empty or missing — run Build once, or Clean --all to recreate it.'
      : 'Pick the clone first.'));
    return;
  }

  for (const sec of doc.sections) {
    const wrap = el('div', 'cfg-sec');
    if (sec.title) wrap.appendChild(el('div', 'cfg-sec-title', sec.title));
    if (sec.note && sec.note.length) {
      wrap.appendChild(el('p', 'cfg-sec-note', sec.note.join('\n')));
    }
    const entries = sec.entries || [];
    for (const entry of entries) wrap.appendChild(cfgRow(entry));
    if (!sec.title && !(sec.note && sec.note.length) && entries.length === 0) continue;
    box.appendChild(wrap);
  }
  updateCfgStatus();
}

function cfgRow(entry) {
  const row = el('div', 'cfg-row');
  row.dataset.line = String(entry.line);
  row.classList.toggle('is-off', !entry.enabled);

  const on = document.createElement('input');
  on.type = 'checkbox';
  on.className = 'cfg-on';
  on.checked = entry.enabled;
  on.title = entry.enabled ? 'on — click to comment this line out' : 'off — click to enable';

  const key = el('code', 'cfg-key', entry.key);
  key.title = entry.key;

  const value = document.createElement('input');
  value.className = 'cfg-value';
  value.value = entry.value;
  value.spellcheck = false;
  value.autocomplete = 'off';
  value.setAttribute('aria-label', entry.key);

  const info = el('button', 'cfg-info', 'i');
  info.type = 'button';
  info.setAttribute('aria-expanded', 'false');
  const comment = entry.comment || [];
  info.disabled = comment.length === 0;
  info.title = comment.length ? 'What this setting does' : 'the file has no note for this one';

  const note = el('p', 'cfg-info-text', comment.join('\n'));
  note.hidden = true;

  const sync = () => {
    const changed = on.checked !== entry.enabled || value.value !== entry.value;
    row.classList.toggle('is-dirty', changed);
    row.classList.toggle('is-off', !on.checked);
    if (changed) {
      cfgEdits.set(entry.line, {
        line: entry.line,
        key: entry.key,
        value: value.value,
        enabled: on.checked,
      });
    } else {
      cfgEdits.delete(entry.line);
    }
    updateCfgStatus();
  };

  on.addEventListener('change', sync);
  value.addEventListener('input', sync);
  info.addEventListener('click', () => {
    note.hidden = !note.hidden;
    info.setAttribute('aria-expanded', String(!note.hidden));
  });

  // ⓘ leads the row: it is the first thing to reach for when a setting is
  // unfamiliar, and a leading column keeps every row's ⓘ in the same place.
  row.append(info, on, key, value, note);
  return row;
}

function updateCfgStatus() {
  // Two views, two kinds of "dirty": the form counts rows, the textarea is one
  // blob. Both have to enable Save, or the raw view can only be saved with
  // Ctrl+S — which is not a discoverable answer.
  const n = cfgEdits.size;
  const dirty = cfgRaw ? cfgRawDirty : n > 0;
  let text = '';
  if (cfgRaw) text = cfgRawDirty ? 'unsaved changes' : '';
  else text = n ? `${n} unsaved change${n === 1 ? '' : 's'}` : '';

  $('cfg-status').textContent = text;
  $('cfg-save').disabled = !dirty || !state || !state.cloneValid;
  $('cfg-revert').disabled = !dirty;
}

async function saveConfig() {
  if (!state || !state.cloneValid) return;
  try {
    if (cfgRaw) {
      if (!$('cfg').value) return;
      await api('api/config', { method: 'POST', body: { text: $('cfg').value } });
      cfgRawDirty = false;
      updateCfgStatus();
      status('config.env saved', 3000);
    } else {
      if (cfgEdits.size === 0) {
        status('nothing to save', 3000);
        return;
      }
      const edits = [...cfgEdits.values()];
      const res = await api('api/config/apply', { method: 'POST', body: { edits } });
      cfgEdits.clear();
      state.config = res.config;
      state.configText = res.text;
      renderConfig(true);
      status(`saved ${edits.length} change${edits.length === 1 ? '' : 's'}`, 4000);
    }
  } catch (err) {
    status(err.message, 9000);
  }
}

function setConfigMode(raw) {
  cfgRaw = raw;
  if (!raw) {
    // Coming back from the textarea: re-read the file, because it may have been
    // edited there and a form built from the old text would show stale values.
    cfgEdits.clear();
    cfgRawDirty = false;
    updateCfgStatus();
    refreshState(true);
    return;
  }
  renderConfig(true);
  updateCfgStatus();
}

// -------------------------------------------------------------------- docs --
function renderDocsNav() {
  const nav = $('docs-nav');
  nav.textContent = '';
  for (const doc of state.docs || []) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = doc.title;
    b.className = doc.name === currentDoc ? 'is-active' : '';
    b.addEventListener('click', () => openDoc(doc.name));
    nav.appendChild(b);
  }
}

async function openDoc(name) {
  try {
    const data = await api('api/doc?name=' + encodeURIComponent(name));
    currentDoc = name;
    renderDocsNav();
    $('docs-body').innerHTML = mdToHtml(data.text);
    $('docs-body').scrollTop = 0;
  } catch (err) {
    $('docs-body').textContent = 'could not read ' + name + ': ' + err.message;
  }
}

// ------------------------------------------------------------------ device --
const VALUE_KEYS = { codename: 'trc.codename', manufacturer: 'trc.manufacturer' };

function adbReady() {
  return !!(state && state.adb && state.adb.available);
}

function adbValue(name) {
  return $(name === 'codename' ? 'adb-codename' : 'adb-manufacturer').value.trim();
}

function seedAdbValues() {
  if (!state || !state.config) return;
  if (!$('adb-codename').value) {
    $('adb-codename').value = localStorage.getItem(VALUE_KEYS.codename) || cfgValue('DEVICE_CODENAME');
  }
  if (!$('adb-manufacturer').value) {
    $('adb-manufacturer').value = localStorage.getItem(VALUE_KEYS.manufacturer) || cfgValue('DEVICE_MANUFACTURER');
  }
}

function cfgValue(key) {
  const doc = state.config || {};
  for (const sec of doc.sections || []) {
    for (const e of sec.entries || []) {
      if (e.key !== key || !e.enabled) continue;
      const v = (e.value || '').trim();
      return v.startsWith('<') ? '' : v;
    }
  }
  return '';
}

function rememberAdbValues() {
  localStorage.setItem(VALUE_KEYS.codename, adbValue('codename'));
  localStorage.setItem(VALUE_KEYS.manufacturer, adbValue('manufacturer'));
}

function renderAdb() {
  const adb = (state && state.adb) || {};
  const line = $('adb-status');
  const install = $('adb-install');

  if (adb.available) {
    const where = adb.source === 'tools' ? 'tools/platform-tools' : 'on PATH';
    line.textContent = `adb ${adb.version || ''} — ${adb.path} (${where})`.replace(/\s+/g, ' ');
    line.title = adb.path;
    install.hidden = true;
  } else {
    line.textContent = adb.error || 'adb was not found';
    install.hidden = !adb.installable;
    install.title = adb.url || '';
  }

  seedAdbValues();
  renderPresets();
  $('adb-input').disabled = !adb.available;
  $('adb-detect').disabled = !adb.available;
  renderRunState();
}

const GROUP_TITLES = {
  identity: 'Device identity',
  match: 'Finding the match property',
  display: 'Display',
  fingerprint: 'Fingerprint and framework',
};

function missingNeeds(preset) {
  return (preset.needs || []).filter((need) => !adbValue(need));
}

function renderPresets() {
  const box = $('adb-presets');
  box.textContent = '';

  const groups = new Map();
  for (const p of (state && state.adbPresets) || []) {
    if (!groups.has(p.group)) groups.set(p.group, []);
    groups.get(p.group).push(p);
  }

  for (const [group, list] of groups) {
    const sec = el('div', 'preset-group');
    sec.appendChild(el('h3', null, GROUP_TITLES[group] || group));
    for (const p of list) {
      const b = el('button', 'preset');
      b.type = 'button';

      const cmd = document.createElement('code');
      const shown = p.args.join(' ');
      cmd.textContent = 'adb ' + shown.replace(/\{codename\}/g, adbValue('codename') || '{codename}')
        .replace(/\{manufacturer\}/g, adbValue('manufacturer') || '{manufacturer}');

      const why = el('span', 'why', p.why);
      if (p.advice) why.appendChild(el('span', 'advice', p.advice));

      b.append(cmd, why);

      const missing = missingNeeds(p);
      b.disabled = !adbReady() || missing.length > 0;
      if (missing.length) b.title = `needs ${missing.join(' and ')} — fill it in above`;
      else b.title = p.why;

      b.addEventListener('click', () => runAdb({ preset: p.id }));
      sec.appendChild(b);
    }
    box.appendChild(sec);
  }
}

async function runAdb(body) {
  try {
    adbClear();
    await api('api/adb', {
      method: 'POST',
      body: {
        ...body,
        codename: adbValue('codename'),
        manufacturer: adbValue('manufacturer'),
      },
    });
    setRunning(true);
    if (body.command) pushHistory(body.command);
  } catch (err) {
    adbPrint('✗ ' + err.message);
    status(err.message, 9000);
  }
}

const history = [];
let historyAt = -1;

function pushHistory(command) {
  if (!command) return;
  if (history[history.length - 1] !== command) history.push(command);
  if (history.length > 60) history.shift();
  historyAt = history.length;
}

function adbStep(delta) {
  if (history.length === 0) return;
  historyAt = Math.min(history.length, Math.max(0, historyAt + delta));
  $('adb-input').value = historyAt === history.length ? '' : history[historyAt];
}

async function installAdb() {
  try {
    adbClear();
    await api('api/adb/install', { method: 'POST', body: {} });
    setRunning(true);
    status('downloading platform-tools…', 0);
  } catch (err) {
    adbPrint('✗ ' + err.message);
    status(err.message, 9000);
  }
}

async function detectDevice() {
  try {
    status('asking the phone…', 0);
    const d = await api('api/adb/detect', { method: 'POST', body: {} });
    if (d.codename) $('adb-codename').value = d.codename;
    if (d.manufacturer) $('adb-manufacturer').value = d.manufacturer;
    rememberAdbValues();
    renderPresets();
    status(`detected ${d.codename || 'the device'}`, 5000);
  } catch (err) {
    status(err.message, 9000);
    adbPrint('✗ ' + err.message);
  }
}

async function extract(action) {
  try {
    switchTab('build');
    clearLog();
    setRunning(true);
    status('pulling…', 0);
    await api('api/extract', { method: 'POST', body: { action } });
  } catch (err) {
    setRunning(false);
    status(err.message, 8000);
  }
}

// ------------------------------------------------------------------ update --
let updInfo = null;

async function openUpdate() {
  $('upd-error').hidden = true;
  $('upd-output').hidden = true;
  $('upd-files').hidden = true;
  $('upd-files-label').hidden = true;
  $('upd-clash').hidden = true;
  $('upd-go').disabled = true;
  $('upd-go').textContent = 'Update now';
  delete $('upd-go').dataset.done;
  $('upd-head').textContent = 'checking for updates…';
  if ($('update').showModal) $('update').showModal();

  try {
    updInfo = await api('api/update', { method: 'POST', body: { action: 'check' } });
  } catch (err) {
    updInfo = null;
    $('upd-head').textContent = 'could not check for updates: ' + err.message;
    $('upd-go').hidden = true;
    return;
  }
  $('upd-go').hidden = false;
  renderUpdate();
}

function renderUpdate() {
  const u = updInfo;
  const go = $('upd-go');
  if (!u) return;

  $('upd-output').hidden = true;
  $('upd-error').hidden = true;

  if (u.error) {
    $('upd-head').textContent = 'could not check for updates: ' + u.error;
    $('upd-files').hidden = true;
    $('upd-files-label').hidden = true;
    $('upd-clash').hidden = true;
    go.disabled = true;
    return;
  }

  if (!u.available) {
    $('upd-head').textContent = `already up to date${u.upstream ? ` (${u.upstream})` : ''}`;
    $('upd-files').hidden = true;
    $('upd-files-label').hidden = true;
    $('upd-clash').hidden = true;
    go.disabled = true;
    return;
  }

  const count = `${u.behind} new commit${u.behind === 1 ? '' : 's'}`;
  $('upd-head').textContent = `${count} on ${u.upstream} (you are on ${u.branch || 'this branch'}${u.ahead ? `, ${u.ahead} commit(s) of your own` : ''})`;

  const files = u.files || [];
  if (files.length) {
    $('upd-files-label').hidden = false;
    $('upd-files').hidden = false;
    $('upd-files').textContent = files.join('\n');
  }

  const clash = u.clash || [];
  if (clash.length) {
    $('upd-clash').hidden = false;
    $('upd-clash-files').textContent = clash.join('\n');
    $('upd-clash-note').textContent =
      'These files are also edited here, so git cannot fast-forward over them. ' +
      'They will be copied to backups/pre-update-<time>/ first, then replaced by ' +
      'the new version — retype any values from that copy afterwards.';
  } else {
    $('upd-clash').hidden = true;
  }

  if (u.configChanges && u.configChanges.length) {
    $('upd-files-label').hidden = false;
    $('upd-files').hidden = false;
    $('upd-files').textContent = files.join('\n') +
      '\n\nconfig.env settings it changes:\n' + u.configChanges.join('\n');
  }

  go.textContent = clash.length ? 'Back up my edits and update' : 'Update now';
  go.disabled = false;
}

async function runUpdate() {
  const u = updInfo;
  if (!u || !u.available) return;
  const go = $('upd-go');
  go.disabled = true;
  go.textContent = 'updating…';

  try {
    const res = await api('api/update', {
      method: 'POST',
      body: { action: 'pull', backup: (u.clash || []).length > 0 },
    });
    $('upd-output').hidden = false;
    $('upd-output').textContent = (res.output || 'updated') +
      (res.backedUp && res.backedUp.length ? '\n\nbacked up:\n' + res.backedUp.join('\n') : '') +
      (res.restart ? '\n\nThe app itself changed — close this window and start it again (gui.sh / gui.cmd) to run the new version. The build scripts are already the new ones.' : '');
    go.textContent = 'Close';
    go.disabled = false;
    go.dataset.done = '1';
    await refreshState(true);
  } catch (err) {
    if (err.data && err.data.clash) {
      // The check said it was clean but the tree changed under us; show the
      // real list and let the user decide again.
      updInfo.clash = err.data.clash;
      renderUpdate();
      $('upd-error').hidden = false;
      $('upd-error').textContent = 'nothing was changed: ' + err.message;
      return;
    }
    $('upd-error').hidden = false;
    $('upd-error').textContent = err.message;
    go.disabled = false;
    go.textContent = (u.clash || []).length ? 'Back up my edits and update' : 'Update now';
  }
}

// -------------------------------------------------------------------- tabs --
function switchTab(name) {
  for (const t of document.querySelectorAll('.tab')) {
    t.classList.toggle('is-active', t.dataset.tab === name);
  }
  for (const p of document.querySelectorAll('.pane')) {
    p.classList.toggle('is-active', p.id === 'pane-' + name);
  }
  if (name === 'device') renderAdb();
  if (name === 'config') renderConfig();
}

// ------------------------------------------------------------------ dialog --
function openSettings() {
  $('set-clone').value = state ? state.clone : '';
  $('set-bash').value = state ? state.bash : '';
  $('set-error').hidden = true;
  $('settings').showModal();
}

async function saveSettings(event) {
  event.preventDefault();
  const clone = $('set-clone').value.trim();
  const bash = $('set-bash').value.trim();
  try {
    state = await api('api/settings', { method: 'POST', body: { clone, bash } });
    $('settings').close();
    cfgEdits.clear();
    await refreshState(true);
    status('paths saved', 3000);
  } catch (err) {
    $('set-error').textContent = err.message;
    $('set-error').hidden = false;
  }
}

// ------------------------------------------------------------------- markdown --
// Deliberately small: headings, lists, fences, tables, quotes and inline
// emphasis are all the docs use. Links to another .md open in place; anything
// else opens in the real browser, so the webview never navigates away from the
// app.
let docNames = new Set();

function mdToHtml(md) {
  docNames = new Set((state.docs || []).map((d) => d.name));
  const lines = md.replace(/\r\n/g, '\n').split('\n');
  const out = [];
  let i = 0;

  while (i < lines.length) {
    const line = lines[i];

    if (/^\s*```/.test(line)) {
      const fence = line.trim().slice(3);
      i++;
      const code = [];
      while (i < lines.length && !/^\s*```/.test(lines[i])) code.push(lines[i++]);
      i++;
      out.push(`<pre data-lang="${esc(fence)}"><code>${esc(code.join('\n'))}</code></pre>`);
      continue;
    }

    let m = /^(#{1,6})\s+(.*)$/.exec(line);
    if (m) {
      const level = m[1].length;
      out.push(`<h${level}>${inline(m[2])}</h${level}>`);
      i++;
      continue;
    }

    if (/^\s*(-{3,}|\*{3,})\s*$/.test(line)) {
      out.push('<hr>');
      i++;
      continue;
    }

    if (/^\s*\|/.test(line) && i + 1 < lines.length && /^\s*\|[\s:|-]+\|?\s*$/.test(lines[i + 1])) {
      const header = cells(line);
      i += 2;
      const rows = [];
      while (i < lines.length && /^\s*\|/.test(lines[i])) {
        rows.push(cells(lines[i]));
        i++;
      }
      out.push('<table><thead><tr>' + header.map((c) => `<th>${inline(c)}</th>`).join('') + '</tr></thead><tbody>' +
        rows.map((r) => '<tr>' + r.map((c) => `<td>${inline(c)}</td>`).join('') + '</tr>').join('') +
        '</tbody></table>');
      continue;
    }

    if (/^\s*>/.test(line)) {
      const quote = [];
      while (i < lines.length && /^\s*>/.test(lines[i])) {
        quote.push(lines[i].replace(/^\s*>\s?/, ''));
        i++;
      }
      out.push('<blockquote>' + mdToHtml(quote.join('\n')) + '</blockquote>');
      continue;
    }

    if (/^\s*([-*+]|\d+\.)\s+/.test(line)) {
      const ordered = /^\s*\d+\./.test(line);
      const items = [];
      while (i < lines.length && /^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
        items.push(inline(lines[i].replace(/^\s*([-*+]|\d+\.)\s+/, '')));
        i++;
        // Continuation lines of the same item.
        while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*([-*+]|\d+\.)\s+/.test(lines[i])) {
          items[items.length - 1] += ' ' + inline(lines[i].trim());
          i++;
        }
      }
      const tag = ordered ? 'ol' : 'ul';
      out.push(`<${tag}>` + items.map((t) => `<li>${t}</li>`).join('') + `</${tag}>`);
      continue;
    }

    if (line.trim() === '') {
      i++;
      continue;
    }

    const para = [];
    while (i < lines.length && lines[i].trim() !== '' &&
           !/^\s*(#{1,6}\s|>|```|\||([-*+]|\d+\.)\s)/.test(lines[i]) &&
           !/^\s*(-{3,}|\*{3,})\s*$/.test(lines[i])) {
      para.push(lines[i]);
      i++;
    }
    out.push('<p>' + para.map(inline).join(' ') + '</p>');
  }

  return out.join('\n');
}

function cells(line) {
  return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => c.trim());
}

function inline(text) {
  let s = esc(text);
  s = s.replace(/`([^`]+)`/g, '<code>$1</code>');
  s = s.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  s = s.replace(/\*([^*]+)\*/g, '<em>$1</em>');

  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (whole, label, href) => {
    const url = href.replace(/&amp;/g, '&');
    if (/^https?:\/\//i.test(url)) {
      return `<button type="button" class="md-ext" data-url="${esc(url)}">${label}</button>`;
    }
    if (/^#/.test(url)) return label;
    const name = url.split('/').pop().split('#')[0];
    if (docNames.has(name)) {
      return `<button type="button" class="md-link" data-doc="${esc(name)}">${label}</button>`;
    }
    return label;
  });
  return s;
}

// -------------------------------------------------------------------- wire --
function bind() {
  $('run').addEventListener('click', runSelected);
  $('stop').addEventListener('click', stopRun);
  $('log-clear').addEventListener('click', clearLog);
  $('open-out').addEventListener('click', () => {
    api('api/open', { method: 'POST', body: { target: 'out' } }).catch((e) => status(e.message, 6000));
  });

  $('chip-clone').addEventListener('click', openSettings);
  $('chip-bash').addEventListener('click', openSettings);
  $('settings-form').addEventListener('submit', saveSettings);
  $('set-save').addEventListener('click', saveSettings);

  $('chip-update').addEventListener('click', openUpdate);
  $('upd-go').addEventListener('click', (event) => {
    event.preventDefault();
    if ($('upd-go').dataset.done === '1') {
      $('update').close();
      return;
    }
    runUpdate();
  });

  $('cfg-save').addEventListener('click', saveConfig);
  $('cfg-mode').addEventListener('click', () => setConfigMode(!cfgRaw));
  $('cfg-revert').addEventListener('click', async () => {
    cfgEdits.clear();
    cfgRawDirty = false;
    await refreshState(true);
    status('reverted to the file on disk', 3000);
  });
  $('cfg-check').addEventListener('click', async () => {
    if (cfgEdits.size > 0 || (cfgRaw && cfgRawDirty)) await saveConfig();
    switchTab('build');
    selectedVerb = 'check';
    renderVerbs();
    renderFlags();
    await runSelected();
  });
  $('cfg').addEventListener('input', () => {
    cfgRawDirty = true;
    updateCfgStatus();
  });

  $('adb-refresh').addEventListener('click', () => refreshState(true));
  $('adb-install').addEventListener('click', installAdb);
  $('adb-detect').addEventListener('click', detectDevice);
  $('adb-run').addEventListener('click', () => {
    const command = $('adb-input').value.trim();
    if (!command) return;
    runAdb({ command });
  });
  $('adb-stop').addEventListener('click', stopRun);
  $('adb-input').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') {
      event.preventDefault();
      const command = $('adb-input').value.trim();
      if (command) runAdb({ command });
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      adbStep(-1);
    } else if (event.key === 'ArrowDown') {
      event.preventDefault();
      adbStep(1);
    }
  });
  for (const input of [$('adb-codename'), $('adb-manufacturer')]) {
    input.addEventListener('change', () => {
      rememberAdbValues();
      renderPresets();
    });
  }

  for (const b of document.querySelectorAll('[data-extract]')) {
    b.addEventListener('click', () => extract(b.dataset.extract));
  }

  $('docs-body').addEventListener('click', (event) => {
    const target = event.target.closest('button.md-link, button.md-ext');
    if (!target) return;
    if (target.dataset.doc) {
      openDoc(target.dataset.doc);
    } else if (target.dataset.url) {
      api('api/url', { method: 'POST', body: { url: target.dataset.url } })
        .catch((err) => status(err.message, 6000));
    }
  });

  for (const t of document.querySelectorAll('.tab')) {
    t.addEventListener('click', () => switchTab(t.dataset.tab));
  }

  document.addEventListener('keydown', (event) => {
    if ((event.ctrlKey || event.metaKey) && event.key === 's') {
      event.preventDefault();
      if (document.querySelector('#pane-config').classList.contains('is-active')) saveConfig();
    }
    if (event.key === 'Escape') return;
  });

  window.addEventListener('beforeunload', () => { cfgRawDirty = false; });
}

(async function start() {
  bind();
  connectLog();
  connectAdbLog();
  await refreshState(true);
  if (!state || !state.cloneValid) openSettings();
  setInterval(refreshState, 20000);
})();

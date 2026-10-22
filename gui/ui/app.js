'use strict';

/* ---------------------------------------------------------------------------
   The window is a thin client over the handlers in server.go. Everything it
   can do is one of build.sh's verbs, so there is no build logic here: it picks
   a verb, ticks flags, and renders what the child prints.

   Three panes talk to the phone or edit files — config.env, adb and the src/
   workspace — and all of them go through the server, which owns the parsing,
   the path rules and every write. Nothing here touches the disk directly.
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
let running = false;      // the build console
let adbRunning = false;  // the device console, which has its own stream
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
  if (opts.form !== undefined) {
    // Multipart upload: the browser owns the Content-Type boundary, so no
    // header is set here.
    init.body = opts.form;
  } else if (opts.body !== undefined) {
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
  adbRunning = !!(state.adbRun && state.adbRun.running);

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
  const upd = state.update || {};

  // One button for both paths: the clone and bash are set in the same dialog,
  // so two chips that open it only made the header look busier. The dot still
  // says whether the pair is usable, and the tooltip keeps both paths visible.
  const path = $('chip-path');
  path.dataset.tone = state.cloneValid && state.bashValid ? 'ok' : 'bad';
  path.title = [
    'clone: ' + (state.clone || 'none — click to set'),
    'bash: ' + (state.bash || 'none — click to set'),
    'click to change either',
  ].join('\n');

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

  // The button always says what it does; the dot carries the answer. Green
  // means there is something to pull, which is the one case worth a colour.
  const chip = $('chip-update');
  if (upd.available) {
    chip.dataset.tone = 'ok';
    chip.title = `${upd.behind} new commit${upd.behind === 1 ? '' : 's'} on ${upd.upstream} — click to see what it changes`;
  } else if (upd.error && !upd.checked) {
    chip.dataset.tone = 'warn';
    chip.title = 'could not check for updates: ' + upd.error;
  } else {
    chip.dataset.tone = '';
    chip.title = upd.checked ? 'up to date — click to check again' : 'click to check for updates';
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

  // The two consoles keep separate streams and separate buffers, but they share
  // one job slot on the server: both write into the same clone, so a pull and a
  // build must never overlap.
  $('run').disabled = !ready || running || adbRunning || !v;
  $('stop').disabled = !running;
  $('run').textContent = v ? `Run ${v.label.toLowerCase()}` : 'Run';

  const flags = v ? [...checkedFlags].filter((f) => v.flags && v.flags.includes(f)) : [];
  const cmd = v ? `build.sh ${v.arg}${flags.length ? ' ' + flags.join(' ') : ''} -y` : '';
  $('run').title = v ? `runs: bash --noprofile --norc ./${cmd}` : '';

  for (const input of $('flags').querySelectorAll('input')) input.disabled = running;
  for (const b of $('verbs').querySelectorAll('.verb')) b.disabled = running;
  $('adb-run').disabled = running || adbRunning || !adbReady();
  $('adb-run').title = running ? 'a build is running — one job at a time' : '';
  $('adb-stop').disabled = !adbRunning;
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
    // A build (re)writes src/framework/res/values/generated.xml, so a tree that
    // was read before it started is out of date.
    if (files) loadFiles();
  }
}

function clearLog() {
  $('log').textContent = '';
  lastSeq = 0;
}

// The Device tab has its own console and its own stream (/api/adb/log). Before
// this split both panes subscribed to one stream, so an adb command showed up in
// the build log and a build showed up in the device console.
function connectAdbLog() {
  const stream = new EventSource('api/adb/log');
  stream.addEventListener('message', (event) => {
    let line;
    try { line = JSON.parse(event.data); } catch (_) { return; }
    if (line.seq <= adbSeq) {
      adbClear();
      adbSeq = 0;
    }
    adbSeq = line.seq;
    if (renderLogLine($('adb-console'), line)) {
      adbRunning = false;
      renderRunState();
      refreshState();
    }
  });
}

function adbClear() {
  $('adb-console').textContent = '';
  adbSeq = 0;
}

let adbStatusTimer = null;

// Device messages belong next to the device, not in the Build pane's status
// line, which the build owns.
function adbStatus(message, ms = 4000) {
  $('adb-status-note').textContent = message;
  if (adbStatusTimer) clearTimeout(adbStatusTimer);
  if (ms) adbStatusTimer = setTimeout(() => { $('adb-status-note').textContent = ''; }, ms);
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
  //
  // A section shows its heading and its rows only. The paragraph the file keeps
  // under that heading is the same text the row's ⓘ opens, so printing it here
  // as well made the form read like the raw file it is meant to replace.
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
    const entries = sec.entries || [];
    for (const entry of entries) wrap.appendChild(cfgRow(entry));
    if (!sec.title && entries.length === 0) continue;
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

// ------------------------------------------------------------------- files --
// The src/ workspace. The server owns every path rule (see gui/files.go); this
// side draws the tree, keeps one file or folder open on the right, and sends
// the operations.
//
// Two things about the tree are deliberate:
//   - a disabled file stays where it belongs, greyed and badged, instead of
//     being collected somewhere else. Its location is the useful part.
//   - clicking a folder shows its contents in the right-hand pane and makes it
//     the upload target, so "where will these files go?" is answered by the
//     folder itself rather than by a path somewhere else on screen.
let files = null;
let filesTarget = { path: '', disabled: false }; // where Upload and New write
let filesSel = null;      // {path, disabled, dir} shown on the right
let filesDirty = false;
let filesBinary = false;
let filesTooBig = false;
let filesSize = 0;
let filesCheck = null;
let filesCollapsed = new Set();
let filesStatusTimer = null;
let filesCheckTimer = null;
let filesCheckSeq = 0;
let newTarget = { dir: '', kind: 'file' };
let confirmAnswer = null;

function fileStatus(message, ms = 4000) {
  $('file-status').textContent = message;
  if (filesStatusTimer) clearTimeout(filesStatusTimer);
  if (ms) filesStatusTimer = setTimeout(() => { $('file-status').textContent = ''; }, ms);
}

function parentOf(path) {
  const cut = path.lastIndexOf('/');
  return cut < 0 ? '' : path.slice(0, cut);
}

function entryOf(path, disabled, dir) {
  if (!files) return null;
  return (files.entries || []).find((e) =>
    e.path === path && !!e.disabled === !!disabled && !!e.dir === !!dir) || null;
}

function fileKey(node) {
  return (node.disabled ? 'd:' : 'e:') + node.path;
}

function sameSelection(path, disabled) {
  return !!filesSel && filesSel.path === path && !!filesSel.disabled === !!disabled;
}

// buildTree turns the flat list into one tree. Disabled entries are placed
// where they logically belong: a disabled file sits under the folder that holds
// it, and a folder that exists only disabled is shown greyed at its normal
// place. A disabled copy of a folder that still exists enabled is not drawn a
// second time — its children already have a row to belong to.
function buildTree(entries) {
  const root = { path: '', name: 'src', dir: true, disabled: false, children: [] };
  const index = new Map([['e:', root]]);
  const dirsEnabled = new Set(['']);
  const dirsDisabled = new Set();

  for (const e of entries || []) {
    if (!e.dir) continue;
    (e.disabled ? dirsDisabled : dirsEnabled).add(e.path);
  }

  const ensureDir = (rel, disabled) => {
    const key = (disabled ? 'd:' : 'e:') + rel;
    const found = index.get(key);
    if (found) return found;

    const cut = rel.lastIndexOf('/');
    const parentRel = cut < 0 ? '' : rel.slice(0, cut);
    // The enabled folder is the parent whenever it exists, so a disabled file
    // is listed inside the folder the user recognises.
    let parent;
    if (dirsEnabled.has(parentRel)) parent = ensureDir(parentRel, false);
    else if (dirsDisabled.has(parentRel)) parent = ensureDir(parentRel, true);
    else parent = ensureDir(parentRel, false);

    const node = { path: rel, name: rel.slice(cut + 1), dir: true, disabled, children: [] };
    parent.children.push(node);
    index.set(key, node);
    return node;
  };

  const parentFor = (rel) => {
    if (dirsEnabled.has(rel)) return ensureDir(rel, false);
    if (dirsDisabled.has(rel)) return ensureDir(rel, true);
    return ensureDir(rel, false);
  };

  for (const e of entries || []) {
    if (e.dir) {
      if (e.disabled && dirsEnabled.has(e.path)) continue;
      if (e.path) ensureDir(e.path, e.disabled);
      continue;
    }
    parentFor(parentOf(e.path)).children.push({
      path: e.path, name: e.name, dir: false, text: e.text,
      size: e.size, mod: e.mod, disabled: e.disabled, children: [],
    });
  }

  const sort = (node) => {
    node.children.sort((a, b) => {
      if (a.dir !== b.dir) return a.dir ? -1 : 1;
      const byName = a.name.localeCompare(b.name);
      if (byName !== 0) return byName;
      if (a.disabled === b.disabled) return 0;
      return a.disabled ? 1 : -1;
    });
    for (const child of node.children) sort(child);
  };
  sort(root);
  return root;
}

async function loadFiles() {
  if (!state || !state.cloneValid) {
    files = null;
    filesSel = null;
    filesTarget = { path: '', disabled: false };
    renderFiles();
    renderPane();
    return;
  }
  try {
    files = await api('api/files');
  } catch (err) {
    files = null;
    filesSel = null;
    renderFiles();
    renderPane();
    fileStatus(err.message, 9000);
    return;
  }

  if (filesSel && !(filesSel.dir && filesSel.path === '') &&
      !entryOf(filesSel.path, filesSel.disabled, filesSel.dir)) {
    filesSel = null;
    filesDirty = false;
    filesCheck = null;
    filesBinary = false;
  }
  if (!filesSel) filesSel = { path: '', disabled: false, dir: true };
  if (filesTarget.path !== '' && !entryOf(filesTarget.path, false, true)) {
    filesTarget = { path: '', disabled: false };
  }
  renderFiles();
  renderPane();
}

function renderFiles() {
  const box = $('files-tree');
  const scroll = box.scrollTop;
  box.textContent = '';

  if (!files || !state || !state.cloneValid) {
    box.appendChild(el('p', 'ft-empty', 'No clone selected.'));
    renderFilesTarget();
    return;
  }

  const root = buildTree(files.entries);
  renderFileNode(box, root, 0);
  if (root.children.length === 0) {
    box.appendChild(el('p', 'ft-empty', 'src/ is empty.'));
  }
  box.scrollTop = scroll;
  renderFilesTarget();
}

function renderFilesTarget() {
  const target = $('files-target');
  target.textContent = '';
  target.append(
    document.createTextNode('Uploads and new files go to '),
    el('code', null, 'src/' + (filesTarget.path ? filesTarget.path + '/' : '')),
  );
  target.title = filesTarget.path ? 'click a folder in the tree to change this' : 'the top of the tree';
}

function renderFileNode(box, node, depth) {
  const row = el('div', 'ft-row');
  row.style.paddingLeft = 6 + depth * 13 + 'px';
  row.dataset.path = node.path;
  row.classList.toggle('is-off', !!node.disabled);
  row.classList.toggle('is-target', node.dir && !node.disabled && filesTarget.path === node.path);
  row.classList.toggle('is-selected', !!filesSel && filesSel.path === node.path &&
    !!filesSel.disabled === !!node.disabled && !!filesSel.dir === !!node.dir);

  const collapsed = node.dir && filesCollapsed.has(fileKey(node));

  if (node.dir) {
    const caret = el('button', 'ft-caret', collapsed ? '▸' : '▾');
    caret.type = 'button';
    caret.title = collapsed ? 'Expand' : 'Collapse';
    caret.setAttribute('aria-expanded', String(!collapsed));
    caret.addEventListener('click', (event) => {
      event.stopPropagation();
      if (collapsed) filesCollapsed.delete(fileKey(node));
      else filesCollapsed.add(fileKey(node));
      renderFiles();
    });
    row.appendChild(caret);
  } else {
    row.appendChild(el('span', 'ft-caret'));
  }

  const main = el('button', 'ft-main');
  main.type = 'button';
  main.append(el('span', 'ft-icon', node.dir ? '' : (node.text ? '·' : '▪')));
  main.append(el('span', 'ft-label', node.name + (node.dir ? '/' : '')));
  if (node.disabled) main.append(el('span', 'ft-badge', 'disabled'));
  main.title = node.dir
    ? 'show this folder — and make it the upload target'
    : 'open ' + (node.disabled ? 'src/.disabled/' : 'src/') + node.path;
  main.addEventListener('click', () => {
    if (node.dir) {
      if (collapsed) filesCollapsed.delete(fileKey(node));
      openFolder(node.path, node.disabled);
      return;
    }
    openFile(node.path, node.disabled);
  });
  row.appendChild(main);

  if (!node.dir) row.appendChild(el('span', 'ft-meta', bytes(node.size || 0)));

  if (node.dir && node.path && !node.disabled) {
    const del = el('button', 'ft-off', '×');
    del.type = 'button';
    del.title = 'Delete this folder and everything in it';
    del.addEventListener('click', (event) => {
      event.stopPropagation();
      deleteEntry(node.path, node.disabled, true);
    });
    row.appendChild(del);
  }

  if (node.path) {
    const off = el('button', 'ft-off', node.disabled ? '↺' : '⊘');
    off.type = 'button';
    off.title = node.disabled
      ? 'Enable — put it back under src/'
      : 'Disable — move it to src/.disabled/, out of the build';
    off.addEventListener('click', (event) => {
      event.stopPropagation();
      toggleEntry(node.path, node.disabled, node.dir);
    });
    row.appendChild(off);
  }

  box.appendChild(row);
  if (node.dir && !collapsed) {
    for (const child of node.children) renderFileNode(box, child, depth + 1);
  }
}

// ------------------------------------------------------------------ panes --
// One selection, three possible right-hand panes: the editor, a folder's
// contents, or the empty placeholder. renderPane is the only place that decides
// which one is on screen.
function renderPane() {
  const sel = filesSel;
  const isFile = !!sel && !sel.dir;
  const placeholder = $('file-placeholder');

  $('file-editor').hidden = !isFile || filesBinary;
  $('folder-view').hidden = !sel || !sel.dir;
  placeholder.hidden = !!sel;

  if (!sel) {
    $('file-path').textContent = 'no file selected';
    placeholder.textContent = '';
    placeholder.appendChild(el('p', 'muted', 'Pick a file or folder on the left, or drop one on the tree.'));
  } else {
    $('file-path').textContent = 'src/' + (sel.disabled ? '.disabled/' : '') +
      sel.path + (sel.dir && sel.path ? '/' : '');
    if (isFile && filesBinary) {
      placeholder.hidden = false;
      placeholder.textContent = '';
      placeholder.appendChild(el('p', 'muted',
        (filesTooBig
          ? `${bytes(filesSize)} is too large for the editor.`
          : `binary file — ${bytes(filesSize)}.`) +
        ' Replace it with Upload, or Delete it.'));
    }
  }

  renderFileButtons();
  renderFileCheck();
  if (sel && sel.dir) renderFolder();
}

function renderFileButtons() {
  const sel = filesSel;
  const isFile = !!sel && !sel.dir;
  $('file-save').disabled = !isFile || filesBinary || !filesDirty;
  $('file-disable').disabled = !sel || sel.path === '';
  $('file-disable').textContent = sel && sel.disabled ? 'Enable' : 'Disable';
  $('file-disable').title = sel && sel.disabled
    ? 'put it back under src/'
    : 'move it to src/.disabled/ — the build stops seeing it, nothing is lost';
  $('file-delete').disabled = !sel || sel.path === '';
}

async function openFile(path, disabled) {
  if (filesDirty) {
    // Clicking the file that is already open should keep the buffer, not
    // re-read the disk over unsaved edits.
    if (sameSelection(path, disabled) && filesSel && !filesSel.dir) return;
    fileStatus('save your changes first — another file is open', 7000);
    return;
  }
  try {
    fileStatus('opening…', 0);
    const q = 'path=' + encodeURIComponent(path) + (disabled ? '&disabled=1' : '');
    const data = await api('api/files/read?' + q);
    filesSel = { path, disabled: !!disabled, dir: false };
    filesDirty = false;
    filesBinary = !!data.binary;
    filesTooBig = !!data.tooBig;
    filesSize = data.size || 0;
    filesCheck = data.check || null;
    $('file-editor').value = data.text || '';
    renderPane();
    renderFiles();
    fileStatus('', 0);
  } catch (err) {
    fileStatus(err.message, 9000);
  }
}

function openFolder(path, disabled) {
  if (filesDirty && !(sameSelection(path, disabled) && filesSel && filesSel.dir)) {
    fileStatus('save your changes first — a file is open', 7000);
    return;
  }
  filesSel = { path, disabled: !!disabled, dir: true };
  filesDirty = false;
  filesCheck = null;
  filesBinary = false;
  if (!disabled) filesTarget = { path, disabled: false };
  renderFiles();
  renderPane();
}

function renderFolder() {
  const sel = filesSel;
  if (!sel || !sel.dir) {
    $('folder-view').hidden = true;
    return;
  }
  $('folder-view').hidden = false;

  const where = 'src/' + (sel.disabled ? '.disabled/' : '') + (sel.path ? sel.path + '/' : '');
  $('folder-path').textContent = where;

  // A disabled copy of a folder that still exists enabled is not a second
  // entry in the tree, so it is not a second row here either.
  const enabledDirs = new Set((files.entries || [])
    .filter((e) => e.dir && !e.disabled).map((e) => e.path));
  const children = (files.entries || []).filter((e) =>
    parentOf(e.path) === sel.path && !(e.dir && e.disabled && enabledDirs.has(e.path)));
  children.sort((a, b) => {
    if (a.dir !== b.dir) return a.dir ? -1 : 1;
    const byName = a.name.localeCompare(b.name);
    if (byName !== 0) return byName;
    if (a.disabled === b.disabled) return 0;
    return a.disabled ? 1 : -1;
  });

  let total = 0;
  for (const child of children) total += child.size || 0;
  const count = children.length;
  $('folder-summary').textContent = `${count} item${count === 1 ? '' : 's'}` +
    (total ? ' · ' + bytes(total) : '');

  const note = $('folder-note');
  if (sel.disabled) {
    note.textContent = 'This folder is disabled — the build does not see it. Enable it to add files again.';
  } else if (filesTarget.path === sel.path) {
    note.textContent = 'Uploads and new files land here.';
  } else {
    note.textContent = 'Click a folder in the tree to make it the upload target.';
  }
  $('folder-upload').disabled = sel.disabled;
  $('folder-new').disabled = sel.disabled;

  const list = $('folder-list');
  list.textContent = '';
  if (children.length === 0) {
    list.appendChild(el('p', 'fo-empty', sel.disabled
      ? 'This folder is empty.'
      : 'This folder is empty — drop files here or use Upload here.'));
    return;
  }
  for (const child of children) list.appendChild(folderRow(child));
}

function folderRow(entry) {
  const row = el('div', 'fo-row');
  row.classList.toggle('is-off', !!entry.disabled);

  const main = el('button', 'fo-main');
  main.type = 'button';
  main.append(el('span', 'ft-icon', entry.dir ? '' : (entry.text ? '·' : '▪')));
  main.append(el('span', 'fo-name', entry.name + (entry.dir ? '/' : '')));
  if (entry.disabled) main.append(el('span', 'ft-badge', 'disabled'));
  main.append(el('span', 'fo-meta', entry.dir ? 'folder' : bytes(entry.size || 0)));
  main.title = entry.dir ? 'open this folder' : 'open this file';
  main.addEventListener('click', () => {
    if (entry.dir) openFolder(entry.path, entry.disabled);
    else openFile(entry.path, entry.disabled);
  });
  row.appendChild(main);

  if (entry.path) {
    const off = el('button', 'ft-off', entry.disabled ? '↺' : '⊘');
    off.type = 'button';
    off.title = entry.disabled ? 'Enable' : 'Disable';
    off.addEventListener('click', () => toggleEntry(entry.path, entry.disabled, entry.dir));
    row.appendChild(off);
  }
  return row;
}

// ----------------------------------------------------------------- checks --
function isCheckable(path) {
  return path === 'module/sepolicy.rule' || /(^|\/)etc\/vintf\/manifest\/[^/]+\.xml$/.test(path);
}

function renderFileCheck() {
  const box = $('file-checks');
  box.textContent = '';
  const check = filesCheck;
  if (!check || !filesSel || filesSel.dir || filesBinary) {
    box.hidden = true;
    return;
  }
  box.hidden = false;
  box.classList.toggle('is-bad', (check.errors || []).length > 0);

  const head = el('div', 'check-head');
  head.append(el('strong', null, check.kind === 'sepolicy' ? 'SELinux rules' : 'VINTF manifest'));
  if (check.summary) head.append(el('span', 'muted', check.summary));
  if (!(check.errors || []).length && !(check.warnings || []).length) {
    head.append(el('span', 'muted', '· looks usable'));
  }
  box.appendChild(head);

  for (const warning of check.warnings || []) box.appendChild(el('p', 'check-warn', warning));
  for (const problem of check.errors || []) box.appendChild(el('p', 'check-bad', problem));

  if ((check.hals || []).length) {
    const line = el('p', 'check-hals');
    line.append(document.createTextNode('Declares: '));
    check.hals.forEach((hal, i) => {
      if (i) line.append(document.createTextNode(' · '));
      line.append(el('code', null, hal.name || 'unnamed'));
      const detail = [hal.format, hal.version, hal.interface && hal.interface + '/' + (hal.instance || 'default')]
        .filter(Boolean).join(' ');
      if (detail) line.append(document.createTextNode(' (' + detail + ')'));
    });
    box.appendChild(line);
  }
}

function scheduleFileCheck() {
  if (filesCheckTimer) clearTimeout(filesCheckTimer);
  if (!filesSel || filesSel.dir || !isCheckable(filesSel.path)) return;
  filesCheckTimer = setTimeout(runFileCheck, 500);
}

async function runFileCheck() {
  if (!filesSel || filesSel.dir) return;
  const seq = ++filesCheckSeq;
  try {
    const res = await api('api/files/check', {
      method: 'POST',
      body: { path: filesSel.path, text: $('file-editor').value },
    });
    if (seq !== filesCheckSeq) return;
    filesCheck = res.check || null;
    renderFileCheck();
  } catch (_) {
    // A check is advice; the save itself reports real failures.
  }
}

async function saveFile() {
  if (!filesSel || filesSel.dir || !filesDirty) return;
  try {
    fileStatus('saving…', 0);
    const res = await api('api/files/write', {
      method: 'POST',
      body: { path: filesSel.path, text: $('file-editor').value, disabled: filesSel.disabled },
    });
    filesDirty = false;
    filesCheck = res.check || null;
    renderPane();
    await loadFiles();
    renderPane();
    fileStatus('saved', 2500);
  } catch (err) {
    fileStatus(err.message, 10000);
  }
}

async function toggleEntry(path, disabled, dir) {
  const isOpen = sameSelection(path, disabled);
  // Disabling a folder moves everything inside it, including the file that is
  // open, so an unsaved buffer blocks that too — not just the open row itself.
  const openInside = filesSel && !filesSel.dir && filesSel.disabled === !!disabled &&
    (filesSel.path === path || filesSel.path.startsWith(path + '/'));
  if (filesDirty && openInside) {
    fileStatus('save your changes first — the file on disk is what moves', 7000);
    return;
  }
  try {
    fileStatus(disabled ? 'enabling…' : 'disabling…', 0);
    const res = await api('api/files/toggle', { method: 'POST', body: { path, disabled } });
    if (!disabled && (filesTarget.path === path || filesTarget.path.startsWith(path + '/'))) {
      filesTarget = { path: '', disabled: false };
    }
    await loadFiles();
    if (isOpen) {
      if (dir) openFolder(path, res.disabled);
      else openFile(path, res.disabled);
    }
    fileStatus(res.disabled
      ? 'disabled — the build will not see it'
      : 'enabled — the build sees it again', 4000);
  } catch (err) {
    fileStatus(err.message, 10000);
  }
}

// ------------------------------------------------------------------ delete --
// Deleting is the one action here that cannot be undone, so it always goes
// through the dialog. The destructive button is on the left, Cancel is on the
// right and is the highlighted one (and the one focused when the dialog opens).
function askConfirm(title, text, yes = 'Delete') {
  return new Promise((resolve) => {
    confirmAnswer = resolve;
    $('confirm-title').textContent = title;
    $('confirm-text').textContent = text;
    $('confirm-yes').textContent = yes;
    $('confirm').showModal();
    $('confirm-no').focus();
  });
}

function resolveConfirm(answer) {
  const resolve = confirmAnswer;
  confirmAnswer = null;
  if ($('confirm').open) $('confirm').close();
  if (resolve) resolve(answer);
}

async function deleteEntry(path, disabled, dir) {
  if (!path) return;
  const openInside = filesSel && !filesSel.dir && filesSel.disabled === !!disabled &&
    (filesSel.path === path || filesSel.path.startsWith(path + '/'));
  if (filesDirty && openInside) {
    fileStatus('save your changes first — the file on disk is what is deleted', 7000);
    return;
  }

  const label = 'src/' + (disabled ? '.disabled/' : '') + path;
  const ok = await askConfirm(
    dir ? 'Delete this folder?' : 'Delete this file?',
    `${label}${dir ? ' and everything in it' : ''} will be removed. This cannot be undone.`,
  );
  if (!ok) return;

  try {
    fileStatus('deleting…', 0);
    await api('api/files/delete', { method: 'POST', body: { path, disabled } });

    const wasSel = filesSel && filesSel.disabled === !!disabled &&
      (filesSel.path === path || filesSel.path.startsWith(path + '/'));
    if (filesTarget.path === path || filesTarget.path.startsWith(path + '/')) {
      filesTarget = { path: '', disabled: false };
    }
    if (wasSel) {
      filesSel = null;
      filesDirty = false;
      filesCheck = null;
      filesBinary = false;
    }
    await loadFiles();

    if (wasSel) {
      const parent = parentOf(path);
      if (parent && entryOf(parent, false, true)) openFolder(parent, false);
      else openFolder('', false);
    }
    fileStatus('deleted ' + label, 4000);
  } catch (err) {
    fileStatus(err.message, 10000);
  }
}

// ------------------------------------------------------------------ upload --
function pickUpload(folder) {
  const input = folder ? $('files-input-dir') : $('files-input');
  input.value = '';
  input.click();
}

async function uploadFiles(items) {
  if (!items.length) return;
  if (!state || !state.cloneValid) {
    fileStatus('pick the clone first', 6000);
    return;
  }
  if (filesTarget.disabled) {
    fileStatus('that folder is disabled — enable it first', 6000);
    return;
  }
  const dir = filesTarget.path;
  const where = 'src/' + (dir ? dir + '/' : '');

  const form = new FormData();
  // The browser drops directories from a multipart filename, so the paths go
  // first, in the same order as the files that follow.
  form.append('paths', JSON.stringify(items.map((i) => i.path)));
  for (const item of items) form.append('files', item.file, item.file.name);

  fileStatus(`copying ${items.length} file${items.length === 1 ? '' : 's'} into ${where}…`, 0);
  try {
    const res = await api('api/files/upload?dir=' + encodeURIComponent(dir), { method: 'POST', form });
    const written = res.written || [];
    const skipped = res.skipped || [];
    await loadFiles();
    if (skipped.length) {
      fileStatus(`copied ${written.length}, skipped ${skipped.length} — ${skipped[0]}`, 15000);
    } else {
      fileStatus(`copied ${written.length} file${written.length === 1 ? '' : 's'} into ${where}`, 5000);
    }
  } catch (err) {
    fileStatus(err.message, 15000);
  }
}

function readDrop(dt) {
  const out = [];
  const entries = [];
  for (const item of dt.items || []) {
    if (item.kind !== 'file') continue;
    const entry = item.webkitGetAsEntry && item.webkitGetAsEntry();
    if (entry) entries.push(entry);
  }
  if (entries.length === 0) {
    for (const file of dt.files || []) out.push({ file, path: file.name });
    return Promise.resolve(out);
  }
  return (async () => {
    for (const entry of entries) await walkDrop(entry, '', out);
    return out;
  })();
}

function walkDrop(entry, prefix, out) {
  return new Promise((resolve) => {
    if (entry.isFile) {
      entry.file(
        (file) => { out.push({ file, path: prefix + entry.name }); resolve(); },
        () => resolve(),
      );
      return;
    }
    const reader = entry.createReader();
    const all = [];
    const read = () => reader.readEntries(
      (batch) => {
        if (batch.length === 0) {
          (async () => {
            for (const child of all) await walkDrop(child, prefix + entry.name + '/', out);
            resolve();
          })();
          return;
        }
        all.push(...batch);
        read();
      },
      () => resolve(),
    );
    read();
  });
}

function bindFileDrop() {
  const tree = $('files-tree');
  const stop = (event) => { event.preventDefault(); event.stopPropagation(); };
  tree.addEventListener('dragenter', (event) => {
    stop(event);
    tree.classList.add('is-drop');
  });
  tree.addEventListener('dragover', (event) => {
    stop(event);
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'copy';
    tree.classList.add('is-drop');
  });
  tree.addEventListener('dragleave', (event) => {
    stop(event);
    if (!event.relatedTarget || !tree.contains(event.relatedTarget)) tree.classList.remove('is-drop');
  });
  tree.addEventListener('drop', async (event) => {
    stop(event);
    tree.classList.remove('is-drop');
    const items = await readDrop(event.dataTransfer);
    if (items.length) uploadFiles(items);
  });
}

// -------------------------------------------------------------------- new --
// In the manifest folder, "New…" means a manifest; anywhere else, a plain file.
function defaultNewKind() {
  return /(^|\/)vendor\/etc\/vintf\/manifest$/.test(filesTarget.path) ? 'aidl' : 'file';
}

function openNewDialog(opts = {}) {
  newTarget = { dir: opts.dir !== undefined ? opts.dir : filesTarget.path, kind: opts.kind || 'file' };
  $('file-new-kind').value = newTarget.kind;
  $('file-new-name').value = opts.name || '';
  $('file-new-error').hidden = true;
  updateNewDialog();
  $('file-new').showModal();
  $('file-new-name').focus();
}

function updateNewDialog() {
  const kind = $('file-new-kind').value;
  newTarget.kind = kind;

  const titles = {
    file: 'New file', dir: 'New folder', aidl: 'New VINTF manifest',
    hidl: 'New VINTF manifest', sepolicy: 'SELinux rules',
  };
  $('file-new-title').textContent = titles[kind] || 'New file';
  $('file-new-where').textContent = 'in src/' + (newTarget.dir ? newTarget.dir + '/' : '');

  const name = $('file-new-name');
  const hints = {
    file: 'Any name. The file is created empty, then opened for editing.',
    dir: 'A folder to put files in. It does not need to exist yet.',
    aidl: 'The HAL name is taken from the file name: android.hardware.biometrics.fingerprint.xml.',
    hidl: 'The HAL name is taken from the file name: android.hardware.vibrator.xml.',
    sepolicy: 'Adds a commented starter to src/module/sepolicy.rule.',
  };
  $('file-new-hint').textContent = hints[kind] || '';

  if (kind === 'sepolicy') {
    newTarget.dir = 'module';
    $('file-new-where').textContent = 'in src/module/';
    if (!name.value) name.value = 'sepolicy.rule';
    name.placeholder = 'sepolicy.rule';
  } else if (kind === 'aidl' || kind === 'hidl') {
    if (!newTarget.dir) newTarget.dir = 'vendor/etc/vintf/manifest';
    $('file-new-where').textContent = 'in src/' + newTarget.dir + '/';
    name.placeholder = 'android.hardware.biometrics.fingerprint.xml';
  } else {
    name.placeholder = 'name';
  }
}

function showNewError(message) {
  $('file-new-error').textContent = message;
  $('file-new-error').hidden = false;
}

async function createNew(event) {
  event.preventDefault();
  const kind = $('file-new-kind').value;
  const name = $('file-new-name').value.trim().replace(/\\/g, '/').replace(/^\/+/, '');
  if (!name) {
    showNewError('give it a name first');
    return;
  }
  const rel = newTarget.dir ? newTarget.dir + '/' + name : name;
  if (kind !== 'dir' && (entryOf(rel, false, false) || entryOf(rel, true, false))) {
    showNewError('src/' + rel + ' already exists — open it from the tree instead');
    return;
  }

  try {
    if (kind === 'dir') {
      await api('api/files/mkdir', { method: 'POST', body: { path: rel } });
      $('file-new').close();
      await loadFiles();
      openFolder(rel, false);
      fileStatus('created src/' + rel + '/', 4000);
      return;
    }
    const text = fileTemplate(kind, name);
    await api('api/files/write', { method: 'POST', body: { path: rel, text } });
    $('file-new').close();
    await loadFiles();
    await openFile(rel, false);
    fileStatus('created src/' + rel, 4000);
  } catch (err) {
    showNewError(err.message);
  }
}

// fileTemplate is the text a new file starts with. The manifest templates are
// shaped so the checker has something real to say about them; the sepolicy one
// is deliberately all comments, because an invented allow rule is worse than no
// rule at all.
function fileTemplate(kind, name) {
  if (kind === 'aidl') return aidlManifest(name);
  if (kind === 'hidl') return hidlManifest(name);
  if (kind === 'sepolicy') return SEPOLICY_TEMPLATE;
  return '';
}

function halFromName(name) {
  const base = name.replace(/\.xml$/i, '').replace(/[^A-Za-z0-9._-]/g, '');
  return base || 'android.hardware.example';
}

function ifaceFromHal(hal) {
  const parts = hal.split('.').filter((p) => p && p !== 'android' && p !== 'hardware' && p !== 'vendor');
  const camel = parts.map((p) => p.charAt(0).toUpperCase() + p.slice(1)).join('');
  return 'I' + (camel || 'Example');
}

function aidlManifest(name) {
  const hal = halFromName(name);
  const iface = ifaceFromHal(hal);
  return `<?xml version="1.0" encoding="utf-8"?>
<!-- AIDL HAL. A fragment copied from your device's /vendor/etc/vintf/manifest/
     is always better than one written by hand: see docs/device-extraction.md. -->
<manifest version="1.0" type="device">
    <hal format="aidl">
        <name>${hal}</name>
        <version>1</version>
        <interface>
            <name>${iface}</name>
            <instance>default</instance>
        </interface>
    </hal>
</manifest>
`;
}

function hidlManifest(name) {
  const hal = halFromName(name);
  const iface = ifaceFromHal(hal);
  return `<?xml version="1.0" encoding="utf-8"?>
<!-- HIDL HAL. A16 GSIs do not bind HIDL HALs; use this only for an older
     GSI. See docs/device-extraction.md. -->
<manifest version="1.0" type="device">
    <hal format="hidl">
        <name>${hal}</name>
        <transport>hwbinder</transport>
        <version>2.3</version>
        <interface>
            <name>${iface}</name>
            <instance>default</instance>
        </interface>
        <fqname>@2.3::${iface}/default</fqname>
    </hal>
</manifest>
`;
}

const SEPOLICY_TEMPLATE = `# SELinux rules for the vendor HALs this module ships.
# One statement per line, ending with ';'. build.sh includes this file only
# when the build includes vendor HALs and a line starts with "allow".
#
# Start from a denial rather than from a guess:
#   adb logcat -b all -d | grep "avc: denied"
#
# allow <hal_type> vendor_file:file { read execute getattr open map };
# allow <hal_type> <device_type>:chr_file rw_file_perms;
# allow <hal_type> <sysfs_type>:dir r_dir_perms;
# allow <hal_type> <sysfs_type>:file r_file_perms;
# allow <hal_type> <data_type>:dir create_dir_perms;
# allow <hal_type> <data_type>:file create_file_perms;
#
# Reference rules for a Samsung A90 5G: stuff/templates/sepolicy.rule.example
`;

// jumpTo is what the two buttons above the tree do: open the file or folder, or
// offer to create it with the right template when it does not exist yet.
function jumpTo(rel) {
  if (!files) return;
  const enabled = files.entries || [];
  if (enabled.some((e) => e.dir && !e.disabled && e.path === rel)) {
    openFolder(rel, false);
    scrollToPath(rel, false);
    return;
  }
  if (enabled.some((e) => !e.dir && !e.disabled && e.path === rel)) {
    openFile(rel, false);
    scrollToPath(rel, false);
    return;
  }
  if (enabled.some((e) => e.dir && e.disabled && e.path === rel)) {
    openFolder(rel, true);
    scrollToPath(rel, true);
    return;
  }
  if (enabled.some((e) => !e.dir && e.disabled && e.path === rel)) {
    openFile(rel, true);
    scrollToPath(rel, true);
    return;
  }
  if (rel === 'module/sepolicy.rule') {
    openNewDialog({ dir: 'module', kind: 'sepolicy', name: 'sepolicy.rule' });
  } else {
    openNewDialog({ dir: rel, kind: 'aidl' });
  }
}

function scrollToPath(rel, disabled = false) {
  const row = [...document.querySelectorAll('#files-tree .ft-row')]
    .find((r) => r.dataset.path === rel && r.classList.contains('is-off') === !!disabled);
  if (row) row.scrollIntoView({ block: 'nearest' });
}

function bindFiles() {
  $('files-upload').addEventListener('click', () => pickUpload(false));
  $('files-upload-dir').addEventListener('click', () => pickUpload(true));
  $('files-new').addEventListener('click', () => openNewDialog({ kind: defaultNewKind() }));
  $('files-refresh').addEventListener('click', () => loadFiles());

  $('files-input').addEventListener('change', () => {
    const items = [...$('files-input').files].map((file) => ({ file, path: file.name }));
    uploadFiles(items);
  });
  $('files-input-dir').addEventListener('change', () => {
    const items = [...$('files-input-dir').files]
      .map((file) => ({ file, path: file.webkitRelativePath || file.name }));
    uploadFiles(items);
  });

  for (const button of document.querySelectorAll('#files-quick button')) {
    button.addEventListener('click', () => jumpTo(button.dataset.jump));
  }

  $('file-save').addEventListener('click', saveFile);
  $('file-disable').addEventListener('click', () => {
    if (filesSel) toggleEntry(filesSel.path, filesSel.disabled, filesSel.dir);
  });
  $('file-delete').addEventListener('click', () => {
    if (filesSel) deleteEntry(filesSel.path, filesSel.disabled, filesSel.dir);
  });

  $('folder-upload').addEventListener('click', () => pickUpload(false));
  $('folder-new').addEventListener('click', () => {
    openNewDialog({ dir: filesSel ? filesSel.path : filesTarget.path });
  });

  $('file-editor').addEventListener('input', () => {
    filesDirty = true;
    renderFileButtons();
    scheduleFileCheck();
  });

  $('file-new-kind').addEventListener('change', updateNewDialog);
  $('file-new-form').addEventListener('submit', createNew);
  $('file-new-cancel').addEventListener('click', () => $('file-new').close());

  $('confirm-yes').addEventListener('click', () => resolveConfirm(true));
  $('confirm-no').addEventListener('click', () => resolveConfirm(false));
  $('confirm').addEventListener('cancel', (event) => {
    event.preventDefault();
    resolveConfirm(false);
  });
  $('confirm').addEventListener('close', () => {
    if (confirmAnswer) {
      const resolve = confirmAnswer;
      confirmAnswer = null;
      resolve(false);
    }
  });

  bindFileDrop();
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
    const where = adb.source === 'tools' ? 'stuff/tools/platform-tools' : 'on PATH';
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
    const snap = await api('api/adb', {
      method: 'POST',
      body: {
        ...body,
        codename: adbValue('codename'),
        manufacturer: adbValue('manufacturer'),
      },
    });
    adbRunning = !!(snap && snap.running);
    renderRunState();
    if (body.command) pushHistory(body.command);
  } catch (err) {
    adbPrint('✗ ' + err.message);
    adbStatus(err.message, 9000);
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
    const snap = await api('api/adb/install', { method: 'POST', body: {} });
    adbRunning = !!(snap && snap.running);
    renderRunState();
    adbStatus('downloading platform-tools…', 0);
  } catch (err) {
    adbPrint('✗ ' + err.message);
    adbStatus(err.message, 9000);
  }
}

// Every property the server tried, in the order it tried them. Detecting is a
// guess — on a GSI ro.product.device names the GSI, not the phone — so the
// answer is shown with the command that produced it and the other answers are
// one click away.
let detectCandidates = [];
let detectAt = 0;

async function detectDevice() {
  try {
    adbStatus('asking the phone…', 0);
    const d = await api('api/adb/detect', { method: 'POST', body: {} });
    detectCandidates = (d.candidates || []).filter((c) => c.value);
    detectAt = 0;
    if (d.manufacturer) $('adb-manufacturer').value = d.manufacturer;
    if (detectCandidates.length) applyDetectCandidate();
    else $('detect-note').hidden = true;
    rememberAdbValues();
    renderPresets();
    adbStatus(`detected ${d.codename || 'the device'}`, 5000);
  } catch (err) {
    adbStatus(err.message, 9000);
    adbPrint('✗ ' + err.message);
  }
}

function applyDetectCandidate() {
  const note = $('detect-note');
  const pick = detectCandidates[detectAt];
  if (!pick) {
    note.hidden = true;
    return;
  }

  $('adb-codename').value = pick.value;
  rememberAdbValues();
  renderPresets();

  const source = $('detect-source');
  source.textContent = '';
  source.append(document.createTextNode('codename from '), el('code', null, pick.prop));
  if (pick.note) source.append(el('span', 'muted', ' — ' + pick.note));

  const others = detectCandidates.length - 1;
  if (others === 0) source.append(el('span', 'muted', ' · no other command answered'));
  const next = $('detect-next');
  next.hidden = others === 0;
  next.title = others
    ? `${others} other command${others === 1 ? '' : 's'} returned a value — click to use the next one`
    : '';
  note.hidden = false;
}

function nextDetectCandidate() {
  if (detectCandidates.length < 2) return;
  detectAt = (detectAt + 1) % detectCandidates.length;
  applyDetectCandidate();
}

async function extract(action) {
  try {
    adbClear();
    switchTab('device');
    adbRunning = true;
    renderRunState();
    adbStatus('pulling…', 0);
    await api('api/extract', { method: 'POST', body: { action } });
  } catch (err) {
    adbRunning = false;
    renderRunState();
    adbStatus(err.message, 8000);
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
      'They will be copied to stuff/backups/pre-update-<time>/ first, then replaced by ' +
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
  if (name === 'files') loadFiles();
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
    files = null;
    filesSel = null;
    filesTarget = { path: '', disabled: false };
    filesDirty = false;
    filesBinary = false;
    filesCheck = null;
    await refreshState(true);
    if (document.querySelector('#pane-files').classList.contains('is-active')) await loadFiles();
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

  $('chip-path').addEventListener('click', openSettings);
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
  $('detect-next').addEventListener('click', nextDetectCandidate);
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
      // A codename typed by hand is the user's answer: stop pointing at the one
      // Detect found.
      if (input.id === 'adb-codename') {
        detectCandidates = [];
        $('detect-note').hidden = true;
      }
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
      if (document.querySelector('#pane-files').classList.contains('is-active')) saveFile();
    }
    if (event.key === 'Escape') return;
  });

  window.addEventListener('beforeunload', () => { cfgRawDirty = false; });
}

(async function start() {
  bind();
  bindFiles();
  connectLog();
  connectAdbLog();
  await refreshState(true);
  if (!state || !state.cloneValid) openSettings();
  setInterval(refreshState, 20000);
})();

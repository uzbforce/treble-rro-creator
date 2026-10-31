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
// The node a repainting progress bar owns, per console: the build log and the
// adb console each draw their own in place.
const progressNode = new WeakMap();
// Where the current adb run writes: the <pre> under the preset that started it,
// or null for the console at the top of the pane.
let adbTarget = null;
// preset id -> the panel under that command, kept across the re-render every
// finished run triggers so the answer stays where the question was clicked.
const presetOut = new Map();
let currentDoc = null;
let statusTimer = null;
let refreshInFlight = false;

// A run that stopped for a sudo password keeps its verb here, so the retry is
// exactly the same command. sudoPassword is the answer; it stays in this
// window's memory for the session and is never written by the page.
let pendingRun = null;
let sudoPassword = '';
let sudoPromptOpen = false;
let sudoDeclined = false;

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

  // One job at a time: a second preset clicked mid-run would be refused by the
  // server, and the panel under the command still running would end up with the
  // refusal in it. Blocked-for-needs is remembered by renderPresets, which is
  // what reads the codename and the adb install state.
  for (const b of $('adb-presets').querySelectorAll('button.preset')) {
    if (running || adbRunning) b.disabled = true;
    else b.disabled = b.dataset.blocked === '1';
  }
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
  sudoDeclined = false;
  pendingRun = { verb: v.name, flags, label: v.label.toLowerCase() };
  await startRun(pendingRun);
}

// startRun is separate so the sudo dialog can repeat exactly the command that
// stopped for a password: same verb, same flags, now with the answer.
async function startRun(run) {
  try {
    clearLog();
    setRunning(true);
    status(`running ${run.label}…`, 0);
    const body = { verb: run.verb, flags: run.flags };
    // Only the two verbs that can install need it; check and clean never run
    // sudo, so the password does not travel with them.
    if (sudoPassword && (run.verb === 'build' || run.verb === 'setup')) body.sudo = sudoPassword;
    await api('api/run', { method: 'POST', body });
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
  // The console breathes while a job owns it (see app.css): one class, so the
  // rule that draws it has a single source and stops the moment it is false.
  document.body.classList.toggle('is-running', value);
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
    // The server's own line asking for a password: not something to print, an
    // action to take. The sentence before it already explained why.
    if (line.stream === 'sudo') {
      openSudoPrompt();
      return;
    }
    appendLine(line);
  });

  stream.addEventListener('error', () => {
    // EventSource retries on its own; the replay would duplicate, which the
    // seq check above handles.
  });
}

function renderLogLine(pre, line) {
  const stick = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;

  if (line.stream === 'progress') {
    // pacman and adb pull repaint one line with \r. Rewrite that line instead
    // of appending a row per chunk, so a download reads like a terminal.
    let live = progressNode.get(pre);
    if (!live || live.parentNode !== pre) {
      live = document.createElement('span');
      live.className = 'progress';
      pre.appendChild(live);
      progressNode.set(pre, live);
    }
    live.textContent = line.text + '\n';
    if (stick) pre.scrollTop = pre.scrollHeight;
    return false;
  }
  // Any real line ends the bar's run: the next repaint starts a new line.
  progressNode.delete(pre);

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
    // The console is the record of every run. A preset also writes a copy under
    // its own button, so the answer is where the command was clicked.
    const panel = adbTarget;
    if (line.seq <= adbSeq) {
      $('adb-console').textContent = '';
      if (panel) panel.textContent = '';
      adbSeq = 0;
    }
    adbSeq = line.seq;
    const finished = renderLogLine($('adb-console'), line);
    // The panel shows the output only: the command itself is the button above
    // it, and repeating it there was noise.
    if (panel && line.stream !== 'note') renderLogLine(panel, line);
    if (finished) {
      adbRunning = false;
      renderRunState();
      refreshState();
    }
  });
}

// Clears the shared console and points the stream back at it: a typed command
// belongs in the console, not in whichever preset ran last.
function adbClear() {
  $('adb-console').textContent = '';
  adbSeq = 0;
  adbTarget = null;
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
  const stick = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 30;
  pre.appendChild(el('span', 'err', text + '\n'));
  if (stick) pre.scrollTop = pre.scrollHeight;
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

  // Search/filter input for config entries
  const searchInput = el('input', 'filter-input');
  searchInput.type = 'text';
  searchInput.placeholder = 'Search config entries…';
  searchInput.addEventListener('input', () => {
    const term = searchInput.value.trim().toLowerCase();
    const rows = box.querySelectorAll('.cfg-row');
    for (const row of rows) {
      const text = (row.textContent || '').toLowerCase();
      row.style.display = text.includes(term) ? '' : 'none';
    }
  });
  box.insertBefore(searchInput, box.firstChild);

  const doc = state.config;
  if (!state.cloneValid || !doc || !doc.sections || doc.sections.length === 0) {
    box.appendChild(el('p', 'muted', state.cloneValid
      ? 'config.env is empty or missing — run Build once, or Clean --all to recreate it.'
      : 'Pick the clone first.'));
    return;
  }

  // Two different questions, so two cards, each beside the pair it writes: the
  // module's own condition (DEVICE_PROP_*) is the codename the phone carries,
  // and the submission pair (HW_OVERLAY_MATCH_*) is a ranking of properties.
  // One card used to serve both, and the codename answer landed in the pair a
  // section further down.
  let modulePlaced = false;
  let matchPlaced = false;
  for (const sec of doc.sections) {
    const wrap = el('div', 'cfg-sec');
    if (sec.title) wrap.appendChild(el('div', 'cfg-sec-title', sec.title));
    const entries = sec.entries || [];
    for (const entry of entries) wrap.appendChild(cfgRow(entry));
    if (!sec.title && entries.length === 0) continue;
    if (!modulePlaced && hasKey(sec, 'DEVICE_PROP_NAME')) {
      wrap.appendChild(moduleCard());
      modulePlaced = true;
    }
    // The match card belongs with the submission keys, because a wrong one is
    // the failure that looks like success: the overlay is enabled and nothing
    // changes.
    if (!matchPlaced && hasKey(sec, 'HW_OVERLAY_MATCH_PROP')) {
      wrap.appendChild(matchCard());
      matchPlaced = true;
    }
    box.appendChild(wrap);
  }
  if (!modulePlaced) box.appendChild(moduleCard());
  if (!matchPlaced) box.appendChild(matchCard());
  updateCfgStatus();
}

function hasKey(sec, key) {
  return (sec.entries || []).some((e) => e.key === key);
}

// Keys whose value is a string even when it reads like a boolean: a device name
// or a match value can be "true" today and a codename tomorrow, so those keep
// their text field.
const CFG_STRING_KEYS = new Set([
  'DEVICE_PROP_NAME', 'DEVICE_PROP_VALUE',
  'HW_OVERLAY_MATCH_PROP', 'HW_OVERLAY_MATCH_VALUE',
]);

function cfgRow(entry) {
  const row = el('div', 'cfg-row');
  row.dataset.line = String(entry.line);
  // A value of true/false is one bit, so it gets one control: the switch is the
  // value (on = true, off = false). The row is still dimmed while the line is
  // commented out; touching the switch uncomments it.
  const isBool = !CFG_STRING_KEYS.has(entry.key) &&
    (entry.value === 'true' || entry.value === 'false');
  row.classList.toggle('is-off', !entry.enabled);

  const on = document.createElement('input');
  on.type = 'checkbox';
  on.className = 'cfg-on';
  on.checked = isBool ? entry.value === 'true' : entry.enabled;
  on.title = isBool
    ? (on.checked ? 'true — click to write false' : 'false — click to write true')
    : (entry.enabled ? 'on — click to comment this line out' : 'off — click to enable');

  const key = el('code', 'cfg-key', entry.key);
  key.title = entry.key;

  // A boolean needs no text field: `true` and `false` are the switch.
  const field = isBool ? null : document.createElement('input');
  if (field) {
    field.className = 'cfg-value';
    field.value = entry.value;
    field.spellcheck = false;
    field.autocomplete = 'off';
    field.setAttribute('aria-label', entry.key);
  }

  const info = el('button', 'cfg-info', 'i');
  info.type = 'button';
  info.setAttribute('aria-expanded', 'false');
  const comment = entry.comment || [];
  info.disabled = comment.length === 0;
  info.title = comment.length ? 'What this setting does' : 'the file has no note for this one';

  const note = el('p', 'cfg-info-text', comment.join('\n'));
  note.hidden = true;

  const sync = () => {
    const next = isBool ? (on.checked ? 'true' : 'false') : field.value;
    // For a boolean the switch cannot also mean "commented out", so any change
    // there makes the line active.
    const enabled = isBool ? true : on.checked;
    const changed = isBool
      ? (next !== entry.value || !entry.enabled)
      : (next !== entry.value || on.checked !== entry.enabled);
    row.classList.toggle('is-dirty', changed);
    row.classList.toggle('is-off', isBool ? (!entry.enabled && !changed) : !on.checked);
    if (changed) {
      cfgEdits.set(entry.line, {
        line: entry.line,
        key: entry.key,
        value: next,
        enabled,
      });
    } else {
      cfgEdits.delete(entry.line);
    }
    updateCfgStatus();
  };

  on.addEventListener('change', sync);
  if (field) field.addEventListener('input', sync);
  info.addEventListener('click', () => {
    note.hidden = !note.hidden;
    info.setAttribute('aria-expanded', String(!note.hidden));
  });

  // ⓘ leads the row: it is the first thing to reach for when a setting is
  // unfamiliar, and a leading column keeps every row's ⓘ in the same place.
  row.append(info, on, key, ...(field ? [field] : []), note);
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

// ---------------------------------------------------- module condition --
// The module's condition is the codename the phone carries, not a property
// ranking: the module writes persist.sys.overlay.<codename> at boot, so it
// always matches. Detect reads the codename off the phone; Use stages
// DEVICE_PROP_NAME / DEVICE_PROP_VALUE and nothing else. The submission pair
// is a separate question with its own card further down.
let moduleDetect = null;
let moduleError = '';
let moduleBusy = false;
let moduleBodyEl = null;

const MODULE_PROP_PREFIX = 'persist.sys.overlay.';

// Both detectors ask the same phone the same way, so the frame is built once.
function detectorCard(title, keys, hint) {
  const card = el('div', 'cfg-match');
  const head = el('div', 'cfg-match-head');
  head.appendChild(el('span', 'cfg-match-title', title));
  head.appendChild(el('span', 'muted small', keys));

  const pick = document.createElement('select');
  pick.className = 'adb-device-select cfg-match-device';
  pick.setAttribute('aria-label', 'phone to ask');

  const ask = document.createElement('button');
  ask.type = 'button';
  ask.textContent = 'Ask the phone';

  head.append(pick, ask);
  card.appendChild(head);
  card.appendChild(el('p', 'hint', hint));
  return { card, pick, ask };
}

function moduleCard() {
  const { card, pick, ask } = detectorCard(
    'Module condition',
    'DEVICE_PROP_NAME / _VALUE',
    'The codename this phone carries. The module sets persist.sys.overlay.<codename> before zygote, so a wrong codename is what makes it skip this phone.'
  );
  pick.addEventListener('change', () => {
    setAdbDevice(pick.value);
    // One phone per answer: the last phone's codename must not stay on screen
    // looking like it belongs to the new one.
    moduleDetect = null;
    moduleError = '';
    renderAdbDevices();
    refreshModuleBody();
  });
  ask.addEventListener('click', askModuleProp);
  card.appendChild(moduleBody());
  renderAdbDevices();
  if (!adbDevices.length) refreshAdbDevices().then(() => renderAdbDevices());
  return card;
}

// Same trap as the match card: moduleBody() reassigns moduleBodyEl while it
// builds, so the node being replaced has to be captured first.
function refreshModuleBody() {
  const old = moduleBodyEl;
  if (!old || !old.isConnected) return;
  old.replaceWith(moduleBody());
}

function moduleBody() {
  const body = el('div', 'cfg-match-body');
  moduleBodyEl = body;

  if (moduleBusy) {
    body.appendChild(el('p', 'muted small', 'asking the phone…'));
    return body;
  }
  if (moduleError) body.appendChild(el('p', 'cfg-match-error', moduleError));

  if (!moduleDetect) {
    const prop = cfgEntry('DEVICE_PROP_NAME');
    const value = cfgEntry('DEVICE_PROP_VALUE');
    if (prop && prop.value) {
      body.appendChild(el('p', 'muted small',
        `config.env activates on ${prop.value} = "${value && value.value ? value.value : ''}"${prop.enabled ? '' : ' — that line is commented out'}.`));
    } else {
      body.appendChild(el('p', 'muted small',
        'No condition is set, so the module would activate on every phone — only right when that is what you mean.'));
    }
    return body;
  }

  const answers = (moduleDetect.candidates || []).filter((c) => c.value);
  const summary = el('div', 'cfg-match-summary');
  summary.appendChild(el('span', 'muted small', 'codename '));
  summary.appendChild(el('code', null, moduleDetect.codename || 'not found'));
  if (moduleDetect.model) summary.appendChild(el('span', 'muted small', ' · ' + moduleDetect.model));
  if (answers.length > 1) summary.appendChild(el('span', 'cfg-match-badge trust-medium', `${answers.length} commands answered`));
  body.appendChild(summary);

  if (!answers.length) {
    body.appendChild(el('p', 'cfg-match-warn',
      'No property on this phone carries its codename — it may be an unnamed build. Set the condition by hand in the row above.'));
    return body;
  }

  for (const c of answers) body.appendChild(moduleRow(c));
  if (answers.length > 1) {
    body.appendChild(el('p', 'muted small',
      'All of these are on the phone; the first is the one usually trusted on a GSI. Only the pair above changes — Save writes it.'));
  }
  return body;
}

function moduleRow(c) {
  const row = el('div', 'cfg-match-row');
  const head = el('div', 'cfg-match-row-head');
  head.appendChild(el('code', 'cfg-match-prop', MODULE_PROP_PREFIX + c.value));
  head.appendChild(el('span', 'cfg-match-eq', '='));
  head.appendChild(el('code', 'cfg-match-val', '"true"'));

  const use = document.createElement('button');
  use.type = 'button';
  use.textContent = 'Use';
  use.addEventListener('click', () => useModuleCodename(c));
  head.appendChild(use);

  row.appendChild(head);
  row.appendChild(el('p', 'cfg-match-why', `codename from ${c.prop}${c.note ? ' — ' + c.note : ''}`));
  return row;
}

async function askModuleProp() {
  if (moduleBusy) return;
  await refreshAdbDevices();
  const pick = adbDeviceChoice();
  if (pick.blocked) {
    moduleError = `${adbReadyDevices().length} phones are connected — pick one beside the button`;
    refreshModuleBody();
    return;
  }
  if (!pick.serial && !adbReadyDevices().length) {
    moduleError = 'No phone is ready — plug one in and allow USB debugging.';
    refreshModuleBody();
    return;
  }
  moduleBusy = true;
  moduleError = '';
  refreshModuleBody();
  try {
    moduleDetect = await api('api/adb/detect', { method: 'POST', body: { serial: pick.serial } });
  } catch (err) {
    moduleDetect = null;
    moduleError = err.message;
  } finally {
    moduleBusy = false;
    refreshModuleBody();
  }
}

// Writes the module pair only — never the submission pair.
function useModuleCodename(c) {
  const prop = MODULE_PROP_PREFIX + c.value;
  const name = stageCfgValue('DEVICE_PROP_NAME', prop);
  const value = stageCfgValue('DEVICE_PROP_VALUE', 'true');
  if (!name || !value) {
    status('config.env has no DEVICE_PROP_* lines — add them in the raw editor', 9000);
    return;
  }
  const row = document.querySelector(`#cfg-fields .cfg-row[data-line="${(cfgEntry('DEVICE_PROP_NAME') || {}).line}"]`);
  if (row) row.scrollIntoView({ block: 'center' });
  status(`staged DEVICE_PROP_NAME = "${prop}" and DEVICE_PROP_VALUE = "true" — Save writes them`, 9000);
}

// ------------------------------------------------------- match property --
// The one mistake in this file that looks like success: a match condition the
// framework never satisfies. The overlay installs, `cmd overlay list` prints
// [x], and no resource changes. The phone can answer most of it — which
// properties carry its codename, which partition each one comes from, and
// whether zygote can read that SELinux area — so the ranking is read from the
// device and using a row only stages the two lines, which Save writes.
let matchReport = null;
let matchError = '';
let matchBusy = false;
let matchBodyEl = null;

function cfgEntry(key) {
  for (const sec of (state.config && state.config.sections) || []) {
    for (const entry of sec.entries || []) {
      if (entry.key === key) return entry;
    }
  }
  return null;
}

function matchCard() {
  const { card, pick, ask } = detectorCard(
    'Submission match',
    'HW_OVERLAY_MATCH_PROP / _VALUE',
    'Which property the submission ships this overlay to. A property only works if zygote can read it and the value survives what is installed — the two things that make an overlay show as enabled and do nothing.'
  );
  pick.addEventListener('change', () => {
    setAdbDevice(pick.value);
    // The ranking is about one phone: switching phones must not leave the last
    // phone's answer on screen looking like it belongs to the new one.
    matchReport = null;
    matchError = '';
    renderAdbDevices();
    refreshMatchBody();
  });
  ask.addEventListener('click', askMatchProp);
  card.appendChild(matchBody());
  renderAdbDevices();
  // First paint of the form can happen before the device list has ever been
  // fetched; fill the picker as soon as it arrives.
  if (!adbDevices.length) refreshAdbDevices().then(() => renderAdbDevices());
  return card;
}

// matchBody() assigns the new node to matchBodyEl as it builds it, so the node
// being replaced has to be captured first — replacing matchBodyEl with itself
// after that is a no-op and the answer never reaches the screen.
function refreshMatchBody() {
  const old = matchBodyEl;
  if (!old || !old.isConnected) return;
  old.replaceWith(matchBody());
}

function trustLabel(trust) {
  if (trust === 'high') return 'fits';
  if (trust === 'medium') return 'partial';
  return 'risky';
}

function confidenceLabel(confidence) {
  if (confidence === 'high') return 'safe pick';
  if (confidence === 'medium') return 'no perfect pick';
  return 'nothing usable';
}

function matchBody() {
  const body = el('div', 'cfg-match-body');
  matchBodyEl = body;

  if (matchBusy) {
    body.appendChild(el('p', 'muted small', 'asking the phone…'));
    return body;
  }
  if (matchError) body.appendChild(el('p', 'cfg-match-error', matchError));

  if (!matchReport) {
    const cur = { prop: cfgEntry('HW_OVERLAY_MATCH_PROP'), value: cfgEntry('HW_OVERLAY_MATCH_VALUE') };
    if (cur.prop && cur.prop.value) {
      body.appendChild(el('p', 'muted small',
        `config.env matches on ${cur.prop.value} == "${cur.value ? cur.value.value : ''}"${cur.prop.enabled ? '' : ' — that line is commented out'}.`));
    } else {
      body.appendChild(el('p', 'muted small', 'No match property is set: the submission would be always active, which is only right for a device that has no name to match.'));
    }
    return body;
  }

  const rep = matchReport;
  const summary = el('div', 'cfg-match-summary');
  summary.appendChild(el('span', 'muted small', 'codename '));
  summary.appendChild(el('code', null, rep.codename || 'not found'));
  if (rep.model) summary.appendChild(el('span', 'muted small', ' · ' + rep.model));
  summary.appendChild(el('span', 'cfg-match-badge trust-' + rep.confidence, confidenceLabel(rep.confidence)));
  body.appendChild(summary);

  // A match condition that does not hold is invisible: the overlay enables and
  // changes nothing. So unless a property satisfies every rule, the honest
  // answer is the one that already works — the module's own property.
  if (rep.confidence !== 'high') body.appendChild(keepCurrentNote(rep));

  const rows = rep.candidates || [];
  for (const c of rows.slice(0, 3)) body.appendChild(matchRow(c));
  if (rows.length > 3) {
    const more = document.createElement('details');
    const rest = rows.length - 3;
    more.appendChild(el('summary', 'muted small', `${rest} more candidate${rest === 1 ? '' : 's'}`));
    for (const c of rows.slice(3)) more.appendChild(matchRow(c));
    body.appendChild(more);
  }

  if ((rep.rejected || []).length) {
    const ruled = document.createElement('details');
    ruled.appendChild(el('summary', 'muted small', `${rep.rejected.length} propert${rep.rejected.length === 1 ? 'y' : 'ies'} ruled out`));
    for (const r of rep.rejected) {
      ruled.appendChild(el('p', 'cfg-match-rejected', `${r.prop} = ${r.value} — ${r.reason}`));
    }
    body.appendChild(ruled);
  }

  if (rep.moduleProp) {
    body.appendChild(el('p', 'muted small',
      `The module's own condition stays ${rep.moduleProp} = true: the module sets that property at boot, so it cannot fail to match.`));
  }
  return body;
}

// "Use what already works": the property the module sets itself, which cannot
// fail to match because the module writes it at boot. Shown whenever no property
// on the phone satisfies every rule.
function keepCurrentNote(rep) {
  const box = el('p', 'cfg-match-warn');
  const current = (((cfgEntry('DEVICE_PROP_NAME') || {}).value || rep.moduleProp || '')).trim();

  box.appendChild(el('b', null, 'Keep the match you already have. '));
  box.appendChild(document.createTextNode(rep.confidence === 'low'
    ? 'Nothing on this phone carries its codename in a property the framework will read, so none of these is a safe pick. '
    : 'No property here is both readable by zygote and left alone by a GSI, so none of these is a safer bet than what already works. '));
  if (current) {
    box.appendChild(document.createTextNode('Leave '));
    box.appendChild(el('code', null, 'DEVICE_PROP_NAME'));
    box.appendChild(document.createTextNode(' as '));
    box.appendChild(el('code', null, current));
    box.appendChild(document.createTextNode(' — the module sets that property itself, so it always matches. '));
  }
  box.appendChild(document.createTextNode('The rows below are only for a submission that ships without the module; check the one you pick with cmd overlay lookup after flashing.'));
  return box;
}

function matchRow(c) {
  const row = el('div', 'cfg-match-row');
  const head = el('div', 'cfg-match-row-head');
  head.appendChild(el('code', 'cfg-match-prop', c.prop));
  head.appendChild(el('span', 'cfg-match-eq', '='));
  head.appendChild(el('code', 'cfg-match-val', `"${c.value}"`));
  head.appendChild(el('span', 'cfg-match-badge trust-' + c.trust, trustLabel(c.trust)));

  const use = document.createElement('button');
  use.type = 'button';
  use.textContent = 'Use';
  use.addEventListener('click', () => useMatch(c));
  head.appendChild(use);

  row.appendChild(head);
  row.appendChild(el('p', 'cfg-match-why', c.why || ''));
  if (c.risk) row.appendChild(el('p', 'cfg-match-risk', '⚠ ' + c.risk));
  return row;
}

async function askMatchProp() {
  if (matchBusy) return;
  await refreshAdbDevices();
  const pick = adbDeviceChoice();
  if (pick.blocked) {
    matchError = `${adbReadyDevices().length} phones are connected — pick one beside the button`;
    refreshMatchBody();
    return;
  }
  if (!pick.serial && !adbReadyDevices().length) {
    matchError = 'No phone is ready — plug one in and allow USB debugging.';
    refreshMatchBody();
    return;
  }
  matchBusy = true;
  matchError = '';
  refreshMatchBody();
  try {
    matchReport = await api('api/adb/match-prop', { method: 'POST', body: { serial: pick.serial } });
  } catch (err) {
    matchReport = null;
    matchError = err.message;
  } finally {
    matchBusy = false;
    refreshMatchBody();
  }
}

// Stages one config line the way the row itself would, so the change shows up in
// the form and Save sends it. Nothing is written to disk here.
function stageCfgValue(key, value) {
  const entry = cfgEntry(key);
  if (!entry) return false;
  const row = document.querySelector(`#cfg-fields .cfg-row[data-line="${entry.line}"]`);
  if (!row) return false;
  const on = row.querySelector('.cfg-on');
  const input = row.querySelector('.cfg-value');
  // The match keys are strings; a boolean row has no text field to stage.
  if (!input) return false;
  input.value = value;
  if (on && !on.checked) {
    on.checked = true;
    on.dispatchEvent(new Event('change'));
  }
  input.dispatchEvent(new Event('input'));
  row.classList.add('is-flash');
  setTimeout(() => row.classList.remove('is-flash'), 1500);
  return true;
}

function useMatch(c) {
  const prop = stageCfgValue('HW_OVERLAY_MATCH_PROP', c.prop);
  const value = stageCfgValue('HW_OVERLAY_MATCH_VALUE', c.value);
  if (!prop || !value) {
    status('config.env has no HW_OVERLAY_MATCH_* lines — add them in the raw editor', 9000);
    return;
  }
  const row = document.querySelector(`#cfg-fields .cfg-row[data-line="${(cfgEntry('HW_OVERLAY_MATCH_PROP') || {}).line}"]`);
  if (row) row.scrollIntoView({ block: 'center' });
  status(`staged ${c.prop} = "${c.value}" — Save writes it`, 9000);
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
    openDialog($('confirm'));
    $('confirm-no').focus();
  });
}

function resolveConfirm(answer) {
  const resolve = confirmAnswer;
  confirmAnswer = null;
  closeDialog($('confirm'));
  if (resolve) resolve(answer);
}

// ------------------------------------------------------------------- sudo --
// toolchain.sh says it could install the tools if something could ask for a
// password; the server turns that into this dialog. The password is posted with
// the retry and handed to sudo -A for that run only.
function openSudoPrompt() {
  if (!pendingRun || sudoPromptOpen || sudoDeclined) return;
  sudoPromptOpen = true;
  $('sudo-error').hidden = true;
  if (sudoPassword) {
    $('sudo-error').textContent = 'sudo could not install with the last password — try again.';
    $('sudo-error').hidden = false;
  }
  $('sudo-password').value = '';
  openDialog($('sudo'));
  $('sudo-password').focus();
}

async function submitSudo(event) {
  event.preventDefault();
  const password = $('sudo-password').value;
  if (!password) {
    $('sudo-error').textContent = 'enter the password sudo would ask for';
    $('sudo-error').hidden = false;
    return;
  }
  sudoPassword = password;
  closeDialog($('sudo'));
  if (pendingRun) await startRun(pendingRun);
}

function cancelSudo() {
  sudoDeclined = true;
  closeDialog($('sudo'));
  status('install skipped — the build tools are still missing', 6000);
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
  openDialog($('file-new'));
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
      closeDialog($('file-new'));
      await loadFiles();
      openFolder(rel, false);
      fileStatus('created src/' + rel + '/', 4000);
      return;
    }
    const text = fileTemplate(kind, name);
    await api('api/files/write', { method: 'POST', body: { path: rel, text } });
    closeDialog($('file-new'));
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
  $('file-new-cancel').addEventListener('click', () => closeDialog($('file-new')));

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

  $('sudo-form').addEventListener('submit', submitSudo);
  $('sudo-cancel').addEventListener('click', cancelSudo);
  $('sudo').addEventListener('cancel', (event) => {
    // Esc: same as Cancel, so the prompt cannot leave a retry half-armed.
    event.preventDefault();
    cancelSudo();
  });
  $('sudo').addEventListener('close', () => {
    sudoPromptOpen = false;
    $('sudo-password').value = '';
  });

  bindFileDrop();
}

// -------------------------------------------------------------------- docs --
function renderDocsNav() {
  const nav = $('docs-nav');
  nav.textContent = '';

  // Search/filter input for docs
  const searchInput = el('input', 'filter-input');
  searchInput.type = 'text';
  searchInput.placeholder = 'Search docs…';
  const noMatch = el('p', 'filter-empty', 'No docs match your search.');
  noMatch.hidden = true;
  searchInput.addEventListener('input', () => {
    const term = searchInput.value.trim().toLowerCase();
    const buttons = nav.querySelectorAll('button');
    for (const b of buttons) {
      const text = b.textContent.toLowerCase();
      b.style.display = !term || text.includes(term) ? '' : 'none';
    }
    // The message is a sibling: rewriting nav.textContent here would remove the
    // input too, leaving no way to clear a search that matched nothing.
    noMatch.hidden = [...buttons].some((b) => b.style.display !== 'none');
  });
  nav.append(searchInput, noMatch);

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

// More than one phone on the desk: adb has no default device and refuses to
// guess, and neither does the page. /api/adb/devices lists them, the picker
// picks one, and every request carries that serial — the scripts take
// --device for the same reason. One phone stays automatic, so the common case
// needs no clicks.
let adbDevices = [];
let adbDevice = localStorage.getItem('adb.device') || '';
let adbDevicesFetch = null;

function adbReadyDevices() {
  return adbDevices.filter((d) => d.state === 'device');
}

// The serial a device-mode request should send, and the reason it cannot start.
function adbDeviceChoice() {
  const ready = adbReadyDevices();
  if (adbDevice && ready.some((d) => d.serial === adbDevice)) return { serial: adbDevice, blocked: '' };
  if (ready.length === 1) return { serial: ready[0].serial, blocked: '' };
  if (ready.length <= 1) return { serial: '', blocked: '' };
  return { serial: '', blocked: `${ready.length} devices are connected — pick one in the device list` };
}

function setAdbDevice(serial) {
  adbDevice = serial || '';
  if (adbDevice) localStorage.setItem('adb.device', adbDevice);
  else localStorage.removeItem('adb.device');
}

// Redraws every picker (Device, Detect, UDFPS) from the one list.
function renderAdbDevices() {
  const ready = adbReadyDevices();
  const pick = adbDeviceChoice();
  // A remembered phone that is gone must not quietly point at another one.
  if (adbDevice && !ready.some((d) => d.serial === adbDevice)) setAdbDevice('');

  for (const sel of document.querySelectorAll('select.adb-device-select')) {
    sel.textContent = '';
    if (!ready.length) {
      const opt = document.createElement('option');
      opt.value = '';
      opt.textContent = adbDevices.length ? 'no device is ready' : 'no device connected';
      sel.appendChild(opt);
      sel.disabled = true;
      continue;
    }
    if (!pick.serial && ready.length > 1) {
      const opt = document.createElement('option');
      opt.value = '';
      opt.textContent = 'choose a device…';
      sel.appendChild(opt);
    }
    for (const d of ready) {
      const opt = document.createElement('option');
      opt.value = d.serial;
      opt.textContent = `${d.label} — ${d.serial}`;
      sel.appendChild(opt);
    }
    sel.disabled = ready.length === 1;
    sel.value = pick.serial || '';
  }

  const note = $('adb-device-note');
  const others = adbDevices.length - ready.length;
  if (!ready.length) note.textContent = others ? `${others} attached but not ready` : '';
  else if (ready.length === 1) note.textContent = others ? `${others} other attached but not ready` : 'the only connected phone';
  else note.textContent = pick.serial ? 'commands go to this phone' : 'pick the phone to command';
  note.title = adbDevices.map((d) => `${d.serial} — ${d.label} (${d.state})`).join('\n');

  renderPresets();
  renderRunState();
}

async function refreshAdbDevices() {
  if (adbDevicesFetch) return adbDevicesFetch;
  if (!adbReady()) {
    adbDevices = [];
    renderAdbDevices();
    return;
  }
  adbDevicesFetch = api('api/adb/devices')
    .then((res) => {
      adbDevices = (res && res.devices) || [];
    })
    .catch((err) => {
      adbDevices = [];
      $('adb-device-note').textContent = err.message;
      $('adb-device-note').title = err.message;
    })
    .finally(() => { adbDevicesFetch = null; });
  await adbDevicesFetch;
  renderAdbDevices();
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
  const blocked = adbDeviceChoice().blocked;
  $('adb-input').disabled = !adb.available;
  $('adb-detect').disabled = !adb.available || !!blocked;
  $('adb-detect').title = blocked;
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
      // "adb devices" is about the tool; every other preset is about one phone.
      const noDevice = p.id === 'devices' ? '' : adbDeviceChoice().blocked;
      const blocked = !adbReady() || missing.length > 0 || !!noDevice;
      // renderRunState re-disables these from the stored reason while a build
      // or another adb command owns the one job slot.
      b.dataset.blocked = blocked ? '1' : '';
      b.disabled = blocked || running || adbRunning;
      if (running || adbRunning) b.title = 'a command is already running — one job at a time';
      else if (noDevice) b.title = noDevice;
      else if (missing.length) b.title = `needs ${missing.join(' and ')} — fill it in above`;
      else b.title = p.why;

      b.dataset.preset = p.id;
      b.addEventListener('click', () => runAdb({ preset: p.id }));
      sec.appendChild(b);
      // Output from an earlier click is re-attached here: renderPresets runs
      // again after every run, and the panel belongs under its own command.
      const out = presetOut.get(p.id);
      if (out) sec.appendChild(out.node);
    }
    box.appendChild(sec);
  }
  applyPresetFilter();
}

// The panel a preset's output goes into: the text, a Copy, and a Hide that
// folds the text away without throwing it out. The map keeps the same nodes, so
// a re-render or a Hide never loses lines that already streamed in.
function presetPanel(id) {
  let out = presetOut.get(id);
  if (out) return out;

  const pre = el('pre', 'preset-log');
  pre.setAttribute('aria-live', 'polite');

  const copy = el('button', 'primary', 'Copy');
  copy.type = 'button';
  copy.title = 'Copy this output';
  copy.addEventListener('click', async () => {
    const text = pre.textContent;
    if (!text) return;
    try {
      await navigator.clipboard.writeText(text);
      copy.textContent = 'Copied';
      setTimeout(() => { copy.textContent = 'Copy'; }, 1400);
    } catch (_) {
      // No clipboard to write to: select the text so Ctrl+C still does what the
      // button promised.
      const range = document.createRange();
      range.selectNodeContents(pre);
      const sel = window.getSelection();
      sel.removeAllRanges();
      sel.addRange(range);
      copy.textContent = 'Ctrl+C';
    }
  });

  const toggle = el('button', null, 'Hide');
  toggle.type = 'button';
  toggle.title = 'Fold this output away';

  // Controls first, at the left edge: they are a short reach from the command
  // above, whatever the length of the answer below them.
  const node = el('div', 'preset-out');
  const bar = el('div', 'preset-out-bar');
  bar.append(toggle, copy);
  node.append(bar, pre);

  out = { node, pre, toggle, copy, hidden: false };
  toggle.addEventListener('click', () => {
    out.hidden = !out.hidden;
    pre.hidden = out.hidden;
    // Nothing to copy out of sight: Copy comes back with the text.
    copy.hidden = out.hidden;
    toggle.textContent = out.hidden ? 'Show' : 'Hide';
    toggle.title = out.hidden ? 'Show this output again' : 'Fold this output away';
  });
  presetOut.set(id, out);
  return out;
}

// Shows the panel for a preset about to run and points the stream at it. The
// button is looked up rather than captured: renderPresets replaces the buttons,
// never the panel.
function startPresetOutput(id) {
  const out = presetPanel(id);
  out.pre.textContent = '';
  out.hidden = false;
  out.pre.hidden = false;
  out.copy.hidden = false;
  out.toggle.textContent = 'Hide';
  out.toggle.title = 'Fold this output away';
  if (!out.node.isConnected) {
    const button = document.querySelector(`#adb-presets button.preset[data-preset="${id}"]`);
    if (button) button.after(out.node);
  }
  out.node.scrollIntoView({ block: 'nearest' });
  adbTarget = out.pre;
  adbSeq = 0;
  return out;
}

// The filter input sits outside #adb-presets, so re-rendering the list (Detect,
// a saved codename) keeps whatever was typed. A group with no matching command
// goes away with its heading.
function applyPresetFilter() {
  const input = $('adb-search');
  if (!input) return;
  const term = input.value.trim().toLowerCase();
  for (const sec of $('adb-presets').querySelectorAll('.preset-group')) {
    let shown = 0;
    for (const b of sec.querySelectorAll('button.preset')) {
      const hit = !term || b.textContent.toLowerCase().includes(term);
      b.style.display = hit ? '' : 'none';
      // The output panel is a sibling of its button, so it has to follow it out
      // of the filter — otherwise a hidden command keeps a visible answer.
      const out = presetOut.get(b.dataset.preset);
      if (out) out.node.style.display = hit ? '' : 'none';
      if (hit) shown += 1;
    }
    sec.style.display = shown ? '' : 'none';
  }
}

async function runAdb(body) {
  const presetId = body.preset || '';
  const pick = adbDeviceChoice();
  if (pick.blocked && presetId && presetId !== 'devices') {
    adbStatus(pick.blocked, 9000);
    return;
  }
  try {
    if (presetId) {
      // The console's last run is not this run, and this run's answer belongs
      // under the command that was clicked.
      $('adb-console').textContent = '';
      startPresetOutput(presetId);
    } else {
      adbClear();
    }
    const snap = await api('api/adb', {
      method: 'POST',
      body: {
        ...body,
        serial: pick.serial,
        codename: adbValue('codename'),
        manufacturer: adbValue('manufacturer'),
      },
    });
    adbRunning = !!(snap && snap.running);
    renderRunState();
    if (body.command) pushHistory(body.command);
  } catch (err) {
    // The failure belongs where the user is looking: under the command that did
    // not start, or in the console for a typed one.
    if (presetId) {
      const pre = startPresetOutput(presetId).pre;
      pre.appendChild(el('span', 'err', '✗ ' + err.message + '\n'));
    }
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
  refreshAdbDevices();
}

// Every property the server tried, in the order it tried them. Detecting is a
// guess — on a GSI ro.product.device names the GSI, not the phone — so the
// answer is shown with the command that produced it and the other answers are
// one click away.
let detectCandidates = [];
let detectAt = 0;

async function detectDevice() {
  const pick = adbDeviceChoice();
  if (pick.blocked) {
    adbStatus(pick.blocked, 9000);
    return;
  }
  try {
    adbStatus('asking the phone…', 0);
    const d = await api('api/adb/detect', { method: 'POST', body: { serial: pick.serial } });
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
  if ($('update').showModal) openDialog($('update'));

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
    // The file list and the clash warning describe a pull that has just
    // happened: keeping them above the result buries what the update actually
    // did, and the head line was still counting commits that no longer exist.
    $('upd-files').hidden = true;
    $('upd-files-label').hidden = true;
    $('upd-clash').hidden = true;
    $('upd-head').textContent = `updated${u.upstream ? ' from ' + u.upstream : ''}`;

    $('upd-output').hidden = false;
    $('upd-output').textContent = (res.output || 'updated') +
      (res.backedUp && res.backedUp.length ? '\n\nbacked up:\n' + res.backedUp.join('\n') : '') +
      (res.restart ? '\n\nThe app itself changed — close this window and start it again (treble-rro-creator.sh / treble-rro-creator.cmd) to run the new version. The build scripts are already the new ones.' : '');
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

// ------------------------------------------------------------------- udfps --
// The probe is a script (stuff/scripts/udfps-probe.sh) that answers in JSON;
// this side only draws the answers and writes the one the user picks. Every row
// keeps its source visible, because "540, 2198, 89" means nothing without
// knowing which property or overlay it came from.
let udfpsReport = null;
let udfpsPick = -1;
let udfpsFirmware = null; // what the path turned out to be, when it was a ROM image

// firmwareLine says what the path was: a bare image the app unpacked, or a tree
// that was already readable. The probe's own answer is the folder it scanned.
function firmwareLine(fw, scanned) {
  if (!fw) return 'Scanned ' + (scanned || 'the folder');
  if (!fw.unpacked) return 'Read ' + (scanned || fw.dir) + ' (already unpacked)';
  const parts = ['Unpacked ' + shortName(fw.source)];
  if (fw.partitions) {
    const ok = fw.partitions.filter((p) => p.fs !== '?').length;
    parts.push(ok + ' partition' + (ok === 1 ? '' : 's'));
  }
  if (fw.kept) parts.push(fw.kept + ' files');
  if (fw.cached) parts.push('from the cache');
  return parts.join(' · ') + ' — scanned ' + (scanned || fw.dir);
}

function shortName(p) {
  if (!p) return '';
  const bits = String(p).split(/[\\/]/);
  return bits[bits.length - 1] || p;
}

// The firmware path fields open the platform's own chooser, because the page
// cannot turn a file picker into a path: a webview hands the script a File, and
// the scan needs a path the unpacker can open — a 9 GB super.img is not going
// to be uploaded to find out where it is. An empty answer is the user closing
// the dialog, so the field keeps whatever was typed.
async function choosePath(button, field, kind) {
  if (button.disabled) return;
  button.disabled = true;
  try {
    const res = await api('api/pick', { method: 'POST', body: { kind, start: $(field).value.trim() } });
    if (res && res.path) {
      $(field).value = res.path;
      $(field).focus();
    }
  } catch (err) {
    status(err.message, 6000);
  } finally {
    button.disabled = false;
  }
}

async function probeUDFPS(mode) {
  const buttons = [$('udfps-detect'), $('udfps-scan')];
  for (const b of buttons) b.disabled = true;
  const pick = adbDeviceChoice();
  if (mode !== 'firmware' && pick.blocked) {
    for (const b of buttons) b.disabled = false;
    $('udfps-summary').textContent = pick.blocked;
    return;
  }
  $('udfps-results').hidden = false;
  $('udfps-rows').textContent = '';
  $('udfps-warnings').textContent = '';
  $('udfps-notes').textContent = '';
  $('udfps-detail').textContent = '';
  $('udfps-applied').textContent = '';
  $('udfps-files-fold').hidden = true;
  $('udfps-log').hidden = true;
  $('udfps-apply').disabled = true;
  udfpsReport = null;
  udfpsPick = -1;
  udfpsFirmware = null;
  $('udfps-summary').textContent = mode === 'firmware' ? 'reading the firmware…' : 'asking the phone…';

  try {
    const res = await api('api/udfps', {
      method: 'POST',
      body: {
        action: 'probe',
        mode,
        serial: pick.serial,
        path: mode === 'firmware' ? $('udfps-path').value.trim() : '',
      },
    });
    udfpsReport = res.report;
    udfpsFirmware = res.firmware || null;
    renderUDFPS(res.log);
  } catch (err) {
    $('udfps-summary').textContent = 'nothing came back: ' + err.message;
    const log = (err.data && err.data.log) || '';
    if (log) {
      $('udfps-log').hidden = false;
      $('udfps-log').textContent = log;
    }
  } finally {
    for (const b of buttons) b.disabled = false;
  }
}

function renderUDFPS(log) {
  const r = udfpsReport;
  const tbody = $('udfps-rows');
  tbody.textContent = '';

  if (r.mode === 'firmware') {
    $('udfps-summary').textContent = firmwareLine(udfpsFirmware, r.firmware);
  } else if (r.device) {
    const d = r.device;
    const parts = [
      d.model || 'unknown device',
      d.codename ? '(' + d.codename + ')' : '',
      d.width && d.height ? d.width + '×' + d.height + ' px' : '',
      d.rom || '',
    ];
    $('udfps-summary').textContent = parts.filter(Boolean).join(' · ');
  }

  if (!r.candidates.length) {
    const tr = el('tr');
    const td = el('td', 'muted', 'No source answered — read the notes below.');
    td.colSpan = 6;
    tr.appendChild(td);
    tbody.appendChild(tr);
  }

  const chosen = r.chosen;
  r.candidates.forEach((c, i) => {
    if (udfpsPick < 0 && chosen && c.source === chosen.source && c.kind === chosen.kind) {
      udfpsPick = i;
    }
    const tr = el('tr');
    if (i === udfpsPick) tr.classList.add('is-picked');

    const radioCell = el('td');
    const radio = el('input');
    radio.type = 'radio';
    radio.name = 'udfps-pick';
    radio.checked = i === udfpsPick;
    radio.addEventListener('change', () => selectUDFPS(i));
    radioCell.appendChild(radio);

    tr.appendChild(radioCell);
    tr.appendChild(el('td', 'udfps-source', c.source));
    tr.appendChild(el('td', 'num', String(c.x)));
    tr.appendChild(el('td', 'num', String(c.y)));
    tr.appendChild(el('td', 'num', 'r=' + c.radius));
    tr.appendChild(el('td', 'udfps-conf ' + c.confidence, c.confidence));
    tr.title = c.detail || '';
    tr.addEventListener('click', () => {
      radio.checked = true;
      selectUDFPS(i);
    });
    tbody.appendChild(tr);
  });

  if (udfpsPick < 0 && r.candidates.length) udfpsPick = 0;
  selectUDFPS(udfpsPick);

  const warnings = $('udfps-warnings');
  for (const w of r.warnings || []) warnings.appendChild(el('p', 'warn', w));
  const notes = $('udfps-notes');
  for (const n of r.notes || []) notes.appendChild(el('p', 'muted small', n));

  if ((r.files || []).length) {
    const list = $('udfps-files');
    list.textContent = '';
    for (const f of r.files) {
      const row = el('div', 'udfps-file');
      row.appendChild(el('code', '', f.path));
      row.appendChild(el('span', 'muted small', f.role || ''));
      list.appendChild(row);
    }
    $('udfps-files-fold').hidden = false;
  }

  if (log) {
    $('udfps-log').hidden = false;
    $('udfps-log').textContent = log;
  }
}

function selectUDFPS(i) {
  const r = udfpsReport;
  if (!r || !r.candidates.length) return;
  udfpsPick = i;
  const rows = $('udfps-rows').querySelectorAll('tr');
  rows.forEach((tr, n) => {
    tr.classList.toggle('is-picked', n === i && r.candidates[n] !== undefined);
  });
  const c = r.candidates[i];
  $('udfps-detail').textContent = c.detail || '';
  $('udfps-apply').disabled = false;
  $('udfps-applied').textContent = '';
}

async function applyUDFPS() {
  const r = udfpsReport;
  const c = r && r.candidates[udfpsPick];
  if (!c) return;
  $('udfps-apply').disabled = true;
  try {
    await api('api/udfps', { method: 'POST', body: { action: 'apply', x: c.x, y: c.y, radius: c.radius } });
    // config.env changed on disk: repaint the form so the Config tab agrees.
    await refreshState(true);
    $('udfps-applied').textContent = 'written to config.env: ' + c.x + ' / ' + c.y + ' / r=' + c.radius;
    status('UDFPS values saved to config.env', 4000);
  } catch (err) {
    $('udfps-applied').textContent = 'not written: ' + err.message;
  } finally {
    $('udfps-apply').disabled = false;
  }
}

// ------------------------------------------------------------------ detect --
// device-probe.sh answers in JSON; every row keeps its source, because "135"
// means nothing without knowing whether dumpsys, a framework resource or an
// OEM overlay said it. Several rows can carry the same setting: those are the
// sources that disagree, and exactly one of them is written per setting.
let detectReport = null;
let detectPick = {}; // setting -> index of the fact that will be written
let detectFirmware = null; // what the path turned out to be, when it was a ROM image

async function probeDetect(mode) {
  const buttons = [$('detect-run'), $('detect-scan')];
  for (const b of buttons) b.disabled = true;
  const pick = adbDeviceChoice();
  if (mode !== 'firmware' && pick.blocked) {
    for (const b of buttons) b.disabled = false;
    $('detect-summary').textContent = pick.blocked;
    return;
  }
  $('detect-results').hidden = false;
  $('detect-rows').textContent = '';
  $('detect-warnings').textContent = '';
  $('detect-notes').textContent = '';
  $('detect-detail').textContent = '';
  $('detect-applied').textContent = '';
  $('detect-files-fold').hidden = true;
  $('detect-log').hidden = true;
  $('detect-apply').disabled = true;
  detectReport = null;
  detectPick = {};
  detectFirmware = null;
  $('detect-summary').textContent = mode === 'firmware' ? 'reading the firmware…' : 'asking the phone…';

  try {
    const res = await api('api/detect', {
      method: 'POST',
      body: {
        action: 'probe',
        mode,
        serial: pick.serial,
        path: mode === 'firmware' ? $('detect-path').value.trim() : '',
      },
    });
    detectReport = res.report;
    detectFirmware = res.firmware || null;
    renderDetect(res.log);
  } catch (err) {
    $('detect-summary').textContent = 'nothing came back: ' + err.message;
    const log = (err.data && err.data.log) || '';
    if (log) {
      $('detect-log').hidden = false;
      $('detect-log').textContent = log;
    }
  } finally {
    for (const b of buttons) b.disabled = false;
  }
}

function renderDetect(log) {
  const r = detectReport;
  const tbody = $('detect-rows');
  tbody.textContent = '';

  if (r.mode === 'firmware') {
    $('detect-summary').textContent = firmwareLine(detectFirmware, r.firmware);
  } else if (r.device) {
    const d = r.device;
    const parts = [
      d.model || 'unknown device',
      d.codename ? '(' + d.codename + ')' : '',
      d.width && d.height ? d.width + '×' + d.height + ' px' : '',
      d.density ? d.density + ' dpi' : '',
      d.rom || '',
      d.isGsi ? 'GSI' : '',
    ];
    $('detect-summary').textContent = parts.filter(Boolean).join(' · ');
  }

  if (!r.facts.length) {
    const tr = el('tr');
    const td = el('td', 'muted', 'No source answered — read the notes below.');
    td.colSpan = 5;
    tr.appendChild(td);
    tbody.appendChild(tr);
  }

  // The first row for a setting is its highest-priority source; a second row
  // means two sources disagree, so only one may be ticked.
  detectPick = {};
  r.facts.forEach((f, i) => {
    if (!(f.key in detectPick) && f.confidence !== 'low') detectPick[f.key] = i;

    const tr = el('tr');
    tr.dataset.i = String(i);

    const boxCell = el('td');
    const box = el('input');
    box.type = 'checkbox';
    box.checked = detectPick[f.key] === i;
    box.addEventListener('change', () => {
      if (box.checked) detectPick[f.key] = i;
      else if (detectPick[f.key] === i) delete detectPick[f.key];
      syncDetectPicks();
    });
    boxCell.appendChild(box);

    tr.appendChild(boxCell);
    tr.appendChild(el('td', 'udfps-source', f.key));
    const shown = f.value.length > 60 ? f.value.slice(0, 59) + '…' : f.value;
    tr.appendChild(el('td', 'num', shown + (f.unit ? ' ' + f.unit : '')));
    tr.appendChild(el('td', 'udfps-source', f.source));
    tr.appendChild(el('td', 'udfps-conf ' + f.confidence, f.confidence));
    tr.title = f.detail || '';
    tr.addEventListener('click', (event) => {
      if (event.target !== box) {
        box.checked = true;
        detectPick[f.key] = i;
        syncDetectPicks();
      }
      $('detect-detail').textContent = f.detail || '';
    });
    tbody.appendChild(tr);
  });

  syncDetectPicks();

  const warnings = $('detect-warnings');
  for (const w of r.warnings || []) warnings.appendChild(el('p', 'warn', w));
  const notes = $('detect-notes');
  for (const n of r.notes || []) notes.appendChild(el('p', 'muted small', n));

  if ((r.files || []).length) {
    const list = $('detect-files');
    list.textContent = '';
    for (const f of r.files) {
      const row = el('div', 'udfps-file');
      row.appendChild(el('code', '', f.path));
      row.appendChild(el('span', 'muted small', f.role || ''));
      list.appendChild(row);
    }
    $('detect-files-fold').hidden = false;
  }

  if (log) {
    $('detect-log').hidden = false;
    $('detect-log').textContent = log;
  }
}

function syncDetectPicks() {
  if (!detectReport) return;
  for (const tr of $('detect-rows').querySelectorAll('tr[data-i]')) {
    const i = Number(tr.dataset.i);
    const f = detectReport.facts[i];
    if (!f) continue;
    const box = tr.querySelector('input');
    box.checked = detectPick[f.key] === i;
    tr.classList.toggle('is-picked', box.checked);
  }
  const keys = Object.keys(detectPick);
  $('detect-apply').disabled = keys.length === 0;
  if (keys.length) {
    $('detect-detail').textContent = keys.length + ' setting(s) ticked: ' + keys.join(', ');
  }
}

async function applyDetect() {
  if (!detectReport) return;
  const values = {};
  for (const key of Object.keys(detectPick)) {
    values[key] = detectReport.facts[detectPick[key]].value;
  }
  $('detect-apply').disabled = true;
  try {
    await api('api/detect', { method: 'POST', body: { action: 'apply', values } });
    // config.env changed on disk: repaint the form so the Config tab agrees.
    await refreshState(true);
    $('detect-applied').textContent = 'written to config.env: ' + Object.keys(values).join(', ');
    status('Display values saved to config.env', 4000);
  } catch (err) {
    $('detect-applied').textContent = 'not written: ' + err.message;
  } finally {
    $('detect-apply').disabled = Object.keys(detectPick).length === 0;
  }
}

// The power profile is a file rather than a value, so it has its own actions:
// read (device or folder) returns the converted XML, and save writes it to the
// source tree after the user has seen it.
let powerXML = '';

async function readPower(mode) {
  const buttons = [$('power-read'), $('power-folder')];
  for (const b of buttons) b.disabled = true;
  const pick = adbDeviceChoice();
  if (mode !== 'firmware' && pick.blocked) {
    for (const b of buttons) b.disabled = false;
    $('power-summary').textContent = pick.blocked;
    return;
  }
  $('power-save').disabled = true;
  $('power-saved').textContent = '';
  $('power-summary').textContent = mode === 'firmware' ? 'reading the folder…' : 'asking the phone…';

  try {
    const res = await api('api/detect', {
      method: 'POST',
      body: {
        action: 'power',
        mode,
        serial: pick.serial,
        path: mode === 'firmware' ? $('detect-path').value.trim() : '',
      },
    });
    const p = res.profile;
    powerXML = p.xml;
    $('power-preview').hidden = false;
    $('power-preview').textContent = p.xml;
    $('power-summary').textContent =
      p.items + ' entries from ' + (p.source || 'the ROM') +
      (res.log ? ' · ' + res.log : '');
    $('power-save').disabled = false;
  } catch (err) {
    powerXML = '';
    $('power-summary').textContent = 'nothing came back: ' + err.message;
    const log = (err.data && err.data.log) || '';
    if (log) {
      $('power-preview').hidden = false;
      $('power-preview').textContent = log;
    }
  } finally {
    for (const b of buttons) b.disabled = false;
  }
}

async function savePower() {
  if (!powerXML) return;
  $('power-save').disabled = true;
  try {
    const res = await api('api/detect', {
      method: 'POST',
      body: { action: 'power-save', xml: powerXML },
    });
    await refreshState(true);
    $('power-saved').textContent = 'written: ' + res.path + ' (' + res.items + ' entries)';
    status('power_profile.xml saved', 4000);
  } catch (err) {
    $('power-saved').textContent = 'not written: ' + err.message;
    $('power-save').disabled = false;
  }
}

// ----------------------------------------------------------------- addons --
// An addon is a tweak the module owns: a Settings value it writes on the phone
// (the volume panel side, the screen timeout) or, for the overlay addons, a
// resource the build bakes into the APK. The catalog and the rules live in
// src/webui/addons.sh, so this pane is only a form over it: what it saves is
// src/module/addons.conf, the file the build packs, the module applies the live
// ones from at every boot, and resources.sh reads the overlay ones from.
let addonDoc = null;          // GET api/addons: the helper's own JSON
let addonPicks = {};          // id -> the value the control shows
let addonSaved = {};          // id -> the value already in the file
const addonStateLines = new Map();    // id -> the row's state line
const addonDefaultBtns = new Map();   // id -> the "back to the default" link

function takeAddonDoc(doc) {
  addonDoc = doc;
  addonPicks = {};
  addonSaved = {};
  addonStateLines.clear();
  addonDefaultBtns.clear();
  for (const a of doc.addons || []) {
    addonPicks[a.id] = a.value;
    if (a.saved) addonSaved[a.id] = a.value;
  }
  renderAddons();
  updateAddons();
}

async function loadAddons() {
  try {
    takeAddonDoc(await api('api/addons'));
  } catch (err) {
    addonDoc = null;
    addonPicks = {};
    addonSaved = {};
    addonStateLines.clear();
    addonDefaultBtns.clear();
    const box = $('addons-list');
    box.textContent = '';
    box.appendChild(el('p', 'hint', 'Could not read the addons: ' + err.message));
    $('addons-save').disabled = true;
    $('addons-status').textContent = '';
  }
}

function renderAddons() {
  const box = $('addons-list');
  box.textContent = '';
  const list = (addonDoc && addonDoc.addons) || [];
  if (!list.length) {
    box.appendChild(el('p', 'hint',
      'This clone has no addon catalog (src/webui/addons.sh) — update it with git pull.'));
    return;
  }

  for (const a of list) {
    const row = el('div', 'addon-row');
    row.dataset.id = a.id;

    const main = el('div', 'addon-main');
    main.appendChild(el('span', 'addon-label', a.label));
    main.appendChild(el('code', 'addon-key', a.id));
    if (a.kind === 'overlay') main.appendChild(el('span', 'addon-tag', 'overlay'));
    main.appendChild(el('p', 'addon-summary', a.summary));
    row.appendChild(main);

    const side = el('div', 'addon-side');
    // "Remove" for a single addon: back to the default, so the line leaves the
    // file and the module stops enforcing it. The control keeps the default
    // value, so it can be chosen again (and saved) whenever it is wanted.
    const defBtn = el('button', 'link addon-default', 'default');
    defBtn.type = 'button';
    defBtn.title = a.kind === 'overlay'
      ? 'stop baking this into the APK — back to the ROM default'
      : 'hand this value back to the ROM — back to the default';
    defBtn.addEventListener('click', () => {
      addonPicks[a.id] = a.default;
      renderAddons();
      updateAddons();
    });
    side.appendChild(defBtn);
    addonDefaultBtns.set(a.id, defBtn);

    if (a.choices.length === 2 && a.choices[0] === 'on' && a.choices[1] === 'off') {
      // on/off is a switch: it is the same control the config form uses for a
      // boolean line, so it reads the same way in both places.
      const wrap = el('label', 'addon-switch');
      const sw = document.createElement('input');
      sw.type = 'checkbox';
      sw.className = 'cfg-on';
      sw.checked = addonPicks[a.id] === 'on';
      sw.title = sw.checked ? 'on — click to turn off' : 'off — click to turn on';
      sw.addEventListener('change', () => {
        addonPicks[a.id] = sw.checked ? 'on' : 'off';
        sw.title = sw.checked ? 'on — click to turn off' : 'off — click to turn on';
        updateAddons();
      });
      wrap.appendChild(sw);
      side.appendChild(wrap);
    } else {
      const pick = document.createElement('select');
      for (const choice of a.choices) {
        const opt = document.createElement('option');
        opt.value = choice;
        opt.textContent = choice;
        pick.appendChild(opt);
      }
      pick.value = addonPicks[a.id];
      pick.setAttribute('aria-label', a.label);
      pick.addEventListener('change', () => {
        addonPicks[a.id] = pick.value;
        updateAddons();
      });
      side.appendChild(pick);
    }

    const line = el('span', 'addon-state');
    addonStateLines.set(a.id, line);
    side.appendChild(line);

    row.appendChild(side);
    box.appendChild(row);
  }
}

function updateAddons() {
  const list = (addonDoc && addonDoc.addons) || [];
  let dirty = 0;
  for (const a of list) {
    const saved = addonSaved[a.id];
    const pick = addonPicks[a.id];
    const changed = pick !== (saved || a.default);
    if (changed) dirty += 1;

    const row = document.querySelector(`.addon-row[data-id="${a.id}"]`);
    if (row) row.classList.toggle('is-dirty', changed);

    const defBtn = addonDefaultBtns.get(a.id);
    if (defBtn) defBtn.hidden = !saved && pick === a.default;

    const line = addonStateLines.get(a.id);
    if (!line) continue;
    const bits = [saved ? 'saved' : 'default'];
    if (a.kind === 'overlay') {
      // No phone value to compare: an overlay addon exists only once the build
      // has baked it into the APK.
      bits.push('next build');
      line.textContent = bits.join(' · ');
      line.dataset.diff = 'false';
      continue;
    }
    const phone = addonDoc.device === 'yes' && a.live;
    if (phone) bits.push('phone: ' + a.live);
    line.textContent = bits.join(' · ');
    // Highlighted only when a *saved* addon is not what the phone resolves:
    // that is the module saying it did not apply it. An unsaved addon whose
    // phone value differs from the default is just the phone's own setting.
    line.dataset.diff = saved && phone && a.live !== saved ? 'true' : 'false';
  }

  $('addons-save').disabled = dirty === 0;
  $('addons-status').textContent = dirty
    ? `${dirty} unsaved change${dirty === 1 ? '' : 's'}`
    : (addonDoc && addonDoc.conf === 'yes'
        ? 'saved in src/module/addons.conf — the next build packs it'
        : 'nothing chosen — the module changes nothing');
}

async function saveAddons() {
  const values = {};
  for (const a of (addonDoc && addonDoc.addons) || []) values[a.id] = addonPicks[a.id];
  $('addons-save').disabled = true;
  try {
    takeAddonDoc(await api('api/addons/save', { method: 'POST', body: { values } }));
  } catch (err) {
    $('addons-status').textContent = 'not saved: ' + err.message;
    $('addons-save').disabled = false;
  }
}

async function clearAddons() {
  $('addons-clear').disabled = true;
  try {
    takeAddonDoc(await api('api/addons/save', { method: 'POST', body: { reset: true } }));
  } catch (err) {
    $('addons-status').textContent = 'not cleared: ' + err.message;
  } finally {
    $('addons-clear').disabled = false;
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
  if (name === 'device') {
    renderAdb();
    refreshAdbDevices();
  }
  if (name === 'detect' || name === 'udfps' || name === 'config') refreshAdbDevices();
  if (name === 'config') renderConfig();
  if (name === 'addons') loadAddons();
  if (name === 'files') loadFiles();
}

// ------------------------------------------------------------------ dialog --
// A dialog grows out of the control that opened it and travels to the middle
// of the window. Only the browser knows where it will land, so the start point
// is measured after showModal: the button's centre, relative to the dialog's,
// and a scale that fits the dialog inside that button. Without a button (a
// dialog the app opens for itself) the plain centred fade in app.css is used.
function openDialog(dlg, from) {
  // Focus moves into the dialog on showModal, so the trigger is read first.
  const trigger = from || document.activeElement;
  // Reopened while its exit was still playing: drop the exit and start over.
  if (dlg.classList.contains('is-closing')) {
    dlg.classList.remove('is-closing', 'from-control');
    dlg.close();
  }
  if (dlg.open) return; // showModal() throws on an open dialog; the fields still repaint
  dlg.classList.remove('from-control');
  dlg.showModal();
  const box = trigger && trigger.getBoundingClientRect ? trigger.getBoundingClientRect() : null;
  // A body-sized or empty rect means the dialog was not opened from a control.
  if (!box || !box.width || box.width > window.innerWidth * .8) return;
  const d = dlg.getBoundingClientRect();
  const dx = (box.left + box.width / 2) - (d.left + d.width / 2);
  const dy = (box.top + box.height / 2) - (d.top + d.height / 2);
  const s = Math.min(.8, Math.max(.35, (box.width + box.height) / (d.width + d.height)));
  dlg.style.setProperty('--from-x', Math.round(dx) + 'px');
  dlg.style.setProperty('--from-y', Math.round(dy) + 'px');
  dlg.style.setProperty('--from-s', s.toFixed(3));
  dlg.classList.add('from-control');
}

// Leaving: the same measured start point played backwards, so a dialog that
// flew out of a button goes back into it. The dialog is still open while it
// animates; closeDialog() calls the real close() once the card has left, which
// is what the 'close' listeners that reset state wait for.
const DIALOG_OUT_MS = 260;

function closeDialog(dlg, value) {
  if (!dlg || !dlg.open || dlg.classList.contains('is-closing')) return;

  const finish = () => {
    dlg.removeEventListener('animationend', onEnd);
    dlg.classList.remove('is-closing', 'from-control');
    if (dlg.open) dlg.close(value);
  };
  const onEnd = (event) => {
    if (event.target === dlg) finish();
  };

  // With motion turned down there is nothing to wait for, and a window that is
  // not painting animations would otherwise leave the dialog stuck open.
  if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    finish();
    return;
  }
  // Closed while it was still flying in: an exit would restart from the middle
  // and jump, so this one just goes.
  const arriving = dlg.getAnimations && dlg.getAnimations().some(
    (a) => a.playState === 'running' &&
      (a.animationName === 'dialog-fly' || a.animationName === 'dialog-in')
  );
  if (arriving) {
    finish();
    return;
  }
  dlg.classList.add('is-closing');
  dlg.addEventListener('animationend', onEnd);
  setTimeout(finish, DIALOG_OUT_MS + 160); // longer than the CSS animation, as a backstop
}

function openSettings() {
  $('set-clone').value = state ? state.clone : '';
  $('set-bash').value = state ? state.bash : '';
  $('set-error').hidden = true;
  openDialog($('settings'));
}

async function saveSettings(event) {
  event.preventDefault();
  const clone = $('set-clone').value.trim();
  const bash = $('set-bash').value.trim();
  try {
    state = await api('api/settings', { method: 'POST', body: { clone, bash } });
    closeDialog($('settings'));
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
  // A button inside <summary> must not also toggle the fold it is closing.
  $('hide-out').addEventListener('click', (event) => {
    event.preventDefault();
    event.stopPropagation();
    $('out-fold').open = false;
  });
  $('stop').addEventListener('click', stopRun);
  $('log-clear').addEventListener('click', clearLog);
  $('open-out').addEventListener('click', () => {
    api('api/open', { method: 'POST', body: { target: 'out' } }).catch((e) => status(e.message, 6000));
  });

  $('chip-path').addEventListener('click', openSettings);
  $('settings-form').addEventListener('submit', saveSettings);
  $('set-save').addEventListener('click', saveSettings);

  $('chip-update').addEventListener('click', openUpdate);

  // Esc goes through the animated close as well. The dialogs that give a
  // cancel its own meaning (the delete question, the sudo prompt) keep their
  // own handlers: they run too, and set the answer before the card has left.
  for (const dlg of document.querySelectorAll('dialog')) {
    dlg.addEventListener('cancel', (event) => {
      event.preventDefault();
      closeDialog(dlg);
    });
  }
  $('set-cancel').addEventListener('click', () => closeDialog($('settings')));
  $('upd-later').addEventListener('click', () => closeDialog($('update')));
  $('upd-go').addEventListener('click', (event) => {
    event.preventDefault();
    if ($('upd-go').dataset.done === '1') {
      closeDialog($('update'));
      return;
    }
    runUpdate();
  });

  $('addons-save').addEventListener('click', saveAddons);
  $('addons-clear').addEventListener('click', clearAddons);

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

  $('adb-refresh').addEventListener('click', () => {
    refreshState(true);
    refreshAdbDevices();
  });
  $('adb-devices-reload').addEventListener('click', () => refreshAdbDevices());
  for (const sel of document.querySelectorAll('select.adb-device-select')) {
    sel.addEventListener('change', () => {
      setAdbDevice(sel.value);
      renderAdbDevices();
    });
  }
  // Clear the text, not the run: the stream keeps writing and a preset's panel
  // keeps its copy.
  $('adb-clear').addEventListener('click', () => { $('adb-console').textContent = ''; });
  $('adb-install').addEventListener('click', installAdb);
  $('adb-detect').addEventListener('click', detectDevice);
  $('adb-search').addEventListener('input', applyPresetFilter);
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

  $('detect-pick').addEventListener('click', () => choosePath($('detect-pick'), 'detect-path', 'file'));
  $('detect-pick-dir').addEventListener('click', () => choosePath($('detect-pick-dir'), 'detect-path', 'folder'));
  $('detect-run').addEventListener('click', () => probeDetect('device'));
  $('detect-scan').addEventListener('click', () => probeDetect('firmware'));
  $('detect-apply').addEventListener('click', applyDetect);
  $('power-read').addEventListener('click', () => readPower('device'));
  $('power-folder').addEventListener('click', () => readPower('firmware'));
  $('power-save').addEventListener('click', savePower);
  $('detect-path').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') probeDetect('firmware');
  });

  $('udfps-pick').addEventListener('click', () => choosePath($('udfps-pick'), 'udfps-path', 'file'));
  $('udfps-pick-dir').addEventListener('click', () => choosePath($('udfps-pick-dir'), 'udfps-path', 'folder'));
  $('udfps-detect').addEventListener('click', () => probeUDFPS('device'));
  $('udfps-scan').addEventListener('click', () => probeUDFPS('firmware'));
  $('udfps-apply').addEventListener('click', applyUDFPS);
  $('udfps-path').addEventListener('keydown', (event) => {
    if (event.key === 'Enter') probeUDFPS('firmware');
  });

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
  await refreshAdbDevices();
  if (!state || !state.cloneValid) openSettings();
  setInterval(refreshState, 20000);
})();

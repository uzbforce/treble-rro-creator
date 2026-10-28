// ---------------------------------------------------------------------------
// src/webui/addons.sh — the module's addon helper
// ---------------------------------------------------------------------------
// The addons are Settings values the module writes on the phone, so the failure
// that matters is a *silent* one: a choice saved but never applied, or a value
// applied on every boot that nobody asked for. The fake `settings` below is the
// phone, so both cases can be checked here instead of by flashing.
//
// Run: node --test stuff/tests/addons-sh.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import {
  chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const script = join(root, 'src', 'webui', 'addons.sh');
const template = join(root, 'src', 'module', 'addons.conf');

// Git Bash reads a backslash as an escape, so every path handed to the script
// (which is POSIX sh on every platform) is written with forward slashes.
const posix = (p) => p.replace(/\\/g, '/');

// The shipped file is also where the desktop app writes the user's picks, so a
// developer's clone often has active lines in it. These tests are about the
// script, so each one starts from the same comment-only file a fresh clone
// ships.
const pristineConf = () => readFileSync(template, 'utf8')
  .split(/\r?\n/).filter((line) => !/^[A-Za-z]/.test(line)).join('\n');

// The module as it is installed: webroot/addons.sh next to addons.conf.
function moduleTree() {
  const dir = mkdtempSync(join(tmpdir(), 'addons-sh-'));
  mkdirSync(join(dir, 'mod', 'webroot'), { recursive: true });
  copyFileSync(script, join(dir, 'mod', 'webroot', 'addons.sh'));
  writeFileSync(join(dir, 'mod', 'addons.conf'), pristineConf());
  fakeSettings(dir);
  return dir;
}

// One flat file is the whole "device": `settings put` overwrites a key, `get`
// answers null for a key that was never written — exactly what Android does.
function fakeSettings(dir) {
  const bin = join(dir, 'bin');
  mkdirSync(bin, { recursive: true });
  const path = join(bin, 'settings');
  writeFileSync(path, `#!/bin/sh
k="$2/$3"
case "$1" in
  get)
    v=$(awk -F= -v k="$k" '$1==k {print $2}' "$FAKE_SETTINGS_STORE" 2>/dev/null)
    [ -n "$v" ] && echo "$v" || echo null ;;
  put)
    touch "$FAKE_SETTINGS_STORE"
    grep -v "^$k=" "$FAKE_SETTINGS_STORE" > "$FAKE_SETTINGS_STORE.new" 2>/dev/null
    mv "$FAKE_SETTINGS_STORE.new" "$FAKE_SETTINGS_STORE" 2>/dev/null
    echo "$k=$4" >> "$FAKE_SETTINGS_STORE" ;;
  *) exit 1 ;;
esac
`);
  chmodSync(path, 0o755);
  return path;
}

function run(dir, args, opts = {}) {
  const settings = join(dir, 'bin', 'settings');
  try {
    const out = execFileSync('sh', [posix(join(dir, 'mod', 'webroot', 'addons.sh')), ...args], {
      cwd: dir,
      encoding: 'utf8',
      env: {
        ...process.env,
        ADDONS_SETTINGS: posix(settings),
        ADDONS_STATE_DIR: posix(join(dir, 'state')),
        FAKE_SETTINGS_STORE: posix(join(dir, 'store.txt')),
        ...opts.env,
      },
    });
    return { code: 0, out };
  } catch (e) {
    return { code: e.status, out: `${e.stdout || ''}${e.stderr || ''}` };
  }
}

const conf = (dir) => readFileSync(join(dir, 'mod', 'addons.conf'), 'utf8');
const values = (dir) =>
  conf(dir).split(/\r?\n/).filter((l) => /^[A-Za-z]/.test(l)).sort();
const store = (dir) => {
  try {
    return readFileSync(join(dir, 'store.txt'), 'utf8');
  } catch {
    return '';
  }
};

test('list is JSON the page can parse, and a comment-only file enforces nothing', () => {
  const dir = moduleTree();
  const { code, out } = run(dir, ['list']);
  assert.equal(code, 0);
  const doc = JSON.parse(out);
  assert.equal(doc.conf, 'no', 'the shipped template must not count as saved values');
  assert.equal(doc.device, 'yes', 'the fake settings command stands in for the phone');
  assert.ok(doc.addons.length >= 5);
  for (const a of doc.addons) {
    assert.match(a.id, /^[a-z0-9_]+$/);
    assert.ok(a.choices.includes(a.value), `${a.id}: ${a.value} is not one of its choices`);
    assert.ok(a.choices.includes(a.default), `${a.id}: default is not a choice`);
    assert.equal(a.saved, false);
    assert.equal(a.summary.includes('|'), false, 'a pipe would break the catalog line');
    assert.ok(['setting', 'overlay'].includes(a.kind), `${a.id}: kind is ${a.kind}`);
  }
  const ids = doc.addons.map((a) => a.id);
  assert.deepEqual(ids, [...new Set(ids)], 'ids must be unique');
  const overlay = doc.addons.filter((a) => a.kind === 'overlay').map((a) => a.id);
  assert.deepEqual(overlay,
    ['any_rotation', 'nav_bar_padding', 'status_bar_background', 'hide_notch'],
    'these four are resources the build emits, not settings');
});

test('only deviations are written, and setting one back to its default drops it', () => {
  const dir = moduleTree();
  assert.equal(run(dir, ['set', 'volume_panel=left', 'status_clock=off']).code, 0);
  assert.deepEqual(values(dir), ['status_clock=off', 'volume_panel=left']);
  // volume_panel: left is 1, right is 0.
  assert.match(store(dir), /secure\/volume_panel_on_left=1/);
  assert.match(store(dir), /secure\/icon_blacklist=clock/);

  // back to the default: the value is restored now, but no longer pinned
  assert.equal(run(dir, ['set', 'volume_panel=right']).code, 0);
  assert.deepEqual(values(dir), ['status_clock=off']);
  assert.match(store(dir), /secure\/volume_panel_on_left=0/);
  assert.equal(JSON.parse(run(dir, ['list']).out).conf, 'yes');
});

test('hiding the clock edits icon_blacklist instead of replacing it', () => {
  const dir = moduleTree();
  // The list already hides another icon: that entry is not this addon's to drop.
  writeFileSync(join(dir, 'store.txt'), 'secure/icon_blacklist=rotate\n');
  assert.equal(run(dir, ['set', 'status_clock=off']).code, 0);
  assert.match(store(dir), /secure\/icon_blacklist=rotate,clock/);

  // Back to the default: the clock returns, the other entry stays.
  assert.equal(run(dir, ['set', 'status_clock=on']).code, 0);
  assert.match(store(dir), /secure\/icon_blacklist=rotate$/m);
  assert.deepEqual(values(dir), []);

  // Reset is allowed to put the clock back too, again without touching rotate.
  assert.equal(run(dir, ['set', 'status_clock=off']).code, 0);
  assert.equal(run(dir, ['reset']).code, 0);
  assert.match(store(dir), /secure\/icon_blacklist=rotate$/m);
});

test('a bad id or value is refused and changes nothing', () => {
  const dir = moduleTree();
  const bad = run(dir, ['set', 'volume_panel=sideways']);
  assert.equal(bad.code, 1);
  assert.match(bad.out, /volume_panel: 'sideways' is not one of/);
  const unknown = run(dir, ['set', 'not_an_addon=on']);
  assert.equal(unknown.code, 1);
  assert.match(unknown.out, /no such addon/);
  assert.deepEqual(values(dir), []);
  assert.equal(store(dir), '');
});

test('apply is what the boot runs: saved values only, and exit 0', () => {
  const dir = moduleTree();
  run(dir, ['set', 'stay_awake=on', 'status_clock=off']);
  writeFileSync(join(dir, 'store.txt'), '');  // a fresh boot: nothing applied yet

  const boot = run(dir, ['apply']);
  assert.equal(boot.code, 0);
  assert.match(boot.out, /\+ stay_awake=on/);
  assert.match(boot.out, /\+ status_clock=off/);
  // The largest int a Setting can hold: about 24 days, i.e. until power-off.
  assert.match(store(dir), /system\/screen_off_timeout=2147483647/);
  assert.match(store(dir), /secure\/icon_blacklist=clock/);
});

test('a value the device rejects is reported as saved but not live', () => {
  const dir = moduleTree();
  run(dir, ['set', 'volume_panel=left']);
  // A settings command that accepts the write but keeps the old value: this is
  // what a restricted namespace looks like from here.
  writeFileSync(join(dir, 'bin', 'settings'), '#!/bin/sh\n[ "$1" = get ] && { echo null; exit 0; }\nexit 0\n');
  chmodSync(join(dir, 'bin', 'settings'), 0o755);
  const applied = run(dir, ['apply']);
  assert.equal(applied.code, 1);
  assert.match(applied.out, /volume_panel: the device still reports 'unset'/);
});

test('reset hands every live addon back and keeps the comments', () => {
  const dir = moduleTree();
  run(dir, ['set', 'volume_panel=left', 'stay_awake=on']);
  assert.equal(run(dir, ['reset']).code, 0);
  assert.deepEqual(values(dir), []);
  assert.match(conf(dir), /^# Module addons/m);
  assert.match(store(dir), /secure\/volume_panel_on_left=0/);
  assert.match(store(dir), /system\/screen_off_timeout=60000/);
  assert.equal(JSON.parse(run(dir, ['list']).out).conf, 'no');
  assert.equal(run(dir, ['reset']).code, 0, 'reset with nothing saved is not an error');
});

test('reset and save work on a desktop, where there is no settings command', () => {
  const dir = moduleTree();
  const noPhone = { env: { ADDONS_SETTINGS: '/nonexistent/settings' } };
  const saved = run(dir, ['set', 'volume_panel=left', 'any_rotation=on'], noPhone);
  assert.equal(saved.code, 0, 'saving must not fail just because no phone is attached');
  assert.deepEqual(values(dir), ['any_rotation=on', 'volume_panel=left']);
  // There is no APK to leave alone on a desktop: Clear all is the build choice.
  const cleared = run(dir, ['reset'], noPhone);
  assert.equal(cleared.code, 0);
  assert.deepEqual(values(dir), []);
});

test('an overlay addon is saved for the build, never written to Settings', () => {
  const dir = moduleTree();
  assert.equal(run(dir, ['set', 'any_rotation=on', 'nav_bar_padding=off',
    'status_bar_background=off', 'hide_notch=on']).code, 0);
  assert.deepEqual(values(dir), ['any_rotation=on', 'hide_notch=on',
    'nav_bar_padding=off', 'status_bar_background=off']);
  assert.equal(store(dir), '', 'only a rebuilt APK can apply these');
  const doc = JSON.parse(run(dir, ['list']).out);
  for (const a of doc.addons.filter((x) => x.kind === 'overlay')) {
    assert.equal(a.saved, true);
    assert.equal(a.live, '', 'a resource has no live value to read back');
  }
  // `apply` at boot must skip them instead of reporting a put that never ran.
  const boot = run(dir, ['apply']);
  assert.equal(boot.code, 0);
  assert.equal(boot.out.trim(), '');
});

test('reset on the phone keeps the overlay addons it is running', () => {
  const dir = moduleTree();
  run(dir, ['set', 'volume_panel=left', 'nav_bar_padding=off']);
  const reset = run(dir, ['reset']);
  assert.equal(reset.code, 0);
  assert.deepEqual(values(dir), ['nav_bar_padding=off'],
    'the flashed APK still has it; only a rebuild can undo that');
  assert.match(reset.out, /overlay addons stay as they are/);
});

test('a line from an older catalog is ignored at boot and pruned by reset', () => {
  const dir = moduleTree();
  const file = join(dir, 'mod', 'addons.conf');
  writeFileSync(file, `${readFileSync(file, 'utf8')}\nanimations=fast\n`);
  const boot = run(dir, ['apply']);
  assert.equal(boot.code, 0, 'an addon that no longer exists must not fail the boot');
  assert.equal(store(dir), '');
  assert.equal(run(dir, ['reset']).code, 0);
  assert.deepEqual(values(dir), []);
});

test('restore-conf keeps the rebuild\'s own choices and carries the rest over', () => {
  const dir = moduleTree();
  // The previous install had both of these; only one of them was changed on
  // the phone after it was flashed.
  run(dir, ['set', 'volume_panel=left', 'captive_portal=off']);
  // The new zip names its own choice for one addon and says nothing about the
  // other, which nobody touched in the app.
  writeFileSync(join(dir, 'mod', 'addons.conf'),
    `${pristineConf()}volume_panel=right\n`);
  assert.equal(run(dir, ['restore-conf']).code, 0);
  assert.deepEqual(values(dir), ['captive_portal=off', 'volume_panel=right'],
    'the new build wins for what it names; the saved file fills the gaps');
});

test('restore-conf brings the saved file back after a reinstall', () => {
  const dir = moduleTree();
  run(dir, ['set', 'captive_portal=off']);
  // The update replaced the module directory with the shipped file (which
  // names nothing here, so the whole saved file comes back).
  writeFileSync(join(dir, 'mod', 'addons.conf'), pristineConf());
  assert.deepEqual(values(dir), []);
  const restored = run(dir, ['restore-conf']);
  assert.equal(restored.code, 0);
  assert.deepEqual(values(dir), ['captive_portal=off']);
});

// The overlay addons are resources, so the build is where they happen. This runs
// the same generators build.sh runs, against a throwaway module directory.
function generateResources(confText) {
  const dir = mkdtempSync(join(tmpdir(), 'addons-res-'));
  const mod = join(dir, 'mod');
  const out = join(dir, 'res');
  mkdirSync(mod, { recursive: true });
  for (const sub of ['framework/values', 'framework/values-land', 'systemui/values']) {
    mkdirSync(join(out, sub), { recursive: true });
  }
  writeFileSync(join(mod, 'addons.conf'), confText);
  // MODULE_DIR is set after common.sh: that is what normalises the paths.
  const gen = `
set -eo pipefail
ROOT="$1"; MOD="$2"; OUT="$3"
export ROOT
source "$ROOT/stuff/scripts/common.sh"
MODULE_DIR="$MOD"; RES_DIR="$OUT/framework"; SYSUI_RES_DIR="$OUT/systemui"
ROUNDED_CORNER_RADIUS=100
STATUS_BAR_HEIGHT=76
STATUS_BAR_HEIGHT_LANDSCAPE=24
DISPLAY_CUTOUT="M 0,0 H -29 V 118 H 29 V 0 H 0 Z"
HAS_UDFPS=false; HAS_AOD=true; HAS_DOZE=false; HAS_AUTO_BRIGHTNESS=false
HAS_BURN_IN_PROTECTION=false; HAS_DOUBLE_TAP_WAKE=false; HAS_HBM=false
HAS_5G=false; HAS_VOLTE=false
source "$ROOT/stuff/scripts/resources.sh"
generate_resource_xml
generate_systemui_resource_xml
`;
  execFileSync('bash', ['-c', gen, 'gen', posix(root), posix(mod), posix(out)],
    { cwd: root, stdio: 'pipe' });
  const read = (rel) => {
    try {
      return readFileSync(join(out, rel), 'utf8');
    } catch {
      return '';
    }
  };
  return { read };
}

test('the overlay addons become resources, and the shade is written per density', () => {
  const on = generateResources('status_bar_background=off\nhide_notch=on\n');
  assert.match(on.read('framework/values/generated.xml'),
    /<bool name="config_maskMainBuiltInDisplayCutout">true<\/bool>/);
  assert.match(on.read('systemui/values/generated.xml'),
    /name="status_background" type="drawable">@android:color\/transparent</);

  // The default-config item alone loses to the ROM's density-qualified 9-patch
  // (AssetManager2::FindEntry), so every density the ROM uses gets a copy.
  for (const d of ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
    assert.match(on.read(`systemui/values-${d}-v4/generated.xml`),
      /name="status_background" type="drawable">@android:color\/transparent</, d);
  }

  // Back to the defaults: the resource goes, and so do the copies — a leftover
  // one is a build that keeps removing the shade nobody asked about.
  const off = generateResources('#status_bar_background=off\n#hide_notch=on\n');
  assert.doesNotMatch(off.read('framework/values/generated.xml'),
    /config_maskMainBuiltInDisplayCutout/);
  assert.doesNotMatch(off.read('systemui/values/generated.xml'), /status_background/);
  assert.equal(off.read('systemui/values-xxhdpi-v4/generated.xml'), '',
    'a stale density copy must be removed');
});

test('the shipped template names every addon the catalog offers', () => {
  const doc = JSON.parse(run(moduleTree(), ['list']).out);
  const text = readFileSync(template, 'utf8');
  for (const a of doc.addons) {
    assert.match(text, new RegExp(`^#${a.id}=`, 'm'),
      `src/module/addons.conf should show ${a.id} as a commented example`);
  }
});

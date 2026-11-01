// ---------------------------------------------------------------------------
// stuff/scripts/match-prop.sh — which property the overlay should match on
// ---------------------------------------------------------------------------
// The failure this pins: a match property is checked by plain string equality,
// and getting it wrong is silent — the overlay installs, `cmd overlay list`
// shows it enabled, and nothing on screen changes. Two ways to get it wrong, and
// both used to look like a fine answer:
//
//   - a property zygote cannot read (build_odm_prop, build_bootimage_prop), so
//     the condition never holds under a GSI;
//   - a property on /system or /product, which the GSI itself replaces, so the
//     value changes the moment the overlay is installed onto it.
//
// No phone is involved: --values/--labels read saved `getprop` and `getprop -Z`
// output, which is the same text the script parses off the wire.
//
// Run: node --test stuff/tests/match-prop.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const script = join(root, 'stuff', 'scripts', 'match-prop.sh');

function dump(pairs) {
  return Object.entries(pairs)
    .map(([k, v]) => `[${k}]: [${v}]`)
    .join('\n') + '\n';
}

// `getprop -Z` prints the same shape, with the SELinux label as the value.
function areas(pairs) {
  return dump(
    Object.fromEntries(Object.entries(pairs).map(([k, v]) => [k, `u:object_r:${v}:s0`]))
  );
}

function dir(files) {
  const d = mkdtempSync(join(tmpdir(), 'match-prop-'));
  for (const [name, body] of Object.entries(files)) {
    writeFileSync(join(d, name), body);
  }
  return d;
}

// `getprop -Z` is missing on old Android, so --labels is optional: a test with
// only a values dump is the no-labels case on purpose.
function run(d, extra = []) {
  const args = [script, '--values', join(d, 'values')];
  if (existsSync(join(d, 'labels'))) args.push('--labels', join(d, 'labels'));
  args.push('--json', ...extra);
  const out = spawnSync('bash', args, {
    encoding: 'utf8',
    env: { ...process.env, CFG_FILE: join(d, 'config.env'), TERM: 'dumb' },
  });
  assert.equal(out.stderr.replace(/^\s+|\s+$/g, ''), '', `stderr: ${out.stderr}`);
  return { report: JSON.parse(out.stdout), status: out.status };
}

// A Xiaomi ROM: the OEM name sits on /vendor and zygote may read it.
const XIAOMI = {
  'ro.product.vendor.device': 'zephyr',
  'ro.product.device': 'zephyr',
  'ro.product.model': 'Redmi Note 17',
};
const XIAOMI_AREAS = {
  'ro.product.vendor.device': 'build_vendor_prop',
  'ro.product.device': 'build_system_prop',
  'ro.product.model': 'build_prop',
};

test('the vendor property wins, and it is the one the tool trusts', () => {
  const d = dir({ values: dump(XIAOMI), labels: areas(XIAOMI_AREAS) });
  const { report, status } = run(d);
  assert.equal(status, 0);
  assert.equal(report.codename, 'zephyr');
  assert.equal(report.confidence, 'high');
  assert.equal(report.candidates[0].prop, 'ro.product.vendor.device');
  assert.equal(report.candidates[0].value, 'zephyr');
  assert.equal(report.candidates[0].perfect, true);
  assert.equal(report.moduleProp, 'persist.sys.overlay.zephyr');
});

// The same codename on /system is not the answer: a GSI replaces /system, so the
// value the overlay matches stops existing the moment it is installed.
test('a /system property ranks below /vendor and says what it is gambling on', () => {
  const d = dir({ values: dump(XIAOMI), labels: areas(XIAOMI_AREAS) });
  const { report } = run(d);
  const system = report.candidates.find((c) => c.prop === 'ro.product.device');
  assert.ok(system, 'ro.product.device has to be ranked, not hidden');
  assert.equal(system.perfect, false);
  assert.ok(system.score < report.candidates[0].score);
  assert.match(system.risk, /GSI/);
});

// build_odm_prop and build_bootimage_prop are the documented traps: the value
// survives a GSI, but zygote is refused the label, so the condition never holds.
test('an unreadable label is not a trusted answer even on a partition a GSI keeps', () => {
  const values = dump({ 'ro.product.odm.device': 'zephyr' });
  const cards = areas({ 'ro.product.odm.device': 'build_odm_prop' });
  const d = dir({ values, labels: cards });
  const { report } = run(d);
  assert.equal(report.confidence, 'medium');
  assert.equal(report.candidates[0].prop, 'ro.product.odm.device');
  assert.equal(report.candidates[0].perfect, false);
  assert.match(report.candidates[0].risk, /denied to zygote/);
});

// `--write` is for a scripted run, so it may only take an answer it trusts.
test('--write refuses a medium answer and leaves config.env exactly as it was', () => {
  const before = 'HW_OVERLAY_MATCH_PROP="ro.product.device"\nHW_OVERLAY_MATCH_VALUE="zephyr"\n';
  const d = dir({ values: dump({ 'ro.product.odm.device': 'zephyr' }), labels: areas({ 'ro.product.odm.device': 'build_odm_prop' }), 'config.env': before });
  const out = spawnSync(
    'bash',
    [script, '--values', join(d, 'values'), '--labels', join(d, 'labels'), '--write'],
    { encoding: 'utf8', env: { ...process.env, CFG_FILE: join(d, 'config.env'), TERM: 'dumb' } }
  );
  assert.equal(out.status, 1, 'a refusal has to be a non-zero exit');
  assert.match(out.stdout, /Not writing/);
  assert.equal(readFileSync(join(d, 'config.env'), 'utf8'), before);
});

test('--write takes a trusted answer and rewrites both keys', () => {
  const d = dir({
    values: dump(XIAOMI),
    labels: areas(XIAOMI_AREAS),
    'config.env': 'HW_OVERLAY_MATCH_PROP="ro.product.device"\nHW_OVERLAY_MATCH_VALUE="old"\n',
  });
  execFileSync('bash', [script, '--values', join(d, 'values'), '--labels', join(d, 'labels'), '--write'], {
    encoding: 'utf8',
    env: { ...process.env, CFG_FILE: join(d, 'config.env'), TERM: 'dumb' },
  });
  const cfg = readFileSync(join(d, 'config.env'), 'utf8');
  assert.match(cfg, /^HW_OVERLAY_MATCH_PROP="ro\.product\.vendor\.device"$/m);
  assert.match(cfg, /^HW_OVERLAY_MATCH_VALUE="zephyr"$/m);
});

// A phone with nothing device-shaped on it must not produce a match at all: a
// made-up pair is worse than the one already in config.env.
test('no codename anywhere is reported as no answer, with a non-zero exit', () => {
  const d = dir({ values: dump({ 'ro.hardware': 'qcom', 'ro.board.platform': 'bengal' }) });
  const out = spawnSync('bash', [script, '--values', join(d, 'values'), '--json'], {
    encoding: 'utf8',
    env: { ...process.env, CFG_FILE: join(d, 'config.env'), TERM: 'dumb' },
  });
  const report = JSON.parse(out.stdout);
  assert.equal(report.candidates.length, 0);
  assert.equal(report.confidence, 'low');
  assert.equal(out.status, 1);
});

// getprop output sometimes arrives with CRLF (adb on Windows) and warnings mixed
// into the same stream; neither may turn into a property.
test('CRLF and stray warning lines are skipped, not parsed', () => {
  const d = dir({
    values: '[ro.product.vendor.device]: [zephyr]\r\nwarning: something\r\n\r\n',
  });
  const { report } = run(d);
  assert.equal(report.candidates.length, 1);
  assert.equal(report.candidates[0].prop, 'ro.product.vendor.device');
  assert.equal(report.candidates[0].value, 'zephyr');
});

// The device path is a pipeline (`adb shell getprop | parse_props`), not a file
// argument. Every test above hands over --values, which is exactly how a reader
// that only looked at `$1` went unnoticed: each run against a real phone died
// with "$1: unbound variable" and then blamed the phone's getprop.
test('a phone read over adb goes through the pipeline', () => {
  const d = dir({ values: dump(XIAOMI), labels: areas(XIAOMI_AREAS) });
  const adb = join(d, 'adb');
  writeFileSync(
    adb,
    `#!/bin/sh
if [ "$1" = "devices" ]; then
  printf 'List of devices attached\\nBPHONE  device product:zephyr model:Redmi_Note_17 device:zephyr transport_id:1\\n'
  exit 0
fi
if [ "$1" = "-s" ] && [ "$3" = "get-state" ]; then echo device; exit 0; fi
if [ "$1" = "-s" ] && [ "$3" = "shell" ] && [ "$4" = "getprop" ]; then
  if [ "$5" = "-Z" ]; then cat "$FAKE_LABELS"; else cat "$FAKE_VALUES"; fi
  exit 0
fi
exit 0
`
  );
  chmodSync(adb, 0o755);
  const out = spawnSync('bash', [script, '--adb', adb, '--device', 'BPHONE', '--json'], {
    encoding: 'utf8',
    env: {
      ...process.env,
      CFG_FILE: join(d, 'config.env'),
      TERM: 'dumb',
      FAKE_VALUES: join(d, 'values'),
      FAKE_LABELS: join(d, 'labels'),
    },
  });
  assert.equal(out.stderr.trim(), '', `stderr: ${out.stderr}`);
  assert.equal(out.status, 0, `status: ${out.status}`);
  const report = JSON.parse(out.stdout);
  assert.equal(report.codename, 'zephyr');
  assert.equal(report.candidates[0].prop, 'ro.product.vendor.device');
});

// The app answers the same question in Go (gui/matchprop.go). If these two lists
// ever disagree the terminal and the window give different advice for one phone.
test('the candidate list the shell ranks is the one the app ranks', () => {
  const go = readFileSync(join(root, 'gui', 'matchprop.go'), 'utf8');
  const sh = readFileSync(script, 'utf8');
  const ranked = /CANDIDATES='([\s\S]*?)'/.exec(sh);
  assert.ok(ranked, 'the shell candidate table is gone');
  const props = ranked[1].split('\n').map((line) => line.split('|')[0]).filter(Boolean);
  assert.ok(props.length >= 5);
  for (const prop of props) {
    assert.ok(go.includes(`"${prop}"`), `${prop} is ranked by the shell but not by gui/matchprop.go`);
  }
});
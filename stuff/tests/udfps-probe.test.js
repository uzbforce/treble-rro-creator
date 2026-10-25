// ---------------------------------------------------------------------------
// stuff/scripts/udfps-probe.sh — firmware mode has to answer from the ROM
// ---------------------------------------------------------------------------
// The failure this pins: a Xiaomi ROM puts the sensor geometry in
// vendor/build.prop as the FOD rectangle properties, not in an overlay APK. The
// probe used to list only the first 40 *.prop files (a real tree has hundreds,
// starting with system_ext's per-app cust.prop) and never turned the pair into a
// candidate at all, so a full super.img answered nothing while the same phone
// over adb answered 540,2198,89 from the very same property.
//
// No phone and no aapt2 are involved: the tree is a few text files.
//
// Run: node --test stuff/tests/udfps-probe.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const probe = join(root, 'stuff', 'scripts', 'udfps-probe.sh');

function tree(files) {
  const dir = mkdtempSync(join(tmpdir(), 'udfps-fw-'));
  for (const [rel, body] of Object.entries(files)) {
    const path = join(dir, rel);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, body);
  }
  return dir;
}

function run(dir) {
  const out = execFileSync('bash', [probe, '--firmware', dir, '--json'], {
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'pipe'],
    env: { ...process.env, TERM: 'dumb' },
  });
  return JSON.parse(out);
}

// The zephyr (Redmi Note 17 4G) values, exactly as vendor/build.prop ships them.
const ZEPHYR = `ro.hardware.fp.fod=true
ro.hardware.fp.fod.location=low
persist.vendor.sys.fp.fod.location.X_Y=451,2109
persist.vendor.sys.fp.fod.size.width_height=178,178
`;

test('the rectangle in vendor/build.prop is an answer, and the arithmetic is the rectangle centre', () => {
  const dir = tree({ 'vendor/build.prop': ZEPHYR });
  const report = run(dir);
  assert.equal(report.candidates.length, 1, JSON.stringify(report.candidates));
  const c = report.candidates[0];
  assert.equal(c.source, 'firmware-fod-props');
  assert.equal(c.x, 540);
  assert.equal(c.y, 2198);
  assert.equal(c.radius, 89);
  assert.equal(c.confidence, 'high');
  assert.equal(report.chosen.x, 540, 'the answer has to be chosen, not only listed');
  assert.match(c.detail, /location\.X_Y=451,2109/);
});

// A tree carries hundreds of per-app .prop files; the vendor build.prop has to
// be read even when it is not in the first handful find returns.
test('a build.prop behind hundreds of other .prop files is still read', () => {
  const files = {};
  for (let i = 0; i < 220; i += 1) {
    const name = `system_ext/etc/cust/${String(i).padStart(3, '0')}/cust.prop`;
    files[name] = `ro.cust.slot=${i}\n`;
  }
  files['vendor/build.prop'] = ZEPHYR;
  const report = run(tree(files));
  assert.equal(report.candidates.length, 1, JSON.stringify(report.candidates));
  assert.equal(report.chosen.x, 540);
});

// Android 8 shipped the same pair without the vendor segment.
test('the pre-vendor property names are read too', () => {
  const dir = tree({
    'vendor/build.prop': 'persist.sys.fp.fod.location.X_Y=300,1800\npersist.sys.fp.fod.size.width_height=100,120\n',
  });
  const report = run(dir);
  assert.equal(report.candidates.length, 1, JSON.stringify(report.candidates));
  assert.deepEqual(
    [report.chosen.x, report.chosen.y, report.chosen.radius],
    [350, 1860, 50]
  );
});

// A rectangle with no size is not a sensor position; inventing one would put
// the icon where no finger can reach.
test('an unusable pair is refused with a warning, not turned into a guess', () => {
  const dir = tree({
    'vendor/build.prop': 'persist.vendor.sys.fp.fod.location.X_Y=0,0\npersist.vendor.sys.fp.fod.size.width_height=0,0\n',
  });
  const report = run(dir);
  assert.equal(report.candidates.length, 0);
  assert.equal(report.chosen, null);
  assert.ok(report.warnings.length > 0, 'the refusal has to be visible');
});

test('a tree with nothing to read answers nothing instead of failing', () => {
  const report = run(tree({ 'system/build.prop': 'ro.product.device=zephyr\n' }));
  assert.equal(report.candidates.length, 0);
  assert.equal(report.chosen, null);
  assert.equal(report.mode, 'firmware');
});

// The probe is also run through the app, which passes an absolute folder: the
// paths it prints have to be usable, not a temp dir from this test.
test('the probe still names the source file it answered from', () => {
  const dir = tree({ 'vendor/build.prop': ZEPHYR });
  const report = run(dir);
  const detail = report.candidates[0].detail;
  assert.ok(detail.startsWith(dir), `detail does not name the tree: ${detail}`);
});

// ---------------------------------------------------------------------------
// src/webui/apply.sh — what the page is told the device resolves
// ---------------------------------------------------------------------------
// `cmd overlay lookup` answers in the unit the resource declares. The module's
// own overlay writes px, so its values come back as "113.0px", but a ROM whose
// framework value is 28dp answers "28.0dip". The page works in px and writes
// whatever it read back, so reading that "28.0dip" as 28px made an Apply that
// only touched the content padding shrink the status bar to 28px — the clock
// and the icons jumped to the top of the screen.
//
// The fake `cmd` and `wm` below reproduce that ROM without a phone.
// Run: node --test stuff/tests/apply-sh.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const script = join(root, 'src', 'webui', 'apply.sh');

// A module tree with the script in webroot/, the way it is installed.
function moduleTree() {
  const dir = mkdtempSync(join(tmpdir(), 'apply-sh-'));
  mkdirSync(join(dir, 'mod', 'webroot'), { recursive: true });
  mkdirSync(join(dir, 'bin'), { recursive: true });
  copyFileSync(script, join(dir, 'mod', 'webroot', 'apply.sh'));
  return dir;
}

// <density output> <lookup answers as "$4 -> value"> ...
function fakeTools(dir, density, lookups) {
  const bin = join(dir, 'bin');
  const wm = join(bin, 'wm');
  writeFileSync(wm, `#!/bin/sh\nprintf '%s\\n' ${density ? `'${density}'` : "''"} | tr ';' '\\n'\n`);
  chmodSync(wm, 0o755);

  const cmd = join(bin, 'cmd');
  const cases = Object.entries(lookups)
    .map(([res, value]) => `    ${res}) echo '${value}' ;;`)
    .join('\n');
  writeFileSync(cmd, `#!/bin/sh
case "$1 $2" in
  "overlay list") echo "no overlays"; exit 0 ;;
  "overlay lookup") case "$4" in
${cases}
    *) exit 1 ;;
  esac; exit 0 ;;
esac
exit 1
`);
  chmodSync(cmd, 0o755);
  return cmd;
}

function status(dir, cmd) {
  const out = execFileSync('sh', [join(dir, 'mod', 'webroot', 'apply.sh'), 'status'], {
    env: {
      ...process.env,
      PATH: `${join(dir, 'bin')}${process.platform === 'win32' ? ';' : ':'}${process.env.PATH}`,
      WEBUI_CMD: cmd,
      WEBUI_STATE_DIR: join(dir, 'state'),
    },
    encoding: 'utf8',
  });
  const kv = {};
  for (const line of out.split(/\r?\n/)) {
    const i = line.indexOf('=');
    if (i > 0) kv[line.slice(0, i)] = line.slice(i + 1);
  }
  return kv;
}

test('a dp answer is converted to px with the effective density', () => {
  const dir = moduleTree();
  // A LineageOS 16 build: 28dp status bar, density overridden to 429dpi.
  const cmd = fakeTools(dir, 'Physical density: 420;Override density: 429', {
    'android:dimen/status_bar_height_default': '28.0dip',
    'android:dimen/rounded_corner_content_padding': '0.0px',
    'android:dimen/rounded_corner_radius': '50.0px',
    'com.android.systemui:dimen/status_bar_padding_start': '34.0dip',
  });
  const st = status(dir, cmd);
  // 28 * 429 / 160 = 75.07 — the bar the device really shows is 76px.
  assert.equal(st.sb_height, '75');
  assert.equal(st.pad_start, '91');
  // px answers are already px and must not be scaled.
  assert.equal(st.radius, '50');
  assert.equal(st.pad_content, '0');
  // A resource the fake does not answer stays empty instead of becoming 0.
  assert.equal(st.pad_end, '');
});

test('a dp answer without a readable density is left empty', () => {
  const dir = moduleTree();
  const cmd = fakeTools(dir, '', {
    'android:dimen/status_bar_height_default': '28.0dip',
  });
  const st = status(dir, cmd);
  // Reporting 28 here is the bug this guards: a dp value read as px.
  assert.equal(st.sb_height, '');
});

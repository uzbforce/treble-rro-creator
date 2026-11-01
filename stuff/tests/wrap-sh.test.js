// ---------------------------------------------------------------------------
// wrap.sh — the APK paths a person pastes
// ---------------------------------------------------------------------------
// Explorer's "Copy as path" returns "C:\Users\..." with the quotes, and Git
// Bash's own file tests want /c/... with slashes. The menu passes the line
// through untouched, so wrap.sh has to clean it before testing the file.
//
// Run: node --test stuff/tests/wrap-sh.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

function inputPath(value, windows = false) {
  const out = spawnSync(
    'bash',
    [
      '-c',
      `. "$1/stuff/scripts/common.sh"; IS_WINDOWS=${windows ? 'true' : 'false'}; input_path "$2"`,
      '_',
      root,
      value,
    ],
    { encoding: 'utf8', env: { ...process.env, ROOT: root } }
  );
  assert.equal(out.status, 0, out.stderr);
  return out.stdout;
}

test('a path copied by Explorer loses its quotes, not its contents', () => {
  assert.equal(
    inputPath('"C:\\Users\\uzbfo\\Downloads\\overlay.apk"', true),
    '/c/Users/uzbfo/Downloads/overlay.apk'
  );
  assert.equal(inputPath("'out/apks/overlay.apk'", false), 'out/apks/overlay.apk');
});

test('a Windows drive or UNC path becomes one Git Bash can open', () => {
  assert.equal(
    inputPath('C:\\Users\\uzbfo\\Downloads\\overlay.apk', true),
    '/c/Users/uzbfo/Downloads/overlay.apk'
  );
  assert.equal(inputPath('D:/builds/overlay.apk', true), '/d/builds/overlay.apk');
  assert.equal(inputPath('\\\\server\\share\\overlay.apk', true), '//server/share/overlay.apk');
});

test('a Linux path is not rewritten', () => {
  assert.equal(inputPath('/home/me/My Builds/overlay.apk', false), '/home/me/My Builds/overlay.apk');
  // A backslash is a valid character in a Unix file name; only Windows paths
  // are converted.
  assert.equal(inputPath('C:\\not-a-drive-on-linux', false), 'C:\\not-a-drive-on-linux');
});

test('spaces around a pasted path are trimmed, spaces inside it are kept', () => {
  assert.equal(inputPath('  "/tmp/My Builds/overlay.apk"  ', false), '/tmp/My Builds/overlay.apk');
});

// The helper is only useful if wrap.sh calls it. A missing APK is enough: the
// error that comes back must name the path, not the quotes around it.
test('wrap.sh checks the path without the quotes around it', () => {
  const out = spawnSync(
    'bash',
    [join(root, 'stuff', 'scripts', 'wrap.sh'), '--overlay', '"no-such-overlay.apk"'],
    { cwd: root, encoding: 'utf8', env: { ...process.env, ROOT: root, TERM: 'dumb' } }
  );
  assert.notEqual(out.status, 0);
  const output = `${out.stdout}${out.stderr}`;
  assert.match(output, /no such file: no-such-overlay\.apk/);
  assert.ok(!output.includes('no such file: "no-such-overlay.apk"'), output);
});

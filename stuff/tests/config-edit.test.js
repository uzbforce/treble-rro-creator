// ---------------------------------------------------------------------------
// stuff/scripts/config-edit.sh — writing config.env
// ---------------------------------------------------------------------------
// The failure this pins: config.env is *sourced* by the build (build.sh, and
// every standalone script via common.sh), so a saved value is shell code. A
// model name reading `$(reboot)` used to be written into the file unchanged and
// run on the next build; a value with a newline in it ended the line early and
// the rest of it became a key of its own.
//
// No phone and no build involved: these are the functions the menu, the app and
// match-prop.sh all write through.
//
// Run: node --test stuff/tests/config-edit.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const script = join(root, 'stuff', 'scripts', 'config-edit.sh');

// A throwaway ROOT holding one config.env, in the shape the real file uses:
// section headers, bare words, and two keys that are quoted.
function workspace(body) {
  const d = mkdtempSync(join(tmpdir(), 'config-edit-'));
  writeFileSync(
    join(d, 'config.env'),
    body ??
      [
        '# ─── Device ─────────────────────────────────────────────',
        'DEVICE_MANUFACTURER=Xiaomi',
        'DEVICE_MODEL="Redmi Note 17"',
        '#DEVICE_CODENAME=zephyr',
        'HAS_UDFPS=false',
        '',
      ].join('\n')
  );
  return d;
}

// Run a bash snippet with the helpers sourced and ROOT pointed at the fixture.
function run(d, snippet) {
  const file = join(d, 'run.sh');
  writeFileSync(file, `. "${script}"\n${snippet}\n`);
  const out = spawnSync('bash', [file], {
    encoding: 'utf8',
    env: { ...process.env, ROOT: d, TERM: 'dumb' },
  });
  return { out, code: out.status };
}

const cfg = (d) => readFileSync(join(d, 'config.env'), 'utf8');

// A JS string as a single shell word, for embedding fixtures in a snippet.
const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

test('a value with $, a backtick, a quote and a backslash round-trips', () => {
  const d = workspace();
  const value = 'a$(reboot)b`id`c\\ d"e';
  const r = run(
    d,
    [
      `value=${shq(value)}`,
      'v="$(cfg_quote "$value")"',
      'eval "got=$v"',
      '[ "$got" = "$value" ] || { printf "got=%s\\n" "$got" >&2; exit 1; }',
    ].join('\n')
  );
  assert.equal(r.code, 0, r.out.stderr);
});

test('cfg_quote escapes everything the shell expands inside double quotes', () => {
  const d = workspace();
  const r = run(d, `cfg_quote 'x$(touch PWNED)y\`id\`z$HOME'`);
  assert.equal(r.code, 0, r.out.stderr);
  assert.equal(r.out.stdout, '"x\\$(touch PWNED)y\\`id\\`z\\$HOME"');
});

test('a written value cannot run when the file is sourced', () => {
  const d = workspace();
  const marker = join(d, 'PWNED');
  // Both values are single-quoted in the generated script: inside double
  // quotes the test itself would run them, which is the bug being pinned.
  const r = run(
    d,
    [
      `cfg_set DEVICE_MODEL ${shq(`$(touch ${marker})`)}`,
      `cfg_set DEVICE_MANUFACTURER ${shq(`\`touch ${marker}.tick\``)}`,
    ].join('\n')
  );
  assert.equal(r.code, 0, r.out.stderr);

  // build.sh and common.sh both do exactly this.
  const source = spawnSync('bash', ['-c', `. "${join(d, 'config.env')}"`], {
    encoding: 'utf8',
    env: { ...process.env, TERM: 'dumb' },
  });
  assert.equal(source.status, 0, source.stderr);
  assert.equal(existsSync(marker), false, 'value ran as a command');
  assert.equal(existsSync(`${marker}.tick`), false, 'value ran as a command');

  // …and it still reads back as what the user typed.
  const back = run(d, 'cfg_get DEVICE_MODEL');
  assert.equal(back.out.stdout, `$(touch ${marker})`);
});

test('a newline in a value stays on one line', () => {
  const d = workspace();
  const before = cfg(d).split('\n').length;
  const r = run(d, `cfg_set DEVICE_MODEL "$(printf 'Redmi\\nNote')"`);
  assert.equal(r.code, 0, r.out.stderr);

  const text = cfg(d);
  assert.equal(text.split('\n').length, before, 'the file gained a line');
  assert.match(text, /^DEVICE_MODEL="Redmi Note"$/m);
  // Nothing that looks like a key was created out of the second half.
  const keys = text.split('\n').filter((l) => /^[A-Z_]+=/i.test(l)).map((l) => l.split('=')[0]);
  assert.deepEqual(keys, ['DEVICE_MANUFACTURER', 'DEVICE_MODEL', 'HAS_UDFPS']);
});

test('control characters are stripped, not written', () => {
  const d = workspace();
  const r = run(d, `cfg_set DEVICE_MODEL "$(printf 'a\\033[31mb')"`);
  assert.equal(r.code, 0, r.out.stderr);
  // Quoted because the line it replaced was quoted; the point is the escape
  // sequence is gone, not that the style changed.
  assert.match(cfg(d), /^DEVICE_MODEL="ab"$/m);
});

test('a plain word stays bare, so the file keeps its style', () => {
  const d = workspace();
  const r = run(d, 'cfg_set DEVICE_MANUFACTURER Samsung');
  assert.equal(r.code, 0, r.out.stderr);
  assert.match(cfg(d), /^DEVICE_MANUFACTURER=Samsung$/m);
});

test('a quoted line stays quoted, and a commented key is switched on', () => {
  const d = workspace();
  const r = run(d, "cfg_set DEVICE_MODEL 'Redmi Note 17 Pro'\ncfg_set DEVICE_CODENAME zephyr");
  assert.equal(r.code, 0, r.out.stderr);
  const text = cfg(d);
  assert.match(text, /^DEVICE_MODEL="Redmi Note 17 Pro"$/m);
  // Was `#DEVICE_CODENAME=zephyr`: enabling it keeps the key, drops the '#'.
  assert.match(text, /^DEVICE_CODENAME=zephyr$/m);
  assert.equal(text.split('\n').length, 6, 'the file gained a line');
});

test('switching a key off and on leaves the value alone', () => {
  const d = workspace();
  run(d, 'cfg_set_active DEVICE_MODEL 0');
  assert.match(cfg(d), /^#DEVICE_MODEL="Redmi Note 17"$/m);
  run(d, 'cfg_set_active DEVICE_MODEL 1');
  assert.match(cfg(d), /^DEVICE_MODEL="Redmi Note 17"$/m);
});
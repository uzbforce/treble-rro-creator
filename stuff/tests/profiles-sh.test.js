// ---------------------------------------------------------------------------
// stuff/scripts/profiles.sh — the saved config.env sets
// ---------------------------------------------------------------------------
// The helper owns the files, so the damage it can do is file damage: two rows
// that read the same, a profile with no answers switched over config.env, a
// lost marker adopted by guesswork (the next switch then saves this device's
// answers into another device's profile), and ids that are not ids reaching a
// path. Every case here is one of those, plus the out/ note that keeps a
// previous device's module from being installed by mistake.
//
// Run: node --test stuff/tests/profiles-sh.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const scripts = join(root, 'stuff', 'scripts');

// A throwaway ROOT with the real helper, its config reader, and one config.env.
// profiles.sh sources config-edit.sh from ROOT, so both have to be there.
function workspace() {
  const d = mkdtempSync(join(tmpdir(), 'profiles-'));
  mkdirSync(join(d, 'stuff', 'scripts'), { recursive: true });
  for (const name of ['profiles.sh', 'config-edit.sh']) {
    copyFileSync(join(scripts, name), join(d, 'stuff', 'scripts', name));
  }
  writeFileSync(
    join(d, 'config.env'),
    ['DEVICE_MANUFACTURER=Xiaomi', 'DEVICE_MODEL="Redmi Note 17"', 'DEVICE_CODENAME=zephyr', ''].join('\n')
  );
  return d;
}

function run(d, snippet) {
  const file = join(d, 'run.sh');
  writeFileSync(file, `. "${join(scripts, 'profiles.sh')}"\n${snippet}\n`);
  const out = spawnSync('bash', [file], {
    encoding: 'utf8',
    // The fixture is the working directory as well as ROOT: the helper reads
    // and writes paths relative to both, and a stray `out/` must not land in
    // the checkout running the tests.
    cwd: d,
    env: { ...process.env, ROOT: d, TERM: 'dumb' },
  });
  return { stdout: out.stdout, stderr: out.stderr, status: out.status };
}

const cfgOf = (d, id) => readFileSync(join(d, 'stuff', 'profiles', id, 'config.env'), 'utf8');

test('two profiles cannot share a name, whatever the case or spacing', () => {
  const d = workspace();
  const r = run(d, 'profiles_new_with "Pixel 8" >/dev/null || exit 9; profiles_new_with "  pixel   8 "');
  assert.equal(r.status, 1);
  assert.match(r.stderr, /already taken by p1/);
});

test('a rename onto another profile name is refused, but its own is not', () => {
  const d = workspace();
  const r = run(
    d,
    [
      'profiles_new_with "Pixel" >/dev/null || exit 9',
      'profiles_new_with "Note" >/dev/null || exit 9',
      'profiles_rename p1 "NOTE" && exit 8', // duplicate: must fail
      'profiles_rename p2 "Note" || exit 7', // its own name: must pass
      'profiles_name p2',
    ].join('\n')
  );
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), 'Note');
});

test('the default name skips a number that is already in use', () => {
  const d = workspace();
  const r = run(d, 'profiles_new_with "Profile #2" >/dev/null || exit 9; profiles_new_with "" >/dev/null || exit 9; profiles_name p2');
  assert.equal(r.status, 0, r.stderr);
  assert.equal(r.stdout.trim(), 'Profile #3');
});

test('a profile whose config.env is gone is not switched to', () => {
  const d = workspace();
  const r = run(
    d,
    [
      'profiles_new_with "First" >/dev/null || exit 9',
      'profiles_new_with "Second" >/dev/null || exit 9',
      'rm -f stuff/profiles/p2/config.env',
      'profiles_switch p2',
    ].join('\n')
  );
  assert.equal(r.status, 1);
  assert.match(r.stderr, /has no config\.env/);
  assert.match(readFileSync(join(d, 'config.env'), 'utf8'), /DEVICE_CODENAME=zephyr/);
});

// The marker is the only thing saying which profile config.env belongs to. When
// it is gone, a matching saved copy is proof enough; anything else is a guess,
// and a wrong guess overwrites the other device's saved answers on the next
// switch.
test('a lost marker is adopted when config.env matches a profile, and not otherwise', () => {
  const d = workspace();
  const adopted = run(
    d,
    'profiles_new_with "Pixel" >/dev/null || exit 9; rm -f stuff/profiles/active; profiles_ensure >/dev/null; profiles_active'
  );
  assert.equal(adopted.stdout.trim(), 'p1');

  const d2 = workspace();
  const guessed = run(
    d2,
    [
      'profiles_new_with "Pixel" >/dev/null || exit 9',
      'profiles_new_with "Note" >/dev/null || exit 9',
      'rm -f stuff/profiles/active',
      // Absolute, like every other write here: a snippet that runs with the
      // wrong cwd must never reach the checkout's own config.env. One that did
      // left a codename line in it, and the line was committed.
      'printf "DEVICE_CODENAME=edited\\n" >> "$ROOT/config.env"',
      'profiles_ensure >/dev/null || true',
      'echo "active=[$(profiles_active)]"',
      'profiles_switch p1 >/dev/null 2>&1 || exit 9',
      'grep -c edited stuff/profiles/p2/config.env || true',
    ].join('\n')
  );
  assert.match(guessed.stdout, /active=\[\]/);
  assert.match(guessed.stderr, /no profile is active/);
  // The edit must not be saved into a profile nobody proved it belonged to.
  assert.equal(guessed.stdout.trim().split('\n').pop(), '0');
});

test('a name with a pipe does not break the table', () => {
  const d = workspace();
  const r = run(d, 'profiles_new_with "Pixel" >/dev/null || exit 9; profiles_rename p1 "a|b" >/dev/null || exit 9; profiles_print');
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /a\/b/);
  assert.ok(!r.stdout.includes('a|b'), r.stdout);
});

// The device cell is built from config.env, which is hand-edited: a pipe in the
// model name used to add a column to the table and a tab added a field to the
// machine listing, so the app showed half a device and dropped the rest.
test('a device name with a pipe or a tab stays inside its cell', () => {
  const d = workspace();
  writeFileSync(
    join(d, 'config.env'),
    ['DEVICE_MANUFACTURER=Xiaomi', 'DEVICE_MODEL="A|B\tC"', 'DEVICE_CODENAME=zephyr', ''].join('\n')
  );
  const r = run(d, 'profiles_list');
  assert.equal(r.status, 0, r.stderr);
  const line = r.stdout.trim();
  assert.equal(line.split('\t').length, 4, line);
  const cell = line.split('\t')[3];
  assert.match(cell, /A\/B C/);
  assert.ok(!cell.includes('|'), cell);

  const shown = run(d, 'profiles_print');
  assert.equal(shown.status, 0, shown.stderr);
  assert.match(shown.stdout, /A\/B C/);
});

// Creating a profile claims its folder first, so the folder itself is in the
// listing while the name is being checked. A name equal to the folder's own
// default number must not read as a duplicate of itself, and a refused name must
// not leave an empty folder behind for the list to show.
test('a new profile claims its folder without tripping over its own name', () => {
  const d = workspace();
  const r = run(
    d,
    [
      'profiles_new_with "Profile #2" >/dev/null || exit 9',
      'echo "after-dup=[$(profiles_new_with "profile #2" 2>/dev/null)] ids=[$(profiles_ids | tr "\\n" ",")]"',
      'profiles_new_with "" >/dev/null || exit 8',
      'echo "name=[$(profiles_name p2)]"',
      'profiles_list | cut -f3 | tr "\\n" ","',
    ].join('\n')
  );
  assert.equal(r.status, 0, r.stderr);
  // The refused name went to p1 and took its folder with it.
  assert.match(r.stdout, /after-dup=\[\] ids=\[p1,\]/);
  // #2 belongs to p1, so the new folder p2 takes the next free number rather
  // than claiming one that is in use.
  assert.match(r.stdout, /name=\[Profile #3\]/);
  assert.match(r.stdout, /^Profile #2,Profile #3,$/m);
});

test('switching says out/ still holds the previous build', () => {
  const d = workspace();
  const r = run(
    d,
    [
      'profiles_new_with "Pixel" >/dev/null || exit 9',
      'mkdir -p out && : > out/treble-overlay-x-ksu.zip',
      'profiles_switch p1',
    ].join('\n')
  );
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /out\/ still holds the previous build \(1 zip\)/);
});

test('an id is not a path: nothing outside stuff/profiles is touched', () => {
  const d = workspace();
  const r = run(
    d,
    [
      'mkdir -p victim',
      'profiles_switch "../victim" || echo "switch=$?"',
      'profiles_delete "p1/../../victim" || echo "delete=$?"',
      'profiles_has ".." || echo "has=$?"',
      '[ -d victim ] || exit 3',
    ].join('\n')
  );
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /switch=2/);
  assert.match(r.stdout, /delete=2/);
  assert.match(r.stdout, /has=1/);
  assert.ok(existsSync(join(d, 'victim')), 'a refused id removed a folder');
});
// ---------------------------------------------------------------------------
// stuff/scripts/adb-device.sh — the one rule for "which phone?"
// ---------------------------------------------------------------------------
// Both probes source it, and its whole job is to not guess. That makes it worth
// testing with more than a syntax check: the failure it prevents (writing to the
// wrong phone) is silent until it is too late.
//
// The fake adb below answers `devices -l` with a canned table and `get-state`
// with "device", so no phone is involved.
//
// Run: node --test stuff/tests/adb-device.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const lib = join(root, 'stuff', 'scripts', 'adb-device.sh');
// Some cases run with a PATH that deliberately has nothing on it, so bash is
// resolved once, up front, by absolute path.
const BASH = execFileSync('sh', ['-c', 'command -v bash'], { encoding: 'utf8' }).trim();

const BOTH_READY = `List of devices attached
RFCM90F5BBX            device product:lineage_r3q model:SM_A908N device:r3q transport_id:36
595648cf1cdc           device product:zephyr_global model:26012RN62A device:zephyr transport_id:37
`;

const ONE_READY = `List of devices attached
RFCM90F5BBX            device product:lineage_r3q model:SM_A908N device:r3q transport_id:36
0123456789AB           unauthorized usb:1-1 transport_id:3
`;

const NONE_READY = `List of devices attached
0123456789AB           unauthorized usb:1-1 transport_id:3
emulator-5554          offline
`;

// A fake adb whose body is written by the caller, for the cases a canned table
// cannot express: a wedged server, a state that changes between calls.
function fakeAdbScript(body, devicesOutput = '') {
  const dir = mkdtempSync(join(tmpdir(), 'adb-device-'));
  const adb = join(dir, 'adb');
  writeFileSync(adb, `#!/bin/sh\n${body}`);
  chmodSync(adb, 0o755);
  const table = join(dir, 'devices.txt');
  writeFileSync(table, devicesOutput);
  return { adb, table, dir };
}

function fakeAdb(devicesOutput) {
  // $1 is "devices" or "-s"; get-state only matters for a device that was
  // accepted, and a real adb would answer "device" there too.
  return fakeAdbScript(
    `if [ "$1" = "devices" ]; then
  cat "$FAKE_DEVICES"
  exit 0
fi
if [ "$1" = "-s" ] && [ "$3" = "get-state" ]; then
  echo device
  exit 0
fi
exit 0
`,
    devicesOutput
  );
}

// Runs adb_pick_device in a bash that sources the library, and returns both the
// chosen serial and whatever the helper printed. stdin is a pipe unless a menu
// answer is supplied, which is exactly the non-interactive case the app sees.
function pickUsing(adb, table, serialArg, { stdin = '', env = {} } = {}) {
  // 2>&1: the helper explains itself on stderr, and these tests are about that
  // explanation as much as about the serial.
  const script = `{ . "${lib}" && adb_pick_device "$FAKE_ADB" ${JSON.stringify(serialArg)} test-probe && printf 'PICKED=%s' "$DEVICE_SERIAL"; } 2>&1`;
  const run = () =>
    execFileSync('bash', ['-c', script], {
      env: { ...process.env, FAKE_ADB: adb, FAKE_DEVICES: table, TERM: 'dumb', ...env },
      input: stdin,
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    });
  try {
    return { out: run(), status: 0 };
  } catch (err) {
    return { out: `${err.stdout || ''}${err.stderr || ''}`, status: err.status ?? 1 };
  }
}

function pick(devicesOutput, serialArg, { stdin = '', env = {} } = {}) {
  const { adb, table } = fakeAdb(devicesOutput);
  return pickUsing(adb, table, serialArg, { stdin, env });
}

test('one ready phone is used even when another is unauthorized', () => {
  const { out, status } = pick(ONE_READY, '');
  assert.equal(status, 0, out);
  assert.match(out, /PICKED=RFCM90F5BBX/);
  // The unauthorized phone is called out by state, not counted as an option.
  assert.match(out, /0123456789AB.*unauthorized/);
});

test('two ready phones without a pick stop with the list, not a guess', () => {
  const { out, status } = pick(BOTH_READY, '');
  assert.notEqual(status, 0);
  assert.match(out, /595648cf1cdc/);
  assert.match(out, /RFCM90F5BBX/);
  assert.match(out, /--device SERIAL/);
  assert.doesNotMatch(out, /PICKED=/);
});

test('an explicit serial is used as given', () => {
  const { out, status } = pick(BOTH_READY, '595648cf1cdc');
  assert.equal(status, 0, out);
  assert.match(out, /PICKED=595648cf1cdc/);
});

test('an explicit serial that is not attached names what is', () => {
  const { out, status } = pick(BOTH_READY, 'GONE');
  assert.notEqual(status, 0);
  assert.match(out, /GONE is not attached/);
  assert.match(out, /RFCM90F5BBX/);
});

test('an explicit serial that is not ready says why', () => {
  const { out, status } = pick(ONE_READY, '0123456789AB');
  assert.notEqual(status, 0);
  assert.match(out, /attached but unauthorized/);
});

test('nothing attached says so instead of asking about states', () => {
  const { out, status } = pick('List of devices attached\n\n', '');
  assert.notEqual(status, 0);
  assert.match(out, /no device in adb devices/);
});

test('nothing ready explains each state', () => {
  const { out, status } = pick(NONE_READY, '');
  assert.notEqual(status, 0);
  assert.match(out, /no device is ready/);
  assert.match(out, /accept the USB debugging prompt/);
  assert.match(out, /unplug and replug/);
});

test('the menu takes a number, a serial or an unambiguous prefix', () => {
  const { adb, table } = fakeAdb(BOTH_READY);
  const run = (answer) =>
    execFileSync(
      'bash',
      [
        '-c',
        `. "${lib}" && adb_device_choose "$(cat "$FAKE_DEVICES" | awk 'NR > 1 && NF && $2 == "device"')"`,
      ],
      {
        env: { ...process.env, FAKE_ADB: adb, FAKE_DEVICES: table },
        input: answer,
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'pipe'],
      }
    ).trim();
  assert.equal(run('2\n'), '595648cf1cdc');
  assert.equal(run('595648cf1cdc\n'), '595648cf1cdc');
  assert.equal(run('RFCM\n'), 'RFCM90F5BBX');
});

test('a prefix two serials share is ambiguous, and it asks again', () => {
  const shared = `List of devices attached
ABC123                 device product:one model:One device:one transport_id:1
ABC456                 device product:two model:Two device:two transport_id:2
`;
  const { adb, table } = fakeAdb(shared);
  const out = execFileSync(
    'bash',
    ['-c', `. "${lib}" && adb_device_choose "$(cat "$FAKE_DEVICES" | awk 'NR > 1 && NF && $2 == "device"')"`],
    {
      env: { ...process.env, FAKE_ADB: adb, FAKE_DEVICES: table },
      input: 'ABC\nABC456\n',
      encoding: 'utf8',
      stdio: ['pipe', 'pipe', 'pipe'],
    }
  ).trim();
  assert.equal(out, 'ABC456');
});

// --- hardening --------------------------------------------------------------
// `adb devices` is not a table: the daemon's own chatter shares the stream. A
// line that is not a device must never be offered as one.
test('daemon chatter and version warnings are not devices', () => {
  const noisy = `List of devices attached
adb server version (41) doesn't match this client (39); killing...
* daemon started successfully *
RFCM90F5BBX            device product:lineage_r3q model:SM_A908N device:r3q transport_id:36
595648cf1cdc           device product:zephyr_global model:26012RN62A device:zephyr transport_id:37
`;
  const { out, status } = pick(noisy, '');
  assert.notEqual(status, 0);
  // Two real phones, so the answer is the list — with exactly two rows.
  assert.match(out, /2 devices are ready/);
  assert.doesNotMatch(out, /daemon started/);
  assert.doesNotMatch(out, /server version/);
});

test('a serial listed twice is offered once', () => {
  const twice = `List of devices attached
RFCM90F5BBX            device product:lineage_r3q model:SM_A908N device:r3q transport_id:36
RFCM90F5BBX            device product:lineage_r3q model:SM_A908N device:r3q transport_id:36
`;
  const { out, status } = pick(twice, '');
  assert.equal(status, 0, out);
  assert.match(out, /PICKED=RFCM90F5BBX/);
  assert.doesNotMatch(out, /2 devices are ready/);
});

test('a wireless transport is labelled as one', () => {
  const wireless = `List of devices attached
192.168.0.31:5555      device product:lineage_r3q model:SM_A908N device:r3q transport_id:36
595648cf1cdc           device product:zephyr_global model:26012RN62A device:zephyr transport_id:37
`;
  const { out, status } = pick(wireless, '');
  assert.notEqual(status, 0);
  assert.match(out, /192\.168\.0\.31:5555 .*\[wireless\]/);
});

// The first call after the server restarts can come back without a header. That
// is a retry, not an empty desk.
test('a listing with no header is retried until the server answers', () => {
  const { adb, table, dir } = fakeAdbScript(
    `if [ "$1" = "devices" ]; then
  if [ -f "$FAKE_COUNTER" ]; then cat "$FAKE_DEVICES"; else : > "$FAKE_COUNTER"; echo "adb server version (41) doesn't match this client (39); killing..." >&2; fi
  exit 0
fi
if [ "$1" = "-s" ] && [ "$3" = "get-state" ]; then echo device; exit 0; fi
exit 0
`,
    ONE_READY
  );
  const counter = join(dir, 'calls');
  const out = execFileSync('bash', ['-c', `{ . "${lib}" && adb_pick_device "$FAKE_ADB" "" test-probe && printf 'PICKED=%s' "$DEVICE_SERIAL"; } 2>&1`], {
    env: { ...process.env, FAKE_ADB: adb, FAKE_DEVICES: table, FAKE_COUNTER: counter },
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  assert.match(out, /PICKED=RFCM90F5BBX/);
});

// A phone that is still handshaking is not "nothing is ready" — waiting is what
// makes a just-plugged or wireless device work on the first run.
test('a device that is still connecting is waited for', () => {
  const { adb, table, dir } = fakeAdbScript(
    `if [ "$1" = "devices" ]; then
  if [ -f "$FAKE_COUNTER" ]; then cat "$FAKE_DEVICES"; else : > "$FAKE_COUNTER"; printf 'List of devices attached\nRFCM90F5BBX  connecting\n'; fi
  exit 0
fi
if [ "$1" = "-s" ] && [ "$3" = "get-state" ]; then echo device; exit 0; fi
exit 0
`,
    ONE_READY
  );
  const counter = join(dir, 'calls');
  const out = execFileSync('bash', ['-c', `{ . "${lib}" && adb_pick_device "$FAKE_ADB" "" test-probe && printf 'PICKED=%s' "$DEVICE_SERIAL"; } 2>&1`], {
    env: { ...process.env, FAKE_ADB: adb, FAKE_DEVICES: table, FAKE_COUNTER: counter },
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  assert.match(out, /PICKED=RFCM90F5BBX/);
});

// The menu case: a serial is named (or was set in config.env) while the phone is
// still showing its debugging prompt. Failing there means the user plugs in,
// accepts, and then runs the menu again — so it waits instead.
test('a named serial that is not ready yet is waited for', () => {
  const { adb, table, dir } = fakeAdbScript(
    `if [ "$1" = "devices" ]; then
  if [ -f "$FAKE_COUNTER" ]; then cat "$FAKE_DEVICES"; else : > "$FAKE_COUNTER"; printf 'List of devices attached\nRFCM90F5BBX  unauthorized\n'; fi
  exit 0
fi
if [ "$1" = "-s" ] && [ "$3" = "get-state" ]; then echo device; exit 0; fi
exit 0
`,
    ONE_READY
  );
  const { out, status } = pickUsing(adb, table, 'RFCM90F5BBX', {
    env: { FAKE_COUNTER: join(dir, 'calls'), ADB_WAIT_SECONDS: '5' },
  });
  assert.equal(status, 0, out);
  assert.match(out, /RFCM90F5BBX is attached but unauthorized/);
  assert.match(out, /waiting for a device to become ready/);
  assert.match(out, /PICKED=RFCM90F5BBX/);
});

// Plugging the phone in after the menu opened should be enough on its own.
test('an empty desk is waited on until a phone appears', () => {
  const { adb, table, dir } = fakeAdbScript(
    `if [ "$1" = "devices" ]; then
  if [ -f "$FAKE_COUNTER" ]; then cat "$FAKE_DEVICES"; else : > "$FAKE_COUNTER"; printf 'List of devices attached\n\n'; fi
  exit 0
fi
if [ "$1" = "-s" ] && [ "$3" = "get-state" ]; then echo device; exit 0; fi
exit 0
`,
    ONE_READY
  );
  const { out, status } = pickUsing(adb, table, '', {
    env: { FAKE_COUNTER: join(dir, 'calls'), ADB_WAIT_SECONDS: '5' },
  });
  assert.equal(status, 0, out);
  assert.match(out, /no device in adb devices/);
  assert.match(out, /PICKED=RFCM90F5BBX/);
});

// Nothing ever appears: the deadline is reported, not waited out forever.
test('a wait that times out says how long it waited', () => {
  const { out, status } = pick('List of devices attached\n\n', '', {
    env: { ADB_WAIT_SECONDS: '2' },
  });
  assert.notEqual(status, 0);
  assert.match(out, /no device appeared within 2s/);
  assert.doesNotMatch(out, /PICKED=/);
});

// Ready in the listing, dead on the wire: the snapshot is checked, not trusted.
test('a phone that is listed but will not answer get-state is refused', () => {
  const { adb, table } = fakeAdbScript(
    `if [ "$1" = "devices" ]; then cat "$FAKE_DEVICES"; exit 0; fi
if [ "$1" = "-s" ]; then echo "error: device offline" >&2; exit 1; fi
exit 0
`,
    ONE_READY
  );
  const { out, status } = pickUsing(adb, table, '');
  assert.notEqual(status, 0);
  assert.match(out, /did not answer get-state/);
  assert.doesNotMatch(out, /PICKED=/);
});

// The wait promises "Ctrl-C stops this" on screen, so Ctrl-C has to stop it. A
// trap that only runs the cleanup (`trap cleanup EXIT HUP INT TERM`) replaces the
// default action, so the interrupt cleaned up and the loop carried on polling —
// three presses and the prompt did not come back.
test('Ctrl-C ends the wait instead of being swallowed', async () => {
  for (const name of ['match-prop', 'device-probe', 'udfps-probe', 'device-id']) {
    const body = readFileSync(join(root, 'stuff', 'scripts', `${name}.sh`), 'utf8');
    for (const line of body.match(/^trap .*$/gm) || []) {
      if (/\bINT\b/.test(line)) {
        assert.match(line, /\bexit\b/, `${name}.sh traps INT without exiting: ${line}`);
      }
    }
  }

  // And in practice: a 120s wait is cut short by a real SIGINT. The trap is set
  // by the probe, so the probe is what runs — match-prop is the one from the
  // bug report.
  const { adb, table, dir: tmp } = fakeAdb('List of devices attached\n\n');
  const child = spawn('bash', [join(root, 'stuff', 'scripts', 'match-prop.sh'), '--adb', adb], {
    env: {
      ...process.env,
      FAKE_DEVICES: table,
      ADB_WAIT_SECONDS: '120',
      CFG_FILE: join(tmp, 'config.env'),
      TERM: 'dumb',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
    detached: true,
  });
  let stderr = '';
  child.stderr.on('data', (chunk) => (stderr += chunk));
  const started = Date.now();
  const exited = new Promise((resolve) => child.on('exit', (code, signal) => resolve({ code, signal })));
  await new Promise((resolve) => setTimeout(resolve, 1200));
  process.kill(-child.pid, 'SIGINT');
  const { code } = await exited;
  const took = Date.now() - started;
  assert.ok(took < 6000, `the wait ignored SIGINT for ${took}ms`);
  assert.equal(code, 130, `expected the interrupt exit code, got ${code}: ${stderr}`);
});

// A wedged adb server otherwise hangs the probe with nothing on screen, which
// reads as the script being stuck.
test('adb that never answers is cut off with advice, not a hang', () => {
  const { adb, dir } = fakeAdbScript(`sleep 30
`);
  const outFile = join(dir, 'out');
  const started = Date.now();
  const out = execFileSync('bash', ['-c', `. "${lib}" && adb_device_exec 5 "$OUT" "$FAKE_ADB" devices -l; printf 'status=%s' "$?"`], {
    env: { ...process.env, FAKE_ADB: adb, OUT: outFile },
    encoding: 'utf8',
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  assert.match(out, /status=124/);
  assert.ok(Date.now() - started < 5000, 'the bounded runner waited past its deadline');

  // The same deadline in the listing, with the advice the user needs. The limit
  // is a parameter here so the test does not sit out the real 20s.
  const listOut = execFileSync(
    'bash',
    ['-c', `. "${lib}" && adb_device_list "$FAKE_ADB" 5; printf 'status=%s note=%s' "$?" "$ADB_DEVICES_NOTE"`],
    { env: { ...process.env, FAKE_ADB: adb }, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }
  );
  assert.match(listOut, /status=1/);
  assert.match(listOut, /did not answer within .*adb kill-server/);
});

// --- this phone, read directly (Termux) --------------------------------------
// In Termux there is no adb server to dial: the phone is the machine the script
// is running on, and the reads a PC makes over `adb shell` happen natively as
// root. These cases pin that the source is chosen without touching adb, that a
// refused root prompt is a clear line rather than an empty report, and that the
// probes' `su 0` retries are not a second escalation.

// A bin directory holding `su` (which logs the command it was handed and runs
// it), on top of the normal PATH.
function localEnv(extra = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'adb-local-'));
  const bin = join(dir, 'bin');
  mkdirSync(bin, { recursive: true });
  const log = join(dir, 'su.log');
  // A shell cannot change uid, so the gate's own question (`id -u`) is what is
  // answered as root; everything else runs as-is. The log is how a test sees
  // exactly what the tool asked for.
  writeFileSync(
    join(bin, 'su'),
    `#!/bin/sh
printf '%s\\n' "$2" >> "$FAKE_SU_LOG"
case "$2" in
  'id -u') echo 0 ;;
  *) exec sh -c "$2" ;;
esac
`
  );
  chmodSync(join(bin, 'su'), 0o755);
  return {
    dir,
    log,
    env: {
      PATH: `${bin}:${process.env.PATH}`,
      FAKE_SU_LOG: log,
      TERMUX_VERSION: '1',
      ROOT: root,
      ...extra,
    },
  };
}

function localRun(env, script) {
  try {
    return {
      out: execFileSync(BASH, ['-c', `{ . "${lib}" && ${script}; } 2>&1`], {
        env,
        input: '',
        encoding: 'utf8',
        stdio: ['pipe', 'pipe', 'pipe'],
      }),
      status: 0,
    };
  } catch (err) {
    return { out: `${err.stdout || ''}${err.stderr || ''}`, status: err.status ?? 1 };
  }
}

test('Termux is recognised by the environment it sets, and only there', () => {
  const plain = { PATH: process.env.PATH, HOME: '/home/someone', PREFIX: '/usr' };
  assert.equal(localRun(plain, 'device_is_termux && echo yes || echo no').out.trim(), 'no');
  const cases = [
    { TERMUX_VERSION: '0.118.1' },
    { PREFIX: '/data/data/com.termux/files/usr' },
    { HOME: '/data/data/com.termux/files/home' },
  ];
  for (const extra of cases) {
    const out = localRun({ ...plain, ...extra }, 'device_is_termux && echo yes || echo no');
    assert.equal(out.out.trim(), 'yes', `not detected from ${JSON.stringify(extra)}`);
  }
});

test('--device local reads this phone and never runs adb', () => {
  const { dir, env } = localEnv();
  // An adb that would be obvious if it were used, and would answer if asked.
  const marker = join(dir, 'adb-was-run');
  const adb = join(dir, 'adb');
  writeFileSync(adb, `#!/bin/sh\n: > "$FAKE_MARKER"\nexit 0\n`);
  chmodSync(adb, 0o755);
  const out = localRun(
    { ...env, adb, FAKE_MARKER: marker },
    `device_connect test-probe local && printf 'PICKED=%s' "$DEVICE_SERIAL"`
  );
  assert.equal(out.status, 0, out.out);
  assert.match(out.out, /PICKED=local/);
  assert.ok(!existsSync(marker), 'local mode ran adb');
  // It says which phone it is reading, and how it got root.
  assert.match(out.out, /reading this phone directly \(via su\)/);
});

test('a session answer of "local" is used without announcing it again', () => {
  // The menu asks once and passes 1 down; every probe would otherwise repeat
  // the line, which reads like a second, failed attempt.
  const { env } = localEnv({ DEVICE_LOCAL_REQUEST: '1' });
  const out = localRun(env, `device_connect test-probe && printf 'PICKED=%s' "$DEVICE_SERIAL"`);
  assert.equal(out.status, 0, out.out);
  assert.match(out.out, /PICKED=local/);
  assert.doesNotMatch(out.out, /reading this phone directly/);
});

test('a serial typed on the command line outranks the session answer', () => {
  const { adb, table } = fakeAdb(ONE_READY);
  const { env } = localEnv({ DEVICE_LOCAL_REQUEST: '1', adb, FAKE_DEVICES: table });
  const out = localRun(env, `device_connect test-probe RFCM90F5BBX && printf 'PICKED=%s' "$DEVICE_SERIAL"`);
  assert.equal(out.status, 0, out.out);
  assert.match(out.out, /PICKED=RFCM90F5BBX/);
});

test('the local shell is already root, so `su 0` is not escalated twice', () => {
  const { env, log } = localEnv();
  const out = localRun(
    env,
    `device_connect test-probe local >/dev/null 2>&1; : > "$FAKE_SU_LOG"; device_sh 'su 0 echo hello'`
  );
  assert.equal(out.status, 0, out.out);
  assert.equal(out.out.trim(), 'hello');
  assert.equal(readFileSync(log, 'utf8').trim(), 'echo hello');
});

test('a root-only file is read natively, quotes in the path and all', () => {
  const { dir, env } = localEnv();
  const remote = join(dir, "vendor's overlay.apk");
  writeFileSync(remote, 'PK-not-really-an-apk');
  const dest = join(dir, 'pulled.apk');
  const out = localRun(env, `device_connect test-probe local >/dev/null 2>&1; device_pull ${JSON.stringify(remote)} ${JSON.stringify(dest)}`);
  assert.equal(out.status, 0, out.out);
  assert.equal(readFileSync(dest, 'utf8'), 'PK-not-really-an-apk');
});

test('no escalator on the phone explains how to get one, and fails', () => {
  // A PATH with `id` and nothing else: no su, tsu or sudo to find.
  const dir = mkdtempSync(join(tmpdir(), 'adb-noroot-'));
  const bin = join(dir, 'bin');
  mkdirSync(bin, { recursive: true });
  const id = execFileSync('sh', ['-c', 'command -v id'], { encoding: 'utf8' }).trim();
  execFileSync('ln', ['-s', id, join(bin, 'id')]);
  const out = localRun(
    { PATH: bin, TERMUX_VERSION: '1', ROOT: dir, HOME: '/data/data/com.termux/files/home' },
    `device_connect test-probe local; printf 'rc=%s SERIAL=%s' "$?" "$DEVICE_SERIAL"`
  );
  assert.match(out.out, /rc=1/);
  assert.match(out.out, /needs root, and no su\/tsu\/sudo was found/);
  assert.match(out.out, /pkg install tsu/);
  assert.match(out.out, /SERIAL=$/);
});

test('root that is refused says so instead of reporting nothing', () => {
  const { dir } = localEnv();
  // su that fails the way a denied prompt does.
  const refused = join(dir, 'refused');
  mkdirSync(refused, { recursive: true });
  writeFileSync(join(refused, 'su'), '#!/bin/sh\nexit 1\n');
  chmodSync(join(refused, 'su'), 0o755);
  const out = localRun(
    { ...localEnv().env, PATH: `${refused}:${process.env.PATH}` },
    `device_connect test-probe local; printf 'rc=%s SERIAL=%s' "$?" "$DEVICE_SERIAL"`
  );
  assert.match(out.out, /rc=1/);
  assert.match(out.out, /root was not granted/);
  assert.match(out.out, /SERIAL=$/);
});

test('Termux without adb and without an answer offers the phone itself', () => {
  // A probe run straight from the command line, not through the menu: stdin is
  // not a terminal, so it cannot ask — and adb has nothing to dial, so the
  // direct source is the only one that can answer.
  const { dir, env } = localEnv({ ROOT: mkdtempSync(join(tmpdir(), 'adb-noroot-')) });
  // An adb that answers with an empty desk: "adb is present but sees no phone",
  // which is the case the offer exists for.
  const adb = join(dir, 'adb');
  writeFileSync(adb, `#!/bin/sh\nprintf 'List of devices attached\\n\\n'\n`);
  chmodSync(adb, 0o755);
  const out = localRun(
    { ...env, adb },
    `device_connect test-probe && printf 'PICKED=%s' "$DEVICE_SERIAL"`
  );
  assert.equal(out.status, 0, out.out);
  assert.match(out.out, /PICKED=local/);
});

test('in Termux a phone adb can already see is used, and the direct source is not offered', () => {
  // Wireless debugging exists on Termux: when adb really has a phone, that is
  // the phone the user is pointing at. Only an empty `adb devices` makes this
  // machine the obvious candidate.
  const { adb, table } = fakeAdb(ONE_READY);
  const { env } = localEnv({ adb, FAKE_DEVICES: table });
  const out = localRun(env, `device_connect test-probe && printf 'PICKED=%s' "$DEVICE_SERIAL"`);
  assert.equal(out.status, 0, out.out);
  assert.match(out.out, /PICKED=RFCM90F5BBX/);
  assert.doesNotMatch(out.out, /reading this phone directly/);
});

test('Termux with the offer declined points at running as root, not at adb', () => {
  const out = localRun(
    {
      PATH: '/nonexistent',
      TERMUX_VERSION: '1',
      DEVICE_LOCAL_REQUEST: '0',
      ROOT: mkdtempSync(join(tmpdir(), 'adb-noroot-')),
    },
    `device_connect test-probe; printf 'rc=%s SERIAL=%s' "$?" "$DEVICE_SERIAL"`
  );
  assert.match(out.out, /rc=1/);
  assert.match(out.out, /adb cannot reach a phone from Termux/);
  assert.match(out.out, /tsu .*\/build\.sh/);
  assert.doesNotMatch(out.out, /install platform-tools/);
});

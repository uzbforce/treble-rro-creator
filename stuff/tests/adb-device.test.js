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
import { execFileSync } from 'node:child_process';
import { chmodSync, mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const lib = join(root, 'stuff', 'scripts', 'adb-device.sh');

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
function pickUsing(adb, table, serialArg, { stdin = '' } = {}) {
  // 2>&1: the helper explains itself on stderr, and these tests are about that
  // explanation as much as about the serial.
  const script = `{ . "${lib}" && adb_pick_device "$FAKE_ADB" ${JSON.stringify(serialArg)} test-probe && printf 'PICKED=%s' "$DEVICE_SERIAL"; } 2>&1`;
  const run = () =>
    execFileSync('bash', ['-c', script], {
      env: { ...process.env, FAKE_ADB: adb, FAKE_DEVICES: table, TERM: 'dumb' },
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

function pick(devicesOutput, serialArg, { stdin = '' } = {}) {
  const { adb, table } = fakeAdb(devicesOutput);
  return pickUsing(adb, table, serialArg, { stdin });
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

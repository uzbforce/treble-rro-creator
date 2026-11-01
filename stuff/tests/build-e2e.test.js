// ---------------------------------------------------------------------------
// stuff/tests/build-e2e.test.js — a whole build, with no Android SDK
// ---------------------------------------------------------------------------
// Every other test here checks one generator. The build itself — resource
// staging, APK link/sign, module packaging, the hardware-overlay tree, the three
// zips — was only ever exercised by hand on a machine with aapt2, a JDK and a
// framework-res.apk, so a change that broke the last steps could ship unnoticed.
//
// This runs ./build.sh build -y in a throwaway copy of the repo against a fake
// toolchain: stub aapt2 / zipalign / apksigner / java in stuff/tools (which the
// build puts on PATH) and a dummy framework-res.apk. No SDK, no phone, no
// network. The stubs do not validate resources — they just have to produce the
// files the build expects at each step, so what is under test is the build's own
// plumbing and its assertions on the output.
//
// Run: node --test stuff/tests/build-e2e.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

function have(cmd) {
  return spawnSync('bash', ['-c', `command -v ${cmd}`], { encoding: 'utf8' }).status === 0;
}

// --- the fake tools -------------------------------------------------------
// aapt2 compile/link are the two that have to leave files behind: link's -o is
// copied to the output path, and compile writes one .flat per resource file so
// the `compiled/*.flat` glob in the link step is not left unexpanded.
const AAPT2 = `#!/bin/sh
verb="$1"; shift
case "$verb" in
  compile)
    dir=""; out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --dir) dir="$2"; shift 2 ;;
        -o) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$out" ] || exit 1
    mkdir -p "$out" || exit 1
    [ -d "$dir" ] || exit 1
    ( cd "$dir" && find . -type f -name '*.xml' | sed 's|^\\./||' ) | while IFS= read -r f; do
      base=$(printf '%s' "$f" | tr '/' '_')
      printf 'flat' > "$out/\${base%.xml}.flat"
    done
    ;;
  link)
    out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -n "$out" ] || exit 1
    mkdir -p "$(dirname "$out")" || exit 1
    printf 'fake-apk' > "$out"
    ;;
  dump)
    # framework_resource_index() needs at least one parsable entry, otherwise the
    # build stops with "Could not read the resource table".
    printf '  resource 0x01010000 bool/fake\\n'
    printf '  resource 0x01010001 dimen/fake\\n'
    ;;
esac
exit 0
`;

const ZIPALIGN = `#!/bin/sh
prev=""; last=""
for a in "$@"; do
  case "$a" in -*) ;; *) prev="$last"; last="$a" ;; esac
done
[ -n "$prev" ] && [ -n "$last" ] || exit 1
cp "$prev" "$last"
`;

const APKSIGNER = `#!/bin/sh
sub="$1"; shift
case "$sub" in
  sign)
    out=""; last=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) out="$2"; shift 2 ;;
        --key|--cert|--min-sdk-version|--max-sdk-version) shift 2 ;;
        -*) shift ;;
        *) last="$1"; shift ;;
      esac
    done
    [ -n "$out" ] && [ -n "$last" ] || exit 1
    mkdir -p "$(dirname "$out")" || exit 1
    cp "$last" "$out"
    ;;
  verify) : ;;
esac
exit 0
`;

function fakeTools(dir) {
  mkdirSync(dir, { recursive: true });
  for (const [name, body] of [
    ['aapt2', AAPT2],
    ['zipalign', ZIPALIGN],
    ['apksigner', APKSIGNER],
    ['java', '#!/bin/sh\nexit 0\n'],
  ]) {
    const p = join(dir, name);
    writeFileSync(p, body);
    chmodSync(p, 0o755);
  }
  // The build falls back to stuff/tools/framework-res.apk when the path in
  // config.env does not exist; its contents never matter to the stubs.
  writeFileSync(join(dir, 'framework-res.apk'), 'fake-resource-dictionary');
}

function run(cmd, opts = {}) {
  return spawnSync('bash', ['-c', cmd], { encoding: 'utf8', ...opts });
}

function copyRepo(dest) {
  // tar because it excludes with one flag and needs no rsync on Windows.
  const tar = run(
    `tar -cf - --exclude=.git --exclude=out --exclude=build --exclude=stuff/tools . \
        | tar -C ${JSON.stringify(dest)} -xf -`,
    { cwd: root }
  );
  assert.equal(tar.status, 0, `copying the repo failed: ${tar.stderr}`);
}

test('a full build runs against a fake toolchain and produces the three zips',
  { skip: !have('bash') || !have('zip') ? 'needs bash and zip' : false },
  () => {
    const tmp = mkdtempSync(join(tmpdir(), 'build-e2e-'));
    copyRepo(tmp);
    fakeTools(join(tmp, 'stuff', 'tools'));

    // A stable device name: the committed config.env is the placeholder template
    // and the assertions below look for out/<overlay>-ksu.zip by pattern, but the
    // module id also ends up inside the zip, so pin it.
    const cfg = run(
      `sed -i -e 's|^DEVICE_CODENAME=.*|DEVICE_CODENAME="zephyr"|' \
              -e 's|^DEVICE_MANUFACTURER=.*|DEVICE_MANUFACTURER="Xiaomi"|' config.env`,
      { cwd: tmp }
    );
    assert.equal(cfg.status, 0, `patching config.env failed: ${cfg.stderr}`);

    const build = spawnSync('bash', ['build.sh', 'build', '-y', '--allow-unknown-resources'], {
      cwd: tmp,
      encoding: 'utf8',
      timeout: 300000,
      env: {
        ...process.env,
        PATH: `${join(tmp, 'stuff', 'tools')}:${process.env.PATH}`,
        TREBLE_MENU: '0',
        TERM: 'dumb',
      },
    });
    const log = `${build.stdout}\n${build.stderr}`;
    assert.equal(build.status, 0, `build failed (exit ${build.status}):\n${log.slice(-4000)}`);

    // Guard against a build that exits 0 early: these lines only print at the end
    // of the pipeline, after signing and packaging.
    assert.match(log, /Module packaged: out\/.*-ksu\.zip/, 'the build stopped before packaging');
    assert.match(log, /Hardware Overlay TEST module created/, 'the test module was not built');

    // Nothing may be downloaded on this path: the toolchain is "complete" as far
    // as the build can tell, and every file it needs is already there.
    assert.doesNotMatch(log, /Downloading/, 'the build tried to download something');

    const out = readdirSync(join(tmp, 'out'));
    const zips = out.filter((f) => f.endsWith('.zip'));
    assert.ok(zips.some((f) => f.endsWith('-ksu.zip')), `no module zip in out/: ${zips}`);
    assert.ok(zips.some((f) => f.endsWith('-hardware-overlay.zip')), `no overlay repo zip: ${zips}`);
    assert.ok(zips.some((f) => f.endsWith('-hardware-overlay-test.zip')), `no test zip: ${zips}`);
    assert.ok(
      out.some((f) => f.endsWith('-overrides.txt')),
      `no resource audit report in out/: ${out}`
    );

    // What has to be in the flashable module, or the install does nothing:
    // the overlay APK, the module metadata, both boot scripts and the WebUI.
    const moduleZip = join(tmp, 'out', zips.find((f) => f.endsWith('-ksu.zip')));
    if (have('unzip')) {
      const list = run(`unzip -Z1 ${JSON.stringify(moduleZip)}`);
      assert.equal(list.status, 0, `unzip failed: ${list.stderr}`);
      const entries = list.stdout.split('\n');
      const has = (re) => entries.some((e) => re.test(e));
      assert.ok(has(/^module\.prop$/), `module.prop missing:\n${list.stdout}`);
      assert.ok(has(/^service\.sh$/), 'service.sh missing');
      assert.ok(has(/^post-fs-data\.sh$/), 'post-fs-data.sh missing');
      assert.ok(has(/^customize\.sh$/), 'customize.sh missing');
      assert.ok(has(/^system\/product\/overlay\/.+\.apk$/), `no overlay APK in the module:\n${list.stdout}`);
      assert.ok(has(/^webroot\/index\.html$/), 'webroot/index.html missing');
      assert.ok(has(/^webroot\/apply\.sh$/), 'webroot/apply.sh missing');
    }
  });
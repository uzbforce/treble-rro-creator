/* The submission zip has to match what Doze-off/vendor_hardware_overlay expects
   (the repo submissions go to; upstream TrebleDroid's tree is identical), or the
   pull request is rejected by their tests/tests.sh (or, worse, merged and never
   active on any device). These tests build the tree the way
   build.sh does — from resource XML generated into a temp directory, so a fresh
   clone needs no Android tools — and check it against the repo's rules.

   Run: node --test tests/ */

"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const ROOT = path.join(__dirname, "..");

// tests/blacklist of the overlay repo: resources an overlay may not define.
const BLACKLIST = [
  "config_useRoundIcon",
  "config_swipe_up_gesture_setting_available",
  "config_cameraDoubleTapPowerGestureEnabled",
  "config_cellBroadcastAppLinks",
  "config_doublePressOnPowerBehavior",
  "config_dozeComponent",
  "config_enableAutoPowerModes",
  "config_enableMultiUserUI",
  "config_mainBuiltInDisplayIsRound",
  "config_multiuserMaximumUsers",
  "config_screen_magnification_multi_tap_adjustment",
  "config_swipe_up_gesture_default",
  "config_allowAllRotations",
  "config_volumeAdjustmentForRemoteGroupSessions",
  "config_unplugTurnsOnScreen",
];

// MSYS/Git Bash accepts C:/... but not the backslashes node.join() produces.
function bashPath(p) {
  return p.split(path.sep).join("/");
}

function baseConfig(extra = "") {
  return [
    'DEVICE_MANUFACTURER="samsung"',
    'DEVICE_MODEL="Galaxy A90 5G"',
    'DEVICE_CODENAME="r3q"',
    "OVERLAY_PRIORITY=628",
    "OVERLAY_PRIORITY_SYSTEMUI=9999",
    extra,
    "",
  ].join("\n");
}

// buildTree <opts> -> { dir, out, stdout, stderr }
//   extraConfig: appended to the generated config.env
//   powerProfile: "real" (a profile with data) or "placeholder" (no <item>)
//   env: extra environment for the script
function buildTree(opts = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "treble-hwoverlay-"));
  const res = path.join(dir, "res");
  // The committed resources plus the generated ones, like a real build.
  fs.cpSync(path.join(ROOT, "src/framework/res"), path.join(res, "framework/res"), { recursive: true });
  fs.cpSync(path.join(ROOT, "src/systemui/res"), path.join(res, "systemui/res"), { recursive: true });
  exec("tests/gen-res.sh", [bashPath(res)], dir);

  const xmlDir = path.join(res, "framework/res/xml");
  fs.mkdirSync(xmlDir, { recursive: true });
  fs.writeFileSync(
    path.join(xmlDir, "power_profile.xml"),
    (opts.powerProfile || "real") === "real"
      ? '<?xml version="1.0" encoding="utf-8"?>\n<device name="Android">\n    <item name="screen.on">66.06</item>\n    <item name="battery.capacity">4900</item>\n</device>\n'
      : '<?xml version="1.0" encoding="utf-8"?>\n<device name="Android">\n    <!-- extract from your firmware -->\n</device>\n'
  );

  const cfg = path.join(dir, "config.env");
  fs.writeFileSync(cfg, baseConfig(opts.extraConfig));

  const out = path.join(dir, "tree");
  const proc = spawnSync(
    "bash",
    ["scripts/hardware-overlay.sh", "write", bashPath(out), bashPath(cfg)],
    {
      cwd: ROOT,
      encoding: "utf8",
      env: {
        ...process.env,
        RES_DIR: bashPath(path.join(res, "framework/res")),
        SYSUI_RES_DIR: bashPath(path.join(res, "systemui/res")),
        ...(opts.env || {}),
      },
    }
  );
  assert.strictEqual(proc.status, 0, "hardware-overlay.sh failed:\n" + proc.stdout + proc.stderr);
  return { dir, out, stdout: proc.stdout, stderr: proc.stderr };
}

function exec(cmd, args, dir) {
  const proc = spawnSync("bash", [cmd, ...args], { cwd: ROOT, encoding: "utf8" });
  assert.strictEqual(proc.status, 0, cmd + " failed:\n" + proc.stdout + proc.stderr);
  return proc;
}

function read(p) {
  return fs.readFileSync(p, "utf8");
}

function walk(dir, acc = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) walk(full, acc);
    else acc.push(full);
  }
  return acc;
}

const tree = buildTree();
const fw = path.join(tree.out, "samsung/r3q");
const sui = path.join(tree.out, "samsung/r3q-SystemUI");

test("the tree is laid out the way the repo expects", () => {
  for (const f of ["AndroidManifest.xml", "Android.mk", "res/values/config.xml", "res/values/generated.xml"]) {
    assert.ok(fs.existsSync(path.join(fw, f)), "samsung/r3q/" + f);
  }
  assert.ok(fs.existsSync(path.join(sui, "AndroidManifest.xml")), "samsung/r3q-SystemUI");
  assert.ok(fs.existsSync(path.join(tree.out, "_submission/overlay.mk.lines")));
  assert.ok(fs.existsSync(path.join(tree.out, "_submission/HOW-TO-SUBMIT.md")));
});

test("the framework manifest is a static overlay of android", () => {
  const manifest = read(path.join(fw, "AndroidManifest.xml"));
  assert.match(manifest, /package="me\.phh\.treble\.overlay\.samsung\.r3q"/);
  assert.match(manifest, /android:targetPackage="android"/);
  assert.match(manifest, /android:isStatic="true"/);
  assert.match(manifest, /android:priority="\d+"/);
});

test("the match value is exact — no glob the framework would never match", () => {
  const manifest = read(path.join(fw, "AndroidManifest.xml"));
  const value = /requiredSystemPropertyValue="([^"]*)"/.exec(manifest);
  assert.ok(value, "a match value is written");
  assert.doesNotMatch(value[1], /[*]/, "no wildcard: " + value[1]);
  assert.doesNotMatch(value[1], /^[+-]/, "no +/- prefix: " + value[1]);
  assert.strictEqual(value[1], "r3q", "the device codename");
  assert.match(manifest, /requiredSystemPropertyName="ro\.product\.vendor\.device"/);
});

test("the SystemUI overlay targets com.android.systemui", () => {
  const manifest = read(path.join(sui, "AndroidManifest.xml"));
  assert.match(manifest, /package="me\.phh\.treble\.overlay\.samsung\.r3q\.systemui"/);
  assert.match(manifest, /android:targetPackage="com\.android\.systemui"/);
  assert.match(manifest, /android:isStatic="true"/);
});

test("the Android.mk files install into product/overlay", () => {
  for (const [dir, name] of [
    [fw, "treble-overlay-samsung-r3q"],
    [sui, "treble-overlay-samsung-r3q-systemui"],
  ]) {
    const mk = read(path.join(dir, "Android.mk"));
    assert.match(mk, new RegExp("LOCAL_PACKAGE_NAME := " + name));
    assert.match(mk, /LOCAL_MODULE_PATH := \$\(TARGET_OUT_PRODUCT\)\/overlay/);
    assert.match(mk, /LOCAL_IS_RUNTIME_RESOURCE_OVERLAY := true/);
    assert.match(mk, /include \$\(BUILD_PACKAGE\)/);
  }
});

test("no resource from the repo's blacklist survives into the submission", () => {
  const offenders = [];
  for (const file of walk(tree.out)) {
    if (!file.endsWith(".xml")) continue;
    const text = read(file);
    for (const name of BLACKLIST) {
      if (text.includes('name="' + name + '"')) offenders.push(path.relative(tree.out, file) + ": " + name);
    }
  }
  assert.deepStrictEqual(offenders, [], "blacklisted resources in the submission");
});

test("the resources the module would set are still in the source XML", () => {
  // The filtering is for the submission only — the module keeps them.
  const src = read(path.join(ROOT, "src/framework/res/values/config.xml"));
  assert.match(src, /name="config_dozeComponent"/);
});

test("overlay.mk lines are one per module, tab indented and continued", () => {
  const lines = read(path.join(tree.out, "_submission/overlay.mk.lines")).split(/\r?\n/).filter(Boolean);
  assert.deepStrictEqual(lines, [
    "\ttreble-overlay-samsung-r3q \\",
    "\ttreble-overlay-samsung-r3q-systemui \\",
  ]);
});

test("the submission notes name the getprop to check", () => {
  const notes = read(path.join(tree.out, "_submission/HOW-TO-SUBMIT.md"));
  assert.match(notes, /adb shell getprop ro\.product\.vendor\.device/);
  assert.match(notes, /overlay\.mk/);
  // `cmd overlay` takes the package name, never the module name.
  assert.match(notes, /cmd overlay lookup me\.phh\.treble\.overlay\.samsung\.r3q /);
});

test("the submission notes send the pull request to the maintained repo", () => {
  const notes = read(path.join(tree.out, "_submission/HOW-TO-SUBMIT.md"));
  // The repo the guide targets, its only active branch, and the fact that the
  // fork has no CI — a guide naming another repo, or implying a green check
  // will appear, sends people to the wrong place.
  assert.match(notes, /github\.com\/Doze-off\/vendor_hardware_overlay/);
  assert.match(notes, /base branch\s+`pie`/);
  assert.match(notes, /nothing runs them for you/i);
  assert.match(notes, /aapt bundled in build\//);
  assert.doesNotMatch(notes, /PR against `TrebleDroid\//);
});

test("the priority is not one the repo already uses", () => {
  const manifest = read(path.join(fw, "AndroidManifest.xml"));
  const priority = /android:priority="(\d+)"/.exec(manifest)[1];
  const used = new Set(
    read(path.join(ROOT, "scripts/data/treble-overlay-priorities.txt"))
      .split(/\r?\n/)
      .filter((l) => /^\d+$/.test(l))
  );
  assert.ok(!used.has(priority), "priority " + priority + " is taken in the repo");
});

test("a real power_profile.xml is shipped", () => {
  assert.ok(fs.existsSync(path.join(fw, "res/xml/power_profile.xml")), "res/xml/power_profile.xml");
});

test("the empty power_profile template is left out", () => {
  const t = buildTree({ powerProfile: "placeholder" });
  assert.ok(!fs.existsSync(path.join(t.out, "samsung/r3q/res/xml/power_profile.xml")), "placeholder shipped");
});

test("an empty match property submits an always-active overlay", () => {
  const t = buildTree({ extraConfig: 'HW_OVERLAY_MATCH_PROP=""' });
  const manifest = read(path.join(t.out, "samsung/r3q/AndroidManifest.xml"));
  assert.doesNotMatch(manifest, /requiredSystemProperty/);
  assert.match(manifest, /android:isStatic="true"/);
});

test("a glob value is reported, because it can never match", () => {
  const t = buildTree({ extraConfig: 'HW_OVERLAY_MATCH_VALUE="+*samsung/r3q*"' });
  // warn() writes to stdout, err() to stderr — accept either.
  assert.match(t.stdout + t.stderr, /looks like a glob/i);
});

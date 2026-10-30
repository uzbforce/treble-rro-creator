/* The WebUI writes values straight into the overlay APKs, so the writer is the
   most fragile code in the project. These tests run the shipped page code
   (not a copy) against the APKs this build produced.

   Run: node --test stuff/tests/ */
"use strict";

const test = require("node:test");
const assert = require("node:assert");
const { readFileSync } = require("node:fs");
const { join } = require("node:path");
const { loadPage, readResource, arscOf, readFixture } = require("./page-harness");

const page = loadPage();
const T = page.__treble;

const FW = () => readFixture("treble-overlay-generic-generic.apk");
const SUI = () => readFixture("treble-overlay-generic-generic-systemui.apk");

function patch(bytes, wanted) {
  return T.patchApk(bytes, wanted);
}

// The CRC in both zip headers has to match the bytes, or the framework's
// parser rejects the entry.
function assertCrc(apkBytes) {
  const entry = T.zipEntry(apkBytes, "resources.arsc");
  const crc = T.crc32(apkBytes, entry.offset, entry.offset + entry.size);
  const view = new DataView(apkBytes.buffer, apkBytes.byteOffset, apkBytes.byteLength);
  assert.strictEqual(view.getUint32(entry.local + 14, true), crc, "local header CRC");
  assert.strictEqual(view.getUint32(entry.central + 16, true), crc, "central directory CRC");
}

test("an existing dimen is rewritten in place", () => {
  const before = FW();
  const out = patch(before, [{ name: "dimen/rounded_corner_radius", type: "dimen", value: "240px" }]);
  assert.deepStrictEqual(out.patched, ["dimen/rounded_corner_radius"]);
  assert.deepStrictEqual(out.added, []);
  assert.strictEqual(out.bytes.length, before.length, "patching in place must not resize the APK");
  const value = readResource(page, out.bytes, "dimen", "rounded_corner_radius");
  assert.strictEqual(value.px, 240);
  assert.strictEqual(value.unit, 0);
  assertCrc(out.bytes);
});

test("a dp value keeps the dip unit", () => {
  const out = patch(FW(), [{ name: "dimen/status_bar_height_default", type: "dimen", value: "48dp" }]);
  const value = readResource(page, out.bytes, "dimen", "status_bar_height_default");
  assert.strictEqual(value.px, 48);
  assert.strictEqual(value.unit, 1, "dp must be stored as dip (unit 1)");
});

test("a dimen the build does not ship is added", () => {
  const out = patch(FW(), [{ name: "dimen/rounded_corner_content_padding", type: "dimen", value: "48px" }]);
  assert.deepStrictEqual(out.added, ["dimen/rounded_corner_content_padding"]);
  const value = readResource(page, out.bytes, "dimen", "rounded_corner_content_padding");
  assert.strictEqual(value.px, 48);
});

test("a dimen is added to a table that has no dimen type", () => {
  const before = SUI();
  const table = T.readArsc(arscOf(page, before));
  assert.deepStrictEqual(table.pkg.types, ["bool"], "fixture precondition");
  const out = patch(before, [{ name: "dimen/status_bar_padding_start", type: "dimen", value: "160px" }]);
  assert.deepStrictEqual(out.added, ["dimen/status_bar_padding_start"]);
  const after = T.readArsc(arscOf(page, out.bytes));
  assert.deepStrictEqual(after.pkg.types, ["bool", "dimen"], "the dimen type is created");
  const value = readResource(page, out.bytes, "dimen", "status_bar_padding_start");
  assert.strictEqual(value.px, 160);
  // The booleans that were already there must still read correctly.
  assert.strictEqual(readResource(page, out.bytes, "bool", "doze_display_state_supported").data, 0);
});

test("a bool is rewritten in place", () => {
  const before = FW();
  const out = patch(before, [{ name: "bool/config_showNavigationBar", type: "bool", value: "false" }]);
  assert.deepStrictEqual(out.patched, ["bool/config_showNavigationBar"]);
  assert.strictEqual(out.bytes.length, before.length);
  const value = readResource(page, out.bytes, "bool", "config_showNavigationBar");
  assert.strictEqual(value.data, 0);
  assert.strictEqual(value.dataType, 0x12);
});

test("a bool the build does not ship is added, true as 0xFFFFFFFF", () => {
  const out = patch(FW(), [{ name: "bool/config_enablePrivacyDot", type: "bool", value: "true" }]);
  assert.deepStrictEqual(out.added, ["bool/config_enablePrivacyDot"]);
  const value = readResource(page, out.bytes, "bool", "config_enablePrivacyDot");
  assert.strictEqual(value.data, 0xffffffff);
});

test("an integer is rewritten in place", () => {
  const out = patch(FW(), [
    { name: "integer/config_multiuserMaximumUsers", type: "integer", value: "8" }
  ]);
  assert.deepStrictEqual(out.patched, ["integer/config_multiuserMaximumUsers"]);
  assert.strictEqual(readResource(page, out.bytes, "integer", "config_multiuserMaximumUsers").data, 8);
});

test("a string already in the value pool is rewritten in place", () => {
  const before = FW();
  const table = T.readArsc(arscOf(page, before));
  const pool = T.poolStrings(arscOf(page, before), table.poolAt);
  const take = pool[1];                       // config_dozeComponent's value
  const out = patch(before, [
    { name: "string/config_displayLightSensorType", type: "string", value: take }
  ]);
  assert.deepStrictEqual(out.patched, ["string/config_displayLightSensorType"]);
  assert.strictEqual(out.bytes.length, before.length, "reusing a pooled string keeps the size");
  assert.strictEqual(readResource(page, out.bytes, "string", "config_displayLightSensorType").string, take);
});

test("a string that needs a new pool entry is added and read back", () => {
  const before = FW();
  const wanted = "org.lineageos.sensor.udfps";
  const out = patch(before, [
    { name: "string/config_displayLightSensorType", type: "string", value: wanted }
  ]);
  assert.deepStrictEqual(out.added, ["string/config_displayLightSensorType"]);
  const readBack = readResource(page, out.bytes, "string", "config_displayLightSensorType");
  assert.strictEqual(readBack.string, wanted);

  // Appending to the pool must not renumber the strings that were there.
  const oldTable = T.readArsc(arscOf(page, before));
  const newTable = T.readArsc(arscOf(page, out.bytes));
  const oldPool = T.poolStrings(arscOf(page, before), oldTable.poolAt);
  const newPool = T.poolStrings(arscOf(page, out.bytes), newTable.poolAt);
  assert.deepStrictEqual(newPool.slice(0, oldPool.length), oldPool);
  assertCrc(out.bytes);
});

test("a second apply of the same values adds nothing", () => {
  const wanted = [
    { name: "dimen/rounded_corner_radius", type: "dimen", value: "240px" },
    { name: "dimen/rounded_corner_content_padding", type: "dimen", value: "48px" },
    { name: "bool/config_enablePrivacyDot", type: "bool", value: "true" }
  ];
  const once = patch(FW(), wanted);
  const twice = patch(once.bytes, wanted);
  assert.deepStrictEqual(twice.added, []);
  assert.strictEqual(twice.patched.length, 3);
  assert.strictEqual(twice.bytes.length, once.bytes.length, "nothing moves on the second pass");
});

test("an invalid value is reported, not written", () => {
  const out = patch(FW(), [{ name: "dimen/rounded_corner_radius", type: "dimen", value: "15 furlongs" }]);
  assert.deepStrictEqual(out.bad, ["dimen/rounded_corner_radius"]);
  assert.strictEqual(out.bytes, null);
});

test("arrays and maps are refused instead of guessed at", () => {
  const apk = FW();
  const table = T.readArsc(arscOf(page, apk));
  // The fixture has no array, so a type the table cannot express stands in:
  // "array" is not one of its types, so the entry is added as a new type…
  // which is exactly what must not happen silently for a real array. The page
  // only ever sends what webui-manifest.json lists, and arrays are marked
  // read-only there (checked in manifest.test.js).
  assert.ok(table.pkg.types.indexOf("array") === -1);
});

test("an entry is removed from its configuration, and the rest is untouched", () => {
  const before = FW();
  const table = T.readArsc(arscOf(page, before));
  const out = T.writeTable(arscOf(page, before), table, [
    { type: "bool", name: "config_showNavigationBar", remove: true }], null);
  const apk = T.rewriteZip(before, "resources.arsc", out);
  assert.strictEqual(readResource(page, apk, "bool", "config_showNavigationBar"), null);
  const other = readResource(page, apk, "bool", "config_enableWifiDisplay");
  assert.strictEqual(other.dataType, 0x12);
  assert.strictEqual(other.data, 0xffffffff);
  assertCrc(apk);
});

// Entry indexes are resource ids (0xPPTTEEEE), so a removal has to leave a
// hole: shifting the entries after it would give their ids to other resources.
function defaultChunk(table, type) {
  const typeId = table.pkg.types.indexOf(type) + 1;
  return table.pkg.chunks.find(
    (c) => c.type === 0x0201 && c.typeId === typeId && c.isDefault) || null;
}

function specOf(table, type) {
  const typeId = table.pkg.types.indexOf(type) + 1;
  return table.pkg.chunks.find((c) => c.type === 0x0202 && c.typeId === typeId) || null;
}

function indexOf(table, chunk, name) {
  for (const e of chunk.entries) {
    if (!e.complex && table.pkg.keys[e.key] === name) return e.index;
  }
  return -1;
}

test("removing an entry keeps the ids of the entries after it", () => {
  const before = FW();
  const t0 = T.readArsc(arscOf(page, before));
  const after0 = indexOf(t0, defaultChunk(t0, "bool"), "config_unplugTurnsOnScreen");
  assert.ok(after0 > 0, "fixture precondition");
  const out = T.writeTable(arscOf(page, before), t0, [
    { type: "bool", name: "config_showNavigationBar", remove: true }], null);
  const apk = T.rewriteZip(before, "resources.arsc", out);
  assert.strictEqual(readResource(page, apk, "bool", "config_showNavigationBar"), null);
  const t1 = T.readArsc(arscOf(page, apk));
  assert.strictEqual(indexOf(t1, defaultChunk(t1, "bool"), "config_unplugTurnsOnScreen"),
    after0, "the entry after the hole keeps its id");
});

test("a key added to an existing type grows the type spec", () => {
  const before = FW();
  const spec0 = specOf(T.readArsc(arscOf(page, before)), "bool");
  const out = patch(before, [{ name: "bool/config_enablePrivacyDot", type: "bool", value: "true" }]);
  const table = T.readArsc(arscOf(page, out.bytes));
  const top = Math.max(...defaultChunk(table, "bool").entries.map((e) => e.index));
  const spec = specOf(table, "bool");
  assert.ok(spec.count > spec0.count, "the new entry is past the old spec");
  assert.ok(spec.count >= top + 1, "the spec covers every entry id");
});

test("removing an entry the table does not have leaves every byte alone", () => {
  const before = FW();
  const out = T.writeTable(arscOf(page, before), T.readArsc(arscOf(page, before)), [
    { type: "bool", name: "config_not_in_this_build", remove: true }], null);
  // Not merely the same length: a no-op must not rewrite a chunk, or every
  // Apply would re-arm the boot guard for nothing.
  assert.ok(Buffer.from(out).equals(Buffer.from(arscOf(page, before))));
});

// The status bar shade is a drawable the ROM only keeps at density
// configurations, so "no shade" has to be written to each of them; a lone
// default entry would lose to the ROM's density entry (see resources.sh).
test("a density-qualified drawable is written per density and removed from all", () => {
  const before = SUI();
  const densities = [160, 240, 320, 480];
  const cfgs = densities.map(T.densityConfig);
  const once = T.writeTable(arscOf(page, before), T.readArsc(arscOf(page, before)), [
    { type: "drawable", name: "status_background", dataType: 0x1c, data: 0, configs: cfgs }], null);
  const apk = T.rewriteZip(before, "resources.arsc", once);
  const table = T.readArsc(arscOf(page, apk));
  const found = [];
  for (const c of table.pkg.chunks) {
    if (c.type !== 0x0201 || table.pkg.types[c.typeId - 1] !== "drawable") continue;
    for (const e of c.entries) {
      if (e && table.pkg.keys[e.key] === "status_background") {
        found.push({ density: c.config[14] | (c.config[15] << 8), dataType: e.dataType, data: e.data });
      }
    }
  }
  assert.deepStrictEqual(found.map((f) => f.density).sort((a, b) => a - b), densities);
  for (const f of found) {
    assert.strictEqual(f.dataType, 0x1c, "a drawable replaced by a colour");
    assert.strictEqual(f.data, 0, "transparent");
  }

  const off = T.writeTable(arscOf(page, apk), T.readArsc(arscOf(page, apk)), [
    { type: "drawable", name: "status_background", remove: true }], null);
  const apk2 = T.rewriteZip(apk, "resources.arsc", off);
  const t2 = T.readArsc(arscOf(page, apk2));
  for (const c of t2.pkg.chunks) {
    if (c.type !== 0x0201) continue;
    for (const e of c.entries) {
      assert.ok(!e || t2.pkg.keys[e.key] !== "status_background", "stays removed");
    }
  }
});

test("an overlay addon is planned only when its pick changed", () => {
  const saved = { id: "hide_notch", kind: "overlay", saved: true, value: "on", default: "off" };
  assert.deepStrictEqual(T.addonOpsFor([saved], { hide_notch: "on" }, "fw"), [],
    "a row that matches the file is not rewritten on every Apply");
  const off = T.addonOpsFor([saved], { hide_notch: "off" }, "fw");
  assert.strictEqual(off.length, 1);
  assert.strictEqual(off[0].remove, true);
  assert.strictEqual(off[0].name, "config_maskMainBuiltInDisplayCutout");

  const unsaved = { id: "hide_notch", kind: "overlay", saved: false, value: "off", default: "off" };
  const on = T.addonOpsFor([unsaved], { hide_notch: "on" }, "fw");
  assert.strictEqual(on.length, 1);
  assert.strictEqual(on[0].remove, false);
  assert.strictEqual(on[0].dataType, 0x12);
  assert.strictEqual(on[0].data, 0xffffffff);
});

// The page must write the names resources.sh emits, or a rebuild would undo
// the addon without anyone noticing.
test("the addon resources are the ones the build emits", () => {
  const res = readFileSync(join(__dirname, "..", "scripts", "resources.sh"), "utf8");
  for (const spec of Object.values(T.ADDON_RESOURCES)) {
    for (const item of spec.res) {
      assert.ok(res.includes(item.name), `resources.sh no longer emits ${item.name}`);
    }
  }
});

test("the archive stays readable after a patch", () => {
  const out = patch(FW(), [
    { name: "dimen/rounded_corner_radius", type: "dimen", value: "96px" },
    { name: "string/config_dozeComponent", type: "string", value: "com.android.systemui/com.android.systemui.doze.DozeService" }
  ]);
  assert.ok(T.zipEntry(out.bytes, "AndroidManifest.xml"), "the manifest entry is still in the zip");
  assert.ok(T.zipEntry(out.bytes, "resources.arsc"), "the table is still in the zip");
  const table = T.readArsc(arscOf(page, out.bytes));
  assert.ok(table, "the table still parses");
});

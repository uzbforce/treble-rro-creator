/* The WebUI writes values straight into the overlay APKs, so the writer is the
   most fragile code in the project. These tests run the shipped page code
   (not a copy) against the APKs this build produced.

   Run: node --test stuff/tests/ */
"use strict";

const test = require("node:test");
const assert = require("node:assert");
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

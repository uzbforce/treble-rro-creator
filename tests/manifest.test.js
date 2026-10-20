/* The page renders itself from webroot/webui-manifest.json, so the manifest has
   to describe the build's resources correctly: a stable resource key, a value,
   the APK it lives in, and read-only for anything the page cannot write.

   Run: node --test tests/ */
"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.join(__dirname, "..");

function buildManifest() {
  const out = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "treble-manifest-")), "webui-manifest.json");
  execFileSync("bash", ["scripts/manifest.sh", "write", out], { cwd: ROOT, stdio: "pipe" });
  return JSON.parse(fs.readFileSync(out, "utf8"));
}

const manifest = buildManifest();

test("the manifest is valid JSON with a resource list", () => {
  assert.ok(Array.isArray(manifest.resources), "resources[]");
  assert.ok(manifest.resources.length > 0, "the build writes at least one resource");
  assert.ok(manifest.id, "the module id is recorded");
});

test("every entry has a resource key, a value and an APK", () => {
  for (const r of manifest.resources) {
    assert.strictEqual(r.res, `${r.apk}:${r.type}/${r.name}`, "res is apk:type/name");
    assert.ok(["fw", "sui"].includes(r.apk), "apk is fw or sui: " + r.apk);
    assert.ok(["dimen", "bool", "integer", "string", "array"].includes(r.type), "type: " + r.type);
    assert.strictEqual(typeof r.value, "string", "value is a string: " + r.res);
    assert.strictEqual(typeof r.group, "string", "group: " + r.res);
    assert.strictEqual(typeof r.ro, "boolean", "ro: " + r.res);
  }
});

test("no resource is listed twice", () => {
  const seen = new Set();
  for (const r of manifest.resources) {
    assert.ok(!seen.has(r.res), "duplicate: " + r.res);
    seen.add(r.res);
  }
});

test("arrays are read-only (one value per overlay resource)", () => {
  const arrays = manifest.resources.filter((r) => r.type === "array");
  for (const r of arrays) assert.strictEqual(r.ro, true, r.res + " must be read-only");
});

test("dimens and bools the sliders do not cover are editable", () => {
  const editable = manifest.resources.filter((r) => !r.ro).map((r) => r.res);
  // From the generated XML: these exist whatever config.env says.
  assert.ok(editable.includes("fw:dimen/rounded_corner_radius"), "radius");
  assert.ok(editable.some((k) => k === "sui:bool/doze_display_state_supported"), "a SystemUI bool");
});

test("a value that is a resource reference is read-only", () => {
  for (const r of manifest.resources) {
    if (/^[@?]/.test(r.value)) assert.strictEqual(r.ro, true, r.res + " references another resource");
  }
});

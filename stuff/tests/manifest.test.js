/* The page renders itself from webroot/webui-manifest.json, so the manifest has
   to describe the build's resources correctly: a stable resource key, a value,
   the APK it lives in, and read-only for anything the page cannot write.

   The manifest is built from the XML in src/framework/res and src/systemui/res,
   and the generated part of that XML is gitignored (it is a build artifact). The
   test therefore generates it first, from the fixed config in stuff/tests/gen-res.sh,
   into a temp tree — the result must not depend on whether this checkout has
   been built, nor on the local config.env.

   Run: node --test stuff/tests/ */
"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.join(__dirname, "..", "..");

// MSYS/Git Bash accepts C:/... but not the backslashes node.join() produces.
function bashPath(p) {
  return p.split(path.sep).join("/");
}

function buildManifest() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "treble-manifest-"));
  const res = path.join(dir, "res");
  execFileSync("bash", ["stuff/tests/gen-res.sh", bashPath(res)], { cwd: ROOT, stdio: "pipe" });

  const out = path.join(dir, "webui-manifest.json");
  execFileSync("bash", ["stuff/scripts/manifest.sh", "write", bashPath(out)], {
    cwd: ROOT,
    stdio: "pipe",
    env: {
      ...process.env,
      RES_DIR: bashPath(path.join(res, "framework/res")),
      SYSUI_RES_DIR: bashPath(path.join(res, "systemui/res")),
    },
  });
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
  assert.ok(editable.includes("sui:dimen/status_bar_padding_start"), "a SystemUI dimen");
  assert.ok(editable.some((k) => k === "sui:bool/doze_display_state_supported"), "a SystemUI bool");
});

test("a value that is a resource reference is read-only", () => {
  for (const r of manifest.resources) {
    if (/^[@?]/.test(r.value)) assert.strictEqual(r.ro, true, r.res + " references another resource");
  }
});

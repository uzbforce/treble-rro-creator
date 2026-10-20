/* Loads src/webui/index.html's script in a sandbox with a DOM stub.
   The page is one IIFE that wires itself up on load; in Node there is no
   document, so every element is a no-op stand-in and the resource-table
   functions are reached through window.__treble (the page's own test hook).
   The point is to test the shipped code, not a copy of it. */
"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const PAGE = path.join(__dirname, "..", "src", "webui", "index.html");

// Any property access returns another stub (except a few that the page reads
// as values), so getElementById(...).style.setProperty(...) and friends are
// harmless.
function fakeEl() {
  const store = {};
  return new Proxy(store, {
    get(target, key) {
      if (key === Symbol.toPrimitive) return () => "";
      if (key in target) return target[key];
      return function () { return fakeEl(); };
    },
    set(target, key, value) { target[key] = value; return true; }
  });
}

function loadPage(pagePath) {
  const file = pagePath || PAGE;
  const html = fs.readFileSync(file, "utf8");
  const scripts = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)];
  if (!scripts.length) throw new Error("no <script> block in " + file);
  const source = scripts[scripts.length - 1][1];

  // The page is run as a function in *this* realm (not a vm context), so the
  // arrays and typed arrays it creates behave like normal Node ones when a
  // test compares them.
  const noopTimer = function () { return 0; };
  const win = { location: { href: "file:///data/adb/modules/test/webroot/index.html" } };
  const factory = new Function(
    "window", "document", "navigator", "setTimeout", "clearTimeout",
    "setInterval", "clearInterval", "console", "atob", "btoa",
    source
  );
  factory.call(win, win, fakeEl(), { userAgent: "node" }, noopTimer, noopTimer,
    noopTimer, noopTimer, console,
    (s) => Buffer.from(String(s), "base64").toString("binary"),
    (s) => Buffer.from(String(s), "binary").toString("base64"));
  if (!win.__treble) throw new Error("the page did not expose its test hook");
  win.__treble.window = win;
  return win;
}

// A resource value as the framework would read it out of the default config.
function readResource(page, apkBytes, type, name) {
  const T = page.__treble;
  const entry = T.zipEntry(apkBytes, "resources.arsc");
  const arsc = apkBytes.subarray(entry.offset, entry.offset + entry.size);
  const table = T.readArsc(arsc);
  if (!table) throw new Error("resources.arsc did not parse");
  const pool = T.poolStrings(arsc, table.poolAt);
  const typeId = table.pkg.types.indexOf(type) + 1;
  for (const chunk of table.pkg.chunks) {
    if (chunk.type !== 0x0201 || !chunk.isDefault || chunk.typeId !== typeId) continue;
    for (const e of chunk.entries) {
      if (!e || e.complex) continue;
      if (table.pkg.keys[e.key] !== name) continue;
      return {
        dataType: e.dataType,
        data: e.data,
        string: e.dataType === 0x03 ? pool[e.data] : null,
        // complex dimension: (value << 8) | unit (0 = px, 1 = dip)
        px: e.dataType === 0x05 ? (e.data >>> 8) : null,
        unit: e.dataType === 0x05 ? (e.data & 0xff) : null
      };
    }
  }
  return null;
}

function arscOf(page, apkBytes) {
  const entry = page.__treble.zipEntry(apkBytes, "resources.arsc");
  return apkBytes.subarray(entry.offset, entry.offset + entry.size);
}

function readFixture(rel) {
  return new Uint8Array(fs.readFileSync(path.join(__dirname, "fixtures", rel)));
}

module.exports = { loadPage, readResource, arscOf, readFixture, fakeEl };

/* Every relative link in the docs and the README has to point at a real file
   and, when it carries #anchor, at a heading that exists. The docs cross-link a
   lot (config.env points into docs/configuration.md, troubleshooting points at
   sections elsewhere), and a renamed heading otherwise only shows up as a dead
   link on GitHub.

   Run: node stuff/tests/docs-links.js */
"use strict";

const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..", "..");
const errors = [];

// GitHub's heading slug: lowercase, drop everything that is not a letter,
// digit, space, hyphen or underscore, then spaces -> hyphens. Spaces are not
// collapsed: "padding (start / end)" becomes "padding-start--end", which is
// why the anchors in these docs have a double hyphen.
function slug(text) {
  return text
    .trim()
    .toLowerCase()
    .replace(/<[^>]+>/g, "")
    .replace(/[`*~]/g, "")
    .replace(/[^\p{L}\p{N}\s_-]/gu, "")
    .replace(/ /g, "-");
}

function anchorsOf(file) {
  const text = fs.readFileSync(file, "utf8");
  const out = new Set();
  const seen = new Map();
  for (const line of text.split(/\r?\n/)) {
    const m = /^(#{1,6})\s+(.*)$/.exec(line);
    if (!m) continue;
    const base = slug(m[2]);
    // GitHub suffixes repeated headings: name, name-1, name-2 …
    const n = seen.get(base) || 0;
    seen.set(base, n + 1);
    out.add(n === 0 ? base : base + "-" + n);
  }
  return out;
}

function markdownFiles(dir, acc = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    // Downloaded trees are not ours: Go's own docs come with the toolchain
    // fetch in gui/build.sh, and theirs are written for golang.org.
    if (entry.name === "node_modules" || entry.name.startsWith(".") ||
        entry.name.startsWith("_") || entry.name === "build" || entry.name === "out") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) markdownFiles(full, acc);
    else if (/\.md$/i.test(entry.name)) acc.push(full);
  }
  return acc;
}

const cache = new Map();
function anchorsFor(file) {
  if (!cache.has(file)) cache.set(file, anchorsOf(file));
  return cache.get(file);
}

for (const file of markdownFiles(ROOT)) {
  const text = fs.readFileSync(file, "utf8");
  const rel = path.relative(ROOT, file).replace(/\\/g, "/");
  // [text](target) — the target is everything up to the first ) or space.
  const linkRe = /\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;
  let m;
  while ((m = linkRe.exec(text)) !== null) {
    const raw = m[1];
    if (/^(https?:|mailto:|#)/.test(raw)) continue;      // external or same-page
    const [target, hash] = raw.split("#");
    if (!target) continue;
    const resolved = path.resolve(path.dirname(file), decodeURI(target));
    if (!fs.existsSync(resolved)) {
      errors.push(`${rel}: ${raw} -> file not found`);
      continue;
    }
    if (hash && /\.md$/i.test(resolved)) {
      const anchors = anchorsFor(resolved);
      if (!anchors.has(decodeURIComponent(hash))) {
        errors.push(`${rel}: ${raw} -> no heading with that anchor`);
      }
    }
  }
}

if (errors.length) {
  console.error("Broken documentation links:");
  for (const e of errors) console.error("  " + e);
  process.exit(1);
}
console.log("docs: every relative link resolves");

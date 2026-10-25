// ---------------------------------------------------------------------------
// index.html and app.js have to agree
// ---------------------------------------------------------------------------
// The window is one page and one script with no framework and no bundler: a
// rename in the HTML or a typo in the script is not caught by any compiler, and
// the failure mode is a dead button and a console error only a devtools user
// sees. Pulling the ids out of both files catches that in CI instead.
//
// Run: node --test stuff/tests/gui-ui.test.js
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const html = readFileSync(join(root, 'gui', 'ui', 'index.html'), 'utf8');
const js = readFileSync(join(root, 'gui', 'ui', 'app.js'), 'utf8');

function idsInHtml() {
  const ids = new Set();
  for (const m of html.matchAll(/\bid="([^"]+)"/g)) ids.add(m[1]);
  return ids;
}

// $('x') and document.getElementById('x'). Anything computed is skipped: there
// are none today, and a new one should be reviewed by hand anyway.
function idsInJs() {
  const ids = new Map();
  const patterns = [/\$\('([^']+)'\)/g, /getElementById\('([^']+)'\)/g];
  for (const re of patterns) {
    for (const m of js.matchAll(re)) {
      if (m[1].includes('+') || m[1].includes('${')) continue;
      ids.set(m[1], (ids.get(m[1]) || 0) + 1);
    }
  }
  return ids;
}

// Two elements may not share an id: getElementById returns the first, so code
// that meant the second one silently reads (or overwrites) the wrong element.
// A new <select> placed next to an existing hint paragraph did exactly that and
// only showed up as a picker that would not stay filled.
test('no id appears twice in the page', () => {
  const counts = new Map();
  for (const id of idsInHtml()) {
    counts.set(id, html.split(`id="${id}"`).length - 1);
  }
  const dupes = [...counts].filter(([, n]) => n > 1).map(([id]) => id);
  assert.deepEqual(dupes, [], `ids defined more than once: ${dupes.join(', ')}`);
});

test('every id the script looks up exists in the page', () => {
  const inHtml = idsInHtml();
  const missing = [...idsInJs().keys()].filter((id) => !inHtml.has(id));
  assert.deepEqual(missing, [], `app.js reaches for ids the page does not define: ${missing.join(', ')}`);
});

test('every id in the page is wired to something', () => {
  const used = idsInJs();
  const unused = [...idsInHtml()].filter((id) => !used.has(id));
  // Some ids are only styled or read by CSS; this is a warning list, and the
  // test fails only for ids that look like controls.
  const controls = unused.filter((id) => {
    const re = new RegExp(`<[^>]*\\bid="${id}"[^>]*>`);
    const tag = html.match(re)?.[0] || '';
    return /^<(button|input|textarea|dialog)/.test(tag);
  });
  assert.deepEqual(controls, [], `controls in index.html nothing uses: ${controls.join(', ')}`);
});

test('the page loads its stylesheet and script from the same folder', () => {
  assert.match(html, /href="app\.css"/);
  assert.match(html, /src="app\.js"/);
});

// A tab is a button with data-tab and a section with the matching pane id. A
// mismatch means the tab switches to nothing — visible only by clicking it.
test('every tab has a pane', () => {
  const tabs = [...html.matchAll(/data-tab="([^"]+)"/g)].map((m) => m[1]);
  assert.ok(tabs.length >= 4, `expected the build/config/device/docs tabs, found ${tabs.join(', ')}`);
  for (const tab of tabs) {
    assert.ok(html.includes(`id="pane-${tab}"`), `tab "${tab}" has no #pane-${tab}`);
  }
  assert.ok(js.includes("'pane-' + name"), 'switchTab no longer builds pane ids the way the test assumes');
});

// The buttons the server has to serve. Keeping the list here means a handler
// that is renamed in Go fails this test instead of a 404 in the window.
test('every api path the script calls exists in server.go', () => {
  const server = readFileSync(join(root, 'gui', 'server.go'), 'utf8');
  // The page uses relative paths ('api/state'); the server registers the whole
  // path under the per-launch token prefix.
  const paths = new Set(
    [...js.matchAll(/api\('([^']+)'/g)]
      .map((m) => m[1].replace(/^api\//, '').split('?')[0])
  );
  const missing = [...paths].filter((p) => !server.includes(`"/api/${p}"`));
  assert.deepEqual(missing, [], `server.go does not register: ${missing.join(', ')}`);
});

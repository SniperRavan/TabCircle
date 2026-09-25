// Regression tests for tab lifetime sweep.
//
// Auto-closing tabs is irreversible; ensure filter predicates protect user tabs.
//
// Run: node extension/tests/lifetime-sweep.test.js

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SOURCE = path.join(__dirname, "..", "background.js");

/// Load background.js in sandbox with chrome mocks.
function loadExtension({ tabs, favorites, lifetimeHours, connected, favoritesKnown }) {
  const removed = [];
  const logs = [];
  const noopEvent = () => ({ addListener() {} });

  const sandbox = {
    console,
    setTimeout,
    clearTimeout,
    URL,
    Date,
    Promise,
    Set,
    Map,
    Array,
    JSON,
    self: { addEventListener() {} },
    WebSocket: function () {},
    chrome: {
      runtime: {
        onMessage: noopEvent(),
        onStartup: noopEvent(),
        onInstalled: noopEvent(),
        getManifest: () => ({ version: "0.0.0" }),
        getURL: (p) => p,
        sendMessage: async () => {},
        lastError: undefined,
      },
      tabs: {
        onActivated: noopEvent(),
        onRemoved: noopEvent(),
        onUpdated: noopEvent(),
        onAttached: noopEvent(),
        onDetached: noopEvent(),
        query: async () => tabs,
        remove: async (ids) => { removed.push(...[].concat(ids)); },
        get: async (id) => tabs.find((t) => t.id === id),
        update: async () => {},
        create: async () => ({ id: 999 }),
      },
      windows: { onFocusChanged: noopEvent(), update: async () => {} },
      action: { onClicked: noopEvent() },
      alarms: { onAlarm: noopEvent(), create() {}, clear() {} },
      storage: { session: { get: async () => ({}), set: async () => {} } },
      offscreen: { hasDocument: async () => true, createDocument: async () => {} },
    },
  };
  sandbox.globalThis = sandbox;

  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(SOURCE, "utf8"), sandbox, { filename: "background.js" });

  // Set state under test for background.js top-level bindings.
  vm.runInContext(
    `settings.tabLifetimeHours = ${lifetimeHours};
     settings.favorites = ${JSON.stringify(favorites)};
     connected = ${connected};
     favoritesKnown = ${favoritesKnown};
     send = (m) => { if (m && m.type === "log") __logs.push(m.message); };`,
    Object.assign(sandbox, { __logs: logs })
  );

  return { sandbox, removed, logs };
}

const HOUR = 3600 * 1000;
const now = Date.now();
const idle = (h) => now - h * HOUR;

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`  ✓ ${name}`);
  } else {
    failures += 1;
    console.log(`  ✗ ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

async function run(title, setup, assert) {
  console.log(title);
  const ctx = loadExtension(setup);
  await vm.runInContext("sweepExpiredTabs()", ctx.sandbox);
  await new Promise((r) => setTimeout(r, 0));
  assert(ctx.removed, ctx.logs);
}

(async () => {
  // Baseline: confirm expired normal tabs are cleaned
  await run(
    "Expired normal tabs are closed (baseline)",
    {
      tabs: [
        { id: 1, url: "https://a.com/", lastAccessed: idle(30), active: false, pinned: false },
        { id: 2, url: "https://b.com/", lastAccessed: idle(1), active: false, pinned: false },
      ],
      favorites: [],
      lifetimeHours: 24,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => {
      check("Closes tab idle for 30h", removed.includes(1));
      check("Keeps tab idle for 1h", !removed.includes(2), `removed=${removed}`);
    }
  );

  await run(
    "Pinned tabs never swept (primary defense)",
    {
      tabs: [
        { id: 1, url: "https://mail.google.com/", lastAccessed: idle(500), active: false, pinned: true },
        { id: 2, url: "https://x.com/", lastAccessed: idle(500), active: false, pinned: false },
      ],
      favorites: [{ id: "f1", url: "https://mail.google.com/", currentUrl: "https://mail.google.com/" }],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => {
      check("Pinned favorite tab preserved", !removed.includes(1), `removed=${removed}`);
      check("Expired normal tab cleaned", removed.includes(2));
    }
  );

  await run(
    "Unpinned favorite guarded by domain (secondary defense)",
    {
      // Unpinned favorite guarded by domain
      tabs: [
        { id: 1, url: "https://notion.so/page", lastAccessed: idle(300), active: false, pinned: false },
        { id: 2, url: "https://x.com/", lastAccessed: idle(300), active: false, pinned: false },
      ],
      favorites: [{ id: "f1", url: "https://notion.so/", currentUrl: "https://notion.so/page" }],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => {
      check("Unpinned favorite tab preserved", !removed.includes(1), `removed=${removed}`);
      check("Unrelated expired tab swept as usual", removed.includes(2));
    }
  );

  await run(
    "When favorite is pinned, other tabs on domain are not exempted",
    {
      tabs: [
        { id: 1, url: "https://github.com/me", lastAccessed: idle(300), active: false, pinned: true },
        { id: 2, url: "https://github.com/other", lastAccessed: idle(300), active: false, pinned: false },
      ],
      favorites: [{ id: "f1", url: "https://github.com/me", currentUrl: "https://github.com/me" }],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => {
      check("Pinned tab kept", !removed.includes(1));
      check("Idle tab under same domain swept", removed.includes(2), `removed=${removed}`);
    }
  );

  await run(
    "Never sweep before favorites list arrives",
    {
      tabs: [{ id: 1, url: "https://a.com/", lastAccessed: idle(300), active: false, pinned: false }],
      favorites: [],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: false,
    },
    (removed) => check("None closed", removed.length === 0, `removed=${removed}`)
  );

  await run(
    "Do not sweep when helper is disconnected",
    {
      tabs: [{ id: 1, url: "https://a.com/", lastAccessed: idle(300), active: false, pinned: false }],
      favorites: [],
      lifetimeHours: 12,
      connected: false,
      favoritesKnown: true,
    },
    (removed) => check("None closed", removed.length === 0, `removed=${removed}`)
  );

  await run(
    "Do not sweep when lifetime is 0 (disabled)",
    {
      tabs: [{ id: 1, url: "https://a.com/", lastAccessed: idle(9000), active: false, pinned: false }],
      favorites: [],
      lifetimeHours: 0,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => check("None closed", removed.length === 0, `removed=${removed}`)
  );

  await run(
    "Active, audible, and grouped tabs are never closed",
    {
      tabs: [
        { id: 1, url: "https://a.com/", lastAccessed: idle(300), active: true, pinned: false },
        { id: 2, url: "https://b.com/", lastAccessed: idle(300), active: false, pinned: false, audible: true },
        { id: 3, url: "https://c.com/", lastAccessed: idle(300), active: false, pinned: false, groupId: 7 },
        { id: 4, url: "https://d.com/", lastAccessed: idle(300), active: false, pinned: false, groupId: -1 },
      ],
      favorites: [],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => {
      check("Active tab preserved", !removed.includes(1));
      check("Audible tab preserved", !removed.includes(2));
      check("Grouped tab preserved", !removed.includes(3));
      check("Remaining tabs cleaned", removed.includes(4), `removed=${removed}`);
    }
  );

  await run(
    "Tabs without lastAccessed are untouched",
    {
      tabs: [
        { id: 1, url: "https://a.com/", active: false, pinned: false },
        { id: 2, url: "https://b.com/", lastAccessed: 0, active: false, pinned: false },
      ],
      favorites: [],
      lifetimeHours: 12,
      connected: true,
      favoritesKnown: true,
    },
    (removed) => check("None closed", removed.length === 0, `removed=${removed}`)
  );

  console.log(failures === 0 ? "\nAll tests passed" : `\n${failures} failed`);
  process.exit(failures === 0 ? 0 : 1);
})();

// Regression tests for closed tab archiving.
//
// Validates that metadata and close reasons are accurately recorded without silent failures.
//   - Incognito tabs must never be recorded to disk
//   - Accurate distinction between manual, automatic (lifetime), and switcher closes
//   - Shadow metadata retrieval ensures info is present after onRemoved
// onRemoved does not provide tab metadata,
// and closing reasons must be registered before tabs.remove.
//
// Run: node extension/tests/closed-tabs.test.js

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SOURCE = path.join(__dirname, "..", "background.js");

/// Load background.js into sandbox with chrome mock.
///
/// Captures onRemoved listener and triggers it on tabs.remove.
/// Validates that marks precede tabs.remove.
///
///
function loadExtension({ tabs, sessionStorage = {}, lifetimeHours = 0 }) {
  const sent = [];
  const logs = [];
  const removed = [];
  const created = [];
  const noopEvent = () => ({ addListener() {} });
  let onRemovedListener = null;

  const liveTabs = tabs.map((t) => ({ ...t }));

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
    Object,
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
        onRemoved: { addListener(fn) { onRemovedListener = fn; } },
        onUpdated: noopEvent(),
        onAttached: noopEvent(),
        onDetached: noopEvent(),
        query: async () => liveTabs.filter((t) => !t.__gone),
        remove: async (ids) => {
          const list = [].concat(ids);
          removed.push(...list);
          for (const id of list) {
            const tab = liveTabs.find((t) => t.id === id);
            if (tab) tab.__gone = true;
            // Chrome behavior: onRemoved fires after remove; shadow copy preserves metadata.
            if (onRemovedListener) await onRemovedListener(id, { isWindowClosing: false });
          }
        },
        get: async (id) => {
          const tab = liveTabs.find((t) => t.id === id && !t.__gone);
          if (!tab) throw new Error(`No tab with id: ${id}`);
          return tab;
        },
        update: async () => {},
        create: async (opts) => { created.push(opts); return { id: 999, windowId: 1 }; },
      },
      windows: { onFocusChanged: noopEvent(), update: async () => {} },
      action: { onClicked: noopEvent() },
      alarms: { onAlarm: noopEvent(), create() {}, clear() {} },
      storage: {
        session: {
          get: async (keys) => {
            const out = {};
            for (const k of [].concat(keys)) {
              if (k in sessionStorage) out[k] = sessionStorage[k];
            }
            return out;
          },
          set: async (obj) => { Object.assign(sessionStorage, obj); },
        },
      },
      offscreen: { hasDocument: async () => true, createDocument: async () => {} },
    },
  };
  sandbox.globalThis = sandbox;

  vm.createContext(sandbox);
  vm.runInContext(fs.readFileSync(SOURCE, "utf8"), sandbox, { filename: "background.js" });

  vm.runInContext(
    `connected = true;
     favoritesKnown = true;
     settings.tabLifetimeHours = ${lifetimeHours};
     settings.favorites = [];
     send = (m) => { __sent.push(m); if (m && m.type === "log") __logs.push(m.message); };`,
    Object.assign(sandbox, { __sent: sent, __logs: logs })
  );

  return {
    sandbox,
    sent,
    logs,
    removed,
    created,
    /// Collected closed tab archives across all batches
    archived: () => sent.filter((m) => m.type === "tabsClosed").flatMap((m) => m.tabs),
    batches: () => sent.filter((m) => m.type === "tabsClosed"),
    fireRemoved: (id, removeInfo) => {
      const tab = liveTabs.find((t) => t.id === id);
      if (tab) tab.__gone = true;
      return onRemovedListener(id, removeInfo ?? { isWindowClosing: false });
    },
    run: (code) => vm.runInContext(code, sandbox),
  };
}

const HOUR = 3600 * 1000;
const now = Date.now();
const idle = (h) => now - h * HOUR;

/// Wait for flushClosed 120ms debounce.
const settle = () => new Promise((r) => setTimeout(r, 200));

let failures = 0;
function check(name, condition, detail) {
  if (condition) {
    console.log(`  ✓ ${name}`);
  } else {
    failures += 1;
    console.log(`  ✗ ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

const tab = (id, url, extra = {}) => ({
  id,
  url,
  windowId: 1,
  title: `T${id}`,
  favIconUrl: `${url}favicon.ico`,
  lastAccessed: now,
  active: false,
  pinned: false,
  ...extra,
});

(async () => {
  // ── Baseline ────────────────────────────────────────────────────────
  {
    console.log("Manually closed tab archives with metadata (baseline)");
    const ctx = loadExtension({ tabs: [tab(1, "https://a.com/"), tab(2, "https://b.com/")] });
    await ctx.run("pushMRU()");          // Establish shadow metadata
    await ctx.fireRemoved(1);
    await settle();

    const archived = ctx.archived();
    check("Recorded 1 closed tab", archived.length === 1, `archived=${JSON.stringify(archived)}`);
    check("URL matches", archived[0]?.url === "https://a.com/");
    check("Title retrieved from shadow metadata", archived[0]?.title === "T1", `title=${archived[0]?.title}`);
    check("Favicon included", archived[0]?.favIconUrl === "https://a.com/favicon.ico");
    check("Reason is manual", archived[0]?.reason === "manual", `reason=${archived[0]?.reason}`);
  }

  // ── Privacy Boundary ────────────────────────────────────────────────
  {
    console.log("Incognito tabs never archived");
    const ctx = loadExtension({
      tabs: [
        tab(1, "https://secret.example/", { incognito: true }),
        tab(2, "https://ordinary.example/"),
      ],
    });
    await ctx.run("pushMRU()");
    await ctx.fireRemoved(1);
    await ctx.fireRemoved(2);
    await settle();

    const archived = ctx.archived();
    // Verify raw payload to ensure no incognito info leaked
    //
    // Verify incognito tab is never saved to disk
    const wire = JSON.stringify(ctx.batches());
    check("Incognito tab excluded from archive", !archived.some((t) => t.url.includes("secret.example")),
          `archived=${JSON.stringify(archived)}`);
    check("Raw archive message does not contain incognito tab", !wire.includes("secret.example"));
    check("Normal tabs in same batch archived properly", archived.some((t) => t.url.includes("ordinary.example")));
  }

  {
    console.log("chrome:// and extension pages not archived");
    const ctx = loadExtension({
      tabs: [tab(1, "chrome://extensions/"), tab(2, "https://ok.example/")],
    });
    await ctx.run("pushMRU()");
    await ctx.fireRemoved(1);
    await ctx.fireRemoved(2);
    await settle();

    const archived = ctx.archived();
    check("chrome:// tab filtered out", !archived.some((t) => t.url.startsWith("chrome://")),
          `archived=${JSON.stringify(archived)}`);
    check("Normal page preserved", archived.length === 1);
  }

  // ── Reason Classification ───────────────────────────────────────────
  {
    console.log("Automatically cleaned tab marked as lifetime");
    const ctx = loadExtension({
      tabs: [tab(1, "https://old.example/", { lastAccessed: idle(300) })],
      lifetimeHours: 12,
    });
    await ctx.run("pushMRU()");
    await ctx.run("sweepExpiredTabs()");
    await settle();

    const archived = ctx.archived();
    check("Tab removed", ctx.removed.includes(1));
    check("Reason is lifetime", archived[0]?.reason === "lifetime",
          `reason=${archived[0]?.reason}`);
  }

  {
    console.log("Switcher close button marked as switcher");
    const ctx = loadExtension({ tabs: [tab(1, "https://x.example/"), tab(2, "https://y.example/")] });
    await ctx.run("pushMRU()");
    await ctx.run(`handleHelperMessage(JSON.stringify({ type: "close", tabId: 1 }))`);
    await settle();

    const archived = ctx.archived();
    check("Reason is switcher", archived[0]?.reason === "switcher",
          `reason=${archived[0]?.reason}`);
  }

  {
    console.log("Closing window marks tabs as window");
    const ctx = loadExtension({ tabs: [tab(1, "https://w.example/")] });
    await ctx.run("pushMRU()");
    await ctx.fireRemoved(1, { isWindowClosing: true });
    await settle();

    check("Reason is window", ctx.archived()[0]?.reason === "window",
          `reason=${ctx.archived()[0]?.reason}`);
  }

  // ── Shadow Copy ─────────────────────────────────────────────────────
  {
    console.log("When SW woken by onRemoved, metadata retrieved from storage.session");
    // Key scenario: SW was recycled and tabMeta in memory is empty.
    const ctx = loadExtension({
      tabs: [],
      sessionStorage: {
        mru: [7],
        tabMeta: {
          7: { url: "https://revived.example/", title: "Restored from storage",
               favIconUrl: "https://revived.example/f.ico", incognito: false },
        },
      },
    });
    await ctx.fireRemoved(7);
    await settle();

    const archived = ctx.archived();
    check("Archived successfully", archived.length === 1, `archived=${JSON.stringify(archived)}`);
    check("Title comes from storage snapshot", archived[0]?.title === "Restored from storage");
  }

  {
    console.log("Missing shadow metadata does not create empty records");
    const ctx = loadExtension({ tabs: [tab(1, "https://a.example/")] });
    await ctx.run("pushMRU()");
    await ctx.fireRemoved(4242);         // Never seen by any pushMRU
    await settle();

    check("No message sent", ctx.batches().length === 0,
          `sent=${JSON.stringify(ctx.batches())}`);
  }

  // ── Batch Merging ───────────────────────────────────────────────────
  {
    console.log("Multiple closed tabs merged into single batch message");
    const ctx = loadExtension({
      tabs: [1, 2, 3, 4, 5].map((i) => tab(i, `https://s${i}.example/`, { lastAccessed: idle(300) })),
      lifetimeHours: 12,
    });
    await ctx.run("pushMRU()");
    await ctx.run("sweepExpiredTabs()");
    await settle();

    check("Merged into 1 batch", ctx.batches().length === 1, `batches=${ctx.batches().length}`);
    check("All 5 tabs included", ctx.archived().length === 5, `count=${ctx.archived().length}`);
  }

  // ── Reopen ──────────────────────────────────────────────────────────
  {
    console.log("Helper reopen command opens new tab");
    const ctx = loadExtension({ tabs: [tab(1, "https://a.example/")] });
    await ctx.run(
      `handleHelperMessage(JSON.stringify({ type: "reopen", url: "https://back.example/page" }))`
    );
    await settle();

    check("Opened tab", ctx.created.length === 1, `created=${JSON.stringify(ctx.created)}`);
    check("URL matches", ctx.created[0]?.url === "https://back.example/page");
  }

  {
    console.log("reopen validates http(s) protocol");
    const ctx = loadExtension({ tabs: [tab(1, "https://a.example/")] });
    await ctx.run(
      `handleHelperMessage(JSON.stringify({ type: "reopen", url: "javascript:alert(1)" }))`
    );
    await settle();

    check("Did not open non-http tab", ctx.created.length === 0, `created=${JSON.stringify(ctx.created)}`);
  }

  console.log(failures === 0 ? "\nAll tests passed" : `\n${failures} failed`);
  process.exit(failures === 0 ? 0 : 1);
})();

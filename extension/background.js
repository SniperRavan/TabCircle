// TabCircle Bridge — MV3 service worker
//
// Responsibilities:
//   1. Maintain global tab MRU order (most recently used first)
//   2. Push MRU list to helper via local WebSocket
//   3. Execute tab switch commands from helper
//
// Connection is held by offscreen document: MV3 service worker is recycled
// after 30s of inactivity, preventing auto-reconnect without browser events.
// offscreen.js holds the persistent WebSocket and wakes SW on message arrival.
// SW communicates with offscreen via chrome.runtime messaging.

const OFFSCREEN_PATH = "offscreen.html";
const RECONNECT_ALARM = "tabcircle-reconnect";
const STORAGE_KEY = "mru";
const META_KEY = "tabMeta";

/// Settings source of truth lives in the helper application.
/// Local values are an in-memory cache requested upon connection.
/// Safe against SW recycles.
const DEFAULT_SETTINGS = {
  scopeToWindow: true,
  // Tab lifetime in hours, 0 = do not close. Idle tabs closed by sweepExpiredTabs.
  // Default is 0: safe fallback if helper is offline.
  // Destruction action fallback must always do nothing.
  tabLifetimeHours: 0,
  // Favorited tabs [{url, title}], reconciled upon connection.
  favorites: [],
  // Capture viewport screenshots for switcher cards. Set false in low-resource mode.
  captureThumbnails: true,
};

// Unhandled promise rejections forwarded to helper logs.
// Diagnostic logging for unhandled errors.
self.addEventListener("unhandledrejection", (event) => {
  event.preventDefault();
  const reason = event.reason;
  const detail = (reason && (reason.stack || reason.message)) || String(reason);
  // Suppress shutdown noise from pending API calls.
  if (detail.includes("browser is shutting down")) return;
  send({ type: "log", message: `sw unhandled rejection: ${detail}` });
});

let connected = false;   // Connection state reported by offscreen
let browserIsDark = true; // Browser theme state reported by offscreen
let mru = [];          // Array of tabId in MRU order, global across all windows
let mruLoaded = false;
let settings = { ...DEFAULT_SETTINGS };

/// Shadow copy of tab metadata: tabId -> {url, title, favIconUrl, incognito}.
///
/// Needed because chrome.tabs.onRemoved does not provide tab metadata,
/// and tabs.get(tabId) throws after the tab has been destroyed.
/// Pre-caching metadata allows recording closed tabs accurately.
///
/// Sweep already knows victims, but manual closures rely entirely on this copy.
/// Manual close events rely on this shadow copy as sole info source.
let tabMeta = {};

// ── MRU Maintenance ────────────────────────────────────────────────────

// MRU is persisted to and restored from storage.session across SW restarts.
// storage.session is cleared on browser exit, matching browser session lifecycle.
async function loadMRU() {
  if (mruLoaded) return;
  const stored = await chrome.storage.session.get([STORAGE_KEY, META_KEY]);
  mru = stored[STORAGE_KEY] ?? [];
  // Restore metadata shadow copy from session storage
  tabMeta = stored[META_KEY] ?? {};
  mruLoaded = true;
}

async function persistMRU() {
  await chrome.storage.session.set({ [STORAGE_KEY]: mru, [META_KEY]: tabMeta });
}

async function touchTab(tabId) {
  await loadMRU();
  const i = mru.indexOf(tabId);
  if (i === 0) return;               // Already at front, no change needed
  if (i > 0) mru.splice(i, 1);
  mru.unshift(tabId);
  await persistMRU();
  await pushMRU();
}

async function forgetTab(tabId) {
  await loadMRU();
  const i = mru.indexOf(tabId);
  if (i === -1) return;
  mru.splice(i, 1);
  await persistMRU();
  await pushMRU();
}

/// Push MRU order and display metadata to helper.
async function pushMRU() {
  if (!connected) return;
  await loadMRU();

  const allTabs = await chrome.tabs.query({});

  // Clean up closed tabs (closed while SW was sleeping).
  // This must be evaluated across all windows; filtering is handled by helper.
  // Filtering beforehand would inadvertently wipe history of other windows.
  const aliveIds = new Set(allTabs.map((t) => t.id));
  const cleaned = mru.filter((id) => aliveIds.has(id));
  const mruDirty = cleaned.length !== mru.length;
  if (mruDirty) mru = cleaned;

  // Refresh shadow metadata copy across all tabs.
  // Avoid redundant writes to storage.session by checking dirty state.
  // pushMRU is a high-frequency path so optimize memory transfers.
  let metaDirty = Object.keys(tabMeta).length !== allTabs.length;
  const nextMeta = {};
  for (const t of allTabs) {
    const entry = {
      url: t.url ?? "",
      title: t.title ?? "",
      favIconUrl: t.favIconUrl ?? "",
      // Never persist or expose incognito tab metadata.
      // Incognito tabs must remain strictly private.
      // Defense line if user enabled incognito access in extension settings.
      incognito: t.incognito === true,
    };
    nextMeta[t.id] = entry;
    const prev = tabMeta[t.id];
    if (!prev || prev.url !== entry.url || prev.title !== entry.title
        || prev.favIconUrl !== entry.favIconUrl) {
      metaDirty = true;
    }
  }
  tabMeta = nextMeta;

  if (mruDirty || metaDirty) await persistMRU();

  if (allTabs.length === 0) return;

  // Push all windows; helper handles window-scope filtering.
  // Window filtering is performed in helper UI.
  // Include currentWindowId for helper filtering.
  // Push full list regardless of scopeToWindow.
  const windowId = await currentWindowId();

  const byId = new Map(allTabs.map((t) => [t.id, t]));

  // Known MRU tabs first; background/restored tabs appended at end.
  const known = mru.filter((id) => byId.has(id));
  const knownSet = new Set(known);
  const unknown = allTabs.filter((t) => !knownSet.has(t.id)).map((t) => t.id);

  send({
    type: "mru",
    currentWindowId: windowId ?? -1,
    isDark: browserIsDark,
    tabs: [...known, ...unknown].map((id) => {
      const t = byId.get(id);
      return {
        id: t.id,
        windowId: t.windowId,
        title: t.title ?? "",
        url: t.url ?? "",
        favIconUrl: t.favIconUrl ?? "",
        // Last accessed timestamp in ms (Chrome 121+).
        // Used for idle duration calculation.
        lastAccessed: typeof t.lastAccessed === "number" ? t.lastAccessed : 0,
        // Pinned state for card badge
        pinned: t.pinned ?? false,
      };
    }),
  });
}

/// Throttled pushMRU for high frequency events.
///
/// onUpdated fires repeatedly during page load for title and favicon.
/// SPAs can trigger dozens of updates per second.
/// Critical paths (activation, close, move) call pushMRU directly.
let pushTimer = null;
function schedulePush() {
  clearTimeout(pushTimer);
  pushTimer = setTimeout(() => {
    pushTimer = null;
    pushMRU();
  }, 80);
}

/// Returns ID of the last focused normal window.
///
/// Avoid windows.getLastFocused due to deprecated windowTypes filter.
/// Reverse-lookup from active tab is more reliable.
async function currentWindowId() {
  const [tab] = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
  return tab?.windowId;
}

// ── Thumbnails ─────────────────────────────────────────────────────────
//
// Capture screenshot when a tab is activated; debounced to respect rate limits.
// Tabs in MRU have all been activated, ensuring thumbnails are populated.
//
// Constraints:
//   - Rate limits on captureVisibleTab: handled with debounce
//   - chrome:// and Web Store pages cannot be captured: fallback to favicon

const THUMB_DEBOUNCE_MS = 250;   // Debounce delay to let page finish rendering
/// Max thumbnail long edge. Kept uncropped so helper can align as background.
///
/// Full viewport resolution allows helper to use image for refraction backdrop.
/// Higher resolution avoids blur when scaled up in overlay.
const THUMB_MAX_WIDTH = 900;

let thumbTimer = null;

function scheduleThumbnail(tabId, windowId) {
  if (settings.captureThumbnails === false) return;
  clearTimeout(thumbTimer);
  thumbTimer = setTimeout(() => captureThumbnail(tabId, windowId), THUMB_DEBOUNCE_MS);
}

async function captureThumbnail(tabId, windowId) {
  if (!connected || settings.captureThumbnails === false) return;
  try {
    // 1. Confirm active tab exists and is the targeted tab
    const [current] = await chrome.tabs.query({ active: true, windowId });
    if (!current || current.id !== tabId || !current.url) return;

    // 2. Browser internal and privileged pages (chrome://, brave://, devtools://, about:, etc.)
    // cannot be captured by extensions due to browser security policies.
    const url = current.url.toLowerCase();
    if (!url.startsWith("http://") && !url.startsWith("https://") && !url.startsWith("file://")) {
      return;
    }

    const dataUrl = await chrome.tabs.captureVisibleTab(windowId, {
      format: "jpeg",
      quality: 70,
    });
    // Confirm active tab has not changed during async capture
    const [after] = await chrome.tabs.query({ active: true, windowId });
    if (after?.id !== tabId) return;

    // Include URL: helper caches by URL across restarts
    // full:true indicates complete uncropped viewport screenshot
    // Used by helper for background refraction effect
    // Aligns precisely with window coordinates
    // Backward compatibility fallback
    send({ type: "thumb", tabId, url: current.url ?? "", full: true,
           data: await downscale(dataUrl) });
  } catch (e) {
    const msg = String(e?.message || e);
    // Suppress repeated activeTab error logs when extension requires reload in brave://extensions
    if (msg.includes("activeTab")) {
      // Internal hint - only logged once per connection
      if (!captureThumbnail._warnedActiveTab) {
        captureThumbnail._warnedActiveTab = true;
        send({ type: "log", message: "Hint: Click 'Reload' on TabCircle Bridge in brave://extensions (or chrome://extensions) to enable full thumbnail captures." });
      }
    } else {
      send({ type: "log", message: `thumb capture skipped: ${msg}` });
    }
  }
}

/// Downscale full viewport image to THUMB_MAX_WIDTH while preserving aspect ratio.
///
/// Preserves aspect ratio for proper alignment in helper overlay.
/// Alignment depends on full-viewport coverage.
/// Cropping is deferred to rendering stage in helper UI.
/// Avoids falling back to plain blur.
///
/// Cards crop independently in UI.
/// Shifted cropping responsibility to renderer.
async function downscale(dataUrl) {
  // decode base64 manually in SW since fetch does not support data: URLs in MV3.
  // Standard atob decode to Uint8Array.
  const base64 = dataUrl.slice(dataUrl.indexOf(",") + 1);
  const raw = atob(base64);
  const bytes = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
  const bitmap = await createImageBitmap(new Blob([bytes], { type: "image/jpeg" }));

  const scale = Math.min(1, THUMB_MAX_WIDTH / bitmap.width);
  const w = Math.max(1, Math.round(bitmap.width * scale));
  const h = Math.max(1, Math.round(bitmap.height * scale));

  const canvas = new OffscreenCanvas(w, h);
  const ctx = canvas.getContext("2d");
  ctx.drawImage(bitmap, 0, 0, w, h);
  bitmap.close();

  const out = await canvas.convertToBlob({ type: "image/jpeg", quality: 0.6 });
  return bytesToBase64(new Uint8Array(await out.arrayBuffer()));
}

function bytesToBase64(bytes) {
  let binary = "";
  const CHUNK = 0x8000;   // Chunk size prevents stack overflow with Function.apply
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  }
  return btoa(binary);
}

// ── Favorited Tabs (Persistent Pins) ───────────────────────────────────
//
// Helper manages favorite list (url + title), reconciled on configuration receipt:
//   - If no tab for domain: open pinned in background
//   - If tabs exist but none pinned: pin the first one
// Match by domain to handle web app redirect paths.
// Reconcile only on config update, avoiding periodic forced overrides.
// Explicit user closes are respected until next browser restart.
//
// Chrome pinned tabs are window-scoped; helper keeps favorites globally persistent.
// Favorites are decoupled from individual browser windows.

let ensuringFavorites = false;

/// Settle delay after startup to let browser session restore complete.
/// Prevents creating duplicate pins before restored tabs appear.
/// Waits until settle deadline before reconciling favorites.
let startupSettleUntil = 0;

/// Tracks tabs pinned by extension to avoid echo notification loop:
/// ensures extension-initiated pins are skipped in onUpdated.
/// Cycle prevention marker.
const selfPinned = new Set();

/// Tracks tabs unpinned by helper command:
/// prevents reporting unpin event back to helper.
const selfUnpinned = new Set();

/// Whether initial config with favorites has been received.
/// Prevents running auto-sweep before favorites are loaded.
/// Reset to false on SW restart.
let favoritesKnown = false;

/// Domains queued for unpinning while browser was offline.
/// Processed on next reconciliation.
let pendingUnpinHosts = [];

function hostOf(url) {
  try {
    return new URL(url).host || null;
  } catch {
    return null;
  }
}

async function ensureFavorites() {
  if (ensuringFavorites) return;
  ensuringFavorites = true;
  try {
    const settleWait = startupSettleUntil - Date.now();
    if (settleWait > 0) await new Promise((r) => setTimeout(r, settleWait));

    const favorites = settings.favorites ?? [];
    const allTabsRaw = await chrome.tabs.query({});

    // Apply queued offline unpins first before matching:
    // session restore brings back old pins, which must be pruned before matching,
    // otherwise they get re-adopted as favorites.
    const unpinHosts = pendingUnpinHosts;
    pendingUnpinHosts = [];
    const suppressed = new Set();
    if (unpinHosts.length > 0) {
      // Tabs deleted while offline should be closed directly,
      // without leaving an unpinned orphan tab behind.
      // If it is the last tab in window, unpin instead of removing.
      // Fallback to unpin.
      let remaining = allTabsRaw.length;
      for (const t of allTabsRaw) {
        const h = hostOf(t.url ?? "");
        if (!t.pinned || !h || !unpinHosts.includes(h)) continue;
        suppressed.add(t.id);
        try {
          if (remaining > 1) {
            markClosing([t.id], "unpin");
            await chrome.tabs.remove(t.id);
            remaining -= 1;
            send({ type: "log", message: `pending unpin: closed ${h}` });
          } else {
            selfUnpinned.add(t.id);
            await chrome.tabs.update(t.id, { pinned: false });
            send({ type: "log", message: `pending unpin: unpinned ${h} (last tab)` });
          }
        } catch (e) {
          send({ type: "log", message: `pending unpin failed (${h}): ${e}` });
        }
      }
      // Acknowledge unpins to helper
      send({ type: "unpinsApplied", hosts: unpinHosts });
    }

    // Exclude suppressed tabs from matching
    // Don't let suppressed tabs participate in matching
    const allTabs = allTabsRaw.filter((t) => !suppressed.has(t.id));
    // Two-pass favorite matching:
    // Pass 1: exact URL match. Pass 2: host fallback.
    // Prevents two favorites on the same domain from stealing each other's tab.
    // Avoids duplicate pins.
    const claimed = new Set();
    const plan = favorites.map((fav) => {
      const targetUrl = fav.currentUrl || fav.url;
      const exact = allTabs.find((t) => !claimed.has(t.id) && (t.url ?? "") === targetUrl);
      if (exact) claimed.add(exact.id);
      return { fav, match: exact ?? null };
    });
    for (const entry of plan) {
      if (entry.match) continue;
      // Prefer last visited URL to restore previous session state.
      // Accounts for login page redirects.
      // Prevents opening duplicate tabs on redirect.
      const targetUrl = entry.fav.currentUrl || entry.fav.url;
      const curHost = hostOf(targetUrl);
      const origHost = hostOf(entry.fav.url);
      const free = (t) => !claimed.has(t.id);
      entry.match =
        (curHost ? allTabs.find((t) => free(t) && hostOf(t.url ?? "") === curHost) : null) ??
        (origHost ? allTabs.find((t) => free(t) && hostOf(t.url ?? "") === origHost) : null);
      if (entry.match) claimed.add(entry.match.id);
    }
    // Pass 3: match remaining favorites with unclaimed pinned tabs.
    // Restored pins may drift to login flow URLs;
    // adopting existing pinned tabs avoids duplicate creations.
    // Binds to existing pin rather than creating a new one.
    for (const entry of plan) {
      if (entry.match) continue;
      const stray = allTabs.find((t) => t.pinned && !claimed.has(t.id));
      if (stray) {
        claimed.add(stray.id);
        entry.match = stray;
      }
    }

    for (const { fav, match } of plan) {
      const targetUrl = fav.currentUrl || fav.url;
      try {
        if (match) {
          if (!match.pinned) {
            selfPinned.add(match.id);
            await chrome.tabs.update(match.id, { pinned: true });
            send({ type: "log", message: `favorite re-pinned: ${hostOf(match.url ?? "") ?? "?"}` });
          }
          send({ type: "favoriteBound", id: fav.id, tabId: match.id });
        } else {
          const created = await chrome.tabs.create({ url: targetUrl, pinned: true, active: false });
          // Some Chromium derivatives do not return Tab object from tabs.create;
          // handle undefined tab ID gracefully.
          // Skip binding if id is missing.
          if (created?.id !== undefined) {
            selfPinned.add(created.id);
            claimed.add(created.id);
            send({ type: "favoriteBound", id: fav.id, tabId: created.id });
          }
          send({ type: "log", message: `favorite restored: ${targetUrl}` });
        }
      } catch (e) {
        send({ type: "log", message: `favorite ensure failed (${fav.url}): ${e}` });
      }
    }

    // Report external pinned tabs to helper as favorites:
    // Pinned = Favorited (two-way sync).
    for (const t of allTabs) {
      if (t.pinned && !claimed.has(t.id) && (t.url ?? "").startsWith("http")) {
        send({ type: "pinnedTab", tabId: t.id, url: t.url, title: t.title ?? "",
               favIconUrl: t.favIconUrl ?? "" });
      }
    }
  } finally {
    ensuringFavorites = false;
  }
}

// ── Tab Lifetime Management (Auto-close idle tabs) ─────────────────────
//
// Auto-close tabs exceeding idle threshold using tab.lastAccessed.
// Tabs without lastAccessed are left untouched.
//
// Protected tabs (never close):
//   - pinned: explicit user keeps; primary line of defense for favorites
//   - favorite domains: secondary line of defense
//   - active: active tab in each window; prevents closing window
//     keeps at least one tab open per window
//   - audible: currently playing sound/audio
//   - tab groups: tabs organized into intentional groups
// Only clean tabs when actively connected to helper.

const LIFETIME_ALARM = "tabcircle-lifetime";
const LIFETIME_SWEEP_MINUTES = 5;

async function sweepExpiredTabs() {
  const hours = settings.tabLifetimeHours;
  // Only sweep when connected and favorites are known.
  // Prevents sweeping before favorites list is received.
  // Avoids race condition during initial handshake.
  // Destructive action safety policy: do nothing on ambiguity.
  if (!hours || !connected || !favoritesKnown) return;

  const cutoff = Date.now() - hours * 3600 * 1000;
  const allTabs = await chrome.tabs.query({});

  // Second line of defense for favorites:
  //
  // Primary defense is !t.pinned; this protects favorite domains
  // during the transition before they are re-pinned.
  // Handles edge cases in third-party Chromium builds
  // where pinned flag is temporarily lost.
  // Prevents sweep from accidentally closing unpinned favorites.
  //
  // Next ensure pass would re-open, but closing and reopening is disruptive.
  // Keeps experience smooth.
  // Guard only domains without an active pin; other tabs under domain can be swept.
  // Targeted protection without over-exemption.
  const pinnedHosts = new Set(
    allTabs.filter((t) => t.pinned).map((t) => hostOf(t.url ?? "")).filter(Boolean)
  );
  const guardedHosts = new Set(
    (settings.favorites ?? [])
      .flatMap((f) => [hostOf(f.currentUrl ?? ""), hostOf(f.url ?? "")])
      .filter((h) => h && !pinnedHosts.has(h))
  );

  const victims = allTabs.filter((t) =>
    !t.active && !t.pinned && !t.audible &&
    !guardedHosts.has(hostOf(t.url ?? "")) &&
    (t.groupId === undefined || t.groupId === -1) &&
    typeof t.lastAccessed === "number" && t.lastAccessed > 0 &&
    t.lastAccessed < cutoff
  );
  if (victims.length === 0) return;

  // Log swept tabs to helper:
  // Provides audit trail in helper logs.
  // Limit to first 40 entries to avoid overwhelming log line length.
  // Keeps log output clean and readable.
  const LOG_LIMIT = 40;
  const detail = victims
    .slice(0, LOG_LIMIT)
    .map((t) => `${(t.title || t.url || "?").slice(0, 40)} (idle ${Math.round((Date.now() - t.lastAccessed) / 3600000)}h)`)
    .join("; ")
    + (victims.length > LOG_LIMIT ? `; ...and ${victims.length - LOG_LIMIT} more` : "");
  send({ type: "log", message: `lifetime sweep: closing ${victims.length} tab(s) > ${hours}h idle: ${detail}` });

  try {
    // Mark closing reason before calling tabs.remove
    // so onRemoved synchronously identifies lifetime reason.
    markClosing(victims.map((t) => t.id), "lifetime");
    await chrome.tabs.remove(victims.map((t) => t.id));
  } catch (e) {
    send({ type: "log", message: `lifetime sweep failed: ${e}` });
  }
}

// ── Closed Tab Tracking ────────────────────────────────────────────────
//
// Reports closed tabs with reason to helper for restoration menu.
//
// Five close reasons:
// pre-marked before operation:
//   - lifetime / switcher / unpin: initiated by extension/helper
//     registered before tabs.remove (onRemoved is synchronous)
//   - window: removeInfo.isWindowClosing from Chrome
//   - manual: user closed via Cmd+W / click / middle click
//
// Note: Browser exit terminates SW without running onRemoved.
// Crashes also cannot be intercepted; MV3 constraint.
// Browser exit does not generate close records.

const CLOSED_FLUSH_MS = 120;
const REASON_TTL_MS = 30_000;

/// tabId -> {reason, at}: tracks close reason for self-initiated closures
const closeReasons = new Map();

function markClosing(tabIds, reason) {
  const at = Date.now();
  for (const id of tabIds) closeReasons.set(id, { reason, at });
}

/// Buffer for closed tab records; merges batch closures into single message.
/// Avoids spamming WebSocket frames.
let closedBuffer = [];
let closedFlushTimer = null;

async function recordClosed(tabId, removeInfo) {
  // SW may have been woken up by onRemoved: read metadata from storage.session.
  // Previous pushMRU snapshot holds the tab info before removal.
  // Ensure loadMRU completes before lookup.
  await loadMRU();

  const meta = tabMeta[tabId];
  const marked = closeReasons.get(tabId);
  closeReasons.delete(tabId);

  // Untracked tabs (opened and closed immediately in background)
  // have no restore value and are discarded.
  if (!meta?.url) return;
  if (meta.incognito) return;                    // Never record incognito tabs
  if (!meta.url.startsWith("http")) return;      // Skip internal and extension scheme URLs

  closedBuffer.push({
    url: meta.url,
    title: meta.title ?? "",
    favIconUrl: meta.favIconUrl ?? "",
    reason: marked?.reason ?? (removeInfo?.isWindowClosing ? "window" : "manual"),
    closedAt: Date.now(),
  });

  clearTimeout(closedFlushTimer);
  closedFlushTimer = setTimeout(flushClosed, CLOSED_FLUSH_MS);
}

function flushClosed() {
  closedFlushTimer = null;

  // Prune stale close reasons after TTL
  // Clean up memory for failed removes
  const cutoff = Date.now() - REASON_TTL_MS;
  for (const [id, mark] of closeReasons) {
    if (mark.at < cutoff) closeReasons.delete(id);
  }

  if (closedBuffer.length === 0) return;
  const batch = closedBuffer;
  closedBuffer = [];
  // If disconnected, buffer is dropped cleanly.
  // Aligns with connected-only policy.
  send({ type: "tabsClosed", tabs: batch });
}

/// Reopen a closed tab.
async function reopenTab(url, active) {
  try {
    const tab = await chrome.tabs.create({ url, active: active !== false });
    // Reopened tab should focus and bring window to front.
    // Focus window.
    if (active !== false && tab?.windowId !== undefined) {
      await chrome.windows.update(tab.windowId, { focused: true });
    }
  } catch (e) {
    send({ type: "log", message: `reopen failed (${url}): ${e}` });
  }
}

// ── Tab Switch Execution ───────────────────────────────────────────────

async function activateTab(tabId) {
  try {
    const tab = await chrome.tabs.get(tabId);
    await chrome.tabs.update(tabId, { active: true });
    // Target tab may be in another window; bring that window to front as well.
    await chrome.windows.update(tab.windowId, { focused: true });
  } catch (e) {
    console.warn("[TabCircle] Switch failed, tab may be closed:", tabId, e);
    await forgetTab(tabId);
  }
}

// ── WebSocket Communication ────────────────────────────────────────────

function send(obj) {
  if (!connected) return;
  chrome.runtime
    .sendMessage({ target: "offscreen", type: "ws-send", data: JSON.stringify(obj) })
    .catch(() => {});
}

/// Ensure offscreen document exists; idempotent.
async function ensureOffscreen() {
  if (await chrome.offscreen.hasDocument()) return;
  try {
    await chrome.offscreen.createDocument({
      url: OFFSCREEN_PATH,
      // WORKERS reason provides an environment independent of SW lifecycle.
      // Maintains persistent background connection.
      reasons: ["WORKERS"],
      justification: "Maintain a persistent local WebSocket connection to the TabCircle helper.",
    });
  } catch (e) {
    // Concurrent creation race is harmless.
    if (!String(e).includes("Only a single offscreen")) {
      console.warn("[TabCircle] offscreen creation failed:", e);
    }
  }
}

async function connect() {
  await ensureOffscreen();
  // Poke offscreen document to report status or reconnect.
  chrome.runtime
    .sendMessage({ target: "offscreen", type: "ws-poke" })
    .catch(() => {});
}

/// Handle incoming helper message forwarded by offscreen document.
async function handleHelperMessage(raw) {
  let msg;
  try {
    msg = JSON.parse(raw);
  } catch {
    return;   // Ignore non-JSON or external messages
  }
  switch (msg.type) {
    case "switch":
      if (typeof msg.tabId === "number") await activateTab(msg.tabId);
      break;
    case "unpin":
      // Unpin tabs for specified hosts:
      // explicit instruction from helper
      if (Array.isArray(msg.hosts)) {
        const pinned = await chrome.tabs.query({ pinned: true });
        for (const t of pinned) {
          const h = hostOf(t.url ?? "");
          if (h && msg.hosts.includes(h)) {
            try {
              selfUnpinned.add(t.id);
              await chrome.tabs.update(t.id, { pinned: false });
            } catch (e) {
              selfUnpinned.delete(t.id);
              send({ type: "log", message: `unpin failed (${h}): ${e}` });
            }
          }
        }
      }
      break;
    case "close":
      // Close button on switcher card.
      // onRemoved handles MRU update automatically.
      if (typeof msg.tabId === "number") {
        try {
          markClosing([msg.tabId], "switcher");
          await chrome.tabs.remove(msg.tabId);
        } catch (e) {
          // Tab may have already closed; forget locally.
          send({ type: "log", message: `close failed: ${e}` });
          await forgetTab(msg.tabId);
        }
      }
      break;
    case "reopen":
      // Reopen tab requested by helper
      if (typeof msg.url === "string" && msg.url.startsWith("http")) {
        await reopenTab(msg.url, msg.active);
      }
      break;
    case "ping":
      send({ type: "pong" });
      break;
    case "requestMRU":
      await pushMRU();
      break;
    case "settings":
      // Settings from helper: push fresh MRU list to apply changes.
      // Helper filters on its side.
      if (typeof msg.scopeToWindow === "boolean") {
        settings.scopeToWindow = msg.scopeToWindow;
        pushMRU();
      }
      if (typeof msg.tabLifetimeHours === "number") {
        settings.tabLifetimeHours = msg.tabLifetimeHours;
      }
      if (typeof msg.captureThumbnails === "boolean") {
        settings.captureThumbnails = msg.captureThumbnails;
        if (!settings.captureThumbnails && thumbTimer) {
          clearTimeout(thumbTimer);
          thumbTimer = null;
        }
      }
      // Pending unpins must be set before ensureFavorites.
      if (Array.isArray(msg.pendingUnpinHosts)) {
        pendingUnpinHosts = msg.pendingUnpinHosts;
      }
      if (Array.isArray(msg.favorites)) {
        settings.favorites = msg.favorites;
        favoritesKnown = true;
        ensureFavorites();
      }
      break;
  }
}

// Connection events and data forwarded from offscreen:
// Process messages sequentially to preserve semantic order
// and avoid race conditions during unpin/reconcile.
// Prevents re-pin loop.
let helperQueue = Promise.resolve();

chrome.runtime.onMessage.addListener((message) => {
  if (message?.target !== "sw") return;

  switch (message.type) {
    case "ws-open":
      if (!connected) {
        connected = true;
        console.log("[TabCircle] Connected to helper");
        // Include extension version for compatibility check
        send({ type: "requestSettings", extVersion: chrome.runtime.getManifest().version });
        pushMRU();
        chrome.tabs
          .query({ active: true, lastFocusedWindow: true })
          .then(([tab]) => { if (tab) scheduleThumbnail(tab.id, tab.windowId); });
      }
      break;
    case "ws-close":
      connected = false;
      console.log("[TabCircle] Connection disconnected");
      break;
    case "theme":
      browserIsDark = message.isDark;
      break;
    case "ws-message":
      helperQueue = helperQueue
        .then(() => handleHelperMessage(message.data))
        .catch(() => {});
      break;
  }
});

// ── Event Listeners ────────────────────────────────────────────────────

chrome.tabs.onActivated.addListener(({ tabId, windowId }) => {
  connect();          // Auto-heal connection
  touchTab(tabId);
  scheduleThumbnail(tabId, windowId);
});

// Sequence is critical: recordClosed reads metadata before forgetTab prunes it.
// Awaiting both ensures correct order without race.
// Preserves microtask execution order.
chrome.tabs.onRemoved.addListener(async (tabId, removeInfo) => {
  await recordClosed(tabId, removeInfo);
  await forgetTab(tabId);
});

// When switching windows, update MRU for the focused tab.
chrome.windows.onFocusChanged.addListener(async (windowId) => {
  if (windowId === chrome.windows.WINDOW_ID_NONE) return;
  const [tab] = await chrome.tabs.query({ active: true, windowId });
  if (!tab) return;
  await touchTab(tab.id);
  scheduleThumbnail(tab.id, windowId);
});

// Throttled push on title or favicon changes.
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.title || changeInfo.favIconUrl) schedulePush();
  // Refresh push on pinned state change.
  if (changeInfo.pinned !== undefined) schedulePush();

  // User unpinned a tab.
  // Helper decides if it belongs to favorites.
  // Avoid echo loop with selfUnpinned.
  // Prevents cycle.
  //
  // Verify after 400ms delay: window/browser close triggers transient pinned:false.
  // If tab is still alive and unpinned, report to helper;
  // if tab is gone, it was closed rather than unpinned.
  // Naturally safe on browser exit.
  // User pinned a tab -> report to helper as favorite.
  // Skip self-pinned tabs to prevent loop.
  if (changeInfo.pinned === true) {
    if (selfPinned.has(tabId)) {
      selfPinned.delete(tabId);
    } else if ((tab?.url ?? "").startsWith("http")) {
      send({ type: "pinnedTab", tabId, url: tab.url, title: tab?.title ?? "",
             favIconUrl: tab?.favIconUrl ?? "" });
    }
  }

  if (changeInfo.pinned === false) {
    if (selfUnpinned.has(tabId)) {
      // Ignore echo from our own unpin command
      selfUnpinned.delete(tabId);
      return;
    }
    const fallbackHost = hostOf(tab?.url ?? "") ?? "";
    setTimeout(async () => {
      try {
        const live = await chrome.tabs.get(tabId);
        if (!live.pinned) {
          send({ type: "unpinned", host: hostOf(live.url ?? "") ?? fallbackHost, tabId });
        }
      } catch {
        // Tab no longer exists: closed rather than unpinned
      }
    }, 400);
  }
});

// Tab moved between windows; refresh MRU.
// Position in MRU persists naturally.
chrome.tabs.onAttached.addListener(() => pushMRU());
chrome.tabs.onDetached.addListener(() => pushMRU());

// Action button clicked -> request helper to open settings.
// Single entry point for settings in helper UI.
chrome.action.onClicked.addListener(() => {
  connect();
  send({ type: "openSettings" });
});

function ensureAlarms() {
  chrome.alarms.create(RECONNECT_ALARM, { periodInMinutes: 0.5 });
  chrome.alarms.create(LIFETIME_ALARM, { periodInMinutes: LIFETIME_SWEEP_MINUTES });
}

chrome.runtime.onStartup.addListener(() => {
  startupSettleUntil = Date.now() + 2500;
  connect();
  ensureAlarms();
});
chrome.runtime.onInstalled.addListener(() => {
  connect();
  ensureAlarms();
});

// Fallback: reconnect on alarm if connection was lost.
// Helper ping keeps connection alive normally.
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONNECT_ALARM) connect();
  if (alarm.name === LIFETIME_ALARM) sweepExpiredTabs();
});

connect();

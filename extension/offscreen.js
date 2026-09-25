// TabCircle — offscreen document
//
// Maintains the WebSocket connection to the helper and forwards messages
// between the helper and the service worker.

const WS_URL = "ws://127.0.0.1:41573/";
const RETRY_MS = 300;

let ws = null;
let retryTimer = null;

self.addEventListener("unhandledrejection", (event) => {
  event.preventDefault();
  const reason = event.reason;
  const detail = (reason && (reason.stack || reason.message)) || String(reason);
  try {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "log", message: `offscreen unhandled rejection: ${detail}` }));
    }
  } catch {}
});

self.addEventListener("error", (event) => {
  try {
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({
        type: "log",
        message: `offscreen error: ${event.message} @ ${event.filename}:${event.lineno}`,
      }));
    }
  } catch {}
});

function toWorker(message) {
  chrome.runtime.sendMessage({ target: "sw", ...message }).catch(() => {});
}

function reportTheme() {
  try {
    const isDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "theme", isDark }));
    }
    toWorker({ type: "theme", isDark });
  } catch {}
}

try {
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    reportTheme();
  });
} catch {}

function connect() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;

  clearTimeout(retryTimer);
  try {
    ws = new WebSocket(WS_URL);
  } catch {
    scheduleRetry();
    return;
  }

  ws.onopen = () => {
    toWorker({ type: "ws-open" });
    reportTheme();
  };

  ws.onmessage = (event) => {
    try {
      const parsed = JSON.parse(event.data);
      if (parsed.type === "requestTheme") {
        reportTheme();
        return;
      }
    } catch {}
    toWorker({ type: "ws-message", data: event.data });
  };

  ws.onclose = () => {
    ws = null;
    toWorker({ type: "ws-close" });
    scheduleRetry();
  };

  ws.onerror = () => {
    try { ws?.close(); } catch {}
  };
}

function scheduleRetry() {
  clearTimeout(retryTimer);
  retryTimer = setTimeout(connect, RETRY_MS);
}

chrome.runtime.onMessage.addListener((message) => {
  if (message?.target !== "offscreen") return;

  if (message.type === "ws-send") {
    if (ws?.readyState === WebSocket.OPEN) ws.send(message.data);
  } else if (message.type === "ws-poke") {
    if (ws?.readyState === WebSocket.OPEN) {
      toWorker({ type: "ws-open" });
    } else {
      connect();
    }
  }
});

connect();

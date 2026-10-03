// Eyes Only — browser side.
//
// Reports this browser's windows (position, size, state) and tabs (title, URL, which one is active) to
// the Eyes Only menu-bar app over native messaging. The app decides what to protect; this
// extension has no UI and never talks to the network.

const HOST = "com.eyesonly.bridge";
let port = null;
let pending = null;

function connect() {
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (e) {
    port = null;
    setTimeout(connect, 3000);
    return;
  }
  port.onMessage.addListener(onMessage);
  port.onDisconnect.addListener(() => {
    port = null;
    setTimeout(connect, 3000);   // the app may not be running yet
  });
  sendState();
}

async function snapshot() {
  const windows = await chrome.windows.getAll({ populate: true, windowTypes: ["normal", "popup", "app"] });
  return windows.map(w => ({
    id: w.id, focused: w.focused, state: w.state, incognito: w.incognito,
    left: w.left, top: w.top, width: w.width, height: w.height,
    tabs: (w.tabs || []).map(t => ({ id: t.id, title: t.title || "", url: t.url || t.pendingUrl || "", active: t.active }))
  }));
}

async function sendState() {
  if (!port) return;
  try {
    port.postMessage({ type: "state", windows: await snapshot() });
  } catch (e) { /* port closed mid-send; onDisconnect reconnects */ }
}

// Tab switches go out at once: that's the moment a protected tab's cover has to appear.
function now() { clearTimeout(pending); pending = null; sendState(); }
// Everything else (titles, loading, moves) is coalesced.
function soon() { clearTimeout(pending); pending = setTimeout(sendState, 60); }

chrome.tabs.onActivated.addListener(now);
chrome.windows.onFocusChanged.addListener(now);
chrome.tabs.onAttached.addListener(now);
chrome.tabs.onDetached.addListener(now);
chrome.tabs.onReplaced.addListener(now);
chrome.tabs.onCreated.addListener(soon);
chrome.tabs.onRemoved.addListener(soon);
chrome.tabs.onMoved.addListener(soon);
// A new address goes out at once too: navigating to a protected site has to bring the cover up before it paints.
chrome.tabs.onUpdated.addListener((tabId, info) => { if (info.url) now(); else if (info.title || info.status) soon(); });
chrome.windows.onCreated.addListener(soon);
chrome.windows.onRemoved.addListener(soon);
chrome.windows.onBoundsChanged.addListener(soon);

function onMessage(msg) {
  if (!msg || typeof msg !== "object") return;
  if (msg.type === "refresh") sendState();
}

chrome.runtime.onStartup.addListener(() => { if (!port) connect(); });
chrome.runtime.onInstalled.addListener(() => { if (!port) connect(); });
connect();

importScripts("provider-core.js");

const NATIVE_HOST = "dev.islet.pulse.chrome_downloads";
const POLL_MILLISECONDS = 2000;
const COMMANDS_PER_FLUSH = 12;
let tracker = null;
let nativePort = null;
let timer = null;
let reconciling = false;
let listenersRegistered = false;
const pending = new Map();
const inFlight = new Map();
const drainWaiters = new Set();

function commandKey(command) {
  if (command.kind === "disable") return "provider:disable";
  const id = command.item ? command.item.id : command.id;
  return `${command.profileID}:${id}`;
}

function notifyDrainWaiters() {
  if (pending.size || inFlight.size) return;
  for (const resolve of drainWaiters) resolve();
  drainWaiters.clear();
}

function waitForDrain(milliseconds = 5000) {
  if (!pending.size && !inFlight.size) return Promise.resolve();
  return new Promise((resolve) => {
    const finish = () => {
      drainWaiters.delete(finish);
      resolve();
    };
    drainWaiters.add(finish);
    setTimeout(finish, milliseconds);
  });
}

async function savedState() {
  const state = await chrome.storage.local.get(["enabled", "profileID", "knownIDs"]);
  if (!state.profileID) {
    state.profileID = crypto.randomUUID();
    await chrome.storage.local.set({ profileID: state.profileID });
  }
  return {
    enabled: state.enabled !== false,
    profileID: state.profileID,
    knownIDs: Array.isArray(state.knownIDs) ? state.knownIDs : [],
  };
}

function connectHost() {
  if (nativePort) return nativePort;
  nativePort = chrome.runtime.connectNative(NATIVE_HOST);
  nativePort.onMessage.addListener((response) => {
    const requestID = response && response.requestID;
    const key = inFlight.get(requestID);
    if (!key) return;
    inFlight.delete(requestID);
    const command = pending.get(key);
    if (response.ok === true && command && command.requestID === requestID) {
      pending.delete(key);
      flushPending();
    }
    notifyDrainWaiters();
  });
  nativePort.onDisconnect.addListener(() => {
    nativePort = null;
    inFlight.clear();
    notifyDrainWaiters();
  });
  return nativePort;
}

function flushPending() {
  if (!pending.size) {
    notifyDrainWaiters();
    return;
  }
  const port = connectHost();
  const activeKeys = new Set(inFlight.values());
  for (const [key, command] of pending) {
    if (inFlight.size >= COMMANDS_PER_FLUSH) break;
    if (activeKeys.has(key)) continue;
    try {
      inFlight.set(command.requestID, key);
      activeKeys.add(key);
      port.postMessage(command);
    } catch (_error) {
      inFlight.delete(command.requestID);
      nativePort = null;
      break;
    }
  }
}

async function publish(commands) {
  for (const command of commands) {
    pending.set(commandKey(command), { ...command, requestID: crypto.randomUUID() });
  }
  await chrome.storage.local.set({ knownIDs: tracker.snapshot() });
  flushPending();
}

async function reconcile() {
  if (!tracker || reconciling) return;
  reconciling = true;
  try {
    const items = await chrome.downloads.search({ state: "in_progress" });
    await publish(tracker.reconcile(items));
  } finally {
    reconciling = false;
  }
}

async function onCreated(item) {
  if (tracker) await publish(tracker.ingest(item));
}

async function onChanged(delta) {
  if (!tracker) return;
  const items = await chrome.downloads.search({ id: delta.id });
  await publish(items.length ? tracker.ingest(items[0]) : tracker.erase(delta.id));
}

async function onErased(id) {
  if (tracker) await publish(tracker.erase(id));
}

function addDownloadListeners() {
  if (listenersRegistered) return;
  chrome.downloads.onCreated.addListener(onCreated);
  chrome.downloads.onChanged.addListener(onChanged);
  chrome.downloads.onErased.addListener(onErased);
  listenersRegistered = true;
}

function removeDownloadListeners() {
  if (!listenersRegistered) return;
  chrome.downloads.onCreated.removeListener(onCreated);
  chrome.downloads.onChanged.removeListener(onChanged);
  chrome.downloads.onErased.removeListener(onErased);
  listenersRegistered = false;
}

async function enableObservation() {
  if (tracker) return;
  const state = await savedState();
  if (!state.enabled) {
    removeDownloadListeners();
    return;
  }
  tracker = new IsletChromeDownloads.Tracker(state.profileID, state.knownIDs);
  addDownloadListeners();
  timer = setInterval(reconcile, POLL_MILLISECONDS);
  await reconcile();
}

async function disableObservation() {
  removeDownloadListeners();
  if (timer !== null) clearInterval(timer);
  timer = null;
  const cleanup = tracker ? tracker.disable() : [];
  pending.clear();
  inFlight.clear();
  await chrome.storage.local.set({ knownIDs: [] });
  if (tracker) {
    await publish([...cleanup, { kind: "disable", profileID: tracker.profileID }]);
    await waitForDrain();
  }
  if (nativePort) {
    nativePort.disconnect();
    nativePort = null;
  }
  pending.clear();
  inFlight.clear();
  tracker = null;
}

chrome.storage.onChanged.addListener(async (changes, area) => {
  if (area !== "local" || !changes.enabled) return;
  if (changes.enabled.newValue === false) await disableObservation();
  else await enableObservation();
});

// Register synchronously so Chrome can wake a suspended Manifest V3 worker for download events.
// The enabled-state load immediately removes these listeners when the provider is disabled.
addDownloadListeners();
enableObservation();

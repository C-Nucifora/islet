importScripts("provider-core.js");

const NATIVE_HOST = "dev.islet.pulse.chrome_downloads";
const POLL_MILLISECONDS = 2000;
const HOST_IDLE_MILLISECONDS = 10_000;
const COMMANDS_PER_FLUSH = 12;
let tracker = null;
let nativePort = null;
let pollTimer = null;
let hostIdleTimer = null;
let listenersRegistered = false;
let lifecycleTail = Promise.resolve();
let persistenceTail = Promise.resolve();
let initializationPromise = null;
const pending = new Map();
const inFlight = new Map();
const drainWaiters = new Set();

function commandKey(command) {
  if (command.kind === "disable") return "provider:disable";
  const id = command.item ? command.item.id : command.id;
  return `${command.profileID}:${id}`;
}

function commandDownloadID(command) {
  const id = command.item ? command.item.id : command.id;
  return Number.isSafeInteger(id) && id >= 0 ? id : null;
}

function isTerminal(command) {
  return (
    command.kind === "end" ||
    (command.kind === "upsert" &&
      command.item &&
      (command.item.state === "complete" || command.item.state === "interrupted"))
  );
}

function durableKnownIDs() {
  const identifiers = new Set(tracker ? tracker.snapshot() : []);
  for (const command of pending.values()) {
    const id = commandDownloadID(command);
    if (id !== null && isTerminal(command)) identifiers.add(id);
  }
  return Array.from(identifiers).sort((left, right) => left - right);
}

function persistKnownIDs() {
  const knownIDs = durableKnownIDs();
  const write = persistenceTail.then(() => chrome.storage.local.set({ knownIDs }));
  persistenceTail = write.catch(() => {});
  return write;
}

function hasActiveDownloads() {
  return tracker !== null && tracker.snapshot().length > 0;
}

function cancelHostIdleTimer() {
  if (hostIdleTimer === null) return;
  clearTimeout(hostIdleTimer);
  hostIdleTimer = null;
}

function scheduleHostDisconnect() {
  if (!nativePort || pending.size || inFlight.size || hasActiveDownloads()) {
    cancelHostIdleTimer();
    return;
  }
  if (hostIdleTimer !== null) return;
  hostIdleTimer = setTimeout(() => {
    hostIdleTimer = null;
    if (!nativePort || pending.size || inFlight.size || hasActiveDownloads()) return;
    const port = nativePort;
    nativePort = null;
    port.disconnect();
  }, HOST_IDLE_MILLISECONDS);
}

function notifyDrainWaiters() {
  if (pending.size || inFlight.size) return;
  for (const resolve of drainWaiters) resolve();
  drainWaiters.clear();
  scheduleHostDisconnect();
}

function waitForDrain(milliseconds = 5000) {
  if (!pending.size && !inFlight.size) return Promise.resolve();
  return new Promise((resolve) => {
    let timeout = null;
    const finish = () => {
      drainWaiters.delete(finish);
      if (timeout !== null) clearTimeout(timeout);
      resolve();
    };
    drainWaiters.add(finish);
    timeout = setTimeout(finish, milliseconds);
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
  cancelHostIdleTimer();
  if (nativePort) return nativePort;
  const port = chrome.runtime.connectNative(NATIVE_HOST);
  nativePort = port;
  port.onMessage.addListener((response) => {
    const requestID = response && response.requestID;
    const key = inFlight.get(requestID);
    if (!key) return;
    inFlight.delete(requestID);
    const command = pending.get(key);
    if (response.ok === true) {
      const finishAcknowledgement = () => {
        flushPending();
        notifyDrainWaiters();
      };
      if (command && command.requestID === requestID) {
        pending.delete(key);
        void persistKnownIDs().then(finishAcknowledgement, finishAcknowledgement);
      } else {
        finishAcknowledgement();
      }
      return;
    }
    if (nativePort === port) nativePort = null;
    inFlight.clear();
    port.disconnect();
    notifyDrainWaiters();
  });
  port.onDisconnect.addListener(() => {
    if (nativePort !== port) return;
    nativePort = null;
    inFlight.clear();
    cancelHostIdleTimer();
    notifyDrainWaiters();
  });
  return nativePort;
}

function flushPending() {
  if (!pending.size) {
    notifyDrainWaiters();
    return;
  }
  cancelHostIdleTimer();
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
      inFlight.clear();
      if (nativePort === port) nativePort = null;
      port.disconnect();
      break;
    }
  }
}

function synchronizePolling() {
  if (hasActiveDownloads()) {
    if (pollTimer === null) {
      pollTimer = setInterval(() => {
        void serializeLifecycle(reconcile);
      }, POLL_MILLISECONDS);
    }
    cancelHostIdleTimer();
    return;
  }
  if (pollTimer !== null) clearInterval(pollTimer);
  pollTimer = null;
  scheduleHostDisconnect();
}

async function publish(commands) {
  for (const command of commands) {
    pending.set(commandKey(command), { ...command, requestID: crypto.randomUUID() });
  }
  await persistKnownIDs();
  synchronizePolling();
  flushPending();
}

async function reconcile() {
  if (!tracker) return;
  const active = await chrome.downloads.search({ state: "in_progress" });
  const activeIDs = new Set(
    active.filter((item) => Number.isSafeInteger(item.id) && item.id >= 0).map((item) => item.id)
  );
  const recoveredActive = [];
  const commands = [];
  for (const id of tracker.snapshot()) {
    if (activeIDs.has(id)) continue;
    const matches = await chrome.downloads.search({ id });
    if (!matches.length) {
      commands.push(...tracker.erase(id));
    } else if (matches[0].state === "in_progress") {
      recoveredActive.push(matches[0]);
    } else {
      commands.push(...tracker.ingest(matches[0]));
    }
  }
  commands.push(...tracker.reconcile([...active, ...recoveredActive]));
  await publish(commands);
}

function serializeLifecycle(operation) {
  const result = lifecycleTail.then(async () => {
    await initializationPromise;
    return operation();
  });
  lifecycleTail = result.catch(() => {});
  return result;
}

function onCreated(item) {
  return serializeLifecycle(async () => {
    if (tracker) await publish(tracker.ingest(item));
  });
}

function onChanged(delta) {
  return serializeLifecycle(async () => {
    if (!tracker) return;
    const items = await chrome.downloads.search({ id: delta.id });
    await publish(items.length ? tracker.ingest(items[0]) : tracker.erase(delta.id));
  });
}

function onErased(id) {
  return serializeLifecycle(async () => {
    if (tracker) await publish(tracker.erase(id));
  });
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
  if (tracker) {
    addDownloadListeners();
    return;
  }
  const state = await savedState();
  if (!state.enabled) {
    removeDownloadListeners();
    return;
  }
  tracker = new IsletChromeDownloads.Tracker(state.profileID, state.knownIDs);
  addDownloadListeners();
  await reconcile();
}

async function disableObservation() {
  removeDownloadListeners();
  if (pollTimer !== null) clearInterval(pollTimer);
  pollTimer = null;
  cancelHostIdleTimer();
  const cleanup = tracker ? tracker.disable() : [];
  pending.clear();
  inFlight.clear();
  await persistKnownIDs();
  if (tracker) {
    await publish([...cleanup, { kind: "disable", profileID: tracker.profileID }]);
    await waitForDrain();
  }
  if (nativePort) {
    const port = nativePort;
    nativePort = null;
    port.disconnect();
  }
  pending.clear();
  inFlight.clear();
  tracker = null;
  await persistKnownIDs();
  notifyDrainWaiters();
}

async function initializeObservation() {
  const state = await savedState();
  if (!state.enabled) {
    removeDownloadListeners();
    return;
  }
  tracker = new IsletChromeDownloads.Tracker(state.profileID, state.knownIDs);
  addDownloadListeners();
  await reconcile();
}

chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local" || !changes.enabled) return undefined;
  return serializeLifecycle(() =>
    changes.enabled.newValue === false ? disableObservation() : enableObservation()
  );
});

chrome.runtime.onStartup.addListener(() => serializeLifecycle(reconcile));

// Register synchronously so Chrome can wake a suspended Manifest V3 worker for download events.
// Initialization removes these listeners if the saved provider setting is disabled.
addDownloadListeners();
initializationPromise = initializeObservation();

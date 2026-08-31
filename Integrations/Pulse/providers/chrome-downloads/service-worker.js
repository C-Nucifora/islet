importScripts("provider-core.js");

const NATIVE_HOST = "dev.islet.pulse.chrome_downloads";
const POLL_MILLISECONDS = 2000;
const HOST_IDLE_MILLISECONDS = 10_000;
const COMMANDS_PER_FLUSH = 12;
const RETRY_INITIAL_MILLISECONDS = 250;
const RETRY_MAX_MILLISECONDS = 2000;
const RETRY_LIMIT = 4;
const ACKNOWLEDGEMENT_MILLISECONDS = 5000;
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
const retryStates = new Map();
const acknowledgementTimers = new Map();
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

function clearRetryState(key) {
  const state = retryStates.get(key);
  if (state && state.timer !== null) clearTimeout(state.timer);
  retryStates.delete(key);
}

function clearAllRetryStates() {
  for (const key of retryStates.keys()) clearRetryState(key);
}

function clearAcknowledgementTimer(requestID) {
  const timer = acknowledgementTimers.get(requestID);
  if (timer === undefined) return;
  clearTimeout(timer);
  acknowledgementTimers.delete(requestID);
}

function clearAllAcknowledgementTimers() {
  for (const requestID of acknowledgementTimers.keys()) clearAcknowledgementTimer(requestID);
}

function removeInFlightRequest(requestID) {
  const request = inFlight.get(requestID);
  if (!request) return null;
  inFlight.delete(requestID);
  clearAcknowledgementTimer(requestID);
  return request;
}

function removeInFlightRequestsForKey(key) {
  for (const [requestID, request] of inFlight) {
    if (request.key === key) removeInFlightRequest(requestID);
  }
}

function scheduleRetry(key, commandID) {
  const command = pending.get(key);
  if (!command || command.commandID !== commandID) return;
  let state = retryStates.get(key);
  if (!state) {
    state = { attempts: 0, ready: false, timer: null };
    retryStates.set(key, state);
  }
  state.ready = false;
  if (state.timer !== null || state.attempts >= RETRY_LIMIT) return;
  const delay = Math.min(
    RETRY_INITIAL_MILLISECONDS * 2 ** state.attempts,
    RETRY_MAX_MILLISECONDS
  );
  state.attempts += 1;
  state.timer = setTimeout(() => {
    if (retryStates.get(key) !== state) return;
    state.timer = null;
    const current = pending.get(key);
    if (!current || current.commandID !== commandID) {
      clearRetryState(key);
      return;
    }
    state.ready = true;
    flushPending();
  }, delay);
}

function scheduleAcknowledgementDeadline(key, commandID, requestID) {
  const timer = setTimeout(() => {
    if (acknowledgementTimers.get(requestID) !== timer) return;
    acknowledgementTimers.delete(requestID);
    const request = inFlight.get(requestID);
    if (!request || request.key !== key || request.commandID !== commandID) return;
    inFlight.delete(requestID);
    scheduleRetry(key, commandID);
    flushPending();
    notifyDrainWaiters();
  }, ACKNOWLEDGEMENT_MILLISECONDS);
  acknowledgementTimers.set(requestID, timer);
}

function retryIsReady(key) {
  const state = retryStates.get(key);
  return state === undefined || (state.timer === null && state.ready);
}

function retryIsExhausted(key) {
  const state = retryStates.get(key);
  return (
    state !== undefined &&
    state.timer === null &&
    !state.ready &&
    state.attempts >= RETRY_LIMIT
  );
}

function hasDeliverablePending() {
  for (const key of pending.keys()) {
    if (!retryIsExhausted(key)) return true;
  }
  return false;
}

function markRetrySent(key) {
  const state = retryStates.get(key);
  if (state) state.ready = false;
}

function scheduleTransportRetries(requests) {
  for (const request of requests) scheduleRetry(request.key, request.commandID);
}

function scheduleHostDisconnect() {
  if (!nativePort || hasDeliverablePending() || inFlight.size || hasActiveDownloads()) {
    cancelHostIdleTimer();
    return;
  }
  if (hostIdleTimer !== null) return;
  hostIdleTimer = setTimeout(() => {
    hostIdleTimer = null;
    if (!nativePort || hasDeliverablePending() || inFlight.size || hasActiveDownloads()) return;
    const port = nativePort;
    nativePort = null;
    port.disconnect();
  }, HOST_IDLE_MILLISECONDS);
}

function notifyDrainWaiters() {
  if (pending.size || inFlight.size) {
    scheduleHostDisconnect();
    return;
  }
  clearAllRetryStates();
  clearAllAcknowledgementTimers();
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
    const request = removeInFlightRequest(requestID);
    if (!request) return;
    const { key, commandID } = request;
    const command = pending.get(key);
    if (response.ok === true) {
      const finishAcknowledgement = () => {
        flushPending();
        notifyDrainWaiters();
      };
      if (command && command.commandID === commandID) {
        pending.delete(key);
        clearRetryState(key);
        void persistKnownIDs().then(finishAcknowledgement, finishAcknowledgement);
      } else {
        finishAcknowledgement();
      }
      return;
    }
    if (command && command.commandID === commandID) {
      scheduleRetry(key, commandID);
    }
    flushPending();
    notifyDrainWaiters();
  });
  port.onDisconnect.addListener(() => {
    if (nativePort !== port) return;
    nativePort = null;
    const disconnectedRequests = Array.from(inFlight.values());
    inFlight.clear();
    clearAllAcknowledgementTimers();
    cancelHostIdleTimer();
    scheduleTransportRetries(disconnectedRequests);
    flushPending();
    notifyDrainWaiters();
  });
  return nativePort;
}

function flushPending() {
  if (!pending.size) {
    notifyDrainWaiters();
    return;
  }
  const activeKeys = new Set(Array.from(inFlight.values(), (request) => request.key));
  const hasEligibleCommand = Array.from(pending.keys()).some(
    (key) => !activeKeys.has(key) && retryIsReady(key)
  );
  if (!hasEligibleCommand || inFlight.size >= COMMANDS_PER_FLUSH) return;
  cancelHostIdleTimer();
  let port;
  try {
    port = connectHost();
  } catch (_error) {
    for (const [key, command] of pending) {
      if (!activeKeys.has(key) && retryIsReady(key)) {
        scheduleRetry(key, command.commandID);
      }
    }
    return;
  }
  for (const [key, command] of pending) {
    if (inFlight.size >= COMMANDS_PER_FLUSH) break;
    if (activeKeys.has(key)) continue;
    if (!retryIsReady(key)) continue;
    try {
      const requestID = crypto.randomUUID();
      inFlight.set(requestID, { key, commandID: command.commandID });
      activeKeys.add(key);
      markRetrySent(key);
      const { commandID: _commandID, ...message } = command;
      port.postMessage({ ...message, requestID });
      scheduleAcknowledgementDeadline(key, command.commandID, requestID);
    } catch (_error) {
      const disconnectedRequests = Array.from(inFlight.values());
      inFlight.clear();
      clearAllAcknowledgementTimers();
      if (nativePort === port) nativePort = null;
      port.disconnect();
      scheduleTransportRetries(disconnectedRequests);
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
    const key = commandKey(command);
    clearRetryState(key);
    removeInFlightRequestsForKey(key);
    pending.set(key, { ...command, commandID: crypto.randomUUID() });
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
    if (!delta.state && !tracker.snapshot().includes(delta.id)) return;
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
  clearAllRetryStates();
  clearAllAcknowledgementTimers();
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
  clearAllAcknowledgementTimers();
  tracker = null;
  clearAllRetryStates();
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

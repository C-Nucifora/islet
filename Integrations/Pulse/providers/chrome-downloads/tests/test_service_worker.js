const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const providerCore = require("../provider-core.js");
const workerSource = fs.readFileSync(path.join(__dirname, "..", "service-worker.js"), "utf8");
const profileID = "12345678-1234-4123-8123-123456789abc";

function download(id, state = "in_progress", bytesReceived = 25) {
  return {
    id,
    filename: `/Users/test/Downloads/${id}.zip`,
    bytesReceived,
    totalBytes: 100,
    state,
    paused: false,
    error: state === "interrupted" ? "NETWORK_FAILED" : "",
    exists: true,
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

class FakeEvent {
  constructor() {
    this.listeners = new Set();
  }

  addListener(listener) {
    this.listeners.add(listener);
  }

  removeListener(listener) {
    this.listeners.delete(listener);
  }

  async emit(...arguments_) {
    await Promise.all(Array.from(this.listeners, (listener) => listener(...arguments_)));
  }
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function createHarness({
  state = { enabled: true, profileID, knownIDs: [] },
  storageGate = null,
  search = async () => [],
  autoAcknowledge = true,
  autoDisconnectEvent = true,
  onPortDisconnect = null,
} = {}) {
  const events = {
    created: new FakeEvent(),
    changed: new FakeEvent(),
    erased: new FakeEvent(),
    startup: new FakeEvent(),
    storageChanged: new FakeEvent(),
  };
  const writes = [];
  const searches = [];
  const messages = [];
  const ports = [];
  const intervals = new Map();
  const timeouts = new Map();
  let searchHandler = search;
  let shouldAcknowledge = autoAcknowledge;
  let nextTimerID = 1;
  let nextRequestID = 1;

  const storage = {
    async get(keys) {
      if (storageGate) await storageGate.promise;
      const names = Array.isArray(keys) ? keys : [keys];
      return Object.fromEntries(
        names.filter((name) => Object.hasOwn(state, name)).map((name) => [name, clone(state[name])])
      );
    },
    async set(changes) {
      Object.assign(state, clone(changes));
      writes.push(clone(changes));
    },
  };

  function connectNative() {
    const onMessage = new FakeEvent();
    const onDisconnect = new FakeEvent();
    const port = {
      onMessage,
      onDisconnect,
      disconnected: false,
      postMessage(command) {
        messages.push(clone(command));
        if (shouldAcknowledge) {
          queueMicrotask(() => {
            void onMessage.emit({ ok: true, requestID: command.requestID });
          });
        }
      },
      disconnect() {
        if (port.disconnected) return;
        port.disconnected = true;
        if (onPortDisconnect) onPortDisconnect();
        if (autoDisconnectEvent) queueMicrotask(() => void onDisconnect.emit());
      },
    };
    ports.push(port);
    return port;
  }

  const context = {
    IsletChromeDownloads: providerCore,
    chrome: {
      downloads: {
        onCreated: events.created,
        onChanged: events.changed,
        onErased: events.erased,
        async search(query) {
          searches.push(clone(query));
          return clone(await searchHandler(query));
        },
      },
      runtime: {
        onStartup: events.startup,
        connectNative,
      },
      storage: {
        local: storage,
        onChanged: events.storageChanged,
      },
    },
    clearInterval(identifier) {
      intervals.delete(identifier);
    },
    clearTimeout(identifier) {
      timeouts.delete(identifier);
    },
    console,
    crypto: {
      randomUUID() {
        return `00000000-0000-4000-8000-${String(nextRequestID++).padStart(12, "0")}`;
      },
    },
    importScripts() {},
    queueMicrotask,
    setInterval(callback, milliseconds) {
      const identifier = nextTimerID++;
      intervals.set(identifier, { callback, milliseconds });
      return identifier;
    },
    setTimeout(callback, milliseconds) {
      const identifier = nextTimerID++;
      timeouts.set(identifier, { callback, milliseconds });
      return identifier;
    },
  };

  vm.runInNewContext(workerSource, context, { filename: "service-worker.js" });

  async function settle() {
    for (let iteration = 0; iteration < 4; iteration += 1) {
      await new Promise((resolve) => setImmediate(resolve));
    }
  }

  return {
    events,
    intervals,
    messages,
    ports,
    searches,
    state,
    timeouts,
    writes,
    clearMessages() {
      messages.length = 0;
    },
    fireIntervals() {
      return Array.from(intervals.values(), ({ callback }) => callback());
    },
    fireTimeouts() {
      const callbacks = Array.from(timeouts.values(), ({ callback }) => callback);
      timeouts.clear();
      return callbacks.map((callback) => callback());
    },
    setAutoAcknowledge(value) {
      shouldAcknowledge = value;
    },
    async setEnabled(value) {
      const oldValue = state.enabled;
      state.enabled = value;
      await events.storageChanged.emit({ enabled: { oldValue, newValue: value } }, "local");
      await settle();
    },
    setSearch(handler) {
      searchHandler = handler;
    },
    settle,
  };
}

test("browser startup wakes and reconciles current downloads", async () => {
  const harness = createHarness();
  await harness.settle();
  harness.clearMessages();
  harness.setSearch(async (query) => (query.state === "in_progress" ? [download(1)] : []));

  await harness.events.startup.emit();
  await harness.settle();

  assert.equal(harness.messages.length, 1);
  assert.equal(harness.messages[0].kind, "upsert");
  assert.equal(harness.messages[0].item.id, 1);
});

test("created event waits for cold-start initialization", async () => {
  const storageGate = deferred();
  const harness = createHarness({ storageGate });

  const event = harness.events.created.emit(download(2));
  storageGate.resolve();
  await event;
  await harness.settle();

  assert.equal(harness.messages.length, 1);
  assert.equal(harness.messages[0].kind, "upsert");
  assert.equal(harness.messages[0].item.id, 2);
});

test("changed event waits for cold-start initialization", async () => {
  const storageGate = deferred();
  const harness = createHarness({
    storageGate,
    search: async (query) => (query.id === 3 ? [download(3, "complete", 100)] : []),
  });

  const event = harness.events.changed.emit({ id: 3, state: { current: "complete" } });
  storageGate.resolve();
  await event;
  await harness.settle();

  assert.equal(harness.messages.length, 1);
  assert.equal(harness.messages[0].kind, "upsert");
  assert.equal(harness.messages[0].item.state, "complete");
});

test("erased event waits for cold-start initialization", async () => {
  const storageGate = deferred();
  const harness = createHarness({ storageGate });

  const event = harness.events.erased.emit(4);
  storageGate.resolve();
  await event;
  await harness.settle();

  assert.equal(harness.messages.length, 1);
  assert.equal(harness.messages[0].kind, "end");
  assert.equal(harness.messages[0].id, 4);
});

test("disable remains final when a progress reconciliation is in flight", async () => {
  const pollResult = deferred();
  const harness = createHarness();
  await harness.settle();
  await harness.events.created.emit(download(5));
  await harness.settle();
  harness.clearMessages();
  harness.setSearch(async (query) => {
    if (query.state === "in_progress") return pollResult.promise;
    return [];
  });

  const polls = harness.fireIntervals();
  await Promise.resolve();
  const disable = harness.setEnabled(false);
  pollResult.resolve([download(5, "in_progress", 75)]);
  await Promise.all([...polls.filter(Boolean), disable]);
  await harness.settle();

  assert.deepEqual(harness.state.knownIDs, []);
  assert.equal(harness.messages.at(-1).kind, "disable");
  assert.equal(harness.messages.filter((command) => command.kind === "upsert").length, 1);
});

test("quick disable then enable restores download observation", async () => {
  const harness = createHarness();
  await harness.settle();

  const disable = harness.setEnabled(false);
  const enable = harness.setEnabled(true);
  await Promise.all([disable, enable]);
  harness.clearMessages();
  await harness.events.created.emit(download(6));
  await harness.settle();

  assert.equal(harness.state.enabled, true);
  assert.equal(harness.events.created.listeners.size, 1);
  assert.equal(harness.messages.length, 1);
  assert.equal(harness.messages[0].item.id, 6);
});

test("unacknowledged terminal command survives a worker restart", async () => {
  const sharedState = { enabled: true, profileID, knownIDs: [] };
  const first = createHarness({ state: sharedState });
  await first.settle();
  await first.events.created.emit(download(7));
  await first.settle();
  first.setAutoAcknowledge(false);
  first.setSearch(async (query) => (query.id === 7 ? [download(7, "complete", 100)] : []));

  await first.events.changed.emit({ id: 7, state: { current: "complete" } });
  await first.settle();

  assert.deepEqual(sharedState.knownIDs, [7]);

  const second = createHarness({
    state: sharedState,
    search: async (query) => (query.id === 7 ? [download(7, "complete", 100)] : []),
  });
  await second.settle();

  assert.equal(second.messages.length, 1);
  assert.equal(second.messages[0].kind, "upsert");
  assert.equal(second.messages[0].item.state, "complete");
});

test("polling exists only while a download is active", async () => {
  const harness = createHarness();
  await harness.settle();
  assert.equal(harness.intervals.size, 0);

  await harness.events.created.emit(download(8));
  await harness.settle();
  assert.equal(harness.intervals.size, 1);

  harness.setSearch(async (query) => (query.id === 8 ? [download(8, "complete", 100)] : []));
  await harness.events.changed.emit({ id: 8, state: { current: "complete" } });
  await harness.settle();
  assert.equal(harness.intervals.size, 0);
});

test("native host connection closes after a bounded idle grace period", async () => {
  const harness = createHarness();
  await harness.settle();
  await harness.events.created.emit(download(9));
  await harness.settle();
  harness.setSearch(async (query) => (query.id === 9 ? [download(9, "complete", 100)] : []));

  await harness.events.changed.emit({ id: 9, state: { current: "complete" } });
  await harness.settle();

  assert.equal(harness.ports.length, 1);
  assert.equal(harness.ports[0].disconnected, false);
  assert.equal(harness.timeouts.size, 1);
  harness.fireTimeouts();
  await harness.settle();
  assert.equal(harness.ports[0].disconnected, true);
});

test("late disconnect from the disabled host cannot replace the re-enabled host", async () => {
  const harness = createHarness({ autoDisconnectEvent: false });
  await harness.settle();
  await harness.events.created.emit(download(10));
  await harness.settle();
  const oldPort = harness.ports[0];

  const disable = harness.setEnabled(false);
  const enable = harness.setEnabled(true);
  await Promise.all([disable, enable]);
  await harness.events.created.emit(download(11));
  await harness.settle();
  assert.equal(harness.ports.length, 2);

  await oldPort.onDisconnect.emit();
  harness.setSearch(async (query) => (query.id === 11 ? [download(11, "in_progress", 50)] : []));
  await harness.events.changed.emit({ id: 11 });
  await harness.settle();

  assert.equal(harness.ports.length, 2);
});

test("rejected terminal command remains durable while waiting to retry", async () => {
  const harness = createHarness();
  await harness.settle();
  await harness.events.created.emit(download(12));
  await harness.settle();
  harness.setAutoAcknowledge(false);
  harness.setSearch(async (query) =>
    query.id === 12 ? [download(12, "interrupted", 50)] : []
  );

  await harness.events.changed.emit({ id: 12, state: { current: "interrupted" } });
  await harness.settle();
  const port = harness.ports[0];
  const terminal = harness.messages.at(-1);
  await port.onMessage.emit({ ok: false, requestID: terminal.requestID });
  await harness.settle();

  assert.deepEqual(harness.state.knownIDs, [12]);
  assert.equal(port.disconnected, false);
  assert.equal(harness.timeouts.size, 1);
});

test("failed final terminal delivery retries without another browser event", async () => {
  const harness = createHarness();
  await harness.settle();
  await harness.events.created.emit(download(14));
  await harness.settle();
  harness.setAutoAcknowledge(false);
  harness.setSearch(async (query) =>
    query.id === 14 ? [download(14, "complete", 100)] : []
  );

  await harness.events.changed.emit({ id: 14, state: { current: "complete" } });
  await harness.settle();
  const firstTerminal = harness.messages.at(-1);
  await harness.ports[0].onMessage.emit({ ok: false, requestID: firstTerminal.requestID });
  await harness.settle();

  assert.equal(harness.intervals.size, 0);
  assert.equal(harness.timeouts.size, 1);
  harness.setAutoAcknowledge(true);
  harness.fireTimeouts();
  await harness.settle();

  assert.equal(harness.ports.length, 1);
  assert.equal(
    harness.messages.filter(
      (command) => command.kind === "upsert" && command.item.state === "complete"
    ).length,
    2
  );
  assert.deepEqual(harness.state.knownIDs, []);
});

test("command rejection retries on the same host without ending another active download", async () => {
  const hostActiveDownloads = new Set();
  const harness = createHarness({
    onPortDisconnect() {
      hostActiveDownloads.clear();
    },
  });
  await harness.settle();
  await harness.events.created.emit(download(17));
  await harness.settle();
  hostActiveDownloads.add(17);
  await harness.events.created.emit(download(18));
  await harness.settle();
  harness.setAutoAcknowledge(false);
  harness.setSearch(async (query) =>
    query.id === 18 ? [download(18, "complete", 100)] : []
  );

  await harness.events.changed.emit({ id: 18, state: { current: "complete" } });
  await harness.settle();
  const firstTerminal = harness.messages.at(-1);
  await harness.events.created.emit(download(19));
  await harness.settle();
  const otherProgress = harness.messages.at(-1);
  await harness.ports[0].onMessage.emit({ ok: false, requestID: firstTerminal.requestID });
  await harness.ports[0].onMessage.emit({ ok: true, requestID: otherProgress.requestID });
  await harness.settle();

  assert.equal(harness.ports[0].disconnected, false);
  assert.deepEqual(Array.from(hostActiveDownloads), [17]);
  assert.equal(harness.timeouts.size, 1);
  assert.equal(
    harness.messages.filter(
      (command) => command.kind === "upsert" && command.item.state === "complete"
    ).length,
    1
  );

  harness.setAutoAcknowledge(true);
  harness.fireTimeouts();
  await harness.settle();

  assert.equal(harness.ports.length, 1);
  assert.deepEqual(Array.from(hostActiveDownloads), [17]);
  assert.equal(
    harness.messages.filter(
      (command) => command.kind === "upsert" && command.item.state === "complete"
    ).length,
    2
  );
  assert.deepEqual(harness.state.knownIDs, [17, 19]);
});

test("failed final terminal delivery uses a bounded retry budget", async () => {
  const harness = createHarness();
  await harness.settle();
  await harness.events.created.emit(download(15));
  await harness.settle();
  harness.setAutoAcknowledge(false);
  harness.setSearch(async (query) =>
    query.id === 15 ? [download(15, "interrupted", 50)] : []
  );

  await harness.events.changed.emit({ id: 15, state: { current: "interrupted" } });
  await harness.settle();

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const port = harness.ports.at(-1);
    const command = harness.messages.at(-1);
    await port.onMessage.emit({ ok: false, requestID: command.requestID });
    await harness.settle();
    if (attempt < 4) {
      assert.equal(harness.timeouts.size, 1);
      harness.fireTimeouts();
      await harness.settle();
    }
  }

  assert.equal(harness.messages.length, 6);
  assert.equal(harness.timeouts.size, 0);
  assert.deepEqual(harness.state.knownIDs, [15]);
});

test("transport disconnect retries remain bounded for every affected command", async () => {
  const harness = createHarness({ autoAcknowledge: false });
  await harness.settle();
  await harness.events.created.emit(download(22, "complete", 100));
  await harness.events.created.emit(download(23, "complete", 100));
  await harness.settle();

  for (let disconnection = 0; disconnection < 5; disconnection += 1) {
    const portCount = harness.ports.length;
    await harness.ports.at(-1).onDisconnect.emit();
    await harness.settle();

    assert.equal(harness.ports.length, portCount);
    if (disconnection < 4) {
      assert.equal(harness.timeouts.size, 2);
      harness.fireTimeouts();
      await harness.settle();
      assert.equal(harness.ports.length, portCount + 1);
    } else {
      assert.equal(harness.timeouts.size, 0);
    }
  }

  for (const id of [22, 23]) {
    assert.equal(harness.messages.filter((item) => item.item?.id === id).length, 5);
  }
  assert.deepEqual(harness.state.knownIDs, [22, 23]);
});

test("an exhausted terminal command cannot consume a later command's retry budget", async () => {
  const harness = createHarness();
  await harness.settle();
  await harness.events.created.emit(download(20));
  await harness.settle();
  harness.setAutoAcknowledge(false);
  harness.setSearch(async (query) =>
    query.id === 20 ? [download(20, "complete", 100)] : []
  );
  await harness.events.changed.emit({ id: 20, state: { current: "complete" } });
  await harness.settle();

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const command = harness.messages
      .filter((item) => item.item?.id === 20 && item.item.state === "complete")
      .at(-1);
    await harness.ports[0].onMessage.emit({ ok: false, requestID: command.requestID });
    await harness.settle();
    if (attempt < 4) {
      harness.fireTimeouts();
      await harness.settle();
    }
  }

  assert.equal(
    harness.messages.filter(
      (item) => item.item?.id === 20 && item.item.state === "complete"
    ).length,
    5
  );

  await harness.events.created.emit(download(21, "complete", 100));
  await harness.settle();

  assert.equal(
    harness.messages.filter(
      (item) => item.item?.id === 20 && item.item.state === "complete"
    ).length,
    5
  );
  const laterTerminal = harness.messages
    .filter((item) => item.item?.id === 21 && item.item.state === "complete")
    .at(-1);
  await harness.ports[0].onMessage.emit({
    ok: false,
    requestID: laterTerminal.requestID,
  });
  await harness.settle();

  assert.equal(harness.timeouts.size, 1);
  harness.setAutoAcknowledge(true);
  harness.fireTimeouts();
  await harness.settle();

  assert.equal(
    harness.messages.filter(
      (item) => item.item?.id === 20 && item.item.state === "complete"
    ).length,
    5
  );
  assert.equal(
    harness.messages.filter(
      (item) => item.item?.id === 21 && item.item.state === "complete"
    ).length,
    2
  );
  assert.deepEqual(harness.state.knownIDs, [20]);
});

test("exhausted in-flight commands cannot block a later unsent command", async () => {
  const harness = createHarness({ autoAcknowledge: false });
  await harness.settle();
  const saturatedIDs = Array.from({ length: 12 }, (_, index) => 30 + index);
  for (const id of saturatedIDs) {
    await harness.events.created.emit(download(id, "complete", 100));
  }
  await harness.settle();

  for (let failure = 0; failure < 4; failure += 1) {
    for (const id of saturatedIDs) {
      const command = harness.messages.filter((item) => item.item?.id === id).at(-1);
      await harness.ports.at(-1).onMessage.emit({
        ok: false,
        requestID: command.requestID,
      });
    }
    await harness.settle();
    harness.fireTimeouts();
    await harness.settle();
  }

  await harness.events.created.emit(download(50, "complete", 100));
  await harness.settle();
  assert.equal(harness.messages.filter((item) => item.item?.id === 50).length, 0);

  for (const id of saturatedIDs) {
    const command = harness.messages.filter((item) => item.item?.id === id).at(-1);
    await harness.ports.at(-1).onMessage.emit({ ok: false, requestID: command.requestID });
  }
  await harness.settle();

  assert.equal(harness.messages.filter((item) => item.item?.id === 50).length, 1);
});

test("terminal state supersedes in-flight progress after the stale acknowledgement", async () => {
  const harness = createHarness({ autoAcknowledge: false });
  await harness.settle();
  await harness.events.created.emit(download(13));
  await harness.settle();
  const progress = harness.messages[0];
  harness.setSearch(async (query) =>
    query.id === 13 ? [download(13, "complete", 100)] : []
  );

  await harness.events.changed.emit({ id: 13, state: { current: "complete" } });
  await harness.settle();
  assert.equal(harness.messages.length, 1);
  await harness.ports[0].onMessage.emit({ ok: true, requestID: progress.requestID });
  await harness.settle();

  assert.equal(harness.ports[0].disconnected, false);
  assert.equal(harness.messages.length, 2);
  assert.equal(harness.messages[1].item.state, "complete");
});

test("acknowledged terminal ignores later property-only changes", async () => {
  const harness = createHarness();
  await harness.settle();
  await harness.events.created.emit(download(16));
  await harness.settle();
  harness.setSearch(async (query) =>
    query.id === 16 ? [download(16, "complete", 100)] : []
  );
  await harness.events.changed.emit({ id: 16, state: { current: "complete" } });
  await harness.settle();
  harness.clearMessages();

  await harness.events.changed.emit({ id: 16, exists: { previous: true, current: false } });
  await harness.settle();

  assert.deepEqual(harness.messages, []);
});

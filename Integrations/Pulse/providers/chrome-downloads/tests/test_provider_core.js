const test = require("node:test");
const assert = require("node:assert/strict");
const { Tracker, sanitize } = require("../provider-core.js");

const profileID = "12345678-1234-4123-8123-123456789abc";

function item(id, filename, state = "in_progress", error = "") {
  return {
    id,
    filename,
    state,
    error,
    bytesReceived: 50,
    totalBytes: 100,
    url: "https://secret.example/file",
    referrer: "https://secret.example/account",
  };
}

test("duplicate display names retain independent browser IDs", () => {
  const tracker = new Tracker(profileID);
  const commands = tracker.reconcile([
    item(41, "/Users/test/Downloads/report.pdf"),
    item(42, "/Users/test/Downloads/archive/report.pdf"),
  ]);
  assert.deepEqual(commands.map((command) => command.item.id), [41, 42]);
  assert.deepEqual(tracker.snapshot(), [41, 42]);
});

test("restart recovery ends cached IDs that Chrome no longer reports", () => {
  const tracker = new Tracker(profileID, [10, 11]);
  const commands = tracker.reconcile([item(11, "/tmp/current")]);
  assert.deepEqual(commands.map(({ kind, id, item: value }) => [kind, id ?? value.id]), [
    ["end", 10],
    ["upsert", 11],
  ]);
});

test("unchanged progress does not consume another Pulse command", () => {
  const tracker = new Tracker(profileID);
  const active = item(12, "/tmp/current");
  assert.equal(tracker.reconcile([active]).length, 1);
  assert.equal(tracker.reconcile([active]).length, 0);
  active.bytesReceived = 75;
  assert.equal(tracker.reconcile([active]).length, 1);
});

test("cancellation and removal end the matching item", () => {
  const tracker = new Tracker(profileID, [7, 8]);
  assert.equal(tracker.ingest(item(7, "/tmp/a", "interrupted", "USER_CANCELED"))[0].kind, "end");
  assert.equal(tracker.erase(8)[0].kind, "end");
  assert.deepEqual(tracker.snapshot(), []);
});

test("disable returns cleanup and leaves no observed transfer state", () => {
  const tracker = new Tracker(profileID, [3, 4]);
  assert.deepEqual(tracker.disable().map((command) => command.id), [3, 4]);
  assert.deepEqual(tracker.snapshot(), []);
});

test("browser URLs never cross the native messaging boundary", () => {
  const value = sanitize(item(2, "/tmp/file"));
  assert.equal(value.url, undefined);
  assert.equal(value.referrer, undefined);
  assert.equal(value.filename, "/tmp/file");
});

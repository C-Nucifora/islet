/* Pure download state reducer shared by the Chrome service worker and Node tests. */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  root.IsletChromeDownloads = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const CANCEL_ERRORS = new Set(["USER_CANCELED", "USER_SHUTDOWN"]);

  function fingerprint(item) {
    return JSON.stringify([
      item.filename,
      item.bytesReceived,
      item.totalBytes,
      item.state,
      item.paused,
      item.error,
      item.exists,
    ]);
  }

  function cleanProfileID(value) {
    return typeof value === "string" && /^[0-9a-f-]{16,64}$/i.test(value) ? value : null;
  }

  function sanitize(item) {
    if (!item || !Number.isSafeInteger(item.id) || item.id < 0) return null;
    return {
      id: item.id,
      filename: typeof item.filename === "string" ? item.filename : "",
      bytesReceived: Number.isFinite(item.bytesReceived) ? Math.max(0, item.bytesReceived) : 0,
      totalBytes: Number.isFinite(item.totalBytes) ? item.totalBytes : -1,
      state: typeof item.state === "string" ? item.state : "in_progress",
      paused: item.paused === true,
      error: typeof item.error === "string" ? item.error : "",
      exists: item.exists !== false,
    };
  }

  class Tracker {
    constructor(profileID, knownIDs = []) {
      this.profileID = cleanProfileID(profileID);
      if (!this.profileID) throw new Error("invalid profile ID");
      this.known = new Set(knownIDs.filter((id) => Number.isSafeInteger(id) && id >= 0));
      this.fingerprints = new Map();
    }

    reconcile(items) {
      const current = new Map();
      for (const raw of items || []) {
        const item = sanitize(raw);
        if (item && item.state === "in_progress") current.set(item.id, item);
      }
      const commands = [];
      for (const id of this.known) {
        if (!current.has(id)) commands.push({ kind: "end", profileID: this.profileID, id });
      }
      for (const item of current.values()) {
        const next = fingerprint(item);
        if (this.fingerprints.get(item.id) !== next) {
          commands.push({ kind: "upsert", profileID: this.profileID, item });
          this.fingerprints.set(item.id, next);
        }
      }
      for (const id of this.fingerprints.keys()) {
        if (!current.has(id)) this.fingerprints.delete(id);
      }
      this.known = new Set(current.keys());
      return commands;
    }

    ingest(raw) {
      const item = sanitize(raw);
      if (!item) return [];
      if (item.state === "interrupted" && CANCEL_ERRORS.has(item.error)) {
        this.known.delete(item.id);
        this.fingerprints.delete(item.id);
        return [{ kind: "end", profileID: this.profileID, id: item.id }];
      }
      if (item.state === "complete" || item.state === "interrupted") {
        this.known.delete(item.id);
        this.fingerprints.delete(item.id);
        return [{ kind: "upsert", profileID: this.profileID, item }];
      }
      this.known.add(item.id);
      const next = fingerprint(item);
      if (this.fingerprints.get(item.id) === next) return [];
      this.fingerprints.set(item.id, next);
      return [{ kind: "upsert", profileID: this.profileID, item }];
    }

    erase(id) {
      if (!Number.isSafeInteger(id) || id < 0) return [];
      this.known.delete(id);
      this.fingerprints.delete(id);
      return [{ kind: "end", profileID: this.profileID, id }];
    }

    disable() {
      const commands = Array.from(this.known, (id) => ({
        kind: "end",
        profileID: this.profileID,
        id,
      }));
      this.known.clear();
      this.fingerprints.clear();
      return commands;
    }

    snapshot() {
      return Array.from(this.known).sort((left, right) => left - right);
    }
  }

  return { Tracker, sanitize };
});

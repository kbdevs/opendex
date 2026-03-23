// FILE: session-state.js
// Purpose: Persists the latest active thread so the user can reopen it on the Mac for handoff.
// Layer: CLI helper
// Exports: rememberActiveThread, openLastActiveThread, readLastActiveThread
// Depends on: fs, os, path, child_process

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const DEFAULT_STATE_DIR = path.join(os.homedir(), ".opendex");
const LEGACY_STATE_DIR = path.join(os.homedir(), ".remodex");
const DEFAULT_BUNDLE_ID = "com.openai.codex";

function resolveStateDir() {
  if (fs.existsSync(DEFAULT_STATE_DIR)) {
    return DEFAULT_STATE_DIR;
  }
  if (fs.existsSync(LEGACY_STATE_DIR)) {
    return LEGACY_STATE_DIR;
  }
  return DEFAULT_STATE_DIR;
}

function resolveStateFile() {
  return path.join(resolveStateDir(), "last-thread.json");
}

function rememberActiveThread(threadId, source) {
  if (!threadId || typeof threadId !== "string") {
    return false;
  }

  const payload = {
    threadId,
    source: source || "unknown",
    updatedAt: new Date().toISOString(),
  };

  const stateDir = resolveStateDir();
  fs.mkdirSync(stateDir, { recursive: true });
  fs.writeFileSync(
    path.join(stateDir, "last-thread.json"),
    JSON.stringify(payload, null, 2),
  );
  return true;
}

function openLastActiveThread({ bundleId = DEFAULT_BUNDLE_ID } = {}) {
  const state = readState();
  const threadId = state?.threadId;
  if (!threadId) {
    throw new Error("No remembered Opendex thread found yet.");
  }

  const targetUrl = `codex://threads/${threadId}`;
  execFileSync("open", ["-b", bundleId, targetUrl], { stdio: "ignore" });
  return state;
}

function readState() {
  const stateFile = resolveStateFile();
  if (!fs.existsSync(stateFile)) {
    return null;
  }

  const raw = fs.readFileSync(stateFile, "utf8");
  return JSON.parse(raw);
}

module.exports = {
  rememberActiveThread,
  openLastActiveThread,
  readLastActiveThread: readState,
};

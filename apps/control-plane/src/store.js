const fs = require("fs");
const path = require("path");
const { DEFAULT_DEVICE_CONFIG } = require("./contracts");

// Storage driver selection.
//   file   (default) - persists to data/store.json on a writable disk
//                      (local dev, Azure App Service, bare metal).
//   memory           - keeps state in a process-level object only. Nothing is
//                      written to disk. Intended for ephemeral/serverless hosts
//                      (e.g. Vercel) where the filesystem is read-only and not
//                      shared across invocations. State is LOST on cold start
//                      and is NOT shared when Vercel scales to >1 instance.
//
// Defaults to "memory" automatically on Vercel (process.env.VERCEL is set on
// every deployment) and can be forced with STORE_DRIVER=memory|file.
const driver =
  (process.env.STORE_DRIVER || (process.env.VERCEL ? "memory" : "file")).toLowerCase();
const useMemory = driver === "memory";

const dataDir = process.env.DATA_DIR || path.join(__dirname, "..", "data");
const dataFile = path.join(dataDir, "store.json");

function initialData() {
  return {
    devices: {},
    configs: {
      baseline: DEFAULT_DEVICE_CONFIG,
      byDevice: {}
    },
    jobs: [],
    audit: [],
    counters: {
      job: 1,
      configVersion: DEFAULT_DEVICE_CONFIG.version
    }
  };
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

// --- memory driver -------------------------------------------------------
// A single process-level object. Callers receive clones so that direct
// mutations of a readStore() result do not persist unless writeStore() is
// called, matching the file driver's read-parse / write-stringify semantics.
let memoryState = null;

function readMemory() {
  if (!memoryState) {
    memoryState = initialData();
  }
  return clone(memoryState);
}

function writeMemory(nextValue) {
  memoryState = clone(nextValue);
}

// --- file driver ---------------------------------------------------------
function ensureFileStore() {
  if (!fs.existsSync(dataDir)) {
    fs.mkdirSync(dataDir, { recursive: true });
  }
  if (!fs.existsSync(dataFile)) {
    fs.writeFileSync(dataFile, JSON.stringify(initialData(), null, 2));
  }
}

function readFile() {
  ensureFileStore();
  return JSON.parse(fs.readFileSync(dataFile, "utf-8"));
}

function writeFile(nextValue) {
  fs.writeFileSync(dataFile, JSON.stringify(nextValue, null, 2));
}

// --- public API ----------------------------------------------------------
function readStore() {
  return useMemory ? readMemory() : readFile();
}

function writeStore(nextValue) {
  return useMemory ? writeMemory(nextValue) : writeFile(nextValue);
}

function mutateStore(mutator) {
  const data = readStore();
  const result = mutator(data) || data;
  writeStore(result);
  return result;
}

module.exports = {
  driver,
  readStore,
  mutateStore
};

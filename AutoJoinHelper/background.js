// BloxKit Auto-Join Helper: background part (v2.2)
// Keeps a list of tabs opened by BloxKit for a launch, and asks BloxKit
// (http://127.0.0.1:<port>, this PC only) about each one every 2 seconds:
//   "wait"  -> ask again later
//   "close" -> the launch worked: close THIS tab (only if it is still on roblox.com)
//   anything else, or no answer for 30 seconds -> stop asking and leave the tab alone
// A launch that got its answer is never asked about again, even when its tab loads another
// page later (so a "keep" stays a keep). Tabs the user closes, and launches older than
// 15 minutes, are forgotten.

const POLL_MS = 2000;
const GIVE_UP_MS = 15 * 60 * 1000;
const MAX_FAILS = 15;
const VERSION = chrome.runtime.getManifest().version;
const ROBLOX = /^https:\/\/(www|web)\.roblox\.com\//;

async function load() { return (await chrome.storage.session.get(["tabs", "done"])); }
async function save(tabs, done) { await chrome.storage.session.set({ tabs, done }); }

// Registering a tab and asking about tabs both read, change and save the same list.
// They take turns, so neither overwrites what the other just saved.
let turn = Promise.resolve();
function inTurn(fn) { const p = turn.then(fn, fn); turn = p.catch(() => {}); return p; }

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || msg.type !== "rml-launch" || !sender.tab || !/^[0-9a-f-]{36}$/i.test(msg.op)) return;
  if (!Number.isInteger(msg.port) || msg.port < 1 || msg.port > 65535) return;
  inTurn(() => track(sender.tab.id, msg.op, msg.port));
});

async function track(tabId, op, port) {
  const s = await load();
  const tabs = s.tabs || {}, done = s.done || {};
  if (done[op]) return;                                   // already answered: leave this tab alone
  if (tabs[tabId] && tabs[tabId].op === op) return;       // the same launch, on its next page
  tabs[tabId] = { op, port, since: Date.now(), fails: 0 };
  await save(tabs, done);
  chrome.alarms.create("rml-poll", { periodInMinutes: 0.5 });   // wakes us up if Chrome stops this script
  pollSoon();
}

let timer = null;
function pollSoon() { if (!timer) timer = setTimeout(() => { timer = null; inTurn(pollAll); }, POLL_MS); }

async function ask(e) {
  const ctl = new AbortController();
  const stop = setTimeout(() => ctl.abort(), 5000);
  try {
    const r = await fetch(`http://127.0.0.1:${e.port}/launch/${e.op}?v=${VERSION}`, { signal: ctl.signal, cache: "no-store" });
    return (await r.json()).state;
  } finally { clearTimeout(stop); }
}

async function pollAll() {
  const s = await load();
  const tabs = s.tabs || {}, done = s.done || {};
  const now = Date.now();
  for (const op of Object.keys(done)) if (now - done[op] > GIVE_UP_MS) delete done[op];   // keep the list short
  for (const id of Object.keys(tabs)) {
    const e = tabs[id];
    let tab;
    try { tab = await chrome.tabs.get(Number(id)); } catch { delete tabs[id]; continue; }   // closed already
    if (now - e.since > GIVE_UP_MS) { delete tabs[id]; done[e.op] = now; continue; }
    let state;
    try { state = await ask(e); e.fails = 0; }
    catch { if (++e.fails >= MAX_FAILS) { delete tabs[id]; done[e.op] = now; } continue; }   // BloxKit not answering
    if (state === "wait") continue;
    if (state === "close" && ROBLOX.test(tab.url || "")) { try { await chrome.tabs.remove(tab.id); } catch {} }
    delete tabs[id]; done[e.op] = now;
  }
  await save(tabs, done);
  if (Object.keys(tabs).length) pollSoon(); else chrome.alarms.clear("rml-poll");
}

chrome.alarms.onAlarm.addListener((a) => { if (a.name === "rml-poll") inTurn(pollAll); });

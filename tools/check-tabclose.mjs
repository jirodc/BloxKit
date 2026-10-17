// Checks the helper's tab closing in a real Chrome, end to end:
//     node tools\check-tabclose.mjs
// Needs Node 22+ and Google Chrome. Opens Chrome hidden with a throwaway profile, loads the
// helper the supported way (DevTools Extensions.loadUnpacked), and plays Roblox Manager's part
// with a tiny local server. Logged out, so nothing is launched.
import { spawn } from "node:child_process";
import { createServer } from "node:http";
import { readFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const here = dirname(fileURLToPath(import.meta.url));
const helperDir = resolve(here, "..", "AutoJoinHelper");
const chrome = ["C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
  join(process.env.LOCALAPPDATA || "", "Google\\Chrome\\Application\\chrome.exe")].find((p) => { try { readFileSync(p, { flag: "r" }); return true; } catch { return false; } });
if (!chrome) { console.log("Chrome not found."); process.exit(2); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---- Roblox Manager's part ----
const op = { close: randomUUID(), keep: randomUUID(), priv: randomUUID(), auto: randomUUID() };
const asked = {};          // op -> number of times asked
const seen = [];           // { origin, v }
const server = createServer((req, res) => {
  const m = req.url.match(/^\/launch\/([0-9a-f-]{36})\?v=([\d.]+)$/);
  let state = "unknown";
  if (m) {
    asked[m[1]] = (asked[m[1]] || 0) + 1;
    seen.push({ origin: req.headers.origin || "", v: m[2] });
    if (m[1] === op.close || m[1] === op.auto) state = asked[m[1]] > 2 ? "close" : "wait";   // "wait" twice first
    else if (m[1] === op.keep) state = asked[m[1]] > 1 ? "close" : "keep";   // a later "close" must never be asked for
    else if (m[1] === op.priv) state = "wait";
  }
  res.writeHead(200, { "Content-Type": "application/json" });
  res.end(JSON.stringify({ state }));
});
await new Promise((r) => server.listen(0, "127.0.0.1", r));
const port = server.address().port;

// ---- Chrome over a DevTools pipe ----
const profile = mkdtempSync(join(tmpdir(), "rml-tabclose-"));
const proc = spawn(chrome, ["--headless=new", "--remote-debugging-pipe", "--enable-unsafe-extension-debugging",
  `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "about:blank"],
  { stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"] });
const toChrome = proc.stdio[3], fromChrome = proc.stdio[4];
let nextId = 0; const pending = new Map(); let buf = "";
fromChrome.on("data", (d) => {
  buf += d.toString();
  let i;
  while ((i = buf.indexOf("\0")) >= 0) {
    const msg = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
    if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  }
});
const send = (method, params = {}, sessionId) => new Promise((r) => {
  const id = ++nextId; pending.set(id, r);
  toChrome.write(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }) + "\0");
});

let fails = 0;
const check = (name, ok, why = "") => { if (!ok) fails++; console.log(`${ok ? "PASS" : "FAIL"}  ${name}${ok || !why ? "" : `   (${why})`}`); };
const open = async (url) => (await send("Target.createTarget", { url })).result.targetId;
const alive = async () => new Set((await send("Target.getTargets")).result.targetInfos.filter((t) => t.type === "page").map((t) => t.targetId));
const hrefOf = async (targetId) => {
  const s = (await send("Target.attachToTarget", { targetId, flatten: true })).result.sessionId;
  return (await send("Runtime.evaluate", { expression: "location.href", returnByValue: true }, s)).result.result.value;
};

try {
  const loaded = await send("Extensions.loadUnpacked", { path: helperDir });
  check("helper loads in Chrome", !!loaded.result?.id, JSON.stringify(loaded.error || ""));
  const extId = loaded.result?.id;

  const game = "https://www.roblox.com/games/920587237";
  const t = {
    close: await open(`${game}#rml-launch&op=${op.close}&port=${port}`),
    keep: await open(`${game}#rml-launch&op=${op.keep}&port=${port}`),
    other: await open(game),
    priv: await open(`${game}?privateServerLinkCode=12345678#rml-launch&op=${op.priv}&port=${port}`),
    auto: await open(`${game}#rml-autojoin&op=${op.auto}&port=${port}`),
  };
  let open1 = await alive();
  for (let i = 0; i < 40 && (open1.has(t.close) || open1.has(t.auto)); i++) { await sleep(1000); open1 = await alive(); }

  check("the tab of a launch that worked is closed", !open1.has(t.close), `asked ${asked[op.close] || 0} times`);
  check("it was only closed after Roblox Manager said so (asked 3+ times)", (asked[op.close] || 0) >= 3);
  check("with auto-join on too, the tab is closed", !open1.has(t.auto), `asked ${asked[op.auto] || 0} times`);
  check("the tab of a launch that failed stays open", open1.has(t.keep) && (asked[op.keep] || 0) >= 1);
  check("an unrelated roblox.com tab stays open", open1.has(t.other));
  check("a tab still waiting stays open", open1.has(t.priv));
  const href = open1.has(t.priv) ? await hrefOf(t.priv) : "";
  check("a private server link keeps its code, and the marker is removed", href.includes("privateServerLinkCode=12345678") && !href.includes("rml-"), href);
  check("no web page asked (no origin, or the extension)", seen.length > 0 && seen.every((s) => s.origin === "" || s.origin === `chrome-extension://${extId}`), [...new Set(seen.map((s) => s.origin))].join(","));
  check("the helper says its version (2.2)", seen.length > 0 && seen.every((s) => s.v === "2.2"));

  // After "keep", the same tab loads another roblox.com page (the tab still remembers its launch id).
  const keptAsks = asked[op.keep] || 0;
  const ks = (await send("Target.attachToTarget", { targetId: t.keep, flatten: true })).result.sessionId;
  await send("Page.navigate", { url: `${game}?again=1` }, ks);
  await sleep(9000);
  const open2 = await alive();
  check("a tab that got \"keep\" stays open when it loads another page", open2.has(t.keep));
  check("...and the helper doesn't ask about that launch again", (asked[op.keep] || 0) === keptAsks, `asked ${asked[op.keep]} times`);
} finally {
  proc.kill();
  server.close();
  await sleep(500);
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
}
console.log(fails ? `\n${fails} check(s) failed.` : "\nAll tab-closing checks passed.");
process.exit(fails ? 1 : 0);

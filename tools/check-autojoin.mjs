// Checks the Auto-Join Helper against the live roblox.com pages.
// Run when auto-join stops working (Roblox changes its site often):
//     node tools\check-autojoin.mjs
// Needs Node 22+ and Google Chrome. It opens Chrome hidden, logged out, runs the
// helper the way Chrome does (document_start, in the page), and checks which Roblox
// launcher call it made. Nothing is actually launched: logged out, Roblox only shows a login box.
import { spawn } from "node:child_process";
import { readFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const helper = readFileSync(join(here, "..", "AutoJoinHelper", "autojoin.js"), "utf8");
const chrome = ["C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
  "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
  join(process.env.LOCALAPPDATA || "", "Google\\Chrome\\Application\\chrome.exe")].find((p) => { try { readFileSync(p, { flag: "r" }); return true; } catch { return false; } });
if (!chrome) { console.log("Chrome not found."); process.exit(2); }

const PLACE = 920587237; // any public game works
const cases = [
  { name: "game link", url: `https://www.roblox.com/games/${PLACE}#rml-autojoin`, expect: `joinMultiplayerGame(${PLACE})` },
  { name: "private server link", url: `https://www.roblox.com/games/${PLACE}?privateServerLinkCode=12345678#rml-autojoin`,
    expect: `joinPrivateGame(${PLACE},null,12345678)`, urlMustContain: "privateServerLinkCode=12345678" },
  { name: "rejoin the same server", url: `https://www.roblox.com/games/${PLACE}#rml-autojoin&job=eff40c2e-7776-48fd-a3f7-d6c7468fb88a&place=${PLACE}`,
    expect: `joinGameInstance(${PLACE},eff40c2e-7776-48fd-a3f7-d6c7468fb88a)` },
  { name: "profile link (join main)", url: "https://www.roblox.com/users/1/profile#rml-autojoin", expect: "followPlayerIntoGame(1)" },
  { name: "page NOT opened by the app", url: `https://www.roblox.com/games/${PLACE}`, expect: null },
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const port = 9300 + Math.floor(Math.random() * 500);
const profile = mkdtempSync(join(tmpdir(), "rml-check-"));
const proc = spawn(chrome, ["--headless=new", `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--no-first-run", "about:blank"], { stdio: "ignore" });

let fails = 0;
try {
  for (const c of cases) {
    let target;
    for (let i = 0; i < 40 && !target; i++) {
      await sleep(250);
      try { target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" })).json(); } catch {}
    }
    const ws = new WebSocket(target.webSocketDebuggerUrl);
    await new Promise((r) => (ws.onopen = r));
    let id = 0; const pending = new Map(); let loaded = false;
    ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && pending.has(d.id)) { pending.get(d.id)(d); pending.delete(d.id); } else if (d.method === "Page.loadEventFired") loaded = true; };
    const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
    await send("Page.enable");
    await send("Page.addScriptToEvaluateOnNewDocument", { source: helper });
    await send("Page.navigate", { url: c.url });
    for (let i = 0; i < 60 && !loaded; i++) await sleep(500);
    let did = null;
    for (let i = 0; i < 24; i++) { // up to 12 s for the helper to act
      await sleep(500);
      did = (await send("Runtime.evaluate", { expression: "document.documentElement.getAttribute('data-rml-autojoin')", returnByValue: true })).result.result.value;
      if (did && c.expect) break;
    }
    const href = (await send("Runtime.evaluate", { expression: "location.href", returnByValue: true })).result.result.value;
    let ok = did === c.expect;
    if (c.urlMustContain && !href.includes(c.urlMustContain)) ok = false;
    if (!ok) fails++;
    console.log(`${ok ? "PASS" : "FAIL"}  ${c.name.padEnd(28)} helper did: ${did ?? "nothing"}${ok ? "" : `   (expected ${c.expect ?? "nothing"}; page: ${href})`}`);
    ws.close();
  }
} finally {
  proc.kill();
  await sleep(500);
  try { rmSync(profile, { recursive: true, force: true }); } catch {}
}
console.log(fails ? `\n${fails} check(s) failed. Roblox may have changed its page.` : "\nAll checks passed.");
process.exit(fails ? 1 : 0);

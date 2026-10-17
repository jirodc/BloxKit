// BloxKit Auto-Join Helper: tab closing (v2.2)
// Only acts on pages opened by BloxKit with a launch id: #rml-launch&op=<id>&port=<n>
// (or #rml-autojoin&...&op=<id>&port=<n> when auto-join is on).
// It tells the helper's background part which tab belongs to that launch. The background
// asks BloxKit (on this PC only) whether the launch worked, and closes only this
// tab when BloxKit says so. Nothing is closed when the launch fails or can't be confirmed.
//
// Runs before Roblox's own scripts (document_start), in the extension's own space, so it can
// talk to the background part. Either this script or autojoin.js may run first: whichever
// sees the marker saves the launch id in this tab's sessionStorage.

(function () {
  const KEY = "rml-op";
  const FRESH_MS = 15 * 60 * 1000;
  const h = location.hash;
  const op = h.match(/[#&]op=([0-9a-f-]{36})/i);
  const port = h.match(/[#&]port=(\d{2,5})/);
  if (op && port) {
    try { sessionStorage.setItem(KEY, op[1] + "@" + port[1] + "@" + Date.now()); } catch (e) {}
    // Take the marker out before Roblox's page sees it (it would move ?privateServerLinkCode=
    // behind the #). With auto-join, autojoin.js removes the whole marker itself.
    if (h.includes("rml-launch")) history.replaceState(history.state, "", location.pathname + location.search);
  }
  let saved = "";
  try { saved = sessionStorage.getItem(KEY) || ""; } catch (e) {}
  const s = saved.match(/^([0-9a-f-]{36})@(\d+)@(\d+)$/i);
  if (!s) return;
  if (Date.now() - Number(s[3]) > FRESH_MS) { try { sessionStorage.removeItem(KEY); } catch (e) {} return; }
  chrome.runtime.sendMessage({ type: "rml-launch", op: s[1], port: Number(s[2]) }).catch(() => {});
})();

// Roblox Manager Auto-Join Helper  (v2)
// Only acts on pages opened by Roblox Manager (the link ends with #rml-autojoin).
// It starts the game once, then stops. Nothing else.
//
// How it works:
//  1. Runs before Roblox's own scripts (document_start, in the page). It removes
//     the #rml-autojoin marker right away, because Roblox's page otherwise moves
//     "?privateServerLinkCode=..." behind the # and the private server is lost.
//  2. Remembers "auto-join wanted" for this tab for 90 seconds (sessionStorage), so
//     it survives Roblox's own redirects (share link -> game page).
//  3. Starts the game with Roblox's own launcher (Roblox.GameLauncher):
//       game page       -> joinMultiplayerGame(placeId)
//       same server     -> joinGameInstance(placeId, jobId)   (rejoin: #rml-autojoin&job=...&place=...)
//       private server  -> joinPrivateGame(placeId, null, linkCode)
//       profile page    -> followPlayerIntoGame(userId)
//     If the launcher isn't there, it falls back to clicking Play / Join.

(function () {
  const MARK = "rml-autojoin";
  const KEY = "rml-autojoin";
  const FRESH_MS = 90000;    // the request expires after 90 seconds
  const GIVE_UP_MS = 30000;  // stop looking on a page after 30 seconds

  // ---- 1. take the marker out before Roblox sees it ----
  if (location.hash.includes(MARK)) {
    const job = location.hash.match(/[#&]job=([0-9a-f-]{36})/i);
    const place = location.hash.match(/[#&]place=(\d+)/);
    const op = location.hash.match(/[#&]op=([0-9a-f-]{36})/i);
    const port = location.hash.match(/[#&]port=(\d{2,5})/);
    try {
      sessionStorage.setItem(KEY, String(Date.now()));
      if (job) sessionStorage.setItem(KEY + "-job", job[1] + "@" + (place ? place[1] : ""));
      else sessionStorage.removeItem(KEY + "-job");
      // launch id for tab closing (tabclose.js picks it up, whichever script runs first)
      if (op && port) sessionStorage.setItem("rml-op", op[1] + "@" + port[1] + "@" + Date.now());
    } catch (e) {}
    history.replaceState(history.state, "", location.pathname + location.search);
  }

  let wanted = 0, jobAt = "";
  try { wanted = Number(sessionStorage.getItem(KEY)) || 0; jobAt = sessionStorage.getItem(KEY + "-job") || ""; } catch (e) {}
  if (!wanted || Date.now() - wanted > FRESH_MS) return;

  function done() { try { sessionStorage.removeItem(KEY); sessionStorage.removeItem(KEY + "-job"); } catch (e) {} }
  function record(what) { document.documentElement.setAttribute("data-rml-autojoin", what); }

  // ---- what page is this? ----
  const path = location.pathname.replace(/^\/[a-z]{2}(-[a-z]{2})?(?=\/)/i, ""); // drop a locale prefix like /de or /en-us
  const placeMatch = path.match(/^\/games\/(\d+)/);
  const userMatch = path.match(/^\/users\/(\d+)/);
  const codeMatch = location.href.match(/[?&#]privateServerLinkCode=([^&#]+)/i);
  const kind = placeMatch ? (codeMatch ? "private" : "game")
             : userMatch ? "profile"
             : /^\/share/i.test(path) ? "share" : "other";
  if (kind === "other") return;   // e.g. login page: keep the request for the next page

  // ---- notice if Roblox's own page starts a join (so we never launch twice) ----
  const JOIN_FNS = ["joinMultiplayerGame", "joinPrivateGame", "followPlayerIntoGame", "joinGameInstance", "playTogetherGame"];
  let ours = false, pageLaunched = false;
  const wrapTimer = setInterval(() => {
    const L = window.Roblox && window.Roblox.GameLauncher;
    if (!L || L.__rmlWrapped) return;
    try {
      for (const fn of JOIN_FNS) {
        const orig = L[fn];
        if (typeof orig !== "function") continue;
        L[fn] = function () { if (!ours) pageLaunched = true; return orig.apply(this, arguments); };
      }
      L.__rmlWrapped = true;
    } catch (e) {}
    clearInterval(wrapTimer);
  }, 25);
  setTimeout(() => clearInterval(wrapTimer), GIVE_UP_MS);

  // ---- small on-page note ----
  function note(msg, ok) {
    const show = () => {
      const box = document.createElement("div");
      box.textContent = msg;
      box.style.cssText =
        "position:fixed;top:16px;right:16px;z-index:2147483647;max-width:360px;padding:12px 16px;border-radius:10px;" +
        "font:600 14px Segoe UI,Arial,sans-serif;color:#fff;box-shadow:0 4px 16px rgba(0,0,0,.35);" +
        "background:" + (ok ? "#15803d" : "#c2410c");
      document.body.appendChild(box);
      setTimeout(() => box.remove(), 9000);
    };
    if (document.body) show(); else document.addEventListener("DOMContentLoaded", show);
  }

  // ---- 3a. launch through Roblox's own launcher ----
  function launchWithApi() {
    const L = window.Roblox && window.Roblox.GameLauncher;
    if (!L) return null;
    let fn, args;
    const [jobId, jobPlace] = jobAt.split("@");
    if (kind === "game" && jobId) { fn = "joinGameInstance"; args = [Number(jobPlace || placeMatch[1]), jobId]; }
    else if (kind === "game") { fn = "joinMultiplayerGame"; args = [Number(placeMatch[1])]; }
    else if (kind === "private") { fn = "joinPrivateGame"; args = [Number(placeMatch[1]), null, decodeURIComponent(codeMatch[1])]; }
    else if (kind === "profile") { fn = "followPlayerIntoGame"; args = [Number(userMatch[1])]; }
    else return null;
    if (typeof L[fn] !== "function") return null;
    ours = true;
    try { L[fn].apply(L, args); } catch (e) { ours = false; return null; }
    ours = false;
    record(fn + "(" + args.map((a) => (a === null ? "null" : a)).join(",") + ")");
    return fn;
  }

  // ---- 3b. fallback: find and click the button ----
  function visible(el) {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 0 && r.height > 0 && s.visibility !== "hidden" && s.display !== "none" && !el.disabled;
  }
  function textOf(el) {
    return (el.innerText || el.textContent || el.getAttribute("aria-label") || el.getAttribute("title") || "").trim().toLowerCase();
  }
  function findByWords(words) {
    for (const el of document.querySelectorAll('button, [role="button"], a.btn-primary-md, a.btn-common-play-game-lg')) {
      if (visible(el) && words.includes(textOf(el))) return el;
    }
    return null;
  }
  function findPlayButton() {
    const selectors = [
      'button[data-testid="play-button"]',
      '#game-details-play-button-container button',
      '.btn-common-play-game-lg',
      'button[aria-label="Play"]'
    ];
    for (const sel of selectors) {
      const el = document.querySelector(sel);
      if (el && visible(el)) return el;
    }
    return findByWords(["play"]);
  }
  function clickFallback() {
    const join = ["join", "join game", "join experience", "join server"];
    // On a game page Play comes first: a "Join" there could be a friend's or another private server.
    const target = kind === "profile" || kind === "share" ? findByWords(join) : (findPlayButton() || findByWords(join));
    if (!target) return null;
    target.click();
    record("click:" + (textOf(target) || "play"));
    return textOf(target) || "Play";
  }

  // ---- main loop ----
  const started = Date.now();
  // A private-server page may start the join on its own; give it a moment first.
  const waitFirst = kind === "private" ? 3000 : 0;
  const timer = setInterval(() => {
    const t = Date.now() - started;
    if (pageLaunched) {
      clearInterval(timer); done(); record("page-started-join");
      note("Auto-join: Roblox is starting the game.", true);
      return;
    }
    if (document.readyState === "loading" || t < waitFirst) return;

    if (kind !== "share") {
      const fn = launchWithApi();
      if (fn) {
        clearInterval(timer); done();
        note(kind === "profile" ? "Auto-join: joining your main's server..." :
             kind === "private" ? "Auto-join: joining the private server..." :
             fn === "joinGameInstance" ? "Auto-join: rejoining the same server..." : "Auto-join: starting the game...", true);
        return;
      }
    }
    // The launcher normally shows up within a few seconds; after that, try the button.
    if (t > 6000 || kind === "share") {
      const clicked = clickFallback();
      if (clicked) {
        clearInterval(timer); done();
        note("Auto-join: clicked \"" + clicked + "\" for you.", true);
        return;
      }
    }
    if (t > GIVE_UP_MS) {
      clearInterval(timer);
      if (kind !== "share") done();   // a share page may still send us on to the game page
      note(kind === "profile"
        ? "Auto-join couldn't join. Is your main in a game, and can friends join it? You can click Join yourself."
        : "Auto-join couldn't find the Play button. Please click it yourself.", false);
    }
  }, 400);
})();

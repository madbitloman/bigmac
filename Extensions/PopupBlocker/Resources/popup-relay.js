// BigMac Pop-up Blocker: connects the pop-up guard (popup-guard.js, in the page's MAIN world)
// to the extension, and shows a small notice when it blocks something.
// Runs in Safari's isolated world after popup-guard-rules.js, a copy of popup-guard.js that
// make-app.sh adds under another name and that publishes globalThis.PopupGuard here.
//   - Hands the guard BigMac's settings over the private page channel.
//   - Passes "blocked" notices to the background script (which counts them for BigMac).
//   - In the top frame, shows "Pop-up blocked — Allow once". Always allowing a site is in the
//     toolbar button (toolbar.html), which the page cannot reach.
(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  const Guard = globalThis.PopupGuard;
  if (!Guard || !api?.runtime?.sendMessage) return;

  const channel = Guard.connect(window, onNotice, false);

  function loadSettings() {
    api.runtime.sendMessage({ type: "popup-guard-config" }).then((config) => {
      if (config) channel.send({ type: "config", enabled: config.enabled, strict: config.strict });
    }).catch(() => {});
  }
  loadSettings();

  // A page can fake notices (it cannot fake its way past the guard), so keep them few.
  let sent = 0;
  const recent = new Map();
  function onNotice(message) {
    if (message?.type !== "blocked" || typeof message.reason !== "string" || sent >= 30) return;
    const url = typeof message.url === "string" ? message.url.slice(0, 2048) : "";
    const key = `${message.reason} ${url}`;
    const now = Date.now();
    if (now - (recent.get(key) ?? 0) < 1000) return;
    recent.set(key, now);
    sent += 1;
    api.runtime.sendMessage({ type: "popup-blocked", reason: message.reason.slice(0, 40), url }).catch(() => {});
  }

  api.runtime.onMessage.addListener((message) => {
    if (message?.type === "popup-guard-reload") loadSettings();
    if (message?.type === "popup-toast" && window === window.top && Date.now() >= quietUntil) showToast(message);
    return false;
  });

  // ---------------------------------------------------------------- the notice

  let toast = null;
  let hideTimer = 0;
  // The notice sits in the page, so a click on its buttons also reaches the page's own click
  // handlers; on a click-anywhere site that is one more blocked attempt. Don't show that one.
  let quietUntil = 0;
  const settle = () => {
    quietUntil = Date.now() + 2000;
  };

  const STYLE = `
    :host { all: initial; }
    .toast {
      position: fixed; right: 16px; bottom: 16px; z-index: 2147483647;
      display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px;
      max-width: min(420px, calc(100vw - 32px)); box-sizing: border-box;
      padding: 10px 12px; border-radius: 12px;
      background: rgb(28 28 30 / 0.94); color: #fff;
      font: 13px/1.35 -apple-system, system-ui, sans-serif;
      box-shadow: 0 6px 24px rgb(0 0 0 / 0.3);
      -webkit-backdrop-filter: blur(12px); backdrop-filter: blur(12px);
    }
    .text { flex: 1 1 160px; min-width: 0; }
    .title { font-weight: 600; }
    .detail { color: rgb(255 255 255 / 0.7); overflow-wrap: anywhere; }
    button {
      font: inherit; font-weight: 600; color: #fff; cursor: pointer;
      padding: 5px 9px; border-radius: 8px; border: 1px solid rgb(255 255 255 / 0.2);
      background: rgb(255 255 255 / 0.12);
    }
    button:hover { background: rgb(255 255 255 / 0.2); }
    button:focus-visible { outline: 2px solid #0a84ff; outline-offset: 2px; }
    .close { border: 0; background: none; padding: 2px 6px; font-size: 16px; line-height: 1; color: rgb(255 255 255 / 0.7); }
    @media (prefers-color-scheme: light) {
      .toast { background: rgb(255 255 255 / 0.96); color: #1d1d1f; box-shadow: 0 6px 24px rgb(0 0 0 / 0.18); }
      .detail, .close { color: rgb(0 0 0 / 0.6); }
      button { color: #1d1d1f; border-color: rgb(0 0 0 / 0.15); background: rgb(0 0 0 / 0.05); }
      button:hover { background: rgb(0 0 0 / 0.1); }
    }
  `;

  function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text) node.textContent = text;
    return node;
  }

  function hide() {
    clearTimeout(hideTimer);
    toast?.remove();
    toast = null;
  }

  function showToast({ url }) {
    hide();
    let where = "";
    try {
      where = url ? new URL(url).hostname : "";
    } catch {
      where = "";
    }
    const opensSomewhere = /^https?:/i.test(url ?? "");

    const host = element("div");
    host.style.setProperty("all", "initial", "important");
    host.style.setProperty("position", "fixed", "important");
    host.style.setProperty("z-index", "2147483647", "important");
    const shadow = host.attachShadow({ mode: "closed" });
    // A constructed stylesheet, which a page's Content Security Policy does not block.
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(STYLE);
    shadow.adoptedStyleSheets = [sheet];

    const box = element("div", "toast");
    box.setAttribute("role", "status");
    const text = element("div", "text");
    text.append(element("div", "title", "Pop-up blocked"), element("div", "detail", where ? `To ${where}` : "A new window from this page"),
      element("div", "detail", "More in the toolbar button"));
    box.append(text);
    if (opensSomewhere) {
      const once = element("button", "", "Allow once");
      once.addEventListener("click", () => {
        settle();
        window.open(url, "_blank", "noopener");
        hide();
      });
      box.append(once);
    }
    const close = element("button", "close", "×");
    close.setAttribute("aria-label", "Dismiss");
    close.addEventListener("click", hide);
    box.append(close);
    shadow.append(box);

    box.addEventListener("mouseenter", () => clearTimeout(hideTimer));
    box.addEventListener("mouseleave", () => {
      hideTimer = setTimeout(hide, 4000);
    });
    (document.body ?? document.documentElement).append(host);
    toast = host;
    hideTimer = setTimeout(hide, 10000);
  }
})();

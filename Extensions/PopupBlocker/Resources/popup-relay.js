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
  // The notice's host element lives in the page, so the page can restyle, move or cover it. The
  // notice therefore offers only Allow once, which opens the one blocked window, and takes a click
  // only when it is real (isTrusted), the notice has been on screen as the relay placed it for at
  // least MIN_VISIBLE_MS, nothing has faded or moved it, and the click point hits the notice itself.
  // Anything that touches the host restores it and restarts that clock.
  // Keyboard: Enter or Space on the focused button counts too (a page can't move focus into the
  // closed shadow root); the point checked is then the button's centre.

  const MIN_VISIBLE_MS = 500;
  const MAX_RESTORES = 20;
  const MARGIN = 16;
  const HOST_CSS = [
    "all: initial", "position: fixed", "right: 16px", "bottom: 16px", "top: auto", "left: auto",
    "display: block", "width: max-content", "max-width: min(420px, calc(100vw - 32px))", "height: auto",
    "margin: 0", "padding: 0", "border: 0", "z-index: 2147483647", "opacity: 1", "visibility: visible",
    "transform: none", "filter: none", "clip-path: none", "pointer-events: auto", "overflow: visible",
  ].map((rule) => `${rule} !important`).join("; ");
  const canPopover = typeof HTMLElement.prototype.showPopover === "function";

  let notice = null;
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
      display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px;
      box-sizing: border-box; width: 100%;
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
    if (!notice) return;
    const { host, observer, listeners } = notice;
    notice = null;
    observer.disconnect();
    for (const [target, type, listener] of listeners) target.removeEventListener(type, listener, true);
    host.remove();
  }

  // ------------------------------------------------ keeping the host where the relay put it

  function raise(host) {
    if (!canPopover || !host.isConnected) return;
    try {
      if (host.matches(":popover-open")) host.hidePopover();
      host.showPopover();
    } catch {
      // Not in the document, or the page swapped the attribute; the next restore tries again.
    }
  }

  function place() {
    const { host, observer } = notice;
    for (const name of host.getAttributeNames()) {
      if (name !== "style" && name !== "popover") host.removeAttribute(name);
    }
    host.style.cssText = HOST_CSS;
    if (canPopover && host.getAttribute("popover") !== "manual") host.setAttribute("popover", "manual");
    const root = document.documentElement;
    if (root && host.parentNode !== root) root.append(host);
    raise(host);
    notice.css = host.style.cssText;
    notice.shownAt = Infinity;
    // Our own changes are not the page's.
    observer.takeRecords();
    requestAnimationFrame(() => requestAnimationFrame(() => {
      if (!notice || notice.host !== host) return;
      notice.rect = host.getBoundingClientRect();
      notice.shownAt = performance.now();
    }));
  }

  function tampered() {
    const { host } = notice;
    if (!host.isConnected || host.parentNode !== document.documentElement) return true;
    if (host.style.cssText !== notice.css) return true;
    if (host.getAttributeNames().some((name) => name !== "style" && name !== "popover")) return true;
    return canPopover && (host.getAttribute("popover") !== "manual" || !host.matches(":popover-open"));
  }

  function restore() {
    if (!notice) return;
    notice.restores += 1;
    if (notice.restores > MAX_RESTORES) {
      hide();
      return;
    }
    place();
  }

  // ------------------------------------------------ the click

  function near(a, b) {
    return Math.abs(a - b) <= 1;
  }

  function looksAsPlaced() {
    const { host, rect: placed } = notice;
    if (!placed || tampered()) return false;
    const rect = host.getBoundingClientRect();
    if (!near(rect.left, placed.left) || !near(rect.top, placed.top) || !near(rect.width, placed.width) || !near(rect.height, placed.height)) {
      return false;
    }
    // Bottom-right corner, fully on screen.
    const width = window.innerWidth;
    const height = window.innerHeight;
    if (rect.left < 0 || rect.top < 0 || rect.right > width || rect.bottom > height) return false;
    if (rect.right < width - MARGIN - 40 || rect.bottom < height - MARGIN - 40) return false;
    for (let node = host; node; node = node.parentElement) {
      const style = getComputedStyle(node);
      if (style.opacity !== "1" || style.visibility !== "visible" || style.display === "none") return false;
      if (style.filter !== "none" || style.clipPath !== "none") return false;
      const mask = style.maskImage ?? style.webkitMaskImage;
      if (mask && mask !== "none") return false;
      if (node !== host && style.transform !== "none") return false;
    }
    return true;
  }

  function trustedClick(event, button, shadow) {
    if (!notice || !event.isTrusted) return false;
    if (document.visibilityState !== "visible") return false;
    if (performance.now() - notice.shownAt < MIN_VISIBLE_MS) return false;
    if (!looksAsPlaced()) return false;
    const box = button.getBoundingClientRect();
    let x = event.clientX;
    let y = event.clientY;
    if (event.detail === 0 && x === 0 && y === 0) {
      if (shadow.activeElement !== button) return false;
      x = box.left + box.width / 2;
      y = box.top + box.height / 2;
    }
    if (x < box.left || x > box.right || y < box.top || y > box.bottom) return false;
    return document.elementFromPoint(x, y) === notice.host;
  }

  // ------------------------------------------------ showing it

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
      once.addEventListener("click", (event) => {
        if (!trustedClick(event, once, shadow)) return;
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
      clearTimeout(hideTimer);
      hideTimer = setTimeout(hide, 4000);
    });

    const observer = new MutationObserver(() => {
      if (notice?.host === host && tampered()) restore();
    });
    // Another element entering the top layer (a popover, a dialog, full screen) could sit over the
    // notice: put the notice back on top and restart the clock.
    const onTopLayer = (event) => {
      if (!notice || event.target === host) {
        if (notice && tampered()) restore();
        return;
      }
      if (event.type !== "toggle" || event.newState === "open") place();
    };
    const onResize = () => notice && place();
    const listeners = [
      [window, "toggle", onTopLayer],
      [document, "fullscreenchange", onTopLayer],
      [document, "webkitfullscreenchange", onTopLayer],
      [window, "resize", onResize],
      [document, "visibilitychange", onResize],
    ];
    for (const [target, type, listener] of listeners) target.addEventListener(type, listener, true);

    notice = { host, observer, listeners, css: "", rect: null, shownAt: Infinity, restores: 0 };
    place();
    observer.observe(document, { childList: true, subtree: true });
    observer.observe(host, { attributes: true });
    hideTimer = setTimeout(hide, 10000);
  }
})();

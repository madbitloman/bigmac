// Stand-ins for Safari's extension APIs and the guard, so popup-relay.js runs in a plain page.
// Test-only: shadow roots open, so the test can find the notice's buttons.
(() => {
  const attach = Element.prototype.attachShadow;
  window.__hosts = [];
  Element.prototype.attachShadow = function (init) {
    window.__hosts.push(this);
    return attach.call(this, { ...init, mode: "open" });
  };
  window.__opened = [];
  window.open = (...args) => {
    window.__opened.push(args);
    return null;
  };
  window.__sent = [];
  globalThis.PopupGuard = { connect: () => ({ send() {} }) };
  globalThis.browser = {
    runtime: {
      sendMessage: async (message) => {
        window.__sent.push(message);
        return message?.type === "popup-guard-config" ? { enabled: true, strict: false } : undefined;
      },
      onMessage: { addListener: (listener) => { window.__listener = listener; } },
    },
  };
  window.__show = (url = "http://ads.example/landing") => window.__listener({ type: "popup-toast", url });
  window.__host = () => window.__hosts.at(-1);
  window.__button = (label) => [...window.__host().shadowRoot.querySelectorAll("button")].find((b) => b.textContent === label);
  window.__rect = (el) => {
    const r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2, left: r.left, top: r.top, width: r.width, height: r.height };
  };
})();

// BigMac Pop-up Blocker, background: BigMac's settings for the page guards, and what to do
// when one blocks something. Settings come from the app through the native handler
// (SafariWebExtensionHandler.swift), which reads them from BigMac's shared app group.
const api = globalThis.browser ?? globalThis.chrome;
const SETTINGS_MS = 5000;
let cached = null; // { time, value }

async function settings(fresh = false) {
  if (!fresh && cached && Date.now() - cached.time < SETTINGS_MS) return cached.value;
  let value;
  try {
    value = await api.runtime.sendNativeMessage("com.bigmac.app", { type: "settings" });
  } catch {
    value = null;
  }
  value ??= { popups: true, strict: false, allowed: [] };
  cached = { time: Date.now(), value };
  return value;
}

function siteOf(url) {
  try {
    const { protocol, hostname } = new URL(url);
    if (protocol !== "http:" && protocol !== "https:") return null;
    return hostname.toLowerCase().replace(/^www\./, "");
  } catch {
    return null;
  }
}

function allowed(value, site) {
  return !!site && (value.allowed ?? []).some((domain) => site === domain || site.endsWith("." + domain));
}

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const pageUrl = sender.tab?.url ?? sender.url ?? "";
  switch (message?.type) {
    case "popup-guard-config":
      settings().then((value) => {
        const enabled = value.popups !== false && !allowed(value, siteOf(pageUrl));
        sendResponse({ enabled, strict: enabled && value.strict === true });
      }, () => sendResponse(null));
      return true;
    case "popup-blocked":
      if (!sender.tab || typeof message.url !== "string") return false;
      api.runtime.sendNativeMessage("com.bigmac.app", { type: "blocked" }).catch(() => {});
      // Only the top frame shows the notice, so a blocked pop-up inside an ad frame still surfaces.
      api.tabs.sendMessage(sender.tab.id, { type: "popup-toast", url: message.url, reason: message.reason, site: siteOf(pageUrl) },
        { frameId: 0 }).catch(() => {});
      return false;
    case "popup-allow-site": {
      const site = siteOf(pageUrl);
      if (!site || !sender.tab) return false;
      api.runtime.sendNativeMessage("com.bigmac.app", { type: "allow", site }).then(() => settings(true)).then(() => {
        // Every frame of the tab re-reads its settings, so the guard steps aside without a reload.
        api.tabs.sendMessage(sender.tab.id, { type: "popup-guard-reload" }).catch(() => {});
        sendResponse(true);
      }, () => sendResponse(false));
      return true;
    }
    default:
      return false;
  }
});

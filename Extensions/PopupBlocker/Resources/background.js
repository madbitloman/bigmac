// BigMac Pop-up Blocker, background: BigMac's settings for the page guards, what to do when one
// blocks something, and the toolbar button's page (toolbar.html). Settings come from the app
// through the native handler (SafariWebExtensionHandler.swift), which reads and writes them in
// BigMac's shared app group.
const api = globalThis.browser ?? globalThis.chrome;
const SETTINGS_MS = 5000;
let cached = null; // { time, value }

function native(message) {
  return api.runtime.sendNativeMessage("com.bigmac.app", message);
}

async function settings(fresh = false) {
  if (!fresh && cached && Date.now() - cached.time < SETTINGS_MS) return cached.value;
  let value;
  try {
    value = await native({ type: "settings" });
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

// The allowed-list entry that covers a site (the most specific one), or null.
function allowedEntry(value, site) {
  if (!site) return null;
  const matches = (value.allowed ?? []).filter((domain) => site === domain || site.endsWith("." + domain));
  return matches.sort((a, b) => b.length - a.length)[0] ?? null;
}

// BigMac's allowed sites take domain names only (DomainNormalizer.swift has the final say).
function listable(site) {
  if (!site || site.length > 253 || !/^[a-z0-9.-]+$/.test(site)) return false;
  const labels = site.split(".");
  return labels.length >= 2 && labels.every((label) => label.length > 0 && label.length <= 63) && /[a-z]/.test(labels.at(-1));
}

// ------------------------------------------------------------ blocked pop-ups per tab
// The background unloads when idle, so the counts live in session storage where Safari has it.
const session = api.storage?.session ?? null;
const memory = new Map();

async function readCount(tabId) {
  const key = `tab:${tabId}`;
  if (!session) return memory.get(key) ?? null;
  try {
    return (await session.get(key))[key] ?? null;
  } catch {
    return memory.get(key) ?? null;
  }
}

async function writeCount(tabId, entry) {
  const key = `tab:${tabId}`;
  memory.set(key, entry);
  if (session) await session.set({ [key]: entry }).catch(() => {});
}

async function countBlocked(tabId, site) {
  const entry = await readCount(tabId);
  const count = entry && entry.site === site ? entry.count + 1 : 1;
  await writeCount(tabId, { site, count });
}

api.tabs.onRemoved?.addListener((tabId) => {
  const key = `tab:${tabId}`;
  memory.delete(key);
  session?.remove(key).catch(() => {});
});

// ------------------------------------------------------------ the toolbar button's page

// Only the extension's own page may change the allowed list. Content scripts always come with a tab.
function fromToolbar(sender) {
  if (sender.tab || sender.id !== api.runtime.id) return false;
  return !sender.url || sender.url.startsWith(api.runtime.getURL("toolbar.html"));
}

async function toolbarState(tabId) {
  const tab = await api.tabs.get(tabId);
  const site = siteOf(tab?.url ?? "");
  const value = await settings(true);
  const entry = await readCount(tabId);
  const via = allowedEntry(value, site);
  return {
    site,
    blocked: entry && entry.site === site ? entry.count : 0,
    allowed: !!via,
    via,
    listable: listable(site),
    popups: value.popups !== false,
    linked: value.linked === true,
  };
}

async function setAllowed(tabId, allow) {
  // The site always comes from the tab itself, never from the message.
  const before = await toolbarState(tabId);
  if (allow && !before.allowed && before.listable) await native({ type: "allow", site: before.site });
  if (!allow && before.via) await native({ type: "disallow", site: before.via });
  const after = await toolbarState(tabId);
  if (after.allowed !== before.allowed) {
    // The guard takes only one loosening setting per page, so allowing a site needs a reload.
    // Removing one only tightens, so every frame re-reads its settings in place.
    if (after.allowed) api.tabs.reload(tabId).catch(() => {});
    else api.tabs.sendMessage(tabId, { type: "popup-guard-reload" }).catch(() => {});
  }
  return { ...after, changed: after.allowed === allow };
}

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  const pageUrl = sender.tab?.url ?? sender.url ?? "";
  switch (message?.type) {
    case "popup-guard-config":
      settings().then((value) => {
        const enabled = value.popups !== false && !allowedEntry(value, siteOf(pageUrl));
        sendResponse({ enabled, strict: enabled && value.strict === true });
      }, () => sendResponse(null));
      return true;
    case "popup-blocked": {
      if (!sender.tab || typeof message.url !== "string") return false;
      const site = siteOf(pageUrl);
      native({ type: "blocked" }).catch(() => {});
      countBlocked(sender.tab.id, site).catch(() => {});
      // Only the top frame shows the notice, so a blocked pop-up inside an ad frame still surfaces.
      api.tabs.sendMessage(sender.tab.id, { type: "popup-toast", url: message.url, reason: message.reason },
        { frameId: 0 }).catch(() => {});
      return false;
    }
    case "toolbar-state":
    case "toolbar-allow": {
      if (!fromToolbar(sender) || !Number.isInteger(message.tabId)) return false;
      const work = message.type === "toolbar-state" ? toolbarState(message.tabId) : setAllowed(message.tabId, message.allow === true);
      work.then(sendResponse, () => sendResponse(null));
      return true;
    }
    default:
      return false;
  }
});

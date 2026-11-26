// Tests the pop-up blocker's background script (Extensions/PopupBlocker/Resources/background.js)
// in Node with stand-ins for Safari's extension APIs and the native handler. No browser, no network.
//   node Tests/PopupGuard/relay/background.test.mjs
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "../../../Extensions/PopupBlocker/Resources/background.js"), "utf8");
const EXT = "safari-web-extension://abc/";

function load({ allowed = [], tabs = {} } = {}) {
  const native = [];
  const tabMessages = [];
  const reloads = [];
  let listener = null;
  const store = { popups: true, strict: false, allowed: [...allowed], linked: true };
  const browser = {
    runtime: {
      id: "bigmac",
      getURL: (path) => EXT + path,
      sendNativeMessage: async (_app, message) => {
        native.push(message);
        // The real checks live in Swift; this stand-in only applies them in their simplest form.
        if (message.type === "allow" && !store.allowed.includes(message.site)) store.allowed.push(message.site);
        if (message.type === "disallow") store.allowed = store.allowed.filter((d) => d !== message.site);
        return { ...store, allowed: [...store.allowed] };
      },
      onMessage: { addListener: (fn) => { listener = fn; } },
    },
    tabs: {
      get: async (id) => tabs[id] ?? { id },
      sendMessage: async (id, message) => { tabMessages.push({ id, message }); },
      reload: async (id) => { reloads.push(id); },
      onRemoved: { addListener() {} },
    },
  };
  vm.runInNewContext(source, { browser, URL, Date, Promise, console });
  const send = (message, sender) => new Promise((resolve) => {
    const async = listener(message, sender, resolve);
    if (!async) resolve(undefined);
  });
  return { send, native, tabMessages, reloads, store };
}

const toolbar = { id: "bigmac", url: EXT + "toolbar.html" };
const contentScript = (url, id = 7) => ({ id: "bigmac", url, tab: { id, url }, frameId: 0 });
let failures = 0;
const results = [];
async function test(name, body) {
  try {
    await body();
    results.push(`  ✓ ${name}`);
  } catch (error) {
    failures += 1;
    results.push(`  ✗ ${name}\n      ${error.message}`);
  }
}
function expect(ok, message) {
  if (!ok) throw new Error(message);
}

await test("a content script can't change the allowed list, with or without a site", async () => {
  const bg = load({ tabs: { 7: { id: 7, url: "https://news.example.com/a" } } });
  for (const message of [{ type: "toolbar-allow", tabId: 7, allow: true }, { type: "popup-allow-site" },
    { type: "toolbar-allow", tabId: 7, allow: true, site: "evil.example" }]) {
    expect((await bg.send(message, contentScript("https://news.example.com/a"))) === undefined, `answered ${JSON.stringify(message)}`);
  }
  expect(!bg.native.some((m) => m.type === "allow" || m.type === "disallow"), `native got ${JSON.stringify(bg.native)}`);
});

await test("another extension page can't either", async () => {
  const bg = load({ tabs: { 7: { id: 7, url: "https://example.com/" } } });
  await bg.send({ type: "toolbar-allow", tabId: 7, allow: true }, { id: "bigmac", url: EXT + "other.html" });
  await bg.send({ type: "toolbar-allow", tabId: 7, allow: true }, { id: "someone-else", url: "safari-web-extension://x/toolbar.html" });
  expect(!bg.native.some((m) => m.type === "allow"), `native got ${JSON.stringify(bg.native)}`);
});

await test("the toolbar page allows the tab's own site, whatever the message says", async () => {
  const bg = load({ tabs: { 7: { id: 7, url: "https://www.Example.com/page?x=1" } } });
  const state = await bg.send({ type: "toolbar-allow", tabId: 7, allow: true, site: "evil.example" }, toolbar);
  const allows = bg.native.filter((m) => m.type === "allow");
  expect(allows.length === 1 && allows[0].site === "example.com", `native got ${JSON.stringify(allows)}`);
  expect(state.allowed && state.changed && state.site === "example.com", `state ${JSON.stringify(state)}`);
  expect(bg.reloads.includes(7), "the tab was not reloaded, so the guard would keep blocking until the next visit");
});

await test("switching off removes the entry that covers the site", async () => {
  const bg = load({ allowed: ["example.com"], tabs: { 7: { id: 7, url: "https://news.example.com/" } } });
  const before = await bg.send({ type: "toolbar-state", tabId: 7 }, toolbar);
  expect(before.allowed && before.via === "example.com", `state ${JSON.stringify(before)}`);
  const after = await bg.send({ type: "toolbar-allow", tabId: 7, allow: false }, toolbar);
  expect(bg.native.some((m) => m.type === "disallow" && m.site === "example.com"), `native got ${JSON.stringify(bg.native)}`);
  expect(!after.allowed && after.changed, `state ${JSON.stringify(after)}`);
  expect(bg.tabMessages.some((t) => t.id === 7 && t.message.type === "popup-guard-reload") && !bg.reloads.length,
    "switching off should re-read settings in place, without a reload");
});

await test("an address or a non-web page is never sent to be allowed", async () => {
  const bg = load({ tabs: { 7: { id: 7, url: "http://127.0.0.1:8000/x" }, 8: { id: 8, url: "about:blank" }, 9: { id: 9 } } });
  for (const tabId of [7, 8, 9]) {
    const state = await bg.send({ type: "toolbar-allow", tabId, allow: true }, toolbar);
    expect(!state.allowed && !state.changed, `tab ${tabId}: ${JSON.stringify(state)}`);
  }
  const s7 = await bg.send({ type: "toolbar-state", tabId: 7 }, toolbar);
  expect(s7.site === "127.0.0.1" && !s7.listable, `state ${JSON.stringify(s7)}`);
  expect(!bg.native.some((m) => m.type === "allow"), `native got ${JSON.stringify(bg.native)}`);
});

await test("blocked pop-ups are counted per tab and start again on another site", async () => {
  const bg = load({ tabs: { 7: { id: 7, url: "https://a.example/" } } });
  for (let i = 0; i < 3; i += 1) await bg.send({ type: "popup-blocked", url: "https://ad.example/", reason: "x" }, contentScript("https://a.example/"));
  await new Promise((resolve) => setTimeout(resolve, 10));
  expect((await bg.send({ type: "toolbar-state", tabId: 7 }, toolbar)).blocked === 3, "count is not 3");
  await bg.send({ type: "popup-blocked", url: "https://ad.example/", reason: "x" }, contentScript("https://b.example/"));
  await new Promise((resolve) => setTimeout(resolve, 10));
  const toasts = bg.tabMessages.filter((t) => t.message.type === "popup-toast");
  expect(toasts.length === 4 && toasts.every((t) => !("site" in t.message)), "the notice message should carry no site");
  const s = await bg.send({ type: "toolbar-state", tabId: 7 }, toolbar);
  expect(s.blocked === 0, `count for a.example after the tab moved on: ${s.blocked}`);
});

console.log("Background (Node)");
console.log(results.join("\n"));
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);

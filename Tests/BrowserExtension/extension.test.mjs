// Loads the Chrome and Firefox extension exactly as BigMac.app ships it (Contents/Resources/BrowserExtension)
// into Playwright Chromium, in a throwaway profile, and checks that it blocks. Every host name resolves to a
// local server here, so nothing leaves this machine and a request the extension lets through lands on it.
//   SIGN_IDENTITY="-" ./make-app.sh
//   NODE_PATH=/path/to/node_modules node Tests/BrowserExtension/extension.test.mjs [path/to/BrowserExtension]
// Needs playwright-core and its Chromium (npx playwright-core install chromium).
import { createRequire } from "node:module";
import { createServer } from "node:http";
import { cpSync, existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright-core");
const here = dirname(fileURLToPath(import.meta.url));
const extension = resolve(process.argv[2] ?? join(here, "../../build/BigMac.app/Contents/Resources/BrowserExtension"));
if (!existsSync(join(extension, "manifest.json"))) {
  console.error(`No extension at ${extension}. Build BigMac.app first (make-app.sh).`);
  process.exit(2);
}

// ------------------------------------------------------------ the local "internet"
const hits = []; // "host/path" of every request that reached the server
const pages = {
  "/net.html": `<!doctype html><title>net</title>
    <img id="ad" src="/ad.gif?host=doubleclick" data-host="doubleclick.net">
    <img id="ok" src="/ok.gif" data-host="cdn.example">
    <script>
      // Absolute URLs on the same port, built here so the page needn't know it.
      for (const img of document.images) img.src = "http://" + img.dataset.host + ":" + location.port + "/" + img.id + ".gif";
    </script>`,
  "/popup-network.html": `<!doctype html><title>popup network</title>
    <button id="go" style="width:300px;height:100px">Next</button>
    <script>document.getElementById("go").onclick = () => window.open("http://popads.net:" + location.port + "/landing");</script>`,
  "/timeout.html": `<!doctype html><title>timeout</title><p>Opens a tab one second after loading, with no click.</p>
    <script>setTimeout(() => window.open("http://ads.example:" + location.port + "/timeout-ad"), 1000);</script>`,
  "/link.html": `<!doctype html><title>link</title>
    <a id="go" href="/help" target="_blank" style="display:block;width:300px;height:100px">Help</a>
    <script>document.getElementById("go").href = "http://help.example:" + location.port + "/help";</script>`,
};
const server = createServer((req, res) => {
  hits.push(`${(req.headers.host ?? "").split(":")[0]}${req.url}`);
  const body = pages[req.url.split("?")[0]];
  if (body) {
    res.writeHead(200, { "content-type": "text/html" });
    res.end(body);
  } else if (req.url.endsWith(".gif")) {
    res.writeHead(200, { "content-type": "image/gif" });
    res.end(Buffer.from("R0lGODlhAQABAAAAACw=", "base64"));
  } else {
    res.writeHead(200, { "content-type": "text/html" });
    res.end("<!doctype html><title>landing</title>landing");
  }
});
await new Promise((ready) => server.listen(0, "127.0.0.1", ready));
const port = server.address().port;
const site = (path, host = "site.example") => `http://${host}:${port}${path}`;
const hit = (host, path) => hits.some((h) => h === `${host}${path}` || h.startsWith(`${host}${path}?`));

// ------------------------------------------------------------ the browser
const profile = mkdtempSync(join(tmpdir(), "bigmac-ext-"));
// Chrome writes its indexed rules (_metadata) into the folder it loads, so it gets a copy, never the app bundle.
const loaded = join(profile, "BrowserExtension");
cpSync(extension, loaded, { recursive: true });
const context = await chromium.launchPersistentContext(profile, {
  channel: "chromium", // the full build: the headless shell can't load extensions
  headless: true,
  args: [
    `--disable-extensions-except=${loaded}`,
    `--load-extension=${loaded}`,
    "--host-resolver-rules=MAP * 127.0.0.1",
  ],
});
let worker = context.serviceWorkers()[0] ?? (await context.waitForEvent("serviceworker", { timeout: 15_000 }));
// The rulesets and stylesheets are applied in onInstalled; give it a moment, then check it took.
await new Promise((r) => setTimeout(r, 1500));
const enabled = await worker.evaluate(() => chrome.declarativeNetRequest?.getEnabledRulesets() ?? []);

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
const others = (keep) => context.pages().filter((p) => p !== keep && !p.isClosed());

await test(`the extension loads (${worker.url().split("/")[2]}) with its rulesets on: ${enabled.join(", ")}`, async () => {
  for (const id of ["ads", "easylist", "trackers", "easyprivacy", "popups"]) expect(enabled.includes(id), `ruleset ${id} is off`);
});

await test("an ad server request is blocked by the extension; an ordinary one loads", async () => {
  const page = await context.newPage();
  const failed = [];
  page.on("requestfailed", (r) => failed.push(`${new URL(r.url()).hostname} ${r.failure()?.errorText}`));
  await page.goto(site("/net.html"));
  await page.waitForTimeout(1000);
  expect(failed.some((f) => f.startsWith("doubleclick.net") && f.includes("ERR_BLOCKED_BY_CLIENT")), `doubleclick.net not blocked: ${failed}`);
  expect(!hit("doubleclick.net", "/ad.gif"), "doubleclick.net reached the server");
  expect(hit("cdn.example", "/ok.gif"), "the ordinary image didn't load");
  await page.close();
});

await test("a pop-up to a pop-up network never loads, and its tab is gone", async () => {
  const page = await context.newPage();
  await page.goto(site("/popup-network.html"));
  await page.waitForTimeout(500);
  await page.click("#go");
  await page.waitForTimeout(2500);
  expect(!hit("popads.net", "/landing"), "popads.net reached the server");
  const left = others(page).filter((p) => p.url().includes("popads.net"));
  expect(left.length === 0, `a popads.net tab is still open: ${left.map((p) => p.url())}`);
  await page.close();
});

await test("the pop-up guard stops a tab a page opens with no click", async () => {
  const page = await context.newPage();
  const before = others(page).length;
  await page.goto(site("/timeout.html"));
  await page.waitForTimeout(3000);
  expect(!hit("ads.example", "/timeout-ad"), "the unclicked pop-up reached the server");
  expect(others(page).length === before, `a new tab stayed open: ${others(page).map((p) => p.url())}`);
  await page.close();
});

await test("a link the user clicks still opens its new tab", async () => {
  const page = await context.newPage();
  await page.goto(site("/link.html"));
  await page.waitForTimeout(800); // let the guard settle
  const opened = context.waitForEvent("page", { timeout: 5000 });
  await page.click("#go");
  const tab = await opened;
  await tab.waitForLoadState().catch(() => {});
  await page.waitForTimeout(500);
  expect(hit("help.example", "/help"), "the clicked link's page never loaded");
  await tab.close().catch(() => {});
  await page.close();
});

await context.close();
server.close();
rmSync(profile, { recursive: true, force: true });
console.log(`Browser extension (${extension})`);
console.log(results.join("\n"));
console.log(failures === 0 ? "All passed" : `${failures} failed`);
process.exit(failures === 0 ? 0 : 1);

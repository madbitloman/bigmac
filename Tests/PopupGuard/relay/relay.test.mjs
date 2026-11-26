// Tests the pop-up blocker's in-page notice (Extensions/PopupBlocker/Resources/popup-relay.js) in
// Playwright Chromium. Local only: every request is answered from disk or refused.
//   NODE_PATH=/path/to/node_modules node Tests/PopupGuard/relay/relay.test.mjs
// needs playwright-core and its Chromium (npx playwright-core install chromium).
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const { chromium } = require("playwright-core");
const here = dirname(fileURLToPath(import.meta.url));
const relay = readFileSync(join(here, "../../../Extensions/PopupBlocker/Resources/popup-relay.js"), "utf8");
const stubs = readFileSync(join(here, "stubs.js"), "utf8");
const pageHtml = readFileSync(join(here, "page.html"), "utf8");
const ORIGIN = "http://relay.test";
const AD = "http://ads.example/landing";

const browser = await chromium.launch();
let failures = 0;
const results = [];

async function freshPage() {
  const context = await browser.newContext({ viewport: { width: 1000, height: 700 } });
  await context.route("**/*", (route) => {
    const url = route.request().url();
    if (url === `${ORIGIN}/`) return route.fulfill({ contentType: "text/html", body: pageHtml });
    return route.abort();
  });
  const page = await context.newPage();
  await page.addInitScript(stubs);
  await page.goto(`${ORIGIN}/`);
  await page.addScriptTag({ content: relay });
  return page;
}

const opened = (page) => page.evaluate(() => window.__opened.length);
const allowOnce = (page) => page.evaluate(() => window.__rect(window.__button("Allow once")));
const wait = (page, ms) => page.waitForTimeout(ms);

async function test(name, body) {
  const page = await freshPage();
  try {
    await body(page);
    results.push(`  ✓ ${name}`);
  } catch (error) {
    failures += 1;
    results.push(`  ✗ ${name}\n      ${error.message}`);
  } finally {
    await page.context().close();
  }
}

function expect(ok, message) {
  if (!ok) throw new Error(message);
}

await test("the notice offers Allow once and dismiss only, and points to the toolbar button", async (page) => {
  await page.evaluate(() => window.__show());
  const labels = await page.evaluate(() => [...window.__host().shadowRoot.querySelectorAll("button")].map((b) => b.textContent));
  const text = await page.evaluate(() => window.__host().shadowRoot.textContent);
  expect(JSON.stringify(labels) === JSON.stringify(["Allow once", "×"]), `buttons: ${JSON.stringify(labels)}`);
  expect(/toolbar button/.test(text) && !/always/i.test(text), `text: ${text}`);
  const top = await page.evaluate(() => window.__host().matches(":popover-open"));
  expect(top, "the host is not in the top layer");
});

await test("(d) a normal click after the delay opens the blocked window once", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 700);
  const button = await allowOnce(page);
  await page.mouse.click(button.x, button.y);
  const calls = await page.evaluate(() => window.__opened);
  expect(calls.length === 1 && calls[0][0] === AD && calls[0][1] === "_blank" && calls[0][2] === "noopener", `window.open calls: ${JSON.stringify(calls)}`);
  expect(await page.evaluate(() => !window.__host().isConnected), "the notice did not close");
});

await test("(c) a click within 500 ms of display is ignored; a later one works", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 150);
  const button = await allowOnce(page);
  await page.mouse.click(button.x, button.y);
  expect((await opened(page)) === 0, "an early click opened the window");
  await wait(page, 600);
  await page.mouse.click(button.x, button.y);
  expect((await opened(page)) === 1, "the later click did not open the window");
});

await test("(a) host made transparent and moved under the page's button: no allow", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 700);
  const play = await page.evaluate(() => window.__rect(document.getElementById("play")));
  // The page keeps restyling the host every frame, so the relay can't simply put it back once.
  await page.evaluate(({ left, top }) => {
    window.__tampers = 0;
    const host = window.__host();
    const step = () => {
      host.style.setProperty("opacity", "0", "important");
      host.style.setProperty("left", `${left}px`, "important");
      host.style.setProperty("top", `${top}px`, "important");
      host.style.setProperty("right", "auto", "important");
      host.style.setProperty("bottom", "auto", "important");
      window.__tampers += 1;
      window.__underPlay = document.elementFromPoint(left + 20, top + 20) === host;
      requestAnimationFrame(step);
    };
    step();
  }, play);
  await wait(page, 700);
  await page.mouse.click(play.left + 20, play.top + 20);
  await wait(page, 50);
  const tampers = await page.evaluate(() => window.__tampers);
  expect(tampers > 5, `the page restyled the host only ${tampers} times`);
  expect((await opened(page)) === 0, "the click opened the blocked window");
});

await test("(a) the page fades the host only as the pointer goes down: no allow", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 700);
  const button = await allowOnce(page);
  await page.evaluate(() => {
    window.__tampers = 0;
    window.addEventListener("pointerdown", () => {
      window.__host().style.setProperty("opacity", "0", "important");
      window.__tampers += 1;
    }, true);
  });
  await page.mouse.click(button.x, button.y);
  expect((await page.evaluate(() => window.__tampers)) === 1, "setup: the page did not restyle the host");
  expect((await opened(page)) === 0, "the click opened the blocked window");
});

await test("(a) an ancestor faded to opacity 0, host in place under the click: no allow", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 700);
  const button = await allowOnce(page);
  await page.evaluate(() => document.documentElement.classList.add("faded"));
  const hit = await page.evaluate(({ x, y }) => document.elementFromPoint(x, y) === window.__host(), button);
  expect(hit, "setup: the click point does not reach the host");
  await page.mouse.click(button.x, button.y);
  expect((await opened(page)) === 0, "the click opened the blocked window");
  await page.evaluate(() => document.documentElement.classList.remove("faded"));
  await page.mouse.click(button.x, button.y);
  expect((await opened(page)) === 1, "control: after the page is visible again the click did not work");
});

await test("(a) an ancestor with filter: opacity(0): no allow", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 700);
  const button = await allowOnce(page);
  await page.evaluate(() => { document.documentElement.style.filter = "opacity(0)"; });
  await page.mouse.click(button.x, button.y);
  expect((await opened(page)) === 0, "the click opened the blocked window");
});

await test("(a) host moved into a transparent page wrapper: put back, clock restarted", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 700);
  const button = await allowOnce(page);
  await page.evaluate(() => {
    const wrapper = document.createElement("div");
    wrapper.style.opacity = "0";
    document.body.append(wrapper);
    wrapper.append(window.__host());
  });
  await page.mouse.click(button.x, button.y);
  const parent = await page.evaluate(() => window.__host().parentNode === document.documentElement);
  expect(parent, "the host was not put back");
  expect((await opened(page)) === 0, "the click right after the move opened the window");
});

await test("(b) host kept offscreen with a decoy in its place: no allow", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 700);
  await page.evaluate(() => {
    const decoy = document.createElement("button");
    decoy.id = "decoy";
    decoy.textContent = "Continue";
    document.body.append(decoy);
    window.__tampers = 0;
    const host = window.__host();
    const step = () => {
      host.style.setProperty("right", "-9999px", "important");
      window.__tampers += 1;
      requestAnimationFrame(step);
    };
    step();
  });
  await wait(page, 700);
  const decoy = await page.evaluate(() => window.__rect(document.getElementById("decoy")));
  await page.mouse.click(decoy.x, decoy.y);
  expect((await page.evaluate(() => window.__tampers)) > 5, "setup: the page did not keep moving the host");
  expect((await opened(page)) === 0, "the click opened the blocked window");
});

await test("(b) a see-through page layer opened over the notice: raised, clock restarted", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 700);
  const button = await allowOnce(page);
  await page.evaluate(() => {
    const layer = document.createElement("div");
    layer.id = "layer";
    layer.popover = "manual";
    layer.style.cssText = "inset: 0; width: 100vw; height: 100vh; margin: 0; border: 0; background: transparent; pointer-events: none;";
    document.body.append(layer);
    layer.showPopover();
  });
  await wait(page, 100);
  await page.mouse.click(button.x, button.y);
  expect(await page.evaluate(() => document.getElementById("layer").matches(":popover-open")), "setup: the page layer is not open");
  expect((await opened(page)) === 0, "a click right after the layer opened went through");
});

await test("a click a script sends (not trusted): no allow", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 700);
  await page.evaluate(() => window.__button("Allow once").click());
  expect((await opened(page)) === 0, "a script click opened the window");
});

await test("keyboard: Enter on the focused button after the delay opens the window", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 700);
  await page.evaluate(() => window.__button("Allow once").focus());
  await page.keyboard.press("Enter");
  expect((await opened(page)) === 1, "Enter did not open the window");
});

await test("the page removes the notice: it comes back, then gives up after repeated removals", async (page) => {
  await page.evaluate(() => window.__show());
  await wait(page, 100);
  await page.evaluate(() => window.__host().remove());
  await wait(page, 50);
  expect(await page.evaluate(() => window.__host().isConnected), "the notice was not put back");
  await page.evaluate(async () => {
    for (let i = 0; i < 30; i += 1) {
      window.__host().remove();
      await new Promise((resolve) => setTimeout(resolve, 0));
    }
  });
  expect(!(await page.evaluate(() => window.__host().isConnected)), "the relay kept fighting the page");
});

await browser.close();
console.log("Relay notice (Chromium)");
console.log(results.join("\n"));
console.log(failures ? `${failures} failed` : "all passed");
process.exit(failures ? 1 : 0);

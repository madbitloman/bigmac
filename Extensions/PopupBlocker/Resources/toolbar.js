// BigMac Pop-up Blocker, the toolbar button's page: the current site, how many pop-ups were
// blocked on it in this tab, and the switch that adds it to BigMac's allowed sites. This page
// belongs to the extension, so a web page can't draw over it or click it. The background script
// does the work and takes the site from the tab itself.
(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  const $ = (id) => document.getElementById(id);
  let tabId = null;

  function plural(n, one, many) {
    return `${n} ${n === 1 ? one : many}`;
  }

  function render(state) {
    if (!state) {
      $("site").textContent = "BigMac Pop-up Blocker";
      $("count").textContent = "";
      $("row").hidden = true;
      $("note").textContent = "";
      $("status").textContent = "Couldn't reach the pop-up blocker. Try again in a moment.";
      return;
    }
    if (!state.site) {
      $("site").textContent = "Not a web page";
      $("count").textContent = "";
      $("row").hidden = true;
      $("note").textContent = "Pop-up blocking works on web pages that Safari lets this extension see.";
      $("status").textContent = "";
      return;
    }
    $("site").textContent = state.site;
    $("count").textContent = `${plural(state.blocked, "pop-up", "pop-ups")} blocked on this site in this tab`;
    $("row").hidden = false;
    $("label").textContent = `Always allow pop-ups on ${state.site}`;
    const allow = $("allow");
    allow.checked = state.allowed;
    allow.disabled = !state.linked || (!state.allowed && !state.listable);

    if (state.allowed && state.via && state.via !== state.site) {
      $("note").textContent = `Allowed through ${state.via}. Turning this off removes ${state.via} from BigMac's allowed sites.`;
    } else {
      $("note").textContent = "Allowed sites skip all of BigMac's blocking, ads included. You can also manage them in BigMac's Ad Blocking pane.";
    }
    let status = "";
    if (!state.linked) status = "Open BigMac once so this extension can use its settings.";
    else if (!state.allowed && !state.listable) status = "Only sites with a domain name can be allowed, not addresses like this one.";
    else if (!state.popups) status = "Pop-up blocking is off in BigMac (Ad Blocking, Pop-ups).";
    $("status").textContent = status;
  }

  async function send(message) {
    try {
      return await api.runtime.sendMessage(message);
    } catch {
      return null;
    }
  }

  async function load() {
    try {
      const [tab] = await api.tabs.query({ active: true, currentWindow: true });
      tabId = tab?.id ?? null;
    } catch {
      tabId = null;
    }
    render(tabId === null ? null : await send({ type: "toolbar-state", tabId }));
  }

  $("allow").addEventListener("change", async (event) => {
    const allow = event.target.checked;
    event.target.disabled = true;
    const state = await send({ type: "toolbar-allow", tabId, allow });
    render(state);
    if (state && !state.changed) $("status").textContent = allow ? "Couldn't add this site." : "Couldn't remove this site.";
  });

  load();
})();

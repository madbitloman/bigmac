# Pop-up blocker test pages

Local pages for the pop-up part of BigMac's Safari web extension, BigMac Pop-up and YouTube Blocker
(`Extensions/PopupBlocker`). They come with the pop-up guard from the blocking engine and aren't in this
repository: `scripts/fetch-blocker-sources.sh` copies them into `build/blocker/popup-guard-fixtures` (without
the guard's source there are none, and this checklist can't be run). Each page is one case and
says what should happen. They open nothing outside this machine except the stand-ins for
sign-in and payment windows (accounts.google.com, paypal.com, hooks.stripe.com), which open
the real address in a pop-up and are only loaded, never used. Serve them on 127.0.0.1;
links to `localhost` count as another site:

```sh
python3 -m http.server 8000 --bind 127.0.0.1 --directory build/blocker/popup-guard-fixtures
```

`swift run BigMac --selftest <dir>` checks the parts that need no browser: the guard is the
build-time copy listed in `build/blocker.sha256`, its sign-in list matches the content blocker's, the
extension's manifest (including the toolbar button's page), which site names the native handler
accepts, and the pop-up rules in the Safari rule list. The guard's rules themselves are tested in
the blocking engine (unit tests, WebKit, and Chromium end to end).

`relay/` tests the in-page notice (`popup-relay.js`) in Playwright Chromium, with stand-ins for
Safari's extension APIs. Every request is answered from disk or refused. It needs `playwright-core`
and its Chromium (`npx playwright-core install chromium`):

```sh
NODE_PATH=/path/to/node_modules node Tests/PopupGuard/relay/relay.test.mjs
```

It checks that Allow once works after a normal click and that nothing opens when the click is too
early (under half a second), sent by a script, or lands on a notice the page has faded, moved,
re-parented, pushed off screen or covered with its own layer.

`relay/background.test.mjs` runs the background script in Node (`node Tests/PopupGuard/relay/background.test.mjs`):
only the toolbar button's page can add or remove an allowed site, the site always comes from the
tab, addresses are never sent, and blocked pop-ups are counted per tab and site.

## Owner checklist (Safari)

Switching on a Safari extension changes Safari's settings, so this part is done by hand.

1. Build with `SIGN_IDENTITY="-" ./make-app.sh`, open `build/BigMac.app` once, then in Safari:
   Settings, Extensions, tick **BigMac Pop-up and YouTube Blocker** and **BigMac Ad Blocker**. For the
   pop-up and YouTube blocker choose *Always Allow on Every Website* (or allow it on 127.0.0.1 and localhost only).
   An ad-hoc build may need Safari's Develop menu, *Allow Unsigned Extensions*.
2. Start the server above and open http://127.0.0.1:8000/.
3. Nasty pages: click as the page says. No new tab or window may stay open, and the page
   must stay where it is. A "Pop-up blocked" notice appears in the bottom-right corner.
   - [ ] click-anywhere
   - [ ] play-button (the button still shows "playing"; no ad)
   - [ ] overlay-link and overlay-div (click the player; a second click reaches the player)
   - [ ] synthetic-click, synthetic-dispatch
   - [ ] timeout
   - [ ] pop-under (a window may flash, then closes)
   - [ ] tab-under, tab-under-same-gesture (the new tab may open; this page must not turn into the ad.
         Needs Safari 26.2 or later, which has the Navigation API; older Safari lets the page navigate)
   - [ ] document-open, iframe-borrow, frames-borrow, form-blank
   - [ ] second-window (only the help window opens)
   - [ ] hijacked-link
   - Skip popup-network here: it points at a real pop-up network, which only the Chromium check
     answers locally. Safari's pop-up rules for those networks are tested in WebKit instead.
4. Legitimate pages: each must open.
   - [ ] blank-link; plain-link with Cmd-click; plain-link with a middle click
   - [ ] help-button, delegated-button, share-button
   - [ ] oauth: both buttons open accounts.google.com
   - [ ] payment: both buttons open PayPal and hooks.stripe.com
   - [ ] print: Print shows "print ok"; Print receipt opens a receipt window
   - [ ] script-link, form-user
5. The notice: on click-anywhere it shows **Allow once**, a dismiss button, and "More in the toolbar
   button", and no other choice.
   - [ ] **Allow once**, clicked straight away, does nothing; clicked again after a moment it opens
         the ad page in a new tab.
   - [ ] Tab to **Allow once** and press Return: it opens the ad page too.
6. The toolbar button (BigMac Pop-up and YouTube Blocker in Safari's toolbar; if it's hidden, add it with
   View, Customize Toolbar).
   - [ ] On click-anywhere after a few blocked clicks, its page shows 127.0.0.1 and the number blocked
         in this tab. The switch is greyed out with a note that only domain names can be allowed:
         BigMac's allowed sites take domain names, not addresses.
   - [ ] On a page that isn't a website (a new empty tab), it says so and shows no switch.
   - [ ] Open https://example.com and turn on **Always allow pop-ups on example.com**. BigMac's Ad &
         Pop-up Blocking pane lists example.com under Allowed Sites (reopen the pane if BigMac was open).
         Close and reopen the toolbar page: the switch is still on.
   - [ ] Turn it off: example.com leaves the list.
   - [ ] Add wikipedia.org in BigMac's Allowed Sites, then open https://en.wikipedia.org: the switch
         is on and says the site is allowed through wikipedia.org. Turning it off removes
         wikipedia.org. Leave the list as it was before the test.
7. Strict: in BigMac, turn on *Strict pop-up blocking*, reload the pages. help-button,
   delegated-button, share-button, second-window and Print receipt now open nothing; oauth,
   payment, links and script-link still open. Turn it off again.
8. BigMac's Ad & Pop-up Blocking pane shows both Safari extensions as On and counts the pop-ups
   blocked under Pop-ups stopped.

## Owner checklist: one switch, YouTube, and the update

9. Allowed list while BigMac is open: with the pane open, use the toolbar button's **Always allow
   pop-ups** on https://example.com, then switch to BigMac.
   - [ ] example.com appears under Allowed Sites as soon as BigMac comes to the front.
   - [ ] Toggle any category in BigMac: example.com is still in the list (BigMac no longer saves
         over a change the toolbar page made). Remove it afterwards.
10. Main switch (top right of the pane).
   - [ ] Off: the categories grey out, Safari shows ads again after a reload, the click-anywhere page
         opens its pop-up, and YouTube plays its ads.
   - [ ] On again: everything is back as it was, with the same categories.
11. YouTube (needs the extension allowed on youtube.com).
   - [ ] With **YouTube ads** on, a video's pre-roll ad is skipped or fast-forwarded.
   - [ ] With it off, reload: the ad plays. Turn it back on.
   - [ ] Add youtube.com to Allowed Sites: ads play; remove it again.
12. Updating from a build with three Safari extensions.
   - [ ] After installing the new BigMac.app over the old one, Safari's Extensions list shows only
         **BigMac Ad Blocker** and **BigMac Pop-up and YouTube Blocker**; BigMac YouTube Ad Skipper is gone.
   - [ ] If the pop-up blocker was on before, it's still on (same identifier), under its new name.
   - [ ] BigMac's pane shows the one-time notice about the merge; **OK** hides it for good.

## Owner checklist: Chrome and Firefox

The extension for Chrome and Firefox is installed by hand. `Tests/BrowserExtension/extension.test.mjs`
loads the built copy into Playwright Chromium in a throwaway profile; this part needs your real browsers.

13. In BigMac's pane, **Browsers**:
   - [ ] Only the browsers installed on this Mac have steps and buttons.
   - [ ] **Show Extension in Finder** opens Finder with `BrowserExtension` selected in
         `~/Library/Application Support/BigMac`. A second click says it's up to date.
14. Chrome (and Brave, Edge, Arc if installed):
   - [ ] **Open … Extensions** opens the browser's extensions page. If a browser opens a blank tab
         instead, paste the address (it's on the clipboard) and note which browser.
   - [ ] Developer mode, **Load unpacked**, choose the folder: the blocker extension appears and its
         toolbar button works. Expect the developer-mode banner on the next start.
   - [ ] https://example.com loads; an ad-heavy news site shows fewer ads.
   - [ ] After a rebuild with a newer extension version, **Show Extension in Finder** says it copied
         the new version, and the extension's **Reload** picks it up without losing its settings.
15. Firefox:
   - [ ] **Open Firefox Add-ons** opens about:debugging (This Firefox). Note it if Firefox refuses the
         address from outside.
   - [ ] **Load Temporary Add-on**, choose `manifest.json`: it loads and its toolbar button works.
   - [ ] After quitting Firefox it's gone, as the pane says.

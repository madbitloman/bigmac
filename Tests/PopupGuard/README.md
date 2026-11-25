# Pop-up blocker test pages

Local pages for the Safari pop-up blocker (`Extensions/PopupBlocker`). Each page is one case and
says what should happen. They open nothing outside this machine except the stand-ins for
sign-in and payment windows (accounts.google.com, paypal.com, hooks.stripe.com), which open
the real address in a pop-up and are only loaded, never used. Serve them on 127.0.0.1;
links to `localhost` count as another site:

```sh
python3 -m http.server 8000 --bind 127.0.0.1 --directory Tests/PopupGuard/fixtures
```

`swift run BigMac --selftest <dir>` checks the parts that need no browser: the guard is the
recorded copy of the blocking engine's, its sign-in list matches `FilterLists.swift`, the
extension's manifest, and the pop-up rules in the Safari rule list. The guard's rules themselves
are tested in the blocking engine (unit tests, WebKit, and Chromium end to end).

## Owner checklist (Safari)

Switching on a Safari extension changes Safari's settings, so this part is done by hand.

1. Build with `SIGN_IDENTITY="-" ./make-app.sh`, open `build/BigMac.app` once, then in Safari:
   Settings, Extensions, tick **BigMac Pop-up Blocker** and **BigMac Ad Blocker**. For the pop-up
   blocker choose *Always Allow on Every Website* (or allow it on 127.0.0.1 and localhost only).
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
5. The notice: on click-anywhere, **Allow once** opens the ad page in a new tab.
   **Always allow on this site** adds 127.0.0.1 to BigMac's allowed sites (Ad Blocking pane), after
   which a click opens the ad. Remove 127.0.0.1 from the list afterwards.
6. Strict: in BigMac, turn on *Strict pop-up blocking*, reload the pages. help-button,
   delegated-button, share-button, second-window and Print receipt now open nothing; oauth,
   payment, links and script-link still open. Turn it off again.
7. BigMac's Ad Blocking pane shows the pop-up blocker as On and counts what it blocked.

# Safari: one web extension, or a content blocker plus one?

**Decision:** keep the content blocker (**BigMac Ad Blocker**) for network blocking and element hiding, and merge the
pop-up blocker and the YouTube ad skipper into one web extension (**BigMac Pop-up and YouTube Blocker**). In Safari you
enable two extensions instead of three, and the BigMac app has one switch for all of it.

## The question

Could a single Safari web extension do everything: network blocking with `declarativeNetRequest` (DNR), element
hiding, the pop-up guard, the YouTube skipper and the toolbar page?

## What Safari does with DNR rules

WebKit's source (WebKit/WebKit `main`, November 2026) answers most of it:

- `_WKWebExtensionDeclarativeNetRequestTranslator.mm` and `_WKWebExtensionDeclarativeNetRequestRule.mm` translate every
  DNR rule into a **WebKit content rule list** rule, the same format and engine as a content blocker. A web extension
  doesn't get a faster or different matcher, only an extra translation step.
- The translation makes **one content rule per `requestDomains` entry** ("we also have to create one rule per request
  domain"), plus one `ignore-following-rules` per excluded domain.
- `regexFilter` must pass `WKContentRuleList _supportsRegularExpression:` and be ASCII: the same regex subset as a
  content blocker.
- Resource types map to WebKit's: `main_frame`, `sub_frame`, `script`, `image`, `stylesheet`, `font`, `media`,
  `ping`, `websocket`, `other` and so on. **There is no pop-up type** in DNR, while a content blocker has
  `resource-type: popup`.
- DNR has no element-hiding action. A content blocker has `css-display-none`; a web extension would have to inject
  stylesheets and per-site selectors from scripts on every page.
- `WebExtensionConstants.h`: at most 100 static rulesets, 50 enabled, and 30,000 dynamic plus session rules.

## The numbers here

| | Rules |
|---|---|
| BigMac's content blocker lists (`build/blocker/Filters`, all categories) | 115,521 rules, compiled by WebKit in the self-test |
| of which element hiding (`css-display-none`) | 5,705 |
| of which pop-up windows (`resource-type: popup`) | 2,956 |
| of which limited to or excluding sites (`if-domain` / `unless-domain`) | 6,513 |

A DNR list grouped by domain expands back to roughly this size in Safari, on the same engine. Moving to DNR would
not make Safari faster; it would lose the 2,956 pop-up rules (DNR can't express "a new window to this address") and move 5,705 hiding rules out of the engine
into scripts.

## Other differences that matter for BigMac

- **Settings from the app.** The content blocker rebuilds its list from the app group the moment the app calls
  `SFContentBlockerManager.reloadContentBlocker`. A DNR extension would have to ask the app for its settings and call
  `updateEnabledRulesets` / `updateDynamicRules` from its background page, which Safari only runs now and then.
- **Permissions.** A content blocker never sees pages and asks for no website access. The guard needs "read and change
  web pages on all websites" anyway, but anyone who only wants ads blocked can keep using the content blocker alone.
- **Rule compiler.** BigMac's compiler and its WebKit-checked lists stay as they are.

## What changes

- `Extensions/PopupBlocker` is now the merged web extension: the pop-up guard and its relay, the toolbar page, and the
  YouTube skipper, which only runs when the YouTube switch is on and the site isn't allowed. It keeps the bundle id
  `com.bigmac.app.PopupBlocker`, so anyone who had switched the pop-up blocker on keeps it on with the same website
  permission. Its name in Safari changes.
- `Extensions/YouTube` and its appex are gone.
- BigMac shows a one-time notice to people who used the earlier layout.

// BigMac Pop-up and YouTube Blocker, on youtube.com: asks the background whether the YouTube switch is
// on and the site isn't allowed. If so, the background adds the ad skipper (youtube.js and youtube.css)
// to this frame. Nothing else happens here.
(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  api?.runtime?.sendMessage({ type: "youtube-config" }).catch(() => {});
})();

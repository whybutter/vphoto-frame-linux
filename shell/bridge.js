// window.CortexFrame for WebKitGTK (FRAME-API §2), injected before the page runs.
// Same names and argument types as Android's @JavascriptInterface; the calls go
// out as async script messages, and info() answers from a copy that the shell
// refreshes every second.
(function () {
  "use strict";
  var post = function (m, a) {
    window.webkit.messageHandlers.frameShell.postMessage(JSON.stringify({ m: m, a: a }));
  };
  window.__frameInfo = "{}";
  window.CortexFrame = {
    policy: function (json) { post("policy", String(json)); },
    screenOff: function () { post("screenOff"); },
    setBrightness: function (level) { post("setBrightness", Number(level)); },
    info: function () { return window.__frameInfo; },
    reload: function () { post("reload"); },
  };
  // the page is fixed-size and not a document: no selection UI, no callouts
  document.addEventListener("DOMContentLoaded", function () {
    var s = document.createElement("style");
    s.textContent = "*{-webkit-user-select:none;user-select:none;-webkit-touch-callout:none}";
    document.head.appendChild(s);
  });
})();
